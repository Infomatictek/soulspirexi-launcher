-- SoulspireXI Core: deterministic menu focus, module switching & modal state machine.
-- Manages clean focus ownership between:
--   1. Native FFXI Main Menu (unowned -> all native inputs pass through)
--   2. Docked "Soulspire" Main Menu entry (owned -> inputs consumed cleanly)
--   3. Unified SoulspireXI Core Hub (owned -> ALL controller/menu inputs captured):
--        - Help / Details overlay modal (Y toggle, B dismiss)
--        - Dynamic module switching (LB/RB -> module_prev / module_next)
--        - Delegation into the active module's directional focus controller

local Focus = {}
Focus.__index = Focus

function Focus.new(registry)
    local self = setmetatable({
        registry             = registry,
        dock_focused         = false,
        hub_open             = false,
        opened_from_dock     = false,
        help_open            = false,
        selected_index       = 1,
        active_index         = 1,
        active_module_id     = nil,
        skip_unavailable_nav = false,
        focus_window         = nil,
        focus_cursor         = nil,
        last_action          = 'idle',
    }, Focus)
    self:clamp_selection()
    return self
end

function Focus:count()
    return math.max(1, self.registry:count())
end

function Focus:active_module()
    self:clamp_selection()
    return self.registry:get(self.active_index)
end

function Focus:clamp_selection()
    local n = self.registry:count()
    if n == 0 then
        self.selected_index = 1
        self.active_index = 1
        self.active_module_id = nil
        return
    end
    -- Preserve active module by id across dynamic registry re-orders or additions
    if self.active_module_id then
        local by_id = self.registry:index_of(self.active_module_id)
        if by_id then
            self.active_index = by_id
            self.selected_index = by_id
        end
    end
    if self.selected_index < 1 or self.selected_index > n then
        self.selected_index = 1
    end
    if self.active_index < 1 or self.active_index > n then
        self.active_index = self.selected_index
    end
    local mod = self.registry:get(self.active_index)
    self.active_module_id = mod and mod.id or nil
end

function Focus:owns_input()
    return self.hub_open or self.dock_focused
end

function Focus:is_hub_open()
    return self.hub_open == true
end

local function notify_module(mod, method, ...)
    if mod and mod.controller and type(mod.controller[method]) == 'function' then
        return mod.controller[method](mod.controller, ...)
    end
    return nil
end

function Focus:open_hub(index, from_dock)
    local prev_open = self.hub_open
    self.hub_open = true
    self.help_open = false
    self.opened_from_dock = (from_dock == true)
    if type(index) == 'number' then
        local mod = self.registry:get(index)
        if mod then
            self.selected_index = index
            self.active_index = index
            self.active_module_id = mod.id
        end
    end
    self:clamp_selection()
    self.last_action = from_dock and 'open_from_dock' or 'open_direct'
    local active = self:active_module()
    if not prev_open then
        notify_module(active, 'on_open', self)
    end
    notify_module(active, 'on_activate', self)
end

function Focus:close_hub(native)
    local active = self:active_module()
    notify_module(active, 'on_close', self)

    local return_to_dock = self.opened_from_dock and native ~= nil
    self.hub_open = false
    self.help_open = false
    self.opened_from_dock = false
    if return_to_dock then
        self.dock_focused = true
        self.focus_window = native.window
        self.focus_cursor = native.cursor
        self.last_action = 'close_to_dock'
    else
        self.dock_focused = false
        self.focus_window = nil
        self.focus_cursor = nil
        self.last_action = 'close'
    end
end

function Focus:toggle_hub(index)
    if self.hub_open then
        self:close_hub(nil)
    else
        self:open_hub(index, false)
    end
end

function Focus:blur_all(reason)
    if self.hub_open then
        local active = self:active_module()
        notify_module(active, 'on_close', self)
    end
    self.hub_open = false
    self.help_open = false
    self.opened_from_dock = false
    self.dock_focused = false
    self.focus_window = nil
    self.focus_cursor = nil
    self.last_action = reason or 'blur'
end

function Focus:select_index(index)
    local n = self.registry:count()
    if type(index) ~= 'number' or index < 1 or index > n then return false end
    local prev = self:active_module()
    local next_mod = self.registry:get(index)
    if not next_mod then return false end
    if prev and prev.id ~= next_mod.id then
        notify_module(prev, 'on_deactivate', self)
    end
    self.selected_index = index
    self.active_index = index
    self.active_module_id = next_mod.id
    self.help_open = false
    self.last_action = 'select_module'
    if self.hub_open and (not prev or prev.id ~= next_mod.id) then
        notify_module(next_mod, 'on_activate', self)
    end
    return true
end

function Focus:select_module(id_or_query)
    local idx = self.registry:find_index(id_or_query)
    if not idx then return false end
    return self:select_index(idx)
end

function Focus:switch_module(delta)
    local next_idx = self.registry:step_index(self.active_index, delta, self.skip_unavailable_nav)
    if not next_idx then return false end
    local ok = self:select_index(next_idx)
    if ok then
        self.last_action = (delta and delta < 0) and 'module_prev' or 'module_next'
    end
    return ok
end

-- Keep focus consistent with live FFXI native menu state.
function Focus:sync_native(native)
    if not self.hub_open and self.dock_focused then
        if not native or (self.focus_window and native.window ~= self.focus_window) then
            self.dock_focused = false
            self.focus_window = nil
            self.focus_cursor = nil
            self.last_action = 'native_closed'
        end
    end
    if self.hub_open and self.opened_from_dock and not native then
        -- Native main menu was dismissed underneath; Hub stays open standalone until cancelled.
        self.opened_from_dock = false
        self.dock_focused = false
        self.focus_window = nil
        self.focus_cursor = nil
    end
end

-- Process a logical navigation action:
--   'up', 'down', 'left', 'right', 'confirm', 'cancel', 'context', 'details',
--   'module_prev', 'module_next', 'focus_dock'
-- Returns true if the input was consumed by SoulspireXI Core (must NOT reach FFXI).
function Focus:handle_action(action, native)
    if type(action) ~= 'string' then return false end
    self:sync_native(native)
    self:clamp_selection()

    if self.hub_open then
        -- 1. Help/Details modal captures inputs exclusively while open
        if self.help_open then
            if action == 'cancel' or action == 'details' or action == 'confirm' then
                self.help_open = false
                self.last_action = 'close_help'
            end
            return true
        end

        -- 2. Global LB / RB module switching (unless active module has a blocking confirm modal)
        local active = self:active_module()
        local has_modal = active and active.controller and type(active.controller.has_modal) == 'function'
            and active.controller:has_modal() == true

        if not has_modal and (action == 'module_prev' or action == 'module_next') then
            self:switch_module(action == 'module_prev' and -1 or 1)
            return true
        end

        -- 3. Delegate to active module controller if available
        if active and active.available and active.controller and type(active.controller.on_action) == 'function' then
            local handled = active.controller:on_action(action, { focus = self, native = native })
            if handled then
                self.last_action = active.id .. ':' .. action
                return true
            end
        end

        -- 4. Default shell-level handling when module doesn't consume the action
        if action == 'cancel' then
            self:close_hub(native)
            return true
        elseif action == 'details' then
            self.help_open = not self.help_open
            self.last_action = self.help_open and 'open_help' or 'close_help'
            return true
        elseif action == 'left' then
            -- On unavailable modules (no internal controller), Left/Right switch tabs gracefully
            if not (active and active.available and active.controller) then
                self:switch_module(-1)
            end
            return true
        elseif action == 'right' then
            if not (active and active.available and active.controller) then
                self:switch_module(1)
            end
            return true
        elseif action == 'up' or action == 'down' or action == 'confirm'
            or action == 'context' or action == 'focus_dock'
            or action == 'module_prev' or action == 'module_next' then
            -- Never let any action leak through while Core Hub is open
            return true
        end
        return true
    end

    -- Docked "Soulspire" entry on FFXI Main Menu is focused
    if self.dock_focused then
        if action == 'confirm' then
            self:open_hub(self.active_index, true)
            return true
        elseif action == 'cancel' or action == 'up' or action == 'focus_dock'
            or action == 'module_prev' or action == 'module_next' then
            self.dock_focused = false
            self.focus_window = nil
            self.focus_cursor = nil
            self.last_action = 'return_to_native'
            return true
        elseif action == 'down' or action == 'left' or action == 'right'
            or action == 'context' or action == 'details' then
            return true
        end
        return false
    end

    -- Neither Hub nor Dock is focused: claim dock focus when FFXI Main Menu is open
    -- and player triggers Tab or LB/RB handoff.
    if native ~= nil and (action == 'focus_dock' or action == 'module_prev' or action == 'module_next') then
        self.dock_focused = true
        self.focus_window = native.window
        self.focus_cursor = native.cursor
        self.last_action = 'focus_dock'
        return true
    end

    return false
end

return Focus
