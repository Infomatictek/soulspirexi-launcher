-- SoulspireXI Core — Mouse Cursor & Input Ownership Lifecycle Regression Suite.
-- Covers all 12 required Windows/Ashita v4 lifecycle scenarios, double-cursor
-- prevention, non-sensitive diagnostics, and 1080p/1440p click targeting.
-- Run from addons/ashita4/soulspire_core: luajit tests/mouse_lifecycle_test.lua

package.path = './?.lua;./?/init.lua;../soulspire_talents/?.lua;../crystalsocket/?.lua;' .. package.path

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

local function assert_false(cond, msg)
    if cond then
        error(msg or 'assert_false failed', 2)
    end
end

local MouseLifecycle = require('core.mouse_lifecycle')
local Registry       = require('core.registry')
local Focus          = require('core.focus')
local Input          = require('core.input')
local UI             = require('core.ui')
local WeaponMastery  = require('modules.weapon_mastery')
local CharacterMod   = require('modules.character')
local SoulTalents    = require('modules.soul_talents')

-- Helper: build isolated mock ImGui + Win32 platform + Core Focus/Input/UI harness.
local function create_harness(opts)
    opts = opts or {}
    local clock_now = opts.start_time or 100.0
    local mock_display = { x = opts.view_w or 1920, y = opts.view_h or 1080 }

    local io_state = {
        DisplaySize     = mock_display,
        MouseDrawCursor = opts.initial_draw_cursor == true,
        ConfigFlags     = opts.initial_config_flags or 0,
    }

    local platform_state = {
        window_focused         = (opts.window_focused ~= false),
        os_cursor_visible      = opts.os_cursor_visible, -- true | false | nil
        has_capture            = opts.has_capture == true,
        release_capture_calls  = 0,
        show_cursor_calls      = 0, -- invariant: must ALWAYS stay 0
    }

    local platform = {
        is_window_focused = function()
            return platform_state.window_focused
        end,
        is_os_cursor_visible = function()
            return platform_state.os_cursor_visible
        end,
        has_mouse_capture = function()
            return platform_state.has_capture
        end,
        release_mouse_capture = function()
            platform_state.release_capture_calls = platform_state.release_capture_calls + 1
            platform_state.has_capture = false
            return true
        end,
    }

    local imgui_calls = {
        begin_p_open_values  = {},
        set_next_focus_count = 0,
        set_mouse_cursor     = {},
        invisible_buttons    = {},
    }
    local current_mouse_cursor = opts.initial_mouse_cursor or MouseLifecycle.IMGUI_CURSOR_ARROW
    local click_target_id = nil
    local cursorX, cursorY = 0, 0

    local mock_dl = {
        AddRectFilled           = function() end,
        AddRect                 = function() end,
        AddRectFilledMultiColor = function() end,
        AddLine                 = function() end,
        AddQuadFilled           = function() end,
        AddQuad                 = function() end,
        AddCircleFilled         = function() end,
        AddCircle               = function() end,
        AddTriangleFilled       = function() end,
        AddImage                = function() end,
        AddText                 = function() end,
    }

    local mock_imgui = {
        GetIO              = function() return io_state end,
        GetMouseCursor     = function() return current_mouse_cursor end,
        SetMouseCursor     = function(c)
            current_mouse_cursor = c
            imgui_calls.set_mouse_cursor[#imgui_calls.set_mouse_cursor + 1] = c
        end,
        SetNextWindowPos   = function() end,
        SetNextWindowSize  = function() end,
        SetNextWindowFocus = function()
            imgui_calls.set_next_focus_count = imgui_calls.set_next_focus_count + 1
        end,
        PushStyleVar       = function() end,
        PopStyleVar        = function() end,
        PushStyleColor     = function() end,
        PopStyleColor      = function() end,
        PushTextWrapPos    = function() end,
        PopTextWrapPos     = function() end,
        SetCursorScreenPos = function(p) cursorX, cursorY = p[1], p[2] end,
        GetCursorScreenPos = function() return cursorX, cursorY end,
        GetWindowPos       = function()
            local L = nil
            return 0, 0
        end,
        GetWindowDrawList     = function() return mock_dl end,
        GetBackgroundDrawList = function() return mock_dl end,
        Begin              = function(_title, p_open, _flags)
            imgui_calls.begin_p_open_values[#imgui_calls.begin_p_open_values + 1] = p_open
            return true
        end,
        End                = function() end,
        BeginChild         = function() return true end,
        EndChild           = function() end,
        InvisibleButton    = function(id, size)
            local w = type(size) == 'table' and (tonumber(size[1]) or 0) or 0
            local h = type(size) == 'table' and (tonumber(size[2]) or 0) or 0
            imgui_calls.invisible_buttons[id] = { x = cursorX, y = cursorY, w = w, h = h }
            return id == click_target_id
        end,
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
        TextUnformatted    = function() end,
    }

    local reg = Registry.new()
    local focus = Focus.new(reg)
    local input = Input.new({ clock = function() return clock_now end })
    local ui = nil

    local ml = MouseLifecycle.new({
        clock = function() return clock_now end,
        platform = platform,
        on_mouse_activity = function(ts)
            input:on_mouse_activity(ts)
        end,
        on_focus_regain = function()
            if ui and ui.request_window_focus then
                ui:request_window_focus()
            end
        end,
        on_focus_lost = function()
            input:reset()
        end,
    })

    focus:set_lifecycle_hooks({
        on_hub_open = function(_f, reason)
            ml:acquire(mock_imgui, reason, clock_now)
        end,
        on_hub_close = function(_f, reason, clear_buttons)
            ml:release(mock_imgui, reason, clock_now, clear_buttons == true)
        end,
    })

    ui = UI.new(mock_imgui, reg, focus, nil, {
        ui_scale = 1.0,
        get_last_device = function() return input.last_device end,
    })

    -- Make GetWindowPos return computed L.posX, L.posY so button coordinates match viewport geometry.
    mock_imgui.GetWindowPos = function()
        local L = ui:compute_layout(mock_display.x, mock_display.y)
        return L.posX, L.posY
    end

    local function advance(dt)
        clock_now = clock_now + (dt or 0.016)
    end

    local function dispatch_action(act)
        return focus:handle_action(act, nil)
    end

    local function present_frame()
        ml:tick_present(mock_imgui, focus:is_hub_open(), clock_now)
        input:tick(clock_now, dispatch_action, focus:is_hub_open() and ml.window_focused)
        ui:draw_hub(nil, 'native_hook')
    end

    local function send_mouse(msg, x, y)
        local ev = { message = msg, x = x or 500, y = y or 400, blocked = false }
        if ml:on_mouse_event(ev, focus:is_hub_open(), mock_imgui, clock_now) then
            ev.blocked = true
        end
        return ev
    end

    return {
        reg = reg,
        focus = focus,
        input = input,
        ml = ml,
        ui = ui,
        io = io_state,
        imgui = mock_imgui,
        imgui_calls = imgui_calls,
        platform = platform_state,
        display = mock_display,
        advance = advance,
        dispatch_action = dispatch_action,
        present_frame = present_frame,
        send_mouse = send_mouse,
        set_click_target = function(id) click_target_id = id end,
    }
end

-- =========================================================================
-- Scenario 1: Open Core for the first time (with hidden OS cursor & stale FFXI capture)
-- =========================================================================
do
    local h = create_harness({
        os_cursor_visible    = false,
        has_capture          = true,
        initial_config_flags = MouseLifecycle.IMGUI_CONFIG_NO_MOUSE,
        initial_mouse_cursor = MouseLifecycle.IMGUI_CURSOR_NONE,
    })

    -- Before opening: Core owns nothing, FFXI mouse events pass untouched
    assert_eq(h.ml.owner, 'ffxi', 'S1 initial owner must be ffxi')
    local pre_ev = h.send_mouse(MouseLifecycle.WM_LBUTTONDOWN, 200, 200)
    assert_false(pre_ev.blocked, 'S1 closed Core must never block FFXI mouse events')

    h.focus:open_hub(1, false)
    assert_eq(h.ml.owner, 'core', 'S1 owner transitions to core on first open')
    assert_eq(h.ml.acquire_count, 1, 'S1 acquire_count == 1')
    assert_eq(h.ml.release_count, 0, 'S1 release_count == 0')
    assert_eq(h.io.MouseDrawCursor, true, 'S1 ImGui software cursor enabled on open')
    assert_eq(bit.band(h.io.ConfigFlags, MouseLifecycle.IMGUI_CONFIG_NO_MOUSE), 0, 'S1 NoMouse cleared on open')
    assert_eq(h.platform.release_capture_calls, 1, 'S1 stale FFXI capture released once on acquire')
    assert_false(h.platform.has_capture, 'S1 stale capture is now cleared')
    assert_eq(h.imgui_calls.set_mouse_cursor[1], MouseLifecycle.IMGUI_CURSOR_ARROW, 'S1 None cursor promoted to Arrow')

    h.present_frame()
    assert_eq(h.imgui_calls.set_next_focus_count, 1, 'S1 SetNextWindowFocus fires once on open')
    assert_eq(h.imgui_calls.begin_p_open_values[1], nil, 'S1 imgui.Begin passes nil p_open (not boolean true)')

    -- Subsequent frames do NOT spam SetNextWindowFocus or ReleaseCapture
    h.advance(0.016)
    h.present_frame()
    assert_eq(h.imgui_calls.set_next_focus_count, 1, 'S1 SetNextWindowFocus not repeated per-frame')
    assert_eq(h.platform.release_capture_calls, 1, 'S1 ReleaseCapture not repeated per-frame')
end

-- =========================================================================
-- Scenario 2: Close and reopen Core 20 consecutive times
-- =========================================================================
do
    local h = create_harness({
        os_cursor_visible    = false,
        initial_draw_cursor  = false,
        initial_config_flags = 0,
    })

    for cycle = 1, 20 do
        h.focus:open_hub(1, false)
        h.present_frame()
        assert_eq(h.ml.owner, 'core', 'S2 cycle ' .. cycle .. ' owner == core')
        assert_eq(h.io.MouseDrawCursor, true, 'S2 cycle ' .. cycle .. ' cursor visible while open')
        assert_eq(h.ml.acquire_count, cycle, 'S2 cycle ' .. cycle .. ' acquire_count balanced')

        -- Mouse move & click while open must be blocked from FFXI
        local mv = h.send_mouse(MouseLifecycle.WM_MOUSEMOVE, 400 + cycle * 5, 300)
        assert_true(mv.blocked, 'S2 cycle ' .. cycle .. ' mouse move blocked from FFXI while open')

        h.focus:close_hub(nil)
        h.present_frame()
        assert_eq(h.ml.owner, 'ffxi', 'S2 cycle ' .. cycle .. ' owner restored to ffxi')
        assert_eq(h.io.MouseDrawCursor, false, 'S2 cycle ' .. cycle .. ' MouseDrawCursor restored to false')
        assert_eq(h.ml.release_count, cycle, 'S2 cycle ' .. cycle .. ' release_count balanced')
        h.advance(0.05)
    end
    assert_eq(h.ml.acquire_count, 20, 'S2 total acquires == 20')
    assert_eq(h.ml.release_count, 20, 'S2 total releases == 20')
    assert_eq(h.imgui_calls.set_next_focus_count, 20, 'S2 SetNextWindowFocus fired exactly once per open')
end

-- =========================================================================
-- Scenario 3: Switch between Character and Weapon Mastery (and Soul Talents)
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_hub(1, false) -- Character
    assert_eq(h.focus:active_module().id, 'character', 'S3 starts on character')
    assert_eq(h.ml.acquire_count, 1, 'S3 initial acquire == 1')

    for i = 1, 10 do
        h.focus:select_module('weapon_mastery')
        assert_eq(h.focus:active_module().id, 'weapon_mastery', 'S3 switched to weapon_mastery')
        h.present_frame()
        h.focus:select_module('character')
        assert_eq(h.focus:active_module().id, 'character', 'S3 switched back to character')
        h.present_frame()
        h.focus:switch_module(1) -- weapon_mastery
        h.focus:switch_module(1) -- soul_talents
        h.focus:switch_module(-2) -- character
    end

    assert_eq(h.ml.owner, 'core', 'S3 owner remains core across tab switches')
    assert_eq(h.ml.acquire_count, 1, 'S3 tab switching must NEVER re-acquire cursor/input')
    assert_eq(h.ml.release_count, 0, 'S3 tab switching must NEVER release cursor/input')
    assert_eq(h.io.MouseDrawCursor, true, 'S3 cursor stays visible across tab switches')
    assert_eq(h.imgui_calls.set_next_focus_count, 1, 'S3 tab switching does not spam SetNextWindowFocus')
end

-- =========================================================================
-- Scenario 4: Open Core via native FFXI Commands menu
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false, has_capture = false })
    -- Native menu confirm (e.g., player highlighted "Soulspire" with D-Pad/Keyboard & pressed A/Enter)
    h.focus:open_from_native_menu(1)
    h.input:arm_open_guard(0.20)
    h.present_frame()

    assert_true(h.focus:is_hub_open(), 'S4 hub open via native menu')
    assert_eq(h.ml.owner, 'core', 'S4 lifecycle acquired on native menu open')
    assert_eq(h.io.MouseDrawCursor, true, 'S4 cursor guaranteed visible after native menu dismissal')
    assert_true(h.ml.last_transition:find('open_from_native_menu', 1, true) ~= nil, 'S4 transition records open_from_native_menu')
    -- Confirm guard absorbs immediate Enter/A bounce without closing or breaking cursor
    assert_true(h.input:on_key(28, true, false, h.dispatch_action, true, false), 'S4 confirm bounce absorbed')
    assert_eq(h.ml.owner, 'core', 'S4 cursor ownership intact after confirm guard')
end

-- =========================================================================
-- Scenario 5: Open Core with keyboard controls
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_hub(1, false)
    -- Navigate tabs with keyboard E (scan 18 -> module_next) and Q (scan 16 -> module_prev)
    assert_true(h.input:on_key(18, true, false, h.dispatch_action, true, false), 'S5 E switches module')
    assert_true(h.input:on_key(18, false, false, h.dispatch_action, true, false), 'S5 E release consumed')
    assert_eq(h.input.last_device, 'keyboard', 'S5 last_device == keyboard')
    assert_eq(h.focus:active_module().id, 'weapon_mastery', 'S5 switched to weapon_mastery via keyboard')
    assert_eq(h.io.MouseDrawCursor, true, 'S5 cursor remains visible during keyboard navigation')

    -- Close with Escape (scan 1 -> cancel)
    assert_true(h.input:on_key(1, true, false, h.dispatch_action, true, false), 'S5 Escape closes Core')
    assert_false(h.focus:is_hub_open(), 'S5 Core closed by Escape')
    assert_eq(h.ml.owner, 'ffxi', 'S5 FFXI cursor/input restored after Escape close')
    assert_eq(h.io.MouseDrawCursor, false, 'S5 MouseDrawCursor restored after Escape close')
end

-- =========================================================================
-- Scenario 6: Open Core with gamepad controls
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_from_native_menu(1)
    h.advance(0.25)

    -- RB (XInput 9 -> module_next) switches module with gamepad
    assert_true(h.input:on_pad('xinput', 9, true, h.dispatch_action, true), 'S6 RB consumed')
    assert_true(h.input:on_pad('xinput', 9, false, h.dispatch_action, true), 'S6 RB release consumed')
    assert_eq(h.input.last_device, 'gamepad', 'S6 last_device == gamepad')
    assert_eq(h.focus:active_module().id, 'weapon_mastery', 'S6 gamepad switched module')
    assert_eq(h.ml.owner, 'core', 'S6 Core owns lifecycle during gamepad use')
    assert_eq(h.io.MouseDrawCursor, true, 'S6 cursor remains ready/visible')

    -- B (XInput 13 -> cancel) closes Core cleanly
    assert_true(h.input:on_pad('xinput', 13, true, h.dispatch_action, true), 'S6 B closes Core')
    assert_false(h.focus:is_hub_open(), 'S6 hub closed')
    assert_eq(h.ml.owner, 'ffxi', 'S6 FFXI ownership restored')
end

-- =========================================================================
-- Scenario 7: Move mouse after gamepad use (clean gamepad -> mouse transition)
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_from_native_menu(1)
    h.advance(0.25)

    -- Player navigates with gamepad first (holds D-Pad right -> arm repeat)
    h.input:on_pad('xinput', 3, true, h.dispatch_action, true)
    assert_eq(h.input.last_device, 'gamepad', 'S7 starts on gamepad')

    -- Sub-threshold 1px jitter after initial sample does not spuriously flip if already sampled,
    -- whereas genuine mouse motion immediately flips device to mouse & clears pad repeat.
    local ev1 = h.send_mouse(MouseLifecycle.WM_MOUSEMOVE, 600, 420)
    assert_true(ev1.blocked, 'S7 mouse move blocked from FFXI while Core open')
    assert_eq(h.input.last_device, 'mouse', 'S7 genuine mouse move transitions last_device gamepad -> mouse')
    assert_eq(h.io.MouseDrawCursor, true, 'S7 cursor visible immediately after gamepad -> mouse transition')

    -- Verify all 3 modules return KBM/Click prompt pills for last_device == 'mouse'
    local wm_pills = WeaponMastery.get_prompt_pills({ has_modal = function() return false end }, 'mouse')
    assert_eq(wm_pills[1][1], 'Click', 'S7 WeaponMastery shows Click prompt pill on mouse device')
    local ch_pills = CharacterMod.get_prompt_pills({ has_modal = function() return false end }, 'mouse')
    assert_eq(ch_pills[1][1], 'Arrows', 'S7 Character shows KBM prompt pills on mouse device')
    local st_pills = SoulTalents.get_prompt_pills({ region = 'slots' }, 'mouse')
    assert_eq(st_pills[1][1], 'Arrows', 'S7 SoulTalents shows KBM prompt pills on mouse device')
end

-- =========================================================================
-- Scenario 8: Alt+Tab out and back (both while Core open AND while Core closed)
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_hub(1, false)
    h.present_frame()
    -- Simulate held key + mouse button before Alt+Tab
    h.input:on_key(205, true, false, h.dispatch_action, true, false)
    h.send_mouse(MouseLifecycle.WM_LBUTTONDOWN, 500, 500)
    assert_true(h.ml:has_held_core_buttons(), 'S8 button owned before Alt+Tab')

    -- Alt+Tab OUT
    h.platform.window_focused = false
    h.advance(0.05)
    h.present_frame()
    assert_true(h.focus:is_hub_open(), 'S8 Core stays open logically across Alt+Tab')
    assert_eq(h.ml.owner, 'suspended_unfocused', 'S8 lifecycle suspended when unfocused')
    assert_eq(h.ml.suspend_count, 1, 'S8 suspend_count == 1')
    assert_eq(h.io.MouseDrawCursor, false, 'S8 MouseDrawCursor restored while Alt+Tabbed out')
    assert_false(h.ml:has_held_core_buttons(), 'S8 held mouse buttons cleared on focus loss')
    assert_eq(next(h.input.key_owner), nil, 'S8 held keyboard keys cleared on focus loss')

    -- Alt+Tab BACK (even if OS cursor was hidden again & stale capture appeared)
    h.platform.window_focused = true
    h.platform.has_capture = true
    h.platform.os_cursor_visible = false
    h.advance(0.05)
    h.present_frame()
    assert_eq(h.ml.owner, 'core', 'S8 lifecycle resumed cleanly on focus regain')
    assert_eq(h.ml.resume_count, 1, 'S8 resume_count == 1')
    assert_eq(h.io.MouseDrawCursor, true, 'S8 cursor visible again after Alt+Tab return')
    assert_eq(h.platform.release_capture_calls, 1, 'S8 stale capture released on resume')
    assert_eq(h.imgui_calls.set_next_focus_count, 2, 'S8 SetNextWindowFocus fired on Alt+Tab regain')

    -- Close Core, then Alt+Tab out & back: must be strict no-op on FFXI
    h.focus:close_hub(nil)
    h.platform.window_focused = false
    h.present_frame()
    h.platform.window_focused = true
    h.present_frame()
    assert_eq(h.ml.owner, 'ffxi', 'S8 Alt+Tab while Core closed never alters FFXI ownership')
    assert_eq(h.ml.suspend_count, 1, 'S8 no suspend triggered when Core closed')
    assert_eq(h.ml.resume_count, 1, 'S8 no resume triggered when Core closed')
end

-- =========================================================================
-- Scenario 9: Zone change while Core is open
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_hub(2, false)
    h.send_mouse(MouseLifecycle.WM_LBUTTONDOWN, 450, 320)
    assert_eq(h.ml.owner, 'core', 'S9 owner == core before zone')

    -- Simulate packet_in 0x00A / 0x00B zone change handler
    h.focus:blur_all('zone_change')
    h.input:reset()
    h.present_frame()

    assert_false(h.focus:is_hub_open(), 'S9 Core closed on zone_change')
    assert_eq(h.ml.owner, 'ffxi', 'S9 FFXI ownership restored on zone_change')
    assert_eq(h.io.MouseDrawCursor, false, 'S9 MouseDrawCursor restored on zone_change')
    assert_false(h.ml:has_held_core_buttons(), 'S9 held buttons cleared on zone_change')
    assert_true(h.ml.last_transition:find('zone_change', 1, true) ~= nil, 'S9 transition records zone_change')
end

-- =========================================================================
-- Scenario 10: Addon reload / unload while Core is open
-- =========================================================================
do
    local h = create_harness({
        os_cursor_visible    = false,
        initial_draw_cursor  = false,
        initial_config_flags = MouseLifecycle.IMGUI_CONFIG_NO_MOUSE,
    })
    h.focus:open_hub(1, false)
    assert_eq(h.ml.owner, 'core', 'S10 owner == core prior to unload')

    -- Simulate unload handler (focus:blur_all + idempotent release)
    h.focus:blur_all('unload')
    h.ml:release(h.imgui, 'unload', 105.0, true)
    h.input:reset()

    assert_false(h.focus:is_hub_open(), 'S10 hub closed on unload')
    assert_eq(h.ml.owner, 'ffxi', 'S10 owner == ffxi after unload')
    assert_eq(h.io.MouseDrawCursor, false, 'S10 MouseDrawCursor restored on unload')
    assert_eq(bit.band(h.io.ConfigFlags, MouseLifecycle.IMGUI_CONFIG_NO_MOUSE), MouseLifecycle.IMGUI_CONFIG_NO_MOUSE,
        'S10 original NoMouse ConfigFlags bit preserved exactly on unload')
    assert_eq(h.ml.release_count, 1, 'S10 idempotent double-release does not double-count')

    -- Reload fresh instance: must open cleanly with cursor visible
    local h2 = create_harness({ os_cursor_visible = false })
    h2.focus:open_hub(1, false)
    assert_eq(h2.ml.owner, 'core', 'S10 reloaded addon acquires cleanly')
    assert_eq(h2.io.MouseDrawCursor, true, 'S10 reloaded addon displays cursor')
end

-- =========================================================================
-- Scenario 11: Close Core via X button click & confirm FFXI input restored cleanly
-- =========================================================================
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_hub(1, false)

    -- Left mouse down on Core's X close button
    local down_ev = h.send_mouse(MouseLifecycle.WM_LBUTTONDOWN, 1840, 62)
    assert_true(down_ev.blocked, 'S11 LBUTTONDOWN blocked from FFXI while Core open')

    -- UI renders frame and X button triggers focus:close_hub()
    h.set_click_target('##core_close')
    h.present_frame()
    h.set_click_target(nil)
    assert_false(h.focus:is_hub_open(), 'S11 clicking ##core_close closes Core')
    assert_eq(h.ml.owner, 'ffxi', 'S11 lifecycle released to ffxi')
    assert_eq(h.io.MouseDrawCursor, false, 'S11 MouseDrawCursor restored')

    -- Trailing WM_LBUTTONUP from the X click MUST be absorbed once so FFXI doesn't see an orphan click-up
    local up_ev = h.send_mouse(MouseLifecycle.WM_LBUTTONUP, 1840, 62)
    assert_true(up_ev.blocked, 'S11 trailing WM_LBUTTONUP from X click absorbed cleanly')
    assert_eq(h.ml.absorbed_release_events, 1, 'S11 absorbed_release_events == 1')

    -- Subsequent normal FFXI mouse clicks, drags, wheel, and moves pass 100% untouched!
    for _, msg in ipairs({
        MouseLifecycle.WM_MOUSEMOVE,
        MouseLifecycle.WM_LBUTTONDOWN,
        MouseLifecycle.WM_LBUTTONUP,
        MouseLifecycle.WM_RBUTTONDOWN,
        MouseLifecycle.WM_RBUTTONUP,
        MouseLifecycle.WM_MOUSEWHEEL,
    }) do
        local ffxi_ev = h.send_mouse(msg, 960, 540)
        assert_false(ffxi_ev.blocked, 'S11 FFXI mouse message ' .. tostring(msg) .. ' must NOT be blocked after close')
    end
end

-- =========================================================================
-- Scenario 12: Cursor visibility & click targeting at 1080p and 1440p + Double-Cursor Guard + Diagnostics
-- =========================================================================
for _, res in ipairs({ { 1920, 1080, '1080p' }, { 2560, 1440, '1440p' } }) do
    local vw, vh, label = res[1], res[2], res[3]
    local h = create_harness({ view_w = vw, view_h = vh, os_cursor_visible = false })
    h.focus:open_hub(1, false)
    h.present_frame()

    assert_eq(h.io.MouseDrawCursor, true, 'S12 ' .. label .. ' cursor visible')
    assert_true(h.ui.last_layout ~= nil, 'S12 ' .. label .. ' layout computed')

    -- Verify header utility buttons & tab buttons have valid positive hitboxes inside viewport bounds
    for _, btn_id in ipairs({ '##core_close', '##core_scale_btn', '##core_help', '##core_tab_character', '##core_tab_weapon_mastery' }) do
        local b = h.imgui_calls.invisible_buttons[btn_id]
        assert_true(b ~= nil, 'S12 ' .. label .. ' missing button hitbox ' .. btn_id)
        assert_true(b.w > 0 and b.h > 0, 'S12 ' .. label .. ' positive hitbox size for ' .. btn_id)
        assert_true(b.x >= 0 and b.y >= 0 and (b.x + b.w) <= vw and (b.y + b.h) <= vh,
            string.format('S12 %s hitbox %s out of bounds: (%.1f,%.1f %.1fx%.1f) vs %dx%d', label, btn_id, b.x, b.y, b.w, b.h, vw, vh))
    end

    -- Click Weapon Mastery tab at this resolution and verify module switches cleanly
    h.set_click_target('##core_tab_weapon_mastery')
    h.present_frame()
    h.set_click_target(nil)
    assert_eq(h.focus:active_module().id, 'weapon_mastery', 'S12 ' .. label .. ' clicking Weapon Mastery tab works')
    assert_eq(h.ml.acquire_count, 1, 'S12 ' .. label .. ' clicking tab did not re-acquire lifecycle')
end

-- Strict single-cursor invariant tests (both ConfigFlags=0 and NoMouseCursorChange=64):
local function assert_single_cursor(h, ctx)
    local hw = (h.platform.os_cursor_visible == true) and 1 or 0
    local sw = (h.io.MouseDrawCursor == true) and 1 or 0
    assert_eq(hw + sw, 1, ctx .. ': must have EXACTLY 1 visible cursor (never 0, never 2)')
end

-- Exact Windows double-cursor repro: ConfigFlags=0 (Ashita default) + OS hardware cursor visible!
for _, cfg_case in ipairs({
    { 0, 'ConfigFlags=0' },
    { MouseLifecycle.IMGUI_CONFIG_NO_MOUSE_CURSOR_CHANGE, 'NoMouseCursorChange=64' },
}) do
    local flags, label = cfg_case[1], cfg_case[2]
    local h = create_harness({
        initial_config_flags = flags,
        os_cursor_visible    = true,
    })

    -- Open via /soulspire with hardware cursor already visible -> MUST stay hardware (no double cursor!)
    h.focus:open_hub(1, false)
    h.present_frame()
    assert_eq(h.io.MouseDrawCursor, false, label .. ': OS visible -> MouseDrawCursor MUST stay false')
    assert_eq(h.ml.cursor_mode, 'hardware', label .. ': cursor_mode == hardware')
    assert_eq(h.ml.fallback_active, false, label .. ': fallback_active == false')
    assert_eq(h.ml.fallback_reason, 'none', label .. ': fallback_reason == none')
    assert_single_cursor(h, label .. ' open with OS visible')

    -- Move mouse and switch tabs -> still strictly 1 hardware cursor
    h.send_mouse(MouseLifecycle.WM_MOUSEMOVE, 700, 400)
    h.focus:select_module('weapon_mastery')
    h.present_frame()
    assert_eq(h.io.MouseDrawCursor, false, label .. ': mouse move + tab switch keeps hardware cursor')
    assert_single_cursor(h, label .. ' after mouse move + tab switch')

    -- OS hardware cursor disappears (e.g., FFXI hides it) -> immediately switches to software_fallback (1 cursor)
    h.platform.os_cursor_visible = false
    h.present_frame()
    assert_eq(h.io.MouseDrawCursor, true, label .. ': OS hidden -> MouseDrawCursor enabled as fallback')
    assert_eq(h.ml.cursor_mode, 'software_fallback', label .. ': cursor_mode == software_fallback')
    assert_eq(h.ml.fallback_active, true, label .. ': fallback_active == true')
    assert_eq(h.ml.fallback_reason, 'os_cursor_hidden', label .. ': fallback_reason == os_cursor_hidden')
    assert_single_cursor(h, label .. ' OS hidden fallback')

    -- OS hardware cursor reappears (e.g., moving mouse after gamepad) -> software fallback yields immediately!
    h.platform.os_cursor_visible = true
    h.send_mouse(MouseLifecycle.WM_MOUSEMOVE, 740, 430)
    h.present_frame()
    assert_eq(h.io.MouseDrawCursor, false, label .. ': OS returned -> MouseDrawCursor disabled immediately')
    assert_eq(h.ml.cursor_mode, 'hardware', label .. ': cursor_mode returned to hardware')
    assert_eq(h.ml.fallback_active, false, label .. ': fallback_active cleared')
    assert_single_cursor(h, label .. ' OS returned after gamepad->mouse')

    -- Alt+Tab out -> cursor_mode == none; Alt+Tab back with OS visible -> strictly hardware (1 cursor)
    h.platform.window_focused = false
    h.present_frame()
    assert_eq(h.ml.cursor_mode, 'none', label .. ': unfocused cursor_mode == none')
    assert_eq(h.io.MouseDrawCursor, false, label .. ': unfocused MouseDrawCursor == false')

    h.platform.window_focused = true
    h.platform.os_cursor_visible = true
    h.present_frame()
    assert_eq(h.ml.cursor_mode, 'hardware', label .. ': Alt+Tab regain with OS visible -> hardware')
    assert_single_cursor(h, label .. ' Alt+Tab regain with OS visible')

    -- Close & reopen alternating OS visible/hidden -> strictly 1 cursor every cycle
    for cycle = 1, 6 do
        h.focus:close_hub(nil)
        assert_eq(h.ml.cursor_mode, 'none', label .. ' close cycle ' .. cycle .. ' mode == none')
        h.platform.os_cursor_visible = (cycle % 2 == 0)
        h.focus:open_from_native_menu(1)
        h.present_frame()
        assert_single_cursor(h, label .. ' reopen cycle ' .. cycle)
    end
end

-- Unobservable OS cursor probe (nil): prefer hardware mode (never blindly create a double cursor)
do
    local h = create_harness({
        initial_config_flags = 0,
        os_cursor_visible    = nil,
    })
    h.focus:open_hub(1, false)
    h.present_frame()
    assert_eq(h.io.MouseDrawCursor, false, 'Unobservable probe must NOT blindly enable MouseDrawCursor')
    assert_eq(h.ml.cursor_mode, 'hardware', 'Unobservable probe defaults to hardware mode')
    assert_eq(h.ml.fallback_active, false, 'Unobservable probe fallback_active == false')
    assert_eq(h.ml.fallback_reason, 'probe_unavailable_prefer_hardware', 'Unobservable probe reason recorded')
end

-- Diagnostics schema & non-sensitive logging verification:
do
    local h = create_harness({ os_cursor_visible = false })
    h.focus:open_hub(1, false)
    local d_open = h.ml:diagnostics()
    assert_eq(d_open.cursor_mode, 'software_fallback', 'Diag open cursor_mode')
    assert_eq(d_open.os_cursor_visible, false, 'Diag open os_cursor_visible')
    assert_eq(d_open.imgui_draw_cursor, true, 'Diag open imgui_draw_cursor')
    assert_eq(d_open.fallback_active, true, 'Diag open fallback_active')
    assert_eq(d_open.fallback_reason, 'os_cursor_hidden', 'Diag open fallback_reason')
    assert_eq(d_open.fallback_activations, 1, 'Diag open fallback_activations')

    h.send_mouse(MouseLifecycle.WM_MOUSEMOVE, 1337, 733)
    h.focus:close_hub(nil)

    local d = h.ml:diagnostics()
    assert_eq(d.core_open, false, 'Diag core_open')
    assert_eq(d.owner, 'ffxi', 'Diag owner')
    assert_eq(d.cursor_mode, 'none', 'Diag closed cursor_mode')
    assert_eq(d.fallback_active, false, 'Diag closed fallback_active')
    assert_eq(d.mouse_captured, false, 'Diag mouse_captured')
    assert_eq(d.window_focused, true, 'Diag window_focused')
    assert_eq(d.acquire_count, 1, 'Diag acquire_count')
    assert_eq(d.release_count, 1, 'Diag release_count')
    assert_true(type(d.last_transition) == 'string' and d.last_transition ~= '', 'Diag last_transition populated')

    local status_line = h.ml:format_status_line()
    assert_true(status_line:find('input_lifecycle', 1, true) ~= nil, 'Diag status line has prefix')
    assert_true(status_line:find('cursor_mode=', 1, true) ~= nil, 'Diag status line includes cursor_mode')
    assert_true(status_line:find('fallback=', 1, true) ~= nil, 'Diag status line includes fallback status')
    assert_true(status_line:find('1337', 1, true) == nil, 'Diag status line must never log raw mouse coordinates')
    assert_true(status_line:find('733', 1, true) == nil, 'Diag status line must never log raw mouse coordinates')
end

print('PASS: all 12 SoulspireXI Core mouse/cursor lifecycle regression scenarios passed!')
