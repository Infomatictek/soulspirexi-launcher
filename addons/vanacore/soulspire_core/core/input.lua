-- SoulspireXI Core: unified Keyboard, XInput, and DirectInput controller handler
-- with automatic FFXI controller binding inheritance, Soulspire-specific overrides,
-- dynamic backend-aware button labels, conflict detection, and bounded diagnostics.
--
-- Features:
--   - Automatically imports the player's existing FFXI controller configuration from
--     VanaCore (`vana.gamepad.bindings()`, `vana.config.game('padmode000'|'padsin000')`)
--     without ever modifying or resetting FFXI's bindings.
--   - Cleanly separates physical controller input from logical UI actions:
--       confirm, cancel, up, down, left, right, context, details, module_prev, module_next.
--   - Persists ONLY Soulspire-specific overrides (`use_ffxi_bindings` + `overrides`).
--   - Preserves shared-buffer `xinput_state` / `dinput_state` edge detection (including LT/RT).
--   - Strict input isolation while Core Hub owns focus + immediate restoration on close.

local bit = require('bit')
local Input = {}
Input.__index = Input

-- XInput control index labels (matching VanaCore src/core/gamepad.cpp)
Input.XINPUT_BUTTON_LABELS = {
    [0]  = 'D-Up',  [1]  = 'D-Down', [2]  = 'D-Left', [3]  = 'D-Right',
    [4]  = 'Start', [5]  = 'Back',   [6]  = 'L3',     [7]  = 'R3',
    [8]  = 'LB',    [9]  = 'RB',
    [12] = 'A',     [13] = 'B',      [14] = 'X',      [15] = 'Y',
    [16] = 'LT',    [17] = 'RT',
}

-- Ordered selectable physical controls for the in-game Controller Bindings settings UI
Input.XINPUT_BINDABLE_CODES = { 12, 13, 14, 15, 8, 9, 16, 17, 4, 5, 6, 7, 0, 1, 2, 3 }
Input.DINPUT_BINDABLE_CODES = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }

-- Logical UI actions exposed for binding resolution, prompts, and Settings UI
Input.CONFIGURABLE_ACTIONS = {
    { id = 'confirm',     label = 'Confirm / Select' },
    { id = 'cancel',      label = 'Cancel / Back' },
    { id = 'context',     label = 'Context Action' },
    { id = 'details',     label = 'Help / Details' },
    { id = 'module_prev', label = 'Previous Module' },
    { id = 'module_next', label = 'Next Module' },
    { id = 'up',          label = 'Navigate Up' },
    { id = 'down',        label = 'Navigate Down' },
    { id = 'left',        label = 'Navigate Left' },
    { id = 'right',       label = 'Navigate Right' },
}

-- FFXI XInput padsin000 button ID -> VanaCore XInput control index (matches gamepad.cpp kXView[16])
local FFXI_XINPUT_SLOT_TO_CONTROL = {
    [0] = 13, [1] = 14, [2] = 15, [3] = 12,
    [4] = 3,  [5] = 2,  [6] = 0,  [7] = 1,
    [8] = 8,  [9] = 16, [10] = 6, [11] = 9,
    [12] = 17,[13] = 7, [14] = 4, [15] = 5,
}
local FFXI_SLOT_CANCEL  = 5
local FFXI_SLOT_MENU    = 6
local FFXI_SLOT_CONFIRM = 7
local FFXI_SLOT_OPTIONS = 8

local XINPUT_TRIGGER_THRESHOLD = 30

-- Default DirectInput keyboard scan codes (DIK_*)
Input.DEFAULT_KEY_MAP = {
    [1]   = 'cancel',      -- Escape
    [14]  = 'cancel',      -- Backspace
    [15]  = 'focus_dock',  -- Tab (handoff on Main Menu; region cycle inside Core)
    [16]  = 'module_prev',  -- Q
    [18]  = 'module_next',  -- E
    [19]  = 'respec_ws',    -- R (Respec active WS)
    [20]  = 'toggle_paths', -- T (Toggle path spotlight in Soulforge)
    [26]  = 'module_prev',  -- [
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

-- Default VanaCore/Ashita XInput control indices (0..17)
Input.DEFAULT_XINPUT_MAP = {
    [0]  = 'up',          -- DPAD_UP
    [1]  = 'down',        -- DPAD_DOWN
    [2]  = 'left',        -- DPAD_LEFT
    [3]  = 'right',       -- DPAD_RIGHT
    [8]  = 'module_prev', -- LB
    [9]  = 'module_next', -- RB
    [12] = 'confirm',     -- A
    [13] = 'cancel',      -- B
    [14] = 'context',     -- X
    [15] = 'details',     -- Y
}

-- Default DirectInput 0-based button indices (0..31)
Input.DEFAULT_DINPUT_MAP = {
    [0] = 'context',      -- Btn 1
    [1] = 'confirm',      -- Btn 2
    [2] = 'cancel',       -- Btn 3
    [3] = 'details',      -- Btn 4
    [4] = 'module_prev',  -- Btn 5
    [5] = 'module_next',  -- Btn 6
}

-- Backward-compatible static table aliases
Input.KEY_MAP           = Input.DEFAULT_KEY_MAP
Input.XINPUT_BUTTON_MAP = Input.DEFAULT_XINPUT_MAP
Input.DINPUT_BUTTON_MAP = Input.DEFAULT_DINPUT_MAP

-- XInput analog axis indices in xinput_button
Input.XINPUT_AXIS_LX = 18
Input.XINPUT_AXIS_LY = 19

local REPEATABLE = { up = true, down = true, left = true, right = true }

local KEYBOARD_ACTION_LABELS = {
    confirm     = 'Enter',
    cancel      = 'Esc',
    context     = 'X',
    details     = 'Y',
    module_prev = 'Q',
    module_next = 'E',
    up          = 'Up',
    down        = 'Down',
    left        = 'Left',
    right       = 'Right',
    nav         = 'Arrows',
}

local function shallow_copy(tbl)
    local out = {}
    for k, v in pairs(tbl or {}) do
        out[k] = v
    end
    return out
end

local function parse_csv_field(text, index0)
    if type(text) ~= 'string' or text == '' then return nil end
    local i = 0
    for token in (text .. ','):gmatch('([^,]*),') do
        if i == index0 then
            return tonumber(token:match('^%s*(.-)%s*$'))
        end
        i = i + 1
    end
    return nil
end

function Input.button_label(backend, code)
    local n = tonumber(code)
    if not n then return '?' end
    if backend == 'dinput' then
        return 'Btn ' .. tostring(n + 1)
    end
    return Input.XINPUT_BUTTON_LABELS[n] or ('Btn ' .. tostring(n))
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
    if angle > 31500 or angle < 4500 then return 'up' end
    if angle >= 4500 and angle < 13500 then return 'right' end
    if angle >= 13500 and angle < 22500 then return 'down' end
    if angle >= 22500 and angle <= 31500 then return 'left' end
    return nil
end

function Input.new(opts)
    opts = opts or {}
    local self = setmetatable({
        key_map             = shallow_copy(Input.DEFAULT_KEY_MAP),
        xinput_map          = shallow_copy(Input.DEFAULT_XINPUT_MAP),
        dinput_map          = shallow_copy(Input.DEFAULT_DINPUT_MAP),
        action_codes        = { xinput = {}, dinput = {} },
        action_provenance   = { xinput = {}, dinput = {} },
        use_ffxi_bindings   = (opts.use_ffxi_bindings ~= false),
        overrides           = { xinput = {}, dinput = {} },
        ffxi_raw            = nil,
        ffxi_import_ok      = false,
        ffxi_import_detail  = 'not_imported',
        detected_backend    = 'xinput',
        active_backend      = 'xinput',
        config_source       = 'defaults',
        conflicts           = { xinput = {}, dinput = {} },
        gamepad_bindings_fn = opts.gamepad_bindings_fn,
        gamepad_state_fn    = opts.gamepad_state_fn,
        config_game_fn      = opts.config_game_fn,
        on_bindings_change  = opts.on_bindings_change,
        controller_present  = true,
        key_owner           = {},
        pad_owner           = {},
        repeat_state        = {},
        stick_dir           = nil,
        stick_lx            = 0,
        stick_ly            = 0,
        stick_deadzone      = tonumber(opts.stick_deadzone) or 0.42,
        stick_release       = tonumber(opts.stick_release) or 0.25,
        repeat_delay        = tonumber(opts.repeat_delay) or 0.32,
        repeat_interval     = tonumber(opts.repeat_interval) or 0.11,
        clock               = opts.clock or os.clock,
        confirm_guard_until = 0,
        last_device         = 'gamepad',
        xinput_active_user  = 0,
        diag = {
            detected_backend      = 'xinput',
            active_backend        = 'xinput',
            config_source         = 'defaults',
            ffxi_imported         = false,
            ffxi_import_detail    = 'not_imported',
            controller_present    = true,
            binding_status        = '',
            conflict_count        = 0,
            conflict_summary      = 'none',
            raw_button_mask       = 0,
            last_physical_button  = 'none',
            last_button_state     = 'idle',
            last_action           = 'none',
            last_action_provenance = 'default',
            last_action_reached   = false,
            stick_dir             = 'neutral',
            active_mode           = 'gamepad',
        },
    }, Input)

    self:import_ffxi_bindings()

    if type(opts.persisted_config) == 'table' then
        self:load_persisted_config(opts.persisted_config)
    elseif type(opts.bindings) == 'table' then
        self:apply_bindings(opts.bindings)
    end
    return self
end

function Input:_query_ffxi_bindings()
    local getter = self.gamepad_bindings_fn
    if type(getter) ~= 'function' and type(vana) == 'table' and vana.gamepad and type(vana.gamepad.bindings) == 'function' then
        getter = vana.gamepad.bindings
    end
    if type(getter) == 'function' then
        local ok, res = pcall(getter)
        if ok and type(res) == 'table' then
            return {
                xinput  = (res.xinput ~= false),
                confirm = tonumber(res.confirm) or -1,
                cancel  = tonumber(res.cancel) or -1,
                menu    = tonumber(res.menu) or -1,
                options = tonumber(res.options) or -1,
                via     = 'vana.gamepad.bindings',
            }
        end
    end

    -- Fallback: read raw FFXI registry strings from VanaCore config layer if available
    local cfg_fn = self.config_game_fn
    if type(cfg_fn) ~= 'function' and type(vana) == 'table' and vana.config and type(vana.config.game) == 'function' then
        cfg_fn = vana.config.game
    end
    if type(cfg_fn) == 'function' then
        local okM, padmode = pcall(cfg_fn, 'padmode000')
        local okB, padsin  = pcall(cfg_fn, 'padsin000')
        if (okM and type(padmode) == 'string' and padmode ~= '') or (okB and type(padsin) == 'string' and padsin ~= '') then
            local mode_flag = parse_csv_field(padmode, 5)
            local is_xinput = (mode_flag == nil) or (mode_flag == 1)
            local function slot_val(idx)
                local raw = parse_csv_field(padsin, idx)
                if raw == nil or raw < 0 then return -1 end
                if is_xinput then
                    return FFXI_XINPUT_SLOT_TO_CONTROL[raw] or -1
                end
                return raw
            end
            return {
                xinput  = is_xinput,
                confirm = slot_val(FFXI_SLOT_CONFIRM),
                cancel  = slot_val(FFXI_SLOT_CANCEL),
                menu    = slot_val(FFXI_SLOT_MENU),
                options = slot_val(FFXI_SLOT_OPTIONS),
                via     = 'vana.config.game',
            }
        end
    end
    return nil
end

local function has_any_overrides(overrides_tbl)
    if type(overrides_tbl) ~= 'table' then return false end
    for _ in pairs(overrides_tbl.xinput or {}) do return true end
    for _ in pairs(overrides_tbl.dinput or {}) do return true end
    return false
end

function Input:_build_backend_map(backend)
    local defaults = (backend == 'xinput') and Input.DEFAULT_XINPUT_MAP or Input.DEFAULT_DINPUT_MAP
    local face_pool = (backend == 'xinput') and { 12, 13, 14, 15 } or { 0, 1, 2, 3 }

    -- Start with default action -> code
    local action_to_code = {}
    local provenance = {}
    for code, action in pairs(defaults) do
        action_to_code[action] = code
        provenance[action] = 'default'
    end

    -- Layer 2: Inherited FFXI bindings (when enabled and matching backend)
    local raw = self.ffxi_raw
    local inherited_applied = false
    if self.use_ffxi_bindings and type(raw) == 'table' then
        local raw_backend = raw.xinput and 'xinput' or 'dinput'
        if raw_backend == backend then
            local used = {}
            local inherited_actions = {}

            local function assign_inherited(action, code)
                if type(code) == 'number' and code >= 0 and not used[code] then
                    action_to_code[action] = code
                    provenance[action] = 'inherited'
                    used[code] = action
                    inherited_actions[action] = true
                    inherited_applied = true
                end
            end

            assign_inherited('confirm', raw.confirm)
            assign_inherited('cancel',  raw.cancel)
            assign_inherited('context', raw.options)
            assign_inherited('details', raw.menu)

            -- If FFXI bindings displaced a non-inherited face-button default (e.g. swapped A/B or Confirm on X),
            -- relocate the displaced default action onto an unused face button so there are zero default collisions.
            for _, act in ipairs({ 'confirm', 'cancel', 'context', 'details' }) do
                if not inherited_actions[act] then
                    local cur = action_to_code[act]
                    if cur ~= nil and used[cur] and used[cur] ~= act then
                        for _, cand in ipairs(face_pool) do
                            if not used[cand] then
                                action_to_code[act] = cand
                                used[cand] = act
                                break
                            end
                        end
                    elseif cur ~= nil then
                        used[cur] = act
                    end
                end
            end
        end
    end

    -- Layer 3: Soulspire-specific overrides (action -> code)
    local ov = (self.overrides and self.overrides[backend]) or {}
    for action, code in pairs(ov) do
        local n = tonumber(code)
        if type(action) == 'string' and n ~= nil and n >= 0 then
            action_to_code[action] = n
            provenance[action] = 'overridden'
        end
    end

    -- Build physical code -> action lookup and detect conflicts
    local code_to_action = {}
    local code_actions = {}
    local ordered_actions = {
        'confirm', 'cancel', 'context', 'details',
        'module_prev', 'module_next',
        'up', 'down', 'left', 'right',
    }
    -- Apply defaults/inherited first, then overrides last so explicit overrides win dispatch
    for _, pass in ipairs({ 'base', 'override' }) do
        for _, action in ipairs(ordered_actions) do
            local is_ov = (provenance[action] == 'overridden')
            if (pass == 'override' and is_ov) or (pass == 'base' and not is_ov) then
                local code = action_to_code[action]
                if type(code) == 'number' and code >= 0 then
                    code_to_action[code] = action
                end
            end
        end
    end

    for _, action in ipairs(ordered_actions) do
        local code = action_to_code[action]
        if type(code) == 'number' and code >= 0 then
            code_actions[code] = code_actions[code] or {}
            code_actions[code][#code_actions[code] + 1] = action
        end
    end

    local conflicts = {}
    for code, list in pairs(code_actions) do
        if #list > 1 then
            conflicts[#conflicts + 1] = {
                code    = code,
                label   = Input.button_label(backend, code),
                actions = list,
            }
        end
    end
    table.sort(conflicts, function(a, b) return a.code < b.code end)

    self.action_codes[backend]      = action_to_code
    self.action_provenance[backend] = provenance
    self.conflicts[backend]         = conflicts
    if backend == 'xinput' then
        self.xinput_map = code_to_action
    else
        self.dinput_map = code_to_action
    end
    return inherited_applied
end

function Input:_rebuild_maps()
    local xi_inh = self:_build_backend_map('xinput')
    local di_inh = self:_build_backend_map('dinput')
    local any_inh = xi_inh or di_inh
    local any_ov  = has_any_overrides(self.overrides)

    if self.use_ffxi_bindings and any_inh then
        self.config_source = any_ov and 'ffxi_plus_overrides' or 'ffxi_inherited'
    elseif any_ov then
        self.config_source = 'custom_overrides'
    else
        self.config_source = 'defaults'
    end

    local backend = self.active_backend or self.detected_backend or 'xinput'
    local c_list = self.conflicts[backend] or {}
    local c_parts = {}
    for _, c in ipairs(c_list) do
        c_parts[#c_parts + 1] = c.label .. ':' .. table.concat(c.actions, '+')
    end

    local status_parts = {}
    local prov = self.action_provenance[backend] or {}
    local codes = self.action_codes[backend] or {}
    for _, act in ipairs({ 'confirm', 'cancel', 'context', 'details', 'module_prev', 'module_next' }) do
        local tag = (prov[act] == 'inherited' and 'I') or (prov[act] == 'overridden' and 'O') or 'D'
        status_parts[#status_parts + 1] = string.format('%s=%s[%s]', act, Input.button_label(backend, codes[act]), tag)
    end

    self.diag.detected_backend   = self.detected_backend
    self.diag.active_backend     = backend
    self.diag.config_source      = self.config_source
    self.diag.ffxi_imported      = self.ffxi_import_ok
    self.diag.ffxi_import_detail = self.ffxi_import_detail
    self.diag.conflict_count     = #c_list
    self.diag.conflict_summary   = (#c_parts > 0) and table.concat(c_parts, ', ') or 'none'
    self.diag.binding_status     = table.concat(status_parts, ' ')
end

function Input:import_ffxi_bindings()
    local raw = self:_query_ffxi_bindings()
    if type(raw) == 'table' then
        self.ffxi_raw = raw
        self.detected_backend = raw.xinput and 'xinput' or 'dinput'
        self.active_backend = self.detected_backend
        local has_any = (raw.confirm >= 0 or raw.cancel >= 0 or raw.menu >= 0 or raw.options >= 0)
        self.ffxi_import_ok = has_any
        self.ffxi_import_detail = string.format('%s(%s c=%d x=%d m=%d o=%d)',
            tostring(raw.via or 'ffxi'),
            self.detected_backend, raw.confirm, raw.cancel, raw.menu, raw.options)
    else
        self.ffxi_raw = nil
        self.ffxi_import_ok = false
        self.ffxi_import_detail = 'unavailable_using_defaults'
    end
    self:_rebuild_maps()
    return self.ffxi_import_ok
end

function Input:set_use_ffxi_bindings(enabled)
    self.use_ffxi_bindings = (enabled == true)
    self:_rebuild_maps()
    if type(self.on_bindings_change) == 'function' then
        pcall(self.on_bindings_change, self)
    end
end

function Input:set_action_override(backend, action, code)
    local b = (backend == 'dinput') and 'dinput' or 'xinput'
    local n = tonumber(code)
    if type(action) ~= 'string' or action == '' or not n or n < 0 then
        return false
    end
    self.overrides[b] = self.overrides[b] or {}
    self.overrides[b][action] = n
    self:_rebuild_maps()
    if type(self.on_bindings_change) == 'function' then
        pcall(self.on_bindings_change, self)
    end
    return true
end

function Input:clear_action_override(backend, action)
    local b = (backend == 'dinput') and 'dinput' or 'xinput'
    if self.overrides[b] and self.overrides[b][action] ~= nil then
        self.overrides[b][action] = nil
        self:_rebuild_maps()
        if type(self.on_bindings_change) == 'function' then
            pcall(self.on_bindings_change, self)
        end
        return true
    end
    return false
end

function Input:cycle_action_override(backend, action, step)
    local b = (backend == 'dinput') and 'dinput' or 'xinput'
    local list = (b == 'dinput') and Input.DINPUT_BINDABLE_CODES or Input.XINPUT_BINDABLE_CODES
    local cur = self.action_codes[b] and self.action_codes[b][action]
    local idx = 1
    for i, c in ipairs(list) do
        if c == cur then idx = i break end
    end
    local delta = (tonumber(step) or 1) >= 0 and 1 or -1
    local next_idx = ((idx - 1 + delta) % #list) + 1
    return self:set_action_override(b, action, list[next_idx])
end

function Input:restore_inherited_bindings()
    self.overrides = { xinput = {}, dinput = {} }
    self.use_ffxi_bindings = true
    self:import_ffxi_bindings()
    if type(self.on_bindings_change) == 'function' then
        pcall(self.on_bindings_change, self)
    end
end

function Input:restore_standard_defaults()
    self.overrides = { xinput = {}, dinput = {} }
    self.use_ffxi_bindings = false
    self:_rebuild_maps()
    if type(self.on_bindings_change) == 'function' then
        pcall(self.on_bindings_change, self)
    end
end

-- Persist ONLY Soulspire-specific settings/overrides (never modifying or duplicating FFXI config)
function Input:get_persisted_config()
    return {
        use_ffxi_bindings = self.use_ffxi_bindings == true,
        overrides = {
            xinput = shallow_copy(self.overrides.xinput),
            dinput = shallow_copy(self.overrides.dinput),
        },
    }
end

function Input:load_persisted_config(cfg)
    if type(cfg) ~= 'table' then return end
    if cfg.use_ffxi_bindings ~= nil then
        self.use_ffxi_bindings = (cfg.use_ffxi_bindings == true)
    end
    self.overrides = { xinput = {}, dinput = {} }
    if type(cfg.overrides) == 'table' then
        if type(cfg.overrides.xinput) == 'table' then
            for act, code in pairs(cfg.overrides.xinput) do
                local n = tonumber(code)
                if type(act) == 'string' and n and n >= 0 then self.overrides.xinput[act] = n end
            end
        end
        if type(cfg.overrides.dinput) == 'table' then
            for act, code in pairs(cfg.overrides.dinput) do
                local n = tonumber(code)
                if type(act) == 'string' and n and n >= 0 then self.overrides.dinput[act] = n end
            end
        end
    end
    self:_rebuild_maps()
end

function Input:get_conflicts(backend)
    local b = backend or self.active_backend or self.detected_backend or 'xinput'
    return self.conflicts[b] or {}
end

function Input:get_action_info(action, backend)
    local b = backend or self.active_backend or self.detected_backend or 'xinput'
    local code = self.action_codes[b] and self.action_codes[b][action]
    local prov = (self.action_provenance[b] and self.action_provenance[b][action]) or 'default'
    return {
        action     = action,
        backend    = b,
        code       = code,
        label      = Input.button_label(b, code),
        provenance = prov,
    }
end

-- Dynamic prompt label resolver for any logical action or action-pair
function Input:label_for(action, device)
    local dev = device or self.last_device or 'gamepad'
    if dev == 'keyboard' or dev == 'mouse' then
        if action == 'modules' then return 'Q/E' end
        return KEYBOARD_ACTION_LABELS[action] or tostring(action)
    end
    local b = self.active_backend or self.detected_backend or 'xinput'
    if action == 'modules' then
        return self:label_for('module_prev', 'gamepad') .. '/' .. self:label_for('module_next', 'gamepad')
    end
    if action == 'nav' then
        local codes = self.action_codes[b] or {}
        if b == 'xinput' then
            if codes.up == 0 and codes.down == 1 and codes.left == 2 and codes.right == 3 then
                return 'D-Pad'
            end
            return Input.button_label(b, codes.up) .. '/' .. Input.button_label(b, codes.down)
        else
            local prov = self.action_provenance[b] or {}
            if prov.up == 'overridden' or prov.down == 'overridden' or prov.left == 'overridden' or prov.right == 'overridden' then
                return Input.button_label(b, codes.up) .. '/' .. Input.button_label(b, codes.down)
            end
            return 'D-Pad'
        end
    end
    local code = self.action_codes[b] and self.action_codes[b][action]
    if code ~= nil then
        return Input.button_label(b, code)
    end
    return '?'
end

-- Poll VanaCore gamepad presence so controller disconnect/reconnect cleanly clears stale holds
-- and re-syncs inherited FFXI bindings.
function Input:poll_gamepad_presence()
    local getter = self.gamepad_state_fn
    if type(getter) ~= 'function' and type(vana) == 'table' and vana.gamepad and type(vana.gamepad.state) == 'function' then
        getter = vana.gamepad.state
    end
    if type(getter) ~= 'function' then return self.controller_present end
    local ok, st = pcall(getter)
    if not ok or type(st) ~= 'table' then return self.controller_present end

    local now_present = (st.present == true)
    if self.controller_present and not now_present then
        -- Controller disconnected: drop all held pad ownership & directional repeat cleanly
        self.pad_owner = {}
        self.repeat_state = {}
        self.stick_dir = nil
        self.stick_lx = 0
        self.stick_ly = 0
        self.diag.last_button_state = 'disconnected'
    elseif (not self.controller_present) and now_present then
        -- Controller reconnected: reset transient holds and re-import FFXI bindings
        self.pad_owner = {}
        self.repeat_state = {}
        self.stick_dir = nil
        self.diag.last_button_state = 'reconnected'
        self:import_ffxi_bindings()
    end
    self.controller_present = now_present
    self.diag.controller_present = now_present
    return now_present
end

-- Legacy/compat binding APIs preserved for existing callers & tests
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
            if n and type(action) == 'string' then self.overrides.xinput[action] = n end
        end
    end
    if type(bindings.dinput) == 'table' then
        for code, action in pairs(bindings.dinput) do
            local n = tonumber(code)
            if n and type(action) == 'string' then self.overrides.dinput[action] = n end
        end
    end
    self:_rebuild_maps()
end

function Input:set_binding(device, action, code)
    local n = tonumber(code)
    if type(action) ~= 'string' or action == '' or not n then
        return false
    end
    if device == 'keyboard' then
        self.key_map[n] = action
        return true
    elseif device == 'xinput' or device == 'dinput' then
        return self:set_action_override(device, action, n)
    end
    return false
end

function Input:reset_bindings()
    self.key_map = shallow_copy(Input.DEFAULT_KEY_MAP)
    self:restore_standard_defaults()
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

function Input:on_mouse_activity(_now)
    self.last_device = 'mouse'
    self.diag.active_mode = 'mouse'
    self.repeat_state = {}
end

function Input:get_diagnostics()
    self.diag.stick_dir = self.stick_dir or 'neutral'
    self.diag.active_mode = self.last_device or 'gamepad'
    self.diag.active_backend = self.active_backend or self.detected_backend or 'xinput'
    self.diag.controller_present = self.controller_present
    return self.diag
end

function Input:arm_open_guard(seconds)
    local dur = tonumber(seconds) or 0.18
    self.confirm_guard_until = self.clock() + dur
end

function Input:arm_confirm_guard(seconds)
    self:arm_open_guard(seconds)
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

function Input:tick(now, dispatch_fn, hub_open)
    self:poll_gamepad_presence()
    if not hub_open then
        self.repeat_state = {}
        return 0
    end
    local ts = now or self.clock()
    local fired = 0
    for _, st in pairs(self.repeat_state) do
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

function Input:on_pad(source, button_id, down, dispatch_fn, hub_open)
    local backend = (source == 'dinput') and 'dinput' or 'xinput'
    if self.active_backend ~= backend then
        self.active_backend = backend
        self:_rebuild_maps()
    end

    local map = (backend == 'xinput') and self.xinput_map or self.dinput_map
    local action = map[button_id]
    local token = backend .. ':' .. tostring(button_id)
    local btn_lbl = Input.button_label(backend, button_id)
    local label = token .. ' (' .. btn_lbl .. ')'

    if not down then
        local owned = self.pad_owner[token] == true
        if self.pad_owner[token] ~= nil then
            self.diag.last_physical_button = label
            self.diag.last_button_state = 'released'
        end
        self.pad_owner[token] = nil
        self.repeat_state[token] = nil
        return owned or (hub_open == true)
    end

    if self.pad_owner[token] ~= nil then
        return (self.pad_owner[token] == true) or (hub_open == true)
    end

    self.pad_owner[token] = false
    self.diag.last_physical_button = label
    self.diag.last_button_state = 'pressed'
    self.diag.active_mode = 'gamepad'
    local prov = (action and self.action_provenance[backend] and self.action_provenance[backend][action]) or 'unmapped'
    self.diag.last_action_provenance = prov

    if hub_open == true and self:_confirm_guarded(action) then
        self.pad_owner[token] = true
        self.last_device = 'gamepad'
        self.diag.last_action = tostring(action) .. ' (guarded)'
        self.diag.last_action_reached = false
        return true
    end
    if action and type(dispatch_fn) == 'function' then
        local reached = dispatch_fn(action) == true
        self.diag.last_action = action
        self.diag.last_action_reached = reached
        if reached then
            self.pad_owner[token] = true
            self.last_device = 'gamepad'
            arm_repeat(self, token, action, self.clock())
            return true
        end
    end

    if hub_open == true then
        self.pad_owner[token] = true
        self.last_device = 'gamepad'
        return true
    end

    return false
end

function Input:on_dinput_pov(angle, dispatch_fn, hub_open)
    if self.active_backend ~= 'dinput' then
        self.active_backend = 'dinput'
        self:_rebuild_maps()
    end
    local action = Input.dinput_pov_action(angle)
    local token = 'dinput:pov'

    if not action then
        local owned = self.pad_owner[token] == true
        if self.pad_owner[token] ~= nil then
            self.diag.last_physical_button = 'dinput:pov'
            self.diag.last_button_state = 'released'
        end
        self.pad_owner[token] = nil
        self.repeat_state[token] = nil
        return owned or (hub_open == true)
    end

    if self.pad_owner[token] ~= nil and self.repeat_state[token] and self.repeat_state[token].action == action then
        return (self.pad_owner[token] == true) or (hub_open == true)
    end

    self.pad_owner[token] = false
    self.repeat_state[token] = nil
    self.diag.last_physical_button = 'dinput:pov (' .. tostring(angle) .. ')'
    self.diag.last_button_state = 'pressed'
    self.diag.active_mode = 'gamepad'
    self.diag.last_action_provenance = 'default'
    if type(dispatch_fn) == 'function' then
        local reached = dispatch_fn(action) == true
        self.diag.last_action = action
        self.diag.last_action_reached = reached
        if reached then
            self.pad_owner[token] = true
            self.last_device = 'gamepad'
            arm_repeat(self, token, action, self.clock())
            return true
        end
    end

    if hub_open == true then
        self.pad_owner[token] = true
        return true
    end
    return false
end

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
        self.diag.stick_dir = new_dir
        self.diag.active_mode = 'gamepad'
        self.diag.last_action_provenance = 'analog'
        if type(dispatch_fn) == 'function' then
            local reached = dispatch_fn(new_dir) == true
            self.diag.last_action = new_dir
            self.diag.last_action_reached = reached
        end
        arm_repeat(self, token, new_dir, now or self.clock())
    elseif new_dir == nil and self.stick_dir == nil then
        self.diag.stick_dir = 'neutral'
        self.repeat_state[token] = nil
    end
    return true
end

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

function Input:on_xinput_button(e, dispatch_fn, hub_open, now)
    if type(e) ~= 'table' then return hub_open == true end
    local btn = tonumber(e.button)
    local val = tonumber(e.state) or 0
    if btn == nil then return hub_open == true end
    if btn == Input.XINPUT_AXIS_LX or btn == Input.XINPUT_AXIS_LY then
        return self:on_xinput_axis(btn, val, dispatch_fn, hub_open, now)
    end
    if btn >= 0 and btn < 16 then
        return self:on_pad('xinput', btn, val ~= 0, dispatch_fn, hub_open)
    elseif btn == 16 or btn == 17 then
        return self:on_pad('xinput', btn, val > XINPUT_TRIGGER_THRESHOLD, dispatch_fn, hub_open)
    end
    return hub_open == true
end

function Input:on_dinput_button(e, dispatch_fn, hub_open, now)
    if type(e) ~= 'table' then return hub_open == true end
    local ofs = tonumber(e.button)
    local val = tonumber(e.state) or 0
    if ofs == nil then return hub_open == true end
    if ofs == 32 then
        return self:on_dinput_pov(val, dispatch_fn, hub_open)
    elseif ofs == 0 or ofs == 4 then
        local norm
        if val > 2000 or val < -2000 then
            norm = math.max(-1, math.min(1, (val - 32767.5) / 32767.5))
        else
            norm = math.max(-1, math.min(1, val / 1000))
        end
        if ofs == 0 then
            self.stick_lx = norm
        else
            self.stick_ly = -norm
        end
        return self:on_left_stick(self.stick_lx, self.stick_ly, dispatch_fn, hub_open, now)
    elseif ofs >= 48 then
        return self:on_pad('dinput', ofs - 48, val ~= 0, dispatch_fn, hub_open)
    elseif ofs >= 0 and ofs < 32 then
        return self:on_pad('dinput', ofs, val ~= 0, dispatch_fn, hub_open)
    end
    return hub_open == true
end

local ok_ffi, ffi = pcall(require, 'ffi')
if ok_ffi and ffi then
    pcall(ffi.cdef, [[
        typedef struct _SXI_XINPUT_GAMEPAD {
            uint16_t wButtons;
            uint8_t  bLeftTrigger;
            uint8_t  bRightTrigger;
            int16_t  sThumbLX;
            int16_t  sThumbLY;
            int16_t  sThumbRX;
            int16_t  sThumbRY;
        } SXI_XINPUT_GAMEPAD;
        typedef struct _SXI_XINPUT_STATE {
            uint32_t           dwPacketNumber;
            SXI_XINPUT_GAMEPAD Gamepad;
        } SXI_XINPUT_STATE;
        typedef struct _SXI_DIJOYSTATE {
            int32_t  lX;
            int32_t  lY;
            int32_t  lZ;
            int32_t  lRx;
            int32_t  lRy;
            int32_t  lRz;
            int32_t  rglSlider[2];
            uint32_t rgdwPOV[4];
            uint8_t  rgbButtons[32];
        } SXI_DIJOYSTATE;
    ]])
end

local function normalize_xinput_state(obj)
    if obj == nil then return nil end
    if type(obj) == 'userdata' and ok_ffi and ffi then
        local ok, ptr = pcall(ffi.cast, 'SXI_XINPUT_STATE*', obj)
        if ok and ptr ~= nil then return ptr end
    end
    return obj
end

local function normalize_dinput_state(obj)
    if obj == nil then return nil end
    if type(obj) == 'userdata' and ok_ffi and ffi then
        local ok, ptr = pcall(ffi.cast, 'SXI_DIJOYSTATE*', obj)
        if ok and ptr ~= nil then return ptr end
    end
    return obj
end

-- Filter raw VanaCore XINPUT_STATE (reads Left Stick, wButtons[0..15], AND LT/RT triggers [16..17]
-- BEFORE zeroing the shared state/state_modified buffer).
function Input:filter_xinput_state(state_obj, modified_obj, dispatch_fn, hub_open, now, user_index)
    if not hub_open then
        self.stick_dir = nil
        self.repeat_state['pad:lstick'] = nil
        return false
    end

    state_obj = normalize_xinput_state(state_obj)
    modified_obj = normalize_xinput_state(modified_obj)

    if state_obj ~= nil then
        local ok, wButtons, lt, rt, lx, ly = pcall(function()
            local gp = nil
            local okG, g1 = pcall(function() return state_obj.Gamepad end)
            if okG and g1 ~= nil then
                gp = g1
            else
                local okG2, g2 = pcall(function() return state_obj.gamepad end)
                gp = (okG2 and g2 ~= nil) and g2 or state_obj
            end
            return tonumber(gp.wButtons) or 0,
                   tonumber(gp.bLeftTrigger) or 0,
                   tonumber(gp.bRightTrigger) or 0,
                   tonumber(gp.sThumbLX) or 0,
                   tonumber(gp.sThumbLY) or 0
        end)
        if ok then
            local u = tonumber(user_index) or 0
            local has_activity = (wButtons ~= 0) or (lt > XINPUT_TRIGGER_THRESHOLD) or (rt > XINPUT_TRIGGER_THRESHOLD)
                or (math.abs(lx) > 6000) or (math.abs(ly) > 6000)
            if has_activity then
                self.xinput_active_user = u
            end
            if u == self.xinput_active_user then
                self.diag.raw_button_mask = wButtons
                self.stick_lx = math.max(-1, math.min(1, lx / 32767))
                self.stick_ly = math.max(-1, math.min(1, ly / 32767))
                self:on_left_stick(self.stick_lx, self.stick_ly, dispatch_fn, true, now)
                for b = 0, 15 do
                    local down = bit.band(wButtons, bit.lshift(1, b)) ~= 0
                    self:on_pad('xinput', b, down, dispatch_fn, true)
                end
                self:on_pad('xinput', 16, lt > XINPUT_TRIGGER_THRESHOLD, dispatch_fn, true)
                self:on_pad('xinput', 17, rt > XINPUT_TRIGGER_THRESHOLD, dispatch_fn, true)
            end
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
function Input:filter_dinput_state(state_obj, modified_obj, dispatch_fn, hub_open, now)
    if not hub_open then
        return false
    end

    state_obj = normalize_dinput_state(state_obj)
    modified_obj = normalize_dinput_state(modified_obj)

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

        local ok_pov, pov = pcall(function() return tonumber(state_obj.rgdwPOV[0]) end)
        if ok_pov and pov ~= nil then
            self:on_dinput_pov(pov, dispatch_fn, true)
        end

        local ok_btns, mask = pcall(function()
            local m = 0
            for b = 0, 15 do
                local v = tonumber(state_obj.rgbButtons[b]) or 0
                if v >= 0x80 then
                    m = bit.bor(m, bit.lshift(1, b))
                end
            end
            return m
        end)
        if ok_btns and type(mask) == 'number' then
            self.diag.raw_button_mask = mask
            for b = 0, 15 do
                local down = bit.band(mask, bit.lshift(1, b)) ~= 0
                self:on_pad('dinput', b, down, dispatch_fn, true)
            end
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
