-- SoulspireXI Core: Balanced Mouse, Cursor & Window Focus Ownership Lifecycle.
--
-- Solves both invisible-cursor and double-cursor defects on Windows / Ashita v4
-- without ever hammering global Win32 ShowCursor every frame:
--   1. Explicit input ownership state machine:
--        'ffxi' -> 'core' <-> 'suspended_unfocused' -> 'ffxi'
--   2. Strict single-cursor policy (explicit cursor modes):
--        - 'none'              : Core closed or unfocused (FFXI owns cursor).
--        - 'hardware'          : OS/FFXI hardware cursor is visible (or probe
--                                unavailable); io.MouseDrawCursor is ALWAYS
--                                false so two cursors can never appear.
--        - 'software_fallback' : Win32 GetCursorInfo() explicitly confirms the
--                                OS/FFXI cursor is hidden; io.MouseDrawCursor
--                                is enabled as a single-cursor fallback and
--                                immediately disabled if the OS cursor returns.
--   3. Acquires cursor & mouse ownership ONCE on closed -> open (idempotent;
--      never re-acquires or releases during module tab switches).
--   4. Restores prior ImGui cursor/mouse flags cleanly on close, zone change,
--      logout, disconnect, Alt+Tab focus loss, and addon unload.
--   5. Releases stale FFXI Win32 mouse capture (ReleaseCapture) strictly as a
--      single-shot guard on acquire/resume when GetCapture() is non-null.
--   6. Tracks per-button press ownership so clicking Core's X close button
--      absorbs the trailing WM_LBUTTONUP instead of leaking it to FFXI.
--   7. Exposes lightweight, non-sensitive diagnostics (no raw keystrokes or
--      cursor coordinates logged).

local bit = require('bit')

local MouseLifecycle = {}
MouseLifecycle.__index = MouseLifecycle

-- Win32 mouse message IDs delivered by Ashita v4's `mouse` event.
MouseLifecycle.WM_MOUSEMOVE     = 0x0200
MouseLifecycle.WM_LBUTTONDOWN   = 0x0201
MouseLifecycle.WM_LBUTTONUP     = 0x0202
MouseLifecycle.WM_LBUTTONDBLCLK = 0x0203
MouseLifecycle.WM_RBUTTONDOWN   = 0x0204
MouseLifecycle.WM_RBUTTONUP     = 0x0205
MouseLifecycle.WM_RBUTTONDBLCLK = 0x0206
MouseLifecycle.WM_MBUTTONDOWN   = 0x0207
MouseLifecycle.WM_MBUTTONUP     = 0x0208
MouseLifecycle.WM_MBUTTONDBLCLK = 0x0209
MouseLifecycle.WM_MOUSEWHEEL    = 0x020A
MouseLifecycle.WM_XBUTTONDOWN   = 0x020B
MouseLifecycle.WM_XBUTTONUP     = 0x020C
MouseLifecycle.WM_XBUTTONDBLCLK = 0x020D
MouseLifecycle.WM_MOUSEHWHEEL   = 0x020E

-- Dear ImGui ConfigFlags / MouseCursor constants (stable across ImGui 1.7x-1.9x).
MouseLifecycle.IMGUI_CONFIG_NO_MOUSE               = 16 -- 1 << 4
MouseLifecycle.IMGUI_CONFIG_NO_MOUSE_CURSOR_CHANGE = 64 -- 1 << 6
MouseLifecycle.IMGUI_CURSOR_NONE                   = -1
MouseLifecycle.IMGUI_CURSOR_ARROW                  = 0

-- Explicit single-cursor ownership modes.
MouseLifecycle.CURSOR_MODE_NONE              = 'none'
MouseLifecycle.CURSOR_MODE_HARDWARE          = 'hardware'
MouseLifecycle.CURSOR_MODE_SOFTWARE_FALLBACK = 'software_fallback'

local CURSOR_SHOWING = 0x00000001
local MAX_TRANSITIONS = 12

local BUTTON_DOWN_MAP = {
    [MouseLifecycle.WM_LBUTTONDOWN]   = 'left',
    [MouseLifecycle.WM_LBUTTONDBLCLK] = 'left',
    [MouseLifecycle.WM_RBUTTONDOWN]   = 'right',
    [MouseLifecycle.WM_RBUTTONDBLCLK] = 'right',
    [MouseLifecycle.WM_MBUTTONDOWN]   = 'middle',
    [MouseLifecycle.WM_MBUTTONDBLCLK] = 'middle',
    [MouseLifecycle.WM_XBUTTONDOWN]   = 'x',
    [MouseLifecycle.WM_XBUTTONDBLCLK] = 'x',
}

local BUTTON_UP_MAP = {
    [MouseLifecycle.WM_LBUTTONUP] = 'left',
    [MouseLifecycle.WM_RBUTTONUP] = 'right',
    [MouseLifecycle.WM_MBUTTONUP] = 'middle',
    [MouseLifecycle.WM_XBUTTONUP] = 'x',
}

-- Resolve Win32 user32/kernel32 helpers dynamically via GetProcAddress so we
-- never collide with another Ashita v4 addon's global ffi.cdef declarations.
local function create_win32_platform()
    local ok_ffi, ffi = pcall(require, 'ffi')
    if not ok_ffi or not ffi or ffi.os ~= 'Windows' then
        return {
            is_window_focused     = function() return nil end,
            is_os_cursor_visible  = function() return nil end,
            has_mouse_capture     = function() return false end,
            release_mouse_capture = function() return false end,
        }
    end

    pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char* name);')
    pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void* module, const char* name);')

    local cursor_info_t = nil
    pcall(function()
        cursor_info_t = ffi.typeof([[struct {
            uint32_t cbSize;
            uint32_t flags;
            void*    hCursor;
            int32_t  ptScreenPosX;
            int32_t  ptScreenPosY;
        }[1] ]])
    end)

    local fn_get_fg = nil
    local fn_get_wtpid = nil
    local fn_get_pid = nil
    local fn_get_capture = nil
    local fn_release_capture = nil
    local fn_get_cursor_info = nil
    local pid_buf = nil
    local ci_buf = nil

    pcall(function()
        local u32 = ffi.C.GetModuleHandleA('user32.dll')
        local k32 = ffi.C.GetModuleHandleA('kernel32.dll')
        if u32 ~= nil then
            local pFg = ffi.C.GetProcAddress(u32, 'GetForegroundWindow')
            if pFg ~= nil then fn_get_fg = ffi.cast('void* (__stdcall *)(void)', pFg) end

            local pWt = ffi.C.GetProcAddress(u32, 'GetWindowThreadProcessId')
            if pWt ~= nil then fn_get_wtpid = ffi.cast('uint32_t (__stdcall *)(void*, uint32_t*)', pWt) end

            local pCap = ffi.C.GetProcAddress(u32, 'GetCapture')
            if pCap ~= nil then fn_get_capture = ffi.cast('void* (__stdcall *)(void)', pCap) end

            local pRel = ffi.C.GetProcAddress(u32, 'ReleaseCapture')
            if pRel ~= nil then fn_release_capture = ffi.cast('int32_t (__stdcall *)(void)', pRel) end

            local pCi = ffi.C.GetProcAddress(u32, 'GetCursorInfo')
            if pCi ~= nil and cursor_info_t ~= nil then
                fn_get_cursor_info = ffi.cast('int32_t (__stdcall *)(void*)', pCi)
                ci_buf = ffi.new(cursor_info_t)
            end
        end
        if k32 ~= nil then
            local pPid = ffi.C.GetProcAddress(k32, 'GetCurrentProcessId')
            if pPid ~= nil then fn_get_pid = ffi.cast('uint32_t (__stdcall *)(void)', pPid) end
        end
        pid_buf = ffi.new('uint32_t[1]')
    end)

    local self_pid = nil
    if fn_get_pid then
        local ok, p = pcall(fn_get_pid)
        if ok and p and p ~= 0 then self_pid = tonumber(p) end
    end

    return {
        is_window_focused = function()
            if not (fn_get_fg and fn_get_wtpid and self_pid and pid_buf) then
                return nil
            end
            local ok, focused = pcall(function()
                local hwnd = fn_get_fg()
                if hwnd == nil then return false end
                pid_buf[0] = 0
                fn_get_wtpid(hwnd, pid_buf)
                return tonumber(pid_buf[0]) == self_pid
            end)
            if ok then return focused end
            return nil
        end,

        is_os_cursor_visible = function()
            if not (fn_get_cursor_info and ci_buf) then
                return nil
            end
            local ok, visible = pcall(function()
                ci_buf[0].cbSize = ffi.sizeof(ci_buf[0])
                ci_buf[0].flags = 0
                ci_buf[0].hCursor = nil
                if fn_get_cursor_info(ci_buf) == 0 then
                    return nil
                end
                local showing = bit.band(tonumber(ci_buf[0].flags) or 0, CURSOR_SHOWING) ~= 0
                return showing and (ci_buf[0].hCursor ~= nil)
            end)
            if ok then return visible end
            return nil
        end,

        has_mouse_capture = function()
            if not fn_get_capture then return false end
            local ok, has = pcall(function() return fn_get_capture() ~= nil end)
            return ok and has == true
        end,

        release_mouse_capture = function()
            if not fn_release_capture then return false end
            local ok, res = pcall(fn_release_capture)
            return ok and (tonumber(res) or 0) ~= 0
        end,
    }
end

local function safe_get_io(imgui)
    if type(imgui) ~= 'table' or type(imgui.GetIO) ~= 'function' then
        return nil
    end
    local ok, io = pcall(imgui.GetIO)
    if ok and io ~= nil then
        return io
    end
    return nil
end

local function safe_read_field(obj, key, default_val)
    if obj == nil then return default_val end
    local ok, val = pcall(function() return obj[key] end)
    if ok and val ~= nil then return val end
    return default_val
end

local function safe_write_field(obj, key, value)
    if obj == nil then return false end
    local ok = pcall(function() obj[key] = value end)
    return ok == true
end

function MouseLifecycle.new(opts)
    opts = opts or {}
    local self = setmetatable({
        clock                     = opts.clock or os.clock,
        platform                  = opts.platform or create_win32_platform(),
        on_mouse_activity         = opts.on_mouse_activity,
        on_focus_regain           = opts.on_focus_regain,
        on_focus_lost             = opts.on_focus_lost,
        move_threshold            = tonumber(opts.move_threshold) or 2,

        core_open                 = false,
        owner                     = 'ffxi', -- 'ffxi' | 'core' | 'suspended_unfocused'
        mouse_captured_by_core    = false,
        window_focused            = true,
        cursor_mode               = MouseLifecycle.CURSOR_MODE_NONE, -- 'none' | 'hardware' | 'software_fallback'
        imgui_draw_cursor_applied = false,
        os_cursor_visible         = nil,
        fallback_active           = false,
        fallback_reason           = 'core_inactive',
        fallback_activations      = 0,

        saved_valid               = false,
        saved_mouse_draw_cursor   = false,
        saved_no_mouse_flag       = false,

        acquire_count             = 0,
        release_count             = 0,
        suspend_count             = 0,
        resume_count              = 0,
        capture_releases          = 0,
        blocked_mouse_events      = 0,
        absorbed_release_events   = 0,

        last_transition           = 'init',
        last_transition_at        = 0,
        transitions               = {},

        button_owner              = {},
        last_mouse_x              = nil,
        last_mouse_y              = nil,
    }, MouseLifecycle)
    return self
end

function MouseLifecycle:_record_transition(from_owner, to_owner, reason, now)
    local ts = tonumber(now) or self.clock()
    local label = tostring(reason or 'unknown')
    self.last_transition = string.format('%s->%s:%s', tostring(from_owner), tostring(to_owner), label)
    self.last_transition_at = ts
    local list = self.transitions
    list[#list + 1] = {
        at         = ts,
        from_owner = tostring(from_owner),
        to_owner   = tostring(to_owner),
        reason     = label,
    }
    while #list > MAX_TRANSITIONS do
        table.remove(list, 1)
    end
end

function MouseLifecycle:_probe_window_focused()
    if self.platform and type(self.platform.is_window_focused) == 'function' then
        local ok, focused = pcall(self.platform.is_window_focused)
        if ok and type(focused) == 'boolean' then
            return focused
        end
    end
    return nil
end

function MouseLifecycle:_probe_os_cursor_visible()
    if self.platform and type(self.platform.is_os_cursor_visible) == 'function' then
        local ok, vis = pcall(self.platform.is_os_cursor_visible)
        if ok and type(vis) == 'boolean' then
            return vis
        end
    end
    return nil
end

function MouseLifecycle:_release_stale_capture_once()
    if not self.platform then return false end
    if type(self.platform.has_mouse_capture) == 'function' then
        local okH, has = pcall(self.platform.has_mouse_capture)
        if not (okH and has == true) then
            return false
        end
    else
        return false
    end
    if type(self.platform.release_mouse_capture) == 'function' then
        local okR, released = pcall(self.platform.release_mouse_capture)
        if okR and released then
            self.capture_releases = self.capture_releases + 1
            return true
        end
    end
    return false
end

function MouseLifecycle:_snapshot_io_once(io)
    if self.saved_valid or io == nil then return end
    self.saved_mouse_draw_cursor = safe_read_field(io, 'MouseDrawCursor', false) == true
    local flags = tonumber(safe_read_field(io, 'ConfigFlags', 0)) or 0
    self.saved_no_mouse_flag = bit.band(flags, MouseLifecycle.IMGUI_CONFIG_NO_MOUSE) ~= 0
    self.saved_valid = true
end

function MouseLifecycle:_restore_io(imgui)
    if not self.saved_valid then return end
    local io = safe_get_io(imgui)
    if io ~= nil then
        local cur_draw = safe_read_field(io, 'MouseDrawCursor', false) == true
        if cur_draw ~= self.saved_mouse_draw_cursor then
            safe_write_field(io, 'MouseDrawCursor', self.saved_mouse_draw_cursor)
        end
        local flags = tonumber(safe_read_field(io, 'ConfigFlags', nil))
        if flags ~= nil then
            local has_no_mouse = bit.band(flags, MouseLifecycle.IMGUI_CONFIG_NO_MOUSE) ~= 0
            if self.saved_no_mouse_flag and not has_no_mouse then
                safe_write_field(io, 'ConfigFlags', bit.bor(flags, MouseLifecycle.IMGUI_CONFIG_NO_MOUSE))
            elseif (not self.saved_no_mouse_flag) and has_no_mouse then
                safe_write_field(io, 'ConfigFlags', bit.band(flags, bit.bnot(MouseLifecycle.IMGUI_CONFIG_NO_MOUSE)))
            end
        end
    end
    self.imgui_draw_cursor_applied = false
    self.fallback_active = false
    self.fallback_reason = 'core_inactive'
    self.cursor_mode = MouseLifecycle.CURSOR_MODE_NONE
end

-- Enforce strict single-cursor policy while Core owns focused input:
--   - If OS/FFXI hardware cursor is confirmed visible (os_vis == true):
--       mode = 'hardware', io.MouseDrawCursor = false (NEVER draw a second cursor!)
--   - If OS/FFXI hardware cursor is explicitly confirmed hidden (os_vis == false):
--       mode = 'software_fallback', io.MouseDrawCursor = true (single visible cursor)
--   - If OS cursor visibility is unobservable (os_vis == nil):
--       mode = 'hardware', io.MouseDrawCursor = false (prefer hardware cursor;
--       never risk creating a double cursor without confirming OS cursor is hidden)
-- Never invokes Win32 ShowCursor; only writes io.MouseDrawCursor when changed.
function MouseLifecycle:_sync_cursor_visibility(imgui)
    local io = safe_get_io(imgui)
    local os_vis = self:_probe_os_cursor_visible()
    self.os_cursor_visible = os_vis

    local prev_fallback = self.fallback_active
    local want_imgui_cursor = (os_vis == false)
    local next_mode
    local next_reason

    if os_vis == false then
        next_mode = MouseLifecycle.CURSOR_MODE_SOFTWARE_FALLBACK
        next_reason = 'os_cursor_hidden'
    elseif os_vis == true then
        next_mode = MouseLifecycle.CURSOR_MODE_HARDWARE
        next_reason = 'none'
    else
        next_mode = MouseLifecycle.CURSOR_MODE_HARDWARE
        next_reason = 'probe_unavailable_prefer_hardware'
    end

    if io ~= nil then
        local flags = tonumber(safe_read_field(io, 'ConfigFlags', 0)) or 0
        -- Ensure ImGui mouse input is never stuck disabled while Core owns focus.
        if bit.band(flags, MouseLifecycle.IMGUI_CONFIG_NO_MOUSE) ~= 0 then
            local cleared = bit.band(flags, bit.bnot(MouseLifecycle.IMGUI_CONFIG_NO_MOUSE))
            safe_write_field(io, 'ConfigFlags', cleared)
        end

        local cur_draw = safe_read_field(io, 'MouseDrawCursor', false) == true
        if cur_draw ~= want_imgui_cursor then
            safe_write_field(io, 'MouseDrawCursor', want_imgui_cursor)
        end
    end

    self.imgui_draw_cursor_applied = want_imgui_cursor
    self.fallback_active = want_imgui_cursor
    self.fallback_reason = next_reason
    self.cursor_mode = next_mode
    if want_imgui_cursor and not prev_fallback then
        self.fallback_activations = self.fallback_activations + 1
    end

    if want_imgui_cursor and type(imgui) == 'table'
        and type(imgui.GetMouseCursor) == 'function'
        and type(imgui.SetMouseCursor) == 'function' then
        local okC, cur = pcall(imgui.GetMouseCursor)
        if okC and cur == MouseLifecycle.IMGUI_CURSOR_NONE then
            pcall(imgui.SetMouseCursor, MouseLifecycle.IMGUI_CURSOR_ARROW)
        end
    end
end

-- Acquire mouse & cursor ownership on closed -> open transition (strictly idempotent).
function MouseLifecycle:acquire(imgui, reason, now)
    self.core_open = true
    if self.owner == 'core' and self.saved_valid then
        return false
    end

    local prev_owner = self.owner
    local focused = self:_probe_window_focused()
    if focused == false then
        self.window_focused = false
        self.owner = 'suspended_unfocused'
        self.mouse_captured_by_core = false
        self.cursor_mode = MouseLifecycle.CURSOR_MODE_NONE
        self.fallback_active = false
        self.fallback_reason = 'core_inactive'
        self:_record_transition(prev_owner, self.owner, tostring(reason or 'open') .. ':unfocused', now)
        return false
    end
    if focused == true then
        self.window_focused = true
    end

    local io = safe_get_io(imgui)
    self:_snapshot_io_once(io)
    self:_release_stale_capture_once()
    self:_sync_cursor_visibility(imgui)

    self.owner = 'core'
    self.mouse_captured_by_core = true
    self.acquire_count = self.acquire_count + 1
    self:_record_transition(prev_owner, 'core', reason or 'open', now)

    if type(self.on_focus_regain) == 'function' then
        pcall(self.on_focus_regain, reason or 'open')
    end
    return true
end

-- Release mouse & cursor ownership on open -> closed / zone / logout / unload (strictly idempotent).
-- Pass clear_buttons=true for destructive resets (unload, zone_change, logout, disconnect).
function MouseLifecycle:release(imgui, reason, now, clear_buttons)
    self.core_open = false
    if clear_buttons then
        self.button_owner = {}
    end

    if self.owner == 'ffxi' and not self.saved_valid then
        return false
    end

    local prev_owner = self.owner
    self:_restore_io(imgui)
    self.saved_valid = false
    self.mouse_captured_by_core = false
    self.owner = 'ffxi'
    self.release_count = self.release_count + 1
    self:_record_transition(prev_owner, 'ffxi', reason or 'close', now)
    return true
end

-- Handle explicit or polled Windows foreground focus changes (Alt+Tab out / back).
function MouseLifecycle:on_window_focus_change(focused, imgui, now)
    if type(focused) ~= 'boolean' then return false end
    if focused == self.window_focused then return false end

    self.window_focused = focused
    if not self.core_open then
        -- Never alter FFXI cursor/input ownership while Core is closed.
        return false
    end

    if not focused then
        if self.owner == 'core' then
            self:_restore_io(imgui)
            self.button_owner = {}
            self.mouse_captured_by_core = false
            self.owner = 'suspended_unfocused'
            self.suspend_count = self.suspend_count + 1
            self:_record_transition('core', 'suspended_unfocused', 'window_focus_lost', now)
            if type(self.on_focus_lost) == 'function' then
                pcall(self.on_focus_lost, 'window_focus_lost')
            end
            return true
        end
    else
        if self.owner == 'suspended_unfocused' then
            local io = safe_get_io(imgui)
            self:_snapshot_io_once(io)
            self:_release_stale_capture_once()
            self:_sync_cursor_visibility(imgui)
            self.owner = 'core'
            self.mouse_captured_by_core = true
            self.resume_count = self.resume_count + 1
            self:_record_transition('suspended_unfocused', 'core', 'window_focus_regained', now)
            if type(self.on_focus_regain) == 'function' then
                pcall(self.on_focus_regain, 'window_focus_regained')
            end
            return true
        end
    end
    return false
end

-- Per-frame reconciliation in d3d_present:
--   - Polls read-only foreground focus (Alt+Tab suspend/resume)
--   - Reconciles hub_open mismatch defensively
--   - Keeps cursor visibility healthy without ever invoking ShowCursor/ReleaseCapture
function MouseLifecycle:tick_present(imgui, hub_open, now)
    local is_open = (hub_open == true)
    if is_open and not self.core_open then
        self:acquire(imgui, 'reconcile_open', now)
    elseif (not is_open) and self.core_open then
        self:release(imgui, 'reconcile_close', now, false)
    end

    local focused = self:_probe_window_focused()
    if focused ~= nil and focused ~= self.window_focused then
        self:on_window_focus_change(focused, imgui, now)
    end

    if self.core_open and self.owner == 'core' and self.window_focused then
        self:_sync_cursor_visibility(imgui)
    end
end

-- Handle Ashita v4 `mouse` events. Returns true when e.blocked should be set so
-- clicks, drags, wheel scrolls, and hover never leak into FFXI behind Core.
function MouseLifecycle:on_mouse_event(e, hub_open, imgui, now)
    if type(e) ~= 'table' and type(e) ~= 'cdata' then
        return false
    end
    local msg = e.message
    local is_open = (hub_open == true)

    local down_btn = BUTTON_DOWN_MAP[msg]
    local up_btn   = BUTTON_UP_MAP[msg]
    local is_wheel = (msg == MouseLifecycle.WM_MOUSEWHEEL or msg == MouseLifecycle.WM_MOUSEHWHEEL)
    local is_move  = (msg == MouseLifecycle.WM_MOUSEMOVE)

    if is_open and self.window_focused then
        if self.owner == 'ffxi' then
            self:acquire(imgui, 'mouse_event_reconcile', now)
        end

        if down_btn then
            self.button_owner[down_btn] = true
            self:_sync_cursor_visibility(imgui)
            if type(self.on_mouse_activity) == 'function' then
                pcall(self.on_mouse_activity, now or self.clock())
            end
            self.blocked_mouse_events = self.blocked_mouse_events + 1
            return true
        elseif up_btn then
            self.button_owner[up_btn] = nil
            self.blocked_mouse_events = self.blocked_mouse_events + 1
            return true
        elseif is_wheel then
            if type(self.on_mouse_activity) == 'function' then
                pcall(self.on_mouse_activity, now or self.clock())
            end
            self.blocked_mouse_events = self.blocked_mouse_events + 1
            return true
        elseif is_move then
            local mx = tonumber(e.x)
            local my = tonumber(e.y)
            local moved = false
            if mx ~= nil and my ~= nil then
                if self.last_mouse_x == nil or self.last_mouse_y == nil then
                    moved = true
                else
                    local dx = math.abs(mx - self.last_mouse_x)
                    local dy = math.abs(my - self.last_mouse_y)
                    moved = (dx >= self.move_threshold or dy >= self.move_threshold)
                end
                self.last_mouse_x = mx
                self.last_mouse_y = my
            else
                moved = true
            end
            if moved then
                self:_sync_cursor_visibility(imgui)
                if type(self.on_mouse_activity) == 'function' then
                    pcall(self.on_mouse_activity, now or self.clock())
                end
            end
            self.blocked_mouse_events = self.blocked_mouse_events + 1
            return true
        end
        return false
    end

    -- Core is closed (or unfocused): NEVER block FFXI mouse input, except a
    -- single trailing button-up whose matching button-down was owned by Core
    -- (for example, left-clicking Core's X close button).
    if up_btn and self.button_owner[up_btn] == true then
        self.button_owner[up_btn] = nil
        self.absorbed_release_events = self.absorbed_release_events + 1
        return true
    end

    return false
end

function MouseLifecycle:has_held_core_buttons()
    for _, owned in pairs(self.button_owner) do
        if owned == true then return true end
    end
    return false
end

-- Lightweight, non-sensitive diagnostic snapshot (no raw keys or coordinates).
function MouseLifecycle:diagnostics()
    local copy_tr = {}
    for i = 1, #self.transitions do
        local t = self.transitions[i]
        copy_tr[i] = {
            at         = t.at,
            from_owner = t.from_owner,
            to_owner   = t.to_owner,
            reason     = t.reason,
        }
    end
    return {
        core_open               = self.core_open,
        owner                   = self.owner,
        mouse_captured          = self.mouse_captured_by_core,
        cursor_mode             = self.cursor_mode,
        imgui_draw_cursor       = self.imgui_draw_cursor_applied,
        os_cursor_visible       = self.os_cursor_visible,
        fallback_active         = self.fallback_active,
        fallback_reason         = self.fallback_reason,
        fallback_activations    = self.fallback_activations,
        window_focused          = self.window_focused,
        last_transition         = self.last_transition,
        acquire_count           = self.acquire_count,
        release_count           = self.release_count,
        suspend_count           = self.suspend_count,
        resume_count            = self.resume_count,
        capture_releases        = self.capture_releases,
        blocked_mouse_events    = self.blocked_mouse_events,
        absorbed_release_events = self.absorbed_release_events,
        transitions             = copy_tr,
    }
end

function MouseLifecycle:format_status_line()
    local d = self:diagnostics()
    local os_vis = (d.os_cursor_visible == nil) and 'unobserved' or tostring(d.os_cursor_visible)
    return ('input_lifecycle open=%s owner=%s capture=%s cursor_mode=%s os_cursor=%s imgui_cursor=%s fallback=%s(%s) win_focus=%s acq=%d rel=%d susp=%d res=%d cap_rel=%d last=%s'):format(
        tostring(d.core_open),
        tostring(d.owner),
        tostring(d.mouse_captured),
        tostring(d.cursor_mode),
        os_vis,
        tostring(d.imgui_draw_cursor),
        tostring(d.fallback_active),
        tostring(d.fallback_reason),
        tostring(d.window_focused),
        d.acquire_count,
        d.release_count,
        d.suspend_count,
        d.resume_count,
        d.capture_releases,
        tostring(d.last_transition)
    )
end

return MouseLifecycle
