-- SoulspireXI Core: Centralized Reactive Character State Service
--
-- Single source of truth for live character identity & progression state shared across
-- all Core modules (Universal Header, Character, Weapon Mastery / The Soulforge,
-- Soul Talents, and future Abilities / Equipment / Journal).
--
-- Synchronizes in real time without closing the UI or clicking manual Sync:
--   - Actual character level (stored unsynced level for main job)
--   - Effective level under Level Sync / Level Restriction
--   - Main job and subjob (+ subjob level)
--   - Active Soul and canonical role (resolved strictly from DataService verified cache
--     and Registry.souls — zero hardcoded Soul tables)
--   - Equipped main/ranged weapon signatures (for Weapon Mastery filter & eligibility)
--   - Zone / session / reconnect lifecycle transitions

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

local JOB_IDS = {}
for id, key in pairs(JOB_NAMES) do
    JOB_IDS[key] = id
end

CharacterState.JOB_NAMES = JOB_NAMES
CharacterState.JOB_IDS   = JOB_IDS

function CharacterState.job_key(job_id)
    local id = tonumber(job_id) or 0
    return JOB_NAMES[id] or '---'
end

function CharacterState.job_id(job_key)
    if type(job_key) ~= 'string' or job_key == '' then return 0 end
    return JOB_IDS[string.upper(job_key)] or 0
end

local function read_u32_le(str, offset)
    if type(str) ~= 'string' or #str < offset + 3 then return 0 end
    local b1, b2, b3, b4 = str:byte(offset, offset + 3)
    return (b1 or 0) + (b2 or 0) * 256 + (b3 or 0) * 65536 + (b4 or 0) * 16777216
end

local function copy_table(src)
    local out = {}
    for k, v in pairs(src or {}) do
        out[k] = v
    end
    return out
end

local function default_read_memory()
    if not (AshitaCore and AshitaCore.GetMemoryManager) then
        return nil
    end
    local ok, res = pcall(function()
        local mem    = AshitaCore:GetMemoryManager()
        local party  = mem and mem:GetParty()
        local player = mem and mem:GetPlayer()
        if not party or not player then
            return { in_session = false }
        end

        local sid  = party:GetMemberServerId(0) or 0
        local tidx = party:GetMemberTargetIndex(0) or 0
        local name = party:GetMemberName(0)
        local main_job = player:GetMainJob() or 0
        if sid < 1 or tidx == 0 or type(name) ~= 'string' or name == '' or main_job <= 0 then
            return { in_session = false }
        end

        local getMainLvl = player.GetMainJobLevel or player.GetMainLevel
        local eff_lvl = (getMainLvl and getMainLvl(player)) or 0
        if eff_lvl <= 0 and party.GetMemberMainJobLevel then
            eff_lvl = party:GetMemberMainJobLevel(0) or 0
        end

        -- Ashita v4 IPlayer:GetJobLevel(job) returns stored unsynced job level (from 0x01B).
        local stored_lvl = 0
        if player.GetJobLevel then
            local okJL, jl = pcall(player.GetJobLevel, player, main_job)
            if okJL and tonumber(jl) then
                stored_lvl = tonumber(jl)
            end
        end

        local sub_job = (player.GetSubJob and player:GetSubJob()) or 0
        local sub_lvl = (player.GetSubJobLevel and player:GetSubJobLevel()) or 0
        local zone    = (party.GetMemberZone and party:GetMemberZone(0)) or 0

        local main_eq, ranged_eq = '0:0', '0:0'
        local inv = mem.GetInventory and mem:GetInventory()
        if inv and inv.GetEquippedItem then
            local function eq_sig(slot)
                local eq = inv:GetEquippedItem(slot)
                if eq and (eq.Index or 0) > 0 then
                    local idx = eq.Index
                    local bag = math.floor(idx / 256)
                    local slot_idx = idx % 256
                    local item_id = 0
                    if inv.GetContainerItem then
                        local it = inv:GetContainerItem(bag, slot_idx)
                        if it and it.Id then item_id = it.Id end
                    end
                    return string.format('%d:%d', idx, item_id)
                end
                return '0:0'
            end
            main_eq   = eq_sig(0)
            ranged_eq = eq_sig(2)
        end

        return {
            in_session      = true,
            player_name     = name,
            server_id       = sid,
            zone            = zone,
            main_job        = main_job,
            sub_job         = sub_job,
            actual_lvl      = stored_lvl > 0 and stored_lvl or eff_lvl,
            effective_lvl   = eff_lvl > 0 and eff_lvl or stored_lvl,
            sub_lvl         = sub_lvl,
            main_equip_sig  = main_eq,
            ranged_equip_sig = ranged_eq,
        }
    end)
    if not ok then return nil end
    return res
end

function CharacterState.new(opts)
    opts = opts or {}
    local self = setmetatable({
        data_service      = opts.data_service,
        soul_registry     = opts.soul_registry,
        read_memory_fn    = opts.read_memory or default_read_memory,
        clock             = opts.clock or os.clock,
        poll_interval     = tonumber(opts.poll_interval) or 0.25,
        last_poll_at      = -999,
        force_poll_next   = false,
        listeners         = {},
        stored_job_levels = {},

        in_session        = false,
        player_name       = 'Adventurer',
        server_id         = 0,
        zone              = 0,
        main_job          = 0,
        main_job_key      = '---',
        sub_job           = 0,
        sub_job_key       = nil,
        actual_lvl        = 1,
        effective_lvl     = 1,
        is_level_synced   = false,
        sub_lvl           = 0,

        soul_branch       = 0,
        soul_key          = 'base',
        soul_name         = 'Base',
        soul_abbr         = '---',
        soul_role         = 'Base Job',
        soul_icon         = nil,

        main_equip_sig    = '0:0',
        ranged_equip_sig  = '0:0',

        generation        = 0,
        last_change_reason = 'init',
        last_updated_at   = 0,
    }, CharacterState)
    return self
end

function CharacterState:subscribe(fn)
    if type(fn) ~= 'function' then return nil end
    self.listeners[#self.listeners + 1] = fn
    return fn
end

function CharacterState:unsubscribe(fn)
    for i = #self.listeners, 1, -1 do
        if self.listeners[i] == fn then
            table.remove(self.listeners, i)
        end
    end
end

-- Resolve canonical Soul identity strictly from verified DataService cache or Registry.souls.
-- Zero hardcoded Soul definitions, names, IDs, or progression values.
function CharacterState:resolve_soul(job_id, branch_or_key)
    local jid = tonumber(job_id) or self.main_job or 0
    local jkey = CharacterState.job_key(jid)

    if branch_or_key == nil or branch_or_key == 0 or branch_or_key == '' or string.lower(tostring(branch_or_key)) == 'base' then
        return {
            branch = 0,
            key    = 'base',
            name   = 'Base',
            abbr   = jkey,
            role   = 'Base Job',
            icon   = nil,
        }
    end

    local entry = nil
    local as_num = tonumber(branch_or_key)
    if self.data_service and self.data_service:is_cache_usable() then
        if as_num and as_num >= 1 and as_num <= 3 and jid >= 1 and jid <= 22 then
            entry = self.data_service:get_soul_by_job_branch(jid, as_num)
        elseif type(branch_or_key) == 'string' then
            entry = self.data_service:get_soul_by_key(branch_or_key)
        end
    end
    if not entry and self.soul_registry then
        if as_num and as_num >= 1 and as_num <= 3 and jid >= 1 and jid <= 22 and self.soul_registry.byJob then
            entry = self.soul_registry.byJob(jid, as_num)
        elseif type(branch_or_key) == 'string' and self.soul_registry.resolve then
            entry = self.soul_registry.resolve(branch_or_key)
        end
    end

    if entry then
        return {
            branch = tonumber(entry.branchId) or tonumber(entry.branch) or as_num or 0,
            key    = string.lower(tostring(entry.internalKey or entry.canonicalKey or entry.id or 'base')),
            name   = tostring(entry.displayName or entry.name or branch_or_key),
            abbr   = tostring(entry.abbreviation or jkey),
            role   = tostring(entry.roleLabel or entry.roleCategory or 'Soul'),
            icon   = entry.icon,
        }
    end

    -- Fallback preserves unknown server key cleanly without hardcoding Soul tables
    local raw_str = tostring(branch_or_key)
    return {
        branch = as_num or 0,
        key    = string.lower(raw_str),
        name   = raw_str,
        abbr   = jkey,
        role   = 'Soul',
        icon   = nil,
    }
end

function CharacterState:format_level_label()
    local act = math.max(1, tonumber(self.actual_lvl) or 1)
    local eff = math.max(1, tonumber(self.effective_lvl) or act)
    if self.is_level_synced and eff < act then
        return string.format('Lv.%d (Sync %d)', eff, act)
    end
    return string.format('Lv.%d', act)
end

function CharacterState:get_snapshot()
    return {
        in_session         = self.in_session,
        player_name        = self.player_name,
        server_id          = self.server_id,
        zone               = self.zone,
        main_job           = self.main_job,
        main_job_key       = self.main_job_key,
        sub_job            = self.sub_job,
        sub_job_key        = self.sub_job_key,
        actual_lvl         = self.actual_lvl,
        effective_lvl      = self.effective_lvl,
        is_level_synced    = self.is_level_synced,
        sub_lvl            = self.sub_lvl,
        level_label        = self:format_level_label(),
        soul_branch        = self.soul_branch,
        soul_key           = self.soul_key,
        soul_name          = self.soul_name,
        soul_abbr          = self.soul_abbr,
        soul_role          = self.soul_role,
        soul_icon          = self.soul_icon,
        main_equip_sig     = self.main_equip_sig,
        ranged_equip_sig   = self.ranged_equip_sig,
        generation         = self.generation,
        last_change_reason = self.last_change_reason,
        last_updated_at    = self.last_updated_at,
    }
end

function CharacterState:get_header_identity()
    return {
        player_name     = self.player_name,
        job_key         = self.main_job_key,
        job_level       = self.actual_lvl,
        actual_level    = self.actual_lvl,
        effective_level = self.effective_lvl,
        is_level_synced = self.is_level_synced,
        level_label     = self:format_level_label(),
        sub_job_key     = self.sub_job_key,
        sub_level       = self.sub_lvl,
        soul_name       = self.soul_name,
        soul_key        = self.soul_key,
        soul_abbr       = self.soul_abbr,
        soul_role       = self.soul_role,
        branch          = self.soul_branch,
    }
end

function CharacterState:_emit(ev)
    for _, fn in ipairs(self.listeners) do
        pcall(fn, ev, self)
    end
end

function CharacterState:_apply_changes(patch, source, now)
    local ts = now or self.clock()
    local prev = self:get_snapshot()
    local reasons = {}
    local reason_set = {}
    local function add_reason(r)
        if not reason_set[r] then
            reason_set[r] = true
            reasons[#reasons + 1] = r
        end
    end

    local affects_talents  = false
    local affects_crystals = false
    local clear_ws_cache   = false

    -- 1. Session transitions (connect / disconnect / reconnect)
    if patch.in_session ~= nil and patch.in_session ~= self.in_session then
        local was_in = self.in_session
        self.in_session = patch.in_session == true
        if self.in_session and not was_in then
            add_reason(prev.server_id > 0 and 'reconnect' or 'session_start')
            affects_talents  = true
            affects_crystals = true
            clear_ws_cache   = true
        elseif not self.in_session and was_in then
            add_reason(patch.disconnect_reason or 'disconnect')
            clear_ws_cache = true
        end
    end

    if patch.player_name and patch.player_name ~= '' and patch.player_name ~= self.player_name then
        local had_player = (self.server_id > 0)
        self.player_name = patch.player_name
        if had_player then
            add_reason('character_change')
            affects_talents  = true
            affects_crystals = true
            clear_ws_cache   = true
        end
    end

    if patch.server_id ~= nil and patch.server_id > 0 and patch.server_id ~= self.server_id then
        local had_sid = (self.server_id > 0)
        self.server_id = patch.server_id
        if had_sid then
            add_reason('character_change')
            affects_talents  = true
            affects_crystals = true
            clear_ws_cache   = true
        end
    end

    -- 2. Zone changes
    if patch.zone ~= nil and patch.zone > 0 and patch.zone ~= self.zone then
        local had_zone = (self.zone > 0)
        self.zone = patch.zone
        if had_zone then
            add_reason('zone_change')
            affects_talents  = true
            affects_crystals = true
            clear_ws_cache   = true
        end
    end

    -- 3. Main job & subjob transitions
    local job_changed = false
    if patch.main_job ~= nil and patch.main_job >= 1 and patch.main_job <= 22 and patch.main_job ~= self.main_job then
        local had_job = (self.main_job > 0)
        self.main_job = patch.main_job
        self.main_job_key = CharacterState.job_key(self.main_job)
        job_changed = true
        if had_job then
            add_reason('job_change')
            affects_talents  = true
            affects_crystals = true
            clear_ws_cache   = true
            -- Reset active Soul until new job's CRYS / META arrives (prevents stale previous-job Soul!)
            if patch.soul_branch == nil and patch.soul_key == nil then
                local base_soul = self:resolve_soul(self.main_job, 0)
                self.soul_branch = base_soul.branch
                self.soul_key    = base_soul.key
                self.soul_name   = base_soul.name
                self.soul_abbr   = base_soul.abbr
                self.soul_role   = base_soul.role
                self.soul_icon   = base_soul.icon
            end
        elseif self.soul_abbr == '---' then
            self.soul_abbr = self.main_job_key
        end
    end

    if patch.sub_job ~= nil and patch.sub_job ~= self.sub_job then
        local had_job = (prev.main_job > 0)
        self.sub_job = tonumber(patch.sub_job) or 0
        self.sub_job_key = (self.sub_job >= 1 and self.sub_job <= 22) and CharacterState.job_key(self.sub_job) or nil
        if had_job then
            add_reason('subjob_change')
        end
    end

    if patch.sub_lvl ~= nil and patch.sub_lvl ~= self.sub_lvl then
        local had_job = (prev.main_job > 0)
        self.sub_lvl = math.max(0, tonumber(patch.sub_lvl) or 0)
        if had_job then
            add_reason('subjob_level_change')
        end
    end

    -- 4. Actual level vs Effective level (Level Sync)
    local next_act = self.actual_lvl
    local next_eff = self.effective_lvl
    if patch.actual_lvl ~= nil and patch.actual_lvl > 0 then
        next_act = math.floor(patch.actual_lvl)
        if self.main_job > 0 then
            self.stored_job_levels[self.main_job] = next_act
        end
    elseif job_changed and self.stored_job_levels[self.main_job] then
        next_act = self.stored_job_levels[self.main_job]
    end

    if patch.effective_lvl ~= nil and patch.effective_lvl > 0 then
        next_eff = math.floor(patch.effective_lvl)
    elseif patch.actual_lvl ~= nil and patch.actual_lvl > 0 and not self.is_level_synced then
        next_eff = next_act
    elseif job_changed and patch.effective_lvl == nil then
        next_eff = next_act
    end

    -- If effective level exceeds stored level (e.g. just leveled up before 0x01B arrived),
    -- promote actual_lvl immediately so level-ups are reflected with 0ms lag!
    if next_eff > next_act and patch.explicit_actual ~= true then
        next_act = next_eff
        if self.main_job > 0 then
            self.stored_job_levels[self.main_job] = next_act
        end
    end

    local next_synced = (next_act > 0 and next_eff > 0 and next_eff < next_act)
    local prev_act = self.actual_lvl
    local prev_eff = self.effective_lvl
    local prev_synced = self.is_level_synced

    if next_act ~= prev_act or next_eff ~= prev_eff or next_synced ~= prev_synced then
        self.actual_lvl      = next_act
        self.effective_lvl   = next_eff
        self.is_level_synced = next_synced

        if not job_changed and prev.main_job > 0 then
            if next_synced and not prev_synced then
                add_reason('level_sync_on')
                affects_talents = true
            elseif not next_synced and prev_synced then
                add_reason('level_sync_off')
                affects_talents = true
            elseif next_synced and prev_synced and next_eff ~= prev_eff then
                add_reason('level_sync_change')
                affects_talents = true
            end

            if next_act > prev_act then
                add_reason('level_up')
                affects_talents  = true
                affects_crystals = true
            elseif next_act < prev_act then
                add_reason('level_down')
                affects_talents  = true
                affects_crystals = true
            end
        elseif prev.main_job == 0 and self.main_job > 0 then
            add_reason('initial_sync')
        end
    end

    -- 5. Active Soul & Role transitions
    if patch.soul_branch ~= nil or patch.soul_key ~= nil then
        local ref = (patch.soul_key ~= nil and patch.soul_key ~= '') and patch.soul_key or patch.soul_branch
        local resolved = self:resolve_soul(self.main_job, ref)
        if resolved.key ~= self.soul_key or resolved.branch ~= self.soul_branch or resolved.name ~= self.soul_name then
            self.soul_branch = resolved.branch
            self.soul_key    = resolved.key
            self.soul_name   = resolved.name
            self.soul_abbr   = resolved.abbr
            self.soul_role   = resolved.role
            self.soul_icon   = resolved.icon
            if prev.main_job > 0 then
                add_reason('soul_change')
                affects_talents = true
                clear_ws_cache  = true
            end
        end
    end

    -- 6. Weapon equipment changes
    if patch.main_equip_sig ~= nil and patch.main_equip_sig ~= self.main_equip_sig then
        local had_job = (prev.main_job > 0)
        self.main_equip_sig = patch.main_equip_sig
        if had_job then
            add_reason('weapon_change')
            affects_talents = true
        end
    end
    if patch.ranged_equip_sig ~= nil and patch.ranged_equip_sig ~= self.ranged_equip_sig then
        local had_job = (prev.main_job > 0)
        self.ranged_equip_sig = patch.ranged_equip_sig
        if had_job then
            add_reason('weapon_change')
            affects_talents = true
        end
    end

    -- Allow explicit forced event reason (e.g. zone_packet / logout)
    if patch.force_reason then
        add_reason(patch.force_reason)
        if patch.force_affects_talents then affects_talents = true end
        if patch.force_affects_crystals then affects_crystals = true end
        if patch.force_clear_ws_cache then clear_ws_cache = true end
    end

    if #reasons == 0 then
        return nil
    end

    self.generation = self.generation + 1
    self.last_change_reason = table.concat(reasons, ',')
    self.last_updated_at = ts

    local ev = {
        source           = source or 'memory',
        reasons          = reasons,
        reason           = self.last_change_reason,
        affects_talents  = affects_talents,
        affects_crystals = affects_crystals,
        clear_ws_cache   = clear_ws_cache,
        generation       = self.generation,
        at               = ts,
        prev             = prev,
        cur              = self:get_snapshot(),
    }
    self:_emit(ev)
    return ev
end

-- Poll Ashita memory (rate-limited to poll_interval unless force == true or force_poll_next).
-- Runs continuously while in_session EVEN when SoulspireXI Core is closed!
function CharacterState:poll_memory(now, force)
    local ts = now or self.clock()
    if not force and not self.force_poll_next and (ts - self.last_poll_at) < self.poll_interval then
        return nil
    end
    self.last_poll_at = ts
    self.force_poll_next = false

    local mem = self.read_memory_fn and self.read_memory_fn() or nil
    if type(mem) ~= 'table' then
        return nil
    end

    if mem.in_session == false then
        if self.in_session then
            return self:_apply_changes({
                in_session        = false,
                disconnect_reason = 'disconnect',
            }, 'memory', ts)
        end
        return nil
    end

    -- Preserve cached 0x01B stored level if memory only returned effective level
    local main_job = tonumber(mem.main_job) or 0
    local eff_lvl  = tonumber(mem.effective_lvl or mem.main_lvl) or 0
    local act_lvl  = tonumber(mem.actual_lvl) or 0
    if act_lvl <= 0 and main_job > 0 then
        act_lvl = self.stored_job_levels[main_job] or eff_lvl
    end

    return self:_apply_changes({
        in_session       = true,
        player_name      = mem.player_name or mem.name,
        server_id        = tonumber(mem.server_id) or 0,
        zone             = tonumber(mem.zone) or 0,
        main_job         = main_job,
        sub_job          = tonumber(mem.sub_job) or 0,
        actual_lvl       = act_lvl,
        effective_lvl    = eff_lvl,
        sub_lvl          = tonumber(mem.sub_lvl) or 0,
        main_equip_sig   = mem.main_equip_sig,
        ranged_equip_sig = mem.ranged_equip_sig,
    }, 'memory', ts)
end

-- Observe lightweight FFXI S2C packets for sub-frame level, Level Sync, job, and zone updates.
-- Performs zero JSON parsing or heavy work inside packet_in.
function CharacterState:observe_packet_in(id, data, size, now)
    local ts = now or self.clock()
    local len = (type(size) == 'number' and size > 0) and size or (type(data) == 'string' and #data or 0)

    if id == 0x00A or id == 0x00B then
        self.force_poll_next = true
        return self:_apply_changes({
            force_reason           = 'zone_change',
            force_affects_talents  = true,
            force_affects_crystals = true,
            force_clear_ws_cache   = true,
        }, 'packet_zone', ts)
    end

    if type(data) ~= 'string' or len < 8 then
        return nil
    end

    if id == 0x061 and len >= 16 then
        -- CCharStatsPacket: 0x0C=MJob, 0x0D=MLvl (effective), 0x0E=SJob, 0x0F=SLvl (1-based: 13..16)
        local mjob = data:byte(13) or 0
        local mlvl = data:byte(14) or 0
        local sjob = data:byte(15) or 0
        local slvl = data:byte(16) or 0
        if mjob >= 1 and mjob <= 22 and mlvl >= 1 then
            local stored = self.stored_job_levels[mjob]
            local act = stored or self.actual_lvl
            -- When changing jobs via 0x061, use stored level for new job (or mlvl if unknown)
            if mjob ~= self.main_job then
                act = stored or mlvl
            end
            self.force_poll_next = true
            return self:_apply_changes({
                in_session    = true,
                main_job      = mjob,
                sub_job       = sjob,
                actual_lvl    = act,
                effective_lvl = mlvl,
                sub_lvl       = slvl,
            }, 'packet_0x061', ts)
        end
    elseif id == 0x01B and len >= 56 then
        -- CCharJobsPacket: 0x08=MJob (9), 0x0B=SJob (12), 0x20..0x37 (33..56) = stored job levels[0..23]
        local mjob = data:byte(9) or 0
        local sjob = data:byte(12) or 0
        for j = 1, 22 do
            local jl = data:byte(33 + j) or 0
            if jl > 0 then
                self.stored_job_levels[j] = jl
            end
        end
        if mjob >= 1 and mjob <= 22 then
            local stored_m = self.stored_job_levels[mjob] or 0
            if stored_m > 0 then
                self.force_poll_next = true
                return self:_apply_changes({
                    in_session      = true,
                    main_job        = mjob,
                    sub_job         = sjob,
                    actual_lvl      = stored_m,
                    explicit_actual = true,
                }, 'packet_0x01B', ts)
            end
        end
    elseif (id == 0x0DF or id == 0x0DD) and len >= 38 then
        -- CCharUpdate (0x0DF) / CPartyMemberUpdate (0x0DD): 0x04=id (5..8), 0x22=MJob (35), 0x23=MLvl (36), 0x24=SJob (37), 0x25=SLvl (38)
        local pid = read_u32_le(data, 5)
        if self.server_id > 0 and pid == self.server_id then
            local mjob = data:byte(35) or 0
            local mlvl = data:byte(36) or 0
            local sjob = data:byte(37) or 0
            local slvl = data:byte(38) or 0
            if mjob >= 1 and mjob <= 22 and mlvl >= 1 then
                self.force_poll_next = true
                return self:_apply_changes({
                    in_session    = true,
                    main_job      = mjob,
                    sub_job       = sjob,
                    effective_lvl = mlvl,
                    sub_lvl       = slvl,
                }, id == 0x0DF and 'packet_0x0DF' or 'packet_0x0DD', ts)
            end
        end
    elseif id == 0x063 then
        -- Status effects / Level Sync buff changed — trigger immediate memory re-poll next frame
        self.force_poll_next = true
    end

    return nil
end

-- Called when authoritative 0x1FF CRYS state arrives (Character module or passive sync).
function CharacterState:observe_crys_state(job_id, active_branch, lvl, now)
    local jid = tonumber(job_id) or self.main_job or 0
    if jid < 1 or jid > 22 then return nil end
    local patch = {
        main_job    = jid,
        soul_branch = tonumber(active_branch) or 0,
    }
    if tonumber(lvl) and tonumber(lvl) > 0 then
        patch.actual_lvl = tonumber(lvl)
        patch.explicit_actual = true
    end
    return self:_apply_changes(patch, 'crys_state', now)
end

-- Called when 0x1FC Soul HUD identity packet arrives.
function CharacterState:observe_hud_identity(branch, job_id, now)
    local jid = tonumber(job_id) or self.main_job or 0
    if jid < 1 or jid > 22 then return nil end
    return self:_apply_changes({
        main_job    = jid,
        soul_branch = tonumber(branch) or 0,
    }, 'hud_0x1FC', now)
end

-- Reconcile server-authoritative OXTL META reply (source = 'oxtl_meta' prevents feedback loops).
function CharacterState:observe_oxtl_meta(meta, now)
    if type(meta) ~= 'table' then return nil end
    local jid = CharacterState.job_id(meta.jobKey)
    local sjob = CharacterState.job_id(meta.subJobKey)
    local act = tonumber(meta.jobLevel) or 0
    local eff = tonumber(meta.effectiveLevel) or 0
    if eff <= 0 then
        -- Legacy server META without effectiveLevel preserves locally detected Level Sync
        if self.is_level_synced and self.effective_lvl > 0 and self.effective_lvl < act then
            eff = self.effective_lvl
        else
            eff = act
        end
    end
    local patch = {
        actual_lvl      = act > 0 and act or nil,
        effective_lvl   = eff > 0 and eff or nil,
        explicit_actual = act > 0,
        soul_key        = (type(meta.specKey) == 'string' and meta.specKey ~= '') and meta.specKey or (meta.rawSpecKey or meta.specName),
    }
    if jid >= 1 and jid <= 22 then
        patch.main_job = jid
    end
    if meta.subJobKey ~= nil then
        patch.sub_job = sjob
    end
    if meta.subLevel ~= nil then
        patch.sub_lvl = tonumber(meta.subLevel) or 0
    end
    return self:_apply_changes(patch, 'oxtl_meta', now)
end

function CharacterState:invalidate(reason, now)
    local is_logout = (reason == 'logout' or reason == 'disconnect')
    return self:_apply_changes({
        in_session             = is_logout and false or nil,
        disconnect_reason      = reason,
        force_reason           = reason or 'invalidate',
        force_affects_talents  = not is_logout,
        force_affects_crystals = not is_logout,
        force_clear_ws_cache   = true,
    }, 'lifecycle', now)
end

return CharacterState
