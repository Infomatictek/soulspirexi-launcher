-- SoulspireXI Core: unified Keyboard, XInput, and DirectInput controller handler.
--
-- Features:
--   - Default gamepad controls:
--       LB / RB        : Switch Core modules (or focus Soulspire on FFXI Main Menu)
--       D-Pad / L-Stick: Directional navigation with deadzone, hysteresis & hold-to-repeat
--       A              : Confirm / Select
--       B              : Back / Close
--       X              : Context-sensitive action
--       Y              : Details / Help
--   - Full keyboard equivalents + configurable bindings per device.
--   - Strict input isolation: while Core Hub owns focus, ALL gamepad buttons/axes/sticks
--     and relevant keyboard movement/menu keys are consumed so nothing leaks into FFXI.
--   - Immediate control restoration on close, keeping physically held keys owned only
--     until physical release to prevent phantom inputs in FFXI.

local Input = {}
Input.__index = Input

-- Default DirectInput keyboard scan codes (DIK_*)
Input.DEFAULT_KEY_MAP = {
    [1]   = 'cancel',      -- Escape
    [14]  = 'cancel',      -- Backspace
    [15]  = 'focus_dock',  -- Tab (handoff on Main Menu; region cycle inside Core)
    [16]  = 'module_prev', -- Q
    [18]  = 'module_next', -- E
    [26]  = 'module_prev', -- [
    [27]  = 'module_next', -- ]
    [28]  = 'confirm',     -- Enter
    [33]  = 'context',     -- F
    [35]  = 'details',     -- H
    [45]  = 'context',     -- X
    [21]  = 'details',     -- Y
    [57]  = 'confirm',     -- Space
    [59]  = 'details',     -- F1
    [156] = 'confirm',     -- Numpad Enter
    [200] = 'up',          -- Up Arrow
    [201] = 'module_prev', -- PageUp
    [203] = 'left',        -- Left Arrow
    [205] = 'right',       -- Right Arrow
    [208] = 'down',        -- Down Arrow
    [209] = 'module_next', -- PageDown
    [211] = 'context',     -- Delete
}

-- Extra keyboard scan codes blocked from leaking movement/camera into FFXI while Core Hub is open
-- (unless user is typing in an ImGui text field or chat input).
Input.HUB_BLOCKED_KEYS = {
    [17] = true, -- W
    [30] = true, -- A
    [31] = true, -- S
    [32] = true, -- D
    [72] = true, -- Numpad 8
    [75] = true, -- Numpad 4
    [77] = true, -- Numpad 6
    [80] = true, -- Numpad 2
}

-- Default Ashita v4 XInput button indices (xinput_button event e.button)
-- 0..3: D-Pad Up/Down/Left/Right; 8/9: LB/RB; 12/13/14/15: A/B/X/Y
Input.DEFAULT_XINPUT_MAP = {
    [0]  = 'up',          -- DPAD_UP
    [1]  = 'down',        -- DPAD_DOWN
    [2]  = 'left',        -- DPAD_LEFT
    [3]  = 'right',       -- DPAD_RIGHT
    [8]  = 'module_prev', -- LEFT_SHOULDER (LB)
    [9]  = 'module_next', -- RIGHT_SHOULDER (RB)
    [12] = 'confirm',     -- A
    [13] = 'cancel',      -- B
    [14] = 'context',     -- X
    [15] = 'details',     -- Y
}

-- Default Ashita v4 DirectInput button indices (dinput_button event e.button)
Input.DEFAULT_DINPUT_MAP = {
    [0] = 'context',      -- Square / X
    [1] = 'confirm',      -- Cross / A (standard FFXI DInput confirm)
    [2] = 'cancel',       -- Circle / B (standard FFXI DInput cancel)
    [3] = 'details',      -- Triangle / Y
    [4] = 'module_prev',  -- L1 / LB
    [5] = 'module_next',  -- R1 / RB
}

-- Backward-compatible static table aliases
Input.KEY_MAP           = Input.DEFAULT_KEY_MAP
Input.XINPUT_BUTTON_MAP = Input.DEFAULT_XINPUT_MAP
Input.DINPUT_BUTTON_MAP = Input.DEFAULT_DINPUT_MAP

-- XInput analog axis indices in Ashita v4 xinput_button (when emitted per-axis)
Input.XINPUT_AXIS_LX = 18
Input.XINPUT_AXIS_LY = 19

-- Directional actions eligible for hold-to-repeat
local REPEATABLE = { up = true, down = true, left = true, right = true }

local function shallow_copy(tbl)
    local out = {}
    for k, v in pairs(tbl or {}) do
        out[k] = v
    end
    return out
end

-- DirectInput POV hat angles (hundredths of a degree)
function Input.dinput_pov_action(angle)
    if type(angle) ~= 'number' or angle < 0 or angle == 0xFFFF or angle == 0xFFFFFFFF then
        return nil
    end
    if angle == 0 or angle == 36000 then return 'up' end
    if angle == 9000 then return 'right' end
    if angle == 18000 then return 'down' end
    if angle == 27000 then return 'left' end
    -- Cardinal bias for diagonals
    if angle > 31500 or angle < 4500 then return 'up' end
    if angle >= 4500 and angle < 13500 then return 'right' end
    if angle >= 13500 and angle < 22500 then return 'down' end
    if angle >= 22500 and angle <= 31500 then return 'left' end
    return nil
end

function Input.new(opts)
    opts = opts or {}
    local self = setmetatable({
        key_map         = shallow_copy(Input.DEFAULT_KEY_MAP),
        xinput_map      = shallow_copy(Input.DEFAULT_XINPUT_MAP),
        dinput_map      = shallow_copy(Input.DEFAULT_DINPUT_MAP),
        key_owner       = {}, -- [scan] = nil | false (native) | true (addon)
        pad_owner       = {}, -- [token] = nil | false (native) | true (addon)
        repeat_state    = {}, -- [token] = { action = str, next_at = num }
        stick_dir       = nil,
        stick_lx        = 0,
        stick_ly        = 0,
        stick_deadzone  = tonumber(opts.stick_deadzone) or 0.42,
        stick_release   = tonumber(opts.stick_release) or 0.25,
        repeat_delay    = tonumber(opts.repeat_delay) or 0.32,
        repeat_interval = tonumber(opts.repeat_interval) or 0.11,
        clock           = opts.clock or os.clock,
        confirm_guard_until = 0,
        last_device     = 'gamepad',
    }, Input)

    if type(opts.bindings) == 'table' then
        self:apply_bindings(opts.bindings)
    end
    return self
end

function Input:apply_bindings(bindings)
    if type(bindings) ~= 'table' then return end
    if type(bindings.keyboard) == 'table' then
        for code, action in pairs(bindings.keyboard) do
            local n = tonumber(code)
            if n and type(action) == 'string' then self.key_map[n] = action end
        end
    end
    if type(bindings.xinput) == 'table' then
        for code, action in pairs(bindings.xinput) do
            local n = tonumber(code)
            if n and type(action) == 'string' then self.xinput_map[n] = action end
        end
    end
    if type(bindings.dinput) == 'table' then
        for code, action in pairs(bindings.dinput) do
            local n = tonumber(code)
            if n and type(action) == 'string' then self.dinput_map[n] = action end
        end
    end
end

function Input:set_binding(device, action, code)
    local map = (device == 'keyboard' and self.key_map)
        or (device == 'xinput' and self.xinput_map)
        or (device == 'dinput' and self.dinput_map)
    local n = tonumber(code)
    if not map or type(action) ~= 'string' or action == '' or not n then
        return false
    end
    map[n] = action
    return true
end

function Input:reset_bindings()
    self.key_map    = shallow_copy(Input.DEFAULT_KEY_MAP)
    self.xinput_map = shallow_copy(Input.DEFAULT_XINPUT_MAP)
    self.dinput_map = shallow_copy(Input.DEFAULT_DINPUT_MAP)
end

function Input:get_bindings()
    return {
        keyboard = shallow_copy(self.key_map),
        xinput   = shallow_copy(self.xinput_map),
        dinput   = shallow_copy(self.dinput_map),
    }
end

function Input:watched_keys()
    local keys = {}
    for scan in pairs(self.key_map) do keys[scan] = true end
    for scan in pairs(Input.HUB_BLOCKED_KEYS) do keys[scan] = true end
    return keys
end

function Input:reset()
    self.key_owner = {}
    self.pad_owner = {}
    self.repeat_state = {}
    self.stick_dir = nil
    self.stick_lx = 0
    self.stick_ly = 0
    self.confirm_guard_until = 0
end

-- Suppress accidental double-confirm inside Core immediately after opening from
-- FFXI's native Commands menu via Confirm (Enter / Gamepad A).
function Input:arm_open_guard(seconds)
    local dur = tonumber(seconds) or 0.18
    self.confirm_guard_until = self.clock() + dur
end

function Input:_confirm_guarded(action)
    return action == 'confirm' and self.confirm_guard_until > 0 and self.clock() < self.confirm_guard_until
end

function Input:release_key(scan)
    self.key_owner[scan] = nil
    self.repeat_state['key:' .. tostring(scan)] = nil
end

local function arm_repeat(self, token, action, now)
    if REPEATABLE[action] then
        self.repeat_state[token] = {
            action  = action,
            next_at = (now or self.clock()) + self.repeat_delay,
        }
    end
end

-- Pump directional hold-to-repeat while keys/D-Pad/Left Stick are held down.
function Input:tick(now, dispatch_fn, hub_open)
    if not hub_open then
        self.repeat_state = {}
        return 0
    end
    local ts = now or self.clock()
    local fired = 0
    for token, st in pairs(self.repeat_state) do
        if ts >= st.next_at then
            st.next_at = ts + self.repeat_interval
            if type(dispatch_fn) == 'function' then
                dispatch_fn(st.action)
                fired = fired + 1
            end
        end
    end
    return fired
end

-- Handle a keyboard press/release with per-scan ownership and strict Hub isolation.
-- hub_open (optional boolean): when true, even unmapped movement keys are captured so
-- keyboard input never moves the character behind Core.
function Input:on_key(scan, down, chat_open, dispatch_fn, hub_open, text_input_active)
    local action = self.key_map[scan]
    local is_blocked_world_key = (hub_open == true) and (Input.HUB_BLOCKED_KEYS[scan] == true)
    if not action and not is_blocked_world_key then
        return false
    end

    local token = 'key:' .. tostring(scan)
    if not down then
        local owned = self.key_owner[scan] == true
        self.key_owner[scan] = nil
        self.repeat_state[token] = nil
        return owned
    end

    if self.key_owner[scan] ~= nil then
        return self.key_owner[scan] == true
    end

    self.key_owner[scan] = false
    if chat_open or (text_input_active and action ~= 'cancel') then
        return false
    end

    if hub_open == true and self:_confirm_guarded(action) then
        self.key_owner[scan] = true
        return true
    end

    if action and type(dispatch_fn) == 'function' and dispatch_fn(action) then
        self.key_owner[scan] = true
        self.last_device = 'keyboard'
        arm_repeat(self, token, action, self.clock())
        return true
    end

    if hub_open == true then
        self.key_owner[scan] = true
        return true
    end

    return false
end

-- Handle a controller button press/release (XInput or DirectInput).
-- When hub_open == true, EVERY controller button (mapped or unmapped) is blocked from FFXI!
function Input:on_pad(source, button_id, down, dispatch_fn, hub_open)
    local map = (source == 'xinput') and self.xinput_map or self.dinput_map
    local action = map[button_id]
    local token = source .. ':' .. tostring(button_id)

    if not down then
        local owned = self.pad_owner[token] == true
        self.pad_owner[token] = nil
        self.repeat_state[token] = nil
        return owned or (hub_open == true)
    end

    if self.pad_owner[token] ~= nil then
        return (self.pad_owner[token] == true) or (hub_open == true)
    end

    self.pad_owner[token] = false
    if hub_open == true and self:_confirm_guarded(action) then
        self.pad_owner[token] = true
        self.last_device = 'gamepad'
        return true
    end
    if action and type(dispatch_fn) == 'function' and dispatch_fn(action) then
        self.pad_owner[token] = true
        self.last_device = 'gamepad'
        arm_repeat(self, token, action, self.clock())
        return true
    end

    if hub_open == true then
        -- Unmapped controller buttons MUST NOT leak into FFXI while Core is open.
        self.pad_owner[token] = true
        self.last_device = 'gamepad'
        return true
    end

    return false
end

-- Handle DirectInput POV hat state transitions.
function Input:on_dinput_pov(angle, dispatch_fn, hub_open)
    local action = Input.dinput_pov_action(angle)
    local token = 'dinput:pov'

    if not action then
        local owned = self.pad_owner[token] == true
        self.pad_owner[token] = nil
        self.repeat_state[token] = nil
        return owned or (hub_open == true)
    end

    -- Allow immediate direction change while POV hat is rolled from one direction to another
    if self.pad_owner[token] ~= nil and self.repeat_state[token] and self.repeat_state[token].action == action then
        return (self.pad_owner[token] == true) or (hub_open == true)
    end

    self.pad_owner[token] = false
    self.repeat_state[token] = nil
    if type(dispatch_fn) == 'function' and dispatch_fn(action) then
        self.pad_owner[token] = true
        self.last_device = 'gamepad'
        arm_repeat(self, token, action, self.clock())
        return true
    end

    if hub_open == true then
        self.pad_owner[token] = true
        return true
    end
    return false
end

-- Convert normalized Left Stick coordinates (nx, ny in [-1, 1], +y = up) into directional actions
-- with deadzone, hysteresis, and hold-to-repeat.
function Input:on_left_stick(nx, ny, dispatch_fn, hub_open, now)
    local x = tonumber(nx) or 0
    local y = tonumber(ny) or 0
    local mag = math.max(math.abs(x), math.abs(y))
    local token = 'pad:lstick'

    if not hub_open then
        self.stick_dir = nil
        self.repeat_state[token] = nil
        return false
    end

    if self.stick_dir ~= nil and mag < self.stick_release then
        self.stick_dir = nil
        self.repeat_state[token] = nil
        return true
    end

    local new_dir = nil
    if mag >= self.stick_deadzone then
        if math.abs(x) >= math.abs(y) then
            new_dir = (x > 0) and 'right' or 'left'
        else
            new_dir = (y > 0) and 'up' or 'down'
        end
    end

    if new_dir ~= nil and new_dir ~= self.stick_dir then
        self.stick_dir = new_dir
        self.last_device = 'gamepad'
        if type(dispatch_fn) == 'function' then
            dispatch_fn(new_dir)
        end
        arm_repeat(self, token, new_dir, now or self.clock())
    elseif new_dir == nil and self.stick_dir == nil then
        self.repeat_state[token] = nil
    end
    return true
end

-- Helper for Ashita v4 xinput_button axis events (18 = LX, 19 = LY, range -32768..32767)
function Input:on_xinput_axis(button_id, value, dispatch_fn, hub_open, now)
    local v = tonumber(value) or 0
    if button_id == Input.XINPUT_AXIS_LX then
        self.stick_lx = math.max(-1, math.min(1, v / 32767))
        return self:on_left_stick(self.stick_lx, self.stick_ly, dispatch_fn, hub_open, now)
    elseif button_id == Input.XINPUT_AXIS_LY then
        self.stick_ly = math.max(-1, math.min(1, v / 32767))
        return self:on_left_stick(self.stick_lx, self.stick_ly, dispatch_fn, hub_open, now)
    end
    return hub_open == true
end

-- Filter raw Ashita v4 XINPUT_STATE table/cdata:
-- Reads Left Stick for Core navigation AND zeroes modified state when Core Hub owns focus
-- so FFXI character movement / camera / macro triggers never fire behind Core.
-- All cdata field accesses are pcall-guarded so differing Ashita v4 FFI layouts never error.
function Input:filter_xinput_state(state_obj, modified_obj, dispatch_fn, hub_open, now)
    if not hub_open then
        self.stick_dir = nil
        self.repeat_state['pad:lstick'] = nil
        return false
    end

    if state_obj ~= nil then
        local ok, lx, ly = pcall(function()
            local gp = nil
            local okG, g1 = pcall(function() return state_obj.Gamepad end)
            if okG and g1 ~= nil then
                gp = g1
            else
                local okG2, g2 = pcall(function() return state_obj.gamepad end)
                gp = (okG2 and g2 ~= nil) and g2 or state_obj
            end
            return tonumber(gp.sThumbLX) or 0, tonumber(gp.sThumbLY) or 0
        end)
        if ok then
            self.stick_lx = math.max(-1, math.min(1, lx / 32767))
            self.stick_ly = math.max(-1, math.min(1, ly / 32767))
            self:on_left_stick(self.stick_lx, self.stick_ly, dispatch_fn, true, now)
        end
    end

    if modified_obj ~= nil then
        pcall(function()
            local mgp = nil
            local okG, g1 = pcall(function() return modified_obj.Gamepad end)
            if okG and g1 ~= nil then
                mgp = g1
            else
                local okG2, g2 = pcall(function() return modified_obj.gamepad end)
                mgp = (okG2 and g2 ~= nil) and g2 or modified_obj
            end
            mgp.wButtons      = 0
            mgp.bLeftTrigger  = 0
            mgp.bRightTrigger = 0
            mgp.sThumbLX      = 0
            mgp.sThumbLY      = 0
            mgp.sThumbRX      = 0
            mgp.sThumbRY      = 0
        end)
    end
    return true
end

-- Filter raw DirectInput joystick state table/cdata (DIJOYSTATE / DIJOYSTATE2).
-- Auto-detects 0..65535 vs -1000..1000 centered axes; neutralizes axes/buttons while hub_open.
function Input:filter_dinput_state(state_obj, modified_obj, dispatch_fn, hub_open, now)
    if not hub_open then
        return false
    end

    local is_unsigned = false
    if state_obj ~= nil then
        local ok, lx, ly = pcall(function()
            return tonumber(state_obj.lX), tonumber(state_obj.lY)
        end)
        if ok and lx and ly then
            if lx > 2000 or ly > 2000 then
                is_unsigned = true
                self.stick_lx = math.max(-1, math.min(1, (lx - 32767.5) / 32767.5))
                self.stick_ly = math.max(-1, math.min(1, -(ly - 32767.5) / 32767.5))
            else
                self.stick_lx = math.max(-1, math.min(1, lx / 1000))
                self.stick_ly = math.max(-1, math.min(1, -ly / 1000))
            end
            self:on_left_stick(self.stick_lx, self.stick_ly, dispatch_fn, true, now)
        end
    end

    if modified_obj ~= nil then
        pcall(function()
            local center = is_unsigned and 32767 or 0
            pcall(function() modified_obj.lX = center end)
            pcall(function() modified_obj.lY = center end)
            pcall(function() modified_obj.lZ = center end)
            pcall(function() modified_obj.lRx = center end)
            pcall(function() modified_obj.lRy = center end)
            pcall(function() modified_obj.lRz = center end)
            pcall(function()
                for i = 0, 3 do modified_obj.rgdwPOV[i] = 0xFFFFFFFF end
            end)
            pcall(function()
                for i = 0, 31 do modified_obj.rgbButtons[i] = 0 end
            end)
        end)
    end
    return true
end

return Input
