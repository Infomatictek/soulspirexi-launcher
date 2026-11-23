-- SoulspireXI Core — Comprehensive LuaJIT Unit, Gamepad & Headless Render Test Suite.
-- Run from addons/ashita4/soulspire_core: luajit tests/soulspire_core_test.lua

package.path = './?.lua;./?/init.lua;../soulspire_talents/?.lua;../crystalsocket/?.lua;' .. package.path

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

-- Mock ImGui + DrawList for headless rendering across all modules and resolutions
local mockDisplay = { x = 1920, y = 1080 }
local drawn_texts = {}
local draw_count = 0
local click_next_btn = nil
local cursorX, cursorY = 0, 0

local mock_dl = {
    AddRectFilled           = function() draw_count = draw_count + 1 end,
    AddRect                 = function() draw_count = draw_count + 1 end,
    AddRectFilledMultiColor = function() draw_count = draw_count + 1 end,
    AddLine                 = function() draw_count = draw_count + 1 end,
    AddQuadFilled           = function() draw_count = draw_count + 1 end,
    AddQuad                 = function() draw_count = draw_count + 1 end,
    AddCircleFilled         = function() draw_count = draw_count + 1 end,
    AddCircle               = function() draw_count = draw_count + 1 end,
    AddTriangleFilled       = function() draw_count = draw_count + 1 end,
    AddImage                = function() draw_count = draw_count + 1 end,
    AddText                 = function(_, _, _, s)
        draw_count = draw_count + 1
        drawn_texts[#drawn_texts + 1] = tostring(s or '')
    end,
}

local mock_imgui = {
    GetIO              = function() return { DisplaySize = mockDisplay } end,
    SetNextWindowPos   = function() end,
    SetNextWindowSize  = function() end,
    PushStyleVar       = function() end,
    PopStyleVar        = function() end,
    PushStyleColor     = function() end,
    PopStyleColor      = function() end,
    PushTextWrapPos    = function() end,
    PopTextWrapPos     = function() end,
    SetCursorScreenPos = function(p) cursorX, cursorY = p[1], p[2] end,
    GetCursorScreenPos = function() return cursorX, cursorY end,
    GetWindowPos       = function() return 40, 40 end,
    GetWindowDrawList  = function() return mock_dl end,
    Begin              = function() return true end,
    End                = function() end,
    BeginChild         = function() return true end,
    EndChild           = function() end,
    InvisibleButton    = function(id) return id == click_next_btn end,
    IsItemHovered      = function() return false end,
    IsItemClicked      = function() return false end,
    IsWindowHovered    = function() return false end,
    IsMouseDragging    = function() return false end,
    PushItemWidth      = function() end,
    PopItemWidth       = function() end,
    BeginCombo         = function() return false end,
    EndCombo           = function() end,
    InputText          = function() return false end,
    Checkbox           = function() return false end,
    Dummy              = function() end,
    SetWindowFontScale = function() end,
    CalcTextSize       = function(s) return #tostring(s or '') * 7, 14 end,
    TextUnformatted    = function(s) drawn_texts[#drawn_texts + 1] = tostring(s or '') end,
}

package.loaded['imgui'] = mock_imgui
package.loaded['art']   = { draw = function() return false end, get = function() return nil end, clear = function() end }

local Theme          = require('core.theme')
local Registry       = require('core.registry')
local MenuBridge     = require('core.menu_bridge')
local Focus          = require('core.focus')
local Input          = require('core.input')
local UI             = require('core.ui')
local WeaponMastery  = require('modules.weapon_mastery')
local SoulTalents    = require('modules.soul_talents')
local CharacterMod   = require('modules.character')
local soulforgeState = require('soulforge_state')
local soulforgeUI    = require('soulforge_ui')
local csProtocol     = require('protocol')
local csStateMod     = require('state')

-- =========================================================================
-- 1. Theme & Dynamic Core Registry Tests
-- =========================================================================
assert_true(Theme.u32.gold ~= 0, 'Theme gold ABGR should be non-zero')
assert_true(Theme.u32.bg_primary ~= Theme.u32.bg_card, 'Primary and card backgrounds must differ')

local reg = Registry.new()
local expected_order = {
    { id = 'character',      label = 'Character',      available = true  },
    { id = 'weapon_mastery', label = 'Weapon Mastery', available = true  },
    { id = 'soul_talents',   label = 'Soul Talents',   available = true  },
    { id = 'abilities',      label = 'Abilities',      available = false },
    { id = 'equipment',      label = 'Equipment',      available = false },
    { id = 'journal',        label = 'Journal',        available = false },
}
assert_eq(reg:count(), #expected_order, 'Default Core registry count')
for i, exp in ipairs(expected_order) do
    local m = reg:get(i)
    assert_eq(m.id, exp.id, 'Module id at ' .. i)
    assert_eq(m.label, exp.label, 'Module label at ' .. i)
    assert_eq(m.available, exp.available, 'Module availability at ' .. i)
    assert_true(type(m.icon) == 'string' and m.icon ~= '', 'Module must provide icon')
end
assert_eq(#reg:available_modules(), 3, 'Exactly 3 live modules initially integrated')
assert_eq(reg:find_index('soulforge'), 2, 'Alias lookup for soulforge')
assert_eq(reg:find_index('crystals'), 1, 'Alias lookup for crystals')
assert_eq(reg:find_index('talents'), 3, 'Alias lookup for talents')

-- Dynamic registration preserves order sorting & extensibility
reg:register({ id = 'custom_ext', label = 'Expeditions', icon = 'journal', order = 25, available = true })
assert_eq(reg:count(), 7, 'Dynamic module registration increments count')
assert_eq(reg:get(3).id, 'custom_ext', 'Dynamic module sorted by order=25 between 20 and 30')
assert_true(reg:unregister('custom_ext'), 'Dynamic unregister removes module')
assert_eq(reg:count(), 6, 'Unregister restores count')

-- Step index with and without skipping unavailable modules
assert_eq(reg:step_index(3, 1, false), 4, 'Step forward includes unavailable when skip=false')
assert_eq(reg:step_index(3, 1, true), 1, 'Step forward wraps over unavailable when skip=true')
assert_eq(reg:step_index(1, -1, true), 3, 'Step backward wraps over unavailable when skip=true')

-- =========================================================================
-- 2. Native Menu Bridge & Failure Handling Tests
-- =========================================================================
local function make_mock_memory(form_name, rect, cursor)
    local OPERAND = 0x10000000
    local STORAGE = 0x10001054
    local MANAGER = 0x10001000
    local NODE    = 0x10002000
    local WINDOW  = 0x10003000
    local FORM    = 0x10004000

    local u32_mem = {
        [OPERAND]        = STORAGE,
        [MANAGER]        = NODE,
        [MANAGER + 0x54] = WINDOW,
        [NODE]           = 0,
        [NODE + 0x10]    = WINDOW,
        [WINDOW + 4]     = FORM,
        [WINDOW + 0x10]  = 1,
    }
    local u8_mem = {
        [NODE + 0x14]    = 0,
        [WINDOW + 0x69]  = 1,
        [WINDOW + 0x6E]  = 0,
        [WINDOW + 0x70]  = 0,
    }
    local i16_mem = {
        [WINDOW + 0x3A] = rect.left,
        [WINDOW + 0x3C] = rect.top,
        [WINDOW + 0x3E] = rect.right,
        [WINDOW + 0x40] = rect.bottom,
        [WINDOW + 0x4C] = cursor or 1,
    }
    local str_mem = {
        [FORM + 70] = form_name,
    }

    return {
        read_uint32 = function(a) return u32_mem[a] or 0 end,
        read_uint8  = function(a) return u8_mem[a] or 0 end,
        read_int16  = function(a) return i16_mem[a] or 0 end,
        read_string = function(a) return str_mem[a] or '' end,
    }, OPERAND
end

local scaling = {
    menu   = { w = 1280, h = 720 },
    scaled = { w = 1920, h = 1080 },
    scale_w = function(v) return v * 1.5 end,
    scale_h = function(v) return v * 1.5 end,
}

-- Graceful native hook probe failure -> native-styled-fallback
local mem1, op1 = make_mock_memory('menu    mnu1    ', { left = 20, top = 40, right = 140, bottom = 240 }, 3)
local bridge1 = MenuBridge.new(mem1, scaling, op1, {
    native_probe = function() return false, 'unsupported on test host' end,
})
assert_true(bridge1:is_available(), 'MenuBridge available on valid MenuManager')
assert_eq(bridge1:get_mode(), 'native-styled-fallback', 'Unsupported native hook falls back cleanly')
local ctx1 = bridge1:main_menu_context()
assert_true(ctx1 ~= nil, 'Main menu mnu1 detected')
assert_eq(ctx1.name, 'menu    mnu1', 'Form name trimmed')
assert_eq(ctx1.dock.x, 30, 'Dock x scaled')
assert_eq(ctx1.dock.y, 366, 'Dock y scaled')
assert_eq(ctx1.dock.w, 180, 'Dock w scaled')

-- Native hook probe throwing error fails gracefully (never crashes)
local bridge_throw = MenuBridge.new(mem1, scaling, op1, {
    native_probe = function() error('simulated dll error') end,
})
assert_eq(bridge_throw:get_mode(), 'native-styled-fallback', 'Throwing probe degrades gracefully')

-- Verified retail FFXI Main Menu form ("menu    menuwind" at right edge 1792..1904)
local mem_mw, op_mw = make_mock_memory('menu    menuwind', { left = 1792, top = 48, right = 1904, bottom = 250 }, 1)
local scaling_1080 = { menu = { w = 1920, h = 1080 }, scaled = { w = 1920, h = 1080 }, scale_w = function(v) return v end, scale_h = function(v) return v end }
local bridge_mw = MenuBridge.new(mem_mw, scaling_1080, op_mw, { native_probe = function() return false end })
local ctx_mw = bridge_mw:main_menu_context()
assert_true(ctx_mw ~= nil and ctx_mw.name == 'menu    menuwind', 'Retail FFXI menu    menuwind must be detected')
assert_eq(ctx_mw.dock.x, 1748, 'Right-edge menuwind dock flush-aligned to right=1904 (1904-156=1748)')
assert_eq(ctx_mw.dock.y, 254, 'Dock positioned 4px below menuwind bottom=250')

-- Equipment menu strictly excluded (zero interference with crystalsocket & Hook #24)
local mem_eq, op_eq = make_mock_memory('menu    equip   ', { left = 20, top = 40, right = 200, bottom = 260 }, 1)
local bridge_eq = MenuBridge.new(mem_eq, scaling, op_eq, { native_probe = function() return false end })
assert_eq(bridge_eq:main_menu_context(), nil, 'Equipment menu must NOT activate Soulspire Main Menu dock')

-- Invalid operand fails closed to standalone mode
local bridge_bad = MenuBridge.new(mem1, scaling, 0, { native_probe = function() return false end })
assert_eq(bridge_bad:is_available(), false, 'Invalid operand unavailable')
assert_eq(bridge_bad:get_mode(), 'standalone', 'Invalid operand degrades to standalone')
assert_eq(bridge_bad:main_menu_context(), nil, 'Invalid operand returns nil context')

-- =========================================================================
-- 3. Server State Synchronization + Initial Module Integration Tests
-- =========================================================================
local sent_talent_ops = {}
local fake_clock = 100.0
local sf_state, sf_actions = soulforgeState.new({
    soulRegistry = Registry.souls,
    clock        = function() return fake_clock end,
    sendPacket   = function(pktId, bytes, op, wsId, arg1, arg2)
        sent_talent_ops[#sent_talent_ops + 1] = { pktId = pktId, len = #bytes, op = op, wsId = wsId, arg1 = arg1, arg2 = arg2 }
        return true
    end,
})

-- Feed realistic server-authoritative [OXTAL]| packets
sf_actions.handleProtoLine('META|RDM|75|7|5|12|3|0|spellblade')
sf_actions.handleProtoLine('CAT_BEGIN')
sf_actions.handleProtoLine('CAT|42:3:Savage Blade:physical,34:3:Red Lotus Blade:magical,40:3:Vorpal Blade:physical')
sf_actions.handleProtoLine('CAT_END')
sf_actions.handleProtoLine('SPENT_BEGIN')
sf_actions.handleProtoLine('SPENT|42:3:1,34:2:1')
sf_actions.handleProtoLine('SPENT_END')
sf_actions.handleProtoLine('WS|42|Savage Blade|Sword|physical|3|Fragmentation')
sf_actions.handleProtoLine('NODE|42|sb_t1_a|1|1|2|5|1|0||0|Blade Mastery|Increases Savage Blade potency.|1|0|0||1')
sf_actions.handleProtoLine('NODE|42|sb_t1_b|1|2|1|5|1|0||0|Keen Edge|Increases critical hit rate.|1|0|0||1')
sf_actions.handleProtoLine('NODE|42|sb_t2_a|2|1|0|5|1|2|sb_t1_a|2|Aether Cleave|Adds resonant blade echo.|20|0|0||1')
sf_actions.handleProtoLine('NODE|42|sb_t2_b|2|2|0|5|0|10|sb_t1_b|3|Deep Cut|Locked high-tier node.|20|0|0||1')
sf_actions.handleProtoLine('NODE|42|sc_t1|1|4|1|1|0|0||0|SC 1|Skillchain 1|1|1|1|Impaction|1')
sf_actions.handleProtoLine('NODE|42|sc_t2|2|4|0|1|1|2||0|SC 2|Skillchain 2|5|2|0||1')
sf_actions.handleProtoLine('WS_END|42|7|1')

assert_eq(sf_state.synced, true, 'Soulforge state synced from server')
assert_eq(sf_state.jobKey, 'RDM', 'Job key synced')
assert_eq(sf_state.avail, 7, 'Available talent points synced')
assert_eq(sf_state.wsDetail.id, 42, 'WS detail loaded')
assert_eq(#sf_state.catalog, 3, 'WS catalog count')

-- Server rejection preserves authoritative rank untouched
sf_actions.investNode(42, sf_state.wsDetail.byKey.sb_t2_a)
assert_eq(sent_talent_ops[#sent_talent_ops].op, soulforgeState.OP_INVEST, 'OP_INVEST sent')
assert_true(sf_state.pendingOp ~= nil, 'Pending op blocks duplicate clicks')
sf_actions.handleProtoLine('ERR|Insufficient level on server.')
assert_eq(sf_state.pendingOp, nil, 'ERR clears pending op')
assert_eq(sf_state.wsDetail.byKey.sb_t2_a.rank, 0, 'Authoritative rank untouched on server rejection')

-- Build Character / Soul Identity module with CrystalSocket state & mock packets
local cs_state = csStateMod.new()
local sent_crystal_packets = {}
local char_mod = CharacterMod.new({
    protocol      = csProtocol,
    crystal_state = cs_state,
    soul_registry = Registry.souls,
    clock         = function() return fake_clock end,
    send_packet   = function(pkt)
        sent_crystal_packets[#sent_crystal_packets + 1] = pkt
        return true
    end,
    player_ctx_fn = function()
        return { name = 'Aelindra', server_id = 12345, zone = 230, main_job = 5, main_lvl = 75, sub_job = 3, sub_lvl = 37 }
    end,
    dll_status_fn = function()
        return { enabled = 1, hooks = 24, job = 5, known = 1, branch = 1 }
    end,
})

char_mod:on_open()
assert_true(#sent_crystal_packets == 1, 'Character module sent initial CrystalSocket sync')
-- Verify non-colliding request_id >= 0x4000
local req_b = { sent_crystal_packets[1]:byte(1, 16) }
local req_id = req_b[11] + req_b[12] * 256
assert_true(req_id >= 0x4000 and req_id < 0x8000, 'Core crystal request_id in isolated 0x4000..0x7FFF range')

-- Feed synthetic authoritative 0x1FF CRYC catalog packets + CRYS state reply
-- (RDM=5, owns branches 1+2 = mask 0x06, active = 1)
local function make_cryc(cat_kind, r_id, job_id, branch_id, idx, req_lvl, text)
    local t = text or ''
    return string.char(0xff, 0x21, 0, 0) .. 'CRYC'
        .. string.char(1, cat_kind, r_id % 256, math.floor(r_id / 256), job_id, branch_id, idx, req_lvl, 0, 0, #t % 256, math.floor(#t / 256))
        .. t
end
assert_true(char_mod:handle_packet_in(csProtocol.RESPONSE_ID, make_cryc(csProtocol.CATALOG_BEGIN, req_id, 5, 0, 0, 0, 'Red Mage'), fake_clock))
assert_true(char_mod:handle_packet_in(csProtocol.RESPONSE_ID, make_cryc(csProtocol.CATALOG_ENTRY, req_id, 5, 1, 1, 1, 'crimsonduelist\31Crimson Duelist\31Tank\31crimsonduelist\31Barrier fencer.'), fake_clock))
assert_true(char_mod:handle_packet_in(csProtocol.RESPONSE_ID, make_cryc(csProtocol.CATALOG_ENTRY, req_id, 5, 2, 2, 1, 'royaltactician\31Royal Tactician\31Support\31royaltactician\31Tactical mage.'), fake_clock))
assert_true(char_mod:handle_packet_in(csProtocol.RESPONSE_ID, make_cryc(csProtocol.CATALOG_END, req_id, 5, 0, 0, 0, ''), fake_clock))

local entries_bytes = {}
for j = 0, 23 do
    if j == 5 then
        entries_bytes[#entries_bytes + 1] = string.char(0x06, 1) -- owns branches 1 & 2, active = 1
    else
        entries_bytes[#entries_bytes + 1] = string.char(0, 0)
    end
end
local reply_pkt = string.char(0xff, 0x21, 0, 0) .. 'CRYS'
    .. string.char(1, 0, req_id % 256, math.floor(req_id / 256), 5, 24, 75, 0)
    .. table.concat(entries_bytes)
assert_eq(#reply_pkt, 64, 'Synthetic CRYS reply length is 64')
assert_true(char_mod:handle_packet_in(csProtocol.RESPONSE_ID, reply_pkt, fake_clock), 'Character module accepted CRYS reply')
local header_id = char_mod:get_header_identity()
assert_eq(header_id.job_key, 'RDM', 'Header identity job key')
assert_eq(header_id.job_level, 75, 'Header identity level')
assert_eq(header_id.branch, 1, 'Header identity active branch')

-- Build Weapon Mastery & Soul Talents modules and attach all 3 to Core Registry
local focus = Focus.new(reg)
local wm_mod = WeaponMastery.new(sf_state, sf_actions, soulforgeUI)
local st_mod = SoulTalents.new(sf_state, sf_actions, soulforgeUI, {
    soul_registry = Registry.souls,
    on_jump_to_ws = function(ws_id, node_key)
        focus:select_module('weapon_mastery')
        wm_mod:focus_ws_and_node(ws_id, node_key)
    end,
})
st_mod:observe_hud_line('crimsonduelist|barrier=100|hex=3', fake_clock)

reg:attach_controller('character', char_mod, true)
reg:attach_controller('weapon_mastery', wm_mod, true)
reg:attach_controller('soul_talents', st_mod, true)

-- =========================================================================
-- 4. Opening/Closing Core, Module Switching & Full Gamepad Navigation Tests
-- =========================================================================
local inp = Input.new({ clock = function() return fake_clock end })
local function dispatch(action) return focus:handle_action(action, ctx1) end

-- Unowned native Main Menu inputs MUST pass through to FFXI
assert_eq(inp:on_pad('xinput', 1, true, dispatch, focus:is_hub_open()), false, 'D-Pad Down passes through to native Main Menu')
assert_eq(inp:on_pad('xinput', 1, false, dispatch, focus:is_hub_open()), false)

-- LB on FFXI Main Menu focuses Soulspire dock; A opens Core Hub
assert_eq(inp:on_pad('xinput', 8, true, dispatch, focus:is_hub_open()), true, 'LB focuses Soulspire dock')
assert_eq(inp:on_pad('xinput', 8, false, dispatch, focus:is_hub_open()), true)
assert_eq(focus.dock_focused, true, 'Dock focused')
assert_eq(focus.hub_open, false, 'Hub not open yet')

assert_eq(inp:on_pad('xinput', 12, true, dispatch, focus:is_hub_open()), true, 'XInput A opens Core Hub')
assert_eq(inp:on_pad('xinput', 12, false, dispatch, focus:is_hub_open()), true)
assert_eq(focus.hub_open, true, 'Hub opened from dock')
assert_eq(focus:active_module().id, 'character', 'Initial module is Character')

-- Character module: D-Pad Down selects Soul branch 2 (owned, not active), A opens Confirm Socket modal, A confirms OP_SELECT!
local prev_cs_count = #sent_crystal_packets
assert_eq(focus:handle_action('down', ctx1), true) -- idx 2 (branch 1, active)
assert_eq(focus:handle_action('down', ctx1), true) -- idx 3 (branch 2, owned & inactive)
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(char_mod:has_modal(), true, 'Character confirm_socket modal opened')
-- While modal is open, LB/RB must NOT switch modules!
assert_eq(focus:handle_action('module_next', ctx1), true)
assert_eq(focus:active_module().id, 'character', 'LB/RB blocked during confirmation modal')
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(char_mod:has_modal(), false, 'Modal closed after confirm')
assert_eq(#sent_crystal_packets, prev_cs_count + 1, 'Authoritative CRYS OP_SELECT sent')

-- Switch module via RB (XInput 9) -> Weapon Mastery (The Soulforge)
assert_eq(inp:on_pad('xinput', 9, true, dispatch, focus:is_hub_open()), true, 'RB switches to Weapon Mastery')
assert_eq(inp:on_pad('xinput', 9, false, dispatch, focus:is_hub_open()), true)
assert_eq(focus:active_module().id, 'weapon_mastery', 'Active module is Weapon Mastery')

-- Weapon Mastery Gamepad Navigation: Arsenal -> Filter [X] -> Tree 2D Grid -> Skillchains -> Inspector -> Confirm Forge -> Execute!
sf_state.inspectedNodeKey = nil
wm_mod.node_key = nil
assert_eq(wm_mod.region, 'arsenal', 'Weapon Mastery starts in arsenal')
assert_eq(focus:handle_action('context', ctx1), true) -- cycle weapon filter
assert_eq(sf_state.selectedSkill, 0, 'X cycles filter from Equipped (-1) to All Weapons (0)')
assert_eq(focus:handle_action('down', ctx1), true)
assert_eq(wm_mod.arsenal_index, 2, 'D-Pad Down moves in Arsenal')
assert_eq(focus:handle_action('up', ctx1), true)
assert_eq(wm_mod.arsenal_index, 1, 'D-Pad Up moves in Arsenal')
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(wm_mod.region, 'tree', 'A from Arsenal focuses Talent Tree')
assert_eq(wm_mod.node_key, 'sb_t1_a', 'Initial focused node in Tier 1 Col 1')

-- 2D Tree navigation: Right -> sb_t1_b, Down -> sb_t2_b, Left -> sb_t2_a, Up -> sb_t1_a, Up -> skillchains!
assert_eq(focus:handle_action('right', ctx1), true)
assert_eq(wm_mod.node_key, 'sb_t1_b', 'Right moves to Tier 1 Col 2')
assert_eq(focus:handle_action('down', ctx1), true)
assert_eq(wm_mod.node_key, 'sb_t2_b', 'Down moves to Tier 2 Col 2')
assert_eq(focus:handle_action('left', ctx1), true)
assert_eq(wm_mod.node_key, 'sb_t2_a', 'Left moves to Tier 2 Col 1')
assert_eq(sf_state.inspectedNodeKey, 'sb_t2_a', 'Inspector tracks focused node live')
assert_eq(focus:handle_action('up', ctx1), true)
assert_eq(wm_mod.node_key, 'sb_t1_a', 'Up returns to Tier 1 Col 1')
assert_eq(focus:handle_action('up', ctx1), true)
assert_eq(wm_mod.region, 'skillchains', 'Up from Tier 1 enters Skillchain Forging slots')

-- Cycle skillchain with A (forward) and return Down to Tree
local prev_ops = #sent_talent_ops
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(sent_talent_ops[#sent_talent_ops].op, soulforgeState.OP_CYCLE_SC, 'A on skillchain slot sends OP_CYCLE_SC')
sf_state.pendingOp = nil -- simulate server ack
assert_eq(focus:handle_action('down', ctx1), true)
assert_eq(wm_mod.region, 'tree', 'Down from skillchains returns to Tree')

-- Press A on upgradeable node -> Inspector -> A opens Confirm Forge modal -> A executes OP_INVEST!
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(wm_mod.region, 'inspector', 'A on node focuses Inspector action')
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(wm_mod.region, 'confirm', 'A in Inspector opens deliberate Confirm Forge modal')
assert_eq(wm_mod:has_modal(), true, 'Confirm modal active')
assert_eq(focus:handle_action('right', ctx1), true)
assert_eq(wm_mod.confirm_btn, 2, 'Right selects Cancel')
assert_eq(focus:handle_action('left', ctx1), true)
assert_eq(wm_mod.confirm_btn, 1, 'Left selects Confirm')
prev_ops = #sent_talent_ops
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(#sent_talent_ops, prev_ops + 1, 'Confirm Forge sends OP_INVEST')
assert_eq(sent_talent_ops[#sent_talent_ops].op, soulforgeState.OP_INVEST, 'Sent OP_INVEST')
sf_state.pendingOp = nil

-- Press Y (XInput 15) -> opens Help / Details overlay, B closes it
assert_eq(inp:on_pad('xinput', 15, true, dispatch, focus:is_hub_open()), true, 'Y opens Help overlay')
assert_eq(inp:on_pad('xinput', 15, false, dispatch, focus:is_hub_open()), true)
assert_eq(focus.help_open, true, 'Help overlay open')
assert_eq(inp:on_pad('xinput', 13, true, dispatch, focus:is_hub_open()), true, 'B closes Help overlay')
assert_eq(inp:on_pad('xinput', 13, false, dispatch, focus:is_hub_open()), true)
assert_eq(focus.help_open, false, 'Help overlay closed without closing Core')
assert_eq(focus.hub_open, true, 'Core still open')

-- RB -> Soul Talents -> A jumps straight back to Weapon Mastery focused on Savage Blade!
assert_eq(focus:handle_action('module_next', ctx1), true)
assert_eq(focus:active_module().id, 'soul_talents', 'RB switches to Soul Talents')
assert_eq(focus:handle_action('right', ctx1), true)
assert_eq(st_mod.region, 'nodes', 'Right enters invested talent nodes')
assert_eq(focus:handle_action('confirm', ctx1), true)
assert_eq(focus:active_module().id, 'weapon_mastery', 'A on Soul Talents node jumps to Weapon Mastery')

-- =========================================================================
-- 5. Strict Input Capture, Left Stick, Repeat, Configurable Bindings & Restoration
-- =========================================================================
-- While Hub is open, unmapped XInput Start button (4) MUST still be blocked from FFXI!
assert_eq(inp:on_pad('xinput', 4, true, dispatch, true), true, 'Unmapped XInput Start blocked while Hub open')
assert_eq(inp:on_pad('xinput', 4, false, dispatch, true), true)

-- Raw XINPUT_STATE filtering reads Left Stick AND zeroes modified gamepad state!
local raw_xi = { Gamepad = { wButtons = 0x1000, bLeftTrigger = 200, bRightTrigger = 200, sThumbLX = 28000, sThumbLY = 0, sThumbRX = 12000, sThumbRY = -12000 } }
local mod_xi = { Gamepad = { wButtons = 0x1000, bLeftTrigger = 200, bRightTrigger = 200, sThumbLX = 28000, sThumbLY = 0, sThumbRX = 12000, sThumbRY = -12000 } }
local stick_actions = {}
assert_eq(inp:filter_xinput_state(raw_xi, mod_xi, function(a) stick_actions[#stick_actions + 1] = a; return true end, true, 200.0), true)
assert_eq(stick_actions[1], 'right', 'Left Stick right triggers right navigation')
assert_eq(mod_xi.Gamepad.wButtons, 0, 'Modified wButtons zeroed while Hub open')
assert_eq(mod_xi.Gamepad.sThumbLX, 0, 'Modified sThumbLX zeroed so FFXI character does not walk')
assert_eq(mod_xi.Gamepad.sThumbRX, 0, 'Modified sThumbRX zeroed so FFXI camera does not rotate')
assert_eq(mod_xi.Gamepad.bLeftTrigger, 0, 'Modified bLeftTrigger zeroed')

-- Hold-to-repeat fires after repeat_delay (0.32s)
assert_eq(inp:tick(200.10, function(a) stick_actions[#stick_actions + 1] = a end, true), 0, 'No repeat before delay')
assert_eq(inp:tick(200.40, function(a) stick_actions[#stick_actions + 1] = a end, true), 1, 'Repeat fires after delay')
assert_eq(stick_actions[2], 'right', 'Repeated Left Stick action is right')

-- Neutral stick releases hysteresis cleanly
inp:on_left_stick(0, 0, function() end, true, 200.50)
assert_eq(inp.stick_dir, nil, 'Stick released cleanly')

-- Keyboard WASD movement blocked while Hub open (when not typing in chat/ImGui)
assert_eq(inp:on_key(17, true, false, dispatch, true, false), true, 'W key blocked from moving FFXI char while Hub open')
assert_eq(inp:on_key(17, false, false, dispatch, true, false), true)
assert_eq(inp:on_key(17, true, true, dispatch, true, false), false, 'W key passes through when FFXI chat is open')
inp:release_key(17)

-- Configurable bindings override & reset
assert_true(inp:set_binding('xinput', 'confirm', 6), 'Custom binding accepted')
assert_eq(inp.xinput_map[6], 'confirm', 'Custom XInput binding applied')
inp:reset_bindings()
assert_eq(inp.xinput_map[12], 'confirm', 'Default XInput A binding restored')

-- Closing Core restores normal FFXI controls immediately AND preserves active module!
focus:select_module('weapon_mastery')
focus:close_hub(ctx1)
assert_eq(focus.hub_open, false, 'Hub closed')
assert_eq(focus.dock_focused, true, 'Returned to dock while Main Menu still open')
focus:handle_action('cancel', ctx1)
assert_eq(focus.dock_focused, false, 'Returned fully to native FFXI Main Menu')
assert_eq(focus:owns_input(), false, 'Core no longer owns input')
-- Verify unmapped & mapped XInput buttons now pass through untouched to FFXI!
assert_eq(inp:on_pad('xinput', 12, true, dispatch, focus:is_hub_open()), false, 'XInput A restored to FFXI immediately')
assert_eq(inp:on_pad('xinput', 12, false, dispatch, focus:is_hub_open()), false)
assert_eq(inp:filter_xinput_state(raw_xi, mod_xi, dispatch, false, 201.0), false, 'xinput_state passes through when Hub closed')

-- Reopening Core preserves previously selected module (Weapon Mastery)
focus:open_hub(nil, false)
assert_eq(focus:active_module().id, 'weapon_mastery', 'Active module preserved across close/reopen')

-- Zone change / disconnect blurs everything cleanly
focus:blur_all('zone_change')
assert_eq(focus:owns_input(), false, 'Zone change clears all focus')

-- =========================================================================
-- 6. Headless Multi-Resolution Render Verification (All Modules + Unavailable + Help)
-- =========================================================================
local ui = UI.new(mock_imgui, reg, focus, nil, {
    get_identity = function() return char_mod:get_header_identity() end,
})

-- Clicking docked entry opens Hub
click_next_btn = '##soulspire_dock_btn'
ui:draw(ctx1, bridge1:get_mode())
assert_eq(ui.last_dock.visible, true, 'Main Menu dock rendered')
assert_eq(ui.last_dock.clicks, 1, 'Main Menu dock click recorded')
assert_eq(focus.hub_open, true, 'Clicking Main Menu dock opens Core Hub')
click_next_btn = nil

local resolutions = {
    { w = 1280, h = 720,  expectMode = 'focused' },
    { w = 1920, h = 1080, expectMode = 'balanced' },
    { w = 2560, h = 1440, expectMode = 'expanded' },
    { w = 3440, h = 1440, expectMode = 'expanded' },
}

for _, res in ipairs(resolutions) do
    mockDisplay.x, mockDisplay.y = res.w, res.h
    for _, mod_id in ipairs({ 'character', 'weapon_mastery', 'soul_talents', 'abilities' }) do
        focus:select_module(mod_id)
        draw_count = 0
        drawn_texts = {}
        ui:draw(ctx1, bridge1:get_mode())
        assert_eq(ui.last_layout.mode, res.expectMode, string.format('%dx%d mode', res.w, res.h))
        assert_true(draw_count > 40, string.format('%s rendered at %dx%d (%d draws)', mod_id, res.w, res.h, draw_count))
        local joined = table.concat(drawn_texts, '\n')
        assert_true(joined:find('SOULSPIREXI', 1, true) ~= nil, 'Brand rendered')
        if mod_id == 'abilities' then
            assert_true(joined:find('UNAVAILABLE', 1, true) ~= nil, 'Unavailable module explicitly labeled UNAVAILABLE')
        end
    end
end

-- Verify Help Overlay renders cleanly
focus:select_module('weapon_mastery')
focus.help_open = true
drawn_texts = {}
ui:draw(ctx1, bridge1:get_mode())
assert_true(table.concat(drawn_texts, '\n'):find('CONTROLS & DETAILS', 1, true) ~= nil, 'Help overlay rendered')
focus.help_open = false

-- Micro-benchmark: 200 headless frames of unified Core + Weapon Mastery at 2560x1440
mockDisplay.x, mockDisplay.y = 2560, 1440
local t0 = os.clock()
for _ = 1, 200 do
    ui:draw(ctx1, bridge1:get_mode())
end
local avgMs = ((os.clock() - t0) * 1000) / 200
print(string.format('SoulspireXI Core unified render: %.3f ms/frame avg over 200 frames at 2560x1440.', avgMs))
assert_true(avgMs < 5.0, 'Expected <5ms/frame headless LuaJIT render')

print('SoulspireXI Core Unified UI & Gamepad tests passed.')
