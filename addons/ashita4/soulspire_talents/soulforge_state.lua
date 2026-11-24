-- SoulspireXI — Shared Soulforge State & Server-Authoritative Protocol Controller
-- Reused by both standalone soulspire_talents (/talents) and unified soulspire_core
-- (Weapon Mastery & Soul Talents modules) so there is zero protocol or state duplication.
--
-- Protocol (preserved unchanged):
--   C2S: 0x11F ("OXTL") ops 1..8
--   S2C: 0x1FD ("OXTL") and 0x017 ("[OXTAL]|...")

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
            body        = 'Waiting for server weapon skill catalog and mastery state.',
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

    if not state.synced then
        return {
            kind        = 'loading',
            title       = 'SYNCING ARSENAL...',
            body        = 'Requesting server-authoritative weapon skill catalog and mastery state...',
            action      = 'sync',
            actionLabel = 'RETRY SYNC',
        }
    end

    if #(state.catalog or {}) == 0 then
        return {
            kind        = 'catalog_empty',
            title       = 'ARSENAL UNAVAILABLE',
            body        = 'No weapon skills were received from the server catalog. Click SYNC or press [A] to retry.',
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
    local sendFn       = opts.sendPacket
    local clockFn      = opts.clock or os.clock
    local onJobChange  = opts.onJobChange
    local onSavePrefs  = opts.savePrefs

    local function resolveSpecDisplayName(raw)
        if type(raw) ~= 'string' or raw == '' or raw == 'Base' then return 'Base' end
        if soulRegistry and soulRegistry.displayName then
            return soulRegistry.displayName(raw, raw)
        end
        return raw
    end

    local function resolveWsDisplayName(wsId, raw)
        if wsRegistry and wsRegistry.displayName and wsId then
            return wsRegistry.displayName(wsId, raw)
        end
        return raw
    end

    local state = {
        open                = { false },
        synced              = false,
        syncState           = 'idle', -- 'idle' | 'loading' | 'synced'
        syncRequestedAt     = 0,
        lastSyncCompletedAt = 0,
        needsRefresh        = false,
        jobKey              = '---',
        specName         = 'Base',
        rawSpecKey       = 'Base',
        jobLevel         = 1,
        avail            = 0,
        spent            = 0,
        earned           = 1,
        mainSkill        = 0,
        rangedSkill      = 0,
        catalog          = {},
        catalogById      = {},
        tempCatalog      = nil,
        spentByWs        = {},
        unlockedByWs     = {},
        wsDetailsById    = {}, -- cached per-WS detail for Soul Talents overview
        tempSpent        = nil,
        tempUnlocked     = nil,
        selectedSkill    = -1,
        selectedWsId     = nil,
        wsDetail         = nil,
        tempWs           = nil,
        searchBuf        = { '' },
        investedOnly     = { false },
        confirmResetAll  = false,
        confirmResetAt   = 0,
        statusText       = nil,
        statusTime       = 0,
        pendingOp        = nil,
        rejectedNodeKey  = nil,
        rejectedMsg      = nil,
        rejectedAt       = nil,
        lastKnownJob     = nil,
        lastKnownLvl     = nil,
        lastAutoCheck    = 0,
        inspectedNodeKey = nil,
        renderError      = nil,
        uiFont           = nil,
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

    local function sendTalentPacket(op, wsId, arg1, arg2)
        local bytes = M.encodePacket(op, wsId, arg1, arg2)
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
        if (clockFn() - (state.pendingOp.sentAt or 0)) < 5.0 then
            return true
        end
        state.pendingOp = nil
        setStatus('Server request timed out — click SYNC to refresh.')
        return false
    end

    local function requestWS(wsId)
        if wsId == nil then return end
        state.selectedWsId = wsId
        if state.wsDetailsById[wsId] and (not state.wsDetail or state.wsDetail.id ~= wsId) then
            state.wsDetail = state.wsDetailsById[wsId]
        end
        sendTalentPacket(M.OP_WS, wsId, 0, 0)
    end

    local function requestFullSync()
        state.syncRequestedAt = clockFn()
        if not state.synced or #(state.catalog or {}) == 0 then
            state.syncState = 'loading'
        end
        state.needsRefresh = false
        sendTalentPacket(M.OP_SYNC, 0, 0, 0)
    end

    local function requestStateRefresh()
        state.needsRefresh = false
        sendTalentPacket(M.OP_STATE, 0, 0, 0)
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
        sendTalentPacket(M.OP_INVEST, wsId, node.idx or 0, 0)
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
        sendTalentPacket(M.OP_REFUND, wsId, node.idx or 0, 0)
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
        sendTalentPacket(M.OP_CYCLE_SC, wsId, tier, dir or 1)
        return true
    end

    local function resetWS(wsId)
        if not wsId or isPendingActive() then return false end
        state.pendingOp = { kind = 'reset_ws', wsId = wsId, sentAt = clockFn() }
        setStatus('Resetting weapon skill talents...')
        sendTalentPacket(M.OP_RESET_WS, wsId, 0, 0)
        return true
    end

    local function resetAll()
        if isPendingActive() then return false end
        state.pendingOp = { kind = 'reset_all', wsId = 0, sentAt = clockFn() }
        setStatus('Resetting all weapon skill talents for ' .. tostring(state.specName) .. '...')
        sendTalentPacket(M.OP_RESET_ALL, 0, 0, 0)
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
            if state.wsDetail == nil or state.wsDetail.id ~= state.selectedWsId then
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

    local function handleProtoLine(payload)
        if type(payload) ~= 'string' or payload == '' then return false end
        local parts = splitPipe(payload)
        local kind = parts[1]

        if kind == 'META' then
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
            if state.pendingOp and state.pendingOp.kind == 'reset_all' then
                state.pendingOp = nil
                state.wsDetailsById = {}
                if state.selectedWsId ~= nil then
                    requestWS(state.selectedWsId)
                end
            end
            if prevJob ~= state.jobKey or prevSpec ~= state.specName then
                resetTransient()
                state.inspectedNodeKey = nil
                state.pendingOp        = nil
                state.rejectedNodeKey  = nil
                state.rejectedMsg      = nil
                state.wsDetailsById    = {}
                if type(onJobChange) == 'function' then
                    onJobChange(state)
                end
                if state.open[1] then
                    requestFullSync()
                end
            elseif (prevMain ~= state.mainSkill or prevRanged ~= state.rangedSkill) and state.selectedWsId == nil then
                -- Character equipped an eligible weapon after initial sync: auto-open its first eligible WS
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
                state.catalog = state.tempCatalog
                state.catalogById = {}
                for _, ws in ipairs(state.catalog) do
                    state.catalogById[ws.id] = ws
                end
                state.tempCatalog = nil
                state.synced = true
                state.syncState = 'synced'
                state.lastSyncCompletedAt = clockFn()
                state.needsRefresh = false
                autoSelectEligibleWS()
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
                    cost        = math.max(1, tonumber(parts[18]) or 1),
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
            setStatus('Syncing weapon skill Arsenal from server...')
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
    }

    return state, actions
end

return M
