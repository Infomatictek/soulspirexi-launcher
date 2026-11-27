-- End-to-End Regression Test: VanaCore Native Soul Synchronization & Controller Input
-- Exercises the REAL `soulspire_core.lua` entrypoint and its registered `vana.events.on(...)`
-- handlers (load, present, packet_in, xinput_button, dinput_button, xinput_state, dinput_state, key).

local addon_dir = 'addons/vanacore/soulspire_core'
local handlers = {}
local sent_packets = {}
local set_identity_calls = {}
local tex_load_calls = {}
local now_clock = 184523.40 -- Simulate high wall-clock uptime (far ahead of os.clock()!)
local pending_open_core = 0
local current_job = 1
local current_lvl = 75
local current_zone = 230
local mouse_delta_x = 0

local ui_input = {
    active = false,
    owner_count = 0,
    acquire_count = 0,
    release_count = 0,
    last_release_reason = '',
}

local function build_crys_reply(request_id, job_id, level, owned_mask, active_branch, result)
    result = result or 0
    local bytes = {}
    bytes[1] = 0xFF
    bytes[2] = 0x21 -- 64 bytes ((16 << 9) | 0x1FF)
    bytes[3] = 0x00
    bytes[4] = 0x00
    bytes[5] = string.byte('C')
    bytes[6] = string.byte('R')
    bytes[7] = string.byte('Y')
    bytes[8] = string.byte('S')
    bytes[9] = 1
    bytes[10] = result
    bytes[11] = request_id % 256
    bytes[12] = math.floor(request_id / 256)
    bytes[13] = job_id
    bytes[14] = 24
    bytes[15] = level
    bytes[16] = 0
    for i = 1, 24 do
        local is_target = (i == job_id + 1)
        bytes[15 + i * 2] = is_target and owned_mask or 0
        bytes[16 + i * 2] = is_target and active_branch or 0
    end
    local out = {}
    for i = 1, 64 do out[i] = string.char(bytes[i]) end
    return table.concat(out)
end

local function build_oxhd_packet(unlocked, job_id, soul_key, kv_raw)
    soul_key = soul_key or ''
    kv_raw = kv_raw or ''
    local key_len = #soul_key
    local kv_len = #kv_raw
    return string.char(0xFC, 0x11, 0, 0) .. 'OXHD'
        .. string.char(1, unlocked and 1 or 0, job_id, key_len, kv_len % 256, math.floor(kv_len / 256), 0, 0)
        .. soul_key .. kv_raw
end

local function build_061_packet(job_id, level)
    local t = {}
    for i = 1, 16 do t[i] = '\0' end
    t[13] = string.char(job_id)
    t[14] = string.char(level)
    return table.concat(t)
end

local function fire(event_name, e)
    local list = handlers[event_name] or {}
    local res = false
    for _, fn in ipairs(list) do
        local r = fn(e)
        if r == true then res = true end
    end
    return res
end

_G.addon = { name = 'soulspire_core', path = addon_dir }
_G.vana = {
    paths = { install = '.' },
    log = function() end,
    time = { clock = function() return now_clock end },
    fs = {
        exists = function(p)
            local f = io.open(p, 'rb')
            if f then f:close(); return true end
            return false
        end,
    },
    events = {
        on = function(name, fn)
            handlers[name] = handlers[name] or {}
            handlers[name][#handlers[name] + 1] = fn
        end,
    },
    game = {
        self = function()
            return 1, current_zone, current_job, current_lvl, 1, 37
        end,
        character = function()
            return 'Rin', 1
        end,
        player = function()
            return { main_job = current_job, main_job_level = current_lvl, sub_job = 1, sub_job_level = 37 }
        end,
        jobs = function()
            return { [current_job] = { level = current_lvl } }
        end,
        world = function()
            return { chat_open = false }
        end,
    },
    packets = {
        inject = function(incoming, id, data)
            sent_packets[#sent_packets + 1] = { incoming = incoming, id = id, data = data }
        end,
    },
    imgui = setmetatable({
        GetIO = function()
            return { WantTextInput = false, DisplaySize = { x = 1920, y = 1080 }, MouseDelta = { x = mouse_delta_x, y = 0 } }
        end,
        IsMouseClicked = function() return false end,
        Begin = function() return false end,
        End = function() end,
    }, {
        __index = function() return function() return false end end,
    }),
    soulspire = {
        enabled = function() return true end,
        diagnostics = function()
            return { enabled = true, api_version = 2, hooks_installed = 21, hooks_total = 21, capabilities = 0x391FFD }
        end,
        identity = function()
            local last = set_identity_calls[#set_identity_calls]
            if last then
                return { character_id = 1, job = last.job, branch = last.branch, effective_level = current_lvl, known = last.branch > 0 }
            end
            return { character_id = 1, job = current_job, branch = 1, effective_level = current_lvl, known = true }
        end,
        set_identity = function(job, branch, cid, lvl)
            set_identity_calls[#set_identity_calls + 1] = { job = job, branch = branch, cid = cid, lvl = lvl }
            return true
        end,
        replace_actions = function(list) return #list end,
        replace_visibility = function(list) return #list end,
        set_action_row_limit = function() return true end,
        consume_open_core = function()
            local n = pending_open_core
            pending_open_core = 0
            return n
        end,
        acquire_ui_input = function()
            if not ui_input.active then
                ui_input.active = true
                ui_input.owner_count = 1
                ui_input.acquire_count = ui_input.acquire_count + 1
            end
            return true
        end,
        release_ui_input = function(_owner, reason)
            if ui_input.active then
                ui_input.active = false
                ui_input.owner_count = 0
                ui_input.release_count = ui_input.release_count + 1
                ui_input.last_release_reason = reason or 'closed'
            end
            return true
        end,
        ui_input_state = function()
            return {
                active = ui_input.active,
                owner_count = ui_input.owner_count,
                acquire_count = ui_input.acquire_count,
                release_count = ui_input.release_count,
                last_release_reason = ui_input.last_release_reason,
            }
        end,
        load_texture = function(path)
            tex_load_calls[#tex_load_calls + 1] = path
            local f = io.open(path, 'rb')
            if f then
                f:close()
                return 100 + #tex_load_calls, 128, 128
            end
            return nil, 'decode failed'
        end,
        release_textures = function() return 0 end,
    },
}

local core = dofile(addon_dir .. '/soulspire_core.lua')
fire('load')

local st = core.get_state()
assert(core.startup_report.ok == true, 'startup_report must be ok')
assert(st.focus and st.input and st.character_mod and st.abilities_mod and st.status_diag, 'core modules initialized')

-- 1. Verify Soul Sync sent 0x11F CRYS on login and DOES NOT time out on next present frame (high wall-clock uptime!)
local crys_reqs = {}
for _, p in ipairs(sent_packets) do
    if p.id == 0x11F and p.data:sub(5, 8) == 'CRYS' then crys_reqs[#crys_reqs + 1] = p end
end
assert(#crys_reqs == 1, 'Expected 1 initial 0x11F CRYS query, got ' .. tostring(#crys_reqs))
local req_id_1 = crys_reqs[1].data:byte(11) + crys_reqs[1].data:byte(12) * 256
assert(req_id_1 == 0x4001, 'Expected initial CRYS request_id 0x4001, got ' .. tostring(req_id_1))

-- Advance 16ms and tick present: MUST NOT time out!
now_clock = now_clock + 0.016
fire('present')
assert(st.character_mod.crystal_state.pending ~= nil, 'CRYS request must stay pending after 16ms (clock mismatch regression!)')

-- Deliver server 0x1FF CRYS reply: Rin WAR75 owns all 3 Souls (mask=0x0E), active=2 (Berserker)
now_clock = now_clock + 0.050
local reply_1 = build_crys_reply(req_id_1, 1, 75, 0x0E, 2, 0)
fire('packet_in', { id = 0x1FF, data = reply_1, size = #reply_1 })
local entries, snap, activeBranch = st.character_mod:get_entries()
assert(snap.loaded == true, 'CrystalSocket state must be loaded after 0x1FF reply')
assert(activeBranch == 2, 'Active branch must be 2 (Berserker), got ' .. tostring(activeBranch))
local owned = 0
for _, e in ipairs(entries) do if e.branch > 0 and e.owned then owned = owned + 1 end end
assert(owned == 3, 'Expected 3/3 Souls awakened for Rin, got ' .. tostring(owned))
assert(st.runtime_diag.crys_rx == 1, 'Expected crys_rx == 1')

-- 2. Verify binary 0x1FC OXHD decodes Berserker (branch=2), NOT Commander (branch=1)
local oxhd = build_oxhd_packet(true, 1, 'berserker', 'rage=50')
fire('packet_in', { id = 0x1FC, data = oxhd, size = #oxhd })
assert(st.runtime_diag.oxhd_rx == 1, 'Expected oxhd_rx == 1')
assert(set_identity_calls[#set_identity_calls].job == 1 and set_identity_calls[#set_identity_calls].branch == 2,
    '0x1FC OXHD must set identity to WAR branch 2 (Berserker)')

-- 3. Verify closed Hub does NOT consume controller events (normal FFXI controls untouched)
local closed_ev = { button = 12, state = 1, blocked = false }
local closed_res = fire('xinput_button', closed_ev)
assert(closed_res == false and closed_ev.blocked == false, 'Closed Hub must NOT block xinput_button')

-- 4. Open Hub via native Commands menu (consume_open_core) and verify confirm guard + zero focus_loss churn
pending_open_core = 1
fire('present')
assert(st.focus:is_hub_open() == true, 'Hub must open from consume_open_core')
assert(ui_input.acquire_count == 1 and ui_input.release_count == 0, 'Expected 1 acquire, 0 release on open')

-- Simulate focus_loss from C++ across 60 background frames -> MUST NOT oscillate acquire/release!
ui_input.active = false
ui_input.release_count = ui_input.release_count + 1
ui_input.last_release_reason = 'focus_loss'
for _ = 1, 60 do
    now_clock = now_clock + 0.016
    fire('present')
end
assert(ui_input.acquire_count == 1, 'Background focus_loss must NOT cause 60Hz re-acquire churn (got ' .. tostring(ui_input.acquire_count) .. ')')

-- 5. Controller navigation inside Soul Sanctum (XInput D-Pad, A modal, B cancel modal, A confirm socket, X sync)
now_clock = now_clock + 0.30 -- past 0.22s confirm guard
-- Move down to Spartan (index 1=Base, 2=Commander, 3=Berserker, 4=Spartan)
for _ = 1, 3 do
    local ev_dn = { button = 1, state = 1 }
    assert(fire('xinput_button', ev_dn) == true and ev_dn.blocked == true, 'D-Pad Down must be consumed')
    fire('xinput_button', { button = 1, state = 0 })
end
assert(st.character_mod.selected_idx == 4, 'Expected selected_idx == 4 (Spartan), got ' .. tostring(st.character_mod.selected_idx))
assert(ui_input.acquire_count == 2, 'User controller interaction after focus_loss cleanly re-acquires UI input once')

-- Press A (12) to open Confirm Socket modal
fire('xinput_button', { button = 12, state = 1 })
fire('xinput_button', { button = 12, state = 0 })
assert(st.character_mod:has_modal() == true, 'A on owned inactive Soul must open confirm_socket modal')

-- Press B (13) to cancel modal WITHOUT closing Hub
fire('xinput_button', { button = 13, state = 1 })
fire('xinput_button', { button = 13, state = 0 })
assert(st.character_mod:has_modal() == false and st.focus:is_hub_open() == true, 'B in modal must close modal only, keeping Hub open')

-- Re-open modal and confirm socket Spartan (branch 3) -> sends 0x11F OP_SELECT (op=1, branch=3)
fire('xinput_button', { button = 12, state = 1 })
fire('xinput_button', { button = 12, state = 0 })
fire('xinput_button', { button = 12, state = 1 })
fire('xinput_button', { button = 12, state = 0 })
local last_pkt = sent_packets[#sent_packets]
assert(last_pkt.id == 0x11F and last_pkt.data:byte(10) == 1 and last_pkt.data:byte(14) == 3,
    'Confirming Spartan socket must send 0x11F OP_SELECT branch=3')
local req_id_sel = last_pkt.data:byte(11) + last_pkt.data:byte(12) * 256
local reply_sel = build_crys_reply(req_id_sel, 1, 75, 0x0E, 3, 0)
fire('packet_in', { id = 0x1FF, data = reply_sel, size = #reply_sel })
local _, _, activeAfter = st.character_mod:get_entries()
assert(activeAfter == 3, 'Spartan (branch 3) must become active after server 0x1FF reply')

-- 6. Switch across player modules via RB (9): default mode hides Diagnostics/Equipment; /soulspire devmode on reveals them
local visited = { [st.focus:active_module().id] = true }
for _ = 1, 6 do
    fire('xinput_button', { button = 9, state = 1 })
    fire('xinput_button', { button = 9, state = 0 })
    visited[st.focus:active_module().id] = true
end
assert(visited.character and visited.weapon_mastery and visited.soul_talents and visited.abilities,
    'RB must cycle across all 4 production player modules: Character, Weapon Mastery, Soul Talents, Soul Actions')
assert(not visited.journal and not visited.equipment,
    'Default player RB cycle must hide Diagnostics and Phase D Equipment tabs')

-- Enabling local devmode reveals Diagnostics in RB cycle (does not grant server privileges)
fire('command', { command = '/soulspire devmode on' })
local dev_visited = { [st.focus:active_module().id] = true }
for _ = 1, 7 do
    fire('xinput_button', { button = 9, state = 1 })
    fire('xinput_button', { button = 9, state = 0 })
    dev_visited[st.focus:active_module().id] = true
end
assert(dev_visited.journal, 'Developer mode RB cycle must reach Diagnostics')

-- Select Diagnostics and test DirectInput POV (offset 32, angle 9000 = Right) subtab switching
st.focus:select_module('journal')
assert(st.status_diag.subtab == 'diag')
local di_ev = { button = 32, state = 9000 }
assert(fire('dinput_button', di_ev) == true and di_ev.blocked == true, 'DirectInput POV Right must be consumed')
fire('dinput_button', { button = 32, state = 0xFFFFFFFF })
assert(st.status_diag.subtab == 'mobs', 'DirectInput POV Right must switch Diagnostics subtab to mobs')

-- DirectInput L1 (offset 48+4 = 52) switches module backward
local before_mod = st.focus:active_module().id
fire('dinput_button', { button = 52, state = 0x80 })
fire('dinput_button', { button = 52, state = 0 })
assert(st.focus:active_module().id ~= before_mod, 'DirectInput L1 (offset 52) must switch module')

-- 7. Real VanaCore C++ xinput_state / dinput_state contract (`e.state == e.state_modified` SAME pointer!)
-- Proves ALL physical digital buttons (DPad U/D/L/R, LB/RB, A/B/X/Y) + Left Stick work BEFORE zeroing!
st.focus:select_module('journal')
local shared_x = { Gamepad = { sThumbLX = 30000, sThumbLY = 0, wButtons = 0 } }
fire('xinput_state', { user = 0, state = shared_x, state_modified = shared_x })
assert(shared_x.Gamepad.sThumbLX == 0 and shared_x.Gamepad.wButtons == 0,
    'xinput_state must neutralize shared state buffer while Hub is open')
assert(st.status_diag.subtab == 'flintlock', 'Left Stick Right must navigate Diagnostics subtab')
-- Release stick to neutral
shared_x.Gamepad.sThumbLX = 0
fire('xinput_state', { user = 0, state = shared_x, state_modified = shared_x })

local function pulse_xinput_state(mask, user)
    local buf = { Gamepad = { sThumbLX = 0, sThumbLY = 0, wButtons = mask } }
    fire('xinput_state', { user = user or 0, state = buf, state_modified = buf })
    assert(buf.Gamepad.wButtons == 0, 'xinput_state must zero wButtons in-place so nothing leaks to FFXI')
end

-- Helper: hold button across 2 frames + idle user=1 frame -> must fire ONCE (no duplicate, no premature release)
st.focus:select_module('character')
local before_rb_mod = st.focus:active_module().id
pulse_xinput_state(0x0200, 0) -- RB (bit 9)
local after_rb_mod = st.focus:active_module().id
assert(after_rb_mod ~= before_rb_mod, 'Physical XInput RB (0x0200) via xinput_state must switch top-level module')
local idg = st.input:get_diagnostics()
assert(idg.raw_button_mask == 0x0200 and idg.last_physical_button == 'xinput:9 (RB)' and
    idg.last_button_state == 'pressed' and idg.last_action == 'module_next' and idg.last_action_reached == true,
    'Controller diagnostics must record raw_mask, physical button, pressed state, action, and reached_ui')
-- Idle controller user=1 with wButtons=0 must NOT clear user=0 held RB state
pulse_xinput_state(0x0000, 1)
pulse_xinput_state(0x0200, 0) -- Still held on user=0 -> must NOT double-advance!
assert(st.focus:active_module().id == after_rb_mod, 'Held RB across frames + idle user=1 must NOT double-fire')
pulse_xinput_state(0x0000, 0) -- Release RB
assert(st.input:get_diagnostics().last_button_state == 'released', 'Releasing RB must record released state')

-- LB (0x0100) returns back to Character
pulse_xinput_state(0x0100, 0); pulse_xinput_state(0x0000, 0)
assert(st.focus:active_module().id == before_rb_mod, 'Physical XInput LB (0x0100) via xinput_state must switch module back')

-- D-Pad Up (0x0001) & Down (0x0002) on Character
local idx_before_dpad = st.character_mod.selected_idx
pulse_xinput_state(0x0001, 0); pulse_xinput_state(0x0000, 0) -- D-Pad Up
assert(st.character_mod.selected_idx ~= idx_before_dpad, 'Physical XInput D-Pad Up (0x0001) must move cursor')
pulse_xinput_state(0x0002, 0); pulse_xinput_state(0x0000, 0) -- D-Pad Down
assert(st.character_mod.selected_idx == idx_before_dpad, 'Physical XInput D-Pad Down (0x0002) must move cursor back')

-- D-Pad Left (0x0004) & Right (0x0008) on Diagnostics inner subtabs
st.focus:select_module('journal')
local sub_start = st.status_diag.subtab
pulse_xinput_state(0x0008, 0); pulse_xinput_state(0x0000, 0) -- D-Pad Right
assert(st.status_diag.subtab ~= sub_start, 'Physical XInput D-Pad Right (0x0008) must switch inner tab')
pulse_xinput_state(0x0004, 0); pulse_xinput_state(0x0000, 0) -- D-Pad Left
assert(st.status_diag.subtab == sub_start, 'Physical XInput D-Pad Left (0x0004) must switch inner tab back')

-- Y (0x8000) opens Help overlay; B (0x2000) closes Help overlay without closing Hub
pulse_xinput_state(0x8000, 0); pulse_xinput_state(0x0000, 0) -- Y
assert(st.focus.help_open == true, 'Physical XInput Y (0x8000) must toggle Help modal open')
pulse_xinput_state(0x2000, 0); pulse_xinput_state(0x0000, 0) -- B
assert(st.focus.help_open == false and st.focus:is_hub_open() == true, 'Physical XInput B (0x2000) must dismiss Help modal')

-- X (0x4000) triggers Soul Sync on Character; A (0x1000) opens confirm modal on owned inactive Soul
st.focus:select_module('character')
local reqs_before_x = #sent_packets
pulse_xinput_state(0x4000, 0); pulse_xinput_state(0x0000, 0) -- X
assert(#sent_packets > reqs_before_x, 'Physical XInput X (0x4000) must trigger Soul Sync')
-- Clear pending so A can open socket modal on Berserker (index 3, owned, inactive since Spartan is active)
local rx_pkt = sent_packets[#sent_packets]
local rx_id = rx_pkt.data:byte(11) + rx_pkt.data:byte(12) * 256
fire('packet_in', { id = 0x1FF, data = build_crys_reply(rx_id, 1, 75, 0x0E, 3, 0), size = 64 })
st.character_mod.selected_idx = 3
pulse_xinput_state(0x1000, 0); pulse_xinput_state(0x0000, 0) -- A
assert(st.character_mod:has_modal() == true, 'Physical XInput A (0x1000) must open Confirm Socket modal')
pulse_xinput_state(0x2000, 0); pulse_xinput_state(0x0000, 0) -- B dismisses modal
assert(st.character_mod:has_modal() == false and st.focus:is_hub_open() == true, 'Physical XInput B (0x2000) must dismiss modal')

-- DirectInput shared-buffer `dinput_state` (POV + rgbButtons)
st.focus:select_module('journal')
local dsub_before = st.status_diag.subtab
local shared_d = { lX = 0, lY = 0, rgdwPOV = { [0] = 9000, [1] = 0xFFFFFFFF, [2] = 0xFFFFFFFF, [3] = 0xFFFFFFFF }, rgbButtons = {} }
for i = 0, 31 do shared_d.rgbButtons[i] = 0 end
fire('dinput_state', { state = shared_d, state_modified = shared_d })
assert(shared_d.rgdwPOV[0] == 0xFFFFFFFF, 'dinput_state must neutralize rgdwPOV[0] in-place')
assert(st.status_diag.subtab ~= dsub_before, 'DirectInput POV via dinput_state must switch Diagnostics subtab')
shared_d.rgdwPOV[0] = 0xFFFFFFFF
shared_d.rgbButtons[5] = 0x80 -- R1 -> module_next
local dmod_before = st.focus:active_module().id
fire('dinput_state', { state = shared_d, state_modified = shared_d })
assert(shared_d.rgbButtons[5] == 0, 'dinput_state must neutralize rgbButtons in-place')
assert(st.focus:active_module().id ~= dmod_before, 'DirectInput R1 (rgbButtons[5]) via dinput_state must switch module')
shared_d.rgbButtons[5] = 0
fire('dinput_state', { state = shared_d, state_modified = shared_d })

-- 8. Hold-to-repeat via present tick & Mouse <-> Gamepad device switching
st.focus:select_module('character')
local before_idx = st.character_mod.selected_idx
fire('xinput_button', { button = 1, state = 1 }) -- Hold Down
now_clock = now_clock + 0.40 -- past 0.32s repeat_delay
fire('present')
assert(st.character_mod.selected_idx ~= before_idx, 'Holding D-Pad Down must trigger hold-to-repeat on present')
fire('xinput_button', { button = 1, state = 0 })

mouse_delta_x = 12
now_clock = now_clock + 0.016
fire('present')
assert(st.input.last_device == 'mouse', 'Mouse movement must switch last_device to mouse')
mouse_delta_x = 0

-- 9. Close Hub with B (13) -> immediately releases UI input and restores FFXI controller passthrough
fire('xinput_button', { button = 13, state = 1 })
fire('xinput_button', { button = 13, state = 0 })
assert(st.focus:is_hub_open() == false, 'B must close Hub')
assert(ui_input.active == false, 'Closing Hub must release native UI input immediately')
local after_close = { button = 12, state = 1, blocked = false }
assert(fire('xinput_button', after_close) == false and after_close.blocked == false,
    'After closing Hub, xinput_button must pass through unblocked to FFXI')

-- 10. Job change (0x061 WAR -> COR) triggers fresh 0x11F sync
local req_before_job = #sent_packets
current_job = 1
fire('packet_in', { id = 0x061, data = build_061_packet(1, 75), size = 16 }) -- baseline job=1
current_job = 17
fire('packet_in', { id = 0x061, data = build_061_packet(17, 75), size = 16 }) -- changejob to COR
assert(#sent_packets > req_before_job and sent_packets[#sent_packets].id == 0x11F,
    'Job change (0x061) must trigger fresh 0x11F Soul sync')

-- 11. Texture asset path resolution & zero missing-file load_texture failures
local before_tex = #tex_load_calls
local missing_id = st.assets:load_from_addon('nonexistent_addon', 'missing_panel')
assert(missing_id == nil and #tex_load_calls == before_tex,
    'Missing optional texture must NOT call vana.soulspire.load_texture (zero bogus failure count)')
local crystal_id = st.assets:load_from_addon('crystalsocket', 'berserker')
assert(type(crystal_id) == 'number' and crystal_id > 0,
    'crystalsocket berserker icon must resolve from assets/crystals/berserker.png')

print('PASS: test_soul_sync_and_controller (Soul sync, OXHD, XInput/DInput/Stick/Repeat, focus_loss churn, job change, texture pre-check)')
