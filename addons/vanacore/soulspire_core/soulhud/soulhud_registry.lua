local M = {}

M.VALID_TYPES = {
    stack    = true,
    gauge    = true,
    charges  = true,
    cooldown = true,
    timer    = true,
    toggle   = true,
    combo    = true,
    counter  = true,
    status   = true,
}

local soulsByKey = {}
local soulsByJobBranch = {}

local function makeJobBranchKey(jobId, branchId)
    return tostring(jobId or 0) .. ':' .. tostring(branchId or 0)
end

function M.registerSoul(def)
    if type(def) ~= 'table' or type(def.key) ~= 'string' or def.key == '' then
        return false, 'Invalid soul definition: missing key.'
    end

    local soul = {
        key         = def.key,
        name        = def.name or def.key,
        jobId       = tonumber(def.jobId) or 0,
        jobAbr      = def.jobAbr or '',
        branchId    = tonumber(def.branchId) or 0,
        accentColor = def.accentColor,
        resources   = {},
        byId        = {},
    }

    soulsByKey[soul.key] = soul
    if soul.jobId > 0 and soul.branchId > 0 then
        soulsByJobBranch[makeJobBranchKey(soul.jobId, soul.branchId)] = soul
    end

    if type(def.resources) == 'table' then
        for _, resDef in ipairs(def.resources) do
            M.registerResource(soul.key, resDef)
        end
    end

    return true
end

function M.registerResource(soulKey, resDef)
    local soul = soulsByKey[soulKey]
    if not soul or type(resDef) ~= 'table' or type(resDef.id) ~= 'string' or resDef.id == '' then
        return false
    end

    local rtype = M.VALID_TYPES[resDef.type] and resDef.type or 'status'
    local entry = {
        id            = resDef.id,
        label         = resDef.label or resDef.id,
        shortLabel    = resDef.shortLabel or resDef.label or resDef.id,
        type          = rtype,
        style         = resDef.style,
        min           = tonumber(resDef.min) or 0,
        max           = tonumber(resDef.max) or 1,
        duration      = tonumber(resDef.duration) or 0,
        recastId      = resDef.recastId ~= nil and tonumber(resDef.recastId) or nil,
        maxCharges    = tonumber(resDef.maxCharges) or 1,
        chargeTime    = tonumber(resDef.chargeTime) or 0,
        serverKey     = resDef.serverKey,
        timerKey      = resDef.timerKey,
        activeKey     = resDef.activeKey,
        subKey        = resDef.subKey,
        builder       = resDef.builder,
        spender       = resDef.spender,
        warnThreshold = tonumber(resDef.warnThreshold),
        warnMode      = resDef.warnMode, -- 'low' | 'high' | 'active'
        warnWhen      = resDef.warnWhen,
        visibleWhen   = resDef.visibleWhen,
        format        = resDef.format,
        color         = resDef.color,
        warnColor     = resDef.warnColor,
        compact       = resDef.compact ~= false,
        mapValue      = resDef.mapValue,
    }

    if soul.byId[entry.id] then
        for i, existing in ipairs(soul.resources) do
            if existing.id == entry.id then
                soul.resources[i] = entry
                break
            end
        end
    else
        soul.resources[#soul.resources + 1] = entry
    end
    soul.byId[entry.id] = entry
    return true
end

function M.getSoul(key)
    return soulsByKey[key]
end

function M.getSoulByJobBranch(jobId, branchId)
    return soulsByJobBranch[makeJobBranchKey(jobId, branchId)]
end

function M.listSouls()
    local out = {}
    for _, s in pairs(soulsByKey) do
        out[#out + 1] = s
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

function M.newRuntimeState(soulDef)
    local rt = {
        soulKey = soulDef and soulDef.key or '',
        values  = {},
    }
    if soulDef and soulDef.resources then
        for _, res in ipairs(soulDef.resources) do
            rt.values[res.id] = {
                current     = res.min or 0,
                max         = res.max or 1,
                active      = false,
                ready       = res.type == 'cooldown' or res.type == 'charges',
                remaining   = 0,
                expiresAt   = 0,
                duration    = res.duration or 0,
                charges     = res.maxCharges or 1,
                maxCharges  = res.maxCharges or 1,
                subValue    = 0,
                text        = '',
            }
        end
    end
    return rt
end

function M.updateResource(rt, id, patch)
    if not rt or not rt.values or not id or type(patch) ~= 'table' then
        return
    end
    local st = rt.values[id]
    if not st then
        st = {}
        rt.values[id] = st
    end
    for k, v in pairs(patch) do
        st[k] = v
    end
end

function M.resetState(soulDef, rt)
    if not rt then return end
    local fresh = M.newRuntimeState(soulDef)
    rt.values = fresh.values
end

function M.cleanupState(rt)
    if rt then
        rt.values = {}
    end
end

function M.applyServerData(soulDef, rt, kvMap, now)
    if not soulDef or not rt or type(kvMap) ~= 'table' then
        return
    end
    for _, res in ipairs(soulDef.resources) do
        local st = rt.values[res.id]
        if not st then
            st = {}
            rt.values[res.id] = st
        end

        if type(res.mapValue) == 'function' then
            pcall(res.mapValue, st, kvMap, now, res)
        else
            if res.serverKey and kvMap[res.serverKey] ~= nil then
                local num = tonumber(kvMap[res.serverKey])
                if num ~= nil then
                    st.current = num
                    if res.type == 'toggle' or res.type == 'status' then
                        st.active = num > 0
                    end
                else
                    st.text = tostring(kvMap[res.serverKey])
                    st.active = st.text ~= '' and st.text ~= '0'
                end
            end

            if res.activeKey and kvMap[res.activeKey] ~= nil then
                local num = tonumber(kvMap[res.activeKey])
                st.active = (num ~= nil and num > 0) or (kvMap[res.activeKey] == '1')
            end

            if res.timerKey and kvMap[res.timerKey] ~= nil then
                local rem = math.max(0, tonumber(kvMap[res.timerKey]) or 0)
                st.remaining = rem
                st.expiresAt = rem > 0 and (now + rem) or 0
                if res.type == 'timer' then
                    st.active = rem > 0
                end
            end

            if res.subKey and kvMap[res.subKey] ~= nil then
                st.subValue = tonumber(kvMap[res.subKey]) or kvMap[res.subKey]
            end
        end
    end
end

function M.updateNativeRecasts(soulDef, rt, recastLookup, now)
    if not soulDef or not rt or type(recastLookup) ~= 'table' then
        return
    end
    for _, res in ipairs(soulDef.resources) do
        if res.recastId ~= nil then
            local st = rt.values[res.id]
            if st then
                local rem = recastLookup[res.recastId] or 0
                if res.type == 'charges' and (res.maxCharges or 1) > 1 and (res.chargeTime or 0) > 0 then
                    local maxC = res.maxCharges
                    local cTime = res.chargeTime
                    local totalCap = maxC * cTime
                    local clampedRem = math.min(totalCap, math.max(0, rem))
                    local missingCharges = math.ceil(clampedRem / cTime)
                    local curCharges = math.max(0, maxC - missingCharges)
                    local nextRem = clampedRem > 0 and (clampedRem % cTime) or 0
                    if clampedRem > 0 and nextRem == 0 then
                        nextRem = cTime
                    end
                    st.charges    = curCharges
                    st.current    = curCharges
                    st.maxCharges = maxC
                    st.max        = maxC
                    st.remaining  = nextRem
                    st.duration   = cTime
                    st.ready      = curCharges > 0
                    st.active     = curCharges > 0
                else
                    st.remaining = rem
                    st.ready     = rem <= 0
                    if res.type == 'cooldown' then
                        st.active = rem <= 0
                        if rem > (st.duration or 0) then
                            st.duration = rem
                        end
                    end
                end
            end
        end
    end
end

function M.tickTimers(soulDef, rt, now)
    if not soulDef or not rt then return end
    for _, res in ipairs(soulDef.resources) do
        local st = rt.values[res.id]
        if st and st.expiresAt and st.expiresAt > 0 then
            local rem = st.expiresAt - now
            if rem <= 0 then
                st.remaining = 0
                st.expiresAt = 0
                if res.type == 'timer' then
                    st.active = false
                end
            else
                st.remaining = rem
            end
        end
    end
end

return M
