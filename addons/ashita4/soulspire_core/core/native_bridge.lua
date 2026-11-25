-- SoulspireXI Core <-> Soulspire Native versioned interface bridge (ABI v2).
-- Read-only capability, Main Menu injection, and equipment/weapon-model runtime discovery.
local NativeBridge = {}

NativeBridge.EXPECTED_ABI_VERSION = 2
NativeBridge.CAP_COMMANDS_MENU_ENTRY  = 0x10000
NativeBridge.CAP_WEAPON_MODEL_RESOLVE = 0x20000
NativeBridge.CAP_WEAPON_OFFHAND_BONE  = 0x40000

local ok_ffi, ffi = pcall(require, 'ffi')
local iface_info_t, status_t, weapon_status_t, hook_diag_t, ident_diag_t, weapon_model_diag_t, weapon_offhand_diag_t, main_menu_status_t
local get_info_fn_t, set_u32x4_fn_t, consume_open_fn_t
local cache = {
    module = nil,
    info_addr = nil, info_fn = nil,
    mm_addr = nil, mm_fn = nil,
    consume_addr = nil, consume_fn = nil,
}

NativeBridge.ABI_SIZES = {
    interface_info = 104,
    status = 68,
    weapon_status = 36,
    hook_diag = 60,
    identity_diag = 216,
    weapon_model_diag = 92,
    weapon_offhand_diag = 72,
    main_menu_status = 60,
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

    local ok_st, t_st = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, enabled, hooks, character_id, job, known, branch;
        uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
        uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
    }[1]]=])
    if ok_st then status_t = t_st end

    local ok_ws, t_ws = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, rule_count, rule_generation, effective_level;
        uint32_t allow_hits, deny_hits, total_hooks, expected_hooks;
    }[1]]=])
    if ok_ws then weapon_status_t = t_ws end

    local ok_hd, t_hd = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, total_hooks, expected_hooks;
        uint32_t installed_mask, site_set_mask, capabilities;
        uint32_t ffxi_base, ffxi_timestamp, ffxi_image_size;
        uint32_t init_stage, failed_rva, failed_index;
        uint8_t  observed_bytes[8];
    }[1]]=])
    if ok_hd then hook_diag_t = t_hd end

    local ok_id, t_id = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, source, status, schema_version, soul_count;
        int32_t  tracking_px, offset_x_px;
        uint32_t use_glyph_widths, presentation_from_file;
        char     active_registry_hash[24];
        char     compiled_registry_hash[24];
        char     warning[128];
    }[1]]=])
    if ok_id then ident_diag_t = t_id end

    local ok_wmd, t_wmd = pcall(ffi.typeof, [=[struct {
        uint32_t size, version;
        uint32_t hook32_calls, hook32_remaps;
        uint32_t deny_disabled, deny_zero_or_shield, deny_actor_id;
        uint32_t deny_local_equip, deny_fallback_84, deny_auth;
        uint32_t last_actor_id, last_local_char_id, last_is_local;
        uint32_t last_look_word, last_sub_model_id, last_result_slot;
        uint32_t last_soul_known, last_job, last_branch, last_effective_level;
        uint32_t local_main_packed, local_sub_packed, pres_summary_packed;
    }[1]]=])
    if ok_wmd then weapon_model_diag_t = t_wmd end

    local ok_wod, t_wod = pcall(ffi.typeof, [=[struct {
        uint32_t size, version;
        uint32_t hooks_installed_count, hooks_installed_mask, cap_active;
        uint32_t attach_calls_slot7, authorized_sub_attaches, add_mesh_calls_total;
        uint32_t registered_sub_meshes, registered_sub_total;
        uint32_t draw_calls_total, matching_mesh_draws;
        uint32_t bone_swaps_succeeded, bone_lookups_failed, bone_restores_count;
        uint32_t last_idx_main, last_idx_sub, last_matrices_distinct;
    }[1]]=])
    if ok_wod then weapon_offhand_diag_t = t_wod end

    local ok_mm, t_mm = pcall(ffi.typeof, [=[struct {
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
    if ok_mm then main_menu_status_t = t_mm end

    local ok2, t2 = pcall(ffi.typeof, 'uint32_t (__stdcall *)(void*, uint32_t)')
    if ok2 then get_info_fn_t = t2 end
    local ok3, t3 = pcall(ffi.typeof, 'uint32_t (__stdcall *)(uint32_t, uint32_t, uint32_t, uint32_t)')
    if ok3 then set_u32x4_fn_t = t3 end
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

function NativeBridge.verify_abi_sizes()
    if not (ok_ffi and ffi) then return false, 'FFI unavailable' end
    local checks = {
        { 'interface_info', iface_info_t, NativeBridge.ABI_SIZES.interface_info },
        { 'status', status_t, NativeBridge.ABI_SIZES.status },
        { 'weapon_status', weapon_status_t, NativeBridge.ABI_SIZES.weapon_status },
        { 'hook_diag', hook_diag_t, NativeBridge.ABI_SIZES.hook_diag },
        { 'identity_diag', ident_diag_t, NativeBridge.ABI_SIZES.identity_diag },
        { 'weapon_model_diag', weapon_model_diag_t, NativeBridge.ABI_SIZES.weapon_model_diag },
        { 'weapon_offhand_diag', weapon_offhand_diag_t, NativeBridge.ABI_SIZES.weapon_offhand_diag },
        { 'main_menu_status', main_menu_status_t, NativeBridge.ABI_SIZES.main_menu_status },
    }
    for _, c in ipairs(checks) do
        if not c[2] or ffi.sizeof(c[2]) ~= c[3] then
            return false, ('ABI size mismatch for %s: got %s expected %d'):format(
                c[1], c[2] and tostring(ffi.sizeof(c[2])) or 'nil', c[3])
        end
    end
    return true, nil
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

local function call_u32x4_export(export_name, a, b, c, d)
    if not (ok_ffi and ffi and set_u32x4_fn_t) then return false end
    local ok, res = pcall(function()
        local handle = resolve_module()
        if handle == nil then return false end
        local addr = ffi.C.GetProcAddress(handle, export_name)
        if addr == nil then return false end
        local fn = ffi.cast(set_u32x4_fn_t, addr)
        return tonumber(fn(tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0, tonumber(d) or 0)) == 0
    end)
    return ok and res == true
end

function NativeBridge.set_local_equipped_weapons(main_item_id, main_skill, sub_item_id, sub_skill)
    return call_u32x4_export('SoulspireNativeSetLocalEquippedWeapons', main_item_id, main_skill, sub_item_id, sub_skill)
end

function NativeBridge.upsert_peer_soul(actor_id, job, branch, effective_level)
    return call_u32x4_export('SoulspireNativeUpsertPeerSoul', actor_id, job, branch, effective_level)
end

function NativeBridge.has_weapon_model_resolve_capability()
    local info = NativeBridge.query()
    if not info or type(info.capabilities) ~= 'number' then return false end
    local bit = require('bit')
    return bit.band(info.capabilities, bit.lshift(1, 17)) ~= 0
end

function NativeBridge.query()
    if not (ffi and iface_info_t and get_info_fn_t) then
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
            cache.info_fn = ffi.cast(get_info_fn_t, addr)
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
    if not (ffi and main_menu_status_t and get_info_fn_t) then
        return nil, 'FFI unavailable'
    end
    local ok, status, err = pcall(function()
        local handle = resolve_module()
        if handle == nil then
            return nil, 'soulspire_native.dll not loaded'
        end
        local addr = ffi.C.GetProcAddress(handle, 'SoulspireNativeGetMainMenuStatus')
        if addr == nil then
            return nil, 'SoulspireNativeGetMainMenuStatus unavailable (requires 31/32-hook soulspire_native.dll)'
        end
        if cache.mm_addr ~= addr then
            cache.mm_addr = addr
            cache.mm_fn = ffi.cast(get_info_fn_t, addr)
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

local function call_struct_export(handle, export_name, ctype)
    if handle == nil then return nil, 'module handle is nil' end
    if not (ctype and get_info_fn_t) then return nil, 'FFI type unavailable for ' .. export_name end
    local ok, res, err = pcall(function()
        local addr = ffi.C.GetProcAddress(handle, export_name)
        if addr == nil then
            return nil, export_name .. ' export missing'
        end
        local fn = ffi.cast(get_info_fn_t, addr)
        local buf = ffi.new(ctype)
        local rc = tonumber(fn(buf, ffi.sizeof(buf)))
        if rc ~= 0 then
            return nil, export_name .. ' rc=' .. tostring(rc)
        end
        return buf[0], nil
    end)
    if not ok then
        return nil, export_name .. ' exception: ' .. tostring(res)
    end
    return res, err
end

-- Unified runtime snapshot reusing the canonical soulspire_native.dll bridge.
-- Isolates each export query so one failing export never falsely reports dll_loaded=false.
function NativeBridge.query_equipment_runtime()
    if not (ok_ffi and ffi) then
        return { dll_loaded = false, query_errors = { 'FFI unavailable' } }
    end
    local ok_h, handle = pcall(function()
        return ffi.C.GetModuleHandleA('soulspire_native.dll')
    end)
    if not ok_h then
        return { dll_loaded = false, query_errors = { 'GetModuleHandleA failed: ' .. tostring(handle) } }
    end
    if handle == nil then
        return { dll_loaded = false, query_errors = { 'soulspire_native.dll not loaded in process' } }
    end

    local res = { dll_loaded = true, query_errors = {} }
    local function note_err(e)
        if e then res.query_errors[#res.query_errors + 1] = e end
    end

    local ii, ii_err = NativeBridge.query()
    if ii then
        res.abi_version = ii.abi_version
        res.expected_hooks = ii.expected_hooks
        res.installed_hooks = ii.installed_hooks
        res.capabilities = ii.capabilities
        res.enabled_modules_mask = ii.enabled_modules_mask
        res.active_modules_mask = ii.active_modules_mask
        res.registry_hash = ii.registry_hash
    else
        note_err(ii_err)
    end

    local st, st_err = call_struct_export(handle, 'SoulspireNativeGetStatus', status_t)
    if st then
        res.enabled = tonumber(st.enabled) == 1
        res.hooks = tonumber(st.hooks)
        res.character_id = tonumber(st.character_id)
        res.job = tonumber(st.job)
        res.known = tonumber(st.known) == 1
        res.branch = tonumber(st.branch)
        res.last_error = tonumber(st.last_error)
    else
        note_err(st_err)
    end

    local ws, ws_err = call_struct_export(handle, 'SoulspireNativeGetWeaponStatus', weapon_status_t)
    if ws then
        res.weapon_rules_count = tonumber(ws.rule_count)
        res.weapon_rules_generation = tonumber(ws.rule_generation)
        res.native_effective_level = tonumber(ws.effective_level)
        res.weapon_allow_hits = tonumber(ws.allow_hits)
        res.weapon_deny_hits = tonumber(ws.deny_hits)
    else
        note_err(ws_err)
    end

    local hd, hd_err = call_struct_export(handle, 'SoulspireNativeGetHookDiagnostics', hook_diag_t)
    if hd then
        res.expected_hooks = tonumber(hd.expected_hooks)
        res.installed_hooks = tonumber(hd.total_hooks)
        res.installed_mask = tonumber(hd.installed_mask)
        res.capabilities = tonumber(hd.capabilities)
        res.init_stage = tonumber(hd.init_stage)
        res.failed_rva = tonumber(hd.failed_rva)
    else
        note_err(hd_err)
    end

    local id, id_err = call_struct_export(handle, 'SoulspireNativeGetIdentityDiagnostics', ident_diag_t)
    if id then
        res.compiled_registry_hash = read_cstr(id.compiled_registry_hash, 24)
        res.active_registry_hash = read_cstr(id.active_registry_hash, 24)
    else
        note_err(id_err)
    end

    return res
end

function NativeBridge.query_weapon_model_diag()
    if not (ok_ffi and ffi and weapon_model_diag_t) then
        return nil, 'FFI unavailable'
    end
    local ok_h, handle = pcall(function()
        return ffi.C.GetModuleHandleA('soulspire_native.dll')
    end)
    if not ok_h or handle == nil then
        return nil, 'soulspire_native.dll not loaded'
    end
    local d, err = call_struct_export(handle, 'SoulspireNativeGetWeaponModelDiag', weapon_model_diag_t)
    if not d then return nil, err end
    local mp = tonumber(d.local_main_packed) or 0
    local sp = tonumber(d.local_sub_packed) or 0
    local pp = tonumber(d.pres_summary_packed) or 0
    return {
        hook32_calls         = tonumber(d.hook32_calls) or 0,
        hook32_remaps        = tonumber(d.hook32_remaps) or 0,
        deny_disabled        = tonumber(d.deny_disabled) or 0,
        deny_zero_or_shield  = tonumber(d.deny_zero_or_shield) or 0,
        deny_actor_id        = tonumber(d.deny_actor_id) or 0,
        deny_local_equip     = tonumber(d.deny_local_equip) or 0,
        deny_fallback_84     = tonumber(d.deny_fallback_84) or 0,
        deny_auth            = tonumber(d.deny_auth) or 0,
        last_actor_id        = tonumber(d.last_actor_id) or 0,
        last_local_char_id   = tonumber(d.last_local_char_id) or 0,
        last_is_local        = (tonumber(d.last_is_local) or 0) == 1,
        last_look_word       = tonumber(d.last_look_word) or 0,
        last_sub_model_id    = tonumber(d.last_sub_model_id) or 0,
        last_result_slot     = tonumber(d.last_result_slot) or 7,
        last_soul_known      = (tonumber(d.last_soul_known) or 0) == 1,
        last_job             = tonumber(d.last_job) or 0,
        last_branch          = tonumber(d.last_branch) or 0,
        last_effective_level = tonumber(d.last_effective_level) or 0,
        local_main_item_id   = mp % 65536,
        local_main_skill     = math.floor(mp / 65536),
        local_sub_item_id    = sp % 65536,
        local_sub_skill      = math.floor(sp / 65536),
        pres_loaded          = (pp % 2) == 1,
        pres_bindings        = math.floor(pp / 256) % 256,
        pres_profiles        = math.floor(pp / 65536) % 256,
    }, nil
end

function NativeBridge.query_weapon_offhand_diag()
    if not (ok_ffi and ffi and weapon_offhand_diag_t) then
        return nil, 'FFI unavailable'
    end
    local ok_h, handle = pcall(function()
        return ffi.C.GetModuleHandleA('soulspire_native.dll')
    end)
    if not ok_h or handle == nil then
        return nil, 'soulspire_native.dll not loaded'
    end
    local d, err = call_struct_export(handle, 'SoulspireNativeGetWeaponOffhandDiag', weapon_offhand_diag_t)
    if not d then return nil, err end
    return {
        hooks_installed_count   = tonumber(d.hooks_installed_count) or 0,
        hooks_installed_mask    = tonumber(d.hooks_installed_mask) or 0,
        cap_active              = (tonumber(d.cap_active) or 0) == 1,
        attach_calls_slot7      = tonumber(d.attach_calls_slot7) or 0,
        authorized_sub_attaches = tonumber(d.authorized_sub_attaches) or 0,
        add_mesh_calls_total    = tonumber(d.add_mesh_calls_total) or 0,
        registered_sub_meshes   = tonumber(d.registered_sub_meshes) or 0,
        registered_sub_total    = tonumber(d.registered_sub_total) or 0,
        draw_calls_total        = tonumber(d.draw_calls_total) or 0,
        matching_mesh_draws     = tonumber(d.matching_mesh_draws) or 0,
        bone_swaps_succeeded    = tonumber(d.bone_swaps_succeeded) or 0,
        bone_lookups_failed     = tonumber(d.bone_lookups_failed) or 0,
        bone_restores_count     = tonumber(d.bone_restores_count) or 0,
        last_idx_main           = tonumber(d.last_idx_main) or 0,
        last_idx_sub            = tonumber(d.last_idx_sub) or 0,
        last_matrices_distinct  = (tonumber(d.last_matrices_distinct) or 0) == 1,
    }, nil
end

return NativeBridge
