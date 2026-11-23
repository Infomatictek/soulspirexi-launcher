--[[
* SoulspireXI Gear Manager (soulspire_gear) - Crystal Spec & WS Talent Live Sync
* Passively tracks active SoulspireXI Soul Crystal specialization (0x1FF CRYS,
* [OXSPEC]| text protocol, and crystaljobs.dll FFI) and invested Weaponskill
* Talent nodes ([OXTAL]| text protocol).
--]]

local ox_sync = {}

local okFfi, ffi = pcall(require, 'ffi')
if okFfi and ffi then
    pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char* name);')
    pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void* module, const char* name);')
end

local crystal_status_t = (okFfi and ffi) and ffi.typeof([=[struct {
    uint32_t size, version, enabled, hooks, character_id, job, known, branch;
    uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
    uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
}[1]]=]) or nil

-- Authoritative SoulspireXI Job Crystal Catalog
ox_sync.SPECS_BY_JOB = {
    [1] = { -- WAR
        { id = 1, key = 'commander', name = 'Commander', role = 'Active Tactical Buffer & Tank Support' },
        { id = 2, key = 'berserker', name = 'Berserker', role = 'Fury / Heavy Burst DPS' },
        { id = 3, key = 'gladiator', name = 'Gladiator', role = 'Bloodthirsty Club & Shield Tank' },
    },
    [2] = { -- MNK
        { id = 1, key = 'sensei',    name = 'Sensei',     role = 'Staff Evasion, Parry & Counter Tank' },
        { id = 2, key = 'blackbelt', name = 'Black Belt', role = 'Hand-to-Hand Martial DPS' },
        { id = 3, key = 'chiweaver', name = 'Chi Weaver', role = 'Unarmed Ranged Chi & Pulse Healer' },
    },
    [3] = { -- WHM
        { id = 1, key = 'bishop',    name = 'Bishop',     role = 'Healer' },
    },
    [4] = { -- BLM
        { id = 1, key = 'necromancer', name = 'Necromancer', role = 'Scythe & Undead Summoner' },
    },
    [5] = { -- RDM
        { id = 1, key = 'crimsonduelist', name = 'Crimson Duelist', role = 'Hex-Crippling Fencer & Barrier Weaver' },
    },
    [7] = { -- PLD
        { id = 1, key = 'aegistemplar', name = 'Aegis Templar', role = 'Party-Intercepting Holy Bastion' },
        { id = 2, key = 'templar',      name = 'Templar',       role = 'Healer' },
    },
    [8] = { -- DRK
        { id = 1, key = 'dreadnought', name = 'Dreadnought', role = 'Blood-Pool & Dread Spikes Tank' },
    },
    [9] = { -- BST
        { id = 1, key = 'alphawarden', name = 'Alpha Warden', role = 'Symbiotic Soul-Link & Pack-Mitigation Tank' },
    },
    [12] = { -- SAM
        { id = 1, key = 'ronin',          name = 'Ronin',           role = 'Mushin Seigan & Stagger Tank' },
        { id = 2, key = 'imperialarcher', name = 'Imperial Archer', role = 'Oisoya Bow & Blade Skirmisher' },
        { id = 3, key = 'warlord',        name = 'Warlord',         role = 'Cursed Onimaru & Iaijutsu Tactical Support' },
    },
    [13] = { -- NIN
        { id = 1, key = 'kagemusha',      name = 'Kagemusha',       role = 'Shadow & Ninjutsu Tank' },
    },
    [14] = { -- DRG
        { id = 3, key = 'wyvernheart',    name = 'Wyvernheart',     role = 'Healer' },
    },
    [15] = { -- SMN
        { id = 2, key = 'celestial',      name = 'Celestial',       role = 'Healer' },
    },
    [16] = { -- BLU
        { id = 1, key = 'azurebastion',   name = 'Azure Bastion',   role = 'Monster-Core Assimilator & Dual-Wield Tank' },
        { id = 2, key = 'magus',          name = 'Magus',           role = 'Healer' },
    },
    [18] = { -- PUP
        { id = 1, key = 'vanguard',       name = 'Vanguard',        role = 'Automaton Proxy-Tank & Tactical Link' },
        { id = 2, key = 'animist',        name = 'Animist',         role = 'Healer' },
    },
    [19] = { -- DNC
        { id = 1, key = 'bladewheel',     name = 'Bladewheel',      role = 'Ranged Chakram Dancer' },
        { id = 2, key = 'miragesentinel', name = 'Mirage Sentinel', role = 'Fan-Dance Rhythm & Waltz-Shield Tank' },
        { id = 3, key = 'vampire',        name = 'Vampire',         role = 'Healer' },
    },
    [20] = { -- SCH
        { id = 1, key = 'medic',     name = 'Medic',     role = 'Light Arts & Eos Faerie Healer' },
        { id = 2, key = 'sage',      name = 'Sage',      role = 'Dark Arts & Titania Faerie Nuker' },
    },
    [21] = { -- GEO
        { id = 2, key = 'verdant',   name = 'Verdant',   role = 'Healer' },
    },
    [22] = { -- RUN
        { id = 1, key = 'inquisitor', name = 'Inquisitor', role = 'Parry & Runic Aegis Tank' },
        { id = 2, key = 'spellblade', name = 'Spellblade', role = 'Elemental & Multi-Attack Hybrid DPS' },
        { id = 3, key = 'lifebinder', name = 'Lifebinder', role = 'Font of Life & Ward Sustain Tank' },
    },
}

ox_sync.State = {
    ActiveByJob  = {}, -- jobId -> branchId (0 = none)
    OverrideSpec = {}, -- jobId -> 'auto' | 'none' | specKey
    WsSpent      = {}, -- wsId -> points spent
    WsBonuses    = {}, -- wsId -> { Stats = { STR = ..., ... }, Kind = 'magical'|'hybrid'|nil }
    TempWsNodes  = {},
    LastDllPoll  = 0,
}

local function splitPipe(str)
    local out = {}
    local start = 1
    while true do
        local pos = string.find(str, '|', start, true)
        if not pos then
            out[#out + 1] = string.sub(str, start)
            break
        end
        out[#out + 1] = string.sub(str, start, pos - 1)
        start = pos + 1
    end
    return out
end

-- Poll crystaljobs.dll if loaded by crystalsocket so we immediately know active crystal branch
function ox_sync.PollCrystalDll()
    if not (okFfi and ffi and crystal_status_t) then return false end
    local now = os.clock()
    if (now - ox_sync.State.LastDllPoll) < 2.0 then return false end
    ox_sync.State.LastDllPoll = now

    local changed = false
    pcall(function()
        local mod = ffi.C.GetModuleHandleA('soulspire_native.dll')
        local exportName = 'SoulspireNativeGetStatus'
        if mod == nil then
            mod = ffi.C.GetModuleHandleA('crystaljobs.dll')
            exportName = 'CrystalJobsGetStatus'
        end
        if mod == nil then return end
        local addr = ffi.C.GetProcAddress(mod, exportName)
        if addr == nil and exportName == 'SoulspireNativeGetStatus' then
            addr = ffi.C.GetProcAddress(mod, 'CrystalJobsGetStatus')
        end
        if addr == nil then return end
        local fn = ffi.cast('uint32_t (__stdcall *)(void*, uint32_t)', addr)
        local st = ffi.new(crystal_status_t)
        if fn(st, ffi.sizeof(st)) == 0 and st[0].size == 68 and st[0].known == 1 then
            local jobId = tonumber(st[0].job) or 0
            local branch = tonumber(st[0].branch) or 0
            if jobId >= 1 and jobId <= 22 and ox_sync.State.ActiveByJob[jobId] ~= branch then
                ox_sync.State.ActiveByJob[jobId] = branch
                changed = true
            end
        end
    end)
    return changed
end

-- Returns the Spec entry table ({ id, key, name, role }) active for (jobId, level), or nil
function ox_sync.GetActiveSpec(jobId, level)
    ox_sync.PollCrystalDll()
    local specs = ox_sync.SPECS_BY_JOB[jobId]
    if not specs then return nil end

    local override = ox_sync.State.OverrideSpec[jobId] or 'auto'
    if override == 'none' then
        return nil
    elseif override ~= 'auto' then
        for _, s in ipairs(specs) do
            if s.key == override then
                return s
            end
        end
    end

    if (level or 99) < 10 then
        return nil
    end

    local branchId = ox_sync.State.ActiveByJob[jobId] or 0
    if branchId <= 0 then return nil end
    for _, s in ipairs(specs) do
        if s.id == branchId then
            return s
        end
    end
    return nil
end

function ox_sync.GetSpecsForJob(jobId)
    return ox_sync.SPECS_BY_JOB[jobId] or {}
end

-- Decode 0x1FF CRYS packet from server
function ox_sync.HandlePacketIn(e)
    if e.id ~= 0x1FF then return false end
    local raw = e.data_modified or e.data
    if type(raw) ~= 'string' or #raw < 64 then return false end
    if raw:sub(5, 8) ~= 'CRYS' then return false end

    local b = { raw:byte(1, 64) }
    if b[9] ~= 1 or b[14] ~= 24 then return false end

    local changed = false
    for idx = 1, 23 do
        local active = b[16 + idx * 2]
        local jobId = idx - 1
        if jobId >= 1 and jobId <= 22 and active ~= nil and active <= 7 then
            if ox_sync.State.ActiveByJob[jobId] ~= active then
                ox_sync.State.ActiveByJob[jobId] = active
                changed = true
            end
        end
    end
    return changed
end

local function parseTalentNodesIntoBonuses(wsId, nodes)
    local stats = {}
    local kindOverride = nil
    for _, n in ipairs(nodes or {}) do
        local r = tonumber(n.rank) or 0
        if r > 0 then
            local desc = string.upper(tostring(n.desc or '') .. ' ' .. tostring(n.name or ''))
            for _, statName in ipairs({ 'STR', 'DEX', 'VIT', 'AGI', 'INT', 'MND', 'CHR' }) do
                if string.find(desc, statName, 1, true) then
                    stats[statName] = (stats[statName] or 0) + (0.25 * r)
                end
            end
            if string.find(desc, 'CRIT', 1, true) then
                stats.CRITHITRATE = (stats.CRITHITRATE or 0) + (0.4 * r)
                stats.CRIT_DMG_INCREASE = (stats.CRIT_DMG_INCREASE or 0) + (0.3 * r)
            end
            if string.find(desc, 'MAGIC', 1, true) or string.find(desc, 'ELEMENTAL', 1, true) or string.find(desc, 'HYBRID', 1, true) then
                stats.MATT = (stats.MATT or 0) + (0.5 * r)
                stats.MACC = (stats.MACC or 0) + (0.25 * r)
                if string.find(desc, 'HYBRID', 1, true) then
                    kindOverride = 'hybrid'
                end
            end
            if string.find(desc, 'ACCURACY', 1, true) or string.find(desc, 'ACC', 1, true) then
                stats.ACC = (stats.ACC or 0) + (0.25 * r)
            end
            if string.find(desc, 'ATTACK', 1, true) or string.find(desc, 'ATT', 1, true) then
                stats.ATT = (stats.ATT or 0) + (0.2 * r)
            end
        end
    end
    ox_sync.State.WsBonuses[wsId] = {
        Stats = stats,
        Kind  = kindOverride,
    }
end

-- Passively inspect [OXSPEC]| and [OXTAL]| text messages without blocking other addons
function ox_sync.HandleTextIn(e)
    local msg = e.message or ''
    local specPos = string.find(msg, '[OXSPEC]|', 1, true)
    if specPos ~= nil then
        local payload = string.sub(msg, specPos + 9)
        payload = string.gsub(payload, '[\r\n]+$', '')
        local parts = splitPipe(payload)
        local kind = parts[1]
        if kind == 'STATE' then
            -- STATE|<jobKey>|<level>|<activeId>|<activeKey>|<activeName>
            local jobKey = parts[2]
            local activeId = tonumber(parts[4]) or 0
            for jid, specs in pairs(ox_sync.SPECS_BY_JOB) do
                for _, s in ipairs(specs) do
                    if s.id == activeId and (parts[5] == s.key or jobKey ~= nil) then
                        if parts[5] == s.key then
                            ox_sync.State.ActiveByJob[jid] = activeId
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local talPos = string.find(msg, '[OXTAL]|', 1, true)
    if talPos ~= nil then
        local payload = string.sub(msg, talPos + 8)
        payload = string.gsub(payload, '[\r\n]+$', '')
        local parts = splitPipe(payload)
        local kind = parts[1]
        if kind == 'SPENT' and parts[2] then
            for entry in string.gmatch(parts[2], '([^,]+)') do
                local wsId, pts = string.match(entry, '^(%d+):(%d+)$')
                if wsId and pts then
                    ox_sync.State.WsSpent[tonumber(wsId)] = tonumber(pts)
                end
            end
        elseif kind == 'WS' then
            local wsId = tonumber(parts[2])
            if wsId then
                ox_sync.State.TempWsNodes[wsId] = {}
            end
        elseif kind == 'NODE' then
            local wsId = tonumber(parts[2])
            if wsId and ox_sync.State.TempWsNodes[wsId] then
                table.insert(ox_sync.State.TempWsNodes[wsId], {
                    key  = parts[3],
                    rank = tonumber(parts[6]) or 0,
                    name = parts[12] or '',
                    desc = parts[13] or '',
                })
            end
        elseif kind == 'WS_END' then
            local wsId = tonumber(parts[2])
            if wsId and ox_sync.State.TempWsNodes[wsId] then
                parseTalentNodesIntoBonuses(wsId, ox_sync.State.TempWsNodes[wsId])
                ox_sync.State.TempWsNodes[wsId] = nil
                return true
            end
        end
    end
    return false
end

return ox_sync
