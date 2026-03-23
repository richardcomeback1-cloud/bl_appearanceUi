local ESX = exports.es_extended:getSharedObject()

local function isAdmin(source)
    if source == 0 then return true end

    local xPlayer = ESX.GetPlayerFromId(source)
    if not xPlayer then return false end

    local group = xPlayer.group
    if xPlayer.getGroup then
        group = xPlayer.getGroup()
    end

    return group == 'admin' or group == 'superadmin'
end

local function openAppearanceMenu(target, type)
    TriggerClientEvent('bl_appearance:client:open', target, type or 'appearance')
end

lib.addCommand('appearance', {
    help = 'Open the appearance menu',
    params = {
        {
            name = 'target',
            type = 'playerId',
            help = "Target player's server id",
        },
        {
            name = 'type',
            type = 'string',
            help = 'appearance | outfits | tattoos | clothes | accessories | face | makeup | heritage',
            optional = true
        }
    },
    restricted = 'group.admin'
}, function(source, args, raw)
    local target = args.target or source
    local type = args.type or 'appearance'
    openAppearanceMenu(target, type)
end)

lib.addCommand('skin', {
    help = 'Open the full skin menu for yourself or a target player',
    params = {
        {
            name = 'target',
            type = 'playerId',
            help = "Target player's server id",
            optional = true,
        }
    },
}, function(source, args, raw)
    local target = args.target or source
    if target ~= source and not isAdmin(source) then
        target = source
    end

    openAppearanceMenu(target, 'appearance')
end)
