-- SoulspireXI Core: deterministic menu focus & navigation state machine.
-- Manages clean focus ownership between:
--   1. Native FFXI Main Menu (unowned by addon -> all native inputs pass through)
--   2. Docked "Soulspire" Main Menu entry (owned by addon -> inputs consumed)
--   3. SoulspireXI Core Hub window (owned by addon -> inputs consumed)

local Focus = {}
Focus.__index = Focus

function Focus.new(registry)
    return setmetatable({
        registry = registry,
        dock_focused = false,
        hub_open = false,
        opened_from_dock = false,
        selected_index = 1,
        active_index = 1,
        focus_window = nil,
        focus_cursor = nil,
        last_action = 'idle',
    }, Focus)
end

function Focus:count()
    return math.max(1, self.registry:count())
end

function Focus:clamp_selection()
    local n = self:count()
    if self.selected_index < 1 or self.selected_index > n then
        self.selected_index = 1
    end
    if self.active_index < 1 or self.active_index > n then
        self.active_index = self.selected_index
    end
end

function Focus:owns_input()
    return self.hub_open or self.dock_focused
end

function Focus:open_hub(index, from_dock)
    self.hub_open = true
    self.opened_from_dock = (from_dock == true)
    if type(index) == 'number' then
        self.selected_index = index
        self.active_index = index
    end
    self:clamp_selection()
    self.last_action = from_dock and 'open_from_dock' or 'open_direct'
end

function Focus:close_hub(native)
    local return_to_dock = self.opened_from_dock and native ~= nil
    self.hub_open = false
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
    self.hub_open = false
    self.opened_from_dock = false
    self.dock_focused = false
    self.focus_window = nil
    self.focus_cursor = nil
    self.last_action = reason or 'blur'
end

function Focus:select_index(index)
    local n = self:count()
    if type(index) ~= 'number' or index < 1 or index > n then return false end
    self.selected_index = index
    self.active_index = index
    self.last_action = 'select'
    return true
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

-- Process a logical navigation action ('up', 'down', 'left', 'right', 'confirm', 'cancel', 'focus_dock').
-- Returns true if the input was consumed by SoulspireXI Core (must NOT reach FFXI).
function Focus:handle_action(action, native)
    if type(action) ~= 'string' then return false end
    self:sync_native(native)
    self:clamp_selection()

    local n = self:count()

    if self.hub_open then
        if action == 'cancel' then
            self:close_hub(native)
            return true
        elseif action == 'up' then
            self.selected_index = ((self.selected_index - 2) % n) + 1
            self.active_index = self.selected_index
            self.last_action = 'nav_up'
            return true
        elseif action == 'down' then
            self.selected_index = (self.selected_index % n) + 1
            self.active_index = self.selected_index
            self.last_action = 'nav_down'
            return true
        elseif action == 'confirm' then
            self.active_index = self.selected_index
            self.last_action = 'confirm_section'
            return true
        elseif action == 'left' or action == 'right' or action == 'focus_dock' then
            return true
        end
        return false
    end

    if self.dock_focused then
        if action == 'confirm' then
            self:open_hub(self.selected_index, true)
            return true
        elseif action == 'cancel' or action == 'up' or action == 'focus_dock' then
            self.dock_focused = false
            self.focus_window = nil
            self.focus_cursor = nil
            self.last_action = 'return_to_native'
            return true
        elseif action == 'down' or action == 'left' or action == 'right' then
            return true
        end
        return false
    end

    -- Neither Hub nor Dock is focused: only claim focus when the FFXI Main Menu is active
    -- and the user triggers the dedicated dock-focus handoff action.
    if native ~= nil and action == 'focus_dock' then
        self.dock_focused = true
        self.focus_window = native.window
        self.focus_cursor = native.cursor
        self.last_action = 'focus_dock'
        return true
    end

    return false
end

return Focus
