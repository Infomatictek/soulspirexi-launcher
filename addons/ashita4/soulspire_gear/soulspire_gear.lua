--[[
* SoulspireXI Gear Manager (soulspire_gear) for Ashita v4
*
* Standalone, clean-room automatic equipment set builder, packet-driven action
* swapper, and ImGui loadout manager built from the ground up for SoulspireXI.
*
* Features:
*   - Automatic cap-aware scoring (25% Gear Haste, -50% PDT/MDT, 80% Fast Cast,
*     set bonuses, latents, and augments) from Inventory & Wardrobes 1..8
*   - Native SoulspireXI Soul Crystal Spec & 4-Tier Weaponskill Talent integration
*   - Built-in 0x050/0x051 packet swapper for Idle, Engaged, Resting, Precast,
*     Midcast, Weaponskills, Job Abilities, Ranged Attacks, and Lockstyle (0x053)
*   - Interactive 5-tab ImGui UI (/og or /ogear) with manual slot overrides,
*     custom sets, Weapon Advisor, and Storage Bag Upgrade Finder
*
* Commands:
*   /og              - Toggle SoulspireXI Gear Manager window
*   /ogear           - Alias for /og
*   /og build        - Rebuild all sets now
*   /og dt           - Cycle Damage Taken mode (Off / All / PDT / MDT)
*   /og tp           - Cycle Engaged TP mode (Default / Hybrid / Acc / Tank)
*   /og idle         - Cycle Idle mode (Auto / Normal / DT / Regen / Refresh)
*   /og burst        - Toggle Magic Burst overlay
*   /og kite         - Toggle Movement Speed / Kite overlay
*   /og th           - Toggle Treasure Hunter overlay
*   /og wear <set>   - Hold a specific set (or /og wear off)
*   /og dress        - Pause swapping to manually equip gear, then /og save <name>
*   /og look <set>   - Lock visual appearance (Lockstyle) to <set>
*   /og upgrades     - Scan Mog Safe, Storage, Locker, Satchel, Sack & Case
--]]

addon.name    = 'soulspire_gear'
addon.author  = 'SoulspireXI'
addon.version = '1.0.0'
addon.desc    = 'Standalone automatic gear builder & swapper tailored for SoulspireXI.'
addon.link    = 'https://github.com/Infomatictek/soulspirexi-launcher'

require('common')
local chat = require('chat')

local okJit, jit = pcall(require, 'jit')
if okJit and jit and jit.off then
    jit.off()
end

if (((ashita.interface_version ~= nil and ashita.interface_version >= 4.3)
    or (ashita.addons_version ~= nil and ashita.addons_version >= 4.1))
    and addon.instance and addon_feature) then
    pcall(function()
        addon.instance:enable_feature(addon_feature.use_packet_chunks)
    end)
end

local state   = require('og.state')
local swapper = require('og.swapper')
local ox_sync = require('og.ox_sync')
local ui      = require('og.ui')

local reportedErrors = {}
local function guard(part, fn, ...)
    local ok, err = xpcall(fn, debug.traceback, ...)
    if ok then
        return true
    end
    err = tostring(err)
    local firstLine = err:match('^[^\n]*') or err
    if not reportedErrors[firstLine] then
        reportedErrors[firstLine] = true
        print(chat.header('soulspire_gear') .. chat.error(part .. ': ' .. firstLine))
    end
    return false
end

ashita.events.register('load', 'soulspire_gear_load_cb', function()
    guard('load prefs', state.LoadPrefs)
    guard('initial build', function()
        -- If loaded while already logged in and standing in a zone, allow immediate build after brief delay
        local party = AshitaCore:GetMemoryManager():GetParty()
        if party and (party:GetMemberServerId(0) or 0) > 0 then
            swapper.Zone.Holding = false
            state.StartRebuild(true)
        end
    end)
end)

ashita.events.register('unload', 'soulspire_gear_unload_cb', function()
    guard('save prefs', state.SavePrefs)
    guard('save profile', state.SaveJobProfile)
end)

ashita.events.register('d3d_present', 'soulspire_gear_render_cb', function()
    guard('state tick', state.Tick)
    guard('ui render', ui.Render)
end)

ashita.events.register('packet_in', 'soulspire_gear_packet_in_cb', function(e)
    guard('packet_in', function()
        swapper.HandlePacketIn(e, state)
        if ox_sync.HandlePacketIn(e) then
            state.StartRebuild(false)
        end
    end)
end)

ashita.events.register('packet_out', 'soulspire_gear_packet_out_cb', function(e)
    guard('packet_out', function()
        swapper.HandlePacketOut(e, state)
    end)
end)

ashita.events.register('text_in', 'soulspire_gear_text_in_cb', function(e)
    guard('text_in', function()
        if ox_sync.HandleTextIn(e) then
            state.StartRebuild(false)
        end
    end)
end)

ashita.events.register('command', 'soulspire_gear_command_cb', function(e)
    guard('command', function()
        state.HandleCommand(e, ui)
    end)
end)
