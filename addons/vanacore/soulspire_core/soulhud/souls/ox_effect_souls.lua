-- SoulspireXI custom-effect Souls: spartan, dreadnought, wyvernheart, buccaneer, magus, azurebastion.
-- Keys match the server HUD providers in modules/custom/lua/soulspire_soul_hud.lua.
local function timer(id, label, short, remKey, color, powKey)
    return {
        id = id, label = label, shortLabel = short, type = 'timer', style = 'pill',
        timerKey = remKey, activeKey = remKey, color = color, compact = true,
        format = function(st)
            if (st.remaining or 0) > 0 then return string.format('%ds', math.ceil(st.remaining)) end
            return 'Idle'
        end,
    }
end

local function stacks(id, label, short, key, max, color)
    return {
        id = id, label = label, shortLabel = short, type = 'stack', style = 'segmented',
        min = 0, max = max, serverKey = key, color = color, compact = true,
    }
end

return function(registry)
    registry.registerSoul({
        key = 'spartan', name = 'Spartan', jobAbr = 'WAR', accentColor = 0xFF3D8CE0,
        resources = { timer('phalanx_ward', 'Phalanx Ward', 'Ward', 'ward_rem', 0xFF3D8CE0) },
    })
    registry.registerSoul({
        key = 'dreadnought', name = 'Dreadnought', jobAbr = 'DRK', accentColor = 0xFF8A3DB0,
        resources = {
            timer('blood_carapace', 'Blood Carapace', 'Carapace', 'carapace_rem', 0xFF5A38C0),
            timer('dread_bastion', 'Dread Bastion', 'Bastion', 'bastion_rem', 0xFFB06AA0),
        },
    })
    registry.registerSoul({
        key = 'wyvernheart', name = 'Wyvernheart', jobAbr = 'DRG', accentColor = 0xFFE09A60,
        resources = {
            timer('dragonscale', 'Dragonscale', 'Scale', 'scale_rem', 0xFFE09A60),
            timer('dragonscale_sanctuary', 'Dragonscale Sanctuary', 'Sanct', 'sanct_rem', 0xFFE0C080),
        },
    })
    registry.registerSoul({
        key = 'buccaneer', name = 'Buccaneer', jobAbr = 'COR', accentColor = 0xFF40B0E0,
        resources = {
            timer('house_advantage', 'House Advantage', 'Advantage', 'adv_rem', 0xFF40B0E0),
            timer('card_counting', 'Card Counting', 'Cards', 'cc_rem', 0xFF9ADB5E),
            timer('house_debt', 'House Debt', 'Debt', 'debt_rem', 0xFF4455EE),
        },
    })
    registry.registerSoul({
        key = 'magus', name = 'Magus', jobAbr = 'BLU', accentColor = 0xFFE0B040,
        resources = {
            stacks('azure_catalyst', 'Azure Catalyst', 'Catalyst', 'catalyst_stacks', 5, 0xFFE0B040),
            timer('osmotic_conduit', 'Osmotic Conduit', 'Conduit', 'conduit_rem', 0xFFE0D080),
        },
    })
    registry.registerSoul({
        key = 'azurebastion', name = 'Azure Bastion', jobAbr = 'BLU', accentColor = 0xFFE09040,
        resources = {
            stacks('chitin_carapace', 'Chitin Carapace', 'Chitin', 'chitin_stacks', 5, 0xFFE09040),
            timer('azure_surge', 'Azure Surge', 'Surge', 'surge_rem', 0xFFF0C060),
            timer('diamond_shell', 'Diamond Shell', 'Shell', 'shell_rem', 0xFFF0E0A0),
        },
    })
end
