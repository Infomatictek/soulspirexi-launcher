local Labels = {}
Labels.__index = Labels
local ffi = require('ffi')
local soulIdentity = require('soul_identity')
pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char* name);')
pcall(ffi.cdef, 'void* __stdcall LoadLibraryA(const char* path);')
pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void* module, const char* name);')
local status_type = ffi.typeof([=[struct {
    uint32_t size, version, enabled, hooks, character_id, job, known, branch;
    uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
    uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
}[1]]=])
local weapon_rule_array_type = ffi.typeof([=[struct {
    uint32_t size;
    uint8_t  job;
    uint8_t  branch;
    uint8_t  min_effective_level;
    uint8_t  mode;
    uint32_t main_skill_mask;
    uint32_t sub_skill_mask;
    uint16_t main_item_id;
    uint16_t sub_item_id;
    uint32_t reserved;
}[?]]=])
local weapon_rule_size = 24
local weapon_status_type = ffi.typeof([=[struct {
    uint32_t size, version, rule_count, rule_generation, effective_level;
    uint32_t allow_hits, deny_hits, total_hooks, expected_hooks;
}[1]]=])
local hook_diag_type = ffi.typeof([=[struct {
    uint32_t size, version, total_hooks, expected_hooks;
    uint32_t installed_mask, site_set_mask, capabilities;
    uint32_t ffxi_base, ffxi_timestamp, ffxi_image_size;
    uint32_t init_stage, failed_rva, failed_index;
    uint8_t  observed_bytes[8];
}[1]]=])

local bit = require('bit')

Labels.INIT_STAGES = {
    [0] = 'not_run',
    [1] = 'bad_pe',
    [2] = 'sig_mismatch',
    [3] = 'pin_fail',
    [4] = 'patch_install_fail',
    [5] = 'detour_install_fail',
    [6] = 'ok',
    [7] = 'conflict_legacy_dll',
}

-- Matches soulspire_native.cpp hook bit ordering: 0..21 = CALL patches, 22..26 = PrologueDetours (27 hooks total).
Labels.HOOK_SPECS = {
    [0]  = { rva = 0x0D8CCD, name = 'encode_request' },
    [1]  = { rva = 0x0E2282, name = 'decode_row' },
    [2]  = { rva = 0x13C302, name = 'item_label' },
    [3]  = { rva = 0x14868F, name = 'persona_job' },
    [4]  = { rva = 0x1CBD4C, name = 'normal_sprite' },
    [5]  = { rva = 0x1CC086, name = 'master_sprite' },
    [6]  = { rva = 0x1DEE6D, name = 'full_job_1' },
    [7]  = { rva = 0x1DEEFB, name = 'full_job_2' },
    [8]  = { rva = 0x0FA795, name = 'map_decode' },
    [9]  = { rva = 0x0DD5F6, name = 'map_encode' },
    [10] = { rva = 0x22E4F5, name = 'magic_row_name' },
    [11] = { rva = 0x22E245, name = 'magic_desc' },
    [12] = { rva = 0x22DED1, name = 'magic_target' },
    [13] = { rva = 0x22E51B, name = 'magic_icon' },
    [14] = { rva = 0x226129, name = 'ability_row_name' },
    [15] = { rva = 0x225F5D, name = 'ability_desc' },
    [16] = { rva = 0x225916, name = 'ability_target' },
    [17] = { rva = 0x22614E, name = 'ability_icon' },
    [18] = { rva = 0x22DAB9, name = 'magic_list_filter' },
    [19] = { rva = 0x22562F, name = 'ability_list_filter' },
    [20] = { rva = 0x22E64D, name = 'menu_spell_elig' },
    [21] = { rva = 0x133E33, name = 'soul_can_equip_in_slot' },
    [22] = { rva = 0x22CDE0, name = 'can_use_spell_detour' },
    [23] = { rva = 0x22CB44, name = 'missing_spell_bit_detour' },
    [24] = { rva = 0x133D56, name = 'soul_sub_weapon_detour' },
    [25] = { rva = 0x21DF85, name = 'soul_sub_menu_filter_detour' },
    [26] = { rva = 0x133DD3, name = 'soul_sub_2h_main_detour' },
}

-- Cache named function-pointer types once. Re-parsing an anonymous FFI
-- function-pointer signature on every render/sync can exhaust LuaJIT's type
-- table after prolonged idle time ("table overflow").
local signature_types = {
    GetStatus           = ffi.typeof('uint32_t (__stdcall *)(void*, uint32_t)'),
    SetState            = ffi.typeof('uint32_t (__stdcall *)(const uint8_t*, uint32_t)'),
    Initialize          = ffi.typeof('uint32_t (__stdcall *)(void)'),
    ReplaceWeaponRules  = ffi.typeof('uint32_t (__stdcall *)(const void*, uint32_t)'),
    ClearWeaponRules    = ffi.typeof('uint32_t (__stdcall *)(void)'),
    GetWeaponStatus     = ffi.typeof('uint32_t (__stdcall *)(void*, uint32_t)'),
    GetHookDiagnostics  = ffi.typeof('uint32_t (__stdcall *)(void*, uint32_t)'),
}
local exported = {}
local state_bytes_type = ffi.typeof('uint8_t[8]')

local function resolve_native_module()
    local mod = ffi.C.GetModuleHandleA('soulspire_native.dll')
    if mod ~= nil then return mod, 'SoulspireNative' end
    mod = ffi.C.GetModuleHandleA('crystaljobs.dll')
    if mod ~= nil then return mod, 'CrystalJobs' end
    return nil, nil
end

local function loaded_function(short_name)
    local module, prefix = resolve_native_module()
    if module == nil then
        exported = {}
        return nil, 'soulspire_native.dll is not loaded'
    end
    local address = ffi.C.GetProcAddress(module, prefix .. short_name)
    if address == nil and prefix == 'SoulspireNative' then
        address = ffi.C.GetProcAddress(module, 'CrystalJobs' .. short_name)
    end
    if address == nil then
        exported[short_name] = nil
        return nil, 'DLL export unavailable.'
    end
    local entry = exported[short_name]
    if entry and entry.module == module and entry.address == address then
        return entry.fn
    end
    local sig = signature_types[short_name]
    if not sig then return nil, 'Unrecognized DLL export.' end
    local fn = ffi.cast(sig, address)
    exported[short_name] = { module = module, address = address, fn = fn }
    return fn
end

local function loaded_export()
    local set_state, why = loaded_function('SetState')
    if not set_state then return nil, why end
    return function(bytes) return set_state(ffi.new(state_bytes_type, bytes), 8) end
end

local function integer(value, minimum, maximum)
    return type(value) == 'number' and value >= minimum and value <= maximum and value % 1 == 0
end

function Labels.new(resolve, dll_path)
    return setmetatable({
        resolve = resolve or loaded_export,
        custom_resolve = resolve ~= nil,
        dll_path = dll_path,
        known = false,
        branch = 0,
        native = false,
        load_failed = false,
        init_attempted = false,
        init_rc = nil,
        hud_hint = nil,
        hud_packets = 0,
        hud_decoded = 0,
        hud_rejected = 0,
        last_hud_job = nil,
        last_hud_length = nil,
        last_hud_error = nil,
        send_count = 0,
        last_send_result = nil,
        last_status_error = nil,
        status_failures = 0,
        status_successes = 0,
        weapon_rules_synced = false,
        weapon_rules_missing = false,
        weapon_rules_module = nil,
        weapon_rules_count = 0,
        weapon_rules_error = nil,
    }, Labels)
end

function Labels:set_dll_path(path)
    if type(path) == 'string' and path ~= '' then
        self.dll_path = path
        self.load_failed = false
    end
end

function Labels:ensure_loaded()
    if self.custom_resolve then return true end
    local ok, ready = pcall(function()
        local module = resolve_native_module()
        if module == nil and self.dll_path and not self.load_failed then
            module = ffi.C.LoadLibraryA(self.dll_path)
            if module == nil then
                self.load_failed = true
                self.error = 'DLL LoadLibraryA failed.'
                return false
            end
        end
        if module == nil then return false end

        local get_status = loaded_function('GetStatus')
        if get_status then
            local st = ffi.new(status_type)
            if get_status(st, ffi.sizeof(st)) == 0 and st[0].size == 68 and st[0].version == 1 then
                if st[0].enabled == 1 and st[0].hooks >= 9 then
                    return true
                end
                if not self.init_attempted and st[0].last_error ~= 1 and st[0].last_error ~= 3 then
                    self.init_attempted = true
                    local init_fn = loaded_function('Initialize')
                    if init_fn then
                        self.init_rc = tonumber(init_fn())
                        if self.init_rc ~= 0 then
                            self.error = ('SoulspireNativeInitialize returned %s.'):format(tostring(self.init_rc))
                        end
                    end
                end
            end
        end
        return true
    end)
    return ok and ready == true
end

function Labels:native_decoder_ready()
    local ok, ready = pcall(function()
        self:ensure_loaded()
        local get_status = loaded_function('GetStatus')
        if not get_status then return false end
        local status = ffi.new(status_type)
        return get_status(status, ffi.sizeof(status)) == 0 and status[0].size == 68
            and status[0].version == 1 and status[0].enabled == 1 and status[0].hooks >= 9
    end)
    return ok and ready
end

function Labels:status()
    local loadOk, loadResult = pcall(self.ensure_loaded, self)
    if not loadOk then
        self.last_status_error = 'load exception: ' .. tostring(loadResult)
        self.status_failures = self.status_failures + 1
        return nil
    end
    local ok, info, failure = pcall(function()
        local module = resolve_native_module()
        if module == nil then return nil, 'soulspire_native.dll is not loaded' end
        local get_status = loaded_function('GetStatus')
        if not get_status then return nil, 'SoulspireNativeGetStatus export missing' end
        local st = ffi.new(status_type)
        local rc = get_status(st, ffi.sizeof(st))
        if rc ~= 0 then return nil, 'SoulspireNativeGetStatus returned ' .. tostring(rc) end
        if st[0].size ~= 68 or st[0].version ~= 1 then
            return nil, ('DLL ABI mismatch: size=%d version=%d'):format(
                tonumber(st[0].size), tonumber(st[0].version))
        end
        return {
            enabled = tonumber(st[0].enabled),
            hooks = tonumber(st[0].hooks),
            character_id = tonumber(st[0].character_id),
            job = tonumber(st[0].job),
            known = tonumber(st[0].known),
            branch = tonumber(st[0].branch),
            search_rows = tonumber(st[0].search_rows),
            decoded_rows = tonumber(st[0].decoded_rows),
            item_labels = tonumber(st[0].item_labels),
            search_labels = tonumber(st[0].search_labels),
            full_labels = tonumber(st[0].full_labels),
            queries_sent = tonumber(st[0].queries_sent),
            replies_accepted = tonumber(st[0].replies_accepted),
            replies_rejected = tonumber(st[0].replies_rejected),
            last_error = tonumber(st[0].last_error),
        }
    end)
    if not ok or not info then
        self.last_status_error = ok and failure or ('DLL status exception: ' .. tostring(info))
        self.status_failures = self.status_failures + 1
        return nil
    end
    self.last_status_error = nil
    self.status_successes = self.status_successes + 1
    return info
end

function Labels:sync_weapon_rules(rules, override_replace, opts)
    if type(rules) ~= 'table' then return false, 'invalid rules table' end
    if #rules == 0 and not (type(opts) == 'table' and opts.allow_empty == true) then
        self.weapon_rules_error = 'refusing empty weapon rules sync to preserve native-loaded rules'
        return false, self.weapon_rules_error
    end
    if override_replace then
        local count = #rules
        local buf = count > 0 and ffi.new(weapon_rule_array_type, count) or nil
        for i = 1, count do
            local r = rules[i]
            local dst = buf[i - 1]
            dst.size = weapon_rule_size
            dst.job = r.job or 0
            dst.branch = r.branch or 0
            dst.min_effective_level = r.min_effective_level or 10
            dst.mode = r.mode or 0
            dst.main_skill_mask = r.main_skill_mask or 0
            dst.sub_skill_mask = r.sub_skill_mask or 0
            dst.main_item_id = r.main_item_id or 0
            dst.sub_item_id = r.sub_item_id or 0
            dst.reserved = 0
        end
        local rc = override_replace(buf, count)
        self.weapon_rules_synced = (rc == 0)
        if self.weapon_rules_synced then
            self.weapon_rules_count = count
            self.weapon_rules_error = nil
        else
            self.weapon_rules_count = 0
            self.weapon_rules_error = 'replace returned ' .. tostring(rc)
        end
        return self.weapon_rules_synced, self.weapon_rules_error
    end

    local ok, synced, err = pcall(function()
        self:ensure_loaded()
        local module = resolve_native_module()
        if module == nil then
            self.weapon_rules_synced = false
            self.weapon_rules_module = nil
            return false, 'soulspire_native.dll is not loaded'
        end
        if self.weapon_rules_synced and self.weapon_rules_module == module then
            return true, nil
        end
        if self.weapon_rules_missing and self.weapon_rules_module == module then
            return false, self.weapon_rules_error
        end
        local replace_fn, why = loaded_function('ReplaceWeaponRules')
        if not replace_fn then
            self.weapon_rules_synced = false
            self.weapon_rules_missing = true
            self.weapon_rules_module = module
            return false, why or 'SoulspireNativeReplaceWeaponRules export missing'
        end
        self.weapon_rules_missing = false
        local count = #rules
        local buf = count > 0 and ffi.new(weapon_rule_array_type, count) or nil
        for i = 1, count do
            local r = rules[i]
            local dst = buf[i - 1]
            dst.size = weapon_rule_size
            dst.job = r.job or 0
            dst.branch = r.branch or 0
            dst.min_effective_level = r.min_effective_level or 10
            dst.mode = r.mode or 0
            dst.main_skill_mask = r.main_skill_mask or 0
            dst.sub_skill_mask = r.sub_skill_mask or 0
            dst.main_item_id = r.main_item_id or 0
            dst.sub_item_id = r.sub_item_id or 0
            dst.reserved = 0
        end
        local rc = tonumber(replace_fn(buf, count))
        if rc ~= 0 then
            self.weapon_rules_synced = false
            return false, 'SoulspireNativeReplaceWeaponRules returned ' .. tostring(rc)
        end
        self.weapon_rules_synced = true
        self.weapon_rules_module = module
        self.weapon_rules_count = count
        return true, nil
    end)
    if not ok then
        self.weapon_rules_synced = false
        self.weapon_rules_error = 'weapon rules sync exception: ' .. tostring(synced)
        return false, self.weapon_rules_error
    end
    self.weapon_rules_error = err
    return synced, err
end

function Labels:weapon_status()
    local ok, info = pcall(function()
        self:ensure_loaded()
        local get_status = loaded_function('GetWeaponStatus')
        if not get_status then return nil end
        local st = ffi.new(weapon_status_type)
        if get_status(st, ffi.sizeof(st)) ~= 0 or st[0].size ~= 36 or st[0].version ~= 1 then
            return nil
        end
        return {
            rule_count = tonumber(st[0].rule_count),
            rule_generation = tonumber(st[0].rule_generation),
            effective_level = tonumber(st[0].effective_level),
            allow_hits = tonumber(st[0].allow_hits),
            deny_hits = tonumber(st[0].deny_hits),
            total_hooks = tonumber(st[0].total_hooks),
            expected_hooks = tonumber(st[0].expected_hooks),
        }
    end)
    return ok and info or nil
end

function Labels.format_hook_diagnostics(diag)
    if type(diag) ~= 'table' then return {} end
    local stage = Labels.INIT_STAGES[diag.init_stage] or tostring(diag.init_stage)
    local expected = diag.expected_hooks or 27
    local sub_bit = (expected >= 27) and 24 or 23
    local sub_ok = bit.band(diag.installed_mask or 0, bit.lshift(1, sub_bit)) ~= 0
    local lines = {
        ('hooks_diag stage=%s installed=%d/%d mask=0x%07X site_mask=0x%07X caps=0x%04X sub_weapon_hook=%s'):format(
            stage, diag.total_hooks or 0, expected,
            diag.installed_mask or 0, diag.site_set_mask or 0, diag.capabilities or 0,
            sub_ok and 'OK' or 'MISSING'),
        ('ffxi base=0x%08X ts=0x%08X size=0x%X'):format(
            diag.ffxi_base or 0, diag.ffxi_timestamp or 0, diag.ffxi_image_size or 0),
    }
    local missing = {}
    for i = 0, expected - 1 do
        local m = bit.lshift(1, i)
        if bit.band(diag.installed_mask or 0, m) == 0 then
            local spec = Labels.HOOK_SPECS[i]
            local state = bit.band(diag.site_set_mask or 0, m) ~= 0 and 'overwritten' or 'not_installed'
            if spec then
                missing[#missing + 1] = ('#%d(0x%X %s:%s)'):format(i + 1, spec.rva, spec.name, state)
            else
                missing[#missing + 1] = ('#%d(%s)'):format(i + 1, state)
            end
        end
    end
    if #missing > 0 then
        lines[#lines + 1] = 'missing_hooks=[' .. table.concat(missing, ', ') .. ']'
    else
        lines[#lines + 1] = 'missing_hooks=[none]'
    end
    if (diag.failed_rva or 0) ~= 0 or (diag.init_stage or 0) ~= 6 then
        lines[#lines + 1] = ('failed_detail index=%s rva=0x%X observed=%s'):format(
            diag.failed_index == 0xFFFFFFFF and 'none' or tostring(diag.failed_index),
            diag.failed_rva or 0, tostring(diag.observed_hex or ''))
    end
    return lines
end

function Labels:hook_diagnostics(override_get_diag)
    local ok, info = pcall(function()
        local get_diag = override_get_diag
        if not get_diag then
            self:ensure_loaded()
            get_diag = loaded_function('GetHookDiagnostics')
        end
        if not get_diag then return nil end
        local d = ffi.new(hook_diag_type)
        if get_diag(d, ffi.sizeof(d)) ~= 0 or d[0].size ~= 60 or (d[0].version ~= 1 and d[0].version ~= 2) then
            return nil
        end
        local hex = {}
        for i = 0, 7 do
            hex[#hex + 1] = ('%02X'):format(tonumber(d[0].observed_bytes[i]))
        end
        return {
            total_hooks = tonumber(d[0].total_hooks),
            expected_hooks = tonumber(d[0].expected_hooks),
            installed_mask = tonumber(d[0].installed_mask),
            site_set_mask = tonumber(d[0].site_set_mask),
            capabilities = tonumber(d[0].capabilities),
            ffxi_base = tonumber(d[0].ffxi_base),
            ffxi_timestamp = tonumber(d[0].ffxi_timestamp),
            ffxi_image_size = tonumber(d[0].ffxi_image_size),
            init_stage = tonumber(d[0].init_stage),
            failed_rva = tonumber(d[0].failed_rva),
            failed_index = tonumber(d[0].failed_index),
            observed_hex = table.concat(hex, ' '),
        }
    end)
    return ok and info or nil
end

function Labels:clear_hud_hint()
    self.hud_hint = nil
end

-- A valid, job-matched HUD identity is an alternative client presentation source.
-- Never use it for gameplay or action permissions.
function Labels:observe_hud(data, job, character_id)
    self.hud_packets = self.hud_packets + 1
    self.last_hud_job = job
    self.last_hud_length = type(data) == 'string' and #data or -1
    if not integer(job, 1, 22) or not integer(character_id, 1, 4294967295) then
        self.hud_rejected = self.hud_rejected + 1
        self.last_hud_error = 'invalid player context'
        return false
    end
    local decoded = soulIdentity.decode(data, job)
    if not decoded then
        self.hud_rejected = self.hud_rejected + 1
        self.last_hud_error = 'invalid or mismatched HUD identity'
        return false
    end
    self.hud_decoded = self.hud_decoded + 1
    self.last_hud_error = nil
    self.hud_hint = { job = job, character_id = character_id, branch = decoded.branch }
    return true
end

function Labels:sync(snapshot, character_id, now)
    self:ensure_loaded()
    local id = snapshot.session_key and integer(character_id, 1, 4294967295) and character_id or 0
    local job = integer(snapshot.current_job, 0, 23) and snapshot.current_job or 0
    if id == 0 then self:clear_hud_hint() end
    local verified = id ~= 0 and job >= 1 and job <= 23
        and snapshot.loaded == true and integer(snapshot.active, 0, 7)
    local fallback = not verified and self.hud_hint
        and self.hud_hint.job == job and self.hud_hint.character_id == id
    self.known = verified or fallback or false
    self.branch = verified and snapshot.active or (fallback and self.hud_hint.branch or 0)
    self.source = verified and 'crystal catalog' or (fallback and 'Soul HUD packet' or 'none')
    local bytes = { 1, self.known and 1 or 0, job, self.branch,
        id % 256, math.floor(id / 256) % 256, math.floor(id / 65536) % 256, math.floor(id / 16777216) }
    local key = string.char(unpack(bytes))
    local ok, set_state, why = pcall(self.resolve)
    self.native = ok and set_state ~= nil
    if not self.native then
        self.key = nil
        self.error = not ok and 'DLL lookup unavailable.' or why
        return
    end
    -- Resolve loaded exports each time; never retain a pointer across DLL unload/reload.
    if self.key == key and self.last_send and now - self.last_send < 1 then return end
    self.key, self.last_send = key, now
    local sent, result = pcall(set_state, bytes)
    self.send_count = self.send_count + 1
    self.last_send_result = sent and result or tostring(result)
    self.error = not sent and 'DLL call unavailable.' or result ~= 0 and 'DLL state rejected.' or nil
end

return Labels
