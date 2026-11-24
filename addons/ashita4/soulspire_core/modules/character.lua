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
        protocol      = opts.protocol,
        crystal_state = cs_state,
        soul_registry = opts.soul_registry,
        data_service  = opts.data_service,
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
    if type(self.player_ctx_fn) == 'function' then
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
            return {
                name      = name,
                server_id = sid,
                zone      = party:GetMemberZone(0) or 0,
                main_job  = player:GetMainJob() or 0,
                main_lvl  = (player.GetMainJobLevel and player:GetMainJobLevel()) or 0,
                sub_job   = (player.GetSubJob and player:GetSubJob()) or 0,
                sub_lvl   = (player.GetSubJobLevel and player:GetSubJobLevel()) or 0,
            }
        end)
        if ok then info = res end
    end

    if info then
        self.player_info = info
        if self.crystal_state then
            local key = tostring(info.server_id or 0) .. ':' .. tostring(info.name or '')
            self.crystal_state:set_context(key, info.main_job, info.zone, info.main_lvl)
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
    local entries, snap, activeBranch, jobKey = self:get_entries()
    local activeName = 'Base'
    local activeAbbr = jobKey
    for _, e in ipairs(entries) do
        if e.branch == activeBranch then
            activeName = e.name
            activeAbbr = e.abbr or jobKey
            break
        end
    end
    return {
        player_name = self.player_info.name or 'Adventurer',
        job_key     = jobKey,
        job_level   = snap.current_lvl or self.player_info.main_lvl or 0,
        sub_job_key = JOB_NAMES[self.player_info.sub_job or 0],
        sub_level   = self.player_info.sub_lvl or 0,
        soul_name   = activeName,
        soul_abbr   = activeAbbr,
        branch      = activeBranch,
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

function Character:_get_dll_status()
    if type(self.dll_status_fn) == 'function' then
        local ok, st = pcall(self.dll_status_fn)
        return ok and st or nil
    end
    return nil
end

function Character:draw(imgui, dl, F, L, x, y, w, h)
    self:refresh_player_context()
    self:tick(self.clock())

    local s   = L.uiScale or 1.0
    local gap = L.gap or math.floor(8 * s)
    local pad = math.floor(14 * s)
    local entries, snap, activeBranch, jobKey = self:get_entries()
    self.selected_idx = clamp(self.selected_idx, 1, math.max(1, #entries))
    local focused = entries[self.selected_idx]
    local activeEntry = entries[1]
    for _, e in ipairs(entries) do
        if e.branch == activeBranch then activeEntry = e; break end
    end

    local leftW  = math.floor(w * (L.mode == 'focused' and 0.44 or 0.30))
    local rightW = math.floor(w * (L.mode == 'focused' and 0.00 or 0.32))
    local midW   = math.max(200, w - leftW - rightW - (rightW > 0 and gap * 2 or gap))

    -- 1. Left Panel: Character Identity Card & Native Hook Status
    F.drawPanelFrame(dl, x, y, leftW, h, {
        fillTop  = F.u32.midnight,
        fillBot  = F.u32.abyss,
        border   = F.u32.crystal_violet,
        accent   = F.u32.soul_gold,
        corners  = (L.ornamentLevel >= 1),
        shadow   = false,
    })

    F.drawShadowText(imgui, dl, x + pad, y + 10 * s, 'SOUL IDENTITY', F.u32.soul_gold, 0.94 * s, 'l')
    F.drawDivider(dl, x + pad, y + 32 * s, leftW - pad * 2, F.u32.crystal_violet)

    local medR = math.floor(38 * s)
    local medX = x + leftW * 0.5
    local medY = y + 44 * s + medR
    local activeTex = (self.assets and activeEntry and activeEntry.icon)
        and self.assets:load_from_addon('crystalsocket', activeEntry.icon) or nil
    F.drawCrystalMedallion(dl, medX, medY, medR, {
        texId = activeTex,
        rim   = F.u32.soul_gold_bright,
        core  = F.rgba.crystal_violet,
        studs = true,
    })

    local cy = medY + medR + 14 * s
    F.drawShadowText(imgui, dl, medX, cy,
        F.fitText(imgui, self.player_info.name or 'Adventurer', leftW - pad * 2, 1.06 * s),
        F.u32.text_primary, 1.06 * s, 'c')
    cy = cy + 22 * s

    local subStr = (self.player_info.sub_job and self.player_info.sub_job > 0)
        and (' / ' .. (JOB_NAMES[self.player_info.sub_job] or '---') .. ' Lv.' .. tostring(self.player_info.sub_lvl or 0))
        or ''
    local jobLine = string.format('%s Lv.%d%s', jobKey, snap.current_lvl or self.player_info.main_lvl or 0, subStr)
    F.drawShadowText(imgui, dl, medX, cy, jobLine, F.u32.soul_gold_bright, 0.88 * s, 'c')
    cy = cy + 24 * s

    F.drawBadgePill(imgui, dl, medX - math.floor(82 * s), cy,
        string.format('SOUL: %s [%s]', activeEntry and activeEntry.name or 'Base', activeEntry and activeEntry.abbr or jobKey), {
            width     = math.floor(164 * s),
            height    = math.floor(24 * s),
            fill      = F.abgr(F.rgba.crystal_violet_wash, 0.95),
            border    = F.u32.crystal_violet,
            textCol   = F.u32.crystal_violet_bright,
            fontScale = 0.76 * s,
        })
    cy = cy + 34 * s

    F.drawShadowText(imgui, dl, medX, cy,
        F.fitText(imgui, activeEntry and activeEntry.role or 'Base Job', leftW - pad * 2, 0.80 * s),
        F.u32.text_secondary, 0.80 * s, 'c')
    cy = cy + 26 * s

    -- Native Integration & Protocol Status Box
    local boxH = math.floor(74 * s)
    local boxY = math.min(y + h - pad - boxH, cy)
    dl:AddRectFilled({ x + pad, boxY }, { x + leftW - pad, boxY + boxH }, F.u32.abyss_solid, 5)
    dl:AddRect({ x + pad, boxY }, { x + leftW - pad, boxY + boxH }, F.u32.border_subtle, 5, 0, 1.0)
    F.drawShadowText(imgui, dl, x + pad + 10 * s, boxY + 8 * s, 'SYNC & NATIVE STATUS', F.u32.aether_cyan, 0.72 * s, 'l')
    local statusLabel
    if snap.loaded then
        statusLabel = self:_cache_ready() and 'Collection: ready (cached)' or 'Collection: ready'
    elseif snap.pending or self.retry_after then
        statusLabel = 'Collection: syncing...'
    elseif self.last_sync_err then
        statusLabel = 'Collection: ' .. tostring(self.last_sync_err)
    else
        statusLabel = 'Collection: ' .. tostring(snap.status or 'offline')
    end
    F.drawShadowText(imgui, dl, x + pad + 10 * s, boxY + 26 * s,
        F.fitText(imgui, statusLabel, leftW - pad * 2 - 20 * s, 0.74 * s),
        snap.loaded and F.u32.success or F.u32.text_secondary, 0.74 * s, 'l')
    local dll = self:_get_dll_status()
    local dllLine = dll and string.format('Native DLL: %d hooks active', dll.hooks or 0)
        or 'Native DLL: CrystalSocket managed'
    F.drawShadowText(imgui, dl, x + pad + 10 * s, boxY + 46 * s,
        F.fitText(imgui, dllLine, leftW - pad * 2 - 20 * s, 0.74 * s),
        dll and F.u32.soul_gold or F.u32.text_muted, 0.74 * s, 'l')

    -- 2. Center Panel: Soul Crystal Collection
    local midX = x + leftW + gap
    local listFocused = (self.region == 'crystals')
    F.drawPanelFrame(dl, midX, y, midW, h, {
        fillTop   = F.u32.midnight,
        fillBot   = F.u32.abyss,
        border    = listFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent    = listFocused and F.u32.aether_cyan or F.u32.soul_gold,
        thickness = listFocused and 1.6 or 1.1,
        corners   = (L.ornamentLevel >= 1),
        shadow    = false,
    })

    F.drawShadowText(imgui, dl, midX + pad, y + 10 * s,
        listFocused and '> SOUL CRYSTALS' or 'SOUL CRYSTALS',
        listFocused and F.u32.aether_cyan or F.u32.soul_gold, 0.94 * s, 'l')
    if F.drawActionButton(imgui, dl, '##ch_sync_btn', midX + midW - pad - math.floor(62 * s), y + 6 * s,
        math.floor(62 * s), math.floor(22 * s), 'SYNC [X]', 'cyan', { fontScale = 0.70 * s }) then
        self.sync_retries = 0
        self:sync(not self:_cache_ready())
    end
    F.drawDivider(dl, midX + pad, y + 32 * s, midW - pad * 2, listFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    local rowW = midW - pad * 2
    local rowH = math.floor(68 * s)
    local rowStartY = y + 44 * s

    for i, e in ipairs(entries) do
        local ry = rowStartY + (i - 1) * (rowH + math.floor(8 * s))
        local isSel = (i == self.selected_idx)
        imgui.SetCursorScreenPos({ midX + pad, ry })
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

        local bg = isSel and F.u32.midnight_selected or (hovered and F.u32.midnight_alt or F.u32.midnight_deep)
        local border = (isSel and listFocused) and F.u32.aether_cyan
            or (e.active and F.u32.soul_gold or (e.owned and F.u32.crystal_violet or F.u32.border_subtle))
        dl:AddRectFilled({ midX + pad, ry }, { midX + pad + rowW, ry + rowH }, bg, 6)
        dl:AddRect({ midX + pad, ry }, { midX + pad + rowW, ry + rowH }, border, 6, 0, (isSel or e.active) and 1.8 or 1.0)
        if isSel then
            dl:AddRectFilled({ midX + pad + 1, ry + 6 }, { midX + pad + 4, ry + rowH - 6 },
                listFocused and F.u32.aether_cyan or F.u32.soul_gold, 1)
        end

        local icSz = math.floor(46 * s)
        local ix, iy = midX + pad + 10 * s, ry + math.floor((rowH - icSz) * 0.5)
        local tex = (self.assets and e.icon) and self.assets:load_from_addon('crystalsocket', e.icon) or nil
        F.drawCrystalMedallion(dl, ix + icSz * 0.5, iy + icSz * 0.5, icSz * 0.48, {
            texId = tex,
            rim   = e.active and F.u32.soul_gold_bright or (e.owned and F.u32.crystal_violet or F.u32.border_strong),
            core  = e.owned and F.rgba.crystal_violet or F.rgba.text_muted,
            studs = false,
        })

        local tx = ix + icSz + 12 * s
        local textW = math.max(80, rowW - (tx - (midX + pad)) - 96 * s)
        F.drawShadowText(imgui, dl, tx, ry + 10 * s,
            F.fitText(imgui, e.name, textW, 0.94 * s),
            e.active and F.u32.soul_gold_bright or (e.owned and F.u32.text_primary or F.u32.text_muted), 0.94 * s, 'l')
        F.drawShadowText(imgui, dl, tx, ry + 32 * s,
            F.fitText(imgui, e.role or '', textW, 0.76 * s), F.u32.text_secondary, 0.76 * s, 'l')
        F.drawShadowText(imgui, dl, tx, ry + 48 * s,
            string.format('Badge: %s  |  Req Lv.%d', e.abbr or jobKey, e.req_level or 1),
            F.u32.text_muted, 0.70 * s, 'l')

        local stateTag, stateCol
        if e.active then
            stateTag, stateCol = '[*] SOCKETED', F.u32.soul_gold_bright
        elseif e.owned then
            stateTag, stateCol = '[+] OWNED', F.u32.aether_cyan
        else
            stateTag, stateCol = '[x] LOCKED', F.u32.text_muted
        end
        F.drawShadowText(imgui, dl, midX + pad + rowW - 10 * s, ry + 12 * s, stateTag, stateCol, 0.74 * s, 'r')
    end

    -- 3. Right Panel: Soul Crystal Inspector & Deliberate Socket Confirmation
    if rightW > 0 and focused then
        local rx = midX + midW + gap
        local modalActive = self:has_modal()
        F.drawPanelFrame(dl, rx, y, rightW, h, {
            fillTop   = F.u32.midnight,
            fillBot   = F.u32.abyss,
            border    = modalActive and F.u32.soul_gold or F.u32.border_subtle,
            accent    = modalActive and F.u32.soul_gold or F.u32.aether_cyan_dim,
            thickness = modalActive and 1.6 or 1.1,
            corners   = (L.ornamentLevel >= 1),
            shadow    = false,
        })

        F.drawShadowText(imgui, dl, rx + pad, y + 10 * s, 'SOUL INSPECTOR', F.u32.soul_gold, 0.94 * s, 'l')
        F.drawDivider(dl, rx + pad, y + 32 * s, rightW - pad * 2, F.u32.soul_gold_dim)

        local iy = y + 44 * s
        local innerW = rightW - pad * 2
        F.drawShadowText(imgui, dl, rx + pad, iy, F.fitText(imgui, focused.name, innerW, 1.04 * s), F.u32.soul_gold_bright, 1.04 * s, 'l')
        iy = iy + 24 * s
        F.drawShadowText(imgui, dl, rx + pad, iy, F.fitText(imgui, focused.role or '', innerW, 0.80 * s), F.u32.crystal_violet_bright, 0.80 * s, 'l')
        iy = iy + 22 * s

        local chars = math.max(20, math.floor(innerW / (7.6 * s)))
        for _, line in ipairs(F.wrapLines(focused.description or '', chars, 6)) do
            F.drawShadowText(imgui, dl, rx + pad, iy, line, F.u32.text_primary, 0.80 * s, 'l')
            iy = iy + math.floor(17 * s)
        end
        iy = iy + 10 * s

        if focused.highlights and #focused.highlights > 0 then
            F.drawShadowText(imgui, dl, rx + pad, iy, 'SIGNATURE TRAITS', F.u32.aether_cyan, 0.76 * s, 'l')
            iy = iy + 18 * s
            for _, hl in ipairs(focused.highlights) do
                for _, line in ipairs(F.wrapLines('- ' .. tostring(hl), chars, 2)) do
                    F.drawShadowText(imgui, dl, rx + pad, iy, line, F.u32.text_secondary, 0.76 * s, 'l')
                    iy = iy + math.floor(16 * s)
                end
            end
        end

        -- Bottom action / confirmation dock
        local actBtnH = math.floor(34 * s)
        local actY = y + h - pad - actBtnH
        if modalActive and self.confirm_entry then
            local cH = math.floor(66 * s)
            local cTop = y + h - pad - cH
            dl:AddRectFilled({ rx + pad, cTop }, { rx + rightW - pad, cTop + cH }, F.u32.midnight_alt, 5)
            dl:AddRect({ rx + pad, cTop }, { rx + rightW - pad, cTop + cH }, F.u32.soul_gold, 5, 0, 1.5)
            F.drawShadowText(imgui, dl, rx + pad + 8 * s, cTop + 7 * s,
                F.fitText(imgui, 'Socket ' .. self.confirm_entry.name .. '?', innerW - 16 * s, 0.80 * s),
                F.u32.soul_gold_bright, 0.80 * s, 'l')
            local halfW = math.floor((innerW - 22 * s) * 0.5)
            local bY = cTop + cH - math.floor(30 * s) - 6 * s
            local bH = math.floor(28 * s)
            if F.drawActionButton(imgui, dl, '##ch_cf_ok', rx + pad + 6 * s, bY, halfW, bH,
                (self.confirm_btn == 1 and '> ' or '') .. 'CONFIRM', 'gold', { fontScale = 0.78 * s }) then
                local target = self.confirm_entry
                self.region = 'crystals'
                self.confirm_entry = nil
                self:select_branch(target.branch)
            end
            if F.drawActionButton(imgui, dl, '##ch_cf_no', rx + pad + 12 * s + halfW, bY, halfW, bH,
                (self.confirm_btn == 2 and '> ' or '') .. 'CANCEL', 'neutral', { fontScale = 0.78 * s }) then
                self.region = 'crystals'
                self.confirm_entry = nil
            end
        elseif snap.pending then
            F.drawActionButton(imgui, dl, '##ch_pend', rx + pad, actY, innerW, actBtnH,
                'CONFIRMING WITH SERVER...', 'cyan', { disabled = true, fontScale = 0.80 * s })
        elseif focused.active then
            F.drawActionButton(imgui, dl, '##ch_actv', rx + pad, actY, innerW, actBtnH,
                'CURRENTLY SOCKETED', 'neutral', { disabled = true, fontScale = 0.80 * s })
        elseif focused.owned and self:_can_socket(snap) then
            if F.drawActionButton(imgui, dl, '##ch_sock', rx + pad, actY, innerW, actBtnH,
                'SOCKET SOUL CRYSTAL [A]', 'gold', { fontScale = 0.82 * s }) then
                self.confirm_entry = focused
                self.region = 'confirm_socket'
                self.confirm_btn = 1
            end
        else
            F.drawActionButton(imgui, dl, '##ch_lock', rx + pad, actY, innerW, actBtnH,
                snap.loaded and 'LOCKED BY PROGRESSION' or (self.last_sync_err and 'SYNC FAILED — PRESS [X]' or 'WAITING FOR SERVER SYNC'),
                'neutral', { disabled = true, fontScale = 0.78 * s })
        end
    end
end

return Character
