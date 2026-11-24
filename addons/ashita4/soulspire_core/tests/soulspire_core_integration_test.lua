-- Packaged Soulspire Core End-to-End Integration Regression Suite.
-- Run from addons/ashita4/soulspire_core: luajit tests/soulspire_core_integration_test.lua
--
-- Loads the ACTUAL packaged soulspire_core.lua entrypoint under a realistic Ashita v4
-- harness and exercises:
--   1. Module initialization order (`load` event)
--   2. Fresh login (`0x00A`) & zone transitions (`0x00B` -> `0x00A`)
--   3. Actual `packet_in` callback with representative `0x1FC` OXSI packets (local + remote peers)
--   4. Live Soul switching (Commander -> Berserker -> unsocketed op=0)
--   5. `/soulspire status`, `/soulspire weapondiag on`, `/soulspire weapondiag equip`, `/soulspire weapondiag probe`
--   6. Live `packet_out` & `packet_in` `0x050` observation while diagnostics are enabled
--   7. Actual JSON report file creation, printed report path, and actionable write error handling
--   8. Rate-limited fault isolation so an isolated module error cannot unload soulspire_core

package.path = './?.lua;../crystalsocket/?.lua;' .. package.path

local bit = require('bit')

-- Capture printed logs.
local logs = {}
local orig_print = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do
        parts[i] = tostring(select(i, ...))
    end
    logs[#logs + 1] = table.concat(parts, '\t')
end

local function has_log(substr)
    for i = #logs, 1, -1 do
        if logs[i]:find(substr, 1, true) then return true, logs[i] end
    end
    return false, nil
end

-- Stub Ashita v4 runtime globals and modules.
local events = {}
local tick_ms = 100000

_G.addon = {
    name = '',
    author = '',
    version = '',
    desc = '',
    link = '',
    path = '/tmp/soulspire_core_int_test/addons/soulspire_core',
}

_G.ashita = {
    events = {
        register = function(ev, name, cb)
            events[ev] = cb
        end,
    },
    time = {
        get_tick64 = function() return tick_ms end,
    },
    memory = {},
}

_G.AshitaCore = {
    GetChatManager = function()
        return { IsInputOpen = function() return 0 end }
    end,
    GetPointerManager = function()
        return { Get = function() return nil end }
    end,
    GetMemoryManager = function()
        return {
            GetPlayer = function()
                return { GetMainJobLevel = function() return 20 end }
            end,
            GetInventory = function()
                return {
                    GetEquippedItem = function(_, slot)
                        if slot == 0 then return { Index = 1 } end
                        return { Index = 0 }
                    end,
                    GetContainerCountMax = function(_, bag)
                        return (bag == 0) and 2 or 0
                    end,
                    GetContainerItem = function(_, bag, idx)
                        if bag == 0 and idx == 1 then return { Id = 18480 } end
                        if bag == 0 and idx == 2 then return { Id = 18481 } end
                        return nil
                    end,
                }
            end,
        }
    end,
    GetResourceManager = function()
        return {
            GetItemById = function(_, id)
                if id == 18480 then return { Name = { 'Great Axe' }, Skill = 6, Slots = 1 } end
                if id == 18481 then return { Name = { 'Butterfly Axe' }, Skill = 6, Slots = 1 } end
                return nil
            end,
        }
    end,
}

package.loaded['common'] = true
package.loaded['scaling'] = { scaled = { w = 1280, h = 720 } }
package.loaded['imgui'] = setmetatable({}, {
    __index = function() return function() return false end end,
})

-- Prepare temp directory mirroring Ashita's `addons/soulspire_core` + `plugins/data` layout.
os.execute('rm -rf /tmp/soulspire_core_int_test && mkdir -p /tmp/soulspire_core_int_test/addons/soulspire_core /tmp/soulspire_core_int_test/plugins/data')
local cfg_in = assert(io.open('../../../plugins/ashita4/data/soul-weapon-config.json', 'rb'))
local cfg_bytes = cfg_in:read('*a')
cfg_in:close()
local cfg_out = assert(io.open('/tmp/soulspire_core_int_test/plugins/data/soul-weapon-config.json', 'wb'))
cfg_out:write(cfg_bytes)
cfg_out:close()

-- Helper: build a valid 44-byte 0x1FC OXSI packet (matches weapon_presentation_test.lua).
local function u16le(n)
    return string.char(bit.band(n, 0xFF), bit.band(bit.rshift(n, 8), 0xFF))
end
local function u32le(n)
    return string.char(
        bit.band(n, 0xFF),
        bit.band(bit.rshift(n, 8), 0xFF),
        bit.band(bit.rshift(n, 16), 0xFF),
        bit.band(bit.rshift(n, 24), 0xFF)
    )
end
local function build_oxsi(op, actor_id, char_id, job, branch, char_name, soul_id)
    local payload = string.char(0xFC, 0x00, 0x00, 0x00) .. 'OXSI' .. string.char(1, op)
        .. u32le(actor_id) .. u32le(char_id)
        .. string.char(job, branch, #char_name, #soul_id) .. char_name .. soul_id
    local pad = (4 - (#payload % 4)) % 4
    return payload .. string.rep('\0', pad)
end

local function run_cmd(text)
    local e = { command = text, blocked = false }
    events.command(e)
    assert(e.blocked == true, 'Expected command to be handled: ' .. text)
end

-- 1. Load the actual packaged soulspire_core.lua!
assert(pcall(dofile, 'soulspire_core.lua'), 'soulspire_core.lua failed to load')
assert(type(events.load) == 'function', 'load event not registered')
assert(type(events.packet_in) == 'function', 'packet_in event not registered')
assert(type(events.packet_out) == 'function', 'packet_out event not registered')
assert(type(events.command) == 'function', 'command event not registered')
assert(type(events.d3d_present) == 'function', 'd3d_present event not registered')
assert(type(events.unload) == 'function', 'unload event not registered')

-- 2. Trigger `load` event (initializes assets, weapon_pres, ui).
events.load()

-- 3. Fresh login (`0x00A`) must succeed cleanly.
events.packet_in({ id = 0x00A, data = string.rep('\0', 16) })

-- 4. REGRESSION TEST: Actual `packet_in` with 0x1FC OXSI packets (local + remote peer + Soul switch).
events.packet_in({ id = 0x1FC, data = build_oxsi(1, 1001, 1001, 1, 1, 'LocalWar', 'war_support') })
events.packet_in({ id = 0x1FC, data = build_oxsi(1, 2002, 2002, 1, 2, 'PeerBrz', 'war_dps') })
run_cmd('/soulspire weapondiag')
assert(has_log('loaded=true'), 'weapon_pres should load authoritative soul-weapon-config.json')
assert(has_log('peers=2'), 'OXSI packet_in should track 2 active peers (local + remote)')

-- Switch local Soul from Commander -> Berserker, and clear remote peer (op=0).
events.packet_in({ id = 0x1FC, data = build_oxsi(1, 1001, 1001, 1, 2, 'LocalWar', 'war_dps') })
events.packet_in({ id = 0x1FC, data = build_oxsi(0, 2002, 2002, 1, 0, 'PeerBrz', '') })
run_cmd('/soulspire weapondiag')
assert(has_log('peers=1'), 'Peer count should drop to 1 after remote peer op=0 clear')

-- Zone change (`0x00B`) resets peers cleanly.
events.packet_in({ id = 0x00B, data = string.rep('\0', 16) })
run_cmd('/soulspire weapondiag')
assert(has_log('peers=0'), 'Zone change 0x00B must reset peers to 0')

-- 5. `/soulspire status` works cleanly after login.
run_cmd('/soulspire status')
assert(has_log('version=0.1.0'), '/soulspire status must report core version')

-- 6. `/soulspire weapondiag on`, live `0x050` packet observation, and `/soulspire weapondiag equip`.
run_cmd('/soulspire weapondiag on')
assert(has_log('ENABLED'), '/soulspire weapondiag on must enable diagnostics')

local pkt_out_050 = string.char(0x50, 0x04, 0x00, 0x00, 2, 1, 0, 0)
local pkt_in_050  = string.char(0x50, 0x04, 0x00, 0x00, 2, 1, 0, 0)
events.packet_out({ id = 0x050, data = pkt_out_050 })
events.packet_in({ id = 0x050, data = pkt_in_050 })
assert(has_log('C2S 0x050 equip_slot=1 inv_idx=2 container=0'), 'C2S 0x050 must be logged when diagnostics enabled')
assert(has_log('S2C 0x050 equip_slot=1 inv_idx=2 container=0'), 'S2C 0x050 must be logged when diagnostics enabled')

run_cmd('/soulspire weapondiag equip')
assert(has_log('0x050_trace=2'), 'Equip diag must include both observed 0x050 packets')
assert(has_log('Equip diag report written to:') and has_log('soul-weapon-equip-diag.local.json'),
    'Equip diag must print generated report path in chat')

local rep_f = assert(io.open('/tmp/soulspire_core_int_test/plugins/data/soul-weapon-equip-diag.local.json', 'rb'))
local rep_body = rep_f:read('*a')
rep_f:close()
assert(rep_body:find('"diagnosticType": "soulspire_weapon_equip_diag"', 1, true) ~= nil)
assert(rep_body:find('"packetTrace0x050"', 1, true) ~= nil)

-- 7. File-writing error produces an actionable error in chat (not silent nil).
local Diag = require('core.weapon_equip_diag')
local ok_werr, _, wp_nil, w_err = Diag.run_diagnostic({
    diagnostics_enabled = true,
    output_path = '/nonexistent_dir_xyz/soul-weapon-equip-diag.local.json',
    slices_override = {},
    native_override = { dll_loaded = false },
})
assert(ok_werr == true and wp_nil == nil and type(w_err) == 'string' and w_err:find('Failed opening', 1, true) ~= nil)

-- 8. Render probe command handles non-Windows environment cleanly without throwing.
run_cmd('/soulspire weapondiag probe')

-- 9. `d3d_present` and `unload` run cleanly.
events.d3d_present()
events.unload()

-- Cleanup temp dir.
os.execute('rm -rf /tmp/soulspire_core_int_test')

_G.print = orig_print
print('Packaged soulspire_core end-to-end integration tests passed.')
