-- SoulspireXI Core <-> Soulspire Native versioned interface bridge (ABI v2).
-- Connects to soulspire_native.dll for:
--   1. Interface & capability diagnostics (SoulspireNativeGetInterfaceInfo)
--   2. Native FFXI Commands menu ("menu    menuwind") status (SoulspireNativeGetMainMenuStatus)
--   3. Native Commands menu "Soulspire" confirm open-request dispatch (SoulspireNativeConsumeCoreOpenRequest)
local NativeBridge = {}

NativeBridge.EXPECTED_ABI_VERSION = 2
NativeBridge.CAP_COMMANDS_MENU_ENTRY = 0x10000 -- 1u << 16

local ok_ffi, ffi = pcall(require, 'ffi')
local iface_info_t, main_menu_status_t, get_struct_fn_t, consume_open_fn_t
local cache = {
    module = nil,
    info_addr = nil, info_fn = nil,
    mm_addr = nil, mm_fn = nil,
    consume_addr = nil, consume_fn = nil,
}

if ok_ffi and ffi then
    pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char*);')
    pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void*, const char*);')
    local ok1, t1 = pcall(ffi.typeof, [=[struct {
        uint32_t size;
        uint32_t abi_version;
        uint32_t expected_hooks;
        uint32_t installed_hooks;
        uint32_t capabilities;
        uint32_t enabled_modules_mask;
        uint32_t active_modules_mask;
        uint32_t menu2fon_banks_used;
        uint32_t menu2fon_banks_max;
        uint32_t menu2fon_fallback_draws;
        uint32_t config_from_file;
        uint32_t log_level;
        char     project_name[32];
        char     registry_hash[24];
    }[1]]=])
    if ok1 then iface_info_t = t1 end

    local ok2, t2 = pcall(ffi.typeof, [=[struct {
        uint32_t size;
        uint32_t version;
        uint32_t hooks_installed;
        uint32_t injected;
        uint32_t button_id;
        uint32_t button_count;
        uint32_t frame_height;
        uint32_t sprite_synthesized;
        uint32_t sprite_banks_used;
        uint32_t open_injections;
        uint32_t nav_overrides;
        uint32_t activations;
        uint32_t pending_open_requests;
        uint32_t total_hooks;
        uint32_t expected_hooks;
    }[1]]=])
    if ok2 then main_menu_status_t = t2 end

    local ok3, t3 = pcall(ffi.typeof, 'uint32_t (__stdcall *)(void*, uint32_t)')
    if ok3 then get_struct_fn_t = t3 end

    local ok4, t4 = pcall(ffi.typeof, 'uint32_t (__stdcall *)(void)')
    if ok4 then consume_open_fn_t = t4 end
end

local function clear_cache()
    cache.module = nil
    cache.info_addr, cache.info_fn = nil, nil
    cache.mm_addr, cache.mm_fn = nil, nil
    cache.consume_addr, cache.consume_fn = nil, nil
end

local function resolve_module()
    local handle = ffi.C.GetModuleHandleA('soulspire_native.dll')
    if handle == nil then
        clear_cache()
        return nil
    end
    if cache.module ~= handle then
        clear_cache()
        cache.module = handle
    end
    return handle
end

local function read_cstr(arr, cap)
    local out = {}
    for i = 0, cap - 1 do
        local b = tonumber(arr[i]) or 0
        if b == 0 then break end
        out[#out + 1] = string.char(b)
    end
    return table.concat(out)
end

function NativeBridge.query()
    if not (ffi and iface_info_t and get_struct_fn_t) then
        return nil, 'FFI unavailable'
    end
    local ok, info, err = pcall(function()
        local handle = resolve_module()
        if handle == nil then
            return nil, 'soulspire_native.dll not loaded'
        end
        local addr = ffi.C.GetProcAddress(handle, 'SoulspireNativeGetInterfaceInfo')
        if addr == nil then
            return nil, 'SoulspireNativeGetInterfaceInfo unavailable'
        end
        if cache.info_addr ~= addr then
            cache.info_addr = addr
            cache.info_fn = ffi.cast(get_struct_fn_t, addr)
        end
        local buf = ffi.new(iface_info_t)
        local rc = tonumber(cache.info_fn(buf, ffi.sizeof(buf)))
        if rc ~= 0 or tonumber(buf[0].size) ~= 104 then
            return nil, 'SoulspireNativeGetInterfaceInfo failed: ' .. tostring(rc)
        end
        return {
            abi_version = tonumber(buf[0].abi_version),
            expected_hooks = tonumber(buf[0].expected_hooks),
            installed_hooks = tonumber(buf[0].installed_hooks),
            capabilities = tonumber(buf[0].capabilities),
            enabled_modules_mask = tonumber(buf[0].enabled_modules_mask),
            active_modules_mask = tonumber(buf[0].active_modules_mask),
            menu2fon_banks_used = tonumber(buf[0].menu2fon_banks_used),
            menu2fon_banks_max = tonumber(buf[0].menu2fon_banks_max),
            menu2fon_fallback_draws = tonumber(buf[0].menu2fon_fallback_draws),
            config_from_file = tonumber(buf[0].config_from_file) == 1,
            log_level = tonumber(buf[0].log_level),
            project_name = read_cstr(buf[0].project_name, 32),
            registry_hash = read_cstr(buf[0].registry_hash, 24),
        }, nil
    end)
    if not ok then
        return nil, tostring(info)
    end
    return info, err
end

function NativeBridge.main_menu_status()
    if not (ffi and main_menu_status_t and get_struct_fn_t) then
        return nil, 'FFI unavailable'
    end
    local ok, status, err = pcall(function()
        local handle = resolve_module()
        if handle == nil then
            return nil, 'soulspire_native.dll not loaded'
        end
        local addr = ffi.C.GetProcAddress(handle, 'SoulspireNativeGetMainMenuStatus')
        if addr == nil then
            return nil, 'SoulspireNativeGetMainMenuStatus unavailable (requires 31-hook soulspire_native.dll)'
        end
        if cache.mm_addr ~= addr then
            cache.mm_addr = addr
            cache.mm_fn = ffi.cast(get_struct_fn_t, addr)
        end
        local buf = ffi.new(main_menu_status_t)
        local rc = tonumber(cache.mm_fn(buf, ffi.sizeof(buf)))
        if rc ~= 0 or tonumber(buf[0].size) ~= 60 then
            return nil, 'SoulspireNativeGetMainMenuStatus failed: ' .. tostring(rc)
        end
        return {
            hooks_installed = tonumber(buf[0].hooks_installed) == 1,
            injected = tonumber(buf[0].injected) == 1,
            button_id = tonumber(buf[0].button_id),
            button_count = tonumber(buf[0].button_count),
            frame_height = tonumber(buf[0].frame_height),
            sprite_synthesized = tonumber(buf[0].sprite_synthesized) == 1,
            sprite_banks_used = tonumber(buf[0].sprite_banks_used),
            open_injections = tonumber(buf[0].open_injections),
            nav_overrides = tonumber(buf[0].nav_overrides),
            activations = tonumber(buf[0].activations),
            pending_open_requests = tonumber(buf[0].pending_open_requests),
            total_hooks = tonumber(buf[0].total_hooks),
            expected_hooks = tonumber(buf[0].expected_hooks),
        }, nil
    end)
    if not ok then
        return nil, tostring(status)
    end
    return status, err
end

function NativeBridge.consume_core_open_request()
    if not (ffi and consume_open_fn_t) then
        return 0
    end
    local ok, count = pcall(function()
        local handle = resolve_module()
        if handle == nil then return 0 end
        local addr = ffi.C.GetProcAddress(handle, 'SoulspireNativeConsumeCoreOpenRequest')
        if addr == nil then return 0 end
        if cache.consume_addr ~= addr then
            cache.consume_addr = addr
            cache.consume_fn = ffi.cast(consume_open_fn_t, addr)
        end
        return tonumber(cache.consume_fn()) or 0
    end)
    return ok and (count or 0) or 0
end

return NativeBridge
