-- Cached LuaJIT FFI bridge for crystaljobs.dll's generic native Soul Action API.
-- All FFI types and function pointers are cached once; never allocates new ctypes per frame.
local M = {}

local KIND_ID = {
    spell = 1,
    ability = 2,
    weaponskill = 3,
}

-- Canonical Soul key -> { job, branch } lookup for all 66 SoulspireXI Souls.
local SOUL_TO_PAIR = {
    commander = {1, 1}, berserker = {1, 2}, spartan = {1, 3},
    sensei = {2, 1}, chiweaver = {2, 2}, blackbelt = {2, 3},
    bishop = {3, 1}, zealot = {3, 2}, valkyrie = {3, 3},
    astromancer = {4, 1}, channeler = {4, 2}, necromancer = {4, 3},
    crimsonduelist = {5, 1}, royaltactician = {5, 2}, scarletweaver = {5, 3},
    trickster = {6, 1}, bandit = {6, 2}, phantom = {6, 3},
    templar = {7, 1}, defender = {7, 2}, oathbreaker = {7, 3},
    reaper = {8, 1}, dreadnought = {8, 2}, scourge = {8, 3},
    untamed = {9, 1}, soulbeast = {9, 2}, beastspeaker = {9, 3},
    adventurer = {10, 1}, musician = {10, 2}, minstrel = {10, 3},
    sniper = {11, 1}, huntsman = {11, 2}, arcanearcher = {11, 3},
    ronin = {12, 1}, imperialarcher = {12, 2}, warlord = {12, 3},
    shinobi = {13, 1}, kagemusha = {13, 2}, nightblade = {13, 3},
    lancer = {14, 1}, skyborn = {14, 2}, wyvernheart = {14, 3},
    primalist = {15, 1}, celestial = {15, 2}, herald = {15, 3},
    warmage = {16, 1}, magus = {16, 2}, azurebastion = {16, 3},
    flintlock = {17, 1}, gambler = {17, 2}, buccaneer = {17, 3},
    vanguard = {18, 1}, pugilist = {18, 2}, animist = {18, 3},
    miragesentinel = {19, 1}, vampire = {19, 2}, bladewheel = {19, 3},
    medic = {20, 1}, sage = {20, 2}, archivist = {20, 3},
    diviner = {21, 1}, verdant = {21, 2}, terramancer = {21, 3},
    spellblade = {22, 1}, lifebinder = {22, 2}, inquisitor = {22, 3},
}

M.CAPABILITIES = {
    { bit = 1,   name = 'Equipment Soul name' },
    { bit = 2,   name = 'Search Soul labels' },
    { bit = 4,   name = 'Magic/Ninjutsu menu names' },
    { bit = 8,   name = 'Magic/Ninjutsu menu descriptions' },
    { bit = 16,  name = 'Magic/Ninjutsu target banner' },
    { bit = 32,  name = 'Magic/Ninjutsu menu icons' },
    { bit = 64,  name = 'Ability/WS menu names' },
    { bit = 128, name = 'Ability/WS menu descriptions' },
    { bit = 256,  name = 'Ability/WS target banner' },
    { bit = 512,  name = 'Ability/WS menu icons' },
    { bit = 1024, name = 'Magic/Ninjutsu menu visibility filter' },
    { bit = 2048, name = 'Ability/WS menu visibility filter' },
    { bit = 4096,  name = 'Soul cast lookup' },
    { bit = 8192,  name = 'Soul Sub weapon' },
    { bit = 16384, name = 'Soul Sub 2H' },
    { bit = 32768, name = 'DAT virtualization' },
}

function M.soulToPair(soulKey)
    if type(soulKey) ~= 'string' then return nil end
    local pair = SOUL_TO_PAIR[soulKey:lower()]
    if not pair then return nil end
    return pair[1], pair[2]
end

local okFfi, ffi = pcall(require, 'ffi')
local entry_arr_t, action_status_t, vis_entry_arr_t, vis_status_t
local fn_types = {}
local cache = { module = nil, fns = {} }

if okFfi and ffi then
    pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char*);')
    pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void*, const char*);')
    local ok1, t1 = pcall(ffi.typeof, [=[struct {
        uint32_t size;
        uint8_t  job;
        uint8_t  branch;
        uint16_t action_id;
        uint32_t kind;
        uint16_t icon_id;
        uint16_t icon_id_v2;
        char     name[80];
        char     description[192];
    }[?]]=])
    if ok1 then entry_arr_t = t1 end
    local ok2, t2 = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, capabilities, catalog_count, catalog_generation;
        uint32_t active_job, active_branch, active_source;
        uint32_t magic_name_hits, magic_desc_hits, magic_icon_hits;
        uint32_t ability_name_hits, ability_desc_hits, ability_icon_hits;
        uint32_t total_hooks, expected_hooks;
    }[1]]=])
    if ok2 then action_status_t = t2 end
    local ok3, t3 = pcall(ffi.typeof, [=[struct {
        uint32_t size;
        uint8_t  job;
        uint8_t  branch;
        uint8_t  min_effective_level;
        uint8_t  rule;
        uint32_t kind;
        uint16_t action_id;
        uint16_t reserved;
    }[?]]=])
    if ok3 then vis_entry_arr_t = t3 end
    local ok4, t4 = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, policy_count, policy_generation, effective_level;
        uint32_t magic_hidden_count, magic_shown_count, ability_hidden_count;
        uint32_t total_hooks, expected_hooks;
    }[1]]=])
    if ok4 then vis_status_t = t4 end

    local sigs = {
        ReplaceCatalog      = 'uint32_t (__stdcall *)(const void*, uint32_t)',
        ClearCatalog        = 'uint32_t (__stdcall *)(void)',
        SetActiveSoul       = 'uint32_t (__stdcall *)(uint32_t, uint32_t, uint32_t)',
        ClearActiveSoul     = 'uint32_t (__stdcall *)(void)',
        GetActionStatus     = 'uint32_t (__stdcall *)(void*, uint32_t)',
        SetActionRowLimit   = 'uint32_t (__stdcall *)(uint32_t)',
        ReplaceVisibility   = 'uint32_t (__stdcall *)(const void*, uint32_t)',
        ClearVisibility     = 'uint32_t (__stdcall *)(void)',
        GetVisibilityStatus = 'uint32_t (__stdcall *)(void*, uint32_t)',
    }
    for name, sig in pairs(sigs) do
        local okT, tp = pcall(ffi.typeof, sig)
        if okT then fn_types[name] = tp end
    end
end

local function resolveFn(shortName)
    if not (ffi and fn_types[shortName]) then return nil end
    local handle = ffi.C.GetModuleHandleA('soulspire_native.dll')
    local prefix = 'SoulspireNative'
    if handle == nil then
        handle = ffi.C.GetModuleHandleA('crystaljobs.dll')
        prefix = 'CrystalJobs'
    end
    if handle == nil then
        cache.module = nil
        cache.fns = {}
        return nil
    end
    if cache.module ~= handle then
        cache.module = handle
        cache.fns = {}
    end
    if cache.fns[shortName] then return cache.fns[shortName] end
    local addr = ffi.C.GetProcAddress(handle, prefix .. shortName)
    if addr == nil and prefix == 'SoulspireNative' then
        addr = ffi.C.GetProcAddress(handle, 'CrystalJobs' .. shortName)
    end
    if addr == nil then return nil end
    local fn = ffi.cast(fn_types[shortName], addr)
    cache.fns[shortName] = fn
    return fn
end

function M.syncCatalog(catalog)
    if not (ffi and entry_arr_t and catalog and type(catalog.souls) == 'table') then
        return false, 'FFI or catalog unavailable'
    end
    local replaceFn = resolveFn('ReplaceCatalog')
    if not replaceFn then return false, 'soulspire_native.dll Action API unavailable' end

    local flat = {}
    for soulKey, kinds in pairs(catalog.souls) do
        local job, branch = M.soulToPair(soulKey)
        if job and branch and type(kinds) == 'table' then
            for kindName, entries in pairs(kinds) do
                local kindId = KIND_ID[kindName]
                if kindId and type(entries) == 'table' then
                    for id, info in pairs(entries) do
                        if type(id) == 'number' and type(info) == 'table' then
                            flat[#flat + 1] = {
                                job = job,
                                branch = branch,
                                kind = kindId,
                                id = id,
                                iconId = tonumber(info.iconId) or 65535,
                                iconIdV2 = tonumber(info.iconIdV2) or 65535,
                                name = tostring(info.name or ''),
                                description = tostring(info.description or ''),
                            }
                        end
                    end
                end
            end
        end
    end

    local count = #flat
    if count == 0 then
        local clearFn = resolveFn('ClearCatalog')
        if clearFn then clearFn() end
        return true, 0
    end

    local ok, rc = pcall(function()
        local arr = ffi.new(entry_arr_t, count)
        for i = 1, count do
            local src = flat[i]
            local dst = arr[i - 1]
            dst.size = 288
            dst.job = src.job
            dst.branch = src.branch
            dst.action_id = src.id
            dst.kind = src.kind
            dst.icon_id = src.iconId
            dst.icon_id_v2 = src.iconIdV2
            local n = src.name:sub(1, 79)
            local d = src.description:sub(1, 191)
            ffi.copy(dst.name, n, #n)
            ffi.copy(dst.description, d, #d)
        end
        return tonumber(replaceFn(arr, count))
    end)
    if not ok or rc ~= 0 then
        return false, 'SoulspireNativeReplaceCatalog failed: ' .. tostring(rc)
    end
    return true, count
end

function M.setActiveSoul(soulKey, characterId)
    local job, branch = M.soulToPair(soulKey)
    if not (job and branch) then return M.clearActiveSoul() end
    local fn = resolveFn('SetActiveSoul')
    if not fn then return false end
    local ok, rc = pcall(fn, job, branch, tonumber(characterId) or 0)
    return ok and tonumber(rc) == 0
end

function M.clearActiveSoul()
    local fn = resolveFn('ClearActiveSoul')
    if not fn then return false end
    local ok, rc = pcall(fn)
    return ok and tonumber(rc) == 0
end

function M.setActionRowLimit(limit)
    local n = tonumber(limit)
    if not n or n % 1 ~= 0 or n < 8 or n > 48 then return false end
    local fn = resolveFn('SetActionRowLimit')
    if not fn then return false end
    local ok, rc = pcall(fn, n)
    return ok and tonumber(rc) == 0
end

function M.readStatus()
    if not (ffi and action_status_t) then return nil end
    local fn = resolveFn('GetActionStatus')
    if not fn then return nil end
    local ok, res = pcall(function()
        local buf = ffi.new(action_status_t)
        if fn(buf, ffi.sizeof(buf)) ~= 0 or buf[0].size ~= 64 or buf[0].version ~= 1 then return nil end
        return {
            capabilities = tonumber(buf[0].capabilities),
            catalog_count = tonumber(buf[0].catalog_count),
            catalog_generation = tonumber(buf[0].catalog_generation),
            active_job = tonumber(buf[0].active_job),
            active_branch = tonumber(buf[0].active_branch),
            active_source = tonumber(buf[0].active_source),
            magic_name_hits = tonumber(buf[0].magic_name_hits),
            magic_desc_hits = tonumber(buf[0].magic_desc_hits),
            magic_icon_hits = tonumber(buf[0].magic_icon_hits),
            ability_name_hits = tonumber(buf[0].ability_name_hits),
            ability_desc_hits = tonumber(buf[0].ability_desc_hits),
            ability_icon_hits = tonumber(buf[0].ability_icon_hits),
            total_hooks = tonumber(buf[0].total_hooks),
            expected_hooks = tonumber(buf[0].expected_hooks),
        }
    end)
    return ok and res or nil
end

function M.syncVisibility(policy)
    if not (ffi and vis_entry_arr_t) then
        return false, 'FFI visibility types unavailable'
    end
    local replaceFn = resolveFn('ReplaceVisibility')
    if not replaceFn then return false, 'soulspire_native.dll Visibility API unavailable' end
    if type(policy) ~= 'table' or type(policy.souls) ~= 'table' then
        local clearFn = resolveFn('ClearVisibility')
        if clearFn then clearFn() end
        return true, 0
    end

    local flat = {}
    for soulKey, kinds in pairs(policy.souls) do
        local job, branch = M.soulToPair(soulKey)
        if job and branch and type(kinds) == 'table' then
            for kindName, entries in pairs(kinds) do
                local kindId = KIND_ID[kindName]
                if kindId and type(entries) == 'table' then
                    for id, info in pairs(entries) do
                        if type(id) == 'number' and type(info) == 'table' then
                            local ruleId = (info.rule == 'hidden') and 2 or 1
                            flat[#flat + 1] = {
                                job = job,
                                branch = branch,
                                kind = kindId,
                                id = id,
                                minLevel = tonumber(info.minLevel) or 1,
                                rule = ruleId,
                            }
                        end
                    end
                end
            end
        end
    end

    local count = #flat
    if count == 0 then
        local clearFn = resolveFn('ClearVisibility')
        if clearFn then clearFn() end
        return true, 0
    end

    local ok, rc = pcall(function()
        local arr = ffi.new(vis_entry_arr_t, count)
        for i = 1, count do
            local src = flat[i]
            local dst = arr[i - 1]
            dst.size = 16
            dst.job = src.job
            dst.branch = src.branch
            dst.min_effective_level = src.minLevel
            dst.rule = src.rule
            dst.kind = src.kind
            dst.action_id = src.id
            dst.reserved = 0
        end
        return tonumber(replaceFn(arr, count))
    end)
    if not ok or rc ~= 0 then
        return false, 'SoulspireNativeReplaceVisibility failed: ' .. tostring(rc)
    end
    return true, count
end

function M.clearVisibility()
    local fn = resolveFn('ClearVisibility')
    if not fn then return false end
    local ok, rc = pcall(fn)
    return ok and tonumber(rc) == 0
end

function M.readVisibilityStatus()
    if not (ffi and vis_status_t) then return nil end
    local fn = resolveFn('GetVisibilityStatus')
    if not fn then return nil end
    local ok, res = pcall(function()
        local buf = ffi.new(vis_status_t)
        if fn(buf, ffi.sizeof(buf)) ~= 0 or buf[0].size ~= 40 or buf[0].version ~= 1 then return nil end
        return {
            policy_count = tonumber(buf[0].policy_count),
            policy_generation = tonumber(buf[0].policy_generation),
            effective_level = tonumber(buf[0].effective_level),
            magic_hidden_count = tonumber(buf[0].magic_hidden_count),
            magic_shown_count = tonumber(buf[0].magic_shown_count),
            ability_hidden_count = tonumber(buf[0].ability_hidden_count),
            total_hooks = tonumber(buf[0].total_hooks),
            expected_hooks = tonumber(buf[0].expected_hooks),
        }
    end)
    return ok and res or nil
end

return M
