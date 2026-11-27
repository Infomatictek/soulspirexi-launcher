-- Regression tests for FFXI Controller Binding Inheritance, Overrides, Dynamic Prompts,
-- Conflict Detection, Disconnect/Reconnect, Mouse<->Gamepad Switching, and FFXI Restoration.
-- Run with: luajit addons/vanacore/soulspire_core/tests/test_controller_bindings.lua

package.path = table.concat({
    'addons/vanacore/soulspire_core/?.lua',
    'addons/vanacore/soulspire_core/?/init.lua',
    package.path,
}, ';')

local bit = require('bit')
local Input        = require('core.input')
local Registry     = require('core.registry')
local Focus        = require('core.focus')
local AbilitiesMod = require('modules.abilities')
local StatusDiag   = require('modules.status_and_diag')

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write('FAIL: ' .. tostring(msg) .. '\n')
    end
end

local function make_xinput_buf(wButtons, lt, rt, lx, ly)
    return {
        Gamepad = {
            wButtons      = wButtons or 0,
            bLeftTrigger  = lt or 0,
            bRightTrigger = rt or 0,
            sThumbLX      = lx or 0,
            sThumbLY      = ly or 0,
            sThumbRX      = 0,
            sThumbRY      = 0,
        },
    }
end

-- 1. Standard Xbox bindings imported from FFXI
do
    local t = 10.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 12, cancel = 13, options = 14, menu = 15 }
        end,
    })
    local d = inp:get_diagnostics()
    check(d.detected_backend == 'xinput', 'T1: detected xinput backend')
    check(d.config_source == 'ffxi_inherited', 'T1: config_source is ffxi_inherited')
    check(d.ffxi_imported == true, 'T1: ffxi_imported true')
    check(d.conflict_count == 0, 'T1: zero conflicts on standard Xbox')
    check(inp:label_for('confirm', 'gamepad') == 'A', 'T1: confirm label A')
    check(inp:label_for('cancel', 'gamepad') == 'B', 'T1: cancel label B')
    check(inp:label_for('modules', 'gamepad') == 'LB/RB', 'T1: modules label LB/RB')
end

-- 2. Swapped Confirm (B=13) & Cancel (A=12) — physical routing + dynamic prompts
do
    local t = 20.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 13, cancel = 12, options = 14, menu = 15 }
        end,
    })
    local acts = {}
    local function dispatch(a) acts[#acts + 1] = a return true end

    -- Press physical B (bit 13 -> 0x2000) -> must resolve to 'confirm'
    local bufB = make_xinput_buf(bit.lshift(1, 13))
    inp:filter_xinput_state(bufB, bufB, dispatch, true, t, 0)
    check(acts[1] == 'confirm', 'T2: swapped B dispatches confirm (got ' .. tostring(acts[1]) .. ')')
    check(bufB.Gamepad.wButtons == 0, 'T2: shared buffer zeroed after edge read')
    -- Release B, press physical A (bit 12 -> 0x1000) -> must resolve to 'cancel'
    inp:filter_xinput_state(make_xinput_buf(0), make_xinput_buf(0), dispatch, true, t + 0.05, 0)
    local bufA = make_xinput_buf(bit.lshift(1, 12))
    inp:filter_xinput_state(bufA, bufA, dispatch, true, t + 0.10, 0)
    check(acts[2] == 'cancel', 'T2: swapped A dispatches cancel (got ' .. tostring(acts[2]) .. ')')
    check(inp:label_for('confirm', 'gamepad') == 'B', 'T2: dynamic prompt confirm == B')
    check(inp:label_for('cancel', 'gamepad') == 'A', 'T2: dynamic prompt cancel == A')
    check(inp:get_diagnostics().conflict_count == 0, 'T2: swapped A/B has zero conflicts')
end

-- 3. Nonstandard shoulder / trigger assignments (LT=16 / RT=17 -> module_prev / module_next)
do
    local t = 30.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 12, cancel = 13, options = 14, menu = 15 }
        end,
    })
    inp:set_action_override('xinput', 'module_prev', 16) -- LT
    inp:set_action_override('xinput', 'module_next', 17) -- RT

    local acts = {}
    local function dispatch(a) acts[#acts + 1] = a return true end
    local bufLT = make_xinput_buf(0, 200, 0)
    inp:filter_xinput_state(bufLT, bufLT, dispatch, true, t, 0)
    check(acts[1] == 'module_prev', 'T3: LT trigger dispatches module_prev')
    check(bufLT.Gamepad.bLeftTrigger == 0, 'T3: shared buffer LT zeroed')
    local bufRT = make_xinput_buf(0, 0, 200)
    inp:filter_xinput_state(bufRT, bufRT, dispatch, true, t + 0.05, 0)
    check(acts[2] == 'module_next', 'T3: RT trigger dispatches module_next')
    check(inp:label_for('modules', 'gamepad') == 'LT/RT', 'T3: dynamic modules label is LT/RT')
    check(inp:get_diagnostics().config_source == 'ffxi_plus_overrides', 'T3: config_source is ffxi_plus_overrides')
end

-- 4. Custom DirectInput bindings (xinput=false, confirm=2, cancel=1, POV hat)
do
    local t = 40.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = false, confirm = 2, cancel = 1, options = 0, menu = 3 }
        end,
    })
    local d = inp:get_diagnostics()
    check(d.detected_backend == 'dinput', 'T4: detected DirectInput backend')
    check(inp:label_for('confirm', 'gamepad') == 'Btn 3', 'T4: DInput confirm label is Btn 3 (not Xbox A)')
    check(inp:label_for('cancel', 'gamepad') == 'Btn 2', 'T4: DInput cancel label is Btn 2')

    local acts = {}
    local function dispatch(a) acts[#acts + 1] = a return true end
    local di = {
        lX = 0, lY = 0,
        rgdwPOV = { [0] = 9000, [1] = 0xFFFFFFFF, [2] = 0xFFFFFFFF, [3] = 0xFFFFFFFF },
        rgbButtons = {},
    }
    for i = 0, 31 do di.rgbButtons[i] = 0 end
    di.rgbButtons[2] = 0x80 -- confirm
    inp:filter_dinput_state(di, di, dispatch, true, t)
    check(acts[1] == 'right', 'T4: DInput POV 9000 -> right')
    check(acts[2] == 'confirm', 'T4: DInput button 2 -> confirm')
    check(di.rgbButtons[2] == 0 and di.rgdwPOV[0] == 0xFFFFFFFF, 'T4: DInput shared buffer neutralized')
end

-- 5. Fallback import from raw FFXI padmode000 + padsin000 strings
do
    local t = 50.0
    -- padmode000 field[5]=1 (XInput); padsin000 slot5(cancel)=3(A->12), slot6(menu)=2(Y->15), slot7(confirm)=0(B->13), slot8(options)=1(X->14)
    local inp = Input.new({
        clock = function() return t end,
        config_game_fn = function(key)
            if key == 'padmode000' then return '1,1,1,1,1,1' end
            if key == 'padsin000'  then return '0,0,13,0,0,3,2,0,1,0' end
            return nil
        end,
    })
    check(inp:get_diagnostics().ffxi_imported == true, 'T5: fallback padsin000 import succeeded')
    check(inp:label_for('confirm', 'gamepad') == 'B', 'T5: padsin000 slot 7 (0) -> XInput 13 (B)')
    check(inp:label_for('cancel', 'gamepad') == 'A', 'T5: padsin000 slot 5 (3) -> XInput 12 (A)')
end

-- 6. Custom directional navigation override
do
    local t = 60.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 12, cancel = 13, options = 14, menu = 15 }
        end,
    })
    inp:set_action_override('xinput', 'up', 6)   -- L3
    inp:set_action_override('xinput', 'down', 7) -- R3
    local acts = {}
    inp:filter_xinput_state(make_xinput_buf(bit.lshift(1, 6)), make_xinput_buf(0), function(a) acts[#acts + 1] = a return true end, true, t, 0)
    check(acts[1] == 'up', 'T6: custom directional override L3 -> up')
    check(inp:label_for('nav', 'gamepad') == 'L3/R3', 'T6: nav label reflects custom directional override')
end

-- 7. Conflict detection + Restore Inherited + Restore Standard Defaults
do
    local t = 70.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 13, cancel = 12, options = 14, menu = 15 }
        end,
    })
    -- Override context onto 13 (same as inherited confirm B) -> must detect conflict!
    inp:set_action_override('xinput', 'context', 13)
    local conflicts = inp:get_conflicts('xinput')
    check(#conflicts == 1, 'T7: conflict detected when override collides with inherited confirm')
    check(inp:get_diagnostics().conflict_count == 1, 'T7: diag conflict_count == 1')

    inp:restore_inherited_bindings()
    check(inp:get_diagnostics().conflict_count == 0, 'T7: restore_inherited clears conflicts')
    check(inp:label_for('confirm', 'gamepad') == 'B', 'T7: restore_inherited keeps FFXI swapped confirm=B')

    inp:restore_standard_defaults()
    check(inp.use_ffxi_bindings == false, 'T7: restore_standard_defaults disables FFXI inheritance')
    check(inp:label_for('confirm', 'gamepad') == 'A', 'T7: restore_standard_defaults resets confirm=A')
    check(inp:get_diagnostics().config_source == 'defaults', 'T7: config_source == defaults')
end

-- 8. Dynamic button prompts across modules
do
    local inp = Input.new({
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 13, cancel = 12, options = 15, menu = 14 }
        end,
    })
    inp:set_action_override('xinput', 'module_prev', 16)
    inp:set_action_override('xinput', 'module_next', 17)
    local label_fn = function(act, dev) return inp:label_for(act, dev) end

    local ab = AbilitiesMod.new(nil, nil)
    local sd = StatusDiag.new(nil, nil, {}, nil, nil, {})
    local ab_pills = ab:get_prompt_pills('gamepad', label_fn)
    local sd_pills = sd:get_prompt_pills('gamepad', label_fn)
    check(ab_pills[2][1] == 'LT/RT', 'T8: AbilitiesMod modules pill reflects LT/RT override')
    check(ab_pills[3][1] == 'A', 'T8: AbilitiesMod close pill reflects swapped cancel=A')
    check(sd_pills[3][1] == 'LT/RT' and sd_pills[4][1] == 'A', 'T8: StatusDiag pills dynamically updated')
end

-- 9. Override persistence across simulated relaunch (only overrides persisted, FFXI re-imported)
do
    local ffxi_state = { xinput = true, confirm = 13, cancel = 12, options = 14, menu = 15 }
    local inp1 = Input.new({ gamepad_bindings_fn = function() return ffxi_state end })
    inp1:set_action_override('xinput', 'module_prev', 16)
    local saved = inp1:get_persisted_config()
    check(saved.use_ffxi_bindings == true, 'T9: persisted use_ffxi_bindings')
    check(saved.overrides.xinput.module_prev == 16, 'T9: persisted module_prev override')
    check(saved.overrides.xinput.confirm == nil, 'T9: inherited confirm NOT duplicated into persisted overrides')

    -- Simulate user changing FFXI bindings between sessions (now confirm=14 X, cancel=13 B)
    ffxi_state = { xinput = true, confirm = 14, cancel = 13, options = 12, menu = 15 }
    local inp2 = Input.new({
        gamepad_bindings_fn = function() return ffxi_state end,
        persisted_config    = saved,
    })
    check(inp2:label_for('confirm', 'gamepad') == 'X', 'T9: relaunch re-imports updated FFXI confirm=X')
    check(inp2:label_for('module_prev', 'gamepad') == 'LT', 'T9: relaunch preserves Soulspire override LT')
end

-- 10. Controller disconnect & reconnect
do
    local present = true
    local t = 100.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 13, cancel = 12, options = 14, menu = 15 }
        end,
        gamepad_state_fn = function() return { present = present, idle = 0 } end,
    })
    -- Hold D-Pad down
    inp:filter_xinput_state(make_xinput_buf(bit.lshift(1, 1)), make_xinput_buf(0), function() return true end, true, t, 0)
    check(next(inp.pad_owner) ~= nil, 'T10: pad_owner populated while button held')

    -- Disconnect controller
    present = false
    inp:tick(t + 0.1, function() end, true)
    check(inp:get_diagnostics().controller_present == false, 'T10: disconnect detected')
    check(next(inp.pad_owner) == nil and next(inp.repeat_state) == nil, 'T10: disconnect clears stale holds/repeats')

    -- Reconnect controller
    present = true
    inp:tick(t + 0.2, function() end, true)
    check(inp:get_diagnostics().controller_present == true, 'T10: reconnect detected')
end

-- 11. Mouse <-> Controller switching
do
    local t = 110.0
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 13, cancel = 12, options = 14, menu = 15 }
        end,
    })
    inp:on_mouse_activity(t)
    check(inp.last_device == 'mouse', 'T11: mouse activity switches last_device to mouse')
    check(inp:label_for('confirm') == 'Enter', 'T11: mouse mode prompt shows Enter')

    inp:filter_xinput_state(make_xinput_buf(bit.lshift(1, 13)), make_xinput_buf(0), function() return true end, true, t + 0.1, 0)
    check(inp.last_device == 'gamepad', 'T11: gamepad press switches last_device back to gamepad')
    check(inp:label_for('confirm') == 'B', 'T11: gamepad mode prompt shows inherited B')
end

-- 12. Restoration of normal FFXI controls after closing Core
do
    local t = 120.0
    local reg = Registry.new()
    local foc = Focus.new(reg)
    local inp = Input.new({
        clock = function() return t end,
        gamepad_bindings_fn = function()
            return { xinput = true, confirm = 13, cancel = 12, options = 14, menu = 15 }
        end,
    })
    foc:open_hub()
    -- Press swapped cancel (A = bit 12) -> closes Core
    local bufClose = make_xinput_buf(bit.lshift(1, 12))
    inp:filter_xinput_state(bufClose, bufClose, function(a) return foc:handle_action(a) end, foc:is_hub_open(), t, 0)
    check(not foc:is_hub_open(), 'T12: swapped cancel closes Core hub')

    -- Next frame with Core closed: FFXI input MUST pass through untouched!
    local bufGame = make_xinput_buf(bit.lshift(1, 13), 0, 0, 25000, 0)
    local consumed = inp:filter_xinput_state(bufGame, bufGame, function() return true end, foc:is_hub_open(), t + 0.05, 0)
    check(consumed == false, 'T12: closed hub does not consume XInput state')
    check(bufGame.Gamepad.wButtons == bit.lshift(1, 13) and bufGame.Gamepad.sThumbLX == 25000,
        'T12: FFXI receives full unzeroed controller state after Core closes')
end

print(string.format('Controller Binding Regression Tests: %d passed, %d failed', passed, failed))
if failed > 0 then os.exit(1) end
