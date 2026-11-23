-- SoulspireXI Core <-> Soulspire Native versioned interface bridge (ABI v2).
-- Read-only capability & health discovery via SoulspireNativeGetInterfaceInfo.
local NativeBridge = {}

NativeBridge.EXPECTED_ABI_VERSION = 2

local ok_ffi, ffi = pcall(require, 'ffi')
local iface_info_t, get_info_fn_t
local cache = { module = nil, addr = nil, fn = nil }

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
    local ok2, t2 = pcall(ffi.typeof, 'uint32_t (__stdcall *)(void*, uint32_t)')
    if ok2 then get_info_fn_t = t2 end
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
    if not (ffi and iface_info_t and get_info_fn_t) then
        return nil, 'FFI unavailable'
    end
    local ok, info, err = pcall(function()
        local handle = ffi.C.GetModuleHandleA('soulspire_native.dll')
        if handle == nil then
            cache.module, cache.addr, cache.fn = nil, nil, nil
            return nil, 'soulspire_native.dll not loaded'
        end
        local addr = ffi.C.GetProcAddress(handle, 'SoulspireNativeGetInterfaceInfo')
        if addr == nil then
            return nil, 'SoulspireNativeGetInterfaceInfo unavailable'
        end
        if cache.module ~= handle or cache.addr ~= addr then
            cache.module, cache.addr = handle, addr
            cache.fn = ffi.cast(get_info_fn_t, addr)
        end
        local buf = ffi.new(iface_info_t)
        local rc = tonumber(cache.fn(buf, ffi.sizeof(buf)))
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

return NativeBridge
