-- SoulspireXI Core: Native FFXI Main Menu Integration Bridge.
--
-- Strategy (Zero-Guessing, Isolated & Reversible):
--   1. Probes crystaljobs.dll (read-only FFI) for an optional verified native
--      main-menu hook export (CrystalJobsGetMainMenuBridge). If unsupported
--      by the installed DLL (current 24-hook baseline), fails gracefully without
--      touching FFXiMain.dll memory or any existing Soul identity/equipment hooks.
--   2. Falls back cleanly to verified read-only MenuManager inspection
--      (AshitaCore:GetPointerManager():Get('menu') -> storage - 0x54, identical
--      to crystalsocket/menu.lua) to dock a native-styled "Soulspire" entry onto
--      FFXI's top-level Main Menu (menu    mnu1 / mnu2 / mainmenu / submain).
--   3. If MenuManager layout is unavailable, degrades safely to standalone
--      /soulspire mode without error.

local MenuBridge = {}
MenuBridge.__index = MenuBridge

-- Recognized FFXI top-level Main Menu form names (Page 1 & Page 2).
-- Verified live on retail Windows FFXI: "menu    menuwind" rect=(1792,48,1904,250).
-- Strictly excludes Equipment (menu    equip), ItemInfo, Magic, Ability, etc.
MenuBridge.MAIN_MENU_FORMS = {
    ['menu    menuwind'] = true,
    ['menu    mnu1']     = true,
    ['menu    mnu2']     = true,
    ['menu    menu1']    = true,
    ['menu    menu2']    = true,
    ['menu    com1']     = true,
    ['menu    com2']     = true,
    ['menu    main1']    = true,
    ['menu    main2']    = true,
    ['menu    mainmenu'] = true,
    ['menu    submain']  = true,
}

local function address(value, span)
    return type(value) == 'number' and value >= 0x10000
        and value <= 0xFFFFFFFF - span + 1 and value % 1 == 0
end

local function pointer(value, span)
    return address(value, span) and value % 4 == 0
end

-- Safe read-only probe for a future verified native Main Menu hook in crystaljobs.dll.
-- Never patches memory and fails gracefully on missing DLL or missing export.
function MenuBridge.probe_native_hook(custom_probe)
    if type(custom_probe) == 'function' then
        local ok, supported, detail = pcall(custom_probe)
        if ok and supported == true then
            return true, detail or 'native-hook-active'
        end
        return false, (ok and detail) or 'native hook probe failed'
    end

    local ok, supported, detail = pcall(function()
        local ffi = require('ffi')
        pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char* name);')
        pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void* module, const char* name);')
        local mod = ffi.C.GetModuleHandleA('crystaljobs.dll')
        if mod == nil then
            return false, 'crystaljobs.dll not loaded'
        end
        local fn = ffi.C.GetProcAddress(mod, 'CrystalJobsGetMainMenuBridge')
        if fn == nil then
            return false, 'CrystalJobsGetMainMenuBridge not present in 24-hook crystaljobs.dll'
        end
        return true, 'CrystalJobsGetMainMenuBridge export detected'
    end)
    if ok then
        return supported == true, detail
    end
    return false, 'FFI probe unavailable'
end

function MenuBridge.new(memory, scaling, operand, opts)
    -- Backward-compatible 4th argument: either main_menu_forms table or opts table
    local main_menu_forms = nil
    local native_probe = nil
    if type(opts) == 'table' then
        if opts.forms or opts.native_probe then
            main_menu_forms = opts.forms
            native_probe = opts.native_probe
        else
            main_menu_forms = opts
        end
    end

    local self = setmetatable({
        memory                = memory,
        scaling               = scaling,
        forms                 = main_menu_forms or MenuBridge.MAIN_MENU_FORMS,
        manager               = nil,
        native_hook_supported = false,
        native_hook_reason    = 'not probed',
        mode                  = 'standalone',
        last_error            = nil,
    }, MenuBridge)

    local hook_ok, hook_detail = MenuBridge.probe_native_hook(native_probe)
    self.native_hook_supported = hook_ok
    self.native_hook_reason = hook_detail

    local ok, manager = pcall(function()
        if not memory or not address(operand, 4) then return nil end
        local storage = memory.read_uint32(operand)
        return pointer(storage, 4) and pointer(storage - 0x54, 4) and (storage - 0x54) or nil
    end)
    self.manager = ok and manager or nil
    if not ok then
        self.last_error = tostring(manager)
    end

    if self.native_hook_supported then
        self.mode = 'native-hook'
    elseif self.manager ~= nil and self.scaling ~= nil then
        self.mode = 'native-styled-fallback'
    else
        self.mode = 'standalone'
    end

    return self
end

function MenuBridge:is_available()
    return self.manager ~= nil and self.scaling ~= nil
end

function MenuBridge:get_mode()
    return self.mode
end

function MenuBridge:diagnostics()
    return {
        mode                  = self.mode,
        bridge_available      = self:is_available(),
        native_hook_supported = self.native_hook_supported,
        native_hook_reason    = self.native_hook_reason,
        last_error            = self.last_error,
    }
end

-- Walk all visible native FFXI menu windows (strictly read-only).
function MenuBridge:inspect_all()
    if not self:is_available() then return nil end
    local ok, result = pcall(function()
        local memory = self.memory
        local current = memory.read_uint32(self.manager + 0x54)
        if not pointer(current, 0x71) then return nil end
        if memory.read_uint32(current + 0x10) == 0xE or memory.read_uint8(current + 0x70) ~= 0 then
            return { current = nil, current_name = nil, cursor = nil, windows = {} }
        end

        local node = memory.read_uint32(self.manager)
        local seen, windows = {}, {}
        local current_name = nil

        for _ = 1, 128 do
            if node == 0 then break end
            if not pointer(node, 0x15) or seen[node] then return nil end
            seen[node] = true

            if memory.read_uint8(node + 0x14) == 0 then
                local window = memory.read_uint32(node + 0x10)
                if not pointer(window, 0x6F) then return nil end
                if memory.read_uint8(window + 0x69) ~= 0
                    and memory.read_uint8(window + 0x6E) == 0 then
                    local form = memory.read_uint32(window + 4)
                    if not pointer(form, 86) then return nil end
                    local name = memory.read_string(form + 70, 16):gsub('%z.*$', ''):gsub('%s+$', '')
                    local left = memory.read_int16(window + 0x3A)
                    local top = memory.read_int16(window + 0x3C)
                    local right = memory.read_int16(window + 0x3E)
                    local bottom = memory.read_int16(window + 0x40)
                    local entry = {
                        window = window,
                        name = name,
                        left = left,
                        top = top,
                        right = right,
                        bottom = bottom,
                        is_current = (window == current),
                    }
                    windows[#windows + 1] = entry
                    if window == current then
                        current_name = name
                    end
                end
            end

            node = memory.read_uint32(node)
            if node ~= 0 and seen[node] then return nil end
        end

        if node ~= 0 then return nil end
        local cursor = memory.read_int16(current + 0x4C)
        return {
            current = current,
            current_name = current_name,
            cursor = cursor,
            windows = windows,
        }
    end)
    if not ok then
        self.last_error = tostring(result)
        return nil
    end
    return result
end

-- Returns a main-menu dock context when an FFXI top-level Main Menu is open and active,
-- or nil when no Main Menu is active (e.g., Equipment, Magic, Gameplay, Cutscene).
function MenuBridge:main_menu_context()
    local state = self:inspect_all()
    if not state or not state.current or not state.current_name then return nil end
    if not self.forms[state.current_name] then return nil end

    local main_win = nil
    for _, win in ipairs(state.windows) do
        if win.window == state.current then
            main_win = win
            break
        end
    end
    if not main_win then return nil end

    local scaling = self.scaling
    local left, top, right, bottom = main_win.left, main_win.top, main_win.right, main_win.bottom
    if left < 0 or top < 0 or right <= left or bottom <= top then return nil end
    if scaling.menu and (right > scaling.menu.w or bottom > scaling.menu.h) then return nil end

    local dock_x = scaling.scale_w(left)
    local dock_y = scaling.scale_h(bottom + 4)
    local dock_w = scaling.scale_w(right - left)
    local dock_right = scaling.scale_w(right)
    -- Clamp dock cleanly inside screen if main menu sits near bottom/right edge
    if scaling.scaled and scaling.scaled.h and (dock_y + 38) > scaling.scaled.h then
        dock_y = math.max(8, scaling.scale_h(top) - 40)
    end
    local min_w = 156
    if dock_w < min_w and scaling.scaled and scaling.scaled.w and (dock_x + min_w) > (scaling.scaled.w - 4) then
        -- Flush right-align with the FFXI Main Menu's right edge (e.g. menuwind at right=1904)
        dock_x = math.max(4, dock_right - min_w)
    elseif scaling.scaled and scaling.scaled.w then
        dock_x = math.max(4, math.min(dock_x, scaling.scaled.w - math.max(min_w, dock_w) - 4))
    end

    return {
        window = state.current,
        name = state.current_name,
        cursor = state.cursor,
        mode = self.mode,
        bounds = {
            left = left,
            top = top,
            right = right,
            bottom = bottom,
        },
        dock = {
            x = dock_x,
            y = dock_y,
            w = dock_w,
        },
    }
end

return MenuBridge
