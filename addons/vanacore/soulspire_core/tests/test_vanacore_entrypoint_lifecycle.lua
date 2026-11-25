-- Full-entrypoint VanaCore lifecycle regression test for addons/vanacore/soulspire_core/soulspire_core.lua.
-- Validates against VanaCore's real kEvents[] set (src/core/addons.cpp:111) so invalid events like 'frame' fail immediately.

local VALID_VANACORE_EVENTS = {
    load = true, unload = true, command = true, present = true, mouse = true,
    key = true, packet_in = true, packet_out = true, text_in = true, text_out = true,
    xinput_button = true, dinput_button = true, xinput_state = true, dinput_state = true,
    key_state = true, key_data = true, plugin_event = true, unhandled = true, ipc = true,
    d3d_dp = true, d3d_dpup = true, d3d_dip = true, d3d_dipup = true,
    beginscene = true, endscene = true, gameui_button = true, gameui_replaced = true,
    gameui_trigger = true, gameui_window = true,
}

local handlers = {}
local logs = {}
local injected_packets = {}
local imgui_windows = {}
local pending_open_core = 0
local gamepad_nav_calls = 0

_G.addon = { path = 'addons/vanacore/soulspire_core' }
_G.vana = {
    log = function(msg) logs[#logs + 1] = tostring(msg) end,
    events = {
        on = function(ev, fn)
            assert(VALID_VANACORE_EVENTS[ev], 'INVALID VanaCore event name subscribed: ' .. tostring(ev))
            handlers[ev] = handlers[ev] or {}
            handlers[ev][#handlers[ev] + 1] = fn
        end,
    },
    gamepad = {
        nav = function(on) if on then gamepad_nav_calls = gamepad_nav_calls + 1 end end,
    },
    packets = {
        inject = function(incoming, id, raw)
            injected_packets[#injected_packets + 1] = { incoming = incoming, id = id, raw = raw }
        end,
    },
    soulspire = {
        enabled = function() return true end,
        capabilities = function() return 0x91FFF end, -- includes kCapCommandsMenuEntry (0x10000)
        identity = function()
            return { known = true, job = 13, branch = 1, effective_level = 75, soul_key = 'shinobi', full_name = 'Shinobi', short_name = 'SHN', source = 'packet_1ff' }
        end,
        hud = function()
            return { soul_key = 'shinobi', packet_count = 3, kv = { sh = '2', shmax = '5', feint = '1' } }
        end,
        replace_actions = function(list) return #list end,
        replace_visibility = function(list) return #list end,
        set_row_limit = function() return true end,
        search_actions = function() return {} end,
        decide_visibility = function() return 'show' end,
        all_mob_statuses = function() return {} end,
        consume_open_core = function()
            local c = pending_open_core
            pending_open_core = 0
            return c
        end,
        diagnostics = function()
            return {
                enabled = true, api_version = 1, capabilities = 0x91FFF,
                hooks_installed = 20, hooks_total = 20,
                registry_soul_count = 66, registry_hash = 'cf86aa59ff8d16c6',
                action_count = 10, visibility_count = 10, action_row_limit = 16,
                hooks = { { id = 'menuwind_key_item', owner = 'soulspire', disposition = 'migrated', rva = 0x141800, installed = true, hit_count = 1, detail = 'ok' } },
            }
        end,
    },
    imgui = {
        SetNextWindowSize = function() end,
        Begin = function(title) imgui_windows[title] = (imgui_windows[title] or 0) + 1; return true end,
        End = function() end,
        BeginChild = function() return true end,
        EndChild = function() end,
        Text = function() end,
        TextColored = function() end,
        TextWrapped = function() end,
        Button = function() return false end,
        SmallButton = function() return false end,
        Selectable = function() return false end,
        SameLine = function() end,
        Separator = function() end,
    },
}

local function fire(ev, arg)
    local res = false
    for _, fn in ipairs(handlers[ev] or {}) do
        if fn(arg) then res = true end
    end
    return res
end

-- 1. Execute real entrypoint
local core = dofile('addons/vanacore/soulspire_core/soulspire_core.lua')
assert(core.startup_report.ok == true, 'startup_report must be OK')
assert(handlers.load and #handlers.load == 1, 'must subscribe to load')
assert(handlers.present and #handlers.present == 1, 'must subscribe to present')
assert(handlers.command and #handlers.command == 1, 'must subscribe to command')
assert(handlers.packet_in and #handlers.packet_in == 1, 'must subscribe to packet_in')
assert(handlers.frame == nil, 'must NEVER subscribe to non-existent frame event')

-- 2. Fire realistic VanaCore load lifecycle event
fire('load')
assert(core.startup_report.ok == true, 'startup_report must remain OK after load')

-- 3. Fire 'present' -> Shinobi HUD renders immediately without hub open
fire('present')
assert((imgui_windows['Shinobi HUD###soulspire_native_hud'] or 0) == 1, 'Shinobi HUD must render on present')

-- 4. Test slash commands: /talents, /soulspire status, /soulactions status, /soulactions capabilities
assert(fire('command', { command = '/talents' }) == true, '/talents must be handled')
assert(core.is_hub_open() == true, '/talents must open hub')
assert(core.active_tab() == 'soulforge', '/talents must select soulforge tab (not boolean true!)')
assert(fire('command', { command = '/soulspire status' }) == true)
assert(fire('command', { command = '/soulactions status' }) == true)
assert(fire('command', { command = '/soulactions capabilities' }) == true)

-- 5. Fire 'present' while hub open -> Core Hub renders & requests gamepad nav
fire('present')
assert((imgui_windows['Soulspire Core (VanaCore Native)###soulspire_core_hub'] or 0) == 1, 'Core Hub must render on present')
assert(gamepad_nav_calls >= 1, 'Core Hub must enable vana.gamepad.nav(true)')

-- 6. Close via /soulspire, then verify native Commands menu activation (consume_open_core) re-opens Hub
assert(fire('command', { command = '/soulspire' }) == true)
assert(core.is_hub_open() == false)
pending_open_core = 1
fire('present')
assert(core.is_hub_open() == true, 'consume_open_core() must open Core Hub from native Commands menu')

print('PASS: Full-entrypoint VanaCore lifecycle regression test verified (load/present/command/HUD/Soulforge/native-menu)')
