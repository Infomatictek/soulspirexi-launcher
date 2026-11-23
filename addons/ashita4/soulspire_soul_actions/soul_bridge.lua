-- Client-only active Soul bridge via the existing crystaljobs.dll status export.
-- Does not send packets, alter the server, or inspect arbitrary client memory.
local M = {}
local okReg, soulRegistry = pcall(require, 'soul_registry_generated')
if not okReg or type(soulRegistry) ~= 'table' then soulRegistry = nil end
local names = {
    [1]={'commander','berserker','spartan'},
    [2]={'sensei','chiweaver','blackbelt'},
    [3]={'bishop','zealot','valkyrie'},
    [4]={'astromancer','channeler','necromancer'},
    [5]={'crimsonduelist','royaltactician','scarletweaver'},
    [6]={'trickster','bandit','phantom'},
    [7]={'templar','defender','oathbreaker'},
    [8]={'reaper','dreadnought','scourge'},
    [9]={'untamed','soulbeast','beastspeaker'},
    [10]={'adventurer','musician','minstrel'},
    [11]={'sniper','huntsman','arcanearcher'},
    [12]={'ronin','imperialarcher','warlord'},
    [13]={'shinobi','kagemusha','nightblade'},
    [14]={'lancer','skyborn','wyvernheart'},
    [15]={'primalist','celestial','herald'},
    [16]={'warmage','magus','azurebastion'},
    [17]={'flintlock','gambler','buccaneer'},
    [18]={'vanguard','pugilist','animist'},
    [19]={'miragesentinel','vampire','bladewheel'},
    [20]={'medic','sage','archivist'},
    [21]={'diviner','verdant','terramancer'},
    [22]={'spellblade','lifebinder','inquisitor'},
}
function M.resolve(status, job, character)
    if type(status) ~= 'table' or type(job) ~= 'number' or type(character) ~= 'number'
        or character <= 0 or job <= 0 or job > 22 then return nil end
    if status.enabled ~= 1 or status.known ~= 1 or status.job ~= job
        or status.character_id ~= character then return nil end
    local branch = status.branch
    return names[job] and names[job][branch] or nil
end
function M.displayName(soulKey)
    if type(soulKey) ~= 'string' or soulKey == '' then return nil end
    if soulRegistry and soulRegistry.displayName then
        return soulRegistry.displayName(soulKey, soulKey)
    end
    return soulKey
end
local okFfi, ffi = pcall(require, 'ffi')
local status_t
local get_status_type, cached_module, cached_address, cached_function
if okFfi and ffi then
    pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char*);')
    pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void*, const char*);')
    local ok, tp = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, enabled, hooks, character_id, job, known, branch;
        uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
        uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
    }[1]]=])
    if ok then status_t = tp end
    local okFn, fnType = pcall(ffi.typeof, 'uint32_t (__stdcall *)(void*, uint32_t)')
    if okFn then get_status_type = fnType end
end
function M.read()
    if not (ffi and status_t and get_status_type) then return nil end
    local ok, status = pcall(function()
        local handle = ffi.C.GetModuleHandleA('soulspire_native.dll')
        local exportName = 'SoulspireNativeGetStatus'
        if handle == nil then
            handle = ffi.C.GetModuleHandleA('crystaljobs.dll')
            exportName = 'CrystalJobsGetStatus'
        end
        if handle == nil then cached_module, cached_address, cached_function = nil, nil, nil; return nil end
        local addr = ffi.C.GetProcAddress(handle, exportName)
        if addr == nil and exportName == 'SoulspireNativeGetStatus' then
            addr = ffi.C.GetProcAddress(handle, 'CrystalJobsGetStatus')
        end
        if addr == nil then return nil end
        if cached_module ~= handle or cached_address ~= addr then
            cached_module, cached_address = handle, addr
            cached_function = ffi.cast(get_status_type, addr)
        end
        local fn = cached_function
        local buf = ffi.new(status_t)
        if fn(buf, ffi.sizeof(buf)) ~= 0 or buf[0].size ~= 68 or buf[0].version ~= 1 then return nil end
        return {enabled=tonumber(buf[0].enabled),known=tonumber(buf[0].known),
            job=tonumber(buf[0].job),branch=tonumber(buf[0].branch),
            character_id=tonumber(buf[0].character_id)}
    end)
    return ok and status or nil
end
return M
