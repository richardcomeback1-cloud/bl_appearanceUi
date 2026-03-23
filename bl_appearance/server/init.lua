local resourceName = GetCurrentResourceName()
local activeEvents = {}
local ESX = exports.es_extended:getSharedObject()
local config = exports.bl_appearance:config()

local oxmysql = exports.oxmysql

local function awaitOxmysql(method, query, params)
    local asyncMethod = oxmysql[('%s_async'):format(method)]
    if asyncMethod then
        return asyncMethod(oxmysql, query, params or {})
    end

    local callbackMethod = oxmysql[method]
    if not callbackMethod then
        error(('oxmysql export %s is unavailable'):format(method))
    end

    local p = promise.new()
    callbackMethod(oxmysql, query, params or {}, function(result)
        p:resolve(result)
    end)

    return Citizen.Await(p)
end

local function dbUpdate(query, params)
    return awaitOxmysql('update', query, params)
end

local function dbInsert(query, params)
    return awaitOxmysql('insert', query, params)
end

local function dbQuery(query, params)
    return awaitOxmysql('query', query, params)
end

local function dbSingle(query, params)
    return awaitOxmysql('single', query, params)
end

local function dbScalar(query, params)
    return awaitOxmysql('scalar', query, params)
end

local function dbPrepare(query, params)
    return awaitOxmysql('prepare', query, params)
end

local function dbReady(cb)
    CreateThread(function()
        while GetResourceState('oxmysql') ~= 'started' do
            Wait(50)
        end

        cb()
    end)
end

RegisterNetEvent(('_bl_cb_%s'):format(resourceName), function(key, ...)
    local resolver = activeEvents[key]
    if resolver then
        activeEvents[key] = nil
        resolver(...)
    end
end)

local function triggerClientCallback(eventName, playerId, ...)
    local key
    repeat
        key = ('%s:%d:%s'):format(eventName, math.random(0, 100000), tostring(playerId))
    until not activeEvents[key]

    local p = promise.new()
    activeEvents[key] = function(response)
        p:resolve(response)
    end

    TriggerClientEvent(('_bl_cb_%s'):format(eventName), playerId, resourceName, key, ...)
    return Citizen.Await(p)
end

local function onClientCallback(eventName, cb)
    RegisterNetEvent(('_bl_cb_%s'):format(eventName), function(resource, key, ...)
        local src = source
        local ok, response = pcall(cb, src, ...)
        if not ok then
            print(('an error occurred while handling callback event %s'):format(eventName))
            print(('^3%s^0'):format(response))
            response = nil
        end

        TriggerClientEvent(('_bl_cb_%s'):format(resource), src, key, response)
    end)
end

local function getPlayerWrapper(src)
    local xPlayer = ESX.GetPlayerFromId(tonumber(src))
    if not xPlayer then return nil end

    local identifier = xPlayer.identifier
    if not identifier and xPlayer.getIdentifier then
        identifier = xPlayer.getIdentifier()
    end
    if not identifier and xPlayer.get then
        identifier = xPlayer.get('identifier')
    end

    local job = xPlayer.job or {}
    local gradeLevel = tonumber(job.grade) or tonumber(job.grade_level) or 0
    local gradeName = job.grade_name or job.gradeLabel or 'unknown'

    return {
        source = xPlayer.source,
        id = identifier,
        identifier = identifier,
        job = {
            name = job.name or 'unknown',
            grade = {
                level = gradeLevel,
                name = gradeName,
            }
        },
        addItem = function(item, count, metadata)
            if not item or not count then return false end
            if xPlayer.addInventoryItem then
                xPlayer.addInventoryItem(item, count, metadata)
                return true
            end
            return false
        end,
        removeItem = function(item, count, slot)
            if not item or not count then return false end
            if xPlayer.removeInventoryItem then
                xPlayer.removeInventoryItem(item, count, slot)
                return true
            end
            return false
        end
    }
end

local core = {
    GetPlayer = getPlayerWrapper,
    RegisterUsableItem = function(item, cb)
        if not item or not ESX.RegisterUsableItem then return end
        ESX.RegisterUsableItem(item, function(playerSource)
            cb(playerSource, nil, {})
        end)
    end
}

local function getPlayerData(src)
    return core.GetPlayer(src)
end

local function getFrameworkID(src)
    local player = core.GetPlayer(src)
    return player and player.id or nil
end

local mergeAppearance
local getAppearance
local saveAppearance

local appearanceCache = {}
local pendingAppearanceSaves = {}
local appearanceSaveDebounceMs = math.max(tonumber(GetConvar('bl:appearanceSaveDebounceMs', '750')) or 750, 0)
local appearanceMigrationFlag = 'bl_appearance:legacy_appearance_migrated_v1'

local function cloneTable(value)
    if type(value) ~= 'table' then return value end

    local copy = {}
    for key, entry in pairs(value) do
        copy[key] = cloneTable(entry)
    end

    return copy
end

local function decodeJsonTable(value)
    if not value or value == '' then
        return nil
    end

    local ok, decoded = pcall(json.decode, value)
    if not ok or type(decoded) ~= 'table' then
        return nil
    end

    return decoded
end

local function compactTattoos(tattoos)
    if type(tattoos) ~= 'table' then
        return {}
    end

    local compact = {}
    for i = 1, #tattoos do
        local entry = tattoos[i]
        if type(entry) == 'table' then
            local tattoo = entry.tattoo
            if type(tattoo) == 'table' then
                compact[#compact + 1] = {
                    id = entry.id,
                    zoneIndex = entry.zoneIndex,
                    dlcIndex = entry.dlcIndex,
                    opacity = entry.opacity,
                    tattoo = {
                        label = tattoo.label,
                        hash = tattoo.hash,
                        zone = tattoo.zone,
                        dlc = tattoo.dlc,
                        opacity = tattoo.opacity,
                    }
                }
            end
        end
    end

    return compact
end

local function sanitizeAppearance(appearance)
    if type(appearance) ~= 'table' then
        return nil
    end

    return {
        model = appearance.model,
        hairColor = cloneTable(appearance.hairColor),
        headBlend = cloneTable(appearance.headBlend),
        headStructure = cloneTable(appearance.headStructure),
        headOverlay = cloneTable(appearance.headOverlay),
        drawables = cloneTable(appearance.drawables),
        props = cloneTable(appearance.props),
        tattoos = compactTattoos(appearance.tattoos),
    }
end

local function setAppearanceCache(frameworkId, appearance)
    if not frameworkId then return nil end

    local sanitized = sanitizeAppearance(appearance)
    if sanitized then
        appearanceCache[frameworkId] = sanitized
    else
        appearanceCache[frameworkId] = nil
    end

    return sanitized
end

local function getCachedAppearance(frameworkId)
    local cached = frameworkId and appearanceCache[frameworkId]
    return cached and cloneTable(cached) or nil
end

local function getUserSkin(frameworkId)
    local cached = getCachedAppearance(frameworkId)
    if cached then
        return cached
    end

    local response = dbScalar('SELECT skin FROM users WHERE identifier = ? LIMIT 1', { frameworkId })
    local appearance = decodeJsonTable(response)
    if appearance then
        setAppearanceCache(frameworkId, appearance)
        return getCachedAppearance(frameworkId)
    end

    return nil
end

local function flushAppearanceSave(frameworkId)
    local pending = frameworkId and pendingAppearanceSaves[frameworkId]
    if not pending or not frameworkId then return 0 end

    local updated = dbUpdate('UPDATE users SET skin = ? WHERE identifier = ?', {
        json.encode(pending.appearance), frameworkId
    }) or 0

    if pendingAppearanceSaves[frameworkId] == pending then
        pendingAppearanceSaves[frameworkId] = nil
    end

    return updated
end

local function queueAppearanceSave(frameworkId, appearance, src)
    if not frameworkId or not appearance then return 0 end

    local pending = pendingAppearanceSaves[frameworkId]
    if pending then
        pending.appearance = cloneTable(appearance)
        pending.src = src or pending.src
        pending.updatedAt = GetGameTimer()
        return 1
    end

    pending = {
        appearance = cloneTable(appearance),
        src = src,
        updatedAt = GetGameTimer(),
    }
    pendingAppearanceSaves[frameworkId] = pending

    CreateThread(function()
        local lastUpdatedAt = pending.updatedAt
        while pendingAppearanceSaves[frameworkId] == pending do
            Wait(appearanceSaveDebounceMs)
            if pendingAppearanceSaves[frameworkId] ~= pending then
                return
            end
            if pending.updatedAt == lastUpdatedAt then
                break
            end
            lastUpdatedAt = pending.updatedAt
        end

        flushAppearanceSave(frameworkId)
    end)

    return 1
end

local function syncESXUserSkin(frameworkId, appearance, src)
    local sanitized = setAppearanceCache(frameworkId, appearance)
    if not frameworkId or not sanitized then return 0 end

    local xPlayer = src and ESX.GetPlayerFromId(tonumber(src)) or ESX.GetPlayerFromIdentifier(frameworkId)
    if xPlayer then
        xPlayer.skin = cloneTable(sanitized)
    end

    if appearanceSaveDebounceMs == 0 then
        pendingAppearanceSaves[frameworkId] = { appearance = cloneTable(sanitized), src = src, updatedAt = GetGameTimer() }
        return flushAppearanceSave(frameworkId)
    end

    return queueAppearanceSave(frameworkId, sanitized, src)
end

local function getPersistedAppearance(src, frameworkId)
    return getAppearance(src, frameworkId)
end

local function saveSkin(src, frameworkId, skin)
    frameworkId = frameworkId or getFrameworkID(src)
    local appearance = getPersistedAppearance(src, frameworkId) or {}
    for key, value in pairs(skin or {}) do
        appearance[key] = value
    end
    return saveAppearance(src, frameworkId, appearance, true)
end

local function saveClothes(src, frameworkId, clothes)
    frameworkId = frameworkId or getFrameworkID(src)
    local appearance = getPersistedAppearance(src, frameworkId) or {}
    for key, value in pairs(clothes or {}) do
        appearance[key] = value
    end
    return saveAppearance(src, frameworkId, appearance, true)
end

local function saveTattoos(src, frameworkId, tattoos)
    frameworkId = frameworkId or getFrameworkID(src)
    local appearance = getPersistedAppearance(src, frameworkId) or {}
    appearance.tattoos = tattoos or {}
    return saveAppearance(src, frameworkId, appearance, true)
end

saveAppearance = function(src, frameworkId, appearance, force)
    if not force and src and frameworkId and getFrameworkID(src) ~= frameworkId then
        print(('You are trying to save an appearance for a different player %s %s'):format(src, frameworkId))
    end

    frameworkId = frameworkId or getFrameworkID(src)
    if not frameworkId then return 0 end

    local sanitized = sanitizeAppearance(appearance)
    if not sanitized then return 0 end

    return syncESXUserSkin(frameworkId, sanitized, src)
end

onClientCallback('bl_appearance:server:saveSkin', saveSkin)
exports('SavePlayerSkin', function(id, skin)
    return saveSkin(nil, id, skin)
end)

onClientCallback('bl_appearance:server:saveClothes', saveClothes)
exports('SavePlayerClothes', function(id, clothes)
    return saveClothes(nil, id, clothes)
end)

onClientCallback('bl_appearance:server:saveTattoos', saveTattoos)
exports('SavePlayerTattoos', function(id, tattoos)
    return saveTattoos(nil, id, tattoos)
end)

onClientCallback('bl_appearance:server:saveAppearance', saveAppearance)
exports('SavePlayerAppearance', function(id, appearance)
    return saveAppearance(nil, id, appearance)
end)

local function getOutfits(src, frameworkId)
    frameworkId = frameworkId or getFrameworkID(src)
    local player = core.GetPlayer(src)
    local job = player and player.job or { name = 'unknown', grade = { level = 0, name = 'unknown' } }

    local ok, response = pcall(dbQuery, 'SELECT * FROM outfits WHERE player_id = ? OR (jobname = ? AND jobrank <= ?)', {
        frameworkId, job.name, job.grade.level
    })

    if not ok then
        print(('An error occurred while fetching outfits: %s'):format(response))
        return {}
    end

    if not response or #response == 0 then
        return {}
    end

    local outfits = {}
    for i = 1, #response do
        local outfit = response[i]
        outfits[#outfits + 1] = {
            id = outfit.id,
            label = outfit.label,
            outfit = json.decode(outfit.outfit),
            jobname = outfit.jobname,
        }
    end

    return outfits
end

onClientCallback('bl_appearance:server:getOutfits', getOutfits)
exports('GetOutfits', getOutfits)

local function renameOutfit(src, data)
    return dbUpdate('UPDATE outfits SET label = ? WHERE player_id = ? AND id = ?', {
        data.label, getFrameworkID(src), data.id
    })
end

onClientCallback('bl_appearance:server:renameOutfit', renameOutfit)
exports('RenameOutfit', renameOutfit)

local function deleteOutfit(src, id)
    local result = dbUpdate('DELETE FROM outfits WHERE player_id = ? AND id = ?', {
        getFrameworkID(src), id
    })
    return result > 0
end

onClientCallback('bl_appearance:server:deleteOutfit', deleteOutfit)
exports('DeleteOutfit', deleteOutfit)

local function saveOutfit(src, data)
    local frameworkId = getFrameworkID(src)
    local jobname, jobrank = nil, 0
    if data.job then
        jobname = data.job.name
        jobrank = data.job.rank or data.job.grade or 0
    end

    return dbInsert('INSERT INTO outfits (player_id, label, outfit, jobname, jobrank) VALUES (?, ?, ?, ?, ?)', {
        frameworkId, data.label, json.encode(data.outfit), jobname, jobrank
    })
end

onClientCallback('bl_appearance:server:saveOutfit', saveOutfit)
exports('SaveOutfit', saveOutfit)

local function fetchOutfit(_, id)
    local response = dbScalar('SELECT outfit FROM outfits WHERE id = ?', { id })
    return response and json.decode(response) or nil
end

onClientCallback('bl_appearance:server:fetchOutfit', fetchOutfit)
exports('FetchOutfit', fetchOutfit)

local function importOutfit(src, frameworkId, outfitId, outfitName)
    frameworkId = frameworkId or getFrameworkID(src)
    local result = dbSingle('SELECT label, outfit FROM outfits WHERE id = ?', { outfitId })
    if not result then
        return { success = false, message = 'Outfit not found' }
    end

    local newId = dbInsert('INSERT INTO outfits (player_id, label, outfit) VALUES (?, ?, ?)', {
        frameworkId, outfitName, result.outfit
    })

    return {
        success = true,
        id = newId,
        outfit = json.decode(result.outfit),
        label = outfitName,
    }
end

onClientCallback('bl_appearance:server:importOutfit', importOutfit)
exports('ImportOutfit', importOutfit)

local outfitItem = config.outfitItem

onClientCallback('bl_appearance:server:itemOutfit', function(src, data)
    if not outfitItem then
        return false
    end

    local player = core.GetPlayer(src)
    if not player then return false end
    return player.addItem(outfitItem, 1, data)
end)

core.RegisterUsableItem(outfitItem, function(source2, slot, metadata)
    if not outfitItem then return end

    local player = getPlayerData(source2)
    if player and player.removeItem(outfitItem, 1, slot) and metadata and metadata.outfit then
        TriggerClientEvent('bl_appearance:client:useOutfitItem', source2, metadata.outfit)
    end
end)

local function getSkin(src, frameworkId)
    local appearance = getAppearance(src, frameworkId)
    if not appearance then return nil end

    return {
        headBlend = appearance.headBlend,
        headStructure = appearance.headStructure,
        hairColor = appearance.hairColor,
        model = appearance.model,
    }
end

onClientCallback('bl_appearance:server:getSkin', getSkin)
exports('GetPlayerSkin', function(id)
    return getSkin(nil, id)
end)

local function getClothes(src, frameworkId)
    local appearance = getAppearance(src, frameworkId)
    if not appearance then return nil end

    return {
        drawables = appearance.drawables,
        props = appearance.props,
        headOverlay = appearance.headOverlay,
    }
end

onClientCallback('bl_appearance:server:getClothes', getClothes)
exports('GetPlayerClothes', function(id)
    return getClothes(nil, id)
end)

local function getTattoos(src, frameworkId)
    local appearance = getAppearance(src, frameworkId)
    return appearance and appearance.tattoos or {}
end

onClientCallback('bl_appearance:server:getTattoos', getTattoos)
exports('GetPlayerTattoos', function(id)
    return getTattoos(nil, id)
end)

mergeAppearance = function(skin, clothes, tattoos, id)
    local appearance = {}
    skin = skin or {}
    clothes = clothes or {}

    for key, value in pairs(skin) do
        appearance[key] = value
    end
    for key, value in pairs(clothes) do
        appearance[key] = value
    end

    appearance.tattoos = tattoos or {}
    appearance.id = id
    return appearance
end

getAppearance = function(src, frameworkId)
    if not frameworkId and not src then
        return nil
    end

    frameworkId = frameworkId or getFrameworkID(src)
    local appearance = getUserSkin(frameworkId)
    if type(appearance) ~= 'table' then
        return nil
    end

    appearance.id = frameworkId
    appearance.tattoos = appearance.tattoos or {}
    return appearance
end

onClientCallback('bl_appearance:server:getAppearance', getAppearance)
exports('GetPlayerAppearance', function(id)
    return getAppearance(nil, id)
end)

local function migrateFivem(src)
    local response = dbQuery('SELECT * FROM `players`')
    if not response then return end

    for i = 1, #response do
        local element = response[i]
        if element.skin then
            triggerClientCallback('bl_appearance:client:migration:setAppearance', src, {
                type = 'fivem',
                data = json.decode(element.skin)
            })
            Wait(100)
            local appearance = triggerClientCallback('bl_appearance:client:getAppearance', src)
            saveAppearance(tonumber(src), element.citizenid, appearance, true)
        end
    end

    print(('Converted %s appearances'):format(#response))
end

local function migrateIllenium(src)
    local response = dbQuery('SELECT * FROM `playerskins` WHERE active = 1')
    if not response then return end

    for i = 1, #response do
        local element = response[i]
        if element.skin then
            triggerClientCallback('bl_appearance:client:migration:setAppearance', src, {
                type = 'illenium',
                data = json.decode(element.skin)
            })
            Wait(100)
            local appearance = triggerClientCallback('bl_appearance:client:getAppearance', src)
            saveAppearance(tonumber(src), element.citizenid, appearance, true)
        end
    end

    print(('Converted %s appearances'):format(#response))
end

local function migrateQb(src)
    local response = dbQuery('SELECT * FROM `playerskins` WHERE active = 1')
    if not response then return end

    for i = 1, #response do
        local element = response[i]
        TriggerClientEvent('qb-clothes:loadSkin', src, 0, element.model, element.skin)
        Wait(200)
        local appearance = triggerClientCallback('bl_appearance:client:getAppearance', src)
        saveAppearance(tonumber(src), element.citizenid, appearance, true)
    end

    print(('Converted %s appearances'):format(#response))
end

local migrations = {
    esx = function()
        print('bl_appearance: ESX migration is not implemented in this resource build.')
    end,
    fivem = migrateFivem,
    illenium = migrateIllenium,
    qb = migrateQb,
}

local function hasCompletedAppearanceMigration()
    return GetResourceKvpString(appearanceMigrationFlag) == 'done'
end

local function markAppearanceMigrationComplete()
    SetResourceKvp(appearanceMigrationFlag, 'done')
end

local function migrateLegacyAppearanceTable()
    if hasCompletedAppearanceMigration() then
        return
    end

    local tableExists = dbScalar([[
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = 'appearance'
        LIMIT 1
    ]])

    if not tableExists then
        markAppearanceMigrationComplete()
        return
    end

    local rows = dbQuery('SELECT id, skin, clothes, tattoos FROM appearance')
    if not rows or #rows == 0 then
        markAppearanceMigrationComplete()
        return
    end

    local migrated = 0
    for i = 1, #rows do
        local row = rows[i]
        local appearance = mergeAppearance(
            decodeJsonTable(row.skin) or {},
            decodeJsonTable(row.clothes) or {},
            decodeJsonTable(row.tattoos) or {},
            row.id
        )

        if next(appearance) then
            appearance.id = nil
            local sanitized = sanitizeAppearance(appearance)
            if sanitized then
                setAppearanceCache(row.id, sanitized)
                local updated = dbUpdate('UPDATE users SET skin = ? WHERE identifier = ?', {
                    json.encode(sanitized), row.id
                }) or 0
                if updated > 0 then
                    migrated = migrated + 1
                end
            end
        end
    end

    markAppearanceMigrationComplete()

    if migrated > 0 then
        print(('bl_appearance: migrated %s legacy appearance rows into users.skin'):format(migrated))
    end
end

dbReady(function()
    migrateLegacyAppearanceTable()
end)

AddEventHandler('playerDropped', function()
    local frameworkId = getFrameworkID(source)
    if frameworkId then
        flushAppearanceSave(frameworkId)
        appearanceCache[frameworkId] = nil
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end

    for frameworkId in pairs(pendingAppearanceSaves) do
        flushAppearanceSave(frameworkId)
    end
end)

RegisterNetEvent('bl_appearance:server:setroutingbucket', function()
    local src = source
    SetPlayerRoutingBucket(src, src)
end)

RegisterNetEvent('bl_appearance:server:resetroutingbucket', function()
    local src = source
    SetPlayerRoutingBucket(src, 0)
end)

RegisterCommand('migrate', function(source2)
    if source2 == 0 then
        local players = GetPlayers()
        source2 = tonumber(players[1])
    end

    if not source2 then return end

    local currentConfig = exports.bl_appearance:config()
    local migrationKey = currentConfig.previousClothing == 'fivem-appearance' and 'fivem' or currentConfig.previousClothing
    local migration = migrations[migrationKey]
    if migration then
        migration(source2)
    end
end, true)
