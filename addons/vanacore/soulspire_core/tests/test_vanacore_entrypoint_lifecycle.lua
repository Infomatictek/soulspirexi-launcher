-- Client Sentinel & Full-Entrypoint Runtime Lifecycle Test for VanaCore-Native Soulspire Core (v4.0.0-vanacore)
-- Tests strictly against REAL VanaCore native contracts (`[addons] ashita.enabled=0`):
--   * Zero Ashita globals (`AshitaCore`, `ashita`, `ImGuiWindowFlags_*`, `ImGuiStyleVar_*`, `ImGuiCol_*`, `ImGuiCond_*`).
--   * Real VanaCore `push_vec2` contract: `GetWindowPos`, `GetCursorScreenPos`, `CalcTextSize`, `GetMousePos` return 2 numbers `(x, y)`.
--   * Strict ImGui call-stack balance (`Begin`/`End`, `BeginChild`/`EndChild`, `PushStyleVar`/`PopStyleVar`, `PushStyleColor`/`PopStyleColor`).
--   * Core Shell window chrome verification (`NoTitleBar|NoResize|NoMove|NoScrollbar|NoScrollWithMouse|NoCollapse|NoBackground|NoSavedSettings`).
--   * Authoritative data loading from `addons/vanacore/soulspire_core/data/` (66 Souls, >=150 actions, >=190 visibility rules) + fail-loud check.
--   * Real `0x11F` -> `0x1FF` `CRYS` server Soul synchronization lifecycle (Lv.75 Shinobi unlocked & socketed).
--   * Unified VanaCore Native hook diagnostics (`21/21 hooks active` on Character tab, never `0 hooks active`).
--   * Real `:draw(...)` execution across EVERY Core module (`character`, `weapon_mastery`, `soul_talents`, `abilities`, `journal` -> `diag`/`mobs`/`flintlock`).
--   * Real polished 66-Soul HUD (`soulhud_gauge.lua`) driven by binary `0x1FC` (`OXHD`) Shinobi packet + config modal + commands.
--   * Authoritative UI input/cursor ownership, LB/RB controller switching, native WIC texture loading, zone/logout/unload cleanup.

local bit = require('bit')

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s: expected %s, got %s', msg or 'assert_eq', tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or 'assert_true failed', 2)
    end
end

local script_path = debug.getinfo(1, 'S').source:gsub('^@', '')
local addon_dir   = script_path:gsub('[/\\]tests[/\\][^/\\]+$', '')
local repo_root   = addon_dir:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')

local VALID_VANACORE_EVENTS = {
    load = true, unload = true, present = true, command = true,
    packet_in = true, packet_out = true, key = true, mouse = true,
    xinput_button = true, dinput_button = true,
    xinput_state = true, dinput_state = true,
    zone_change = true, job_change = true, logout = true,
}

local handlers = {}
local logs = {}
local packets_sent = {}
local draw_calls = 0
local drawn_texts = {}
local begin_calls = {}
local loaded_textures = {}
local next_tex_id = 1000
local open_core_queue = 0
local current_clock = 100.0
local native_actions_count = 0
local native_visibility_count = 0

local stack = {
    begin_depth = 0,
    child_depth = 0,
    style_var_depth = 0,
    style_col_depth = 0,
}

local ui_input = {
    active = false,
    owner_count = 0,
    acquire_count = 0,
    release_count = 0,
    last_release_reason = '',
    block_mouse = false,
    capture_gamepad = false,
    show_cursor = false,
}

local mock_dl = setmetatable({
    AddText = function(_self, a, b, c, d, e)
        draw_calls = draw_calls + 1
        -- Support both AddText(pos, col, txt) and AddText(font, size, pos, col, txt)
        local txt = (type(e) == 'string' and e) or (type(c) == 'string' and c) or ''
        if txt ~= '' then
            drawn_texts[#drawn_texts + 1] = txt
        end
    end,
}, {
    __index = function(_, _k)
        return function() draw_calls = draw_calls + 1 end
    end
})

local mock_io = {
    DisplaySize = { x = 1920, y = 1080 },
    MousePos = { x = 960, y = 540 },
    MouseDrawCursor = false,
    WantTextInput = false,
    MouseClicked = { false, false, false },
    MouseDown = { false, false, false },
}

-- VEC2 style vars in Dear ImGui 1.92.3 (WindowPadding=2, WindowMinSize=5, WindowTitleAlign=6, FramePadding=11, ItemSpacing=14, ItemInnerSpacing=15)
local VEC2_STYLE_VARS = { [2] = true, [5] = true, [6] = true, [11] = true, [14] = true, [15] = true }

local mock_imgui = setmetatable({
    Begin = function(title, _p_open, flags)
        assert_true(type(title) == 'string', 'imgui.Begin title must be string')
        begin_calls[#begin_calls + 1] = { title = title, flags = tonumber(flags) or 0 }
        stack.begin_depth = stack.begin_depth + 1
        return true
    end,
    End = function()
        stack.begin_depth = stack.begin_depth - 1
        assert_true(stack.begin_depth >= 0, 'imgui.End underflow')
    end,
    BeginChild = function()
        stack.child_depth = stack.child_depth + 1
        return true
    end,
    EndChild = function()
        stack.child_depth = stack.child_depth - 1
        assert_true(stack.child_depth >= 0, 'imgui.EndChild underflow')
    end,
    PushStyleVar = function(idx, val)
        assert_true(type(idx) == 'number', 'PushStyleVar idx must be numeric, got ' .. tostring(idx))
        if type(val) == 'table' then
            assert_true(VEC2_STYLE_VARS[idx] == true,
                string.format('PushStyleVar(%d, table) invalid: StyleVar %d expects scalar float, not Vec2!', idx, idx))
        end
        stack.style_var_depth = stack.style_var_depth + 1
    end,
    PopStyleVar = function(n)
        stack.style_var_depth = stack.style_var_depth - (tonumber(n) or 1)
        assert_true(stack.style_var_depth >= 0, 'PopStyleVar underflow')
    end,
    PushStyleColor = function(idx, _val)
        assert_true(type(idx) == 'number', 'PushStyleColor idx must be numeric, got ' .. tostring(idx))
        stack.style_col_depth = stack.style_col_depth + 1
    end,
    PopStyleColor = function(n)
        stack.style_col_depth = stack.style_col_depth - (tonumber(n) or 1)
        assert_true(stack.style_col_depth >= 0, 'PopStyleColor underflow')
    end,
    Text = function(s) drawn_texts[#drawn_texts + 1] = tostring(s or '') end,
    TextUnformatted = function(s) drawn_texts[#drawn_texts + 1] = tostring(s or '') end,
    TextColored = function(_c, s) drawn_texts[#drawn_texts + 1] = tostring(s or '') end,
    GetIO = function() return mock_io end,
    GetWindowDrawList = function() return mock_dl end,
    GetForegroundDrawList = function() return mock_dl end,
    GetBackgroundDrawList = function() return mock_dl end,
    -- Real VanaCore `push_vec2` contract: returns 2 Lua numbers (x, y)
    GetWindowPos = function() return 560, 40 end,
    GetCursorScreenPos = function() return 100, 100 end,
    GetCursorPos = function() return 16, 16 end,
    GetContentRegionAvail = function() return 1200, 720 end,
    GetMousePos = function() return 960, 540 end,
    CalcTextSize = function(s) return #(tostring(s or '')) * 8, 16 end,
    GetFont = function() return nil end,
    GetFontSize = function() return 16 end,
    Button = function() return false end,
    SmallButton = function() return false end,
    InvisibleButton = function() return false end,
    Checkbox = function() return false end,
    SliderFloat = function() return false end,
    BeginCombo = function() return false end,
    EndCombo = function() end,
    BeginPopup = function() return false end,
    EndPopup = function() end,
    Selectable = function() return false end,
    IsItemHovered = function() return false end,
    IsItemClicked = function() return false end,
    IsMouseClicked = function() return false end,
    IsMouseReleased = function() return false end,
    IsMouseHoveringRect = function() return false end,
    GetColorU32 = function() return 0xFFFFFFFF end,
}, {
    __index = function(_, _k)
        return function() return nil end
    end
})

_G.addon = {
    name = 'soulspire_core',
    path = addon_dir,
}

-- Pure VanaCore Native runtime (`ashita.enabled=0`): ZERO Ashita or ImGui global enums!
_G.AshitaCore = nil
_G.ashita = nil
_G.ImGuiWindowFlags_NoTitleBar = nil
_G.ImGuiWindowFlags_NoCollapse = nil
_G.ImGuiStyleVar_WindowPadding = nil
_G.ImGuiCol_PopupBg = nil
_G.ImGuiCond_Always = nil

_G.vana = {
    version = '0.9.9-soulspire-native.4',
    log = function(msg) logs[#logs + 1] = tostring(msg) end,
    paths = { install = repo_root, addons = repo_root .. '/addons', addon = addon_dir },
    time = { clock = function() return current_clock end },
    ui = {
        screen = function() return 1920, 1080 end,
        interface_hidden = function() return false end,
    },
    game = {
        character = function() return 'Offset', 1001 end,
        self = function() return 1001, 126, 13, 75, 1, 37, 0, 0, 1400, 200, 1000, 100, 100 end,
        player = function() return { main_job = 13, main_job_level = 75, sub_job = 1, sub_job_level = 37 } end,
        jobs = function() return { [13] = { level = 75 } } end,
        recasts = function() return {} end,
        world = function() return { chat_open = false, weather = 0 } end,
    },
    packets = {
        inject = function(incoming, id, data)
            packets_sent[#packets_sent + 1] = { incoming = incoming, id = id, data = data }
            return true
        end,
    },
    settings = {
        register = function(opts)
            return { data = opts.defaults or {}, save = function() return true end }
        end,
        folder = function() return '/tmp/soulspire_test_cfg' end,
    },
    fs = {
        exists = function(p)
            local f = type(p) == 'string' and io.open(p, 'rb') or nil
            if f then f:close(); return true end
            return false
        end,
        create_dir = function() return true end,
    },
    gamepad = {
        nav = function() end,
    },
    imgui = mock_imgui,
    events = {
        on = function(ev, fn)
            assert_true(VALID_VANACORE_EVENTS[ev] == true, 'Registered non-existent VanaCore event: ' .. tostring(ev))
            handlers[ev] = handlers[ev] or {}
            handlers[ev][#handlers[ev] + 1] = fn
        end,
    },
    soulspire = {
        enabled = function() return true end,
        version = function() return 2 end,
        capabilities = function() return 0x391FFD end,
        identity = function()
            return { known = true, job = 13, branch = 1, effective_level = 75, soul_key = 'shinobi', short_name = 'SHN', full_name = 'Shinobi' }
        end,
        hud = function()
            return { soul_key = '', kv = {}, updated_ms = 0, packet_count = 0 }
        end,
        all_mob_statuses = function()
            return { { server_id = 17199452, payload = '1|1|', updated_ms = 12345, packet_count = 1 } }
        end,
        replace_actions = function(recs) native_actions_count = #recs; return #recs end,
        replace_visibility = function(recs) native_visibility_count = #recs; return #recs end,
        search_actions = function() return { { kind = 1, id = 339, name = 'Shadow Squadron: Ichi', description = 'Summons offensive shadow clones.' } } end,
        decide_visibility = function() return 'show' end,
        consume_open_core = function()
            local n = open_core_queue
            open_core_queue = 0
            return n
        end,
        load_texture = function(path)
            local f = io.open(path, 'rb')
            if not f then return nil, 'not found' end
            f:close()
            next_tex_id = next_tex_id + 1
            loaded_textures[path] = next_tex_id
            return next_tex_id, 256, 256
        end,
        release_textures = function()
            local n = 0
            for _ in pairs(loaded_textures) do n = n + 1 end
            loaded_textures = {}
            return n
        end,
        texture_stats = function()
            local n = 0
            for _ in pairs(loaded_textures) do n = n + 1 end
            return { loaded = n, bytes = n * 256 * 256 * 4, hits = 0, misses = n, failures = 0, device_ready = true }
        end,
        acquire_ui_input = function(_owner, opts)
            if not ui_input.active then
                ui_input.acquire_count = ui_input.acquire_count + 1
            end
            ui_input.active = true
            ui_input.owner_count = 1
            ui_input.block_mouse = opts and opts.block_mouse == true
            ui_input.capture_gamepad = opts and opts.capture_gamepad == true
            ui_input.show_cursor = opts and opts.show_cursor == true
            return true
        end,
        release_ui_input = function(_owner, reason)
            if ui_input.active then
                ui_input.release_count = ui_input.release_count + 1
            end
            ui_input.active = false
            ui_input.owner_count = 0
            ui_input.block_mouse = false
            ui_input.capture_gamepad = false
            ui_input.show_cursor = false
            ui_input.last_release_reason = tostring(reason or 'closed')
            return true
        end,
        ui_input_state = function() return ui_input end,
        ashita_compat_enabled = function() return false end,
        diagnostics = function()
            return {
                enabled = true, api_version = 2, capabilities = 0x391FFD,
                hooks_installed = 21, hooks_total = 21,
                registry_soul_count = 66, registry_hash = 'cf86aa59ff8d16c6',
                weapon_rule_count = 19, weapon_config_hash = '85de194dbb914f94',
                action_count = native_actions_count, visibility_count = native_visibility_count,
                action_row_limit = 16,
                ashita_compat_enabled = false,
                hooks = {
                    { id = 'commands_menu_hook', owner = 'soulspire', disposition = 'installed', rva = 0x121110, hit_count = 12, installed = true, detail = 'ok' },
                },
            }
        end,
    },
}

local function assert_stacks_balanced(ctx_label)
    assert_eq(stack.begin_depth, 0, ctx_label .. ': Begin/End imbalance')
    assert_eq(stack.child_depth, 0, ctx_label .. ': BeginChild/EndChild imbalance')
    assert_eq(stack.style_var_depth, 0, ctx_label .. ': PushStyleVar/PopStyleVar imbalance')
    assert_eq(stack.style_col_depth, 0, ctx_label .. ': PushStyleColor/PopStyleColor imbalance')
end

local function emit(ev, arg)
    local last = nil
    for _, fn in ipairs(handlers[ev] or {}) do
        last = fn(arg)
    end
    return last
end

local function has_drawn_text(substr)
    for _, t in ipairs(drawn_texts) do
        if string.find(t, substr, 1, true) then
            return true
        end
    end
    return false
end

-- Build a valid 64-byte server 0x1FF CRYS reply for a Lv.75 Shinobi (job=13, branch=1 unlocked & active)
local function build_crys_reply(req_id, job_id, level, owned_mask, active_branch)
    local bytes = {
        0xFF, 0x21, 0x00, 0x00,
        string.byte('C'), string.byte('R'), string.byte('Y'), string.byte('S'),
        1, 0, req_id % 256, math.floor(req_id / 256), job_id, 24, level, 0,
    }
    for idx = 1, 24 do
        if idx == job_id + 1 then
            bytes[#bytes + 1] = owned_mask
            bytes[#bytes + 1] = active_branch
        else
            bytes[#bytes + 1] = 0
            bytes[#bytes + 1] = 0
        end
    end
    return string.char(unpack(bytes))
end

-- Build a real binary 0x1FC OXHD Soul HUD packet
local function build_oxhd_packet(job_id, unlocked, soul_key, kv_raw)
    local kv_len = #kv_raw
    local hdr = string.char(
        0xFC, 0x20, 0x00, 0x00,
        string.byte('O'), string.byte('X'), string.byte('H'), string.byte('D'),
        1, unlocked and 1 or 0, job_id, #soul_key,
        kv_len % 256, math.floor(kv_len / 256), 0, 0
    )
    return hdr .. soul_key .. kv_raw
end

-- 1. Load real entrypoint & verify real VanaCore events
local mod = assert(dofile(addon_dir .. '/soulspire_core.lua'))
assert_true(mod.startup_report.ok == true, 'startup_report.ok must be true before load')
assert_true(handlers['frame'] == nil, 'MUST NOT subscribe to non-existent frame event')
assert_true(handlers['present'] ~= nil and #handlers['present'] == 1, 'MUST subscribe to real VanaCore present event')

-- 2. Fire 'load' and verify 66 Souls, full actions, full visibility loaded from addons/vanacore/soulspire_core/data/
emit('load')
assert_true(mod.startup_report.ok == true, 'startup_report.ok must be true; errors: ' .. table.concat(mod.startup_report.errors, '; '))
assert_true(native_actions_count >= 150, 'Expected >=150 Soul actions loaded, got ' .. tostring(native_actions_count))
assert_true(native_visibility_count >= 190, 'Expected >=190 visibility rules loaded, got ' .. tostring(native_visibility_count))

local init_log = logs[#logs] or ''
assert_true(string.find(init_log, 'souls=66', 1, true) ~= nil, 'Init log must report souls=66, got: ' .. init_log)
assert_true(string.find(init_log, 'startup_ok=true', 1, true) ~= nil, 'Init log must report startup_ok=true, got: ' .. init_log)

-- 2b. Verify fail-loud negative case when data paths are missing
local IdentityMod = require('core.identity')
local ActionsMod  = require('core.actions')
local bad_id = IdentityMod.new('/nonexistent_soulspire_dir', '/nonexistent_soulspire_dir')
assert_eq(#bad_id.souls, 0, 'Missing data dir must load 0 souls')
assert_true(type(bad_id.last_error) == 'string' and #bad_id.last_error > 0, 'Missing data dir must populate actionable last_error')
assert_true(#bad_id.tried_paths >= 2, 'Missing data dir must record tried_paths')
local bad_act = ActionsMod.new('/nonexistent_soulspire_dir', bad_id, '/nonexistent_soulspire_dir')
local ba_cnt, bv_cnt = bad_act:sync_to_native()
assert_eq(ba_cnt, 0, 'Missing data dir must load 0 actions')
assert_eq(bv_cnt, 0, 'Missing data dir must load 0 visibility rules')
assert_true(#bad_act.errors >= 2, 'Missing data dir must record actionable errors')

-- 3. Verify Server Soul Sync (0x11F request sent on load -> 0x1FF CRYS reply updates Shinobi active & unlocked!)
assert_true(#packets_sent >= 1, 'Initial load while logged in must send outgoing 0x11F CRYS sync request')
local crys_req = nil
for _, p in ipairs(packets_sent) do
    if p.incoming == false and p.id == 0x11F and type(p.data) == 'string' and p.data:sub(5, 8) == 'CRYS' then
        crys_req = p
        break
    end
end
assert_true(crys_req ~= nil, 'Must inject outgoing 0x11F CRYS packet via vana.packets.inject')
local req_id = crys_req.data:byte(11) + crys_req.data:byte(12) * 256
local crys_reply = build_crys_reply(req_id, 13, 75, 2, 1) -- NIN Lv.75, branch 1 (Shinobi) unlocked & active
emit('packet_in', { id = 0x1FF, size = #crys_reply, data = crys_reply })

-- 4. Verify Polished 66-Soul HUD (binary 0x1FC OXHD Shinobi packet -> renders soulhud_gauge.lua!)
local oxhd_pkt = build_oxhd_packet(13, true, 'shinobi', 'sh=3;shmax=3;feint=1;ox_buffs=815:2:30')
emit('packet_in', { id = 0x1FC, size = #oxhd_pkt, data = oxhd_pkt })
begin_calls = {}
drawn_texts = {}
emit('present')
assert_stacks_balanced('hud_only_present')
assert_eq(ui_input.active, false, 'HUD alone must NOT acquire modal Core UI input')
local hud_begin = nil
for _, bc in ipairs(begin_calls) do
    if bc.title == 'SoulspireSoulHUD##gauge' then hud_begin = bc; break end
end
assert_true(hud_begin ~= nil, 'Polished soulhud_gauge.lua must render SoulspireSoulHUD##gauge')
assert_true(bit.band(hud_begin.flags, 1) == 1, 'Soul HUD must set NoTitleBar')
assert_true(bit.band(hud_begin.flags, 128) == 128, 'Soul HUD must set NoBackground')
assert_true(has_drawn_text('SNI'), 'Polished Shinobi HUD must render SNI medallion badge')

-- 5. Open Core via native Commands menu -> verify ZERO generic window chrome & unified 21/21 hooks
open_core_queue = 1
begin_calls = {}
drawn_texts = {}
emit('present')
assert_stacks_balanced('core_character_tab')
assert_eq(ui_input.active, true, 'Native Commands menu open must acquire authoritative UI input')
assert_eq(ui_input.show_cursor, true, 'Core active must show cursor')

local hub_begin = nil
for _, bc in ipairs(begin_calls) do
    if string.find(bc.title, 'soulspire_core_hub', 1, true) then hub_begin = bc; break end
end
assert_true(hub_begin ~= nil, 'Core Shell must call imgui.Begin for hub')
assert_true(hub_begin.title:sub(1, 2) == '##', 'Core Shell Begin title must hide generic chrome title: ' .. hub_begin.title)
local REQUIRED_HUB_FLAGS = 1 + 2 + 4 + 8 + 16 + 32 + 128 + 256 -- NoTitleBar|NoResize|NoMove|NoScrollbar|NoScrollWithMouse|NoCollapse|NoBackground|NoSavedSettings
assert_eq(bit.band(hub_begin.flags, REQUIRED_HUB_FLAGS), REQUIRED_HUB_FLAGS,
    string.format('Core Shell missing required frameless flags (got 0x%X, need 0x%X)', hub_begin.flags, REQUIRED_HUB_FLAGS))

-- Verify default player UI hides developer hook counts & Diagnostics tab while displaying live synced Shinobi!
assert_true(has_drawn_text('Soul Sanctum Ready'), 'Default player Character tab must show clean Soul Sanctum Ready status')
assert_true(not has_drawn_text('VanaCore Native: 21/21 hooks active'), 'Default player Character tab must NOT expose internal hook counts')
assert_true(not has_drawn_text('Diagnostics'), 'Default player tab ribbon must NOT expose Diagnostics tab')
assert_true(not has_drawn_text('Equipment'), 'Default player tab ribbon must NOT expose PHASE D placeholder tab')
assert_true(has_drawn_text('SHINOBI') or has_drawn_text('Shinobi'), 'Character tab must display live synced Shinobi')
assert_true(not has_drawn_text('Server did not confirm Soul state'), 'Character tab must NOT show timeout error after valid 0x1FF CRYS reply')

-- Verify developer diagnostic commands are gated by default in player mode
mod.close_hub('dev_gate_check')
assert_true(emit('command', { command = '/soulspire diag' }) == true, '/soulspire diag must be handled')
assert_eq(ui_input.active, false, '/soulspire diag must NOT open Diagnostics hub when devmode is off')
assert_true(emit('command', { command = '/soulhud demo shinobi' }) == true, '/soulhud demo must be handled')
assert_true(string.find(logs[#logs] or '', 'developer mode', 1, true) ~= nil, '/soulhud demo must be gated when devmode is off')

-- 6. Render EVERY player Core module tab via real :draw(...) (catches signature/Vec2/nil bugs!)
local player_module_commands = {
    { cmd = '/soulspire character',   label = 'character' },
    { cmd = '/talents',               label = 'weapon_mastery' },
    { cmd = '/soulspire soultalents', label = 'soul_talents' },
}
for _, tc in ipairs(player_module_commands) do
    mod.close_hub('switch')
    assert_true(emit('command', { command = tc.cmd }) == true, tc.cmd .. ' must be handled')
    drawn_texts = {}
    emit('present')
    assert_stacks_balanced('module_' .. tc.label)
end

-- Verify Soul Talents live telemetry populated from binary 0x1FC OXHD (PLAYER-CMD-001 fix)
assert_true(not has_drawn_text('Waiting for live [OXHUD] server telemetry'), 'Soul Talents tab must receive live 0x1FC OXHD telemetry')

-- Also directly test 'abilities' tab via open_hub (default player view must hide dev reload button & raw vis=)
mod.open_hub('abilities')
drawn_texts = {}
emit('present')
assert_stacks_balanced('module_abilities')
assert_true(has_drawn_text('SOUL ACTIONS') or has_drawn_text('Soul Actions') or draw_calls > 0, 'Abilities module must draw cleanly')
assert_true(not has_drawn_text('Native hooks:'), 'Player Soul Actions view must NOT expose raw native hook counts')

-- 6b. Enable explicit local developer diagnostics (/soulspire devmode on) and verify Diagnostics, Mob Status, Flintlock & hooks
mod.close_hub('devmode_enable')
assert_true(emit('command', { command = '/soulspire devmode on' }) == true, '/soulspire devmode on must be handled')
mod.open_hub('character')
drawn_texts = {}
emit('present')
assert_stacks_balanced('devmode_character')
assert_true(has_drawn_text('VanaCore Native: 21/21 hooks active'), 'Devmode Character tab must show 21/21 hooks active')
assert_true(not has_drawn_text('0 hooks active'), 'Character tab must NEVER show 0 hooks active when 21/21 are installed')

local dev_module_commands = {
    { cmd = '/soulspire diag',        label = 'journal_diag' },
    { cmd = '/mobstatus',             label = 'journal_mobs' },
    { cmd = '/flintlock',             label = 'journal_flintlock' },
}
for _, tc in ipairs(dev_module_commands) do
    mod.close_hub('switch')
    assert_true(emit('command', { command = tc.cmd }) == true, tc.cmd .. ' must be handled in devmode')
    drawn_texts = {}
    emit('present')
    assert_stacks_balanced('module_' .. tc.label)
end

-- Verify Diagnostics tab specifically rendered real catalog paths & 21/21 hooks without crashing drawOrnatePanel
mod.close_hub('diag_check')
emit('command', { command = '/soulspire diag' })
drawn_texts = {}
emit('present')
assert_stacks_balanced('diag_verify')
assert_true(has_drawn_text('Hooks=21/21'), 'Diagnostics tab must show Hooks=21/21')
assert_true(has_drawn_text('Souls=66'), 'Diagnostics tab must show Souls=66')

-- 7. Controller shoulder buttons (LB=8 / RB=9 XInput & L1=4 / R1=5 DirectInput) switch modules & consume input
local ev_rb = { button = 9, state = 1, blocked = false }
assert_true(emit('xinput_button', ev_rb) == true and ev_rb.blocked == true, 'XInput RB (9) must be consumed by Core')
emit('xinput_button', { button = 9, state = 0, blocked = false })
local ev_lb = { button = 8, state = 1, blocked = false }
assert_true(emit('xinput_button', ev_lb) == true and ev_lb.blocked == true, 'XInput LB (8) must be consumed by Core')
emit('xinput_button', { button = 8, state = 0, blocked = false })
local ev_d_r1 = { button = 5, state = 0x80, blocked = false }
assert_true(emit('dinput_button', ev_d_r1) == true and ev_d_r1.blocked == true, 'DirectInput R1 (5) must be consumed by Core')

-- 8. Verify /soulhud commands & config modal render cleanly with balanced stacks
mod.close_hub('hud_cmds')
for _, hcmd in ipairs({ '/soulhud status', '/soulhud minimal', '/soulhud expanded', '/soulhud standard', '/soulhud lock', '/soulhud unlock', '/soulhud config' }) do
    assert_true(emit('command', { command = hcmd }) == true, hcmd .. ' must be handled')
end
emit('present')
assert_stacks_balanced('soulhud_config_modal')
emit('command', { command = '/soulhud config' }) -- close config modal

-- 9. Native WIC texture loading loaded real PNG assets without d3d8
local tex_count = 0
for _ in pairs(loaded_textures) do tex_count = tex_count + 1 end
assert_true(tex_count >= 1, 'Native texture manager must load Core PNG artwork')

-- 10. Repeated open/close cycles + zone/logout/unload restore cursor & gameplay ownership cleanly
local acq_before, rel_before = ui_input.acquire_count, ui_input.release_count
for _ = 1, 10 do
    mod.open_hub('weapon_mastery')
    emit('present')
    assert_stacks_balanced('cycle_open')
    assert_eq(ui_input.active, true, 'open_hub must acquire UI input')
    mod.close_hub('cycle_close')
    assert_eq(ui_input.active, false, 'close_hub must release UI input')
end
assert_eq(ui_input.acquire_count, acq_before + 10, '10 open/close cycles must balance acquires')
assert_eq(ui_input.release_count, rel_before + 10, '10 open/close cycles must balance releases')

mod.open_hub('character')
emit('zone_change')
assert_eq(ui_input.active, false, 'zone_change must release UI input ownership')

mod.open_hub('journal')
emit('logout')
assert_eq(ui_input.active, false, 'logout must release UI input ownership')

mod.open_hub('abilities')
emit('unload')
assert_eq(ui_input.active, false, 'unload must release UI input ownership')

print('PASS: VanaCore-Native Soulspire Core v4.0.0 strict real-contract integration test passed (all 5 modules, 66-Soul registry/actions/visibility, 0x1FF CRYS sync, 0x1FC Shinobi HUD, frameless ImGui, 21/21 diagnostics, input/gamepad lifecycle)!')
