-- SoulspireXI Core: keyboard & controller input mapping with ownership tracking.
-- Reuses the verified key ownership pattern from crystalsocket.lua so consumed
-- presses (and their repeats while held) never leak to FFXI's underlying menu.

local Input = {}
Input.__index = Input

-- DirectInput keyboard scan codes (DIK_*)
Input.KEY_MAP = {
    [1]   = 'cancel',     -- Escape
    [15]  = 'focus_dock', -- Tab (clean handoff while FFXI Main Menu is active)
    [28]  = 'confirm',    -- Enter
    [156] = 'confirm',    -- Numpad Enter
    [200] = 'up',         -- Up Arrow
    [208] = 'down',       -- Down Arrow
    [203] = 'left',       -- Left Arrow
    [205] = 'right',      -- Right Arrow
}

-- Ashita v4 XInput button indices (xinput_button event e.button)
-- 0..3: D-Pad Up/Down/Left/Right; 8/9: LB/RB; 12/13: A/B
Input.XINPUT_BUTTON_MAP = {
    [0]  = 'up',         -- DPAD_UP
    [1]  = 'down',       -- DPAD_DOWN
    [2]  = 'left',       -- DPAD_LEFT
    [3]  = 'right',      -- DPAD_RIGHT
    [8]  = 'focus_dock', -- LEFT_SHOULDER (LB)
    [9]  = 'focus_dock', -- RIGHT_SHOULDER (RB)
    [12] = 'confirm',    -- A
    [13] = 'cancel',     -- B
}

-- Ashita v4 DirectInput button indices (dinput_button event e.button)
-- Standard FFXI PlayOnline gamepad layout (Confirm=1/2, Cancel=0/1 varies;
-- map standard face/shoulder buttons conservatively and POV hat for D-Pad).
Input.DINPUT_BUTTON_MAP = {
    [1] = 'confirm',    -- Cross / A (common FFXI DInput confirm)
    [2] = 'cancel',     -- Circle / B (common FFXI DInput cancel)
    [4] = 'focus_dock', -- L1 / LB
    [5] = 'focus_dock', -- R1 / RB
}

-- DirectInput POV hat angles (in hundredths of a degree)
function Input.dinput_pov_action(angle)
    if type(angle) ~= 'number' or angle < 0 or angle == 0xFFFF or angle == 0xFFFFFFFF then
        return nil
    end
    if angle == 0 then return 'up' end
    if angle == 9000 then return 'right' end
    if angle == 18000 then return 'down' end
    if angle == 27000 then return 'left' end
    return nil
end

function Input.new()
    return setmetatable({
        key_owner = {},     -- [scan] = nil (released) | false (native) | true (addon)
        pad_owner = {},     -- [token] = nil (released) | false (native) | true (addon)
    }, Input)
end

function Input:reset()
    self.key_owner = {}
    self.pad_owner = {}
end

function Input:release_key(scan)
    self.key_owner[scan] = nil
end

-- Handle a keyboard press/release with per-scan ownership.
-- dispatch_fn(action) -> boolean (true if consumed by SoulspireXI Core).
function Input:on_key(scan, down, chat_open, dispatch_fn)
    local action = Input.KEY_MAP[scan]
    if not action then return false end

    if not down then
        local owned = self.key_owner[scan] == true
        self.key_owner[scan] = nil
        return owned
    end

    if self.key_owner[scan] ~= nil then
        return self.key_owner[scan] == true
    end

    self.key_owner[scan] = false
    if chat_open then
        return false
    end

    if dispatch_fn(action) then
        self.key_owner[scan] = true
        return true
    end
    return false
end

-- Handle a controller button press/release (XInput or DirectInput).
function Input:on_pad(source, button_id, down, dispatch_fn)
    local map = (source == 'xinput') and Input.XINPUT_BUTTON_MAP or Input.DINPUT_BUTTON_MAP
    local action = map[button_id]
    if not action then return false end

    local token = source .. ':' .. tostring(button_id)
    if not down then
        local owned = self.pad_owner[token] == true
        self.pad_owner[token] = nil
        return owned
    end

    if self.pad_owner[token] ~= nil then
        return self.pad_owner[token] == true
    end

    self.pad_owner[token] = false
    if dispatch_fn(action) then
        self.pad_owner[token] = true
        return true
    end
    return false
end

-- Handle DirectInput POV hat state transitions.
function Input:on_dinput_pov(angle, dispatch_fn)
    local action = Input.dinput_pov_action(angle)
    local token = 'dinput:pov'
    if not action then
        local owned = self.pad_owner[token] == true
        self.pad_owner[token] = nil
        return owned
    end

    if self.pad_owner[token] ~= nil then
        return self.pad_owner[token] == true
    end

    self.pad_owner[token] = false
    if dispatch_fn(action) then
        self.pad_owner[token] = true
        return true
    end
    return false
end

return Input
