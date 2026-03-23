local ped = 0
local resourceName = GetCurrentResourceName()
local eventTimers = {}
local activeEvents = {}
local ESX = exports.es_extended:getSharedObject()
local esxPlayerData = {}
local currentAppearanceState = nil
local armour = 0
local open = false
local creationActive = false

local function cloneTable(value)
    if type(value) ~= 'table' then return value end
    local copy = {}
    for k, v in pairs(value) do
        copy[k] = cloneTable(v)
    end
    return copy
end

local function mergeTables(base, override)
    if type(base) ~= 'table' then
        if override == nil then return base end
        return cloneTable(override)
    end

    local merged = cloneTable(base)
    if type(override) ~= 'table' then
        return merged
    end

    for key, value in pairs(override) do
        if type(value) == 'table' and type(merged[key]) == 'table' then
            merged[key] = mergeTables(merged[key], value)
        else
            merged[key] = cloneTable(value)
        end
    end

    return merged
end

local function hasValue(list, value)
    for i = 1, #list do
        if list[i] == value then
            return true
        end
    end
    return false
end

local function updatePed(pedHandle)
    ped = pedHandle
end

local function sendNUIEvent(action, data)
    SendNUIMessage({ action = action, data = data })
end

local function delay(ms)
    Wait(ms)
end

local function requestModel(model)
    local modelHash = type(model) == 'number' and model or GetHashKey(model)
    if not IsModelValid(modelHash) or not IsModelInCdimage(modelHash) then
        print(("attempted to load invalid model '%s'"):format(tostring(model)))
        return 0
    end

    if HasModelLoaded(modelHash) then
        return modelHash
    end

    RequestModel(modelHash)
    while not HasModelLoaded(modelHash) do
        Wait(100)
    end

    return modelHash
end

local function eventTimer(eventName, waitTime)
    if waitTime and waitTime > 0 then
        local currentTime = GetGameTimer()
        if (eventTimers[eventName] or 0) > currentTime then
            return false
        end
        eventTimers[eventName] = currentTime + waitTime
    end
    return true
end

RegisterNetEvent(('_bl_cb_%s'):format(resourceName), function(key, ...)
    local resolver = activeEvents[key]
    if resolver then
        activeEvents[key] = nil
        resolver(...)
    end
end)

local function triggerServerCallback(eventName, ...)
    if not eventTimer(eventName, 0) then return nil end

    local key
    repeat
        key = ('%s:%d'):format(eventName, math.random(0, 100000))
    until not activeEvents[key]

    local p = promise.new()
    activeEvents[key] = function(response)
        p:resolve(response)
    end

    TriggerServerEvent(('_bl_cb_%s'):format(eventName), resourceName, key, ...)
    return Citizen.Await(p)
end

local function onServerCallback(eventName, cb)
    RegisterNetEvent(('_bl_cb_%s'):format(eventName), function(resource, key, ...)
        local ok, response = pcall(cb, ...)
        if not ok then
            print(('an error occurred while handling callback event %s'):format(eventName))
            print(('^3%s^0'):format(response))
            response = nil
        end

        TriggerServerEvent(('_bl_cb_%s'):format(resource), key, response)
    end)
end

local function decodeLocale(localeName)
    local localePath = ('locale/%s.lua'):format(localeName)
    local localeFileContent = LoadResourceFile(resourceName, localePath)
    if not localeFileContent then
        return nil, localePath
    end

    local localeChunk, loadError = load(localeFileContent, ('@@%s/%s'):format(resourceName, localePath), 't', {})
    if not localeChunk then
        print(('failed to load locale file %s: %s'):format(localePath, loadError))
        return nil, localePath
    end

    local ok, localeTable = pcall(localeChunk)
    if not ok or type(localeTable) ~= 'table' then
        print(('failed to decode locale file %s'):format(localePath))
        return nil, localePath
    end

    return json.encode(localeTable), localePath
end

local function requestLocale()
    local currentLan = exports.bl_appearance:config().locale or 'en'
    local localeFileContent, localePath = decodeLocale(currentLan)
    if not localeFileContent then
        print(('%s not found in locale, using english for now!'):format(localePath))
        localeFileContent = decodeLocale('en')
    end

    if not localeFileContent then
        print('locale/en.lua not found in resource files, using built-in fallback locale')
        localeFileContent = json.encode({
            MENU_TITLE = 'Menu',
            CLOSE_TITLE = 'Close',
            SAVE_TITLE = 'Save',
            ZONE_TITLE = 'Zone'
        })
    end

    return localeFileContent
end

local function syncESXPlayerData(data)
    if type(data) ~= 'table' then return end
    for k, v in pairs(data) do
        esxPlayerData[k] = v
    end
end

local function getPlayerData()
    local liveData = ESX.GetPlayerData and ESX.GetPlayerData() or ESX.PlayerData
    if type(liveData) == 'table' and next(liveData) then
        syncESXPlayerData(liveData)
    end
    return esxPlayerData
end

local function getFrameworkID()
    local playerData = getPlayerData()
    return playerData.identifier or playerData.cid or playerData.charid or playerData.license or nil
end

local function getPlayerGenderModel()
    local playerData = getPlayerData()
    local gender = playerData.gender or playerData.sex
    if gender == 'male' or gender == 'm' or gender == 0 or gender == '0' then
        return 'mp_m_freemode_01'
    end
    return 'mp_f_freemode_01'
end

local function getJobInfo()
    local job = getPlayerData().job
    if not job then return nil end
    return {
        name = job.name,
        rank = type(job.grade) == 'number' and job.grade or tonumber(job.grade) or 0,
        isBoss = job.isBoss or job.grade_name == 'boss'
    }
end

local WHOLE_BODY_MAX_DISTANCE = 2.0
local DEFAULT_MAX_DISTANCE = 1.0
local running = false
local camDistance = 1.8
local cam = nil
local angleY = 0.0
local angleZ = 0.0
local targetCoords = nil
local oldCam = nil
local changingCam = false
local currentBone = 'head'
local CameraBones = {
    whole = 0,
    head = 31086,
    torso = 24818,
    legs = { 16335, 46078 },
    shoes = { 14201, 52301 }
}

local function cosDegrees(degrees)
    return math.cos(math.rad(degrees))
end

local function sinDegrees(degrees)
    return math.sin(math.rad(degrees))
end

local function getAngles()
    local x = ((cosDegrees(angleZ) * cosDegrees(angleY)) + (cosDegrees(angleY) * cosDegrees(angleZ))) / 2 * camDistance
    local y = ((sinDegrees(angleZ) * cosDegrees(angleY)) + (cosDegrees(angleY) * sinDegrees(angleZ))) / 2 * camDistance
    local z = sinDegrees(angleY) * camDistance
    return x, y, z
end

local function setCamPosition(mouseX, mouseY)
    if not running or not targetCoords or changingCam then return end
    mouseX = mouseX or 0
    mouseY = mouseY or 0
    angleZ = angleZ - mouseX
    angleY = angleY + mouseY

    local isHeadOrWhole = currentBone == 'whole' or currentBone == 'head'
    local maxAngle = isHeadOrWhole and 89 or 70
    local minAngle = currentBone == 'shoes' and 5 or -20
    angleY = math.min(math.max(angleY, minAngle), maxAngle)

    local x, y, z = getAngles()
    SetCamCoord(cam, targetCoords.x + x, targetCoords.y + y, targetCoords.z + z)
    PointCamAtCoord(cam, targetCoords.x, targetCoords.y, targetCoords.z)
end

local function moveCamera(coords, distance)
    local heading = GetEntityHeading(ped) + 94.0
    distance = distance or 1.0
    changingCam = true
    camDistance = distance
    angleZ = heading
    local x, y, z = getAngles()
    local newCam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA', coords.x + x, coords.y + y, coords.z + z, 0.0, 0.0, 0.0, 70.0, false, 0)
    targetCoords = coords
    changingCam = false
    oldCam = cam
    cam = newCam
    PointCamAtCoord(newCam, coords.x, coords.y, coords.z)
    if oldCam then
        SetCamActiveWithInterp(newCam, oldCam, 250, 0, 0)
        Wait(250)
        DestroyCam(oldCam, true)
    end
end

local function setCamera(section, distance)
    local bone = CameraBones[section]
    currentBone = section

    if bone == 0 then
        local coords = GetEntityCoords(ped)
        moveCamera(vector3(coords.x, coords.y, coords.z), distance or camDistance)
        return
    end

    distance = distance or camDistance
    if distance > DEFAULT_MAX_DISTANCE then
        distance = DEFAULT_MAX_DISTANCE
    end

    local x, y, z
    if type(bone) == 'table' then
        local c1 = GetPedBoneCoords(ped, bone[1], 0.0, 0.0, 0.0)
        local c2 = GetPedBoneCoords(ped, bone[2], 0.0, 0.0, 0.0)
        x = (c1.x + c2.x) / 2
        y = (c1.y + c2.y) / 2
        z = (c1.z + c2.z) / 2
    else
        local coords = GetPedBoneCoords(ped, bone, 0.0, 0.0, 0.0)
        x, y, z = coords.x, coords.y, coords.z
    end

    moveCamera(vector3(x, y, z), distance)
end

local function startCamera()
    if running then return end
    running = true
    camDistance = WHOLE_BODY_MAX_DISTANCE
    cam = CreateCam('DEFAULT_SCRIPTED_CAMERA', true)
    local coords = GetPedBoneCoords(ped, 31086, 0.0, 0.0, 0.0)
    SetCamCoord(cam, coords.x, coords.y, coords.z)
    RenderScriptCams(true, true, 1000, true, true)
    setCamera('whole', camDistance)
end

local function stopCamera()
    if not running then return end
    running = false
    RenderScriptCams(false, true, 250, true, false)
    if cam then
        DestroyCam(cam, true)
    end
    cam = nil
    targetCoords = nil
end

RegisterNUICallback('appearance:camMove', function(data, cb)
    setCamPosition(data.x, data.y)
    cb(1)
end)

RegisterNUICallback('appearance:camSection', function(section, cb)
    if section == 'whole' then
        setCamera('whole', WHOLE_BODY_MAX_DISTANCE)
    elseif section == 'head' then
        setCamera('head')
    elseif section == 'torso' then
        setCamera('torso')
    elseif section == 'legs' then
        setCamera('legs')
    elseif section == 'shoes' then
        setCamera('shoes')
        setCamPosition()
    end
    cb(1)
end)

RegisterNUICallback('appearance:camZoom', function(direction, cb)
    if direction == 'down' then
        local maxZoom = currentBone == 'whole' and WHOLE_BODY_MAX_DISTANCE or DEFAULT_MAX_DISTANCE
        camDistance = math.min(camDistance + 0.05, maxZoom)
    elseif direction == 'up' then
        camDistance = math.max(camDistance - 0.05, 0.3)
    end
    setCamPosition()
    cb(1)
end)

local head_default = {
    'Blemishes', 'FacialHair', 'Eyebrows', 'Ageing', 'Makeup', 'Blush',
    'Complexion', 'SunDamage', 'Lipstick', 'MolesFreckles', 'ChestHair',
    'BodyBlemishes', 'AddBodyBlemishes', 'EyeColor'
}

local face_default = {
    'Nose_Width', 'Nose_Peak_Height', 'Nose_Peak_Lenght', 'Nose_Bone_Height',
    'Nose_Peak_Lowering', 'Nose_Bone_Twist', 'EyeBrown_Height', 'EyeBrown_Forward',
    'Cheeks_Bone_High', 'Cheeks_Bone_Width', 'Cheeks_Width', 'Eyes_Openning',
    'Lips_Thickness', 'Jaw_Bone_Width', 'Jaw_Bone_Back_Lenght', 'Chin_Bone_Lowering',
    'Chin_Bone_Length', 'Chin_Bone_Width', 'Chin_Hole', 'Neck_Thikness'
}

local drawables_default = {
    'face', 'masks', 'hair', 'torsos', 'legs', 'bags', 'shoes', 'neck', 'shirts', 'vest', 'decals', 'jackets'
}

local props_default = {
    'hats', 'glasses', 'earrings', 'mouth', 'lhand', 'rhand', 'watches', 'bracelets'
}

local function ensureAppearanceState()
    currentAppearanceState = currentAppearanceState or {
        hairColor = { color = 0, highlight = 0 },
        headBlend = {
            shapeFirst = 0, shapeSecond = 0, shapeThird = 0,
            skinFirst = 0, skinSecond = 0, skinThird = 0,
            shapeMix = 0.0, skinMix = 0.0, thirdMix = 0.0, hasParent = false,
        },
        headStructure = {},
        headOverlay = {},
        drawables = {},
        props = {},
        tattoos = {},
        drawTotal = {},
        propTotal = {},
    }
    return currentAppearanceState
end

local sexModels = {
    Male = 'mp_m_freemode_01',
    Female = 'mp_f_freemode_01'
}

local function getSexModelOptions()
    return { 'Male', 'Female' }
end

local function resolveSexModel(model)
    if type(model) == 'string' and sexModels[model] then
        return GetHashKey(sexModels[model])
    end

    return type(model) == 'number' and model or GetHashKey(model)
end

local function findModelIndex(target)
    if target == GetHashKey(sexModels.Male) then
        return 0
    end
    if target == GetHashKey(sexModels.Female) then
        return 1
    end
    return -1
end

local function getHairColor(pedHandle)
    return {
        color = GetPedHairColor(pedHandle),
        highlight = GetPedHairHighlightColor(pedHandle)
    }
end
exports('GetPedHairColor', getHairColor)

local function getHeadBlendData(_)
    ensureAppearanceState()
    return cloneTable(currentAppearanceState.headBlend)
end
exports('GetPedHeadBlend', getHeadBlendData)

local function getHeadOverlay(pedHandle)
    local totals, headData = {}, {}
    for i, overlay in ipairs(head_default) do
        local index = i - 1
        totals[overlay] = GetNumHeadOverlayValues(index)
        if overlay == 'EyeColor' then
            headData[overlay] = {
                index = index,
                overlayValue = GetPedEyeColor(pedHandle)
            }
        else
            local _, overlayValue, colourType, firstColor, secondColor, overlayOpacity = GetPedHeadOverlayData(pedHandle, index)
            headData[overlay] = {
                index = index,
                overlayValue = overlayValue == 255 and -1 or overlayValue,
                colourType = colourType,
                firstColor = firstColor,
                secondColor = secondColor,
                overlayOpacity = overlayOpacity
            }
        end
    end
    return headData, totals
end
exports('GetPedHeadOverlay', getHeadOverlay)

local function getHeadStructure(pedHandle)
    local pedModel = GetEntityModel(pedHandle)
    if pedModel ~= GetHashKey('mp_m_freemode_01') and pedModel ~= GetHashKey('mp_f_freemode_01') then
        return nil
    end
    local faceStruct = {}
    for i, overlay in ipairs(face_default) do
        local index = i - 1
        faceStruct[overlay] = {
            id = overlay,
            index = index,
            value = GetPedFaceFeature(pedHandle, index)
        }
    end
    return faceStruct
end
exports('GetPedHeadStructure', getHeadStructure)

local function getDrawables(pedHandle)
    local drawables, totalDrawables = {}, {}
    for i, name in ipairs(drawables_default) do
        local index = i - 1
        local current = GetPedDrawableVariation(pedHandle, index)
        totalDrawables[name] = {
            id = name,
            index = index,
            total = GetNumberOfPedDrawableVariations(pedHandle, index),
            textures = GetNumberOfPedTextureVariations(pedHandle, index, current)
        }
        drawables[name] = {
            id = name,
            index = index,
            value = current,
            texture = GetPedTextureVariation(pedHandle, index)
        }
    end
    return drawables, totalDrawables
end
exports('GetPedDrawables', getDrawables)

local function getProps(pedHandle)
    local props, totalProps = {}, {}
    for i, name in ipairs(props_default) do
        local index = i - 1
        local current = GetPedPropIndex(pedHandle, index)
        totalProps[name] = {
            id = name,
            index = index,
            total = GetNumberOfPedPropDrawableVariations(pedHandle, index),
            textures = GetNumberOfPedPropTextureVariations(pedHandle, index, current)
        }
        props[name] = {
            id = name,
            index = index,
            value = current,
            texture = GetPedPropTextureIndex(pedHandle, index)
        }
    end
    return props, totalProps
end
exports('GetPedProps', getProps)

local function getTattoos()
    return triggerServerCallback('bl_appearance:server:getTattoos') or {}
end
exports('GetPlayerTattoos', getTattoos)

local function getAppearance(pedHandle)
    ensureAppearanceState()
    local headData, totals = getHeadOverlay(pedHandle)
    local drawables, drawTotal = getDrawables(pedHandle)
    local props, propTotal = getProps(pedHandle)
    local model = GetEntityModel(pedHandle)
    local tattoos = pedHandle == PlayerPedId() and (currentAppearanceState.tattoos or getTattoos()) or (currentAppearanceState.tattoos or {})

    currentAppearanceState.model = model
    currentAppearanceState.modelIndex = findModelIndex(model)
    currentAppearanceState.hairColor = getHairColor(pedHandle)
    currentAppearanceState.headOverlay = cloneTable(headData)
    currentAppearanceState.headOverlayTotal = cloneTable(totals)
    currentAppearanceState.headStructure = getHeadStructure(pedHandle) or currentAppearanceState.headStructure
    currentAppearanceState.drawables = cloneTable(drawables)
    currentAppearanceState.props = cloneTable(props)
    currentAppearanceState.drawTotal = cloneTable(drawTotal)
    currentAppearanceState.propTotal = cloneTable(propTotal)
    currentAppearanceState.tattoos = cloneTable(tattoos)

    return cloneTable(currentAppearanceState)
end
exports('GetPedAppearance', getAppearance)

local function normalizeAppearance(pedHandle, appearance)
    local baseline = getAppearance(pedHandle)
    if not appearance then
        return baseline
    end

    return mergeTables(baseline, appearance)
end

onServerCallback('bl_appearance:client:getAppearance', function()
    updatePed(PlayerPedId())
    return getAppearance(ped)
end)

local function getPedClothes(pedHandle)
    local headData = getHeadOverlay(pedHandle)
    return {
        headOverlay = headData,
        drawables = select(1, getDrawables(pedHandle)),
        props = select(1, getProps(pedHandle))
    }
end
exports('GetPedClothes', getPedClothes)

local function getPedSkin(pedHandle)
    local state = ensureAppearanceState()
    return {
        headBlend = cloneTable(state.headBlend),
        headStructure = getHeadStructure(pedHandle),
        hairColor = getHairColor(pedHandle),
        model = GetEntityModel(pedHandle)
    }
end
exports('GetPedSkin', getPedSkin)

local function getTattooData()
    local tattooZones = {}
    local tattooList, tattooCategories = exports.bl_appearance:tattoos()
    for i = 1, #tattooCategories do
        local category = tattooCategories[i]
        local entry = {
            zone = category.zone,
            label = category.label,
            zoneIndex = category.index,
            dlcs = {}
        }
        for j = 1, #tattooList do
            entry.dlcs[#entry.dlcs + 1] = {
                label = tattooList[j].dlc,
                dlcIndex = j - 1,
                tattoos = {}
            }
        end
        tattooZones[category.index + 1] = entry
    end

    local isFemale = GetEntityModel(ped) == GetHashKey('mp_f_freemode_01')
    for i = 1, #tattooList do
        local data = tattooList[i]
        local dlcHash = GetHashKey(data.dlc)
        for j = 1, #data.tattoos do
            local tattooData = data.tattoos[j]
            local lowerTattoo = string.lower(tattooData)
            local isFemaleTattoo = string.find(lowerTattoo, '_f', 1, true) ~= nil
            local tattoo = nil
            if isFemaleTattoo and isFemale then
                tattoo = tattooData
            elseif not isFemaleTattoo and not isFemale then
                tattoo = tattooData
            end
            if tattoo then
                local hash = GetHashKey(tattoo)
                local zone = GetPedDecorationZoneFromHashes(dlcHash, hash)
                if zone ~= -1 and tattooZones[zone + 1] and tattooZones[zone + 1].dlcs[i] then
                    table.insert(tattooZones[zone + 1].dlcs[i].tattoos, {
                        label = tattoo,
                        hash = hash,
                        zone = zone,
                        dlc = data.dlc
                    })
                end
            end
        end
    end

    return tattooZones
end

onServerCallback('bl_appearance:client:migration:setAppearance', function(data)
    if data.type == 'fivem' then
        exports['fivem-appearance']:setPlayerAppearance(data.data)
    elseif data.type == 'illenium' then
        exports['illenium-appearance']:setPlayerAppearance(data.data)
    end

    currentAppearanceState = cloneTable(data.data)
end)

local toggles_default = {
    hats = { type = 'prop', index = 0 },
    glasses = { type = 'prop', index = 1 },
    masks = { type = 'drawable', index = 1, off = 0 },
    shirts = {
        type = 'drawable', index = 8, off = 15,
        hook = { drawables = {
            { component = 3, variant = 15, texture = 0, id = 'torsos' },
            { component = 8, variant = 15, texture = 0, id = 'shirts' },
        } }
    },
    jackets = {
        type = 'drawable', index = 11, off = 15,
        hook = { drawables = {
            { component = 3, variant = 15, texture = 0, id = 'torsos' },
            { component = 11, variant = 15, texture = 0, id = 'jackets' },
        } }
    },
    vest = { type = 'drawable', index = 9, off = 0 },
    legs = { type = 'drawable', index = 4, off = 18 },
    shoes = { type = 'drawable', index = 6, off = 34 },
}

local function setDrawable(pedHandle, data)
    if not data then return end
    SetPedComponentVariation(pedHandle, data.index, data.value, data.texture, 0)
    ensureAppearanceState().drawables[data.id or drawables_default[data.index + 1]] = cloneTable(data)
    return GetNumberOfPedTextureVariations(pedHandle, data.index, data.value)
end
exports('SetPedDrawable', setDrawable)

local function setProp(pedHandle, data)
    if not data then return end
    if data.value == -1 then
        ClearPedProp(pedHandle, data.index)
    else
        SetPedPropIndex(pedHandle, data.index, data.value, data.texture, false)
    end
    ensureAppearanceState().props[data.id or props_default[data.index + 1]] = cloneTable(data)
    if data.value == -1 then return nil end
    return GetNumberOfPedPropTextureVariations(pedHandle, data.index, data.value)
end
exports('SetPedProp', setProp)

local defMaleHash = GetHashKey('mp_m_freemode_01')
local function setHeadBlend(pedHandle, data)
    if not data then return end
    pedHandle = pedHandle or ped
    local model = GetEntityModel(pedHandle)
    if model ~= GetHashKey('mp_m_freemode_01') and model ~= GetHashKey('mp_f_freemode_01') then
        return
    end

    ensureAppearanceState().headBlend = cloneTable(data)
    SetPedHeadBlendData(
        pedHandle,
        math.max(data.shapeFirst or 0, 0), math.max(data.shapeSecond or 0, 0), math.max(data.shapeThird or 0, 0),
        math.max(data.skinFirst or 0, 0), math.max(data.skinSecond or 0, 0), math.max(data.skinThird or 0, 0),
        (data.shapeMix or 0.0) + 0.0, (data.skinMix or 0.0) + 0.0, (data.thirdMix or 0.0) + 0.0,
        data.hasParent or false
    )
end
exports('SetPedHeadBlend', setHeadBlend)

local function restoreESXPlayerStateAfterModelChange(pedHandle)
    if GetResourceState('es_extended') ~= 'started' or not ESX or not ESX.PlayerLoaded then return end

    ESX.SetPlayerData('ped', pedHandle)
    TriggerEvent('esx:onPlayerModelChanged')
end

local function setModel(pedHandle, data)
    if data == nil then return pedHandle end
    local model
    if type(data) == 'string' then
        model = resolveSexModel(data)
    elseif type(data) == 'number' then
        model = data
    elseif type(data) == 'table' then
        model = data.model or defMaleHash
    else
        model = defMaleHash
    end
    if model == 0 then return pedHandle end

    requestModel(model)
    local isPlayer = IsPedAPlayer(pedHandle)
    if isPlayer then
        SetPlayerModel(PlayerId(), model)
        Wait(0)
        pedHandle = PlayerPedId()
        updatePed(pedHandle)
        restoreESXPlayerStateAfterModelChange(pedHandle)
    end

    SetModelAsNoLongerNeeded(model)
    SetPedDefaultComponentVariation(pedHandle)
    ensureAppearanceState().model = model
    ensureAppearanceState().modelIndex = findModelIndex(model)

    local isJustModel = type(data) == 'string' or type(data) == 'number'
    if not isJustModel and data.headBlend and next(data.headBlend) then
        setHeadBlend(pedHandle, data.headBlend)
    elseif model == GetHashKey('mp_m_freemode_01') then
        SetPedHeadBlendData(pedHandle, 0, 0, 0, 0, 0, 0, 0.0, 0.0, 0.0, false)
    elseif model == GetHashKey('mp_f_freemode_01') then
        SetPedHeadBlendData(pedHandle, 45, 21, 0, 20, 15, 0, 0.3, 0.1, 0.0, false)
    end

    return pedHandle
end
exports('SetPedModel', setModel)

local function setFaceFeature(pedHandle, data)
    if not data then return end
    SetPedFaceFeature(pedHandle, data.index, data.value + 0.0)
    ensureAppearanceState().headStructure[data.id or face_default[data.index + 1]] = cloneTable(data)
end
exports('SetPedFaceFeature', setFaceFeature)

local function setFaceFeatures(pedHandle, data)
    if not data then return end
    for _, value in pairs(data) do
        setFaceFeature(pedHandle, value)
    end
end
exports('SetPedFaceFeatures', setFaceFeatures)

local function setHeadOverlay(pedHandle, data)
    if not data then return end
    local index = data.index
    local value = data.value or data.overlayValue
    if index == 13 then
        SetPedEyeColor(pedHandle, value)
        return
    end
    if data.id == 'hairColor' then
        SetPedHairTint(pedHandle, data.hairColor, data.hairHighlight)
        return
    end
    SetPedHeadOverlay(pedHandle, index, value, (data.overlayOpacity or 0.0) + 0.0)
    SetPedHeadOverlayColor(pedHandle, index, 1, data.firstColor or 0, data.secondColor or 0)
    ensureAppearanceState().headOverlay[data.id or head_default[index + 1]] = cloneTable(data)
end
exports('SetPedHeadOverlay', setHeadOverlay)

local function resetToggles(data)
    local drawables = data.drawables or {}
    local props = data.props or {}
    for toggleItem, toggleData in pairs(toggles_default) do
        local index = toggleData.index
        if toggleData.type == 'drawable' and drawables[toggleItem] then
            local currentDrawable = GetPedDrawableVariation(ped, index)
            if currentDrawable ~= drawables[toggleItem].value then
                SetPedComponentVariation(ped, index, drawables[toggleItem].value, 0, 0)
            end
        elseif toggleData.type == 'prop' and props[toggleItem] then
            local currentProp = GetPedPropIndex(ped, index)
            if currentProp ~= props[toggleItem].value then
                SetPedPropIndex(ped, index, props[toggleItem].value, 0, false)
            end
        end
    end
end

local function setPedClothes(pedHandle, data)
    if not data then return end
    if data.drawables then
        for _, drawable in pairs(data.drawables) do
            setDrawable(pedHandle, drawable)
        end
    end
    if data.props then
        for _, prop in pairs(data.props) do
            setProp(pedHandle, prop)
        end
    end
    if data.headOverlay then
        for id, overlay in pairs(data.headOverlay) do
            local payload = cloneTable(overlay)
            payload.id = id
            setHeadOverlay(pedHandle, payload)
        end
    end
end
exports('SetPedClothes', setPedClothes)

local function setPedSkin(pedHandle, data)
    if not data or not pedHandle then return end
    pedHandle = setModel(pedHandle, data)
    if data.headBlend then setHeadBlend(pedHandle, data.headBlend) end
    if data.headStructure then setFaceFeatures(pedHandle, data.headStructure) end
end
exports('SetPedSkin', setPedSkin)

local function setPedTattoos(pedHandle, data)
    if not data then return end
    currentAppearanceState = ensureAppearanceState()
    currentAppearanceState.tattoos = cloneTable(data)
    ClearPedDecorationsLeaveScars(pedHandle)
    for i = 1, #data do
        local tattooData = data[i].tattoo
        if tattooData then
            local collection = GetHashKey(tattooData.dlc)
            local tattoo = tattooData.hash
            local tattooOpacity = math.floor(((tattooData.opacity or 0.1) * 10) + 0.5)
            for _ = 1, tattooOpacity do
                AddPedDecorationFromHashes(pedHandle, collection, tattoo)
            end
        end
    end
end
exports('SetPedTattoos', setPedTattoos)

local function setPedHairColors(pedHandle, data)
    if not data then return end
    SetPedHairColor(pedHandle, data.color, data.highlight)
    ensureAppearanceState().hairColor = cloneTable(data)
end
exports('SetPedHairColors', setPedHairColors)

local function setPlayerPedAppearance(data)
    if not data then return end
    updatePed(PlayerPedId())
    currentAppearanceState = cloneTable(data)
    setPedSkin(ped, data)
    updatePed(PlayerPedId())
    setPedClothes(ped, data)
    if data.hairColor then setPedHairColors(ped, data.hairColor) end
    if data.tattoos then setPedTattoos(ped, data.tattoos) end
end

local function setPedAppearance(pedHandle, data)
    if not data then return end
    if IsPedAPlayer(pedHandle) then
        setPlayerPedAppearance(data)
        return
    end
    currentAppearanceState = cloneTable(data)
    setPedSkin(pedHandle, data)
    setPedClothes(pedHandle, data)
    if data.hairColor then setPedHairColors(pedHandle, data.hairColor) end
    if data.tattoos then setPedTattoos(pedHandle, data.tattoos) end
end
exports('SetPedAppearance', setPedAppearance)

local function closeMenu()
    SetPedArmour(ped, armour)
    stopCamera()
    SetNuiFocus(false, false)
    sendNUIEvent('appearance:visible', false)
    exports.bl_appearance:hideHud(false)
    open = false
    if creationActive then
        TriggerServerEvent('bl_appearance:server:resetroutingbucket')
        creationActive = false
    end
end

RegisterNUICallback('appearance:cancel', function(appearance, cb)
    setPlayerPedAppearance(appearance)
    closeMenu()
    cb(1)
end)

RegisterNUICallback('appearance:save', function(appearance, cb)
    resetToggles(appearance)
    delay(100)
    local newAppearance = getAppearance(ped)
    newAppearance.tattoos = appearance.tattoos or {}
    triggerServerCallback('bl_appearance:server:saveAppearance', getFrameworkID(), newAppearance)
    setPedTattoos(ped, newAppearance.tattoos)
    closeMenu()
    cb(1)
end)

RegisterNUICallback('appearance:setModel', function(model, cb)
    local hash = resolveSexModel(model)
    if not IsModelInCdimage(hash) or not IsModelValid(hash) then
        cb(0)
        return
    end
    local newPed = setModel(ped, hash)
    updatePed(newPed)
    local appearance = getAppearance(ped)
    appearance.tattoos = {}
    setPedTattoos(ped, {})
    cb(appearance)
end)

RegisterNUICallback('appearance:getModelTattoos', function(_, cb)
    cb(getTattooData())
end)

RegisterNUICallback('appearance:setHeadStructure', function(data, cb)
    setFaceFeature(ped, data)
    cb(1)
end)

RegisterNUICallback('appearance:setHeadOverlay', function(data, cb)
    setHeadOverlay(ped, data)
    cb(1)
end)

RegisterNUICallback('appearance:setHeadBlend', function(data, cb)
    setHeadBlend(ped, data)
    cb(1)
end)

RegisterNUICallback('appearance:setTattoos', function(data, cb)
    setPedTattoos(ped, data)
    cb(1)
end)

RegisterNUICallback('appearance:setProp', function(data, cb)
    cb(setProp(ped, data))
end)

RegisterNUICallback('appearance:setDrawable', function(data, cb)
    cb(setDrawable(ped, data))
end)

RegisterNUICallback('appearance:toggleItem', function(data, cb)
    local item = toggles_default[data.item]
    if not item or not data.data then
        cb(false)
        return
    end

    local current = data.data
    if item.type == 'prop' then
        local currentProp = GetPedPropIndex(ped, item.index)
        if currentProp == -1 then
            setProp(ped, current)
            cb(false)
        else
            ClearPedProp(ped, item.index)
            cb(true)
        end
        return
    end

    local currentDrawable = GetPedDrawableVariation(ped, item.index)
    if current.value == item.off then
        cb(false)
        return
    end

    if current.value == currentDrawable then
        SetPedComponentVariation(ped, item.index, item.off, 0, 0)
        if item.hook and item.hook.drawables then
            for i = 1, #item.hook.drawables do
                local hookItem = item.hook.drawables[i]
                SetPedComponentVariation(ped, hookItem.component, hookItem.variant, hookItem.texture, 0)
            end
        end
        cb(true)
    else
        setDrawable(ped, current)
        if data.hookData then
            for i = 1, #data.hookData do
                setDrawable(ped, data.hookData[i])
            end
        end
        cb(false)
    end
end)

RegisterNUICallback('appearance:saveOutfit', function(data, cb)
    cb(triggerServerCallback('bl_appearance:server:saveOutfit', data))
end)
RegisterNUICallback('appearance:deleteOutfit', function(data, cb)
    cb(triggerServerCallback('bl_appearance:server:deleteOutfit', data.id))
end)
RegisterNUICallback('appearance:renameOutfit', function(data, cb)
    cb(triggerServerCallback('bl_appearance:server:renameOutfit', data))
end)
RegisterNUICallback('appearance:useOutfit', function(outfit, cb)
    setPedClothes(ped, outfit)
    cb(1)
end)
RegisterNUICallback('appearance:importOutfit', function(data, cb)
    cb(triggerServerCallback('bl_appearance:server:importOutfit', getFrameworkID(), data.id, data.outfitName))
end)
RegisterNUICallback('appearance:fetchOutfit', function(data, cb)
    cb(triggerServerCallback('bl_appearance:server:fetchOutfit', data.id))
end)
RegisterNUICallback('appearance:itemOutfit', function(data, cb)
    cb(triggerServerCallback('bl_appearance:server:itemOutfit', data))
end)

local animDict = 'missmic4'
local anim = 'michael_tux_fidget'
local function playOutfitEmote()
    while not HasAnimDictLoaded(animDict) do
        RequestAnimDict(animDict)
        Wait(100)
    end
    TaskPlayAnim(ped, animDict, anim, 3.0, 3.0, 1200, 51, 0.0, false, false, false)
end

RegisterNetEvent('bl_appearance:client:useOutfitItem', function(outfit)
    playOutfitEmote()
    setPedClothes(ped, outfit)
    triggerServerCallback('bl_appearance:server:saveClothes', getFrameworkID(), outfit)
end)

local function getAllowlist(models)
    local allowList = exports.bl_appearance:blacklist().allowList
    local allowlistModels = allowList.characters[getFrameworkID()]
    if not allowlistModels then return models end
    for i = 1, #models do
        if not hasValue(allowlistModels, models[i]) then
            table.insert(allowlistModels, models[i])
        end
    end
    return allowlistModels
end

local function getBlacklist(zone)
    local blacklistData = exports.bl_appearance:blacklist()
    local groupTypes = blacklistData.groupTypes
    local base = blacklistData.base
    if type(zone) == 'string' or not groupTypes then
        return base
    end

    local blacklist = cloneTable(base)
    local playerData = getPlayerData()
    for groupType, groups in pairs(groupTypes) do
        for _, groupBlacklist in pairs(groups) do
            local skip = false
            if groupType == 'jobs' and zone.jobs then
                skip = hasValue(zone.jobs, playerData.job and playerData.job.name)
            elseif groupType == 'gangs' and zone.gangs then
                skip = hasValue(zone.gangs, playerData.gang and playerData.gang.name)
            end
            if not skip then
                for key, value in pairs(groupBlacklist) do
                    if key == 'drawables' then
                        blacklist.drawables = blacklist.drawables or {}
                        for drawableKey, drawableValue in pairs(value) do
                            blacklist.drawables[drawableKey] = drawableValue
                        end
                    else
                        blacklist[key] = value
                    end
                end
            end
        end
    end
    return blacklist
end

local function openMenu(zone, creation)
    creation = creation or false
    if zone == nil or open then return end

    local pedHandle = PlayerPedId()
    local configMenus = exports.bl_appearance:menus()
    local zoneType = type(zone) == 'string' and zone or zone.type
    local menu = configMenus[zoneType]
    if not menu then return end

    updatePed(pedHandle)
    local frameworkID = getFrameworkID()
    local tabs = menu.tabs
    local allowExit = creation and false or menu.allowExit
    armour = GetPedArmour(pedHandle)
    local outfits = hasValue(tabs, 'outfits') and triggerServerCallback('bl_appearance:server:getOutfits', frameworkID) or nil
    local models = hasValue(tabs, 'heritage') and getSexModelOptions() or nil
    local tattoos = hasValue(tabs, 'tattoos') and getTattooData() or nil
    local blacklist = getBlacklist(zone)

    if creation then
        local model = GetHashKey(getPlayerGenderModel())
        pedHandle = setModel(pedHandle, model)
        TriggerServerEvent('bl_appearance:server:setroutingbucket')
        creationActive = true
        updatePed(pedHandle)
    end

    local appearance = nil
    if not creation and frameworkID then
        appearance = triggerServerCallback('bl_appearance:server:getAppearance', frameworkID)
    end

    appearance = normalizeAppearance(pedHandle, appearance)
    currentAppearanceState = cloneTable(appearance)

    startCamera()
    sendNUIEvent('appearance:data', {
        tabs = tabs,
        appearance = appearance,
        blacklist = blacklist,
        tattoos = tattoos,
        outfits = outfits,
        models = models,
        allowExit = allowExit,
        job = getJobInfo(),
        locale = requestLocale()
    })
    SetNuiFocus(true, true)
    sendNUIEvent('appearance:visible', true)
    open = true
    exports.bl_appearance:hideHud(true)
    return true
end
exports('OpenMenu', openMenu)

local function QBBridge()
    RegisterNetEvent('qb-clothing:client:loadPlayerClothing', function(appearance, pedHandle)
        setPedAppearance(pedHandle, appearance)
    end)
    RegisterNetEvent('qb-clothes:client:CreateFirstCharacter', function()
        exports.bl_appearance:InitialCreation()
    end)
    RegisterNetEvent('qb-clothing:client:openOutfitMenu', function()
        openMenu({ type = 'outfits', coords = vector4(0, 0, 0, 0) })
    end)
end

local function ESXBridge()
    local firstSpawn = false
    AddEventHandler('esx_skin:resetFirstSpawn', function()
        firstSpawn = true
    end)
    AddEventHandler('esx_skin:playerRegistered', function()
        if firstSpawn then
            exports.bl_appearance:InitialCreation()
        end
    end)
    RegisterNetEvent('skinchanger:loadSkin2', function(appearance, pedHandle)
        if not appearance.model then
            appearance.model = GetHashKey('mp_m_freemode_01')
        end
        setPedAppearance(pedHandle, appearance)
    end)
    RegisterNetEvent('skinchanger:getSkin', function(cb)
        cb(triggerServerCallback('bl_appearance:server:getAppearance', getFrameworkID()))
    end)
    RegisterNetEvent('skinchanger:loadSkin', function(appearance, cb)
        setPlayerPedAppearance(appearance)
        if cb then cb() end
    end)
    RegisterNetEvent('esx_skin:openSaveableMenu', function(onSubmit)
        exports.bl_appearance:InitialCreation(onSubmit)
    end)
end

local function exportHandler(name, cb)
    AddEventHandler(('__cfx_export_illenium-appearance_%s'):format(name), function(setCB)
        setCB(cb)
    end)
end

local function illeniumCompat()
    exportHandler('startPlayerCustomization', function()
        exports.bl_appearance:InitialCreation()
    end)
    exportHandler('getPedModel', function(pedHandle)
        return GetEntityModel(pedHandle)
    end)
    exportHandler('getPedAppearance', function(pedHandle)
        return getAppearance(pedHandle)
    end)
    exportHandler('setPlayerModel', function(model)
        updatePed(PlayerPedId())
        setModel(ped, model)
    end)
    exportHandler('setPedHeadBlend', function(pedHandle, blend)
        setHeadBlend(pedHandle, blend)
    end)
    exportHandler('setPedAppearance', function(pedHandle, appearance)
        setPedAppearance(pedHandle, appearance)
    end)
    exportHandler('setPedTattoos', function(pedHandle, tattoos)
        setPedTattoos(pedHandle, tattoos)
    end)
end

exports('SetPlayerPedAppearance', function(appearance)
    local resolvedAppearance = appearance
    if not appearance or type(appearance) == 'string' then
        resolvedAppearance = triggerServerCallback('bl_appearance:server:getAppearance', appearance or getFrameworkID())
    end
    if not resolvedAppearance then
        error('No valid appearance found')
    end
    setPlayerPedAppearance(resolvedAppearance)
end)

exports('GetPlayerPedAppearance', function(frameworkID)
    frameworkID = frameworkID or getFrameworkID()
    return triggerServerCallback('bl_appearance:server:getAppearance', frameworkID)
end)

exports('InitialCreation', function(cb)
    openMenu({ type = 'appearance', coords = vector4(0, 0, 0, 0) }, true)
    if cb then cb() end
end)

AddEventHandler('bl_appearance:client:useZone', function(zone)
    openMenu(zone)
end)
RegisterNetEvent('bl_appearance:client:open', function(zone)
    openMenu(zone)
end)

local function loadCurrentPlayerAppearance()
    local frameworkID = getFrameworkID()
    if not frameworkID then return end
    local appearance = triggerServerCallback('bl_appearance:server:getAppearance', frameworkID)
    if not appearance then return end
    setPlayerPedAppearance(appearance)
end

RegisterNetEvent('esx:playerLoaded', function(playerData)
    syncESXPlayerData(playerData)
    loadCurrentPlayerAppearance()
end)
RegisterNetEvent('esx:setJob', function(job)
    syncESXPlayerData({ job = job })
end)
AddEventHandler('onResourceStart', function(resource)
    if resource == GetCurrentResourceName() then
        Wait(500)
        loadCurrentPlayerAppearance()
    end
end)

local framework = GetConvar('bl:framework', 'esx'):gsub("'", '')
if (framework == 'qb' or framework == 'qbx') and GetResourceState('qb-core') == 'started' then
    QBBridge()
elseif framework == 'esx' and GetResourceState('es_extended') == 'started' then
    ESXBridge()
end
illeniumCompat()

local function reloadSkin()
    local frameworkID = getFrameworkID()
    local playerPed = PlayerPedId()
    local maxhealth = GetEntityMaxHealth(playerPed)
    local health = GetEntityHealth(playerPed)
    local armor = GetPedArmour(playerPed)
    local appearance = triggerServerCallback('bl_appearance:server:getAppearance', frameworkID)
    if not appearance then return end
    setPlayerPedAppearance(appearance)
    SetPedMaxHealth(playerPed, maxhealth)
    Wait(1000)
    SetEntityHealth(playerPed, health)
    SetPedArmour(playerPed, armor)
end

RegisterNetEvent('bl_appearance:client:reloadSkin', reloadSkin)
RegisterCommand('reloadskin', reloadSkin, false)
