-- SoulspireXI Core: Universal Character State Service (SoulspireCore.CharacterState)
--
-- Single canonical client-side character-state provider and synchronization coordinator
-- for every SoulspireXI Core module (Character, Weapon Mastery, Soul Talents, Abilities,
-- Equipment, Journal, Universal Soul HUD, and the Soulforge visual overhaul).
--
-- Architectural Guarantees:
--   1. Layered Authority Model:
--        - Ashita/FFXI Runtime (`observed`): immediate job/level/identity/equipment/zone display
--        - SoulspireXI Server (`confirmed`): authoritative Soul ownership, active socket,
--          talent point balances, ranks, mastery slots, and eligibility decisions
--        - Verified Local Cache (`DataService`): static metadata & presentation only (never duplicated here)
--   2. Never represents unknown information as confirmed.
--   3. Event-driven updates (0x00A, 0x00B, 0x00D, 0x01B, 0x01D, 0x037, 0x050, 0x061,
--      0x1FC, 0x1FD, 0x1FF, 0x017) with coalesced sync scheduling and bounded low-frequency
--      reconciliation (no per-frame polling or tab-switch sync storms).
--   4. Immutable/isolated snapshots (LuaJIT 2.1 pairs/ipairs-safe) + selector-based
--      subscriptions with deep-equality change detection and re-entrant loop prevention.
--   5. Unified Synchronization Coordinator: one in-flight request per domain, deduplication,
--      priority scheduling, bounded exponential-backoff retries, session/zone/seq correlation,
--      stale-response rejection, and explicit pending transaction tracking.

local CharacterState = {}
CharacterState.__index = CharacterState

local JOB_NAMES = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM', [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK',
    [9]  = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
}

local SKILL_NAMES = {
    [1]  = 'Hand-to-Hand', [2]  = 'Dagger',       [3]  = 'Sword',
    [4]  = 'Great Sword',  [5]  = 'Axe',          [6]  = 'Great Axe',
    [7]  = 'Scythe',       [8]  = 'Polearm',      [9]  = 'Katana',
    [10] = 'Great Katana', [11] = 'Club',         [12] = 'Staff',
    [25] = 'Archery',      [26] = 'Marksmanship', [27] = 'Throwing',
}

local NATION_NAMES = {
    [0] = "San d'Oria",
    [1] = 'Bastok',
    [2] = 'Windurst',
}

local PRIORITY_RANK = {
    high   = 3,
    normal = 2,
    low    = 1,
}

local DEFAULT_TTL = {
    identity    = 60.0,
    soul        = 30.0,
    progression = 20.0,
    equipment   = 30.0,
    hud         = 30.0,
}

local DEFAULT_BACKOFF = { 1.2, 2.4, 4.0 }
local MAX_NOTIFY_DEPTH = 4
local MAX_SPEC_WS_SLOTS = 4
local DEFAULT_SOUL_REQ_LEVEL = 10

CharacterState.JOB_NAMES = JOB_NAMES
CharacterState.SKILL_NAMES = SKILL_NAMES
CharacterState.NATION_NAMES = NATION_NAMES
CharacterState.MAX_SPEC_WS_SLOTS = MAX_SPEC_WS_SLOTS

-- ---------------------------------------------------------------------------
-- Pure Helpers: Deep Clone, Read-Only Guard (LuaJIT 2.1 pairs-safe), Equality
-- ---------------------------------------------------------------------------
local READONLY_MT = {
    __newindex = function()
        error('SoulspireCore.CharacterState snapshot is read-only; mutate state only via CharacterState APIs.', 2)
    end,
}

local function deep_clone(v, readonly)
    if type(v) ~= 'table' then
        return v
    end
    local out = {}
    for k, val in pairs(v) do
        out[k] = deep_clone(val, readonly)
    end
    if readonly then
        return setmetatable(out, READONLY_MT)
    end
    return out
end

local function values_equal(a, b)
    if a == b then return true end
    if type(a) ~= 'table' or type(b) ~= 'table' then
        return false
    end
    for k, va in pairs(a) do
        if not values_equal(va, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

local function make_equip_slot(src)
    if type(src) ~= 'table' then
        return { bag = 0, slot = 0, itemId = 0, skillId = 0, category = 'None' }
    end
    local sk = tonumber(src.skillId) or 0
    return {
        bag      = tonumber(src.bag) or 0,
        slot     = tonumber(src.slot) or 0,
        itemId   = tonumber(src.itemId) or 0,
        skillId  = sk,
        category = tostring(src.category or SKILL_NAMES[sk] or (sk > 0 and ('Skill #' .. tostring(sk)) or 'None')),
    }
end

local function equip_signature(eq)
    if type(eq) ~= 'table' then return '0:0:0|0:0:0|0:0:0' end
    local m = eq.mainHand or {}
    local s = eq.subHand or {}
    local r = eq.ranged or {}
    return string.format('%d:%d:%d|%d:%d:%d|%d:%d:%d',
        tonumber(m.bag) or 0, tonumber(m.slot) or 0, tonumber(m.itemId) or 0,
        tonumber(s.bag) or 0, tonumber(s.slot) or 0, tonumber(s.itemId) or 0,
        tonumber(r.bag) or 0, tonumber(r.slot) or 0, tonumber(r.itemId) or 0)
end

local function format_equipped_summary(main_sk, ranged_sk)
    local m = tonumber(main_sk) or 0
    local r = tonumber(ranged_sk) or 0
    local parts = {}
    if m > 0 then
        parts[#parts + 1] = SKILL_NAMES[m] or ('Skill #' .. tostring(m))
    end
    if r > 0 and r ~= m then
        parts[#parts + 1] = SKILL_NAMES[r] or ('Skill #' .. tostring(r))
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ' / ')
end

local function owns_branch(mask, branch_id)
    local m = tonumber(mask) or 0
    local b = tonumber(branch_id) or 0
    if b < 1 or b > 7 then return false end
    local bit_val = 2 ^ b
    return math.floor(m / bit_val) % 2 == 1
end

local function make_domain_state(name, ttl)
    return {
        domain             = name,
        state              = 'unknown', -- 'unknown' | 'loading' | 'fresh' | 'stale' | 'error' | 'offline'
        fresh              = false,
        confirmed          = false,
        loading            = false,
        lastSyncAt         = nil,
        lastAttemptAt      = nil,
        invalidatedAt      = nil,
        invalidationReason = nil,
        error              = nil,
        revision           = 0,
        ttlSec             = ttl or 30.0,
        pendingRequests    = 0,
        retries            = 0,
        lastLatencyMs      = nil,
        lastResponseBytes  = 0,
    }
end

-- ---------------------------------------------------------------------------
-- Default Ashita v4 Runtime Memory Reader (safe in headless tests)
-- ---------------------------------------------------------------------------
local function default_runtime_reader()
    if type(AshitaCore) ~= 'table' or not AshitaCore.GetMemoryManager then
        return nil
    end
    local ok, res = pcall(function()
        local mem    = AshitaCore:GetMemoryManager()
        local party  = mem and mem:GetParty()
        local player = mem and mem:GetPlayer()
        if not party or not player then
            return { inSession = false }
        end
        local sid  = party:GetMemberServerId(0) or 0
        local tidx = party:GetMemberTargetIndex(0) or 0
        local name = party:GetMemberName(0)
        if sid < 1 or tidx == 0 or type(name) ~= 'string' or name == '' then
            return { inSession = false }
        end

        local getMainLvl = player.GetMainJobLevel or player.GetMainLevel
        local getSubLvl  = player.GetSubJobLevel or player.GetSubLevel
        local mainJob    = player:GetMainJob() or 0
        local mainLvl    = getMainLvl and (getMainLvl(player) or 0) or 0
        local subJob     = (player.GetSubJob and player:GetSubJob()) or 0
        local subLvl     = getSubLvl and (getSubLvl(player) or 0) or 0
        local nation     = (player.GetNation and player:GetNation()) or nil
        local zone       = party:GetMemberZone(0) or 0

        local isDead = false
        local ent = mem.GetEntity and mem:GetEntity()
        if ent and ent.GetStatus then
            local st = ent:GetStatus(tidx)
            isDead = (st == 2 or st == 3)
        end

        local function read_eq(eq_slot)
            local inv = mem.GetInventory and mem:GetInventory()
            if not inv or not inv.GetEquippedItem then
                return { bag = 0, slot = 0, itemId = 0, skillId = 0 }
            end
            local eq = inv:GetEquippedItem(eq_slot)
            if not eq or (eq.Index or 0) <= 0 then
                return { bag = 0, slot = 0, itemId = 0, skillId = 0 }
            end
            local idx = eq.Index
            local bag = math.floor(idx / 256)
            local slotIdx = idx % 256
            local itemId = 0
            local skillId = 0
            if inv.GetContainerItem then
                local it = inv:GetContainerItem(bag, slotIdx)
                if it and it.Id then
                    itemId = it.Id
                end
            end
            if itemId > 0 and AshitaCore.GetResourceManager then
                local rm = AshitaCore:GetResourceManager()
                local itemRes = rm and rm.GetItemById and rm:GetItemById(itemId)
                if itemRes and itemRes.Skill then
                    skillId = tonumber(itemRes.Skill) or 0
                end
            end
            return { bag = bag, slot = slotIdx, itemId = itemId, skillId = skillId }
        end

        return {
            inSession   = true,
            characterId = sid,
            name        = name,
            targetIndex = tidx,
            mainJob     = mainJob,
            mainLevel   = mainLvl,
            subJob      = subJob,
            subLevel    = subLvl,
            nation      = nation,
            zone        = zone,
            isDead      = isDead,
            equipment   = {
                mainHand = read_eq(0),
                subHand  = read_eq(1),
                ranged   = read_eq(2),
            },
        }
    end)
    return ok and res or nil
end

-- ---------------------------------------------------------------------------
-- State Initialization & Session Reset
-- ---------------------------------------------------------------------------
function CharacterState:_build_empty_session_state(gen, zone_gen)
    return {
        revision = 1,
        session = {
            generation     = gen,
            zoneGeneration = zone_gen,
            sessionKey     = nil,
            active         = false,
            zoning         = false,
        },
        observed = {
            characterId = 0,
            name        = nil,
            targetIndex = 0,
            mainJob     = 0,
            mainJobKey  = nil,
            mainLevel   = 0,
            subJob      = 0,
            subJobKey   = nil,
            subLevel    = 0,
            nation      = nil,
            nationName  = nil,
            zone        = 0,
            zoneName    = nil,
            inSession   = false,
            isDead      = false,
            equipment   = {
                mainHand  = make_equip_slot(nil),
                subHand   = make_equip_slot(nil),
                ranged    = make_equip_slot(nil),
                signature = '0:0:0|0:0:0|0:0:0',
            },
            observedAt = nil,
        },
        confirmed = {
            soul = {
                jobId                  = 0,
                jobKey                 = nil,
                level                  = 0,
                activeBranch           = 0,
                activeSoulId           = nil,
                activeSoulKey          = nil,
                activeSoulName         = nil,
                activeSoulAbbr         = nil,
                activeSoulRole         = nil,
                activeSoulRoleCategory = nil,
                ownedMask              = 0,
                unlockedBranches       = {},
                availableSouls         = {},
                hudBranch              = 0,
                hudJob                 = 0,
                loaded                 = false,
                lastResult             = nil,
                status                 = 'unknown',
                message                = nil,
                revision               = 0,
            },
            progression = {
                jobKey                = nil,
                jobLevel              = 0,
                specKey               = nil,
                specName              = nil,
                talentPoints          = {
                    weaponMastery = { available = 0, spent = 0, earned = 0 },
                    soulTalents   = { available = 0, spent = 0, earned = 0 },
                },
                masteredWeaponSkills  = {},
                masterySlotsUsed      = 0,
                masterySlotsMax       = MAX_SPEC_WS_SLOTS,
                unlockedWsCount       = 0,
                wsUnlockedById        = {},
                wsSpentById           = {},
                wsEligibility         = {
                    mainSkill       = 0,
                    rangedSkill     = 0,
                    serverConfirmed = false,
                },
                synced                = false,
                protocolVersion       = 2,
                revision              = 0,
            },
            equipment = {
                mainSkill       = 0,
                rangedSkill     = 0,
                equippedSummary = nil,
                revision        = 0,
            },
            hud = {
                soulKey  = '',
                kv       = {},
                syncedAt = nil,
                revision = 0,
            },
        },
        effective = {
            characterId      = 0,
            name             = nil,
            mainJob          = 0,
            mainJobKey       = nil,
            mainLevel        = nil,
            mainLevelSource  = 'unknown',
            confirmedLevel   = nil,
            levelMismatch    = false,
            subJob           = 0,
            subJobKey        = nil,
            subLevel         = nil,
            zone             = 0,
            nation           = nil,
            nationName       = nil,
            isDead           = false,
            soulBranch       = 0,
            soulId           = nil,
            soulKey          = nil,
            soulName         = nil,
            soulAbbr         = nil,
            soulRole         = nil,
            soulRoleCategory = nil,
            soulSource       = 'unknown',
            soulEligibility  = {
                eligible  = false,
                minLevel  = DEFAULT_SOUL_REQ_LEVEL,
                reason    = 'Waiting for character state.',
                confirmed = false,
            },
            mainSkill       = 0,
            rangedSkill     = 0,
            equippedSummary = nil,
        },
        domains = {
            identity    = make_domain_state('identity', self.ttl.identity),
            soul        = make_domain_state('soul', self.ttl.soul),
            progression = make_domain_state('progression', self.ttl.progression),
            equipment   = make_domain_state('equipment', self.ttl.equipment),
            hud         = make_domain_state('hud', self.ttl.hud),
        },
        transactions = {
            active = {},
            last   = nil,
        },
        cache = {
            status         = 'unloaded',
            usable         = false,
            compatState    = 'unverified',
            contentVersion = '',
            registryHash   = '',
            talentsWarm    = false,
        },
    }
end

function CharacterState.new(opts)
    opts = opts or {}
    local ttl = {
        identity    = tonumber(opts.identityTtlSec) or DEFAULT_TTL.identity,
        soul        = tonumber(opts.soulTtlSec) or DEFAULT_TTL.soul,
        progression = tonumber(opts.progressionTtlSec) or DEFAULT_TTL.progression,
        equipment   = tonumber(opts.equipmentTtlSec) or DEFAULT_TTL.equipment,
        hud         = tonumber(opts.hudTtlSec) or DEFAULT_TTL.hud,
    }
    local self = setmetatable({
        clock                = opts.clock or os.clock,
        data_service         = opts.dataService or opts.data_service,
        soul_registry        = opts.soulRegistry or opts.soul_registry,
        ipc                  = opts.ipc,
        runtime_reader       = opts.runtimeReader or opts.runtime_reader or default_runtime_reader,
        ttl                  = ttl,
        reconcile_interval   = tonumber(opts.reconcileIntervalSec) or 1.0,
        coalesce_window      = tonumber(opts.coalesceWindowSec) or 0.15,
        request_timeout_sec  = tonumber(opts.requestTimeoutSec) or 4.5,
        max_retries          = tonumber(opts.maxRetries) or 2,
        backoff_schedule     = opts.backoffSchedule or DEFAULT_BACKOFF,

        _session_gen         = 1,
        _zone_gen            = 1,
        _req_seq             = 0,
        _tx_seq              = 0,
        _sub_seq             = 0,
        _subscriptions       = {},
        _sub_order           = {},
        _notifying           = false,
        _notify_depth        = 0,
        _notify_queued       = false,

        _transports          = {}, -- domain -> fn(reqMeta) -> ok, err
        _in_flight           = {}, -- domain -> reqMeta
        _pending_queue       = {}, -- domain -> { priority, force, reason, readyAt }
        _visible_domains     = {}, -- domain -> true
        _session_reset_hooks = {}, -- list of fn(reason, sessionGen)
        _last_reconcile_at   = -999,
        _snapshot_cache_rev  = -1,

        _diag = {
            droppedStaleResponses    = 0,
            dedupedRequests          = 0,
            totalRequestsSent        = 0,
            totalSyncSuccesses       = 0,
            totalSyncFailures        = 0,
            totalRetries             = 0,
            notificationLoopsBlocked = 0,
            listenerErrors           = 0,
            lastLatencyMsByDomain    = {},
            lastResponseBytesByDom   = {},
            lastEvents               = {},
        },
    }, CharacterState)

    self._state = self:_build_empty_session_state(self._session_gen, self._zone_gen)
    self:_sync_cache_summary()
    self:_recompute_effective()
    return self
end

function CharacterState:_record_diag_event(kind, detail)
    local ev = {
        at     = self.clock(),
        kind   = tostring(kind),
        detail = tostring(detail or ''),
    }
    local list = self._diag.lastEvents
    if #list >= 40 then
        table.remove(list, 1)
    end
    list[#list + 1] = ev
    if self.data_service and self.data_service.record_event then
        self.data_service:record_event('char_state', kind, detail)
    end
end

function CharacterState:_resolve_soul_meta(job_id, branch_id, key_hint)
    local jid = tonumber(job_id) or 0
    local bid = tonumber(branch_id) or 0
    if self.data_service and self.data_service:is_cache_usable() then
        if jid >= 1 and jid <= 22 and bid >= 1 and bid <= 3 then
            local s = self.data_service:get_soul_by_job_branch(jid, bid)
            if s then return s end
        end
        if type(key_hint) == 'string' and key_hint ~= '' then
            local s = self.data_service:get_soul_by_key(key_hint)
            if s then return s end
        end
    end
    if self.soul_registry then
        if jid >= 1 and jid <= 22 and bid >= 1 and bid <= 3 and self.soul_registry.byJob then
            local s = self.soul_registry.byJob(jid, bid)
            if s then return s end
        end
        if type(key_hint) == 'string' and key_hint ~= '' and self.soul_registry.resolve then
            local s = self.soul_registry.resolve(key_hint)
            if s then return s end
        end
    end
    return nil
end

function CharacterState:_sync_cache_summary()
    local c = self._state.cache
    if self.data_service and self.data_service.get_cache_info then
        local info = self.data_service:get_cache_info()
        c.status         = info.status or 'unloaded'
        c.usable         = self.data_service:is_cache_usable() == true
        c.compatState    = info.compatState or 'unverified'
        c.contentVersion = info.contentVersion or ''
        c.registryHash   = info.registryHash or ''
        c.talentsWarm    = (self.data_service.is_talents_warm and self.data_service:is_talents_warm()) == true
    else
        c.status      = 'unavailable'
        c.usable      = false
        c.compatState = 'unverified'
        c.talentsWarm = false
    end
end

function CharacterState:_recompute_effective()
    local st  = self._state
    local obs = st.observed
    local cs  = st.confirmed.soul
    local cp  = st.confirmed.progression
    local ce  = st.confirmed.equipment
    local eff = st.effective

    eff.characterId = obs.characterId or 0
    eff.name        = obs.name
    eff.zone        = obs.zone or 0
    eff.nation      = obs.nation
    eff.nationName  = obs.nationName
    eff.isDead      = obs.isDead == true

    -- Layered Authority: Main Job & Level (immediate runtime display, distinct from server confirmation)
    local jobId = (obs.mainJob and obs.mainJob > 0) and obs.mainJob
        or ((cs.jobId and cs.jobId > 0) and cs.jobId or 0)
    eff.mainJob    = jobId
    eff.mainJobKey = (jobId > 0 and JOB_NAMES[jobId]) or cp.jobKey or cs.jobKey or nil

    local confirmedLvl = nil
    if cp.synced and (cp.jobLevel or 0) > 0 then
        confirmedLvl = cp.jobLevel
    elseif cs.loaded and (cs.level or 0) > 0 then
        confirmedLvl = cs.level
    end
    eff.confirmedLevel = confirmedLvl

    if (obs.mainLevel or 0) > 0 then
        eff.mainLevel       = obs.mainLevel
        eff.mainLevelSource = 'observed'
    elseif cs.loaded and (cs.level or 0) > 0 then
        eff.mainLevel       = cs.level
        eff.mainLevelSource = 'confirmed_crys'
    elseif cp.synced and (cp.jobLevel or 0) > 0 then
        eff.mainLevel       = cp.jobLevel
        eff.mainLevelSource = 'confirmed_oxtl'
    else
        eff.mainLevel       = nil
        eff.mainLevelSource = 'unknown'
    end

    eff.levelMismatch = ((obs.mainLevel or 0) > 0 and confirmedLvl ~= nil and obs.mainLevel ~= confirmedLvl)

    eff.subJob    = obs.subJob or 0
    eff.subJobKey = (eff.subJob > 0 and JOB_NAMES[eff.subJob]) or nil
    eff.subLevel  = (eff.subJob > 0 and (obs.subLevel or 0) > 0) and obs.subLevel or nil

    -- Soul identity (server-authoritative CRYS > OXTL META > 0x1FC HUD hint > unknown)
    local branch = 0
    local soulMeta = nil
    local soulSource = 'unknown'

    if cs.loaded and (cs.jobId == jobId or jobId == 0) then
        branch = cs.activeBranch or 0
        if branch > 0 then
            soulMeta = self:_resolve_soul_meta(jobId > 0 and jobId or cs.jobId, branch, cs.activeSoulKey)
            soulSource = 'confirmed_crys'
        else
            soulSource = 'confirmed_crys'
        end
    elseif cp.synced and type(cp.specKey) == 'string' and cp.specKey ~= '' and string.lower(cp.specKey) ~= 'base' then
        soulMeta = self:_resolve_soul_meta(jobId, 0, cp.specKey)
        branch = (soulMeta and tonumber(soulMeta.branchId or soulMeta.branch)) or 0
        soulSource = 'confirmed_oxtl'
    elseif (cs.hudBranch or 0) > 0 and (cs.hudJob == jobId or jobId == 0) then
        branch = cs.hudBranch
        soulMeta = self:_resolve_soul_meta(jobId > 0 and jobId or cs.hudJob, branch, nil)
        soulSource = 'hud_hint'
    elseif cs.loaded then
        soulSource = 'none'
    end

    eff.soulBranch       = branch
    eff.soulSource       = soulSource
    eff.soulId           = soulMeta and soulMeta.id or cs.activeSoulId
    eff.soulKey          = soulMeta and (soulMeta.internalKey or soulMeta.canonicalKey) or cs.activeSoulKey or cp.specKey
    eff.soulName         = soulMeta and (soulMeta.displayName or soulMeta.name) or cs.activeSoulName or ((soulSource == 'confirmed_crys' or soulSource == 'none') and 'Base' or (cp.specName or nil))
    eff.soulAbbr         = soulMeta and soulMeta.abbreviation or cs.activeSoulAbbr or eff.mainJobKey
    eff.soulRole         = soulMeta and (soulMeta.roleLabel or soulMeta.roleCategory) or cs.activeSoulRole
    eff.soulRoleCategory = soulMeta and soulMeta.roleCategory or cs.activeSoulRoleCategory

    -- Soul eligibility context (server-confirmed when CRYS loaded; observed preview otherwise)
    local minLvl = DEFAULT_SOUL_REQ_LEVEL
    local displayLvl = eff.mainLevel or 0
    if cs.loaded then
        local anyOwned = (cs.ownedMask or 0) > 0
        eff.soulEligibility = {
            eligible  = anyOwned,
            minLevel  = minLvl,
            reason    = anyOwned and 'Server confirmed eligible Soul Crystals.' or string.format('Requires Lv.%d+ to unlock Soul Crystals.', minLvl),
            confirmed = true,
        }
    elseif displayLvl > 0 then
        eff.soulEligibility = {
            eligible  = (displayLvl >= minLvl),
            minLevel  = minLvl,
            reason    = (displayLvl >= minLvl) and 'Awaiting server confirmation of Soul ownership.' or string.format('Requires Lv.%d (currently Lv.%d).', minLvl, displayLvl),
            confirmed = false,
        }
    else
        eff.soulEligibility = {
            eligible  = false,
            minLevel  = minLvl,
            reason    = 'Waiting for character state.',
            confirmed = false,
        }
    end

    -- Equipment context (server-confirmed weapon skills take precedence for eligibility; observed fills gaps)
    local mainSk   = (ce.mainSkill or 0) > 0 and ce.mainSkill or (obs.equipment.mainHand.skillId or 0)
    local rangedSk = (ce.rangedSkill or 0) > 0 and ce.rangedSkill or (obs.equipment.ranged.skillId or 0)
    eff.mainSkill       = mainSk
    eff.rangedSkill     = rangedSk
    eff.equippedSummary = format_equipped_summary(mainSk, rangedSk)
end

function CharacterState:_bump_and_notify(reason)
    self._state.revision = self._state.revision + 1
    self:_sync_cache_summary()
    self:_recompute_effective()
    self:_notify_subscribers(reason)
end

-- ---------------------------------------------------------------------------
-- Immutable / Isolated Snapshot & Selector Subscriptions (Phase 4)
-- ---------------------------------------------------------------------------
function CharacterState:getSnapshot()
    -- Returns a structurally isolated read-only clone (LuaJIT 2.1 pairs/ipairs-safe)
    -- so mutating a snapshot can never corrupt shared state or other modules.
    return deep_clone(self._state, true)
end

function CharacterState:subscribe(selector, callback, opts)
    if type(selector) ~= 'function' or type(callback) ~= 'function' then
        error('CharacterState:subscribe requires (selector, callback) functions', 2)
    end
    opts = opts or {}
    self._sub_seq = self._sub_seq + 1
    local id = 'sub_' .. tostring(self._sub_seq)
    local snap = self:getSnapshot()
    local okSel, initial = pcall(selector, snap)
    local sub = {
        id       = id,
        owner    = tostring(opts.owner or 'anonymous'),
        selector = selector,
        callback = callback,
        lastVal  = okSel and deep_clone(initial, false) or nil,
        hasVal   = okSel,
    }
    self._subscriptions[id] = sub
    self._sub_order[#self._sub_order + 1] = id

    if opts.immediate == true and okSel then
        local okCb, errCb = pcall(callback, deep_clone(initial, true), nil, snap)
        if not okCb then
            self._diag.listenerErrors = self._diag.listenerErrors + 1
            self:_record_diag_event('listener_error', sub.owner .. ': ' .. tostring(errCb))
        end
    end
    return id
end

function CharacterState:unsubscribe(subscriptionId)
    if not subscriptionId or not self._subscriptions[subscriptionId] then
        return false
    end
    self._subscriptions[subscriptionId] = nil
    for i = #self._sub_order, 1, -1 do
        if self._sub_order[i] == subscriptionId then
            table.remove(self._sub_order, i)
            break
        end
    end
    return true
end

function CharacterState:unsubscribeByOwner(owner)
    local target = tostring(owner or '')
    local removed = 0
    for i = #self._sub_order, 1, -1 do
        local id = self._sub_order[i]
        local sub = self._subscriptions[id]
        if sub and sub.owner == target then
            self._subscriptions[id] = nil
            table.remove(self._sub_order, i)
            removed = removed + 1
        end
    end
    return removed
end

function CharacterState:onSessionReset(callback)
    if type(callback) ~= 'function' then return end
    self._session_reset_hooks[#self._session_reset_hooks + 1] = callback
end

function CharacterState:_notify_subscribers(_reason)
    if self._notifying then
        -- Coalesce re-entrant state updates; break recursive refresh loops cleanly.
        if self._notify_depth >= MAX_NOTIFY_DEPTH then
            self._diag.notificationLoopsBlocked = self._diag.notificationLoopsBlocked + 1
            self:_record_diag_event('loop_guard', 'Blocked recursive subscriber notification loop')
            return
        end
        self._notify_queued = true
        return
    end

    self._notifying = true
    self._notify_depth = 0
    repeat
        self._notify_queued = false
        self._notify_depth = self._notify_depth + 1
        local snap = self:getSnapshot()
        -- Copy subscription id list so unsubscribe() inside callback is safe
        local ids = {}
        for i = 1, #self._sub_order do
            ids[i] = self._sub_order[i]
        end
        for _, id in ipairs(ids) do
            local sub = self._subscriptions[id]
            if sub then
                local okSel, nextVal = pcall(sub.selector, snap)
                if okSel then
                    if (not sub.hasVal) or (not values_equal(sub.lastVal, nextVal)) then
                        local prevVal = sub.hasVal and deep_clone(sub.lastVal, true) or nil
                        sub.lastVal = deep_clone(nextVal, false)
                        sub.hasVal = true
                        local okCb, errCb = pcall(sub.callback, deep_clone(nextVal, true), prevVal, snap)
                        if not okCb then
                            self._diag.listenerErrors = self._diag.listenerErrors + 1
                            self:_record_diag_event('listener_error', sub.owner .. ': ' .. tostring(errCb))
                        end
                    end
                else
                    self._diag.listenerErrors = self._diag.listenerErrors + 1
                    self:_record_diag_event('selector_error', sub.owner .. ': ' .. tostring(nextVal))
                end
            end
        end
    until (not self._notify_queued) or self._notify_depth >= MAX_NOTIFY_DEPTH

    if self._notify_queued then
        self._diag.notificationLoopsBlocked = self._diag.notificationLoopsBlocked + 1
        self:_record_diag_event('loop_guard', 'Exceeded max notification depth (' .. tostring(MAX_NOTIFY_DEPTH) .. ')')
        self._notify_queued = false
    end
    self._notifying = false
end

-- ---------------------------------------------------------------------------
-- Freshness, Invalidation & Domain Sync Coordinator (Phases 4 & 5)
-- ---------------------------------------------------------------------------
function CharacterState:registerDomainTransport(domain, transportFn)
    if type(domain) == 'string' and type(transportFn) == 'function' then
        self._transports[domain] = transportFn
    end
end

function CharacterState:setVisibleDomains(domainsMap)
    self._visible_domains = {}
    if type(domainsMap) == 'table' then
        for k, v in pairs(domainsMap) do
            if v then self._visible_domains[k] = true end
        end
    end
end

function CharacterState:getFreshness(domain, now)
    local d = self._state.domains[domain]
    if not d then return nil end
    local t = now or self.clock()
    local age = d.lastSyncAt and math.max(0, t - d.lastSyncAt) or nil
    local fresh = (d.state == 'fresh') and (age ~= nil) and (age < (d.ttlSec or 30.0))
    return {
        domain             = domain,
        state              = (d.state == 'fresh' and not fresh) and 'stale' or d.state,
        fresh              = fresh,
        confirmed          = d.confirmed == true,
        loading            = d.loading == true,
        ageSec             = age,
        ttlSec             = d.ttlSec,
        lastSyncAt         = d.lastSyncAt,
        invalidatedAt      = d.invalidatedAt,
        invalidationReason = d.invalidationReason,
        error              = d.error,
        revision           = d.revision,
        pendingRequests    = d.pendingRequests,
        retries            = d.retries,
        lastLatencyMs      = d.lastLatencyMs,
        lastResponseBytes  = d.lastResponseBytes,
    }
end

function CharacterState:invalidate(domain, reason, now)
    local t = now or self.clock()
    local targets
    if domain == 'all' or domain == nil then
        targets = { 'soul', 'progression', 'equipment' }
    elseif type(domain) == 'table' then
        targets = domain
    else
        targets = { domain }
    end

    local changed = false
    for _, domName in ipairs(targets) do
        local d = self._state.domains[domName]
        if d then
            d.fresh = false
            d.invalidatedAt = t
            d.invalidationReason = tostring(reason or 'invalidated')
            if d.state == 'fresh' then
                d.state = 'stale'
            end
            changed = true
        end
    end

    if changed then
        if self.data_service and self.data_service.invalidate_dynamic_state then
            self.data_service:invalidate_dynamic_state(tostring(domain or 'all') .. ':' .. tostring(reason or ''))
        end
        self:_record_diag_event('invalidate', tostring(domain or 'all') .. ' (' .. tostring(reason or '') .. ')')
        self:_bump_and_notify('invalidate:' .. tostring(reason or ''))
    end
end

function CharacterState:_dispatch_domain_request(domain, priority, reason, now)
    local t = now or self.clock()
    local d = self._state.domains[domain]
    if not d then return false, 'unknown_domain' end

    if self._state.session.zoning then
        return false, 'zoning'
    end

    local transport = self._transports[domain]
    if type(transport) ~= 'function' then
        return false, 'no_transport'
    end

    if self._in_flight[domain] then
        self._diag.dedupedRequests = self._diag.dedupedRequests + 1
        if self.data_service then self.data_service:record_metric('deduped_requests', 1) end
        return false, 'in_flight_deduped'
    end

    self._req_seq = self._req_seq + 1
    local req = {
        domain      = domain,
        seq         = self._req_seq,
        sessionGen  = self._session_gen,
        zoneGen     = self._zone_gen,
        priority    = priority or 'normal',
        reason      = tostring(reason or 'refresh'),
        sentAt      = t,
        retries     = 0,
        nextRetryAt = nil,
    }
    self._in_flight[domain] = req
    d.loading = true
    d.pendingRequests = 1
    d.lastAttemptAt = t
    d.error = nil
    if d.state == 'unknown' or d.state == 'error' or d.state == 'stale' then
        d.state = 'loading'
    end

    self._diag.totalRequestsSent = self._diag.totalRequestsSent + 1
    local okCall, sentOk, errMsg = pcall(transport, req)
    if not okCall or sentOk == false then
        self._in_flight[domain] = nil
        d.loading = false
        d.pendingRequests = 0
        d.state = 'error'
        d.error = tostring(errMsg or (not okCall and sentOk) or 'Sync transport failed.')
        self._diag.totalSyncFailures = self._diag.totalSyncFailures + 1
        self:_bump_and_notify('dispatch_error:' .. domain)
        return false, d.error
    end

    self:_bump_and_notify('dispatch:' .. domain)
    return true, req.seq
end

function CharacterState:requestRefresh(domain, priority, opts)
    opts = opts or {}
    local t = opts.now or self.clock()
    local prio = priority or 'normal'
    local reason = opts.reason or 'requestRefresh'
    local force = (opts.force == true)
    local coalesce = (opts.coalesce == true)

    if domain == 'all' then
        local ok1 = self:requestRefresh('soul', prio, opts)
        local ok2 = self:requestRefresh('progression', prio, opts)
        return ok1 or ok2
    end

    -- Equipment refreshes ride on progression (OXTL META returns authoritative main/ranged weapon skill)
    if domain == 'equipment' then
        domain = 'progression'
    end

    local d = self._state.domains[domain]
    if not d then return false, 'unknown_domain' end

    -- Skip network traffic if domain is fresh and not forced (zero tab-switch storms!)
    if not force then
        local f = self:getFreshness(domain, t)
        if f and f.fresh and f.confirmed and not self._state.effective.levelMismatch then
            return false, 'fresh'
        end
    end

    -- Deduplicate if a request for this domain is already in flight
    if self._in_flight[domain] then
        self._diag.dedupedRequests = self._diag.dedupedRequests + 1
        if self.data_service then self.data_service:record_metric('deduped_requests', 1) end
        return false, 'in_flight_deduped'
    end

    -- Coalesced or zoning requests enter the priority queue instead of firing immediately
    if coalesce or self._state.session.zoning then
        local existing = self._pending_queue[domain]
        local readyAt = t + (coalesce and self.coalesce_window or 0)
        if existing then
            if (PRIORITY_RANK[prio] or 2) > (PRIORITY_RANK[existing.priority] or 2) then
                existing.priority = prio
            end
            existing.force = existing.force or force
            existing.reason = reason
            self._diag.dedupedRequests = self._diag.dedupedRequests + 1
            if self.data_service then self.data_service:record_metric('deduped_requests', 1) end
        else
            self._pending_queue[domain] = {
                priority = prio,
                force    = force,
                reason   = reason,
                readyAt  = readyAt,
            }
        end
        return true, 'queued'
    end

    return self:_dispatch_domain_request(domain, prio, reason, t)
end

-- Mark an in-flight domain request completed and compute latency/stale rejection.
function CharacterState:_complete_domain_sync(domain, meta, now)
    meta = meta or {}
    local t = now or self.clock()
    local d = self._state.domains[domain]
    if not d then return true end

    -- Session / Zone / Sequence correlation check: reject stale cross-session/zone responses!
    if meta.sessionGen ~= nil and meta.sessionGen ~= self._session_gen then
        self._diag.droppedStaleResponses = self._diag.droppedStaleResponses + 1
        if self.data_service then self.data_service:record_metric('stale_dropped', 1) end
        self:_record_diag_event('stale_drop', string.format('%s sessionGen %s != %s', domain, tostring(meta.sessionGen), tostring(self._session_gen)))
        return false, 'stale_session'
    end
    if meta.zoneGen ~= nil and meta.zoneGen ~= self._zone_gen then
        self._diag.droppedStaleResponses = self._diag.droppedStaleResponses + 1
        if self.data_service then self.data_service:record_metric('stale_dropped', 1) end
        self:_record_diag_event('stale_drop', string.format('%s zoneGen %s != %s', domain, tostring(meta.zoneGen), tostring(self._zone_gen)))
        return false, 'stale_zone'
    end
    local inflight = self._in_flight[domain]
    if meta.reqSeq ~= nil and inflight and meta.reqSeq ~= inflight.seq then
        self._diag.droppedStaleResponses = self._diag.droppedStaleResponses + 1
        if self.data_service then self.data_service:record_metric('stale_dropped', 1) end
        self:_record_diag_event('stale_drop', string.format('%s reqSeq %s != %s', domain, tostring(meta.reqSeq), tostring(inflight.seq)))
        return false, 'stale_seq'
    end

    local latencyMs = nil
    local retries = 0
    if inflight then
        latencyMs = math.max(0, (t - (inflight.sentAt or t)) * 1000)
        retries = inflight.retries or 0
        self._in_flight[domain] = nil
    end

    d.loading = false
    d.pendingRequests = 0
    d.confirmed = true
    d.fresh = true
    d.state = 'fresh'
    d.lastSyncAt = t
    d.error = nil
    d.retries = retries
    d.revision = d.revision + 1
    if latencyMs ~= nil then
        d.lastLatencyMs = latencyMs
        self._diag.lastLatencyMsByDomain[domain] = latencyMs
    end
    if tonumber(meta.responseBytes) then
        d.lastResponseBytes = tonumber(meta.responseBytes)
        self._diag.lastResponseBytesByDom[domain] = d.lastResponseBytes
    end
    self._diag.totalSyncSuccesses = self._diag.totalSyncSuccesses + 1
    if self.data_service and self.data_service.record_sync_diag then
        self.data_service:record_sync_diag({
            completedAt     = t,
            reqId           = inflight and inflight.seq or (meta.reqSeq or 0),
            domain          = domain,
            op              = meta.op or domain,
            outcome         = 'ok',
            latencyMs       = latencyMs or 0,
            bytesIn         = d.lastResponseBytes or 0,
            retries         = retries,
            cacheHit        = meta.cacheHit == true,
            protocolVersion = meta.protocolVersion or 2,
        })
    end
    return true
end

function CharacterState:reportDomainError(domain, errorMsg, opts)
    opts = opts or {}
    local t = opts.now or self.clock()
    local d = self._state.domains[domain]
    if not d then return end

    local inflight = self._in_flight[domain]
    if opts.retryable == true and inflight and (inflight.retries or 0) < self.max_retries then
        inflight.retries = (inflight.retries or 0) + 1
        local backoff = self.backoff_schedule[inflight.retries] or self.backoff_schedule[#self.backoff_schedule] or 2.5
        inflight.nextRetryAt = t + backoff
        d.retries = inflight.retries
        d.error = tostring(errorMsg or 'Server busy; retrying...')
        self._diag.totalRetries = self._diag.totalRetries + 1
        if self.data_service then self.data_service:record_metric('sync_retries', 1) end
        self:_record_diag_event('retry_scheduled', string.format('%s retry #%d in %.1fs (%s)', domain, inflight.retries, backoff, d.error))
        self:_bump_and_notify('retry:' .. domain)
        return
    end

    self._in_flight[domain] = nil
    d.loading = false
    d.pendingRequests = 0
    d.fresh = false
    d.state = 'error'
    d.error = tostring(errorMsg or 'Synchronization failed.')
    self._diag.totalSyncFailures = self._diag.totalSyncFailures + 1
    if self.data_service and self.data_service.record_sync_diag then
        self.data_service:record_sync_diag({
            completedAt   = t,
            reqId         = inflight and inflight.seq or 0,
            domain        = domain,
            op            = inflight and inflight.reason or domain,
            outcome       = 'error',
            retries       = inflight and inflight.retries or 0,
            timeoutReason = d.error,
        })
    end
    self:_bump_and_notify('error:' .. domain)
end

-- ---------------------------------------------------------------------------
-- Authoritative Domain Updaters (Server Confirmation & Transactions)
-- ---------------------------------------------------------------------------
function CharacterState:applySoulConfirmation(payload, opts)
    opts = opts or {}
    if type(payload) ~= 'table' then return false, 'invalid_payload' end
    local t = opts.now or self.clock()

    local okCorr, corrErr = self:_complete_domain_sync('soul', {
        sessionGen      = payload.sessionGen or opts.sessionGen,
        zoneGen         = payload.zoneGen or opts.zoneGen,
        reqSeq          = payload.reqSeq or opts.reqSeq,
        responseBytes   = payload.responseBytes or opts.responseBytes,
        op              = payload.op or 'crys_state',
        cacheHit        = payload.cacheHit,
        protocolVersion = 1,
    }, t)
    if not okCorr then return false, corrErr end

    local cs = self._state.confirmed.soul
    local prevBranch = cs.activeBranch
    local prevJob    = cs.jobId

    local jobId = tonumber(payload.jobId or payload.job) or self._state.observed.mainJob or cs.jobId or 0
    local branch = tonumber(payload.activeBranch or payload.active) or 0
    local ownedMask = tonumber(payload.ownedMask or payload.owned_mask) or 0
    local level = tonumber(payload.level) or cs.level or 0

    local meta = (branch > 0) and self:_resolve_soul_meta(jobId, branch, payload.activeSoulKey) or nil
    local unlocked = {}
    local available = {}
    for b = 1, 3 do
        local isOwned = owns_branch(ownedMask, b)
        if isOwned then
            unlocked[#unlocked + 1] = b
        end
        local sMeta = self:_resolve_soul_meta(jobId, b, nil)
        if sMeta then
            available[#available + 1] = {
                branch       = b,
                id           = sMeta.id,
                key          = sMeta.internalKey or sMeta.canonicalKey,
                name         = sMeta.displayName or sMeta.name,
                abbr         = sMeta.abbreviation,
                role         = sMeta.roleLabel or sMeta.roleCategory,
                roleCategory = sMeta.roleCategory,
                owned        = isOwned,
                active       = (branch == b),
            }
        end
    end

    cs.jobId                  = jobId
    cs.jobKey                 = JOB_NAMES[jobId] or cs.jobKey
    cs.level                  = level
    cs.activeBranch           = branch
    cs.activeSoulId           = meta and meta.id or nil
    cs.activeSoulKey          = meta and (meta.internalKey or meta.canonicalKey) or (branch == 0 and 'base' or nil)
    cs.activeSoulName         = meta and (meta.displayName or meta.name) or (branch == 0 and 'Base' or nil)
    cs.activeSoulAbbr         = meta and meta.abbreviation or cs.jobKey
    cs.activeSoulRole         = meta and (meta.roleLabel or meta.roleCategory) or nil
    cs.activeSoulRoleCategory = meta and meta.roleCategory or nil
    cs.ownedMask              = ownedMask
    cs.unlockedBranches       = unlocked
    cs.availableSouls         = available
    cs.loaded                 = true
    cs.lastResult             = tonumber(payload.result) or 0
    cs.status                 = 'ready'
    cs.message                = tostring(payload.message or 'Soul state confirmed.')
    cs.revision               = cs.revision + 1

    -- Confirm any active soul_socket transaction
    if self._state.transactions.active.soul_socket then
        self:confirmTransaction('soul_socket', { branch = branch, jobId = jobId }, t)
    end

    -- If active Soul branch changed, progression/talents depend on active Soul -> invalidate & coalesce refresh!
    local soulChanged = (prevJob > 0 and prevJob == jobId and prevBranch ~= branch)
        or (prevBranch ~= branch and self._state.confirmed.progression.synced)
    self:_bump_and_notify('soul_confirmed')
    if soulChanged then
        self:invalidate('progression', 'soul_socket_changed', t)
        self:requestRefresh('progression', 'high', { reason = 'soul_socket_changed', coalesce = true, now = t })
    end
    return true
end

function CharacterState:observeHudBranch(branch, job_id, now)
    local b = tonumber(branch) or 0
    local j = tonumber(job_id) or self._state.observed.mainJob or 0
    local cs = self._state.confirmed.soul
    if cs.hudBranch == b and cs.hudJob == j then
        return false
    end
    cs.hudBranch = b
    cs.hudJob = j
    local changedMismatch = cs.loaded and cs.jobId == j and cs.activeBranch ~= b
    self:_bump_and_notify('hud_branch')
    if changedMismatch then
        self:invalidate('soul', 'hud_branch_mismatch', now)
        self:requestRefresh('soul', 'normal', { reason = 'hud_branch_mismatch', coalesce = true, now = now })
    end
    return true
end

function CharacterState:observeHudTelemetry(soulKey, kv, now)
    local t = now or self.clock()
    local hud = self._state.confirmed.hud
    hud.soulKey = tostring(soulKey or '')
    hud.kv = type(kv) == 'table' and deep_clone(kv, false) or {}
    hud.syncedAt = t
    hud.revision = hud.revision + 1
    local d = self._state.domains.hud
    d.state = 'fresh'
    d.fresh = true
    d.confirmed = true
    d.lastSyncAt = t
    d.revision = d.revision + 1
    self:_bump_and_notify('hud_telemetry')
    return true
end

function CharacterState:applyProgressionConfirmation(payload, opts)
    opts = opts or {}
    if type(payload) ~= 'table' then return false, 'invalid_payload' end
    local t = opts.now or self.clock()

    local okCorr, corrErr = self:_complete_domain_sync('progression', {
        sessionGen      = payload.sessionGen or opts.sessionGen,
        zoneGen         = payload.zoneGen or opts.zoneGen,
        reqSeq          = payload.reqSeq or opts.reqSeq,
        responseBytes   = payload.responseBytes or opts.responseBytes,
        op              = payload.op or 'oxtl_meta',
        cacheHit        = payload.cacheHit,
        protocolVersion = payload.protocolVersion or 2,
    }, t)
    if not okCorr then return false, corrErr end

    local cp = self._state.confirmed.progression
    local ce = self._state.confirmed.equipment

    if type(payload.jobKey) == 'string' and payload.jobKey ~= '' then
        cp.jobKey = payload.jobKey
    end
    if tonumber(payload.jobLevel) and tonumber(payload.jobLevel) > 0 then
        cp.jobLevel = tonumber(payload.jobLevel)
    end
    if type(payload.specKey) == 'string' and payload.specKey ~= '' then
        cp.specKey = payload.specKey
    end
    if type(payload.specName) == 'string' and payload.specName ~= '' then
        cp.specName = payload.specName
    end

    -- Separate talent point ledgers by progression system
    local wmPts = cp.talentPoints.weaponMastery
    if payload.avail ~= nil then wmPts.available = tonumber(payload.avail) or 0 end
    if payload.spent ~= nil then wmPts.spent = tonumber(payload.spent) or 0 end
    if payload.earned ~= nil then wmPts.earned = tonumber(payload.earned) or (wmPts.available + wmPts.spent) end

    if type(payload.soulTalentPoints) == 'table' then
        local stPts = cp.talentPoints.soulTalents
        stPts.available = tonumber(payload.soulTalentPoints.available) or stPts.available
        stPts.spent     = tonumber(payload.soulTalentPoints.spent) or stPts.spent
        stPts.earned    = tonumber(payload.soulTalentPoints.earned) or stPts.earned
    end

    if type(payload.wsSpent) == 'table' then
        cp.wsSpentById = {}
        local mastered = {}
        for wid, pts in pairs(payload.wsSpent) do
            local idNum = tonumber(wid)
            local pNum = tonumber(pts) or 0
            if idNum and pNum > 0 then
                cp.wsSpentById[idNum] = pNum
                local wsMeta = self.data_service and self.data_service:get_weapon_skill(idNum)
                mastered[#mastered + 1] = {
                    wsId  = idNum,
                    name  = wsMeta and wsMeta.name or ('WS #' .. tostring(idNum)),
                    skill = wsMeta and wsMeta.skillId or 0,
                    spent = pNum,
                }
            end
        end
        table.sort(mastered, function(a, b)
            if a.spent ~= b.spent then return a.spent > b.spent end
            return a.wsId < b.wsId
        end)
        cp.masteredWeaponSkills = mastered
        cp.masterySlotsUsed = #mastered
    end

    if type(payload.wsUnlocked) == 'table' then
        cp.wsUnlockedById = {}
        local cnt = 0
        for wid, v in pairs(payload.wsUnlocked) do
            local idNum = tonumber(wid)
            if idNum and v then
                cp.wsUnlockedById[idNum] = true
                cnt = cnt + 1
            end
        end
        cp.unlockedWsCount = cnt
    end

    if payload.mainSkill ~= nil or payload.rangedSkill ~= nil then
        local mSk = tonumber(payload.mainSkill) or ce.mainSkill or 0
        local rSk = tonumber(payload.rangedSkill) or ce.rangedSkill or 0
        ce.mainSkill = mSk
        ce.rangedSkill = rSk
        ce.equippedSummary = format_equipped_summary(mSk, rSk)
        ce.revision = ce.revision + 1
        cp.wsEligibility.mainSkill = mSk
        cp.wsEligibility.rangedSkill = rSk
        cp.wsEligibility.serverConfirmed = true

        local de = self._state.domains.equipment
        de.state = 'fresh'
        de.fresh = true
        de.confirmed = true
        de.lastSyncAt = t
        de.revision = de.revision + 1
    end

    if payload.protocolVersion then
        cp.protocolVersion = tonumber(payload.protocolVersion) or cp.protocolVersion
    end
    cp.synced = true
    cp.revision = cp.revision + 1

    self:_bump_and_notify('progression_confirmed')
    return true
end

-- ---------------------------------------------------------------------------
-- Reliable Transactions (Phase 7) — Never Optimistically Grant Permanent Ranks
-- ---------------------------------------------------------------------------
function CharacterState:beginTransaction(kind, domain, target, now)
    local t = now or self.clock()
    self._tx_seq = self._tx_seq + 1
    local key = tostring(kind)
    local tx = {
        id         = self._tx_seq,
        kind       = key,
        domain     = tostring(domain or 'progression'),
        target     = deep_clone(target or {}, false),
        state      = 'pending',
        sentAt     = t,
        sessionGen = self._session_gen,
        zoneGen    = self._zone_gen,
        error      = nil,
    }
    self._state.transactions.active[key] = tx
    self:_bump_and_notify('tx_begin:' .. key)
    return tx.id
end

function CharacterState:confirmTransaction(kind, resultMeta, now)
    local key = tostring(kind)
    local tx = self._state.transactions.active[key]
    if not tx then return false end
    tx.state = 'confirmed'
    tx.completedAt = now or self.clock()
    tx.result = deep_clone(resultMeta or {}, false)
    self._state.transactions.active[key] = nil
    self._state.transactions.last = tx
    self:_bump_and_notify('tx_confirm:' .. key)
    return true
end

function CharacterState:rejectTransaction(kind, errorMsg, now)
    local key = tostring(kind)
    local tx = self._state.transactions.active[key]
    if not tx then return false end
    tx.state = 'rejected'
    tx.completedAt = now or self.clock()
    tx.error = tostring(errorMsg or 'Transaction rejected by server.')
    self._state.transactions.active[key] = nil
    self._state.transactions.last = tx
    self:_bump_and_notify('tx_reject:' .. key)
    return true
end

function CharacterState:getPendingTransaction(domain)
    for _, tx in pairs(self._state.transactions.active) do
        if domain == nil or tx.domain == domain then
            return deep_clone(tx, true)
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Session Lifecycle & Reset (Logout, Character Switch, Disconnect, Reload)
-- ---------------------------------------------------------------------------
function CharacterState:resetSession(reason, now)
    self._session_gen = self._session_gen + 1
    self._zone_gen = self._zone_gen + 1
    self._in_flight = {}
    self._pending_queue = {}
    self._state = self:_build_empty_session_state(self._session_gen, self._zone_gen)
    self:_sync_cache_summary()
    self:_recompute_effective()
    self:_record_diag_event('session_reset', string.format('gen=%d reason=%s', self._session_gen, tostring(reason or 'reset')))
    for _, hook in ipairs(self._session_reset_hooks) do
        pcall(hook, reason, self._session_gen, now or self.clock())
    end
    self:_bump_and_notify('session_reset:' .. tostring(reason or ''))
    return self._session_gen
end

-- ---------------------------------------------------------------------------
-- Runtime Observation & Packet Events (Phase 3)
-- ---------------------------------------------------------------------------
function CharacterState:observeRuntime(ctx, now)
    local t = now or self.clock()
    if type(ctx) ~= 'table' or ctx.inSession == false then
        if self._state.session.active then
            self:resetSession('session_ended', t)
            self._state.domains.identity.state = 'offline'
            self:_bump_and_notify('offline')
        end
        return false
    end

    local charId = tonumber(ctx.characterId) or 0
    local name   = (type(ctx.name) == 'string' and ctx.name ~= '') and ctx.name or nil
    if charId < 1 or not name then
        return false
    end

    local obs = self._state.observed
    -- Character switch or fresh login after logout: reset all session-scoped state!
    local switchedChar = (obs.characterId > 0 and (obs.characterId ~= charId or (obs.name ~= nil and obs.name ~= name)))
    if switchedChar then
        self:resetSession('character_switched', t)
        obs = self._state.observed
    end

    local wasActive = self._state.session.active
    local prevJob   = obs.mainJob
    local prevLvl   = obs.mainLevel
    local prevSub   = obs.subJob
    local prevSubL  = obs.subLevel
    local prevZone  = obs.zone
    local prevDead  = obs.isDead
    local prevEqSig = obs.equipment.signature

    local changed = false
    local function set_obs(k, v)
        if v ~= nil and obs[k] ~= v then
            obs[k] = v
            changed = true
        end
    end

    set_obs('characterId', charId)
    set_obs('name', name)
    if ctx.targetIndex ~= nil then set_obs('targetIndex', tonumber(ctx.targetIndex) or 0) end
    if ctx.mainJob ~= nil and tonumber(ctx.mainJob) > 0 then
        local mj = tonumber(ctx.mainJob)
        set_obs('mainJob', mj)
        set_obs('mainJobKey', JOB_NAMES[mj])
    end
    if ctx.mainLevel ~= nil and tonumber(ctx.mainLevel) > 0 then
        set_obs('mainLevel', tonumber(ctx.mainLevel))
    end
    if ctx.subJob ~= nil then
        local sj = tonumber(ctx.subJob) or 0
        set_obs('subJob', sj)
        set_obs('subJobKey', sj > 0 and JOB_NAMES[sj] or nil)
    end
    if ctx.subLevel ~= nil then
        set_obs('subLevel', tonumber(ctx.subLevel) or 0)
    end
    if ctx.nation ~= nil then
        local nat = tonumber(ctx.nation)
        set_obs('nation', nat)
        set_obs('nationName', nat ~= nil and NATION_NAMES[nat] or nil)
    end
    if ctx.zone ~= nil and tonumber(ctx.zone) > 0 then
        set_obs('zone', tonumber(ctx.zone))
    end
    if ctx.zoneName ~= nil then
        set_obs('zoneName', tostring(ctx.zoneName))
    end
    if ctx.isDead ~= nil then
        set_obs('isDead', ctx.isDead == true)
    end
    set_obs('inSession', true)
    obs.observedAt = t

    local eqChanged = false
    if type(ctx.equipment) == 'table' then
        local nextEq = {
            mainHand = make_equip_slot(ctx.equipment.mainHand),
            subHand  = make_equip_slot(ctx.equipment.subHand),
            ranged   = make_equip_slot(ctx.equipment.ranged),
        }
        nextEq.signature = equip_signature(nextEq)
        if nextEq.signature ~= prevEqSig then
            obs.equipment = nextEq
            eqChanged = true
            changed = true
        end
    end

    local sess = self._state.session
    if not sess.active then
        sess.active = true
        sess.sessionKey = string.format('%d:%s:%d', charId, name, self._session_gen)
        changed = true
    end

    local di = self._state.domains.identity
    di.state = 'fresh'
    di.fresh = true
    di.confirmed = true
    di.lastSyncAt = t
    if changed then
        di.revision = di.revision + 1
    end

    if not changed and wasActive then
        return false
    end

    local jobChanged  = (prevJob > 0 and obs.mainJob > 0 and obs.mainJob ~= prevJob)
    local lvlChanged  = (prevLvl > 0 and obs.mainLevel > 0 and obs.mainLevel ~= prevLvl)
    local subChanged  = (prevSub ~= obs.subJob) or (prevSubL ~= obs.subLevel)
    local zoneChanged = (prevZone > 0 and obs.zone > 0 and obs.zone ~= prevZone)
    local deadChanged = (prevDead ~= obs.isDead)

    self:_bump_and_notify('runtime_observed')

    -- Trigger coalesced server refreshes ONLY when relevant gameplay context changed!
    if (not wasActive) or switchedChar then
        self:requestRefresh('soul', 'high', { reason = 'login', coalesce = true, now = t })
        if self._visible_domains.progression then
            self:requestRefresh('progression', 'high', { reason = 'login', coalesce = true, now = t })
        end
    elseif jobChanged then
        self:invalidate({ 'soul', 'progression', 'equipment' }, 'job_change', t)
        self:requestRefresh('soul', 'high', { reason = 'job_change', coalesce = true, force = true, now = t })
        self:requestRefresh('progression', 'high', { reason = 'job_change', coalesce = true, force = true, now = t })
    elseif lvlChanged then
        -- Immediate display update already applied above; coalesce ONE server confirmation!
        self:invalidate({ 'soul', 'progression' }, 'level_change', t)
        self:requestRefresh('progression', 'high', { reason = 'level_change', coalesce = true, force = true, now = t })
        self:requestRefresh('soul', 'normal', { reason = 'level_change', coalesce = true, force = true, now = t })
    elseif eqChanged then
        self:invalidate({ 'equipment', 'progression' }, 'equipment_change', t)
        self:requestRefresh('progression', 'high', { reason = 'equipment_change', coalesce = true, force = true, now = t })
    elseif zoneChanged then
        self._zone_gen = self._zone_gen + 1
        self._state.session.zoneGeneration = self._zone_gen
        self:invalidate({ 'soul', 'progression' }, 'zone_change', t)
        self:requestRefresh('soul', 'normal', { reason = 'zone_change', coalesce = true, now = t })
    elseif subChanged then
        self:_record_diag_event('subjob_change', string.format('%s Lv.%d', tostring(obs.subJobKey or 'NONE'), obs.subLevel or 0))
    elseif deadChanged then
        self:_record_diag_event('life_state', obs.isDead and 'died' or 'revived')
    end

    return true
end

-- Handle raw FFXI/Ashita incoming packets for event-driven updates (no per-frame polling).
function CharacterState:onPacketIn(id, data, size, now)
    local t = now or self.clock()
    local len = type(size) == 'number' and size or (type(data) == 'string' and #data or 0)

    -- 0x00B: Zone Out — enter zoning state, supersede in-flight requests from old zone
    if id == 0x00B then
        self._zone_gen = self._zone_gen + 1
        self._state.session.zoneGeneration = self._zone_gen
        self._state.session.zoning = true
        self._in_flight = {}
        for _, domName in ipairs({ 'soul', 'progression' }) do
            local d = self._state.domains[domName]
            if d then
                d.loading = false
                d.pendingRequests = 0
                d.fresh = false
                if d.state == 'fresh' or d.state == 'loading' then
                    d.state = 'stale'
                end
            end
        end
        self:_record_diag_event('zone_out', 'zoneGen=' .. tostring(self._zone_gen))
        self:_bump_and_notify('zone_out')
        return true
    end

    -- 0x00A: Zone In — leave zoning state, refresh runtime identity & invalidate server domains
    if id == 0x00A then
        self._zone_gen = self._zone_gen + 1
        self._state.session.zoneGeneration = self._zone_gen
        self._state.session.zoning = false
        self._in_flight = {}
        self:invalidate({ 'soul', 'progression', 'equipment' }, 'zone_in', t)
        if type(self.runtime_reader) == 'function' then
            local okR, ctx = pcall(self.runtime_reader)
            if okR and type(ctx) == 'table' then
                self:observeRuntime(ctx, t)
            end
        end
        self:requestRefresh('soul', 'high', { reason = 'zone_in', coalesce = true, now = t })
        if self._visible_domains.progression then
            self:requestRefresh('progression', 'high', { reason = 'zone_in', coalesce = true, now = t })
        end
        return true
    end

    -- 0x061: Char Stats — immediate mainJob (byte 13), mainLvl (14), subJob (15), subLvl (16)
    if id == 0x061 and type(data) == 'string' and len >= 16 then
        local mj, ml, sj, sl = string.byte(data, 13, 16)
        local obs = self._state.observed
        if mj and mj >= 1 and mj <= 22 and ml and ml >= 1 then
            local nat = (len >= 81) and string.byte(data, 81) or obs.nation
            self:observeRuntime({
                inSession   = true,
                characterId = obs.characterId > 0 and obs.characterId or 1,
                name        = obs.name or 'Adventurer',
                mainJob     = mj,
                mainLevel   = ml,
                subJob      = sj or obs.subJob,
                subLevel    = sl or obs.subLevel,
                nation      = nat,
                zone        = obs.zone,
            }, t)
            return true
        end
    end

    -- 0x01B: Job Info — immediate mainJob (byte 9), subJob (13), level table (bytes 17..39)
    if id == 0x01B and type(data) == 'string' and len >= 39 then
        local mj = string.byte(data, 9) or 0
        local sj = string.byte(data, 13) or 0
        if mj >= 1 and mj <= 22 then
            local ml = string.byte(data, 17 + mj) or 0
            local sl = (sj >= 1 and sj <= 22) and (string.byte(data, 17 + sj) or 0) or 0
            local obs = self._state.observed
            if ml >= 1 then
                self:observeRuntime({
                    inSession   = true,
                    characterId = obs.characterId > 0 and obs.characterId or 1,
                    name        = obs.name or 'Adventurer',
                    mainJob     = mj,
                    mainLevel   = ml,
                    subJob      = sj,
                    subLevel    = sl,
                    zone        = obs.zone,
                }, t)
                return true
            end
        end
    end

    -- 0x050: Equip List — slotIndex (byte 5), equipSlot (byte 6), bag (byte 7) (1-based)
    if id == 0x050 and type(data) == 'string' and len >= 7 then
        local equipSlot = string.byte(data, 6)
        if equipSlot == 0 or equipSlot == 1 or equipSlot == 2 then
            if type(self.runtime_reader) == 'function' then
                local okR, ctx = pcall(self.runtime_reader)
                if okR and type(ctx) == 'table' and ctx.inSession then
                    self:observeRuntime(ctx, t)
                end
            end
            self:invalidate({ 'equipment', 'progression' }, 'equip_packet', t)
            self:requestRefresh('progression', 'high', { reason = 'equip_packet', coalesce = true, force = true, now = t })
            return true
        end
    end

    -- 0x01D: Inventory Finish — re-read runtime equipment cleanly after login/zone
    if id == 0x01D then
        if type(self.runtime_reader) == 'function' then
            local okR, ctx = pcall(self.runtime_reader)
            if okR and type(ctx) == 'table' and ctx.inSession then
                self:observeRuntime(ctx, t)
            end
        end
        return true
    end

    -- 0x037: Player Status Update — detect death (2/3) and revival
    if id == 0x037 and type(data) == 'string' and len >= 49 then
        local statusByte = string.byte(data, 49)
        local dead = (statusByte == 2 or statusByte == 3)
        if self._state.observed.inSession and self._state.observed.isDead ~= dead then
            local obs = self._state.observed
            self:observeRuntime({
                inSession   = true,
                characterId = obs.characterId,
                name        = obs.name,
                isDead      = dead,
            }, t)
            return true
        end
    end

    return false
end

function CharacterState:onPacketOut(id, _data, _size, now)
    local t = now or self.clock()
    -- 0x00D: Client Leave / Logout
    if id == 0x00D then
        self:resetSession('logout', t)
        return true
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Bounded Tick: Coalesced Queue Dispatch, Retries, Timeouts & Low-Freq Reconcile
-- ---------------------------------------------------------------------------
function CharacterState:tick(now)
    local t = now or self.clock()

    -- 1. Bounded low-frequency runtime reconciliation (default 1.0s — catches GM level
    --    changes, missed packets, reconnects, and character switches without per-frame work).
    if (t - self._last_reconcile_at) >= self.reconcile_interval then
        self._last_reconcile_at = t
        if type(self.runtime_reader) == 'function' then
            local okR, ctx = pcall(self.runtime_reader)
            if okR and ctx ~= nil then
                self:observeRuntime(ctx, t)
            end
        end
        -- Auto-reconcile observed vs confirmed level mismatch
        if self._state.session.active and not self._state.session.zoning and self._state.effective.levelMismatch then
            if not self._in_flight.progression and not self._pending_queue.progression then
                self:requestRefresh('progression', 'high', { reason = 'level_mismatch_reconcile', coalesce = false, force = true, now = t })
            end
        end
    end

    -- 2. Timeout / retry in-flight domain requests with bounded exponential backoff
    if not self._state.session.zoning then
        for domain, req in pairs(self._in_flight) do
            if req.nextRetryAt ~= nil then
                if t >= req.nextRetryAt then
                    req.nextRetryAt = nil
                    req.sentAt = t
                    local transport = self._transports[domain]
                    if type(transport) == 'function' then
                        self._diag.totalRequestsSent = self._diag.totalRequestsSent + 1
                        pcall(transport, req)
                    end
                end
            elseif (t - (req.sentAt or t)) >= self.request_timeout_sec then
                if (req.retries or 0) < self.max_retries then
                    req.retries = (req.retries or 0) + 1
                    local backoff = self.backoff_schedule[req.retries] or self.backoff_schedule[#self.backoff_schedule] or 2.5
                    req.nextRetryAt = t + backoff
                    local d = self._state.domains[domain]
                    if d then
                        d.retries = req.retries
                        d.error = string.format('Sync delayed; retry %d/%d...', req.retries, self.max_retries)
                    end
                    self._diag.totalRetries = self._diag.totalRetries + 1
                    if self.data_service then self.data_service:record_metric('sync_retries', 1) end
                    self:_record_diag_event('timeout_retry', string.format('%s retry %d/%d', domain, req.retries, self.max_retries))
                    self:_bump_and_notify('timeout_retry:' .. domain)
                else
                    if self.data_service then self.data_service:record_metric('timeouts', 1) end
                    self:reportDomainError(domain, 'Server sync timed out. Press Sync [X] to retry.', { now = t, retryable = false })
                end
            end
        end
    end

    -- 3. Timeout stuck pending transactions so UI never freezes permanently
    for key, tx in pairs(self._state.transactions.active) do
        if (t - (tx.sentAt or t)) >= self.request_timeout_sec then
            tx.state = 'timeout'
            tx.completedAt = t
            tx.error = 'Server confirmation timed out; state preserved at last confirmed values.'
            self._state.transactions.active[key] = nil
            self._state.transactions.last = tx
            if self.data_service then self.data_service:record_metric('timeouts', 1) end
            self:_record_diag_event('tx_timeout', key)
            self:_bump_and_notify('tx_timeout:' .. key)
        end
    end

    -- 4. Drain coalesced priority queue (highest priority first)
    if not self._state.session.zoning and self._state.session.active then
        local ready = {}
        for domain, item in pairs(self._pending_queue) do
            if t >= (item.readyAt or 0) and not self._in_flight[domain] then
                ready[#ready + 1] = {
                    domain   = domain,
                    priority = item.priority,
                    rank     = (PRIORITY_RANK[item.priority] or 2) + (self._visible_domains[domain] and 10 or 0),
                    force    = item.force,
                    reason   = item.reason,
                }
            end
        end
        table.sort(ready, function(a, b) return a.rank > b.rank end)
        for _, item in ipairs(ready) do
            self._pending_queue[item.domain] = nil
            self:_dispatch_domain_request(item.domain, item.priority, item.reason, t)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Developer Diagnostics (Phase 8 — Zero Credentials/Secrets)
-- ---------------------------------------------------------------------------
function CharacterState:getDiagnostics(now)
    local t = now or self.clock()
    local st = self._state
    local subByOwner = {}
    local subCount = 0
    for _, sub in pairs(self._subscriptions) do
        subCount = subCount + 1
        subByOwner[sub.owner] = (subByOwner[sub.owner] or 0) + 1
    end

    local pendingReqs = {}
    for domain, req in pairs(self._in_flight) do
        pendingReqs[domain] = {
            seq        = req.seq,
            sessionGen = req.sessionGen,
            zoneGen    = req.zoneGen,
            priority   = req.priority,
            reason     = req.reason,
            retries    = req.retries,
            ageMs      = math.max(0, (t - (req.sentAt or t)) * 1000),
        }
    end

    local domains = {}
    for name in pairs(st.domains) do
        domains[name] = self:getFreshness(name, t)
    end

    local cacheHits = nil
    if self.data_service and self.data_service.metrics then
        local m = self.data_service.metrics
        cacheHits = {
            catalog = m.cache_hits_catalog or 0,
            ws      = m.cache_hits_ws or 0,
            souls   = m.cache_hits_souls or 0,
        }
    end

    local pendingTx = {}
    for k, tx in pairs(st.transactions.active) do
        pendingTx[k] = {
            id     = tx.id,
            domain = tx.domain,
            ageMs  = math.max(0, (t - (tx.sentAt or t)) * 1000),
        }
    end

    return {
        sessionGeneration        = self._session_gen,
        zoneGeneration           = self._zone_gen,
        sessionActive            = st.session.active,
        zoning                   = st.session.zoning,
        observedJob              = st.observed.mainJobKey,
        observedLevel            = st.observed.mainLevel,
        confirmedSoulLevel       = st.confirmed.soul.level,
        confirmedProgressionLvl  = st.confirmed.progression.jobLevel,
        effectiveLevel           = st.effective.mainLevel,
        effectiveLevelSource     = st.effective.mainLevelSource,
        levelMismatch            = st.effective.levelMismatch,
        soul                     = {
            branch = st.effective.soulBranch,
            key    = st.effective.soulKey,
            name   = st.effective.soulName,
            source = st.effective.soulSource,
        },
        equipment                = {
            mainHand        = st.observed.equipment.mainHand.itemId,
            subHand         = st.observed.equipment.subHand.itemId,
            ranged          = st.observed.equipment.ranged.itemId,
            mainSkill       = st.effective.mainSkill,
            rangedSkill     = st.effective.rangedSkill,
            equippedSummary = st.effective.equippedSummary,
        },
        domains                  = domains,
        pendingRequests          = pendingReqs,
        pendingTransactions      = pendingTx,
        retryCounts              = self._diag.totalRetries,
        syncLatencyMs            = deep_clone(self._diag.lastLatencyMsByDomain, false),
        responseSizes            = deep_clone(self._diag.lastResponseBytesByDom, false),
        cacheHits                = cacheHits,
        droppedStaleResponses    = self._diag.droppedStaleResponses,
        dedupedRequests          = self._diag.dedupedRequests,
        totalRequestsSent        = self._diag.totalRequestsSent,
        totalSyncSuccesses       = self._diag.totalSyncSuccesses,
        totalSyncFailures        = self._diag.totalSyncFailures,
        subscriptionCount        = subCount,
        subscriptionsByOwner     = subByOwner,
        notificationLoopsBlocked = self._diag.notificationLoopsBlocked,
        listenerErrors           = self._diag.listenerErrors,
        recentEvents             = deep_clone(self._diag.lastEvents, false),
    }
end

-- ---------------------------------------------------------------------------
-- Presentation-Agnostic Shared Selectors (Phases 6 & 10)
-- Cleanly consumable by Core UI, Character, Weapon Mastery, Soul Talents,
-- Abilities, Equipment, Journal, Soul HUD, and the Soulforge visual overhaul.
-- ---------------------------------------------------------------------------
local Selectors = {}

function Selectors.selectHeaderIdentity(snap)
    if not snap then return nil end
    local eff = snap.effective or {}
    local ds  = snap.domains or {}
    local syncing = (ds.soul and ds.soul.loading) or (ds.progression and ds.progression.loading) or false
    local syncErr = (ds.soul and ds.soul.error) or (ds.progression and ds.progression.error) or nil
    return {
        player_name       = eff.name or 'Adventurer',
        character_id      = eff.characterId or 0,
        job_key           = eff.mainJobKey or '---',
        main_job          = eff.mainJob or 0,
        job_level         = eff.mainLevel or 0,
        level_source      = eff.mainLevelSource or 'unknown',
        confirmed_level   = eff.confirmedLevel,
        level_mismatch    = eff.levelMismatch == true,
        sub_job_key       = eff.subJobKey,
        sub_level         = eff.subLevel or 0,
        soul_name         = eff.soulName or 'Base',
        soul_abbr         = eff.soulAbbr or eff.mainJobKey or '---',
        soul_key          = eff.soulKey,
        soul_role         = eff.soulRole,
        branch            = eff.soulBranch or 0,
        soul_source       = eff.soulSource or 'unknown',
        zone              = eff.zone or 0,
        syncing           = syncing,
        sync_error        = syncErr,
    }
end

function Selectors.selectCharacterView(snap)
    if not snap then return nil end
    local eff = snap.effective or {}
    local cs  = (snap.confirmed and snap.confirmed.soul) or {}
    local dom = (snap.domains and snap.domains.soul) or {}
    return {
        characterId     = eff.characterId or 0,
        name            = eff.name or 'Adventurer',
        mainJob         = eff.mainJob or 0,
        mainJobKey      = eff.mainJobKey or '---',
        mainLevel       = eff.mainLevel,
        confirmedLevel  = cs.level,
        levelSource     = eff.mainLevelSource,
        subJobKey       = eff.subJobKey,
        subLevel        = eff.subLevel,
        zone            = eff.zone or 0,
        nationName      = eff.nationName,
        activeBranch    = eff.soulBranch or 0,
        soulName        = eff.soulName,
        soulKey         = eff.soulKey,
        soulRole        = eff.soulRole,
        ownedMask       = cs.ownedMask or 0,
        unlockedCount   = #(cs.unlockedBranches or {}),
        eligibility     = eff.soulEligibility,
        loaded          = cs.loaded == true,
        freshnessState  = dom.state or 'unknown',
        syncError       = dom.error,
        pendingSocket   = snap.transactions and snap.transactions.active and snap.transactions.active.soul_socket or nil,
    }
end

function Selectors.selectWeaponMasteryHeader(snap)
    if not snap then return nil end
    local eff = snap.effective or {}
    local cp  = (snap.confirmed and snap.confirmed.progression) or {}
    local dom = (snap.domains and snap.domains.progression) or {}
    local wmPts = (cp.talentPoints and cp.talentPoints.weaponMastery) or { available = 0, spent = 0, earned = 0 }
    local pendingTx = nil
    if snap.transactions and snap.transactions.active then
        for _, tx in pairs(snap.transactions.active) do
            if tx.domain == 'progression' then pendingTx = tx; break end
        end
    end
    return {
        jobKey           = eff.mainJobKey or cp.jobKey or '---',
        jobLevel         = eff.mainLevel,
        confirmedLevel   = cp.synced and cp.jobLevel or nil,
        levelSource      = eff.mainLevelSource or 'unknown',
        levelMismatch    = eff.levelMismatch == true,
        specName         = eff.soulName or cp.specName or 'Base',
        specKey          = eff.soulKey or cp.specKey or 'base',
        soulAbbr         = eff.soulAbbr or eff.mainJobKey or '---',
        availPoints      = wmPts.available or 0,
        spentPoints      = wmPts.spent or 0,
        earnedPoints     = wmPts.earned or 0,
        masterySlotsUsed = cp.masterySlotsUsed or 0,
        masterySlotsMax  = cp.masterySlotsMax or MAX_SPEC_WS_SLOTS,
        mainSkill        = eff.mainSkill or 0,
        rangedSkill      = eff.rangedSkill or 0,
        equippedSummary  = eff.equippedSummary,
        synced           = cp.synced == true,
        freshnessState   = dom.state or 'unknown',
        syncError        = dom.error,
        pendingTx        = pendingTx,
        cacheUsable      = snap.cache and snap.cache.usable == true or false,
        revision         = cp.revision or 0,
    }
end

function Selectors.selectSoulTalentsView(snap)
    if not snap then return nil end
    local wm = Selectors.selectWeaponMasteryHeader(snap)
    local cp = (snap.confirmed and snap.confirmed.progression) or {}
    local hud = (snap.confirmed and snap.confirmed.hud) or {}
    return {
        identity             = Selectors.selectHeaderIdentity(snap),
        weaponMasteryPoints  = (cp.talentPoints and cp.talentPoints.weaponMastery) or { available = 0, spent = 0, earned = 0 },
        soulTalentPoints     = (cp.talentPoints and cp.talentPoints.soulTalents) or { available = 0, spent = 0, earned = 0 },
        masteredWeaponSkills = cp.masteredWeaponSkills or {},
        masterySlotsUsed     = wm.masterySlotsUsed,
        masterySlotsMax      = wm.masterySlotsMax,
        hudSoulKey           = hud.soulKey or '',
        hudKv                = hud.kv or {},
        hudSyncedAt          = hud.syncedAt,
        freshnessState       = wm.freshnessState,
        syncError            = wm.syncError,
    }
end

function Selectors.selectAbilitiesContext(snap)
    if not snap then return nil end
    local eff = snap.effective or {}
    return {
        characterId = eff.characterId or 0,
        mainJob     = eff.mainJob or 0,
        mainJobKey  = eff.mainJobKey or '---',
        mainLevel   = eff.mainLevel,
        soulId      = eff.soulId,
        soulKey     = eff.soulKey,
        soulName    = eff.soulName,
        soulBranch  = eff.soulBranch or 0,
    }
end

function Selectors.selectEquipmentContext(snap)
    if not snap then return nil end
    local eff = snap.effective or {}
    local obsEq = (snap.observed and snap.observed.equipment) or {}
    return {
        mainJob         = eff.mainJob or 0,
        mainJobKey      = eff.mainJobKey or '---',
        mainLevel       = eff.mainLevel,
        soulId          = eff.soulId,
        soulKey         = eff.soulKey,
        mainHand        = obsEq.mainHand,
        subHand         = obsEq.subHand,
        ranged          = obsEq.ranged,
        mainSkill       = eff.mainSkill or 0,
        rangedSkill     = eff.rangedSkill or 0,
        equippedSummary = eff.equippedSummary,
    }
end

function Selectors.selectJournalContext(snap)
    if not snap then return nil end
    local eff = snap.effective or {}
    return {
        characterId = eff.characterId or 0,
        name        = eff.name,
        zone        = eff.zone or 0,
        mainJobKey  = eff.mainJobKey,
        mainLevel   = eff.mainLevel,
        soulName    = eff.soulName,
    }
end

function Selectors.selectSoulHudContext(snap)
    if not snap then return nil end
    local eff = snap.effective or {}
    local hud = (snap.confirmed and snap.confirmed.hud) or {}
    return {
        characterId = eff.characterId or 0,
        mainJob     = eff.mainJob or 0,
        mainJobKey  = eff.mainJobKey,
        mainLevel   = eff.mainLevel,
        soulBranch  = eff.soulBranch or 0,
        soulKey     = eff.soulKey,
        soulName    = eff.soulName,
        hudSoulKey  = hud.soulKey or '',
        hudKv       = hud.kv or {},
        hudSyncedAt = hud.syncedAt,
        active      = snap.session and snap.session.active == true or false,
    }
end

CharacterState.Selectors = Selectors

return CharacterState
