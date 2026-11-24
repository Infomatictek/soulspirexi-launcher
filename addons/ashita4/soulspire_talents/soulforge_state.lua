-- SoulspireXI — Shared Soulforge State & Server-Authoritative Protocol Controller
-- Reused by both standalone soulspire_talents (/talents) and unified soulspire_core
-- (Weapon Mastery & Soul Talents modules) so there is zero protocol or state duplication.
--
-- Protocol:
--   C2S: 0x11F ("OXTL")
--     Legacy ops 1..8 preserved 100% backwards-compatibly.
--     v2 cache-aware ops:
--       9  = OP_CACHE_SYNC (clientSchemaVer, flags, syncGen) -> CACHE + META + SPENT + SYNC_END (no 219-WS catalog flood)
--       10 = OP_WS_STATE   (wsId, clientSchemaVer, reqSeq)   -> WSS_BEGIN + WSS + WSS_END (dynamic state merged onto verified cache)
--   S2C: 0x1FD ("OXTL") and 0x017 ("[OXTAL]|...")
--
-- Security:
--   Static descriptions & tree layouts come from the locally SHA-256-verified cache.
--   Server remains 100% authoritative over points, eligibility, ranks, canLearn, unlocks, and mutations.

local M = {}

M.PROTO_TAG     = '[OXTAL]|'
M.PACKET_C2S_ID = 0x11F
M.PACKET_S2C_ID = 0x1FD
M.OP_SYNC       = 1
M.OP_STATE      = 2
M.OP_WS         = 3
M.OP_INVEST     = 4
M.OP_REFUND     = 5
M.OP_CYCLE_SC   = 6
M.OP_RESET_WS   = 7
M.OP_RESET_ALL  = 8
M.OP_CACHE_SYNC = 9
M.OP_WS_STATE   = 10

M.MAX_SYNC_RETRIES      = 2
M.MAX_WS_RETRIES        = 2
M.LEGACY_FALLBACK_SEC   = 1.8
M.REQUEST_TIMEOUT_SEC   = 5.0

M.SKILL_LIST = {
    { id = -1, name = 'Equipped' },
    { id = 0,  name = 'All Weapons' },
    { id = 1,  name = 'Hand-to-Hand' },
    { id = 2,  name = 'Dagger' },
    { id = 3,  name = 'Sword' },
    { id = 4,  name = 'Great Sword' },
    { id = 5,  name = 'Axe' },
    { id = 6,  name = 'Great Axe' },
    { id = 7,  name = 'Scythe' },
    { id = 8,  name = 'Polearm' },
    { id = 9,  name = 'Katana' },
    { id = 10, name = 'Great Katana' },
    { id = 11, name = 'Club' },
    { id = 12, name = 'Staff' },
    { id = 25, name = 'Archery' },
    { id = 26, name = 'Marksmanship' },
    { id = 27, name = 'Throwing' },
}

M.SKILL_NAMES = {}
for _, sk in ipairs(M.SKILL_LIST) do
    M.SKILL_NAMES[sk.id] = sk.name
end

local SC_SHORT_FALLBACK = {
    [1] = 'Trn', [2] = 'Cmp', [3] = 'Liq', [4] = 'Sci',
    [5] = 'Rev', [6] = 'Det', [7] = 'Ind', [8] = 'Imp',
    [9] = 'Grv', [10] = 'Dst', [11] = 'Fus', [12] = 'Frg',
    [13] = 'Lgt', [14] = 'Drk',
}

function M.getSkillName(skillId)
    local id = tonumber(skillId) or 0
    if id == 0 then return 'None' end
    return M.SKILL_NAMES[id] or ('Skill #' .. tostring(id))
end

function M.getEquippedSummary(state)
    if type(state) ~= 'table' then return nil end
    local mainSk   = tonumber(state.mainSkill) or 0
    local rangedSk = tonumber(state.rangedSkill) or 0
    local parts = {}
    if mainSk > 0 then
        parts[#parts + 1] = M.getSkillName(mainSk)
    end
    if rangedSk > 0 and rangedSk ~= mainSk then
        parts[#parts + 1] = M.getSkillName(rangedSk)
    end
    if #parts == 0 then return nil end
    return table.concat(parts, ' / ')
end

function M.getArsenalStatus(state, rows)
    if type(state) ~= 'table' then
        return {
            kind        = 'loading',
            title       = 'SYNCING ARSENAL...',
            body        = 'Waiting for server weapon skill mastery state.',
            action      = 'sync',
            actionLabel = 'SYNC NOW',
        }
    end
    local count = type(rows) == 'table' and #rows or 0
    if count > 0 then
        return {
            kind  = 'ready',
            count = count,
        }
    end

    if not state.synced and #(state.catalog or {}) == 0 then
        if state.lastSyncError then
            return {
                kind        = 'sync_error',
                title       = 'SERVER SYNC FAILED',
                body        = tostring(state.lastSyncError),
                action      = 'sync',
                actionLabel = 'RETRY SYNC',
            }
        end
        return {
            kind        = 'loading',
            title       = 'SYNCING ARSENAL...',
            body        = 'Requesting server-authoritative weapon skill mastery state...',
            action      = 'sync',
            actionLabel = 'RETRY SYNC',
        }
    end

    if #(state.catalog or {}) == 0 then
        return {
            kind        = 'catalog_empty',
            title       = 'ARSENAL UNAVAILABLE',
            body        = state.cacheNotice or 'No weapon skills were loaded from cache or server. Click SYNC or update via SoulspireLauncher.',
            action      = 'sync',
            actionLabel = 'SYNC NOW',
        }
    end

    local rawQuery = ((state.searchBuf and state.searchBuf[1]) or ''):gsub('%z.*$', '')
    local query    = string.lower(rawQuery)
    local invOnly  = state.investedOnly and state.investedOnly[1] == true
    local sk       = tonumber(state.selectedSkill) or -1
    local mainSk   = tonumber(state.mainSkill) or 0
    local rangedSk = tonumber(state.rangedSkill) or 0

    if query ~= '' then
        return {
            kind        = 'search_empty',
            title       = 'NO MATCHING SKILLS',
            body        = string.format('No weapon skills match "%s" in the active filter.', rawQuery),
            action      = 'clear_search',
            actionLabel = 'CLEAR SEARCH',
        }
    end

    if invOnly then
        return {
            kind        = 'invested_empty',
            title       = 'NO INVESTED SKILLS',
            body        = 'No weapon skills in this filter have invested talent points yet. Disable "Invested only" to browse eligible skills.',
            action      = 'clear_invested',
            actionLabel = 'SHOW ALL ELIGIBLE',
        }
    end

    if sk == -1 then
        if not state.synced then
            return {
                kind        = 'loading',
                title       = 'SYNCING EQUIPPED WEAPON...',
                body        = 'Static weapon catalog loaded from cache. Confirming equipped weapon & points with server...',
                action      = 'all_weapons',
                actionLabel = 'SHOW ALL WEAPONS',
            }
        end
        if mainSk == 0 and rangedSk == 0 then
            return {
                kind        = 'no_weapon_equipped',
                title       = 'NO WEAPON EQUIPPED',
                body        = 'No Main or Ranged weapon is currently equipped for the Equipped filter. Equip a weapon or switch to All Weapons to browse your Arsenal.',
                action      = 'all_weapons',
                actionLabel = 'SHOW ALL WEAPONS',
            }
        end
        local eqLabel = M.getEquippedSummary(state) or 'Equipped weapon'
        return {
            kind        = 'equipped_no_ws',
            title       = 'NO ELIGIBLE SKILLS',
            body        = string.format('Equipped %s has no matching weapon skills in the catalog. Switch to All Weapons to browse other families.', eqLabel),
            action      = 'all_weapons',
            actionLabel = 'SHOW ALL WEAPONS',
        }
    end

    return {
        kind        = 'filter_empty',
        title       = 'NO ELIGIBLE SKILLS',
        body        = string.format('No weapon skills matched %s. Switch to All Weapons to browse your full Arsenal.', M.getSkillName(sk)),
        action      = 'all_weapons',
        actionLabel = 'SHOW ALL WEAPONS',
    }
end

local function splitPipe(str)
    local out = {}
    local start = 1
    while true do
        local pos = string.find(str, '|', start, true)
        if not pos then
            table.insert(out, string.sub(str, start))
            break
        end
        table.insert(out, string.sub(str, start, pos - 1))
        start = pos + 1
    end
    return out
end

function M.encodePacket(op, wsId, arg1, arg2)
    local w  = tonumber(wsId) or 0
    local a1 = (tonumber(arg1) or 0) % 256
    local a2 = (tonumber(arg2) or 0) % 256
    local pkt = string.char(0x1F, 0x09, 0x00, 0x00)
        .. 'OXTL'
        .. string.char(1, op % 256, w % 256, math.floor(w / 256) % 256, a1, a2, 0, 0)
    return { pkt:byte(1, #pkt) }
end

function M.new(opts)
    opts = opts or {}
    local soulRegistry = opts.soulRegistry
    local wsRegistry   = opts.wsRegistry
    local dataService  = opts.dataService
    local sendFn       = opts.sendPacket
    local clockFn      = opts.clock or os.clock
    local onJobChange  = opts.onJobChange
    local onSavePrefs  = opts.savePrefs

    local function resolveSpecDisplayName(raw)
        if type(raw) ~= 'string' or raw == '' or raw == 'Base' then return 'Base' end
        if dataService and dataService.get_soul_by_key then
            local s = dataService:get_soul_by_key(raw)
            if s and s.displayName then return s.displayName end
        end
        if soulRegistry and soulRegistry.displayName then
            return soulRegistry.displayName(raw, raw)
        end
        return raw
    end

    local function resolveWsDisplayName(wsId, raw)
        if dataService and dataService.get_weapon_skill and wsId then
            local ws = dataService:get_weapon_skill(wsId)
            if ws and ws.name then return ws.name end
        end
        if wsRegistry and wsRegistry.displayName and wsId then
            return wsRegistry.displayName(wsId, raw)
        end
        return raw
    end

    local state = {
        open                = { false },
        synced              = false,
        syncState           = 'idle', -- 'idle' | 'loading' | 'synced' | 'error'
        syncRequestedAt     = 0,
        lastSyncCompletedAt = 0,
        lastSyncError       = nil,
        syncPending         = nil, -- { kind, gen, sentAt, retries, fallbackTried }
        syncGen             = 0,
        wsReqSeq            = 0,
        wsRequest           = nil, -- { wsId, seq, sentAt, retries, mode }
        wsError             = nil,
        needsRefresh        = false,
        protocolVersion     = 1,
        serverSupportsV2    = nil, -- nil (unknown) | true | false
        catalogSource       = 'none', -- 'cache' | 'server' | 'none'
        cacheNotice         = nil,
        jobKey              = '---',
        specName            = 'Base',
        rawSpecKey          = 'Base',
        specKey             = 'base',
        jobLevel            = 1,
        avail               = 0,
        spent               = 0,
        earned              = 1,
        mainSkill           = 0,
        rangedSkill         = 0,
        catalog             = {},
        catalogById         = {},
        tempCatalog         = nil,
        spentByWs           = {},
        unlockedByWs        = {},
        wsDetailsById       = {}, -- cached per-WS detail for Soul Talents overview
        tempSpent           = nil,
        tempUnlocked        = nil,
        tempWss             = nil,
        selectedSkill       = -1,
        selectedWsId        = nil,
        wsDetail            = nil,
        tempWs              = nil,
        searchBuf           = { '' },
        investedOnly        = { false },
        confirmResetAll     = false,
        confirmResetAt      = 0,
        statusText          = nil,
        statusTime          = 0,
        pendingOp           = nil,
        rejectedNodeKey     = nil,
        rejectedMsg         = nil,
        rejectedAt          = nil,
        lastKnownJob        = nil,
        lastKnownLvl        = nil,
        lastAutoCheck       = 0,
        inspectedNodeKey    = nil,
        renderError         = nil,
        uiFont              = nil,
        ui = {
            scale            = 1.0,
            canvasZoom       = 1.0,
            panX             = 0,
            panY             = 0,
            drawerOpen       = nil,
            confirmAction    = nil,
            confirmResetWs   = false,
            confirmResetWsAt = 0,
            lastViewportW    = 0,
            lastViewportH    = 0,
        },
    }

    local function seedCatalogFromCache()
        if not dataService or not dataService:is_cache_usable() then
            if dataService and dataService.error_message then
                state.cacheNotice = dataService.error_message
            end
            return false
        end
        local cached = dataService:get_all_weapon_skills()
        if type(cached) ~= 'table' or #cached == 0 then
            return false
        end
        local list = {}
        local byId = {}
        for i, ws in ipairs(cached) do
            local entry = {
                id        = ws.wsId or ws.id,
                stableId  = ws.stableId,
                skill     = ws.skillId or ws.skill or 0,
                skillName = ws.skillName or '',
                name      = ws.name or ('WS #' .. tostring(ws.wsId or ws.id)),
                wsType    = ws.wsType or 'physical',
                evolution = ws.evolution == true,
                maxPoints = ws.maxPoints or 56,
            }
            list[i] = entry
            byId[entry.id] = entry
        end
        state.catalog = list
        state.catalogById = byId
        state.catalogSource = 'cache'
        if dataService.compat_state == 'outdated_content' then
            state.cacheNotice = dataService.error_message
        else
            state.cacheNotice = nil
        end
        return true
    end

    -- Immediately seed static 219-WS catalog from verified local cache (0 network packets!)
    seedCatalogFromCache()

    local function isCompactEnabled()
        return dataService ~= nil
            and dataService:is_cache_usable()
            and state.serverSupportsV2 ~= false
    end

    local function sendTalentPacket(op, wsId, arg1, arg2)
        local bytes = M.encodePacket(op, wsId, arg1, arg2)
        if dataService then
            dataService:record_metric('packets_out_oxtl', 1)
        end
        if type(sendFn) == 'function' then
            return sendFn(M.PACKET_C2S_ID, bytes, op, wsId, arg1, arg2)
        end
        if AshitaCore and AshitaCore.GetPacketManager then
            local pm = AshitaCore:GetPacketManager()
            if pm and pm.AddOutgoingPacket then
                pm:AddOutgoingPacket(M.PACKET_C2S_ID, bytes)
                return true
            end
        end
        return false
    end

    local function setStatus(msg)
        state.statusText = msg
        state.statusTime = clockFn()
    end

    local function isPendingActive()
        if state.pendingOp == nil then return false end
        if (clockFn() - (state.pendingOp.sentAt or 0)) < M.REQUEST_TIMEOUT_SEC then
            return true
        end
        state.pendingOp = nil
        if dataService then
            dataService:record_metric('timeouts', 1)
            dataService:record_event('oxtl', 'op_timeout', 'Pending talent mutation timed out')
        end
        setStatus('Server request timed out — click SYNC to refresh.')
        return false
    end

    local function requestWS(wsId, forceLegacy)
        if wsId == nil then return end
        local now = clockFn()
        state.selectedWsId = wsId
        state.wsError = nil
        if state.wsDetailsById[wsId] and (not state.wsDetail or state.wsDetail.id ~= wsId) then
            state.wsDetail = state.wsDetailsById[wsId]
        end

        state.wsReqSeq = (state.wsReqSeq % 250) + 1
        local seq = state.wsReqSeq
        local useCompact = (not forceLegacy) and isCompactEnabled()
        local mode = useCompact and 'compact' or 'legacy'
        state.wsRequest = {
            wsId    = wsId,
            seq     = seq,
            sentAt  = now,
            retries = 0,
            mode    = mode,
        }

        if useCompact then
            local info = dataService:get_cache_info()
            sendTalentPacket(M.OP_WS_STATE, wsId, info.schemaVersion or 1, seq)
        else
            sendTalentPacket(M.OP_WS, wsId, 0, 0)
        end
    end

    local function requestFullSync(forceLegacyCatalog)
        local now = clockFn()
        state.syncRequestedAt = now
        state.lastSyncError = nil
        if not state.synced then
            state.syncState = 'loading'
        end
        state.needsRefresh = false

        state.syncGen = (state.syncGen % 250) + 1
        local gen = state.syncGen

        if not forceLegacyCatalog and dataService and dataService:is_cache_usable() then
            seedCatalogFromCache()
            if state.serverSupportsV2 ~= false then
                local info = dataService:get_cache_info()
                state.syncPending = {
                    kind          = 'cache_sync',
                    gen           = gen,
                    sentAt        = now,
                    retries       = 0,
                    fallbackTried = false,
                }
                sendTalentPacket(M.OP_CACHE_SYNC, info.schemaVersion or 1, 0, gen)
                return
            else
                -- Known legacy server + verified local cache: only request META + SPENT (skip 36-packet CAT flood!)
                state.syncPending = {
                    kind          = 'legacy_state',
                    gen           = gen,
                    sentAt        = now,
                    retries       = 0,
                    fallbackTried = true,
                }
                sendTalentPacket(M.OP_STATE, 0, 0, 0)
                return
            end
        end

        -- Fallback when local cache is missing/corrupt/incompatible or legacy full catalog explicitly requested
        state.syncPending = {
            kind          = 'legacy_full',
            gen           = gen,
            sentAt        = now,
            retries       = 0,
            fallbackTried = true,
        }
        sendTalentPacket(M.OP_SYNC, 0, 0, 0)
    end

    local function requestStateRefresh()
        local now = clockFn()
        state.needsRefresh = false
        state.syncRequestedAt = now
        state.lastSyncError = nil
        state.syncPending = {
            kind          = 'state_refresh',
            gen           = state.syncGen,
            sentAt        = now,
            retries       = 0,
            fallbackTried = true,
        }
        sendTalentPacket(M.OP_STATE, 0, 0, 0)
    end

    local function invalidateForLifecycle(reason)
        state.needsRefresh = true
        state.syncPending  = nil
        state.wsRequest    = nil
        state.tempWs       = nil
        state.tempWss      = nil
        state.tempCatalog  = nil
        state.tempSpent    = nil
        state.tempUnlocked = nil
        state.pendingOp    = nil
        state.wsDetailsById = {}
        state.wsDetail     = nil
        if dataService then
            dataService:invalidate_dynamic_state(reason)
        end
    end

    local function investNode(wsId, node)
        if not wsId or not node or isPendingActive() then return false end
        state.inspectedNodeKey = node.key
        state.rejectedNodeKey = nil
        state.rejectedMsg = nil
        state.pendingOp = {
            kind    = 'invest',
            wsId    = wsId,
            nodeKey = node.key,
            nodeIdx = node.idx or 0,
            sentAt  = clockFn(),
        }
        setStatus('Forging ' .. tostring(node.name or node.key) .. '...')
        local compactFlag = isCompactEnabled() and 1 or 0
        sendTalentPacket(M.OP_INVEST, wsId, node.idx or 0, compactFlag)
        return true
    end

    local function refundNode(wsId, node)
        if not wsId or not node or isPendingActive() then return false end
        state.inspectedNodeKey = node.key
        state.rejectedNodeKey = nil
        state.rejectedMsg = nil
        state.pendingOp = {
            kind    = 'refund',
            wsId    = wsId,
            nodeKey = node.key,
            nodeIdx = node.idx or 0,
            sentAt  = clockFn(),
        }
        setStatus('Refunding ' .. tostring(node.name or node.key) .. '...')
        local compactFlag = isCompactEnabled() and 1 or 0
        sendTalentPacket(M.OP_REFUND, wsId, node.idx or 0, compactFlag)
        return true
    end

    local function cycleSkillchain(wsId, tier, dir)
        if not wsId or not tier or isPendingActive() then return false end
        state.pendingOp = {
            kind   = 'sc',
            wsId   = wsId,
            tier   = tier,
            sentAt = clockFn(),
        }
        local d = (dir == 2) and 2 or 1
        local arg2 = isCompactEnabled() and (128 + d) or d
        sendTalentPacket(M.OP_CYCLE_SC, wsId, tier, arg2)
        return true
    end

    local function resetWS(wsId)
        if not wsId or isPendingActive() then return false end
        state.pendingOp = { kind = 'reset_ws', wsId = wsId, sentAt = clockFn() }
        setStatus('Resetting weapon skill talents...')
        local compactFlag = isCompactEnabled() and 1 or 0
        sendTalentPacket(M.OP_RESET_WS, wsId, 0, compactFlag)
        return true
    end

    local function resetAll()
        if isPendingActive() then return false end
        state.pendingOp = { kind = 'reset_all', wsId = 0, sentAt = clockFn() }
        setStatus('Resetting all weapon skill talents for ' .. tostring(state.specName) .. '...')
        local compactFlag = isCompactEnabled() and 1 or 0
        sendTalentPacket(M.OP_RESET_ALL, state.selectedWsId or 0, 0, compactFlag)
        return true
    end

    local function resetTransient()
        state.confirmResetAll = false
        if state.ui then
            state.ui.confirmAction  = nil
            state.ui.confirmResetWs = false
            state.ui.drawerOpen     = nil
        end
    end

    local function getFilteredCatalog()
        local list = {}
        local rawQuery = (state.searchBuf[1] or ''):gsub('%z.*$', '')
        local query = string.lower(rawQuery)
        local sk = state.selectedSkill

        for _, ws in ipairs(state.catalog) do
            local matchSkill = false
            if sk == 0 then
                matchSkill = true
            elseif sk == -1 then
                matchSkill = (state.mainSkill ~= 0 and ws.skill == state.mainSkill)
                    or (state.rangedSkill ~= 0 and ws.skill == state.rangedSkill)
            else
                matchSkill = (ws.skill == sk)
            end

            if matchSkill then
                local spent = state.spentByWs[ws.id] or 0
                local matchInvested = (not state.investedOnly[1]) or (spent > 0)
                local matchQuery = (query == '') or (string.find(string.lower(ws.name), query, 1, true) ~= nil)
                if matchInvested and matchQuery then
                    table.insert(list, ws)
                end
            end
        end

        return list
    end

    local function autoSelectEligibleWS()
        if not state.synced or #(state.catalog or {}) == 0 then
            return false
        end
        if state.selectedWsId ~= nil then
            if (state.wsDetail == nil or state.wsDetail.id ~= state.selectedWsId) and state.wsRequest == nil then
                requestWS(state.selectedWsId)
                return true
            end
            return false
        end
        local rows = getFilteredCatalog()
        if #rows > 0 then
            requestWS(rows[1].id)
            return true
        end
        for _, ws in ipairs(state.catalog) do
            if (state.mainSkill ~= 0 and ws.skill == state.mainSkill)
                or (state.rangedSkill ~= 0 and ws.skill == state.rangedSkill) then
                requestWS(ws.id)
                return true
            end
        end
        return false
    end

    -- Combine static verified cache tree + server-authoritative dynamic WSS state
    local function assembleCachedWSDetail(wss)
        if not dataService or not dataService:is_cache_usable() then
            return nil, 'cache unavailable'
        end
        local wsMeta = dataService:get_weapon_skill(wss.id)
        local tree   = dataService:get_ws_tree(wss.id, wss.specKey)
        if not wsMeta or not tree then
            return nil, 'ws tree missing from cache'
        end

        local nodes = {}
        local byKey = {}
        local scParts = {}
        for i, staticNode in ipairs(tree.nodes or {}) do
            local dyn = wss.nodeStates[staticNode.key]
            local rank = dyn and dyn.rank or 0
            local canLearn = dyn and dyn.canLearn or false
            local scTier = tonumber(staticNode.scTier) or 0
            local scId = (scTier >= 1 and scTier <= 4) and (wss.scIds[scTier] or 0) or 0
            local scName = ''
            if scId > 0 then
                scName = (dataService.get_skillchain_name and dataService:get_skillchain_name(scId))
                    or SC_SHORT_FALLBACK[scId] or tostring(scId)
                if tree.evolution or rank > 0 then
                    scParts[#scParts + 1] = scName
                end
            end

            local node = {
                idx         = tonumber(staticNode.idx) or i,
                slot        = tonumber(staticNode.slot) or i,
                key         = staticNode.key,
                tier        = tonumber(staticNode.tier) or 1,
                col         = tonumber(staticNode.col) or 1,
                rank        = rank,
                maxRank     = tonumber(staticNode.maxRank) or 1,
                canLearn    = canLearn,
                reqWsPoints = tonumber(staticNode.reqWsPoints) or 0,
                reqKey      = staticNode.reqKey,
                reqRank     = tonumber(staticNode.reqRank) or 0,
                name        = staticNode.name or staticNode.key,
                desc        = dataService.get_node_desc(staticNode, rank),
                nextDesc    = (rank < (tonumber(staticNode.maxRank) or 1))
                    and dataService.get_node_desc(staticNode, rank + 1) or nil,
                reqLevel    = dataService.get_node_next_req_level(staticNode, rank),
                scTier      = scTier,
                scId        = scId,
                scName      = scName,
                cost        = tonumber(staticNode.cost) or 1,
            }
            nodes[i] = node
            byKey[node.key] = node
        end

        local lockTag = wss.unlocked and 'UNLOCKED' or 'LOCKED (Rank 1 Tier 1 to unlock)'
        local summary
        if tree.evolution then
            summary = string.format('%s | WS Evolution | %d/%d choices', lockTag, wss.spent or 0, tree.maxPoints or 5)
        else
            local scText = #scParts > 0 and table.concat(scParts, '/') or 'NONE'
            summary = string.format('%s | SC: %s | Max: %d pts', lockTag, scText, tree.maxPoints or 56)
        end

        return {
            id        = wss.id,
            name      = wsMeta.name,
            skillName = wsMeta.skillName or '',
            wsType    = wsMeta.wsType or 'physical',
            spent     = wss.spent or 0,
            orig      = summary,
            nodes     = nodes,
            byKey     = byKey,
            source    = 'cache+wss',
        }, nil
    end

    local function tick(now)
        local t = now or clockFn()

        -- 1. Bounded sync timeout & legacy server auto-fallback
        local sp = state.syncPending
        if sp then
            local elapsed = t - (sp.sentAt or 0)
            if sp.kind == 'cache_sync' and not sp.fallbackTried and elapsed >= M.LEGACY_FALLBACK_SEC then
                -- Legacy server did not recognize OP_CACHE_SYNC (9): switch cleanly to OP_STATE (2) or OP_SYNC (1)
                sp.fallbackTried = true
                sp.sentAt = t
                state.serverSupportsV2 = false
                if dataService then
                    dataService:mark_legacy_server()
                    dataService:record_event('oxtl', 'legacy_fallback', 'OP_CACHE_SYNC timed out; falling back to OP_STATE/OP_SYNC')
                end
                if dataService and dataService:is_cache_usable() and #(state.catalog or {}) > 0 then
                    sp.kind = 'legacy_state'
                    sendTalentPacket(M.OP_STATE, 0, 0, 0)
                else
                    sp.kind = 'legacy_full'
                    sendTalentPacket(M.OP_SYNC, 0, 0, 0)
                end
            elseif elapsed >= M.REQUEST_TIMEOUT_SEC then
                if (sp.retries or 0) < M.MAX_SYNC_RETRIES then
                    sp.retries = (sp.retries or 0) + 1
                    sp.sentAt = t
                    if dataService then
                        dataService:record_metric('sync_retries', 1)
                        dataService:record_event('oxtl', 'sync_retry', 'retry #' .. tostring(sp.retries) .. ' kind=' .. tostring(sp.kind))
                    end
                    if sp.kind == 'cache_sync' and dataService and dataService:is_cache_usable() then
                        local info = dataService:get_cache_info()
                        sendTalentPacket(M.OP_CACHE_SYNC, info.schemaVersion or 1, 0, sp.gen or 0)
                    elseif sp.kind == 'legacy_state' or sp.kind == 'state_refresh' then
                        sendTalentPacket(M.OP_STATE, 0, 0, 0)
                    else
                        sendTalentPacket(M.OP_SYNC, 0, 0, 0)
                    end
                else
                    state.syncPending = nil
                    state.syncState = 'error'
                    state.lastSyncError = 'Server did not reply to Weapon Mastery sync. Click SYNC NOW or press [X] to retry.'
                    if dataService then
                        dataService:record_metric('timeouts', 1)
                        dataService:record_event('oxtl', 'sync_timeout', state.lastSyncError)
                    end
                    setStatus(state.lastSyncError)
                end
            end
        end

        -- 2. Bounded per-WS request timeout & legacy fallback (prevents infinite "LOADING WS #16...")
        local wr = state.wsRequest
        if wr then
            local elapsed = t - (wr.sentAt or 0)
            if wr.mode == 'compact' and elapsed >= M.LEGACY_FALLBACK_SEC then
                wr.mode = 'legacy'
                wr.sentAt = t
                state.serverSupportsV2 = false
                if dataService then
                    dataService:mark_legacy_server()
                    dataService:record_event('oxtl', 'ws_legacy_fallback', 'wsId=' .. tostring(wr.wsId))
                end
                sendTalentPacket(M.OP_WS, wr.wsId, 0, 0)
            elseif elapsed >= M.REQUEST_TIMEOUT_SEC then
                if (wr.retries or 0) < M.MAX_WS_RETRIES then
                    wr.retries = (wr.retries or 0) + 1
                    wr.sentAt = t
                    if dataService then
                        dataService:record_metric('sync_retries', 1)
                        dataService:record_event('oxtl', 'ws_retry', string.format('wsId=%d retry=%d', wr.wsId, wr.retries))
                    end
                    if wr.mode == 'compact' and isCompactEnabled() then
                        local info = dataService:get_cache_info()
                        sendTalentPacket(M.OP_WS_STATE, wr.wsId, info.schemaVersion or 1, wr.seq or 0)
                    else
                        sendTalentPacket(M.OP_WS, wr.wsId, 0, 0)
                    end
                else
                    local wsEntry = state.catalogById and state.catalogById[wr.wsId]
                    local wsName = wsEntry and wsEntry.name or ('Weapon Skill #' .. tostring(wr.wsId))
                    state.wsRequest = nil
                    state.wsError = 'No server talent tree response for ' .. wsName .. '. Click RETRY or SYNC.'
                    if dataService then
                        dataService:record_metric('timeouts', 1)
                        dataService:record_event('oxtl', 'ws_timeout', state.wsError)
                    end
                    setStatus(state.wsError)
                end
            end
        end
    end

    local function handleProtoLine(payload)
        if type(payload) ~= 'string' or payload == '' then return false end
        local parts = splitPipe(payload)
        local kind = parts[1]

        if kind == 'CACHE' then
            state.serverSupportsV2 = true
            state.protocolVersion  = tonumber(parts[2]) or 2
            local srv = {
                protocolVersion = tonumber(parts[2]) or 2,
                schemaVersion   = tonumber(parts[3]) or 1,
                minSchema       = tonumber(parts[4]) or 1,
                contentHash     = parts[5] or '',
                registryHash    = parts[6] or '',
                contentVersion  = parts[7] or '',
            }
            if dataService then
                local compat = dataService:apply_server_compat(srv)
                state.cacheNotice = dataService.error_message
                if compat == 'incompatible_schema' or compat == 'corrupt_local' then
                    state.catalogSource = 'none'
                    state.catalog = {}
                    state.catalogById = {}
                end
            end
            return true
        elseif kind == 'SYNC_END' then
            state.serverSupportsV2 = true
            state.syncPending = nil
            state.lastSyncError = nil
            if #(state.catalog or {}) == 0 then
                seedCatalogFromCache()
            end
            state.synced = true
            state.syncState = 'synced'
            state.lastSyncCompletedAt = clockFn()
            state.needsRefresh = false
            autoSelectEligibleWS()
            return true
        elseif kind == 'META' then
            local prevJob    = state.jobKey
            local prevSpec   = state.specName
            local prevMain   = state.mainSkill
            local prevRanged = state.rangedSkill
            state.jobKey      = parts[2] or '---'
            state.jobLevel    = tonumber(parts[3]) or 1
            state.avail       = tonumber(parts[4]) or 0
            state.spent       = tonumber(parts[5]) or 0
            state.earned      = tonumber(parts[6]) or 1
            state.mainSkill   = tonumber(parts[7]) or 0
            state.rangedSkill = tonumber(parts[8]) or 0
            state.rawSpecKey  = parts[9] or 'Base'
            state.specName    = resolveSpecDisplayName(parts[9])
            if parts[10] and parts[10] ~= '' then
                state.specKey = string.lower(parts[10])
            else
                local s = dataService and dataService:get_soul_by_key(parts[9])
                state.specKey = (s and s.internalKey and string.lower(s.internalKey))
                    or string.lower(tostring(parts[9] or 'base'))
            end

            if state.pendingOp and state.pendingOp.kind == 'reset_all' then
                state.pendingOp = nil
                state.wsDetailsById = {}
                if state.selectedWsId ~= nil then
                    requestWS(state.selectedWsId)
                end
            end

            -- Only treat as a real job/Soul transition when prevJob was already initialized (fixes initial double-OP_SYNC bug!).
            local wasInitialized = (prevJob ~= nil and prevJob ~= '---')
            if wasInitialized and (prevJob ~= state.jobKey or prevSpec ~= state.specName) then
                resetTransient()
                state.inspectedNodeKey = nil
                state.pendingOp        = nil
                state.rejectedNodeKey  = nil
                state.rejectedMsg      = nil
                state.wsDetailsById    = {}
                state.wsDetail         = nil
                state.wsRequest        = nil
                state.wsError          = nil
                if dataService then
                    dataService:invalidate_dynamic_state('job_or_soul_change:' .. tostring(state.jobKey) .. ':' .. tostring(state.specKey))
                end
                if type(onJobChange) == 'function' then
                    onJobChange(state)
                end
                if state.open[1] and state.syncPending == nil then
                    if isCompactEnabled() then
                        requestStateRefresh()
                    else
                        requestFullSync()
                    end
                end
            elseif (prevMain ~= state.mainSkill or prevRanged ~= state.rangedSkill) and state.selectedWsId == nil then
                autoSelectEligibleWS()
            end
            return true
        elseif kind == 'SPENT_BEGIN' then
            state.tempSpent    = {}
            state.tempUnlocked = {}
            return true
        elseif kind == 'SPENT' then
            state.tempSpent    = state.tempSpent or {}
            state.tempUnlocked = state.tempUnlocked or {}
            if parts[2] and parts[2] ~= '' then
                for entry in string.gmatch(parts[2], '([^,]+)') do
                    local wsId, pts, unl = string.match(entry, '^(%d+):(%d+):(%d+)$')
                    if not wsId then
                        wsId, pts = string.match(entry, '^(%d+):(%d+)$')
                        unl = (tonumber(pts) or 0) > 0 and '1' or '0'
                    end
                    if wsId and pts then
                        local idNum = tonumber(wsId)
                        state.tempSpent[idNum]    = tonumber(pts)
                        state.tempUnlocked[idNum] = (tonumber(unl) or 0) == 1
                    end
                end
            end
            return true
        elseif kind == 'SPENT_END' then
            if state.tempSpent ~= nil then
                state.spentByWs    = state.tempSpent
                state.unlockedByWs = state.tempUnlocked or {}
                state.tempSpent    = nil
                state.tempUnlocked = nil
            end
            -- When running against a legacy server with verified local cache (or state_refresh),
            -- SPENT_END completes sync cleanly without waiting for a 36-packet CAT stream!
            if state.syncPending and (state.syncPending.kind == 'legacy_state' or state.syncPending.kind == 'state_refresh') then
                if #(state.catalog or {}) == 0 then
                    seedCatalogFromCache()
                end
                state.syncPending = nil
                state.lastSyncError = nil
                state.synced = true
                state.syncState = 'synced'
                state.lastSyncCompletedAt = clockFn()
                state.needsRefresh = false
                autoSelectEligibleWS()
            end
            return true
        elseif kind == 'CAT_BEGIN' then
            state.tempCatalog = {}
            return true
        elseif kind == 'CAT' then
            state.tempCatalog = state.tempCatalog or {}
            if parts[2] and parts[2] ~= '' then
                for entry in string.gmatch(parts[2], '([^,]+)') do
                    local wsId, skillId, name, wsType = string.match(entry, '^(%d+):(%d+):(.+):([^:]+)$')
                    if wsId then
                        local idNum = tonumber(wsId)
                        table.insert(state.tempCatalog, {
                            id     = idNum,
                            skill  = tonumber(skillId),
                            name   = resolveWsDisplayName(idNum, name),
                            wsType = wsType,
                        })
                    end
                end
            end
            return true
        elseif kind == 'CAT_END' then
            if state.tempCatalog ~= nil then
                -- Never overwrite a populated verified catalog with an empty truncated stream!
                if #state.tempCatalog > 0 or #(state.catalog or {}) == 0 then
                    state.catalog = state.tempCatalog
                    state.catalogById = {}
                    for _, ws in ipairs(state.catalog) do
                        state.catalogById[ws.id] = ws
                    end
                    if #state.catalog > 0 then
                        state.catalogSource = 'server'
                    end
                end
                state.tempCatalog = nil
                state.syncPending = nil
                state.lastSyncError = nil
                state.synced = true
                state.syncState = 'synced'
                state.lastSyncCompletedAt = clockFn()
                state.needsRefresh = false
                autoSelectEligibleWS()
            end
            return true
        elseif kind == 'WSS_BEGIN' then
            state.serverSupportsV2 = true
            local wsIdNum = tonumber(parts[2])
            local scStr = parts[7] or '0:0:0:0'
            local s1, s2, s3, s4 = string.match(scStr, '^(%d+):(%d+):(%d+):(%d+)$')
            state.tempWss = {
                id         = wsIdNum,
                spent      = tonumber(parts[3]) or 0,
                avail      = tonumber(parts[4]) or state.avail,
                unlocked   = (tonumber(parts[5]) or 0) == 1,
                specKey    = string.lower(tostring(parts[6] or state.specKey or 'base')),
                scIds      = { tonumber(s1) or 0, tonumber(s2) or 0, tonumber(s3) or 0, tonumber(s4) or 0 },
                seq        = tonumber(parts[8]) or 0,
                nodeStates = {},
            }
            return true
        elseif kind == 'WSS' then
            local wsIdNum = tonumber(parts[2])
            if state.tempWss ~= nil and state.tempWss.id == wsIdNum and parts[3] and parts[3] ~= '' then
                for entry in string.gmatch(parts[3], '([^,]+)') do
                    local nk, r, cl = string.match(entry, '^([^=]+)=(%d+):(%d+)$')
                    if nk and r then
                        state.tempWss.nodeStates[nk] = {
                            rank     = tonumber(r) or 0,
                            canLearn = (tonumber(cl) or 0) == 1,
                        }
                    end
                end
            end
            return true
        elseif kind == 'WSS_END' then
            local wsIdNum = tonumber(parts[2])
            if state.tempWss ~= nil and state.tempWss.id == wsIdNum then
                local wss = state.tempWss
                state.tempWss = nil
                state.avail = tonumber(parts[3]) or wss.avail or state.avail
                if parts[4] ~= nil then
                    wss.unlocked = (tonumber(parts[4]) or 0) == 1
                end
                local assembled, err = assembleCachedWSDetail(wss)
                if assembled then
                    state.spentByWs[wsIdNum] = wss.spent or 0
                    state.unlockedByWs[wsIdNum] = wss.unlocked == true
                    state.wsDetail = assembled
                    state.wsDetailsById[wsIdNum] = assembled
                    state.wsError = nil
                    if state.wsRequest and state.wsRequest.wsId == wsIdNum then
                        state.wsRequest = nil
                    end
                    if state.pendingOp ~= nil then
                        state.pendingOp = nil
                        setStatus('Soulforge updated.')
                    end
                else
                    -- Cache missing this tree: fall back transparently to legacy OP_WS
                    if dataService then
                        dataService:record_event('oxtl', 'wss_fallback', tostring(err))
                    end
                    requestWS(wsIdNum, true)
                end
            end
            return true
        elseif kind == 'WS' then
            local wsIdNum = tonumber(parts[2])
            state.tempWs = {
                id        = wsIdNum,
                name      = resolveWsDisplayName(wsIdNum, parts[3] or 'Unknown'),
                skillName = parts[4] or '',
                wsType    = parts[5] or 'physical',
                spent     = tonumber(parts[6]) or 0,
                orig      = parts[7] or '',
                nodes     = {},
                byKey     = {},
                source    = 'server',
            }
            return true
        elseif kind == 'NODES' then
            local body = string.sub(payload, 7)
            local startPos = 1
            while startPos <= #body do
                local sepStart, sepEnd = string.find(body, ';;', startPos, true)
                local entry
                if sepStart then
                    entry = string.sub(body, startPos, sepStart - 1)
                    startPos = sepEnd + 1
                else
                    entry = string.sub(body, startPos)
                    startPos = #body + 1
                end
                if entry ~= '' then
                    handleProtoLine('NODE|' .. entry)
                end
            end
            return true
        elseif kind == 'NODE' then
            if state.tempWs ~= nil and tonumber(parts[2]) == state.tempWs.id then
                local nodeIdx = #state.tempWs.nodes + 1
                local node = {
                    idx         = nodeIdx,
                    slot        = tonumber(parts[18]) or nodeIdx,
                    key         = parts[3],
                    tier        = tonumber(parts[4]) or 1,
                    col         = tonumber(parts[5]) or 1,
                    rank        = tonumber(parts[6]) or 0,
                    maxRank     = tonumber(parts[7]) or 1,
                    canLearn    = (tonumber(parts[8]) or 0) == 1,
                    reqWsPoints = tonumber(parts[9]) or 0,
                    reqKey      = parts[10] ~= '' and parts[10] or nil,
                    reqRank     = tonumber(parts[11]) or 0,
                    name        = parts[12] or parts[3],
                    desc        = parts[13] or '',
                    reqLevel    = tonumber(parts[14]) or 1,
                    scTier      = tonumber(parts[15]) or 0,
                    scId        = tonumber(parts[16]) or 0,
                    scName      = parts[17] or '',
                    cost        = 1,
                }
                table.insert(state.tempWs.nodes, node)
                state.tempWs.byKey[node.key] = node
            end
            return true
        elseif kind == 'WS_END' then
            if state.tempWs ~= nil and tonumber(parts[2]) == state.tempWs.id then
                state.avail = tonumber(parts[3]) or state.avail
                state.spentByWs[state.tempWs.id] = state.tempWs.spent or 0
                if parts[4] ~= nil then
                    state.unlockedByWs[state.tempWs.id] = (tonumber(parts[4]) or 0) == 1
                else
                    state.unlockedByWs[state.tempWs.id] = (state.tempWs.spent or 0) > 0
                end
                state.wsDetail = state.tempWs
                state.wsDetailsById[state.tempWs.id] = state.tempWs
                state.wsError = nil
                if state.wsRequest and state.wsRequest.wsId == state.tempWs.id then
                    state.wsRequest = nil
                end
                state.tempWs = nil
                if state.pendingOp ~= nil then
                    state.pendingOp = nil
                    setStatus('Soulforge updated.')
                end
            end
            return true
        elseif kind == 'ERR' then
            local msg = parts[2] or 'Action failed.'
            if state.pendingOp and state.pendingOp.nodeKey then
                state.rejectedNodeKey = state.pendingOp.nodeKey
            else
                state.rejectedNodeKey = state.inspectedNodeKey
            end
            state.rejectedMsg = msg
            state.rejectedAt  = clockFn()
            state.pendingOp   = nil
            if state.wsRequest then
                state.wsError = msg
                state.wsRequest = nil
            end
            if state.ui then state.ui.confirmAction = nil end
            setStatus(msg)
            return true
        end
        return false
    end

    -- Handle incoming Ashita packet_in event (0x1FD OXTL or 0x017 [OXTAL]|)
    -- Returns true if the packet was an OXTL/OXTAL talent packet.
    local function handlePacketIn(id, data, size)
        if id == M.PACKET_S2C_ID then
            local sz = size or (type(data) == 'string' and #data or 0)
            if type(data) == 'string' and sz >= 12 and data:sub(5, 8) == 'OXTL' then
                local b11, b12 = data:byte(11, 12)
                local payLen = (b11 or 0) + (b12 or 0) * 256
                if dataService then
                    dataService:record_metric('packets_in_oxtl', 1)
                    dataService:record_metric('bytes_in_oxtl', sz)
                end
                if payLen > 0 and #data >= 12 + payLen then
                    local line = data:sub(13, 12 + payLen)
                    if line:sub(1, #M.PROTO_TAG) == M.PROTO_TAG then
                        line = line:sub(#M.PROTO_TAG + 1)
                    end
                    handleProtoLine(line)
                end
                return true
            end
        elseif id == 0x017 then
            if type(data) ~= 'string' or #data < 25 then return false end
            local msg = string.sub(data, 24):match('^([^%z]*)')
            if msg == nil or string.sub(msg, 1, #M.PROTO_TAG) ~= M.PROTO_TAG then
                return false
            end
            if dataService then
                dataService:record_metric('packets_in_oxtl', 1)
                dataService:record_metric('bytes_in_oxtl', #msg)
            end
            handleProtoLine(string.sub(msg, #M.PROTO_TAG + 1))
            return true
        end
        return false
    end

    local function cycleSkillFilter(dir)
        local curIdx = 1
        for i, sk in ipairs(M.SKILL_LIST) do
            if sk.id == state.selectedSkill then
                curIdx = i
                break
            end
        end
        local step = (dir and dir < 0) and -1 or 1
        local nextIdx = ((curIdx - 1 + step) % #M.SKILL_LIST) + 1
        state.selectedSkill = M.SKILL_LIST[nextIdx].id
        return M.SKILL_LIST[nextIdx]
    end

    local function getEquippedSummary()
        return M.getEquippedSummary(state)
    end

    local function getArsenalStatus(rows)
        return M.getArsenalStatus(state, rows or getFilteredCatalog())
    end

    local function applyFilterAction(kind)
        if kind == 'all_weapons' then
            state.selectedSkill = 0
            setStatus('Arsenal Filter: All Weapons')
            return true
        elseif kind == 'clear_invested' then
            state.investedOnly[1] = false
            setStatus('Showing all eligible weapon skills.')
            return true
        elseif kind == 'clear_search' then
            state.searchBuf[1] = ''
            setStatus('Cleared weapon skill search filter.')
            return true
        elseif kind == 'sync' then
            setStatus('Syncing weapon skill mastery from server...')
            requestFullSync()
            return true
        end
        return false
    end

    local actions = {
        send               = sendTalentPacket,
        requestWS          = requestWS,
        sync               = requestFullSync,
        refreshState       = requestStateRefresh,
        invalidate         = invalidateForLifecycle,
        tick               = tick,
        seedFromCache      = seedCatalogFromCache,
        filtered           = getFilteredCatalog,
        skills             = M.SKILL_LIST,
        cycleSkillFilter   = cycleSkillFilter,
        getEquippedSummary = getEquippedSummary,
        getArsenalStatus   = getArsenalStatus,
        applyFilterAction  = applyFilterAction,
        investNode         = investNode,
        refundNode         = refundNode,
        cycleSkillchain    = cycleSkillchain,
        resetWS            = resetWS,
        resetAll           = resetAll,
        setStatus          = setStatus,
        isPendingActive    = isPendingActive,
        handleProtoLine    = handleProtoLine,
        handlePacketIn     = handlePacketIn,
        resetTransient     = resetTransient,
        savePrefs          = onSavePrefs,
        dataService        = dataService,
    }

    return state, actions
end

return M
