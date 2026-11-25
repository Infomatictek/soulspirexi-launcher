-- SoulspireXI Core: Native FFXI Commands Menu Integration Bridge.
--
-- Connects directly to soulspire_native.dll (31-hook ABI v2), which injects a
-- genuine native "Soulspire" entry (Btn 16) between Status (Btn 1) and
-- Equipment (Btn 2) inside FFXI's original Commands menu ("menu    menuwind").
--
-- Never renders a floating ImGui button or docked overlay substitute.
-- When soulspire_native.dll is unavailable, degrades cleanly to standalone
-- /soulspire mode without touching FFXiMain.dll memory.

local ok_nb, NativeBridge = pcall(require, 'core.native_bridge')
if not ok_nb then NativeBridge = nil end

local MenuBridge = {}
MenuBridge.__index = MenuBridge

-- Recognized FFXI top-level Commands Menu form names (strictly read-only diagnostics).
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

-- Read-only probe for soulspire_native.dll's 31-hook native Commands menu entry.
function MenuBridge.probe_native_hook(custom_probe)
    if type(custom_probe) == 'function' then
        local ok, supported, detail = pcall(custom_probe)
        if ok and supported == true then
            return true, detail or 'soulspire_native Commands menu active'
        end
        return false, (ok and detail) or 'native hook probe failed'
    end

    -- VanaCore-native Soulspire engine (DEC-028): require kCapCommandsMenuEntry (0x10000) for main Commands menu readiness.
    if type(vana) == 'table' and type(vana.soulspire) == 'table' and type(vana.soulspire.enabled) == 'function' then
        local ok_en, enabled = pcall(vana.soulspire.enabled)
        if ok_en and enabled == true then
            local ok_d, diag = pcall(vana.soulspire.diagnostics)
            if ok_d and type(diag) == 'table' then
                local inst = tonumber(diag.hooks_installed) or 0
                local tot  = tonumber(diag.hooks_total) or 0
                local caps = tonumber(diag.capabilities) or 0
                local has_cmd_menu = (math.floor(caps / 65536) % 2) == 1
                if has_cmd_menu then
                    return true, string.format('VanaCore-native Commands menu active (btn=16 hooks=%d/%d)', inst, tot)
                end
                return false, string.format('VanaCore-native engine active (hooks=%d/%d) but Commands menu hooks inactive', inst, tot)
            end
        end
    end

    if NativeBridge and type(NativeBridge.main_menu_status) == 'function' then
        local st, err = NativeBridge.main_menu_status()
        if st then
            if st.hooks_installed then
                return true, string.format(
                    'soulspire_native Commands menu active (btn=%d hooks=%d/%d)',
                    st.button_id, st.total_hooks, st.expected_hooks)
            end
            return false, string.format(
                'soulspire_native loaded but Commands menu hooks inactive (hooks=%d/%d)',
                st.total_hooks, st.expected_hooks)
        end
        return false, tostring(err or 'soulspire_native.dll unavailable')
    end
    return false, 'NativeBridge unavailable'
end

function MenuBridge.new(memory, scaling, operand, opts)
    local main_menu_forms = nil
    local native_probe = nil
    local open_consumer = nil
    if type(opts) == 'table' then
        if opts.forms or opts.native_probe or opts.open_consumer then
            main_menu_forms = opts.forms
            native_probe = opts.native_probe
            open_consumer = opts.open_consumer
        else
            main_menu_forms = opts
        end
    end

    local self = setmetatable({
        memory                = memory,
        scaling               = scaling,
        forms                 = main_menu_forms or MenuBridge.MAIN_MENU_FORMS,
        native_probe          = native_probe,
        open_consumer         = open_consumer,
        manager               = nil,
        native_hook_supported = false,
        native_hook_reason    = 'not probed',
        mode                  = 'standalone',
        last_error            = nil,
    }, MenuBridge)

    local ok, manager = pcall(function()
        if not memory or not address(operand, 4) then return nil end
        local storage = memory.read_uint32(operand)
        return pointer(storage, 4) and pointer(storage - 0x54, 4) and (storage - 0x54) or nil
    end)
    self.manager = ok and manager or nil
    if not ok then
        self.last_error = tostring(manager)
    end

    self:refresh_native_status()
    return self
end

function MenuBridge:refresh_native_status()
    local hook_ok, hook_detail = MenuBridge.probe_native_hook(self.native_probe)
    self.native_hook_supported = hook_ok
    self.native_hook_reason = hook_detail
    if self.native_hook_supported then
        self.mode = 'native-commands-menu'
    else
        self.mode = 'standalone'
    end
    return self.native_hook_supported
end

-- Poll and atomically consume pending open requests emitted when the user
-- confirms the native "Soulspire" entry inside FFXI's Commands menu.
function MenuBridge:consume_native_open_request()
    if type(self.open_consumer) == 'function' then
        local ok, count = pcall(self.open_consumer)
        return ok and (tonumber(count) or 0) or 0
    end
    if type(vana) == 'table' and type(vana.soulspire) == 'table' and type(vana.soulspire.consume_open_core) == 'function' then
        local ok, count = pcall(vana.soulspire.consume_open_core)
        if ok and (tonumber(count) or 0) > 0 then
            return tonumber(count)
        end
    end
    if NativeBridge and type(NativeBridge.consume_core_open_request) == 'function' then
        return NativeBridge.consume_core_open_request()
    end
    return 0
end

function MenuBridge:is_available()
    return self.native_hook_supported or (self.manager ~= nil and self.scaling ~= nil)
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

-- Walk all visible native FFXI menu windows (strictly read-only diagnostics).
function MenuBridge:inspect_all()
    if self.manager == nil or self.memory == nil then return nil end
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

-- Returns read-only context when FFXI's top-level Commands menu is open (for diagnostics).
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

    return {
        window = state.current,
        name = state.current_name,
        cursor = state.cursor,
        rect = {
            left = main_win.left,
            top = main_win.top,
            right = main_win.right,
            bottom = main_win.bottom,
        },
    }
end

return MenuBridge
