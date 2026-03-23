Config = {
    locale = 'th',
    openControl = 'E',
    previousClothing = 'esx', -- 'illenium' | 'qb' | 'esx' | 'fivem-appearance'
    textUi = true, -- if true, uses textUI | if false, uses sprite
    outfitItem = false, -- Disabled by default for direct ESX usage unless you wire an inventory metadata handler
}

exports('config', function()
    return Config
end)

---@param state boolean If true, hides the HUD. If false, shows the HUD.
exports('hideHud', function(state)
    -- Implement your code here
    local qbhud = GetResourceState('qb-hud') == 'started'
    if qbhud then
        -- qb hud is trash and doesnt have a hide function
        DisplayRadar(state)
    end
end)
