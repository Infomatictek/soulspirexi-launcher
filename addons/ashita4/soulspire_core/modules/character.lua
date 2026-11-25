-- SoulspireXI Core Module: Character / Soul Identity
-- Reuses CrystalSocket's authoritative protocol (0x11F/0x1FF CRYS/CRYC), state model,
-- 66-Soul identity registry, sibling crystal PNG assets, and read-only crystaljobs.dll
-- status diagnostics. Never alters native Equipment menu hooks or game balance.

local Character = {}
Character.__index = Character

local JOB_NAMES = {
    [1]  = 'WAR', [2]  = 'MNK', [3]  = 'WHM', [4]  = 'BLM',
    [5]  = 'RDM', [6]  = 'THF', [7]  = 'PLD', [8]  = 'DRK',
    [9]  = 'BST', [10] = 'BRD', [11] = 'RNG', [12] = 'SAM',
    [13] = 'NIN', [14] = 'DRG', [15] = 'SMN', [16] = 'BLU',
    [17] = 'COR', [18] = 'PUP', [19] = 'DNC', [20] = 'SCH',
    [21] = 'GEO', [22] = 'RUN',
}

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Use non-colliding request ID window (0x4000..0x7EFF) so Core never collides with
-- standalone crystalsocket (1..0x3FFF) or soulspire_native.dll native decoder (0x8000..0xFFFF).
local CORE_REQ_BASE = 0x4000
local MAX_SYNC_RETRIES = 2
local RETRY_BACKOFF_SEC = 1.6

function Character.new(opts)
    opts = opts or {}
    local cs_state = opts.crystal_state
    if cs_state and (cs_state.next_request or 0) < CORE_REQ_BASE then
        cs_state.next_request = CORE_REQ_BASE
    end

    return setmetatable({
        protocol        = opts.protocol,
        crystal_state   = cs_state,
        character_state = opts.character_state,
        soul_registry   = opts.soul_registry,
        data_service    = opts.data_service,
        assets        = opts.assets,
        send_packet   = opts.send_packet,
        clock         = opts.clock or os.clock,
        dll_status_fn = opts.dll_status_fn,
        player_ctx_fn = opts.player_ctx_fn,
        region        = 'crystals', -- 'crystals' | 'confirm_socket'
        selected_idx  = 1,
        confirm_btn   = 1,
        confirm_entry = nil,
        sync_retries  = 0,
        retry_after   = nil,
        last_sync_err = nil,
        player_info   = {
            name       = 'Adventurer',
            main_job   = 0,
            main_lvl   = 0,
            sub_job    = 0,
            sub_lvl    = 0,
            zone       = 0,
            server_id  = 0,
        },
        hud_branch    = nil,
        hud_job       = nil,
    }, Character)
end

function Character:_cache_ready()
    return self.data_service ~= nil and self.data_service:is_cache_usable()
end

function Character:_can_socket(snap)
    if not snap or not snap.loaded or snap.pending then return false end
    if self:_cache_ready() then
        local cached = self.data_service:get_souls_for_job(snap.current_job or self.player_info.main_job or 0)
        if type(cached) == 'table' and #cached > 0 then
            return true
        end
    end
    return snap.catalog ~= nil and #(snap.catalog.entries or {}) > 0
end

function Character:_ensure_cached_catalog_in_state(job_id)
    -- Keep crystal_state.catalogs[job_id] populated from verified local cache so
    -- crystal_state:request(OP_SELECT, ...) passes its local catalog presence guard
    -- without ever needing a redundant CRYC catalog flood from the server.
    if not self.crystal_state or not self:_cache_ready() then return false end
    local jid = tonumber(job_id) or self.crystal_state.current_job or self.player_info.main_job or 0
    if jid < 1 or jid > 22 then return false end
    if self.crystal_state.catalogs[jid] and #(self.crystal_state.catalogs[jid].entries or {}) > 0 then
        return true
    end
    local souls = self.data_service:get_souls_for_job(jid)
    if type(souls) ~= 'table' or #souls == 0 then return false end
    local entries = {}
    for i, s in ipairs(souls) do
        entries[i] = {
            id           = s.branchId,
            permanent_id = s.id,
            key          = s.internalKey,
            name         = s.displayName,
            role         = s.roleLabel or s.roleCategory,
            icon         = s.icon,
            req_level    = s.reqLevel or 10,
            description  = s.summary or s.lore or '',
            highlights   = s.highlights or {},
        }
    end
    self.crystal_state.catalogs[jid] = {
        job_id   = jid,
        job_name = JOB_NAMES[jid] or '---',
        entries  = entries,
        source   = 'cache',
    }
    return true
end

function Character:has_modal()
    return self.region == 'confirm_socket' and self.confirm_entry ~= nil
end

function Character:refresh_player_context()
    local info = nil
    if self.character_state and type(self.player_ctx_fn) ~= 'function' then
        local snap = self.character_state:get_snapshot()
        if snap and snap.in_session and (snap.main_job or 0) > 0 then
            info = {
                name            = snap.player_name or 'Adventurer',
                server_id       = snap.server_id or 0,
                zone            = snap.zone or 0,
                main_job        = snap.main_job or 0,
                main_lvl        = snap.actual_lvl or 0,
                actual_lvl      = snap.actual_lvl or 0,
                effective_lvl   = snap.effective_lvl or snap.actual_lvl or 0,
                is_level_synced = snap.is_level_synced == true,
                sub_job         = snap.sub_job or 0,
                sub_lvl         = snap.sub_lvl or 0,
            }
        end
    elseif type(self.player_ctx_fn) == 'function' then
        local ok, res = pcall(self.player_ctx_fn)
        if ok and type(res) == 'table' then info = res end
    elseif AshitaCore and AshitaCore.GetMemoryManager then
        local ok, res = pcall(function()
            local mem    = AshitaCore:GetMemoryManager()
            local party  = mem and mem:GetParty()
            local player = mem and mem:GetPlayer()
            if not party or not player then return nil end
            local sid  = party:GetMemberServerId(0) or 0
            local tidx = party:GetMemberTargetIndex(0) or 0
            local name = party:GetMemberName(0)
            if sid < 1 or tidx == 0 or not name or name == '' then return nil end
            local main_job = player:GetMainJob() or 0
            local eff_lvl  = (player.GetMainJobLevel and player:GetMainJobLevel()) or 0
            local act_lvl  = (player.GetJobLevel and main_job > 0 and player:GetJobLevel(main_job)) or eff_lvl
            if act_lvl <= 0 then act_lvl = eff_lvl end
            return {
                name            = name,
                server_id       = sid,
                zone            = party:GetMemberZone(0) or 0,
                main_job        = main_job,
                main_lvl        = act_lvl,
                actual_lvl      = act_lvl,
                effective_lvl   = eff_lvl > 0 and eff_lvl or act_lvl,
                is_level_synced = (act_lvl > 0 and eff_lvl > 0 and eff_lvl < act_lvl),
                sub_job         = (player.GetSubJob and player:GetSubJob()) or 0,
                sub_lvl         = (player.GetSubJobLevel and player:GetSubJobLevel()) or 0,
            }
        end)
        if ok then info = res end
    end

    if info then
        self.player_info = info
        if self.crystal_state then
            local key = tostring(info.server_id or 0) .. ':' .. tostring(info.name or '')
            self.crystal_state:set_context(key, info.main_job, info.zone, info.actual_lvl or info.main_lvl)
        end
    else
        if self.crystal_state then
            self.crystal_state:set_context(nil, nil, nil, nil)
        end
    end
end

function Character:observe_hud_identity(branch, job_id)
    if type(branch) == 'number' and type(job_id) == 'number' then
        self.hud_branch = branch
        self.hud_job = job_id
        if self.character_state then
            self.character_state:observe_hud_identity(branch, job_id, self.clock())
        end
    end
end

-- Observe incoming 0x1FF CRYS/CRYC packets for Core's request range (0x4000..0x7EFF),
-- and also update active/owned state passively when standalone crystalsocket receives a reply.
function Character:handle_packet_in(id, data, now, size)
    if not self.protocol or not self.crystal_state or id ~= self.protocol.RESPONSE_ID then
        return false
    end
    if type(data) ~= 'string' then return false end
    local pkt = (type(size) == 'number' and size > 0 and size <= #data) and data:sub(1, size) or data
    local decoded = self.protocol.decode_packet(pkt)
    if not decoded then return false end

    if self.data_service then
        self.data_service:record_metric('packets_in_crys', 1)
        self.data_service:record_metric('bytes_in_crys', #pkt)
    end

    local ts = now or self.clock()
    if decoded.request_id >= CORE_REQ_BASE and decoded.request_id < 0x8000 then
        local ok, recv_ok, why = pcall(self.crystal_state.receive, self.crystal_state, pkt, ts)
        if ok and recv_ok then
            if decoded.kind == 'state' then
                if decoded.result == 0 then
                    self.sync_retries = 0
                    self.retry_after = nil
                    self.last_sync_err = nil
                    if self.data_service and self.data_service.listeners and self.data_service.listeners.perf_flow then
                        self.data_service:emit('perf_flow', {
                            flow = 'crystal_sync',
                            phase = 'end',
                            outcome = 'complete',
                            scope = 'client_plus_server_rtt',
                            retries = self.sync_retries or 0,
                        })
                    end
                    if self.character_state then
                        local entry = decoded.entries and decoded.entries[decoded.job + 1]
                        local active_branch = entry and entry.active or 0
                        self.character_state:observe_crys_state(decoded.job, active_branch, decoded.level, ts)
                    end
                elseif decoded.result == 3 and self.sync_retries < MAX_SYNC_RETRIES then
                    -- Server Busy (e.g. concurrent sync): schedule clean bounded retry
                    self.sync_retries = self.sync_retries + 1
                    self.retry_after = ts + RETRY_BACKOFF_SEC
                    self.last_sync_err = 'Server busy; retrying Soul sync...'
                    if self.data_service then
                        self.data_service:record_metric('sync_retries', 1)
                        self.data_service:record_event('crys', 'busy_retry', 'req=' .. tostring(decoded.request_id))
                    end
                else
                    self.last_sync_err = self.crystal_state.message
                end
            end
        elseif self.data_service then
            self.data_service:record_event('crys', 'receive_err', tostring(why or recv_ok))
        end
        return true -- owned by Core
    end

    -- Passive sync if standalone crystalsocket received an authoritative state reply
    if decoded.kind == 'state' and decoded.result == 0 and self.crystal_state.current_job == decoded.job then
        self.crystal_state.all_entries = decoded.entries
        self.crystal_state.accepted = decoded.entries[decoded.job + 1]
        if decoded.level and decoded.level > 0 then
            self.crystal_state.current_lvl = decoded.level
        end
        self.crystal_state.status = 'ready'
        self.crystal_state.message = 'Collection updated.'
        self.sync_retries = 0
        self.retry_after = nil
        self.last_sync_err = nil
        self:_ensure_cached_catalog_in_state(decoded.job)
        if self.character_state then
            local active_branch = self.crystal_state.accepted and self.crystal_state.accepted.active or 0
            self.character_state:observe_crys_state(decoded.job, active_branch, decoded.level, ts)
        end
    end
    return false
end

function Character:tick(now)
    if not self.crystal_state then return end
    local ts = now or self.clock()
    local timed_out = self.crystal_state:tick(ts)
    if timed_out then
        if self.data_service then
            self.data_service:record_metric('timeouts', 1)
            self.data_service:record_event('crys', 'timeout', 'CrystalSocket reply timed out')
        end
        if self.sync_retries < MAX_SYNC_RETRIES then
            self.sync_retries = self.sync_retries + 1
            self.retry_after = ts + RETRY_BACKOFF_SEC
            self.last_sync_err = 'No reply; retrying Soul sync (' .. tostring(self.sync_retries) .. '/' .. tostring(MAX_SYNC_RETRIES) .. ')...'
            if self.data_service then
                self.data_service:record_metric('sync_retries', 1)
            end
        else
            self.last_sync_err = 'Server did not confirm Soul state — press [X] to retry.'
        end
    end
    if self.retry_after and ts >= self.retry_after and not self.crystal_state.pending then
        self.retry_after = nil
        self:sync(false)
    end
end

function Character:get_entries()
    local snap = self.crystal_state and self.crystal_state:snapshot() or {}
    local jobId = snap.current_job or self.player_info.main_job or 0
    local jobKey = JOB_NAMES[jobId] or '---'
    local ownedMask = snap.owned_mask or 0
    local activeBranch = snap.loaded and (snap.active or 0)
        or ((self.hud_job == jobId and self.hud_branch) or 0)

    local entries = {
        {
            branch      = 0,
            key         = 'base',
            name        = 'Base ' .. jobKey,
            abbr        = jobKey,
            role        = 'Base Job',
            roleCategory = 'support',
            icon        = nil,
            req_level   = 1,
            owned       = true,
            active      = (activeBranch == 0),
            description = 'Unsocket your Soul Crystal to return to the classic ' .. jobKey .. ' foundation.',
            highlights  = { 'No Soul Crystal socketed', 'Standard job kit & Weapon Skill Mastery' },
        },
    }

    -- 1. Prefer verified local cache for instant static Soul metadata (descriptions, highlights, icons, roles)
    local cachedSouls = (self:_cache_ready() and jobId >= 1 and jobId <= 22)
        and self.data_service:get_souls_for_job(jobId) or nil
    if cachedSouls and #cachedSouls > 0 then
        for _, cs in ipairs(cachedSouls) do
            local isOwned = snap.loaded and self.protocol and self.protocol.owns(ownedMask, cs.branchId) or false
            local desc = (cs.summary and cs.summary ~= '') and cs.summary or (cs.lore or '')
            local hl = {}
            for _, line in ipairs(cs.highlights or {}) do hl[#hl + 1] = line end
            if #hl == 0 and cs.weaponModeLabel and cs.weaponModeLabel ~= '' then
                hl[1] = 'Weapon Style: ' .. tostring(cs.weaponModeLabel)
            end
            entries[#entries + 1] = {
                id           = cs.id,
                branch       = cs.branchId,
                key          = cs.internalKey,
                name         = cs.displayName,
                abbr         = cs.abbreviation or jobKey,
                role         = cs.roleLabel or cs.roleCategory,
                roleCategory = cs.roleCategory or 'support',
                icon         = cs.icon,
                req_level    = cs.reqLevel or 10,
                owned        = isOwned,
                active       = (activeBranch == cs.branchId),
                description  = desc,
                highlights   = hl,
                source       = 'cache',
            }
        end
        return entries, snap, activeBranch, jobKey
    end

    -- 2. Fallback to server-transmitted CRYC catalog (when cache is missing/corrupt/incompatible)
    local catEntries = snap.catalog and snap.catalog.entries or nil
    if catEntries and #catEntries > 0 then
        for _, ce in ipairs(catEntries) do
            local reg = self.soul_registry and self.soul_registry.resolve and self.soul_registry.resolve(ce.key) or nil
            local isOwned = self.protocol and self.protocol.owns(ownedMask, ce.id) or false
            entries[#entries + 1] = {
                branch       = ce.id,
                key          = ce.key,
                name         = (reg and reg.displayName) or ce.name,
                abbr         = (reg and reg.abbreviation) or jobKey,
                role         = ce.role ~= '' and ce.role or (reg and reg.roleLabel) or 'Soul',
                roleCategory = (reg and reg.roleCategory) or 'support',
                icon         = (reg and reg.icon) or ce.icon,
                req_level    = ce.req_level or 1,
                owned        = isOwned,
                active       = (activeBranch == ce.id),
                description  = ce.description or '',
                highlights   = ce.highlights or {},
                source       = 'server',
            }
        end
    elseif self.soul_registry and self.soul_registry.byJob and jobId >= 1 and jobId <= 22 then
        for b = 1, 3 do
            local reg = self.soul_registry.byJob(jobId, b)
            if reg then
                local isOwned = snap.loaded and self.protocol and self.protocol.owns(ownedMask, b) or false
                entries[#entries + 1] = {
                    branch       = b,
                    key          = reg.internalKey,
                    name         = reg.displayName,
                    abbr         = reg.abbreviation,
                    role         = reg.roleLabel or reg.roleCategory,
                    roleCategory = reg.roleCategory,
                    icon         = reg.icon,
                    req_level    = 10,
                    owned        = isOwned,
                    active       = (activeBranch == b),
                    description  = 'Client cache unavailable; syncing live crystal collection from server...',
                    highlights   = { 'Canonical Role: ' .. tostring(reg.roleLabel or reg.roleCategory) },
                    source       = 'registry_fallback',
                }
            end
        end
    end

    return entries, snap, activeBranch, jobKey
end

function Character:get_header_identity()
    if self.character_state then
        local cs = self.character_state:get_header_identity()
        if cs and cs.job_key and cs.job_key ~= '---' then
            return cs
        end
    end
    local entries, snap, activeBranch, jobKey = self:get_entries()
    local activeName = 'Base'
    local activeAbbr = jobKey
    local activeRole = 'Base Job'
    for _, e in ipairs(entries) do
        if e.branch == activeBranch then
            activeName = e.name
            activeAbbr = e.abbr or jobKey
            activeRole = e.role or 'Base Job'
            break
        end
    end
    local actLvl = snap.current_lvl or self.player_info.actual_lvl or self.player_info.main_lvl or 0
    local effLvl = self.player_info.effective_lvl or actLvl
    local isSynced = (self.player_info.is_level_synced == true) or (actLvl > 0 and effLvl > 0 and effLvl < actLvl)
    return {
        player_name     = self.player_info.name or 'Adventurer',
        job_key         = jobKey,
        job_level       = actLvl,
        actual_level    = actLvl,
        effective_level = effLvl,
        is_level_synced = isSynced,
        level_label     = isSynced and string.format('Lv.%d (Sync %d)', effLvl, actLvl) or string.format('Lv.%d', actLvl),
        sub_job_key     = JOB_NAMES[self.player_info.sub_job or 0],
        sub_level       = self.player_info.sub_lvl or 0,
        soul_name       = activeName,
        soul_abbr       = activeAbbr,
        soul_role       = activeRole,
        branch          = activeBranch,
    }
end

function Character:_send_crystal_packet(packet)
    if self.data_service then
        self.data_service:record_metric('packets_out_crys', 1)
    end
    if type(self.send_packet) == 'function' then
        return self.send_packet(packet)
    end
    if type(packet) ~= 'string' or #packet ~= 16 then
        return nil, 'Invalid crystal packet.'
    end
    if AshitaCore and AshitaCore.GetPacketManager then
        local pm = AshitaCore:GetPacketManager()
        if pm and pm.AddOutgoingPacket then
            pm:AddOutgoingPacket(self.protocol.REQUEST_ID, { packet:byte(1, #packet) })
            return true
        end
    end
    return nil, 'Packet manager unavailable.'
end

function Character:sync(force_catalog)
    self:refresh_player_context()
    if not self.crystal_state then return false end
    self.retry_after = nil
    if self.data_service and self.data_service.listeners and self.data_service.listeners.perf_flow then
        self.data_service:emit('perf_flow', { flow = 'crystal_sync', phase = 'begin', scope = 'client_plus_server_rtt' })
    end
    -- When verified local cache is loaded, send lightweight OP_QUERY (1 packet, zero Busy rate-limit!)
    -- unless legacy server catalog sync is explicitly required.
    if not force_catalog and self:_cache_ready() and self:_ensure_cached_catalog_in_state() then
        return self.crystal_state:request(self.protocol.OP_QUERY, 0, self.clock(), function(pkt)
            return self:_send_crystal_packet(pkt)
        end, self.crystal_state.current_job)
    end
    return self.crystal_state:sync_current(self.clock(), function(pkt)
        return self:_send_crystal_packet(pkt)
    end, force_catalog == true)
end

function Character:select_branch(branch)
    if not self.crystal_state or not self.protocol then return false, 'Unavailable' end
    self:_ensure_cached_catalog_in_state()
    if self.data_service and self.data_service.listeners and self.data_service.listeners.perf_flow then
        self.data_service:emit('perf_flow', { flow = 'soul_switch', phase = 'begin', scope = 'client_plus_server_rtt' })
    end
    return self.crystal_state:request(self.protocol.OP_SELECT, branch, self.clock(), function(pkt)
        return self:_send_crystal_packet(pkt)
    end)
end

function Character:on_open()
    self:refresh_player_context()
    if self.crystal_state then
        if self:_cache_ready() and self:_ensure_cached_catalog_in_state() then
            -- Lightweight OP_QUERY for authoritative ownership & active Soul state
            if not self.crystal_state.pending then
                local snap = self.crystal_state:snapshot()
                if not snap.loaded or self.crystal_state.needs_refresh then
                    self:sync(false)
                end
            end
        else
            self.crystal_state:ensure_loaded(self.clock(), function(pkt)
                return self:_send_crystal_packet(pkt)
            end)
        end
    end
end

function Character:on_activate()
    self:on_open()
    if self.region == 'confirm_socket' then
        self.region = 'crystals'
        self.confirm_entry = nil
    end
end

function Character:on_deactivate()
    self.region = 'crystals'
    self.confirm_entry = nil
end

function Character:on_close()
    self:on_deactivate()
end

function Character:on_action(action)
    local entries, snap = self:get_entries()
    self.selected_idx = clamp(self.selected_idx, 1, math.max(1, #entries))

    if self:has_modal() then
        if action == 'left' or action == 'up' then
            self.confirm_btn = 1
            return true
        elseif action == 'right' or action == 'down' then
            self.confirm_btn = 2
            return true
        elseif action == 'cancel' then
            self.region = 'crystals'
            self.confirm_entry = nil
            return true
        elseif action == 'confirm' then
            local target = self.confirm_entry
            self.region = 'crystals'
            self.confirm_entry = nil
            if self.confirm_btn == 1 and target then
                self:select_branch(target.branch)
            end
            return true
        end
        return true
    end

    if action == 'up' or action == 'left' then
        if #entries > 0 then
            self.selected_idx = ((self.selected_idx - 2) % #entries) + 1
        end
        return true
    elseif action == 'down' or action == 'right' then
        if #entries > 0 then
            self.selected_idx = (self.selected_idx % #entries) + 1
        end
        return true
    elseif action == 'confirm' then
        local e = entries[self.selected_idx]
        if e and self:_can_socket(snap) and e.owned and not e.active then
            self.confirm_entry = e
            self.region = 'confirm_socket'
            self.confirm_btn = 1
        end
        return true
    elseif action == 'context' then
        self.sync_retries = 0
        self:sync(not self:_cache_ready())
        return true
    elseif action == 'cancel' then
        return false -- allow Core to close
    end
    return false
end

function Character:get_hints()
    if self:has_modal() then
        return '[D-Pad] Confirm/Cancel   [A] Socket Soul Crystal   [B] Cancel'
    end
    return '[D-Pad/Stick] Browse Souls   [A] Socket Soul Crystal   [X] Refresh Sync   [LB/RB] Switch Module   [Y] Help   [B] Close'
end

function Character:get_prompt_pills(last_device)
    if self:has_modal() then
        return {
            { 'D-Pad', 'Choose' },
            { 'A',     'Confirm Socket' },
            { 'B',     'Cancel' },
        }
    end
    if last_device == 'keyboard' or last_device == 'mouse' then
        return {
            { 'Arrows', 'Browse Souls' },
            { 'Enter',  'Socket Soul' },
            { 'X',      'Sync Collection' },
            { 'Q/E',    'Switch Module' },
            { 'Esc',    'Close' },
        }
    end
    return {
        { 'D-Pad', 'Browse Souls' },
        { 'A',     'Socket Soul' },
        { 'X',     'Sync Collection' },
        { 'LB/RB', 'Modules' },
        { 'B',     'Close' },
    }
end

function Character:_get_dll_status()
    if type(self.dll_status_fn) == 'function' then
        local ok, st = pcall(self.dll_status_fn)
        return ok and st or nil
    end
    return nil
end

function Character:draw(imgui, dl, F, L, x, y, w, h, ctx)
    self:refresh_player_context()
    self:tick(self.clock())

    local s   = L.uiScale or 1.0
    local gap = L.gap or math.floor(10 * s)
    local pad = math.floor(16 * s)
    local entries, snap, activeBranch, jobKey = self:get_entries()
    self.selected_idx = clamp(self.selected_idx, 1, math.max(1, #entries))
    local focused = entries[self.selected_idx]
    local activeEntry = entries[1]
    for _, e in ipairs(entries) do
        if e.branch == activeBranch then activeEntry = e; break end
    end

    local assetsRef  = self.assets or (ctx and ctx.assets)
    local chamberTex = assetsRef and assetsRef:load_texture('character_chamber_bg') or nil
    local bannerTex  = assetsRef and assetsRef:load_texture('soulforge_banner_bg') or nil
    local browserTex = assetsRef and assetsRef:load_from_addon('soulspire_talents', 'panel_browser') or nil
    local inspTex    = assetsRef and assetsRef:load_from_addon('soulspire_talents', 'panel_inspector') or nil

    -- Top Character Identity Banner matching The Soulforge visual language
    local bannerH = math.floor(((L.mode == 'focused' and 56) or 78) * s)
    F.drawOrnatePanel(dl, x, y, w, bannerH, {
        texId      = bannerTex,
        texTint    = F.abgr(F.rgba.white, 0.80),
        scrimAlpha = 0.34,
        border     = F.u32.soul_gold,
        accent     = F.u32.soul_gold_bright,
        rounding   = 6,
        corners    = true,
        shadow     = false,
    })

    local ownedCount = 0
    for _, e in ipairs(entries) do
        if e.branch > 0 and e.owned then ownedCount = ownedCount + 1 end
    end
    local totalSouls = math.max(0, #entries - 1)

    local subStr = (self.player_info.sub_job and self.player_info.sub_job > 0)
        and (' / ' .. (JOB_NAMES[self.player_info.sub_job] or '---') .. ' Lv.' .. tostring(self.player_info.sub_lvl or 0))
        or ''
    local actLvl = self.player_info.actual_lvl or snap.current_lvl or self.player_info.main_lvl or 0
    local effLvl = self.player_info.effective_lvl or actLvl
    local isSynced = (self.player_info.is_level_synced == true) or (actLvl > 0 and effLvl > 0 and effLvl < actLvl)
    local lvlPart = isSynced and string.format('Lv.%d (Sync %d)', effLvl, actLvl) or string.format('Lv.%d', actLvl)
    local jobLine = string.format('%s %s%s', jobKey, lvlPart, subStr)

    F.drawShadowText(imgui, dl, x + 20 * s, y + 12 * s,
        F.fitText(imgui, self.player_info.name or 'Adventurer', math.floor(w * 0.28), 1.24 * s),
        F.u32.white, 1.24 * s, 'l')
    F.drawShadowText(imgui, dl, x + 20 * s, y + 42 * s, jobLine,
        isSynced and F.u32.aether_cyan or F.u32.soul_gold_bright, 0.94 * s, 'l')

    local midX = x + w * 0.5
    F.drawShadowText(imgui, dl, midX, y + 12 * s, 'SOUL SANCTUM', F.u32.soul_gold_bright, (L.mode == 'focused' and 1.12 or 1.46) * s, 'c')
    if L.mode ~= 'focused' then
        F.drawShadowText(imgui, dl, midX, y + 48 * s, 'CHARACTER IDENTITY & SOUL CRYSTALS', F.u32.soul_gold, 0.80 * s, 'c')
    end

    local syncBtnW = math.floor(114 * s)
    local syncBtnH = math.floor(30 * s)
    if F.drawBeveledCtaButton(imgui, dl, '##ch_sync_btn', x + w - pad - syncBtnW, y + math.floor((bannerH - syncBtnH) * 0.5),
        syncBtnW, syncBtnH, 'SYNC [X]', 'cyan', { fontScale = 0.78 * s }) then
        self.sync_retries = 0
        self:sync(not self:_cache_ready())
    end
    if L.mode ~= 'focused' then
        F.drawShadowText(imgui, dl, x + w - pad - syncBtnW - 18 * s, y + 14 * s,
            'SOULS AWAKENED', F.u32.soul_gold, 0.76 * s, 'r')
        F.drawShadowText(imgui, dl, x + w - pad - syncBtnW - 18 * s, y + 36 * s,
            string.format('%d / %d', ownedCount, totalSouls), F.u32.white, 1.24 * s, 'r')
    end

    local bodyY  = y + bannerH + gap
    local bodyH  = math.max(200, h - bannerH - gap)
    local leftW  = math.floor(w * (L.mode == 'focused' and 0.42 or 0.29))
    local rightW = math.floor(w * (L.mode == 'focused' and 0.00 or 0.31))
    local midW   = math.max(220, w - leftW - rightW - (rightW > 0 and gap * 2 or gap))

    -- 1. Left Panel: Dramatic Character & Active Soul Sanctum Portrait
    F.drawOrnatePanel(dl, x, bodyY, leftW, bodyH, {
        texId      = chamberTex,
        texTint    = F.abgr(F.rgba.white, 0.78),
        scrimAlpha = 0.38,
        border     = F.u32.soul_gold_dim,
        accent     = F.u32.soul_gold_bright,
        corners    = true,
        shadow     = false,
    })

    F.drawShadowText(imgui, dl, x + pad, bodyY + 12 * s, 'ACTIVE SOUL', F.u32.soul_gold_bright, 1.06 * s, 'l')
    F.drawDivider(dl, x + pad, bodyY + 38 * s, leftW - pad * 2, F.u32.soul_gold_dim)

    local medR = math.floor(math.min(58 * s, leftW * 0.24))
    local medX = x + leftW * 0.5
    local medY = bodyY + 58 * s + medR
    local activeTex = (assetsRef and activeEntry and activeEntry.icon)
        and assetsRef:load_from_addon('crystalsocket', activeEntry.icon) or nil

    if F.drawAstralRing then
        F.drawAstralRing(dl, medX, medY, medR * 1.48, { alpha = 0.85 })
    end
    F.drawCrystalMedallion(dl, medX, medY, medR, {
        texId = activeTex,
        rim   = F.u32.soul_gold_bright,
        core  = F.rgba.crystal_violet,
        studs = true,
    })

    local cy = medY + medR + 22 * s
    F.drawShadowText(imgui, dl, medX, cy,
        F.fitText(imgui, activeEntry and activeEntry.name or 'Base', leftW - pad * 2, 1.32 * s),
        F.u32.white, 1.32 * s, 'c')
    cy = cy + 30 * s

    local rolePillW = math.min(leftW - pad * 2, math.floor(290 * s))
    local rolePillText = F.fitText(imgui,
        string.format('%s | [%s]', string.upper(activeEntry and activeEntry.role or 'BASE JOB'), activeEntry and activeEntry.abbr or jobKey),
        rolePillW - 18 * s, 0.78 * s)
    F.drawBadgePill(imgui, dl, medX - math.floor(rolePillW * 0.5), cy, rolePillText, {
            width     = rolePillW,
            height    = math.floor(26 * s),
            fill      = F.abgr(F.rgba.crystal_violet_wash, 0.96),
            border    = F.u32.crystal_violet_bright,
            textCol   = F.u32.white,
            fontScale = 0.78 * s,
        })
    cy = cy + 38 * s

    -- Active Soul summary plaque inside Left Sanctum (strictly bounded)
    local leftCharPx = math.max(9.0 * s, F.measureText(imgui, 'M', 0.82 * s))
    local sumChars = math.max(18, math.floor((leftW - pad * 2 - 28 * s) / leftCharPx))
    local sumLines = F.wrapLines((activeEntry and activeEntry.description) or '', sumChars, 4)
    local sumBoxH = math.floor(20 * s + #sumLines * 18 * s)
    local statusBoxH = math.floor(82 * s)
    local maxSumBottom = bodyY + bodyH - pad - statusBoxH - 12 * s
    if #sumLines > 0 and (cy + sumBoxH) < maxSumBottom then
        dl:AddRectFilled({ x + pad, cy }, { x + leftW - pad, cy + sumBoxH }, F.abgr(F.hex('#0B101E', 0.88)), 5)
        dl:AddRect({ x + pad, cy }, { x + leftW - pad, cy + sumBoxH }, F.abgr(F.rgba.soul_gold_dim, 0.65), 5, 0, 1.0)
        for i, ln in ipairs(sumLines) do
            F.drawShadowText(imgui, dl, medX, cy + 10 * s + (i - 1) * 18 * s,
                F.fitText(imgui, ln, leftW - pad * 2 - 20 * s, 0.80 * s), F.u32.text_primary, 0.80 * s, 'c')
        end
    end

    -- Clean bottom Sync & Native Integration Card
    local boxY = bodyY + bodyH - pad - statusBoxH
    dl:AddRectFilled({ x + pad, boxY }, { x + leftW - pad, boxY + statusBoxH }, F.abgr(F.hex('#080C17', 0.92)), 5)
    dl:AddRect({ x + pad, boxY }, { x + leftW - pad, boxY + statusBoxH }, F.u32.border_strong, 5, 0, 1.1)
    F.drawShadowText(imgui, dl, x + pad + 12 * s, boxY + 10 * s, 'SYNCHRONIZATION', F.u32.aether_cyan, 0.78 * s, 'l')
    local statusLabel
    if snap.loaded then
        statusLabel = self:_cache_ready() and 'Live Authoritative (Verified Cache)' or 'Live Authoritative'
    elseif snap.pending or self.retry_after then
        statusLabel = 'Syncing Soul collection...'
    elseif self.last_sync_err then
        statusLabel = tostring(self.last_sync_err)
    else
        statusLabel = 'Status: ' .. tostring(snap.status or 'offline')
    end
    F.drawShadowText(imgui, dl, x + pad + 12 * s, boxY + 32 * s,
        F.fitText(imgui, statusLabel, leftW - pad * 2 - 24 * s, 0.82 * s),
        snap.loaded and F.u32.success or F.u32.text_secondary, 0.82 * s, 'l')
    local dll = self:_get_dll_status()
    local dllLine = dll and string.format('Soulspire Native: %d hooks active', dll.hooks or 0)
        or 'Soulspire Native: standby'
    F.drawShadowText(imgui, dl, x + pad + 12 * s, boxY + 54 * s,
        F.fitText(imgui, dllLine, leftW - pad * 2 - 24 * s, 0.78 * s),
        dll and F.u32.soul_gold or F.u32.text_muted, 0.78 * s, 'l')

    -- 2. Center Panel: Rich Soul Crystal Cards
    local midPanelX = x + leftW + gap
    local listFocused = (self.region == 'crystals')
    F.drawOrnatePanel(dl, midPanelX, bodyY, midW, bodyH, {
        texId      = browserTex,
        texTint    = F.abgr(F.rgba.white, 0.24),
        scrimAlpha = 0.74,
        border     = listFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent     = listFocused and F.u32.aether_cyan or F.u32.soul_gold,
        thickness  = listFocused and 1.8 or 1.3,
        corners    = true,
        shadow     = false,
    })

    F.drawShadowText(imgui, dl, midPanelX + pad, bodyY + 12 * s,
        listFocused and '> SOUL CRYSTALS' or 'SOUL CRYSTALS',
        listFocused and F.u32.aether_cyan or F.u32.soul_gold_bright, 1.06 * s, 'l')
    F.drawShadowText(imgui, dl, midPanelX + midW - pad, bodyY + 15 * s,
        string.format('%s  |  %d PATHS', jobKey, #entries), F.u32.text_secondary, 0.82 * s, 'r')
    F.drawDivider(dl, midPanelX + pad, bodyY + 38 * s, midW - pad * 2, listFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    local rowW = midW - pad * 2
    local rowGap = math.floor(12 * s)
    local availListH = math.max(200, bodyH - 56 * s)
    local rowH = math.floor(F.clamp((availListH - rowGap * math.max(0, #entries - 1)) / math.max(1, #entries), 84 * s, 128 * s))
    local rowStartY = bodyY + 48 * s

    for i, e in ipairs(entries) do
        local ry = rowStartY + (i - 1) * (rowH + rowGap)
        local isSel = (i == self.selected_idx)
        imgui.SetCursorScreenPos({ midPanelX + pad, ry })
        if imgui.InvisibleButton('##ch_soul_' .. tostring(e.branch), { rowW, rowH }) then
            self.selected_idx = i
            self.region = 'crystals'
            if self:_can_socket(snap) and e.owned and not e.active then
                self.confirm_entry = e
                self.region = 'confirm_socket'
                self.confirm_btn = 1
            end
        end
        local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false

        if isSel or e.active then
            F.drawGradRect(dl, midPanelX + pad, ry, midPanelX + pad + rowW, ry + rowH,
                e.active and F.abgr(F.hex('#443218', 0.94)) or F.abgr(F.hex('#182842', 0.94)),
                F.abgr(F.hex('#0D1322', 0.96)))
        else
            dl:AddRectFilled({ midPanelX + pad, ry }, { midPanelX + pad + rowW, ry + rowH },
                hovered and F.u32.midnight_alt or F.abgr(F.hex('#0C1120', 0.90)), 6)
        end

        local border = (isSel and listFocused) and F.u32.aether_cyan
            or (e.active and F.u32.soul_gold_bright or (e.owned and F.u32.crystal_violet or F.u32.border_subtle))
        dl:AddRect({ midPanelX + pad, ry }, { midPanelX + pad + rowW, ry + rowH }, border, 6, 0, (isSel or e.active) and 2.0 or 1.1)
        if isSel then
            dl:AddRectFilled({ midPanelX + pad + 1, ry + 8 }, { midPanelX + pad + 5, ry + rowH - 8 },
                listFocused and F.u32.aether_cyan or F.u32.soul_gold_bright, 1)
        end

        local icSz = math.floor(math.min(62 * s, rowH - 22 * s))
        local ix, iy = midPanelX + pad + 14 * s, ry + math.floor((rowH - icSz) * 0.5)
        local tex = (assetsRef and e.icon) and assetsRef:load_from_addon('crystalsocket', e.icon) or nil
        F.drawCrystalMedallion(dl, ix + icSz * 0.5, iy + icSz * 0.5, icSz * 0.48, {
            texId = tex,
            rim   = e.active and F.u32.soul_gold_bright or (e.owned and F.u32.crystal_violet_bright or F.u32.border_strong),
            core  = e.owned and F.rgba.crystal_violet or F.rgba.text_muted,
            studs = e.active,
        })

        local tx = ix + icSz + 16 * s
        local rowContentW = math.max(100, rowW - (tx - (midPanelX + pad)) - 22 * s)
        local titleMaxW = math.max(80, rowContentW - 118 * s)
        F.drawShadowText(imgui, dl, tx, ry + 12 * s,
            F.fitText(imgui, e.name, titleMaxW, 1.10 * s),
            e.active and F.u32.soul_gold_bright or (e.owned and F.u32.white or F.u32.text_muted), 1.10 * s, 'l')
        F.drawShadowText(imgui, dl, tx, ry + 38 * s,
            F.fitText(imgui, string.format('%s | %s | Req Lv.%d', e.role or '', e.abbr or jobKey, e.req_level or 1), rowContentW, 0.82 * s),
            F.u32.crystal_violet_bright, 0.82 * s, 'l')

        if rowH >= 88 * s and e.description and e.description ~= '' then
            F.drawShadowText(imgui, dl, tx, ry + 60 * s,
                F.fitText(imgui, e.description, rowContentW, 0.78 * s),
                F.u32.text_secondary, 0.78 * s, 'l')
        end

        local stateTag, stateCol, stateBorder
        if e.active then
            stateTag, stateCol, stateBorder = '[*] SOCKETED', F.u32.soul_gold_bright, F.u32.soul_gold
        elseif e.owned then
            stateTag, stateCol, stateBorder = '[+] OWNED', F.u32.aether_cyan, F.u32.aether_cyan_dim
        else
            stateTag, stateCol, stateBorder = '[x] LOCKED', F.u32.text_muted, F.u32.border_subtle
        end
        F.drawBadgePill(imgui, dl, midPanelX + pad + rowW - math.floor(108 * s), ry + 12 * s, stateTag, {
            width     = math.floor(98 * s),
            height    = math.floor(22 * s),
            fill      = F.u32.abyss_solid,
            border    = stateBorder,
            textCol   = stateCol,
            fontScale = 0.74 * s,
        })
    end

    -- 3. Right Panel: Rich Soul Crystal Inspector & Deliberate Socket CTA
    if rightW > 0 and focused then
        local rx = midPanelX + midW + gap
        local modalActive = self:has_modal()
        F.drawOrnatePanel(dl, rx, bodyY, rightW, bodyH, {
            texId      = inspTex,
            texTint    = F.abgr(F.rgba.white, 0.26),
            scrimAlpha = 0.72,
            border     = modalActive and F.u32.soul_gold_bright or F.u32.soul_gold_dim,
            accent     = modalActive and F.u32.soul_gold_bright or F.u32.soul_gold,
            thickness  = modalActive and 1.8 or 1.3,
            corners    = true,
            shadow     = false,
        })

        F.drawShadowText(imgui, dl, rx + pad, bodyY + 12 * s, 'SOUL INSPECTOR', F.u32.soul_gold_bright, 1.06 * s, 'l')
        F.drawDivider(dl, rx + pad, bodyY + 38 * s, rightW - pad * 2, F.u32.soul_gold_dim)

        local iy = bodyY + 50 * s
        local innerW = rightW - pad * 2
        local fTex = (assetsRef and focused.icon) and assetsRef:load_from_addon('crystalsocket', focused.icon) or nil
        local fSz = math.floor(58 * s)
        F.drawCrystalMedallion(dl, rx + pad + fSz * 0.5, iy + fSz * 0.5, fSz * 0.48, {
            texId = fTex,
            rim   = focused.active and F.u32.soul_gold_bright or F.u32.crystal_violet_bright,
            core  = F.rgba.crystal_violet,
            studs = true,
        })
        F.drawShadowText(imgui, dl, rx + pad + fSz + 14 * s, iy + 6 * s,
            F.fitText(imgui, focused.name, innerW - fSz - 14 * s, 1.18 * s), F.u32.white, 1.18 * s, 'l')
        F.drawShadowText(imgui, dl, rx + pad + fSz + 14 * s, iy + 34 * s,
            F.fitText(imgui, focused.role or '', innerW - fSz - 14 * s, 0.88 * s), F.u32.crystal_violet_bright, 0.88 * s, 'l')
        iy = iy + fSz + 16 * s

        local inspCharPx = math.max(9.6 * s, F.measureText(imgui, 'M', 0.84 * s))
        local chars = math.max(18, math.floor((innerW - 28 * s) / inspCharPx))
        local dLines = F.wrapLines(focused.description or '', chars, 5)
        local dBoxH = math.floor(20 * s + #dLines * 19 * s)
        dl:AddRectFilled({ rx + pad, iy }, { rx + rightW - pad, iy + dBoxH }, F.abgr(F.hex('#0D1322', 0.90)), 5)
        dl:AddRect({ rx + pad, iy }, { rx + rightW - pad, iy + dBoxH }, F.u32.border_strong, 5, 0, 1.0)
        for i, line in ipairs(dLines) do
            F.drawShadowText(imgui, dl, rx + pad + 10 * s, iy + 10 * s + (i - 1) * 19 * s,
                F.fitText(imgui, line, innerW - 22 * s, 0.84 * s), F.u32.text_primary, 0.84 * s, 'l')
        end
        iy = iy + dBoxH + 14 * s

        if focused.highlights and #focused.highlights > 0 then
            F.drawShadowText(imgui, dl, rx + pad, iy, 'SIGNATURE TRAITS', F.u32.soul_gold, 0.88 * s, 'l')
            iy = iy + 22 * s
            for _, hl in ipairs(focused.highlights) do
                for _, line in ipairs(F.wrapLines('- ' .. tostring(hl), math.max(18, chars - 2), 2)) do
                    if iy < bodyY + bodyH - 115 * s then
                        F.drawShadowText(imgui, dl, rx + pad + 6 * s, iy,
                            F.fitText(imgui, line, innerW - 14 * s, 0.82 * s), F.u32.text_primary, 0.82 * s, 'l')
                        iy = iy + math.floor(19 * s)
                    end
                end
            end
            iy = iy + 10 * s
        end

        if self.data_service and self.data_service.get_abilities_for_soul and focused.key and focused.key ~= 'base' then
            local okAb, abList = pcall(self.data_service.get_abilities_for_soul, self.data_service, focused.key)
            if okAb and type(abList) == 'table' and #abList > 0 and iy < bodyY + bodyH - 140 * s then
                F.drawDivider(dl, rx + pad, iy, innerW, F.u32.border_subtle)
                iy = iy + 10 * s
                F.drawShadowText(imgui, dl, rx + pad, iy, 'SIGNATURE ABILITIES', F.u32.aether_cyan, 0.86 * s, 'l')
                iy = iy + 22 * s
                for idx = 1, math.min(4, #abList) do
                    local ab = abList[idx]
                    if iy < bodyY + bodyH - 96 * s then
                        local abName = type(ab) == 'table' and (ab.name or ab.displayName or '') or tostring(ab)
                        local abLvl = type(ab) == 'table' and tonumber(ab.level or ab.reqLevel) or nil
                        local abStr = abLvl and string.format('Lv.%d  %s', abLvl, abName) or abName
                        F.drawShadowText(imgui, dl, rx + pad + 6 * s, iy,
                            F.fitText(imgui, abStr, innerW - 12 * s, 0.82 * s), F.u32.text_secondary, 0.82 * s, 'l')
                        iy = iy + math.floor(19 * s)
                    end
                end
            end
        end

        local actBtnH = math.floor(42 * s)
        local actY = bodyY + bodyH - pad - actBtnH
        if modalActive and self.confirm_entry then
            local cH = math.floor(76 * s)
            local cTop = bodyY + bodyH - pad - cH
            F.drawOrnatePanel(dl, rx + pad, cTop, innerW, cH, {
                fillTop = F.u32.midnight_alt, fillBot = F.u32.abyss_solid,
                border = F.u32.soul_gold_bright, corners = false, shadow = false,
            })
            F.drawShadowText(imgui, dl, rx + pad + 10 * s, cTop + 9 * s,
                F.fitText(imgui, 'Socket ' .. self.confirm_entry.name .. '?', innerW - 20 * s, 0.88 * s),
                F.u32.soul_gold_bright, 0.88 * s, 'l')
            local halfW = math.floor((innerW - 24 * s) * 0.5)
            local bY = cTop + cH - math.floor(34 * s) - 7 * s
            local bH = math.floor(32 * s)
            if F.drawBeveledCtaButton(imgui, dl, '##ch_cf_ok', rx + pad + 8 * s, bY, halfW, bH,
                'CONFIRM', 'gold', { focused = (self.confirm_btn == 1), fontScale = 0.84 * s }) then
                local target = self.confirm_entry
                self.region = 'crystals'
                self.confirm_entry = nil
                self:select_branch(target.branch)
            end
            if F.drawActionButton(imgui, dl, '##ch_cf_no', rx + pad + 16 * s + halfW, bY, halfW, bH,
                (self.confirm_btn == 2 and '> ' or '') .. 'CANCEL', 'neutral', { fontScale = 0.84 * s }) then
                self.region = 'crystals'
                self.confirm_entry = nil
            end
        elseif snap.pending then
            F.drawBeveledCtaButton(imgui, dl, '##ch_pend', rx + pad, actY, innerW, actBtnH,
                'Confirming with Server...', 'cyan', { disabled = true, fontScale = 0.90 * s })
        elseif focused.active then
            F.drawBeveledCtaButton(imgui, dl, '##ch_actv', rx + pad, actY, innerW, actBtnH,
                'Currently Socketed', 'gold', { disabled = true, fontScale = 0.90 * s })
        elseif focused.owned and self:_can_socket(snap) then
            if F.drawBeveledCtaButton(imgui, dl, '##ch_sock', rx + pad, actY, innerW, actBtnH,
                'Socket Soul Crystal [A]', 'gold', { fontScale = 0.94 * s }) then
                self.confirm_entry = focused
                self.region = 'confirm_socket'
                self.confirm_btn = 1
            end
        else
            F.drawBeveledCtaButton(imgui, dl, '##ch_lock', rx + pad, actY, innerW, actBtnH,
                snap.loaded and 'Locked by Progression' or (self.last_sync_err and 'Sync Failed - Press [X]' or 'Waiting for Server Sync'),
                'gold', { disabled = true, fontScale = 0.86 * s })
        end
    end
end

return Character
