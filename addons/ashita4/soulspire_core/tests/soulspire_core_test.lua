-- SoulspireXI Core Phase 1A LuaJIT unit test suite.
-- Run from addons/ashita4/soulspire_core: luajit tests/soulspire_core_test.lua

package.path = './?.lua;./?/init.lua;' .. package.path

local Theme      = require('core.theme')
local Registry   = require('core.registry')
local MenuBridge = require('core.menu_bridge')
local Focus      = require('core.focus')
local Input      = require('core.input')
local UI         = require('core.ui')

-- 1. Theme checks
assert(Theme.u32.gold ~= 0, 'Theme gold ABGR should be non-zero')
assert(Theme.u32.bg_primary ~= Theme.u32.bg_card, 'Primary and card backgrounds must differ')
assert(Theme.layout.hub_width > Theme.layout.sidebar_width, 'Hub width must exceed sidebar width')

-- 2. Registry checks: exact 7 required Phase 1A sections
local reg = Registry.new()
local expected_labels = {
    'Soul Crystals',
    'Weapon Skill Talents',
    'Soul Mastery',
    'Combat Records',
    'Expeditions',
    'Player Guides',
    'Settings',
}
assert(reg:count() == #expected_labels, 'Expected 7 registered sections, got ' .. tostring(reg:count()))
for i, label in ipairs(expected_labels) do
    local sec = reg:get(i)
    assert(sec and sec.label == label, ('Section %d expected %q, got %q'):format(i, label, tostring(sec and sec.label)))
    assert(sec.badge == 'PLACEHOLDER', 'Phase 1A section must be clearly labeled PLACEHOLDER')
end
assert(reg:find_index('talents') == 2, 'Short key lookup for talents failed')
assert(reg:find_index('settings') == 7, 'ID lookup for settings failed')
assert(reg:find_index('Soul Crystals') == 1, 'Label lookup for Soul Crystals failed')

-- Modular override preserves order
local replaced_idx = reg:register({ id = 'ws_talents', label = 'Weapon Skill Talents', badge = 'LIVE' })
assert(replaced_idx == 2 and reg:count() == 7 and reg:get(2).badge == 'LIVE', 'Modular section replacement failed')
reg = Registry.new() -- fresh default registry

-- 3. MenuBridge read-only synthetic memory tests
local function make_mock_memory(form_name, rect, cursor)
    local OPERAND = 0x10000000
    local STORAGE = 0x10001054 -- manager = 0x10001000
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
    menu = { w = 1280, h = 720 },
    scaled = { w = 1920, h = 1080 },
    scale_w = function(v) return v * 1.5 end,
    scale_h = function(v) return v * 1.5 end,
}

-- Main Menu page 1 detected and scaled
local mem1, op1 = make_mock_memory('menu    mnu1    ', { left = 20, top = 40, right = 140, bottom = 240 }, 3)
local bridge1 = MenuBridge.new(mem1, scaling, op1)
assert(bridge1:is_available(), 'MenuBridge should be available for valid manager')
local ctx1 = bridge1:main_menu_context()
assert(ctx1 ~= nil, 'Main menu mnu1 must be detected')
assert(ctx1.name == 'menu    mnu1', 'Form name should be trimmed')
assert(ctx1.cursor == 3, 'Cursor index should be read')
assert(ctx1.dock.x == 30 and ctx1.dock.y == 366 and ctx1.dock.w == 180, 'Dock rect scaling mismatch')

-- Equipment menu must NOT trigger Main Menu dock (zero interference with crystalsocket)
local mem_eq, op_eq = make_mock_memory('menu    equip   ', { left = 20, top = 40, right = 200, bottom = 260 }, 1)
local bridge_eq = MenuBridge.new(mem_eq, scaling, op_eq)
assert(bridge_eq:main_menu_context() == nil, 'Equipment menu must not trigger Soulspire Main Menu dock')

-- Invalid operand fails closed safely
local bridge_bad = MenuBridge.new(mem1, scaling, 0)
assert(not bridge_bad:is_available() and bridge_bad:main_menu_context() == nil, 'Invalid operand must fail closed')

-- 4. Focus state machine & navigation tests
local focus = Focus.new(reg)
assert(not focus:owns_input(), 'Initial focus must not own input')
-- Unowned inputs pass through to native FFXI
assert(focus:handle_action('down', ctx1) == false, 'Down on native menu should pass through')
assert(focus:handle_action('confirm', ctx1) == false, 'Confirm on native menu should pass through')
assert(focus:handle_action('cancel', ctx1) == false, 'Cancel on native menu should pass through')

-- Handoff via focus_dock claims ownership
assert(focus:handle_action('focus_dock', ctx1) == true, 'focus_dock on Main Menu must be consumed')
assert(focus.dock_focused == true and focus.hub_open == false, 'Dock should be focused')

-- Confirm opens Hub
assert(focus:handle_action('confirm', ctx1) == true, 'Confirm on focused dock must open Hub')
assert(focus.hub_open == true and focus.opened_from_dock == true, 'Hub should be open from dock')
assert(focus.selected_index == 1, 'Initial section should be 1')

-- Wrap-around navigation (Up from 1 -> 7, Down from 7 -> 1)
assert(focus:handle_action('up', ctx1) == true)
assert(focus.selected_index == 7 and focus.active_index == 7, 'Up from 1 must wrap to 7')
assert(focus:handle_action('down', ctx1) == true)
assert(focus.selected_index == 1 and focus.active_index == 1, 'Down from 7 must wrap to 1')
assert(focus:handle_action('down', ctx1) == true)
assert(focus.selected_index == 2, 'Down from 1 must move to 2')

-- Cancel closes Hub and returns focus to dock while Main Menu is still open
assert(focus:handle_action('cancel', ctx1) == true)
assert(focus.hub_open == false and focus.dock_focused == true, 'Cancel from dock-opened Hub must return to dock')

-- Second cancel returns focus to native FFXI Main Menu
assert(focus:handle_action('cancel', ctx1) == true)
assert(focus.hub_open == false and focus.dock_focused == false, 'Second cancel must return to native menu')

-- Native menu disappearing blurs dock focus
assert(focus:handle_action('focus_dock', ctx1) == true)
focus:sync_native(nil)
assert(focus.dock_focused == false, 'Closing native menu must blur dock focus')

-- 5. Input ownership & controller tests
local inp = Input.new()
local function dispatch(action) return focus:handle_action(action, ctx1) end

-- Chat open blocks keyboard capture
assert(inp:on_key(15, true, true, dispatch) == false, 'Tab while chat is open must not be captured')
inp:release_key(15)

-- Tab focuses dock, held repeat stays consumed until release
assert(inp:on_key(15, true, false, dispatch) == true, 'Tab should focus dock')
assert(inp:on_key(15, true, false, dispatch) == true, 'Held Tab repeat must stay consumed')
assert(inp:on_key(15, false, false, dispatch) == true, 'Tab release must clear owned press')
assert(focus.dock_focused == true)

-- XInput A opens Hub, D-Pad Down navigates, B cancels back to dock, B cancels to native
assert(inp:on_pad('xinput', 12, true, dispatch) == true, 'XInput A must open Hub')
assert(inp:on_pad('xinput', 12, false, dispatch) == true)
assert(focus.hub_open == true)

assert(inp:on_pad('xinput', 1, true, dispatch) == true, 'XInput D-Pad Down must navigate')
assert(inp:on_pad('xinput', 1, false, dispatch) == true)
assert(focus.selected_index == 3)

-- DirectInput POV Up navigates back to 2
assert(inp:on_dinput_pov(0, dispatch) == true, 'DirectInput POV Up must navigate')
assert(inp:on_dinput_pov(-1, dispatch) == true)
assert(focus.selected_index == 2)

-- XInput B closes Hub -> dock, then B -> native
assert(inp:on_pad('xinput', 13, true, dispatch) == true)
assert(inp:on_pad('xinput', 13, false, dispatch) == true)
assert(focus.hub_open == false and focus.dock_focused == true)
assert(inp:on_pad('xinput', 13, true, dispatch) == true)
assert(inp:on_pad('xinput', 13, false, dispatch) == true)
assert(focus.dock_focused == false)

-- 6. UI mock ImGui draw test
local drawn_texts = {}
local click_next_btn = nil
local mock_dl = {
    AddRectFilled = function() end,
    AddRect = function() end,
    AddLine = function() end,
    AddQuadFilled = function() end,
    AddQuad = function() end,
    AddImage = function() end,
}
local mock_imgui = {
    SetNextWindowPos = function() end,
    SetNextWindowSize = function() end,
    PushStyleVar = function() end,
    PopStyleVar = function() end,
    PushStyleColor = function() end,
    PopStyleColor = function() end,
    PushTextWrapPos = function() end,
    PopTextWrapPos = function() end,
    SetCursorScreenPos = function() end,
    GetWindowPos = function() return 100, 100 end,
    GetWindowDrawList = function() return mock_dl end,
    GetIO = function() return { DisplaySize = { x = 1920, y = 1080 } } end,
    Begin = function() return true end,
    End = function() end,
    InvisibleButton = function(id) return id == click_next_btn end,
    IsItemHovered = function() return false end,
    TextUnformatted = function(s) drawn_texts[#drawn_texts + 1] = s end,
}

local ui = UI.new(mock_imgui, reg, focus, nil)
-- Clicking docked entry opens Hub
click_next_btn = '##soulspire_dock_btn'
ui:draw(ctx1, true)
assert(ui.last_dock.visible == true and ui.last_dock.clicks == 1, 'Dock button click should be recorded')
assert(focus.hub_open == true, 'Clicking dock button must open Hub')

-- Render Hub and verify all 7 section names are drawn
drawn_texts = {}
click_next_btn = nil
ui:draw(ctx1, true)
local joined = table.concat(drawn_texts, '\n')
for _, label in ipairs(expected_labels) do
    assert(joined:find(label, 1, true), 'Hub UI did not render required section: ' .. label)
end
assert(joined:find('Native-Styled Main Menu Fallback', 1, true), 'UI must clearly identify fallback mode')

print('SoulspireXI Core Phase 1A tests passed.')
