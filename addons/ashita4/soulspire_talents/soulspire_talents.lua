--[[
* SoulspireXI - The Soulforge (Weaponskill Talent Tree Addon for Ashita v4)
*
* Communicates silently with the LandSandBoat !talent system using
* 0x11F C2S / 0x1FD S2C ("OXTL") and [OXTAL]|... tagged 0x017 packets.
*
* Commands:
*   /talents                  - Toggle The Soulforge window
*   /tal                      - Alias for /talents
*   /talents sync             - Force resync catalog & points from server
*   /talents scale <0.75-1.5> - Set independent UI scale preference
*   /talents zoom <0.75-1.35> - Set talent canvas zoom preference
*   /talents resetview        - Reset canvas pan/zoom and UI scale
--]]

addon.name    = 'soulspire_talents'
addon.author  = 'SoulspireXI'
addon.version = '3.0.0'
addon.desc    = 'The Soulforge: unified Weaponskill Mastery & Talent Tree UI for SoulspireXI.'

require('common')
local imgui       = require('imgui')
local soulforgeUI = require('soulforge_ui')

local PROTO_TAG     = '[OXTAL]|'
local PACKET_C2S_ID = 0x11F
local PACKET_S2C_ID = 0x1FD
local OP_SYNC       = 1
local OP_STATE      = 2
local OP_WS         = 3
local OP_INVEST     = 4
local OP_REFUND     = 5
local OP_CYCLE_SC   = 6
local OP_RESET_WS   = 7
local OP_RESET_ALL  = 8

local SKILL_LIST = {
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

local okReg, soulRegistry = pcall(require, 'soul_registry_generated')
if not okReg or type(soulRegistry) ~= 'table' then soulRegistry = nil end
local okWsReg, wsRegistry = pcall(require, 'ws_registry_generated')
if not okWsReg or type(wsRegistry) ~= 'table' then wsRegistry = nil end

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
    open             = { false },
    synced           = false,
    syncRequestedAt  = 0,
    jobKey           = '---',
    specName         = 'Base',
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
        scale           = 1.0,
        canvasZoom      = 1.0,
        panX            = 0,
        panY            = 0,
        drawerOpen      = nil,
        confirmAction   = nil,
        confirmResetWs  = false,
        confirmResetWsAt = 0,
        lastViewportW   = 0,
        lastViewportH   = 0,
    },
}

-- ---------------------------------------------------------------------------
-- Local Display Preferences (never touches server-authoritative progression)
-- ---------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function getPrefsPath()
    if AshitaCore == nil or not AshitaCore.GetInstallPath then return nil, nil end
    local ok, installPath = pcall(function() return AshitaCore:GetInstallPath() end)
    if not ok or type(installPath) ~= 'string' or installPath == '' then return nil, nil end
    local folder = installPath:gsub('[/\\]+$', '') .. '\\config\\addons\\soulspire_talents'
    return folder, folder .. '\\settings.lua'
end

local function savePrefs()
    pcall(function()
        local folder, path = getPrefsPath()
        if not folder or not path then return end
        if ashita and ashita.fs and ashita.fs.exists and ashita.fs.create_directory then
            if not ashita.fs.exists(folder) then
                ashita.fs.create_directory(folder)
            end
        end
        local f = io.open(path, 'w')
        if f then
            f:write(string.format(
                '-- SoulspireXI The Soulforge display preferences\nreturn { scale = %.2f, canvasZoom = %.2f }\n',
                clamp(tonumber(state.ui.scale) or 1.0, 0.75, 1.50),
                clamp(tonumber(state.ui.canvasZoom) or 1.0, 0.75, 1.35)
            ))
            f:close()
        end
    end)
end

local function loadPrefs()
    pcall(function()
        local _, path = getPrefsPath()
        if not path then return end
        local f = io.open(path, 'r')
        if not f then return end
        f:close()
        local loader = loadfile(path)
        if not loader then return end
        if setfenv then setfenv(loader, {}) end
        local ok, data = pcall(loader)
        if ok and type(data) == 'table' then
            if tonumber(data.scale) then
                state.ui.scale = clamp(tonumber(data.scale), 0.75, 1.50)
            end
            if tonumber(data.canvasZoom) then
                state.ui.canvasZoom = clamp(tonumber(data.canvasZoom), 0.75, 1.35)
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Authoritative Protocol Helpers (preserved unchanged)
-- ---------------------------------------------------------------------------
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

local function sendTalentPacket(op, wsId, arg1, arg2)
    local w = tonumber(wsId) or 0
    local a1 = (tonumber(arg1) or 0) % 256
    local a2 = (tonumber(arg2) or 0) % 256
    local pkt = string.char(0x1F, 0x09, 0x00, 0x00)
        .. 'OXTL'
        .. string.char(1, op % 256, w % 256, math.floor(w / 256) % 256, a1, a2, 0, 0)
    local bytes = { pkt:byte(1, #pkt) }
    AshitaCore:GetPacketManager():AddOutgoingPacket(PACKET_C2S_ID, bytes)
end

local function setStatus(msg)
    state.statusText = msg
    state.statusTime = os.clock()
end

local function isPendingActive()
    return state.pendingOp ~= nil and (os.clock() - (state.pendingOp.sentAt or 0)) < 5.0
end

local function requestWS(wsId)
    if wsId == nil then return end
    state.selectedWsId = wsId
    sendTalentPacket(OP_WS, wsId, 0, 0)
end

local function requestFullSync()
    state.syncRequestedAt = os.clock()
    sendTalentPacket(OP_SYNC, 0, 0, 0)
end

local function investNode(wsId, node)
    if not wsId or not node or isPendingActive() then return end
    state.inspectedNodeKey = node.key
    state.rejectedNodeKey = nil
    state.rejectedMsg = nil
    state.pendingOp = {
        kind    = 'invest',
        wsId    = wsId,
        nodeKey = node.key,
        nodeIdx = node.idx or 0,
        sentAt  = os.clock(),
    }
    setStatus('Forging ' .. tostring(node.name or node.key) .. '...')
    sendTalentPacket(OP_INVEST, wsId, node.idx or 0, 0)
end

local function refundNode(wsId, node)
    if not wsId or not node or isPendingActive() then return end
    state.inspectedNodeKey = node.key
    state.rejectedNodeKey = nil
    state.rejectedMsg = nil
    state.pendingOp = {
        kind    = 'refund',
        wsId    = wsId,
        nodeKey = node.key,
        nodeIdx = node.idx or 0,
        sentAt  = os.clock(),
    }
    setStatus('Refunding ' .. tostring(node.name or node.key) .. '...')
    sendTalentPacket(OP_REFUND, wsId, node.idx or 0, 0)
end

local function cycleSkillchain(wsId, tier, dir)
    if not wsId or not tier or isPendingActive() then return end
    state.pendingOp = {
        kind   = 'sc',
        wsId   = wsId,
        tier   = tier,
        sentAt = os.clock(),
    }
    sendTalentPacket(OP_CYCLE_SC, wsId, tier, dir or 1)
end

local function resetWS(wsId)
    if not wsId or isPendingActive() then return end
    state.pendingOp = { kind = 'reset_ws', wsId = wsId, sentAt = os.clock() }
    setStatus('Resetting weapon skill talents...')
    sendTalentPacket(OP_RESET_WS, wsId, 0, 0)
end

local function resetAll()
    if isPendingActive() then return end
    state.pendingOp = { kind = 'reset_all', wsId = 0, sentAt = os.clock() }
    setStatus('Resetting all weapon skill talents for ' .. tostring(state.specName) .. '...')
    sendTalentPacket(OP_RESET_ALL, 0, 0, 0)
end

-- ---------------------------------------------------------------------------
-- Protocol Parser
-- ---------------------------------------------------------------------------
local function handleProtoLine(payload)
    local parts = splitPipe(payload)
    local kind = parts[1]

    if kind == 'META' then
        local prevJob  = state.jobKey
        local prevSpec = state.specName
        state.jobKey      = parts[2] or '---'
        state.jobLevel    = tonumber(parts[3]) or 1
        state.avail       = tonumber(parts[4]) or 0
        state.spent       = tonumber(parts[5]) or 0
        state.earned      = tonumber(parts[6]) or 1
        state.mainSkill   = tonumber(parts[7]) or 0
        state.rangedSkill = tonumber(parts[8]) or 0
        state.specName    = resolveSpecDisplayName(parts[9])
        if state.pendingOp and state.pendingOp.kind == 'reset_all' then
            state.pendingOp = nil
        end
        if (prevJob ~= state.jobKey or prevSpec ~= state.specName) and state.selectedWsId ~= nil and state.open[1] then
            requestWS(state.selectedWsId)
        end
    elseif kind == 'SPENT_BEGIN' then
        state.tempSpent    = {}
        state.tempUnlocked = {}
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
    elseif kind == 'SPENT_END' then
        if state.tempSpent ~= nil then
            state.spentByWs    = state.tempSpent
            state.unlockedByWs = state.tempUnlocked or {}
            state.tempSpent    = nil
            state.tempUnlocked = nil
        end
    elseif kind == 'CAT_BEGIN' then
        state.tempCatalog = {}
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
    elseif kind == 'CAT_END' then
        if state.tempCatalog ~= nil then
            state.catalog = state.tempCatalog
            state.catalogById = {}
            for _, ws in ipairs(state.catalog) do
                state.catalogById[ws.id] = ws
            end
            state.tempCatalog = nil
            state.synced = true
            if state.selectedWsId == nil then
                for _, ws in ipairs(state.catalog) do
                    if ws.skill == state.mainSkill or ws.skill == state.rangedSkill then
                        requestWS(ws.id)
                        break
                    end
                end
            elseif state.wsDetail == nil or state.wsDetail.id ~= state.selectedWsId then
                requestWS(state.selectedWsId)
            end
        end
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
            state.tempWs = nil
            if state.pendingOp ~= nil then
                state.pendingOp = nil
                setStatus('Soulforge updated.')
            end
        end
    elseif kind == 'ERR' then
        local msg = parts[2] or 'Action failed.'
        if state.pendingOp and state.pendingOp.nodeKey then
            state.rejectedNodeKey = state.pendingOp.nodeKey
        else
            state.rejectedNodeKey = state.inspectedNodeKey
        end
        state.rejectedMsg = msg
        state.rejectedAt  = os.clock()
        state.pendingOp   = nil
        setStatus(msg)
    end
end

-- ---------------------------------------------------------------------------
-- Catalog Filtering
-- ---------------------------------------------------------------------------
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
            matchSkill = (ws.skill == state.mainSkill) or (state.rangedSkill ~= 0 and ws.skill == state.rangedSkill)
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

local actions = {
    send            = sendTalentPacket,
    requestWS       = requestWS,
    sync            = requestFullSync,
    filtered        = getFilteredCatalog,
    skills          = SKILL_LIST,
    investNode      = investNode,
    refundNode      = refundNode,
    cycleSkillchain = cycleSkillchain,
    resetWS         = resetWS,
    resetAll        = resetAll,
    savePrefs       = savePrefs,
}

-- ---------------------------------------------------------------------------
-- ImGui Theme Push (aligns native ImGui combos/inputs to SoulspireXI palette)
-- ---------------------------------------------------------------------------
local function pushSoulforgeImGuiStyle()
    local pushed = 0
    if not (imgui.PushStyleColor and imgui.PopStyleColor) then return 0 end
    local function pc(id, col)
        if id ~= nil and col ~= nil then
            imgui.PushStyleColor(id, col)
            pushed = pushed + 1
        end
    end
    pc(ImGuiCol_PopupBg,        { 0.043, 0.063, 0.098, 0.98 }) -- Abyss #0B1019
    pc(ImGuiCol_Border,         { 0.910, 0.741, 0.439, 0.75 }) -- Soul Gold #E8BD70
    pc(ImGuiCol_FrameBg,        { 0.082, 0.098, 0.157, 0.98 }) -- Midnight #151928
    pc(ImGuiCol_FrameBgHovered, { 0.125, 0.157, 0.247, 1.00 })
    pc(ImGuiCol_FrameBgActive,  { 0.157, 0.196, 0.302, 1.00 })
    pc(ImGuiCol_Header,         { 0.141, 0.173, 0.267, 0.95 })
    pc(ImGuiCol_HeaderHovered,  { 0.224, 0.812, 0.898, 0.28 }) -- Aether Cyan tint
    pc(ImGuiCol_HeaderActive,   { 0.910, 0.741, 0.439, 0.35 }) -- Soul Gold tint
    pc(ImGuiCol_CheckMark,      { 0.910, 0.741, 0.439, 1.00 })
    pc(ImGuiCol_Text,           { 0.945, 0.961, 0.976, 1.00 })
    return pushed
end

-- ---------------------------------------------------------------------------
-- Ashita v4 Events
-- ---------------------------------------------------------------------------
ashita.events.register('load', 'ox_talents_load', function()
    loadPrefs()
    if imgui.AddFontFromFileTTF then
        local fontPaths = {
            'C:\\Windows\\Fonts\\segoeui.ttf',
            'C:\\Windows\\Fonts\\arial.ttf',
        }
        for _, fontPath in ipairs(fontPaths) do
            local ok, font = pcall(imgui.AddFontFromFileTTF, fontPath, 16)
            if ok and font ~= nil then
                state.uiFont = font
                break
            end
        end
    end

    local player = AshitaCore:GetMemoryManager():GetPlayer()
    if player ~= nil and player:GetMainJob() > 0 then
        local getLvl = player.GetMainJobLevel or player.GetMainLevel
        state.lastKnownJob = player:GetMainJob()
        state.lastKnownLvl = getLvl and getLvl(player) or 1
        requestFullSync()
    end
end)

ashita.events.register('command', 'ox_talents_cmd', function(e)
    local args = e.command:args()
    if #args == 0 then return end

    local cmd = string.lower(args[1])
    if cmd ~= '/talents' and cmd ~= '/tal' then return end
    e.blocked = true

    local sub = args[2] and string.lower(args[2]) or ''
    if sub == 'sync' then
        requestFullSync()
        setStatus('Syncing weaponskill talents from server...')
        return
    elseif sub == 'scale' then
        local n = tonumber(args[3])
        if n then
            state.ui.scale = clamp(n, 0.75, 1.50)
            savePrefs()
            setStatus(string.format('Soulforge UI scale set to %d%%.', math.floor(state.ui.scale * 100 + 0.5)))
        end
        return
    elseif sub == 'zoom' then
        local n = tonumber(args[3])
        if n then
            state.ui.canvasZoom = clamp(n, 0.75, 1.35)
            savePrefs()
            setStatus(string.format('Soulforge canvas zoom set to %d%%.', math.floor(state.ui.canvasZoom * 100 + 0.5)))
        end
        return
    elseif sub == 'resetview' then
        state.ui.scale = 1.0
        state.ui.canvasZoom = 1.0
        state.ui.panX, state.ui.panY = 0, 0
        state.ui.drawerOpen = nil
        savePrefs()
        setStatus('Soulforge view reset to defaults.')
        return
    end

    state.open[1] = not state.open[1]
    if state.open[1] then
        if not state.synced then
            requestFullSync()
        else
            sendTalentPacket(OP_STATE, 0, 0, 0)
            if state.selectedWsId ~= nil then
                requestWS(state.selectedWsId)
            end
        end
    end
end)

ashita.events.register('packet_in', 'ox_talents_packet_in', function(e)
    if e.id == PACKET_S2C_ID then
        local buf = e.data_modified or e.data
        local sz  = e.size or (type(buf) == 'string' and #buf or 0)
        if type(buf) == 'string' and sz >= 12 and buf:sub(5, 8) == 'OXTL' then
            e.blocked = true
            local b11, b12 = buf:byte(11, 12)
            local payLen = (b11 or 0) + (b12 or 0) * 256
            if payLen > 0 and #buf >= 12 + payLen then
                local line = buf:sub(13, 12 + payLen)
                if line:sub(1, #PROTO_TAG) == PROTO_TAG then
                    line = line:sub(#PROTO_TAG + 1)
                end
                handleProtoLine(line)
            end
            return
        end
    end

    if e.id ~= 0x017 then return end
    if #e.data < 25 then return end

    local msg = string.sub(e.data, 24):match('^([^%z]*)')
    if msg == nil or string.sub(msg, 1, #PROTO_TAG) ~= PROTO_TAG then return end

    e.blocked = true
    handleProtoLine(string.sub(msg, #PROTO_TAG + 1))
end)

ashita.events.register('d3d_present', 'ox_talents_present', function()
    local now = os.clock()
    if now - state.lastAutoCheck >= 1.0 then
        state.lastAutoCheck = now
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        if player ~= nil and player:GetMainJob() > 0 then
            local getLvl = player.GetMainJobLevel or player.GetMainLevel
            local j = player:GetMainJob()
            local l = getLvl and getLvl(player) or 1
            if state.lastKnownJob ~= nil and (j ~= state.lastKnownJob or l ~= state.lastKnownLvl) then
                if state.open[1] then
                    sendTalentPacket(OP_STATE, 0, 0, 0)
                end
            end
            state.lastKnownJob = j
            state.lastKnownLvl = l
        end
    end

    if not state.open[1] then return end

    if not state.synced and (now - (state.syncRequestedAt or 0)) >= 4.0 then
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        if player ~= nil and player:GetMainJob() > 0 then
            requestFullSync()
        end
    end

    local pushedCols = pushSoulforgeImGuiStyle()
    local fontPushed = false
    if state.uiFont ~= nil and imgui.PushFont then
        fontPushed = pcall(imgui.PushFont, state.uiFont, math.floor(16 * (state.ui.scale or 1.0) + 0.5))
    end

    local okWin, errWin = xpcall(function()
        soulforgeUI.draw(state, actions)
    end, debug.traceback)
    if not okWin then
        state.renderError = tostring(errWin)
    else
        state.renderError = nil
    end

    if fontPushed and imgui.PopFont then
        imgui.PopFont()
    end
    if pushedCols > 0 then
        imgui.PopStyleColor(pushedCols)
    end
end)

ashita.events.register('unload', 'ox_talents_soulforge_unload', function()
    savePrefs()
    soulforgeUI.unload()
end)
