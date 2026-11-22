--[[
* SoulspireXI - Weaponskill Talent Tree Addon for Ashita v4
*
* Communicates silently with the LandSandBoat !talent command using
* [OXTAL]|... tagged 0x017 packets (blocked from the chat log).
*
* Commands:
*   /talents         - Toggle the talent tree window
*   /tal             - Alias for /talents
*   /talents sync    - Force resync catalog & points from server
--]]

addon.name    = 'soulspire_talents'
addon.author  = 'SoulspireXI'
addon.version = '2.0.0'
addon.desc    = 'Per-weaponskill talent tree UI for SoulspireXI.'

require('common')
local bit   = require('bit')
local imgui = require('imgui')
local premiumUI = require('premium_ui')

local PROTO_TAG         = '[OXTAL]|'
local PACKET_C2S_ID     = 0x11F
local PACKET_S2C_ID     = 0x1FD
local OP_SYNC           = 1
local OP_STATE          = 2
local OP_WS             = 3
local OP_INVEST         = 4
local OP_REFUND         = 5
local OP_CYCLE_SC       = 6
local OP_RESET_WS       = 7
local OP_RESET_ALL      = 8
local CHILD_NONE        = ImGuiChildFlags_None or 0
local CHILD_BORDERS     = ImGuiChildFlags_Borders or ImGuiChildFlags_Border or 1
local COL_TEXT          = ImGuiCol_Text or 0
local COL_TEXT_DISABLED = { 0.62, 0.64, 0.68, 1.00 }

local function drawText(str)
    local s = tostring(str or '')
    if imgui.TextUnformatted then
        imgui.TextUnformatted(s)
    else
        imgui.Text((s:gsub('%%', '%%%%')))
    end
end

local function drawTextColored(col, str)
    local s = tostring(str or '')
    if imgui.TextUnformatted and imgui.PushStyleColor and imgui.PopStyleColor then
        imgui.PushStyleColor(COL_TEXT, col)
        local ok, err = pcall(imgui.TextUnformatted, s)
        imgui.PopStyleColor()
        if not ok then
            error(err)
        end
    else
        imgui.TextColored(col, (s:gsub('%%', '%%%%')))
    end
end

local function drawTextDisabled(str)
    drawTextColored(COL_TEXT_DISABLED, str)
end

local SKILL_LIST =
{
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
local function resolveSpecDisplayName(raw)
    if type(raw) ~= 'string' or raw == '' or raw == 'Base' then return 'Base' end
    if soulRegistry and soulRegistry.displayName then
        return soulRegistry.displayName(raw, raw)
    end
    return raw
end

local state =
{
    open            = { false },
    synced          = false,
    syncRequestedAt = 0,
    jobKey          = '---',
    specName        = 'Base',
    jobLevel        = 1,
    avail           = 0,
    spent           = 0,
    earned          = 1,
    mainSkill       = 0,
    rangedSkill     = 0,
    catalog         = {},       -- ordered list of { id, skill, name, wsType }
    catalogById     = {},
    tempCatalog     = nil,
    spentByWs       = {},
    unlockedByWs    = {},
    tempSpent       = nil,
    tempUnlocked    = nil,
    selectedSkill   = -1,       -- -1 = Equipped
    selectedWsId    = nil,
    wsDetail        = nil,      -- { id, name, skillName, wsType, spent, orig, nodes = {} }
    tempWs          = nil,
    searchBuf       = { '' },
    investedOnly    = { false },
    confirmResetAll = false,
    confirmResetAt  = 0,
    statusText      = nil,
    statusTime      = 0,
    lastKnownJob    = nil,
    lastKnownLvl    = nil,
    lastAutoCheck   = 0,
    inspectedNodeKey = nil,
    renderError     = nil,
    renderStyle     = 1,
    uiFont          = nil,
}

local RENDER_STYLES =
{
    { id = 1, key = 'crystal',       name = 'Crystal Lattice' },
    { id = 2, key = 'constellation', name = 'Astral Constellation' },
    { id = 3, key = 'imperial',      name = 'Imperial Relic' },
}

local function abgr(r, g, b, a)
    if imgui.ColorConvertFloat4ToU32 then
        return imgui.ColorConvertFloat4ToU32({ r, g, b, a or 1.0 })
    end
    local val = bit.bor(
        bit.lshift(math.floor((a or 1) * 255), 24),
        bit.lshift(math.floor(b * 255), 16),
        bit.lshift(math.floor(g * 255), 8),
        math.floor(r * 255)
    )
    if val < 0 then
        val = val + 4294967296
    end
    return val
end

local function toXY(a, b)
    if type(a) == 'table' then
        return a[1] or a.x or 0, a[2] or a.y or 0
    end
    return a or 0, b or 0
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

local function requestWS(wsId)
    if wsId == nil then
        return
    end
    state.selectedWsId = wsId
    sendTalentPacket(OP_WS, wsId, 0, 0)
end

local function requestFullSync()
    state.syncRequestedAt = os.clock()
    sendTalentPacket(OP_SYNC, 0, 0, 0)
end

-----------------------------------
-- Protocol Parser
-----------------------------------
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
                    table.insert(state.tempCatalog,
                    {
                        id     = tonumber(wsId),
                        skill  = tonumber(skillId),
                        name   = name,
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
        state.tempWs =
        {
            id        = tonumber(parts[2]),
            name      = parts[3] or 'Unknown',
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
            local node =
            {
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
        end
    elseif kind == 'ERR' then
        setStatus(parts[2] or 'Action failed.')
    end
end

-----------------------------------
-- Ashita Events
-----------------------------------
ashita.events.register('load', 'ox_talents_load', function()
    -- The built-in ProggyClean bitmap font is visibly distorted by some FFXI
    -- backbuffer / UI-scale combinations. Use a normal TrueType UI font at a
    -- fixed pixel size so glyphs retain their intended aspect ratio.
    if imgui.AddFontFromFileTTF then
        local fontPaths = {
            'C:\\Windows\\Fonts\\segoeui.ttf',
            'C:\\Windows\\Fonts\\arial.ttf',
        }
        for _, fontPath in ipairs(fontPaths) do
            local ok, font = pcall(imgui.AddFontFromFileTTF, fontPath, 17)
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
    if #args == 0 then
        return
    end

    local cmd = string.lower(args[1])
    if cmd ~= '/talents' and cmd ~= '/tal' then
        return
    end

    e.blocked = true

    if args[2] ~= nil and string.lower(args[2]) == 'sync' then
        requestFullSync()
        setStatus('Syncing weaponskill talents from server...')
        return
    end

    if args[2] ~= nil and string.lower(args[2]) == 'style' then
        local q = string.lower(tostring(args[3] or ''))
        local num = tonumber(q)
        if num ~= nil and RENDER_STYLES[num] ~= nil then
            state.renderStyle = num
            setStatus('Render style: ' .. RENDER_STYLES[num].name)
        elseif q ~= '' then
            for _, st in ipairs(RENDER_STYLES) do
                if string.find(string.lower(st.name), q, 1, true) or st.key == q then
                    state.renderStyle = st.id
                    setStatus('Render style: ' .. st.name)
                    break
                end
            end
        else
            state.renderStyle = (state.renderStyle % #RENDER_STYLES) + 1
            setStatus('Render style: ' .. RENDER_STYLES[state.renderStyle].name)
        end
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

    if e.id ~= 0x017 then
        return
    end

    if #e.data < 25 then
        return
    end

    local msg = string.sub(e.data, 24):match('^([^%z]*)')
    if msg == nil or string.sub(msg, 1, #PROTO_TAG) ~= PROTO_TAG then
        return
    end

    e.blocked = true
    handleProtoLine(string.sub(msg, #PROTO_TAG + 1))
end)

-----------------------------------
-- ImGui Tree Renderer
-----------------------------------
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

local function isWsUnlockedInDetail(detail)
    if detail == nil then
        return false
    end
    for _, node in ipairs(detail.nodes or {}) do
        if node.tier == 1 and (node.rank or 0) >= 1 then
            return true
        end
    end
    return state.unlockedByWs[detail.id] == true
end

local function colU32(r, g, b, a)
    return abgr(r, g, b, a or 1.0)
end

local function buildPalette(cfg)
    local p = {}
    for k, v in pairs(cfg) do
        p[k] = v
    end
    return p
end

local PALETTES =
{
    -- 1: Crystal Lattice (FFXI Obsidian-Bronze & Crystal Glow)
    [1] = buildPalette({
        id           = 1,
        winBg        = { 0.07, 0.05, 0.04, 0.97 },
        childBg      = { 0.10, 0.07, 0.05, 0.94 },
        popupBg      = { 0.09, 0.06, 0.05, 0.97 },
        border       = { 0.36, 0.25, 0.17, 0.92 },
        titleBg      = { 0.11, 0.07, 0.05, 1.00 },
        titleBgAct   = { 0.20, 0.13, 0.08, 1.00 },
        frameBg      = { 0.15, 0.10, 0.07, 1.00 },
        frameBgHov   = { 0.23, 0.15, 0.10, 1.00 },
        button       = { 0.24, 0.16, 0.10, 1.00 },
        buttonHov    = { 0.36, 0.24, 0.15, 1.00 },
        buttonAct    = { 0.45, 0.30, 0.18, 1.00 },
        header       = { 0.30, 0.20, 0.12, 0.90 },
        headerHov    = { 0.38, 0.26, 0.16, 0.95 },
        headerAct    = { 0.46, 0.32, 0.19, 1.00 },
        separator    = { 0.36, 0.25, 0.17, 0.85 },

        cardRounding = 5.0,
        canvasDot    = colU32(0.45, 0.33, 0.23, 0.22),
        tierRule     = colU32(0.34, 0.24, 0.17, 0.55),
        tierRuleLit  = colU32(0.88, 0.73, 0.38, 0.65),
        bgCardMax    = colU32(0.18, 0.14, 0.07, 0.98),
        bgCardActive = colU32(0.09, 0.15, 0.21, 0.98),
        bgCardAvail  = colU32(0.09, 0.16, 0.11, 0.98),
        bgCardLocked = colU32(0.10, 0.08, 0.07, 0.95),
        innerWell    = colU32(0.06, 0.04, 0.03, 0.85),
        edge         = colU32(0.32, 0.22, 0.16, 1.00),
        edgeHover    = colU32(0.82, 0.74, 0.60, 1.00),
        shadow       = colU32(0.00, 0.00, 0.00, 0.50),
        barBg        = colU32(0.05, 0.03, 0.03, 0.95),
        linkInactive = colU32(0.36, 0.26, 0.19, 0.55),

        gold         = colU32(0.92, 0.77, 0.38, 1.00),
        goldGlow     = colU32(0.92, 0.77, 0.38, 0.24),
        cyan         = colU32(0.32, 0.75, 0.96, 1.00),
        cyanGlow     = colU32(0.32, 0.75, 0.96, 0.22),
        green        = colU32(0.38, 0.86, 0.48, 1.00),
        greenGlow    = colU32(0.38, 0.86, 0.48, 0.20),
        muted        = colU32(0.45, 0.38, 0.33, 1.00),
        bannerBg     = colU32(0.13, 0.09, 0.06, 0.95),
    }),

    -- 2: Astral Constellation (Midnight Indigo & Starlight)
    [2] = buildPalette({
        id           = 2,
        winBg        = { 0.05, 0.06, 0.11, 0.97 },
        childBg      = { 0.07, 0.09, 0.15, 0.94 },
        popupBg      = { 0.06, 0.08, 0.14, 0.97 },
        border       = { 0.22, 0.30, 0.46, 0.90 },
        titleBg      = { 0.06, 0.08, 0.14, 1.00 },
        titleBgAct   = { 0.11, 0.15, 0.26, 1.00 },
        frameBg      = { 0.10, 0.13, 0.22, 1.00 },
        frameBgHov   = { 0.15, 0.20, 0.32, 1.00 },
        button       = { 0.14, 0.19, 0.31, 1.00 },
        buttonHov    = { 0.21, 0.28, 0.44, 1.00 },
        buttonAct    = { 0.27, 0.36, 0.56, 1.00 },
        header       = { 0.16, 0.22, 0.36, 0.92 },
        headerHov    = { 0.22, 0.30, 0.48, 0.95 },
        headerAct    = { 0.28, 0.38, 0.58, 1.00 },
        separator    = { 0.22, 0.30, 0.46, 0.80 },

        cardRounding = 9.0,
        canvasDot    = colU32(0.55, 0.72, 0.98, 0.26),
        tierRule     = colU32(0.24, 0.32, 0.50, 0.45),
        tierRuleLit  = colU32(0.45, 0.85, 1.00, 0.65),
        bgCardMax    = colU32(0.16, 0.14, 0.08, 0.96),
        bgCardActive = colU32(0.08, 0.14, 0.24, 0.96),
        bgCardAvail  = colU32(0.07, 0.16, 0.15, 0.96),
        bgCardLocked = colU32(0.08, 0.10, 0.16, 0.92),
        innerWell    = colU32(0.05, 0.06, 0.11, 0.85),
        edge         = colU32(0.22, 0.29, 0.44, 1.00),
        edgeHover    = colU32(0.75, 0.88, 1.00, 1.00),
        shadow       = colU32(0.00, 0.02, 0.08, 0.55),
        barBg        = colU32(0.04, 0.05, 0.10, 0.95),
        linkInactive = colU32(0.26, 0.34, 0.52, 0.50),

        gold         = colU32(1.00, 0.84, 0.42, 1.00),
        goldGlow     = colU32(1.00, 0.84, 0.42, 0.25),
        cyan         = colU32(0.36, 0.88, 1.00, 1.00),
        cyanGlow     = colU32(0.36, 0.88, 1.00, 0.24),
        green        = colU32(0.36, 0.94, 0.66, 1.00),
        greenGlow    = colU32(0.36, 0.94, 0.66, 0.22),
        muted        = colU32(0.38, 0.44, 0.58, 1.00),
        bannerBg     = colU32(0.09, 0.12, 0.20, 0.95),
    }),

    -- 3: Imperial Relic (Ornate Gold & Deep Crimson Lacquer)
    [3] = buildPalette({
        id           = 3,
        winBg        = { 0.08, 0.04, 0.05, 0.97 },
        childBg      = { 0.11, 0.06, 0.07, 0.94 },
        popupBg      = { 0.10, 0.05, 0.06, 0.97 },
        border       = { 0.48, 0.35, 0.18, 0.92 },
        titleBg      = { 0.13, 0.05, 0.06, 1.00 },
        titleBgAct   = { 0.25, 0.09, 0.10, 1.00 },
        frameBg      = { 0.17, 0.09, 0.10, 1.00 },
        frameBgHov   = { 0.25, 0.13, 0.14, 1.00 },
        button       = { 0.28, 0.12, 0.12, 1.00 },
        buttonHov    = { 0.40, 0.18, 0.16, 1.00 },
        buttonAct    = { 0.50, 0.23, 0.19, 1.00 },
        header       = { 0.34, 0.15, 0.13, 0.92 },
        headerHov    = { 0.44, 0.20, 0.17, 0.95 },
        headerAct    = { 0.54, 0.26, 0.20, 1.00 },
        separator    = { 0.48, 0.35, 0.18, 0.85 },

        cardRounding = 2.0,
        canvasDot    = colU32(0.62, 0.46, 0.24, 0.18),
        tierRule     = colU32(0.42, 0.30, 0.16, 0.55),
        tierRuleLit  = colU32(0.95, 0.78, 0.30, 0.75),
        bgCardMax    = colU32(0.20, 0.14, 0.06, 0.98),
        bgCardActive = colU32(0.14, 0.11, 0.18, 0.98),
        bgCardAvail  = colU32(0.09, 0.16, 0.12, 0.98),
        bgCardLocked = colU32(0.11, 0.07, 0.07, 0.95),
        innerWell    = colU32(0.07, 0.04, 0.04, 0.90),
        edge         = colU32(0.38, 0.27, 0.16, 1.00),
        edgeHover    = colU32(0.95, 0.82, 0.48, 1.00),
        shadow       = colU32(0.00, 0.00, 0.00, 0.55),
        barBg        = colU32(0.06, 0.03, 0.03, 0.95),
        linkInactive = colU32(0.42, 0.30, 0.18, 0.55),

        gold         = colU32(0.96, 0.79, 0.30, 1.00),
        goldGlow     = colU32(0.96, 0.79, 0.30, 0.25),
        cyan         = colU32(0.42, 0.68, 0.98, 1.00),
        cyanGlow     = colU32(0.42, 0.68, 0.98, 0.22),
        green        = colU32(0.36, 0.85, 0.55, 1.00),
        greenGlow    = colU32(0.36, 0.85, 0.55, 0.20),
        muted        = colU32(0.46, 0.35, 0.34, 1.00),
        bannerBg     = colU32(0.15, 0.08, 0.08, 0.96),
    }),
}

local function getPalette()
    return PALETTES[state.renderStyle] or PALETTES[1]
end

local descCache = {}
local function formatReadableDesc(raw)
    local key = tostring(raw or '')
    local cached = descCache[key]
    if cached ~= nil then
        return cached
    end
    if key == '' then
        descCache[key] = 'No description available.'
        return descCache[key]
    end
    local s = key
    s = s:gsub('NextWS', 'Next WS')
    s = s:gsub('CrDmg', 'Crit Dmg')
    s = s:gsub('DEF Ignored', 'DEF Ignore')
    s = s:gsub('DEF Ign', 'DEF Ignore')
    s = s:gsub('SC Dmg', 'Skillchain Dmg')
    s = s:gsub('M%.Def', 'Magic Def')
    s = s:gsub('MDEF', 'Magic Def')
    s = s:gsub('M%.Eva', 'Magic Eva')
    s = s:gsub('MEVA', 'Magic Eva')
    s = s:gsub('M%.Atk', 'Magic Atk')
    s = s:gsub('fTP ALL Hits', 'fTP All Hits')
    s = s:gsub('fTP ALL', 'fTP All Hits')
    s = s:gsub('(%d)h([,%s])', '%1 Hits%2')
    s = s:gsub('(%d)h$', '%1 Hits')
    s = s:gsub('STP', 'Store TP')
    s = s:gsub('Pet Heal', 'Pet/Eos Heal')
    descCache[key] = s
    return s
end

local wrapCache = {}
local function wrapLines(str, maxChars)
    local s = tostring(str or '')
    local key = tostring(maxChars) .. '|' .. s
    local cached = wrapCache[key]
    if cached ~= nil then
        return cached
    end
    local lines = {}
    local cur = ''
    for word in s:gmatch('%S+') do
        if cur == '' then
            cur = word
        elseif #cur + 1 + #word <= maxChars then
            cur = cur .. ' ' .. word
        else
            table.insert(lines, cur)
            cur = word
        end
    end
    if cur ~= '' then
        table.insert(lines, cur)
    end
    wrapCache[key] = lines
    return lines
end

local function drawDiamond(dl, cx, cy, rx, ry, fillCol, borderCol, thick)
    local p1 = { cx, cy - ry }
    local p2 = { cx + rx, cy }
    local p3 = { cx, cy + ry }
    local p4 = { cx - rx, cy }
    if fillCol ~= nil then
        dl:AddQuadFilled(p1, p2, p3, p4, fillCol)
    end
    if borderCol ~= nil then
        dl:AddQuad(p1, p2, p3, p4, borderCol, thick or 1.0)
    end
end

local function drawCornerBrackets(dl, x, y, w, h, len, col, thick)
    local t = thick or 1.5
    -- Top-left
    dl:AddLine({ x, y }, { x + len, y }, col, t)
    dl:AddLine({ x, y }, { x, y + len }, col, t)
    -- Top-right
    dl:AddLine({ x + w - len, y }, { x + w, y }, col, t)
    dl:AddLine({ x + w, y }, { x + w, y + len }, col, t)
    -- Bottom-left
    dl:AddLine({ x, y + h - len }, { x, y + h }, col, t)
    dl:AddLine({ x, y + h }, { x + len, y + h }, col, t)
    -- Bottom-right
    dl:AddLine({ x + w - len, y + h }, { x + w, y + h }, col, t)
    dl:AddLine({ x + w, y + h - len }, { x + w, y + h }, col, t)
end

local function drawBevelPanel(dl, pal, x, y, w, h, fillCol, outerCol, innerCol, rounding)
    local r = rounding or pal.cardRounding
    dl:AddRectFilled({ x + 2, y + 3 }, { x + w + 2, y + h + 3 }, pal.shadow, r)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, fillCol, r)
    dl:AddRect({ x, y }, { x + w, y + h }, outerCol, r, 0, 1.5)
    dl:AddRect({ x + 1, y + 1 }, { x + w - 1, y + h - 1 }, innerCol or pal.edge, math.max(1.0, r - 1.0), 0, 1.0)
end

local function drawProgressBar(dl, pal, x, y, w, h, pct, fillCol, borderCol)
    local r = math.min(3.0, h * 0.4)
    dl:AddRectFilled({ x, y }, { x + w, y + h }, pal.barBg, r)
    local clamped = math.max(0, math.min(1, pct or 0))
    if clamped > 0 then
        dl:AddRectFilled({ x, y }, { x + math.max(3, w * clamped), y + h }, fillCol, r)
    end
    dl:AddRect({ x, y }, { x + w, y + h }, borderCol or pal.edge, r, 0, 1.0)
end

local function getNodeRequirements(node, detail)
    local reqs = {}
    local lvl = node.reqLevel or 1
    local lvlOk = state.jobLevel >= lvl
    table.insert(reqs, {
        ok = lvlOk,
        text = string.format('Level %d+ %s (Current: %d)', lvl, state.jobKey, state.jobLevel),
        short = string.format('Lv.%d', lvl),
    })
    if (node.reqWsPoints or 0) > 0 then
        local ptsOk = detail.spent >= node.reqWsPoints
        table.insert(reqs, {
            ok = ptsOk,
            text = string.format('%d+ points in %s (Current: %d)', node.reqWsPoints, detail.name, detail.spent),
            short = string.format('%d WS pts', node.reqWsPoints),
        })
    end
    if node.reqKey ~= nil then
        local pNode = detail.byKey[node.reqKey]
        if pNode ~= nil then
            local pOk = pNode.rank >= (node.reqRank or 1)
            table.insert(reqs, {
                ok = pOk,
                text = string.format('%s Rank %d+ (Current: %d)', pNode.name, node.reqRank or 1, pNode.rank),
                short = string.format('%s R%d', pNode.name, node.reqRank or 1),
            })
        end
    end
    return reqs
end

local function drawNodeTooltip(node, detail, isMaxed, isScNode, titleCol)
    local readable = formatReadableDesc(node.desc)
    local reqs = getNodeRequirements(node, detail)
    local tierNames = { 'Tier 1 — Foundation', 'Tier 2 — Specialization', 'Tier 3 — Mastery', 'Tier 4 — Capstone' }

    imgui.BeginTooltip()
    local okTip, errTip = pcall(function()
        drawTextColored(titleCol, string.format('%s   [%d / %d]', node.name, node.rank, node.maxRank))
        drawTextDisabled(tierNames[node.tier] or ('Tier ' .. tostring(node.tier)))
        imgui.Separator()
        if imgui.PushTextWrapPos and imgui.PopTextWrapPos then
            imgui.PushTextWrapPos(340)
        end
        local okWrap, errWrap = pcall(function()
            if node.rank > 0 then
                drawTextColored({ 0.55, 0.95, 0.65, 1.0 }, 'Active Effect:')
            else
                drawTextColored({ 0.85, 0.78, 0.55, 1.0 }, 'Effect Preview:')
            end
            drawText(readable)
            imgui.Spacing()

            if isScNode then
                local scLabel = (node.scName ~= '' and node.scName) or 'None'
                drawTextColored({ 0.65, 0.85, 1.0, 1.0 }, 'Selected Skillchain: ' .. scLabel)
                drawTextDisabled('Use < / > on the card to cycle Skillchain properties.')
                imgui.Spacing()
            end

            if not isMaxed then
                imgui.Separator()
                drawTextColored({ 0.85, 0.78, 0.55, 1.0 }, string.format('Next Rank (%d/%d) Requirements:', node.rank + 1, node.maxRank))
                for _, req in ipairs(reqs) do
                    if req.ok then
                        drawTextColored({ 0.42, 0.88, 0.50, 1.0 }, '  [OK] ' .. req.text)
                    else
                        drawTextColored({ 1.00, 0.45, 0.45, 1.0 }, '  [X]  ' .. req.text)
                    end
                end
            else
                imgui.Separator()
                drawTextColored({ 1.00, 0.85, 0.35, 1.0 }, 'Maximum Rank Reached')
            end

            imgui.Spacing()
            drawTextDisabled('Left-Click: +1 Rank   |   Right-Click: -1 Rank')
        end)
        if imgui.PushTextWrapPos and imgui.PopTextWrapPos then
            imgui.PopTextWrapPos()
        end
        if not okWrap then
            error(errWrap)
        end
    end)
    imgui.EndTooltip()
    if not okTip then
        state.renderError = tostring(errTip)
    end
end

local function getNodeVisualState(node, pal)
    local isMaxed = node.rank >= node.maxRank
    if isMaxed then
        return {
            isMaxed   = true,
            bgCol     = pal.bgCardMax,
            outerCol  = pal.gold,
            innerCol  = colU32(0.45, 0.35, 0.14, 0.90),
            accentCol = pal.gold,
            glowCol   = pal.goldGlow,
            titleCol  = { 1.00, 0.88, 0.44, 1.00 },
            pillCol   = { 1.00, 0.90, 0.48, 1.00 },
        }
    elseif node.rank > 0 then
        return {
            isMaxed   = false,
            bgCol     = pal.bgCardActive,
            outerCol  = pal.cyan,
            innerCol  = colU32(0.18, 0.32, 0.44, 0.90),
            accentCol = pal.cyan,
            glowCol   = pal.cyanGlow,
            titleCol  = { 0.54, 0.88, 1.00, 1.00 },
            pillCol   = { 0.56, 0.90, 1.00, 1.00 },
        }
    elseif node.canLearn then
        return {
            isMaxed   = false,
            bgCol     = pal.bgCardAvail,
            outerCol  = pal.green,
            innerCol  = colU32(0.16, 0.34, 0.22, 0.90),
            accentCol = pal.green,
            glowCol   = pal.greenGlow,
            titleCol  = { 0.58, 0.96, 0.68, 1.00 },
            pillCol   = { 0.60, 0.96, 0.68, 1.00 },
        }
    else
        return {
            isMaxed   = false,
            bgCol     = pal.bgCardLocked,
            outerCol  = pal.edge,
            innerCol  = colU32(0.16, 0.12, 0.10, 0.80),
            accentCol = pal.muted,
            glowCol   = nil,
            titleCol  = { 0.62, 0.58, 0.55, 1.00 },
            pillCol   = { 0.60, 0.56, 0.53, 1.00 },
        }
    end
end

local function drawCanvasBackground(dl, styleId, pal, x, y, w, h, maxTier, cardH, gapY, detail)
    if styleId == 2 then
        -- Astral Constellation: deterministic starfield dots
        local step = 44
        local idx = 0
        for gx = x + 16, x + w - 12, step do
            for gy = y + 14, y + h - 12, step do
                idx = idx + 1
                local ox = ((idx * 17) % 19) - 9
                local oy = ((idx * 29) % 19) - 9
                local rad = (idx % 5 == 0) and 1.6 or 1.0
                dl:AddCircleFilled({ gx + ox, gy + oy }, rad, pal.canvasDot, 8)
            end
        end
    elseif styleId == 3 then
        -- Imperial Relic: subtle architectural cross-grid
        local step = 48
        for gx = x + step, x + w - 8, step do
            dl:AddLine({ gx, y + 4 }, { gx, y + h - 4 }, pal.canvasDot, 1.0)
        end
        for gy = y + step, y + h - 8, step do
            dl:AddLine({ x + 4, gy }, { x + w - 4, gy }, pal.canvasDot, 1.0)
        end
    else
        -- Crystal Lattice: subtle dot matrix
        local step = 28
        for gx = x + 14, x + w - 10, step do
            for gy = y + 14, y + h - 10, step do
                dl:AddCircleFilled({ gx, gy }, 1.1, pal.canvasDot, 6)
            end
        end
    end
end

local function drawTierHeader(dl, styleId, pal, x, hy, w, tier, label, gateMet)
    local ruleCol = gateMet and pal.tierRuleLit or pal.tierRule
    local textCol = gateMet and { 0.92, 0.82, 0.52, 0.98 } or COL_TEXT_DISABLED

    if styleId == 2 then
        local dotCol = gateMet and pal.cyan or pal.muted
        dl:AddCircleFilled({ x + 6, hy + 7 }, 4.0, dotCol, 12)
        if gateMet then
            dl:AddCircle({ x + 6, hy + 7 }, 6.5, pal.cyanGlow, 12, 1.5)
        end
        imgui.SetCursorScreenPos({ x + 16, hy })
        drawTextColored(textCol, label)
        local lineX = x + 16 + #label * 7.2 + 8
        if lineX < x + w - 12 then
            dl:AddLine({ lineX, hy + 7 }, { x + w - 12, hy + 7 }, ruleCol, 1.0)
        end
    elseif styleId == 3 then
        drawDiamond(dl, x + 6, hy + 7, 4.5, 4.5, gateMet and pal.gold or pal.muted, pal.edge, 1.0)
        imgui.SetCursorScreenPos({ x + 16, hy })
        drawTextColored(textCol, '[ ' .. label .. ' ]')
        local lineX = x + 16 + (#label + 4) * 7.1 + 8
        if lineX < x + w - 12 then
            dl:AddLine({ lineX, hy + 6 }, { x + w - 12, hy + 6 }, ruleCol, 1.2)
            dl:AddLine({ lineX, hy + 9 }, { x + w - 12, hy + 9 }, pal.tierRule, 1.0)
        end
    else
        drawDiamond(dl, x + 6, hy + 7, 4.0, 4.0, gateMet and pal.gold or pal.muted, nil, 1.0)
        imgui.SetCursorScreenPos({ x + 15, hy })
        drawTextColored(textCol, label)
        local lineX = x + 15 + #label * 7.1 + 8
        if lineX < x + w - 12 then
            dl:AddLine({ lineX, hy + 7 }, { x + w - 12, hy + 7 }, ruleCol, 1.0)
            drawDiamond(dl, x + w - 10, hy + 7, 3.0, 3.0, ruleCol, nil, 1.0)
        end
    end
end

local function drawConnectorLine(dl, styleId, pal, x1, y1, x2, y2, activeLink, isMaxLink)
    local coreCol = isMaxLink and pal.gold or (activeLink and pal.cyan or pal.linkInactive)
    local glowCol = isMaxLink and pal.goldGlow or pal.cyanGlow

    if styleId == 2 then
        -- Astral Constellation: short stem + direct diagonal energy beam + glowing star endpoints
        local stem = 8
        local p1 = { x1, y1 }
        local p2 = { x1, y1 + stem }
        local p3 = { x2, y2 - stem }
        local p4 = { x2, y2 }
        if activeLink then
            dl:AddLine(p1, p2, glowCol, 6.0)
            dl:AddLine(p2, p3, glowCol, 6.0)
            dl:AddLine(p3, p4, glowCol, 6.0)
            dl:AddLine(p1, p2, coreCol, 2.0)
            dl:AddLine(p2, p3, coreCol, 2.0)
            dl:AddLine(p3, p4, coreCol, 2.0)
            dl:AddCircleFilled(p1, 3.0, coreCol, 10)
            dl:AddCircleFilled(p4, 3.5, coreCol, 10)
        else
            dl:AddLine(p1, p2, coreCol, 1.3)
            dl:AddLine(p2, p3, coreCol, 1.3)
            dl:AddLine(p3, p4, coreCol, 1.3)
            dl:AddCircleFilled(p4, 2.2, coreCol, 8)
        end
    elseif styleId == 3 then
        -- Imperial Relic: double-rail brass conduit with corner rivets
        local midY = (y1 + y2) * 0.5
        if activeLink then
            dl:AddLine({ x1, y1 }, { x1, midY }, glowCol, 6.0)
            dl:AddLine({ x1, midY }, { x2, midY }, glowCol, 6.0)
            dl:AddLine({ x2, midY }, { x2, y2 }, glowCol, 6.0)
            dl:AddLine({ x1, y1 }, { x1, midY }, coreCol, 2.2)
            dl:AddLine({ x1, midY }, { x2, midY }, coreCol, 2.2)
            dl:AddLine({ x2, midY }, { x2, y2 }, coreCol, 2.2)
            drawDiamond(dl, x1, midY, 3.5, 3.5, coreCol, pal.barBg, 1.0)
            if math.abs(x2 - x1) > 4 then
                drawDiamond(dl, x2, midY, 3.5, 3.5, coreCol, pal.barBg, 1.0)
            end
            dl:AddRectFilled({ x2 - 3, y2 - 4 }, { x2 + 3, y2 + 1 }, coreCol, 0.0)
        else
            dl:AddLine({ x1, y1 }, { x1, midY }, coreCol, 1.5)
            dl:AddLine({ x1, midY }, { x2, midY }, coreCol, 1.5)
            dl:AddLine({ x2, midY }, { x2, y2 }, coreCol, 1.5)
        end
    else
        -- Crystal Lattice: stepped glowing conduit + midpoint crystal junction
        local midY = (y1 + y2) * 0.5
        if activeLink then
            dl:AddLine({ x1, y1 }, { x1, midY }, glowCol, 6.0)
            dl:AddLine({ x1, midY }, { x2, midY }, glowCol, 6.0)
            dl:AddLine({ x2, midY }, { x2, y2 }, glowCol, 6.0)
            dl:AddLine({ x1, y1 }, { x1, midY }, coreCol, 2.0)
            dl:AddLine({ x1, midY }, { x2, midY }, coreCol, 2.0)
            dl:AddLine({ x2, midY }, { x2, y2 }, coreCol, 2.0)
            drawDiamond(dl, (x1 + x2) * 0.5, midY, 4.0, 4.0, coreCol, pal.barBg, 1.0)
            dl:AddCircleFilled({ x2, y2 - 2 }, 3.0, coreCol, 10)
        else
            dl:AddLine({ x1, y1 }, { x1, midY }, coreCol, 1.5)
            dl:AddLine({ x1, midY }, { x2, midY }, coreCol, 1.5)
            dl:AddLine({ x2, midY }, { x2, y2 }, coreCol, 1.5)
        end
    end
end

local function drawNodeEmblem(dl, styleId, pal, node, x, y, vs, isScNode)
    local cx = x + 17
    local cy = y + 17
    local active = (node.rank > 0 or node.canLearn)
    local fill = active and vs.accentCol or pal.muted

    if styleId == 2 then
        -- Astral circular medallion
        dl:AddCircleFilled({ cx, cy }, 10.0, pal.innerWell, 16)
        dl:AddCircle({ cx, cy }, 10.0, vs.accentCol, 16, 1.2)
        if node.tier >= 4 or isScNode then
            drawDiamond(dl, cx, cy, 5.5, 5.5, fill, nil, 1.0)
        else
            dl:AddCircleFilled({ cx, cy }, 4.2, fill, 12)
        end
    elseif styleId == 3 then
        -- Imperial square crest with inner diamond
        dl:AddRectFilled({ x + 7, y + 7 }, { x + 27, y + 27 }, pal.innerWell, 1.0)
        dl:AddRect({ x + 7, y + 7 }, { x + 27, y + 27 }, vs.accentCol, 1.0, 0, 1.0)
        drawDiamond(dl, cx, cy, 5.5, 5.5, fill, pal.barBg, 1.0)
        if node.tier >= 4 then
            drawDiamond(dl, cx, cy, 2.5, 2.5, pal.barBg, nil, 1.0)
        end
    else
        -- Crystal Lattice socketed crystal
        dl:AddRectFilled({ x + 7, y + 7 }, { x + 27, y + 27 }, pal.innerWell, 3.0)
        dl:AddRect({ x + 7, y + 7 }, { x + 27, y + 27 }, vs.innerCol, 3.0, 0, 1.0)
        drawDiamond(dl, cx, cy, 5.5, 7.0, fill, active and pal.edgeHover or pal.edge, 1.0)
    end
end

local function drawRankIndicator(dl, styleId, pal, x, y, w, rank, maxRank, accentCol)
    local mr = math.max(1, maxRank or 1)
    local r = math.max(0, math.min(mr, rank or 0))

    if styleId == 2 and mr <= 6 then
        -- Astral Constellation: circular star pips
        local spacing = 12
        local startX = x + 2
        local cy = y + 2
        for i = 1, mr do
            local px = startX + (i - 1) * spacing
            if i <= r then
                dl:AddCircleFilled({ px + 3, cy }, 3.2, accentCol, 10)
            else
                dl:AddCircle({ px + 3, cy }, 3.0, pal.edge, 10, 1.1)
            end
        end
        return
    end

    if mr <= 6 then
        local gap = 3
        local segW = (w - (mr - 1) * gap) / mr
        local round = (styleId == 3) and 0.5 or 1.5
        for i = 1, mr do
            local sx1 = x + (i - 1) * (segW + gap)
            local sx2 = sx1 + segW
            local col = (i <= r) and accentCol or pal.barBg
            dl:AddRectFilled({ sx1, y }, { sx2, y + 4 }, col, round)
            dl:AddRect({ sx1, y }, { sx2, y + 4 }, (i <= r) and accentCol or pal.edge, round, 0, 0.8)
        end
    else
        drawProgressBar(dl, pal, x, y, w, 4, r / mr, accentCol, pal.edge)
    end
end

-- Evolution view: a five-stage illustrated constellation instead of rank boxes.
-- All iconography is drawn with ImDrawList primitives, so it needs no extra
-- texture loader or third-party asset and runs in the existing Ashita v4 UI.
local EVOLUTION_STAGES =
{
    'AWAKENING', 'REFINEMENT', 'SYNERGY', 'HYBRID', 'ASCENDANCY',
}
local EVOLUTION_CAPTIONS =
{
    'Choose the purpose of this weaponskill.',
    'Strengthen the technique you chose.',
    'Shape the way it works with your spec.',
    'Adapt its mechanics to your playstyle.',
    'Choose your final, exclusive mastery.',
}

local function drawEvolutionSigil(dl, cx, cy, radius, color, variant, active)
    local shadow = colU32(0.045, 0.055, 0.090, 0.98)
    local inset = colU32(0.11, 0.14, 0.23, 1.0)
    local ink = colU32(color[1], color[2], color[3], color[4])
    dl:AddCircleFilled({ cx + 1.5, cy + 2.0 }, radius + 5, shadow, 48)
    dl:AddCircleFilled({ cx, cy }, radius + 3, active and ink or inset, 48)
    dl:AddCircleFilled({ cx, cy }, radius - 1, shadow, 48)
    dl:AddCircle({ cx, cy }, radius - 5, ink, 48, active and 2.7 or 1.4)
    dl:AddCircle({ cx, cy }, radius - 10, ink, 48, 0.8)
    -- Distinct symbols: sword strike, magic crystal, chained energy, star and crown.
    if variant == 1 then
        drawDiamond(dl, cx, cy - 4, 7, 15, ink, nil, 1)
        dl:AddLine({cx - 13, cy + 11}, {cx + 13, cy + 11}, ink, 3)
        dl:AddLine({cx, cy + 11}, {cx, cy + 19}, ink, 3)
    elseif variant == 2 then
        drawDiamond(dl, cx, cy, 15, 19, nil, ink, 2.8)
        drawDiamond(dl, cx, cy, 7, 10, ink, nil, 1)
    elseif variant == 3 then
        dl:AddCircle({cx - 8, cy - 1}, 10, ink, 32, 3)
        dl:AddCircle({cx + 8, cy + 1}, 10, ink, 32, 3)
        dl:AddLine({cx - 2, cy - 7}, {cx + 2, cy + 7}, ink, 3)
    elseif variant == 4 then
        for i = 1, 8 do
            local a = i * math.pi / 4
            local x1, y1 = cx + math.cos(a) * 7, cy + math.sin(a) * 7
            local x2, y2 = cx + math.cos(a) * 19, cy + math.sin(a) * 19
            dl:AddLine({x1, y1}, {x2, y2}, ink, 2.5)
        end
        dl:AddCircleFilled({cx, cy}, 7, ink, 20)
    else
        dl:AddLine({cx - 16, cy + 12}, {cx - 20, cy - 10}, ink, 3)
        dl:AddLine({cx - 20, cy - 10}, {cx - 6, cy - 1}, ink, 3)
        dl:AddLine({cx - 6, cy - 1}, {cx, cy - 17}, ink, 3)
        dl:AddLine({cx, cy - 17}, {cx + 7, cy - 1}, ink, 3)
        dl:AddLine({cx + 7, cy - 1}, {cx + 20, cy - 10}, ink, 3)
        dl:AddLine({cx + 20, cy - 10}, {cx + 16, cy + 12}, ink, 3)
        dl:AddLine({cx - 16, cy + 12}, {cx + 16, cy + 12}, ink, 3)
    end
end

local function drawEvolutionCanvas(detail)
    local pal = getPalette()
    local dl = imgui.GetWindowDrawList()
    local sx, sy = toXY(imgui.GetCursorScreenPos())
    local regionW = select(1, toXY(imgui.GetContentRegionAvail()))
    local canvasW = math.max(610, regionW - 14)
    local centerX = sx + canvasW / 2
    local colX = { centerX - 172, centerX + 172 }
    local gold = { 0.98, 0.79, 0.39, 1.0 }
    local aqua = { 0.38, 0.83, 0.93, 1.0 }
    local dormant = { 0.39, 0.44, 0.53, 1.0 }
    local bg = { 0.06, 0.075, 0.12, 0.96 }
    local lineCol = { 0.26, 0.37, 0.52, 0.95 }
    local ink = function(c) return colU32(c[1], c[2], c[3], c[4]) end
    local rowHeight = 160
    local topY = sy + 118
    local bottomY = topY + 5 * rowHeight + 205

    dl:AddRectFilled({sx, sy}, {sx + canvasW, bottomY}, ink(bg), 8)
    dl:AddRect({sx + 1, sy + 1}, {sx + canvasW - 1, bottomY - 1}, ink(lineCol), 8, 0, 1.5)
    imgui.SetCursorScreenPos({sx + 17, sy + 10})
    drawTextColored(gold, detail.name .. '  |  WEAPON SKILL EVOLUTION')
    imgui.SetCursorScreenPos({sx + canvasW - 104, sy + 10})
    if imgui.Button('Reset WS##evo_reset_ws', { 88, 24 }) then
        sendTalentPacket(OP_RESET_WS, detail.id, 0, 0)
    end
    imgui.SetCursorScreenPos({sx + 17, sy + 36})
    drawTextColored({0.76, 0.84, 0.94, 1.0},
        string.format('%s   •   %d / 5 decisions made', state.specName or 'Soul', math.min(5, detail.spent or 0)))
    imgui.SetCursorScreenPos({sx + 17, sy + 60})
    drawTextDisabled('Left click a sigil to awaken it. Right click to undo. One choice per stage.')

    dl:AddLine({centerX, topY - 16}, {centerX, topY + 4 * rowHeight + 28}, ink(lineCol), 4)
    for stage = 1, 5 do
        local y = topY + (stage - 1) * rowHeight
        local chosen = false
        local stageNodes = {}
        for _, node in ipairs(detail.nodes or {}) do
            if node.tier == stage and (node.scTier or 0) == 0 then
                table.insert(stageNodes, node)
                if node.rank > 0 then chosen = true end
            end
        end
        table.sort(stageNodes, function(a, b) return a.col < b.col end)
        local stageColor = chosen and gold or dormant
        dl:AddCircleFilled({centerX, y + 28}, 18, ink(bg), 24)
        dl:AddCircle({centerX, y + 28}, 16, ink(stageColor), 28, 2.4)
        dl:AddCircleFilled({centerX, y + 28}, chosen and 7 or 4, ink(stageColor), 20)
        dl:AddLine({centerX - 48, y + 28}, {centerX - 18, y + 28}, ink(stageColor), 2)
        dl:AddLine({centerX + 18, y + 28}, {centerX + 48, y + 28}, ink(stageColor), 2)

        imgui.SetCursorScreenPos({centerX - 71, y - 24})
        drawTextColored(chosen and gold or aqua, string.format('STAGE %d  %s', stage, EVOLUTION_STAGES[stage]))
        imgui.SetCursorScreenPos({centerX - 135, y + 96})
        drawTextDisabled(EVOLUTION_CAPTIONS[stage])

        for ix, node in ipairs(stageNodes) do
            local x = colX[ix] or colX[2]
            local cy = y + 19
            local active = node.rank > 0
            local color = active and gold or (node.canLearn and aqua or dormant)
            if active then
                dl:AddCircle({x, cy}, 43, colU32(0.93, 0.65, 0.23, 0.55), 48, 4)
            end
            drawEvolutionSigil(dl, x, cy, 34, color, stage, active)
            imgui.SetCursorScreenPos({x - 43, cy - 43})
            imgui.InvisibleButton('##evolution_' .. node.key, {86, 86})
            local hovered = imgui.IsItemHovered()
            if imgui.IsItemClicked(0) then
                state.inspectedNodeKey = node.key
                if not active then
                    sendTalentPacket(OP_INVEST, detail.id, node.idx or 1, 0)
                end
            elseif imgui.IsItemClicked(1) then
                state.inspectedNodeKey = node.key
                if active then
                    sendTalentPacket(OP_REFUND, detail.id, node.idx or 1, 0)
                end
            end
            if hovered then
                state.inspectedNodeKey = node.key
                drawNodeTooltip(node, detail, active, false, color)
            end
            local short = (#node.name > 23) and (node.name:sub(1, 21) .. '..') or node.name
            imgui.SetCursorScreenPos({x - 83, cy + 45})
            drawTextColored(color, short)
            if active then
                imgui.SetCursorScreenPos({x - 36, cy + 62})
                drawTextColored(gold, 'AWAKENED')
            elseif node.canLearn then
                imgui.SetCursorScreenPos({x - 26, cy + 62})
                drawTextColored(aqua, 'READY')
            end
        end
    end

    imgui.SetCursorScreenPos({sx + 20, bottomY - 211})
    local inspected = detail.byKey and detail.byKey[state.inspectedNodeKey] or nil
    if inspected then
        drawTextColored(gold, 'INSPECTED: ' .. inspected.name)
        imgui.SetCursorScreenPos({sx + 20, bottomY - 190})
        drawText(formatReadableDesc(inspected.desc))
    else
        drawTextDisabled('Select a glowing sigil to inspect its technique.')
    end
    -- Freely configurable skillchain routing, including OFF on every tier.
    -- No evolution points are spent on these controls.
    local scTop = bottomY - 165
    dl:AddLine({sx + 20, scTop}, {sx + canvasW - 20, scTop}, ink(lineCol), 1.5)
    imgui.SetCursorScreenPos({sx + 21, scTop + 9})
    drawTextColored(gold, 'SKILLCHAIN ROUTING')
    imgui.SetCursorScreenPos({sx + 21, scTop + 32})
    drawTextDisabled('OFF means this WS will not interrupt a party skillchain.')
    local scLabels = { 'FIRST', 'SECOND', 'ADVANCED', 'FINAL' }
    for tier = 1, 4 do
        local sc = detail.byKey and detail.byKey['evsc_t' .. tier] or nil
        if sc then
            local col = (tier - 1) % 2
            local row = math.floor((tier - 1) / 2)
            local x = sx + 24 + col * (canvasW / 2)
            local y = scTop + 65 + row * 41
            local unlocked = (detail.spent or 0) >= tier and state.jobLevel >= (sc.reqLevel or 1)
            imgui.SetCursorScreenPos({x, y})
            drawTextColored(unlocked and aqua or dormant, scLabels[tier])
            imgui.SetCursorScreenPos({x + 92, y - 3})
            if imgui.SmallButton('<##evsc_prev_' .. tier) then
                sendTalentPacket(OP_CYCLE_SC, detail.id, tier, 2)
            end
            imgui.SameLine()
            local scLabel = ((sc.scId or 0) == 0) and 'OFF' or (sc.scName ~= '' and sc.scName or 'OFF')
            drawTextColored((sc.scId or 0) == 0 and dormant or gold, scLabel)
            imgui.SameLine()
            if imgui.SmallButton('>##evsc_next_' .. tier) then
                sendTalentPacket(OP_CYCLE_SC, detail.id, tier, 1)
            end
        end
    end
    imgui.SetCursorScreenPos({sx + 1, bottomY + 4})
    imgui.Dummy({canvasW, 4})
end

local function drawTreeCanvas()
    local pal = getPalette()
    local styleId = pal.id
    local detail = state.wsDetail

    if detail == nil then
        imgui.Spacing()
        drawTextColored({ 0.92, 0.80, 0.48, 1.0 }, '  No Weaponskill Selected')
        drawTextDisabled('  Choose a weaponskill from the list on the left to view and customize its talent tree.')
        if not state.synced then
            imgui.Spacing()
            imgui.SetCursorPosX(imgui.GetCursorPosX() + 10)
            if imgui.Button('Sync Catalog Now', { 170, 30 }) then
                requestFullSync()
            end
        end
        return
    end

    if detail.id == 1 or detail.id == 47 then
        drawEvolutionCanvas(detail)
        return
    end

    local unlocked = isWsUnlockedInDetail(detail)
    local dl = imgui.GetWindowDrawList()

    -- Styled WS Header Banner
    local banX, banY = toXY(imgui.GetCursorScreenPos())
    local banW, _ = toXY(imgui.GetContentRegionAvail())
    banW = math.max(320, banW)
    local banH = 58
    drawBevelPanel(dl, pal, banX, banY, banW, banH, pal.bannerBg, unlocked and pal.gold or pal.edge, pal.edge, pal.cardRounding)
    if styleId == 3 then
        drawCornerBrackets(dl, banX + 2, banY + 2, banW - 4, banH - 4, 8, pal.gold, 1.2)
    end

    imgui.SetCursorScreenPos({ banX + 12, banY + 7 })
    drawTextColored({ 0.98, 0.86, 0.50, 1.0 }, detail.name)
    imgui.SameLine()
    drawTextDisabled(string.format('  •  %s  •  %s', detail.skillName, detail.wsType))
    imgui.SameLine()
    if unlocked then
        drawTextColored({ 0.44, 0.94, 0.56, 1.0 }, '   [UNLOCKED]')
    else
        drawTextColored({ 1.00, 0.50, 0.42, 1.0 }, '   [LOCKED — Invest 1 pt in Tier 1]')
    end

    imgui.SetCursorScreenPos({ banX + 12, banY + 24 })
    drawTextColored({ 0.72, 0.84, 0.96, 1.0 }, detail.orig)

    imgui.SetCursorScreenPos({ banX + 12, banY + 40 })
    drawText(string.format('WS Points: %d / 56', detail.spent))
    drawProgressBar(dl, pal, banX + 132, banY + 44, 140, 7, (detail.spent or 0) / 56, pal.cyan, pal.edge)

    imgui.SetCursorScreenPos({ banX + 286, banY + 40 })
    drawTextColored({ 0.58, 0.94, 0.66, 1.0 }, string.format('Available %s (%s): %d', state.jobKey, state.specName, state.avail))

    if detail.spent > 0 then
        imgui.SetCursorScreenPos({ banX + banW - 108, banY + 8 })
        if imgui.SmallButton('Reset This WS') then
            sendTalentPacket(OP_RESET_WS, detail.id, 0, 0)
        end
    end

    imgui.SetCursorScreenPos({ banX, banY + banH + 6 })

    if detail.nodes == nil or #detail.nodes == 0 then
        imgui.Spacing()
        drawTextColored({ 1.00, 0.55, 0.45, 1.0 }, '  No talent nodes received for ' .. tostring(detail.name) .. '.')
        drawTextDisabled('  Click below to re-request the talent tree from the server.')
        imgui.Spacing()
        imgui.SetCursorPosX(imgui.GetCursorPosX() + 10)
        if imgui.Button('Reload WS Tree', { 150, 28 }) then
            requestWS(detail.id)
        end
        return
    end

    -- Reserve bottom ~94px for the Pinned Node Inspector Panel
    local totalAvailW, totalAvailH = toXY(imgui.GetContentRegionAvail())
    local inspectorH = 94
    local treeRegionH = math.max(260, totalAvailH - inspectorH - 6)

    local hoveredNode = nil

    if imgui.BeginChild('ox_tree_scroll', { 0, treeRegionH }, CHILD_NONE) then
        local canvasPosX, canvasPosY = toXY(imgui.GetCursorScreenPos())
        local availW, availH = toXY(imgui.GetContentRegionAvail())
        local cardW   = 204
        local cardH   = 92
        local gapX    = 18
        local gapY    = 36
        local leftPad = 12

        local tierLabels =
        {
            [1] = 'TIER 1 • FOUNDATION (Lv 1+, 0+ WS pts — Unlocks WS)',
            [2] = 'TIER 2 • SPECIALIZATION (Lv 5+, 2+ WS pts)',
            [3] = 'TIER 3 • MASTERY (Lv 10+, 5+ WS pts)',
            [4] = 'TIER 4 • CAPSTONE (Lv 15+, 8+ WS pts)',
        }

        local coords = {}
        local maxCol = 1
        local maxTier = 1
        for _, node in ipairs(detail.nodes) do
            if node.col > maxCol then maxCol = node.col end
            if node.tier > maxTier then maxTier = node.tier end
            local x = canvasPosX + leftPad + (node.col - 1) * (cardW + gapX)
            local y = canvasPosY + 26 + (node.tier - 1) * (cardH + gapY)
            coords[node.key] = { x = x, y = y }
        end

        local contentW = 28 + maxCol * cardW + math.max(0, maxCol - 1) * gapX
        local contentH = 28 + maxTier * (cardH + gapY)
        local bgW = math.max(availW, contentW)
        local bgH = math.max(availH, contentH)

        dl = imgui.GetWindowDrawList()
        drawCanvasBackground(dl, styleId, pal, canvasPosX, canvasPosY, bgW, bgH, maxTier, cardH, gapY, detail)

        -- Draw Tier Section Headers & rules
        for t = 1, maxTier do
            local hy = canvasPosY + 5 + (t - 1) * (cardH + gapY)
            local gateMet = (t == 1)
                or (t == 2 and detail.spent >= 2 and state.jobLevel >= 5)
                or (t == 3 and detail.spent >= 5 and state.jobLevel >= 10)
                or (t == 4 and detail.spent >= 8 and state.jobLevel >= 15)
            drawTierHeader(dl, styleId, pal, canvasPosX + leftPad, hy, bgW - leftPad, t, tierLabels[t] or ('TIER ' .. tostring(t)), gateMet)
        end

        -- Draw Prerequisite Connector Lines
        for _, node in ipairs(detail.nodes) do
            if node.reqKey ~= nil and coords[node.reqKey] ~= nil and coords[node.key] ~= nil then
                local p = coords[node.reqKey]
                local c = coords[node.key]
                local parentNode = detail.byKey[node.reqKey]
                local activeLink = (parentNode ~= nil and parentNode.rank >= node.reqRank)
                    and (detail.spent >= node.reqWsPoints)
                    and (state.jobLevel >= (node.reqLevel or 1))
                local isMaxLink = activeLink and (parentNode.rank >= parentNode.maxRank) and (node.rank > 0)
                drawConnectorLine(dl, styleId, pal, p.x + cardW * 0.5, p.y + cardH, c.x + cardW * 0.5, c.y, activeLink, isMaxLink)
            end
        end

        -- Draw Node Cards
        for _, node in ipairs(detail.nodes) do
            local pos = coords[node.key]
            local x, y = pos.x, pos.y

            local vs = getNodeVisualState(node, pal)
            local isScNode = (node.scTier or 0) > 0
            local isInspected = (state.inspectedNodeKey == node.key)

            local btnH = isScNode and (cardH - 26) or cardH
            imgui.SetCursorScreenPos({ x, y })
            imgui.InvisibleButton('##node_' .. node.key, { cardW, btnH })
            local hovered = imgui.IsItemHovered()
            if hovered then
                hoveredNode = node
                state.inspectedNodeKey = node.key
            end

            if imgui.IsItemClicked(0) then
                state.inspectedNodeKey = node.key
                sendTalentPacket(OP_INVEST, detail.id, node.idx or 1, 0)
            elseif imgui.IsItemClicked(1) then
                state.inspectedNodeKey = node.key
                sendTalentPacket(OP_REFUND, detail.id, node.idx or 1, 0)
            end

            local outerCol = (hovered or isInspected) and pal.edgeHover or vs.outerCol

            -- Optional outer aura for active/maxed/hovered nodes
            if (vs.glowCol ~= nil and (vs.isMaxed or node.rank > 0 or hovered)) then
                dl:AddRect({ x - 2, y - 2 }, { x + cardW + 2, y + cardH + 2 }, vs.glowCol, pal.cardRounding + 2, 0, 3.0)
            end

            drawBevelPanel(dl, pal, x, y, cardW, cardH, vs.bgCol, outerCol, vs.innerCol, pal.cardRounding)

            if styleId == 3 then
                drawCornerBrackets(dl, x + 2, y + 2, cardW - 4, cardH - 4, 6, vs.accentCol, 1.2)
            elseif styleId == 1 then
                dl:AddRectFilled({ x + 6, y + 2 }, { x + cardW - 6, y + 4 }, vs.accentCol, 1.0)
            end

            -- Left Emblem
            drawNodeEmblem(dl, styleId, pal, node, x, y, vs, isScNode)

            -- Rank Pill Badge (top-right)
            local rankLabel = vs.isMaxed and 'MAX' or string.format('%d/%d', node.rank, node.maxRank)
            local pillW = vs.isMaxed and 36 or 32
            local pillX = x + cardW - pillW - 7
            local pillY = y + 7
            local pillR = (styleId == 2) and 7.0 or ((styleId == 3) and 1.0 or 3.0)
            dl:AddRectFilled({ pillX, pillY }, { pillX + pillW, pillY + 16 }, pal.barBg, pillR)
            dl:AddRect({ pillX, pillY }, { pillX + pillW, pillY + 16 }, vs.accentCol, pillR, 0, 1.0)
            imgui.SetCursorScreenPos({ pillX + (vs.isMaxed and 5 or 6), pillY + 1 })
            drawTextColored(vs.pillCol, rankLabel)

            -- Title (next to emblem)
            local maxTitleChars = 17
            local titleStr = #node.name > maxTitleChars and (string.sub(node.name, 1, maxTitleChars - 2) .. '..') or node.name
            imgui.SetCursorScreenPos({ x + 32, y + 9 })
            drawTextColored(vs.titleCol, titleStr)

            -- Body
            if isScNode then
                local scBonusPct = node.rank * (node.scTier == 4 and 15 or (node.scTier == 3 and 10 or (node.scTier == 2 and 8 or 5)))
                imgui.SetCursorScreenPos({ x + 10, y + 30 })
                drawTextColored({ 0.84, 0.82, 0.78, 1.0 }, string.format('+%d%% Skillchain Dmg', scBonusPct))

                imgui.SetCursorScreenPos({ x + 10, y + 49 })
                if imgui.SmallButton('<##sc_prev_' .. node.key) then
                    state.inspectedNodeKey = node.key
                    sendTalentPacket(OP_CYCLE_SC, detail.id, node.scTier, 255)
                end
                imgui.SameLine()
                local scDisp = (node.scName ~= '' and node.scName) or 'None'
                drawTextColored({ 0.86, 0.92, 1.0, 1.0 }, scDisp)
                imgui.SetCursorScreenPos({ x + cardW - 26, y + 49 })
                if imgui.SmallButton('>##sc_next_' .. node.key) then
                    state.inspectedNodeKey = node.key
                    sendTalentPacket(OP_CYCLE_SC, detail.id, node.scTier, 1)
                end
            else
                local readable = formatReadableDesc(node.desc)
                local wrapped = wrapLines(readable, 28)
                local line1 = wrapped[1] or ''
                local line2 = wrapped[2] or ''
                if #wrapped > 2 then
                    line2 = string.sub(line2, 1, 25) .. '...'
                end
                local descCol = (node.rank > 0 or node.canLearn) and { 0.87, 0.89, 0.92, 1.0 } or { 0.56, 0.53, 0.50, 1.0 }
                imgui.SetCursorScreenPos({ x + 10, y + 30 })
                drawTextColored(descCol, line1)
                if line2 ~= '' then
                    imgui.SetCursorScreenPos({ x + 10, y + 45 })
                    drawTextColored(descCol, line2)
                end
            end

            -- Footer Gate / Next Level Hint
            imgui.SetCursorScreenPos({ x + 10, y + cardH - 23 })
            if not vs.isMaxed then
                local reqLvl = node.reqLevel or 1
                if state.jobLevel < reqLvl then
                    drawTextColored({ 1.00, 0.48, 0.45, 1.0 }, string.format('Req Lv.%d', reqLvl))
                elseif node.reqWsPoints > 0 and detail.spent < node.reqWsPoints then
                    drawTextColored({ 0.95, 0.68, 0.35, 1.0 }, string.format('Req %d WS pts', node.reqWsPoints))
                elseif node.canLearn then
                    drawTextColored({ 0.48, 0.92, 0.58, 1.0 }, string.format('Available (Lv.%d)', reqLvl))
                else
                    drawTextDisabled(string.format('Locked (Lv.%d)', reqLvl))
                end
            else
                drawTextColored({ 0.96, 0.84, 0.45, 1.0 }, 'Mastered')
            end

            -- Bottom Rank Pips / Progress
            drawRankIndicator(dl, styleId, pal, x + 8, y + cardH - 8, cardW - 16, node.rank, node.maxRank, vs.accentCol)

            if hovered then
                drawNodeTooltip(node, detail, vs.isMaxed, isScNode, vs.titleCol)
            end
        end

        imgui.SetCursorScreenPos({ canvasPosX, canvasPosY + bgH - 4 })
        imgui.Dummy({ bgW - 8, 4 })
    end
    imgui.EndChild()

    -- Pinned Node Inspector Panel at bottom of canvas
    local inspectNode = hoveredNode
    if inspectNode == nil and state.inspectedNodeKey ~= nil then
        inspectNode = detail.byKey[state.inspectedNodeKey]
    end
    if inspectNode == nil and detail.nodes and #detail.nodes > 0 then
        inspectNode = detail.nodes[1]
    end

    if imgui.BeginChild('ox_node_inspector', { 0, 0 }, CHILD_BORDERS) then
        if inspectNode ~= nil then
            local ivs = getNodeVisualState(inspectNode, pal)
            local idl = imgui.GetWindowDrawList()
            local ix, iy = toXY(imgui.GetWindowPos())
            local _, ih = toXY(imgui.GetWindowSize())
            if idl and ih > 8 then
                idl:AddRectFilled({ ix + 2, iy + 4 }, { ix + 5, iy + ih - 4 }, ivs.accentCol, 2.0)
            end

            imgui.SetCursorPosX(imgui.GetCursorPosX() + 6)
            drawTextColored(ivs.titleCol, string.format('%s  (%d / %d)', inspectNode.name, inspectNode.rank, inspectNode.maxRank))
            imgui.SameLine()
            drawTextDisabled(string.format('  •  Tier %d  |  Left-Click: +1 Rank  |  Right-Click: -1 Rank', inspectNode.tier))

            if imgui.PushTextWrapPos and imgui.PopTextWrapPos then
                imgui.PushTextWrapPos(math.max(300, totalAvailW - 28))
            end
            pcall(function()
                imgui.SetCursorPosX(imgui.GetCursorPosX() + 6)
                drawText(formatReadableDesc(inspectNode.desc))
            end)
            if imgui.PushTextWrapPos and imgui.PopTextWrapPos then
                imgui.PopTextWrapPos()
            end

            imgui.SetCursorPosX(imgui.GetCursorPosX() + 6)
            if not ivs.isMaxed then
                local reqs = getNodeRequirements(inspectNode, detail)
                local first = true
                for _, req in ipairs(reqs) do
                    if not first then
                        imgui.SameLine()
                        drawTextDisabled('  |  ')
                        imgui.SameLine()
                    end
                    first = false
                    if req.ok then
                        drawTextColored({ 0.42, 0.88, 0.50, 1.0 }, '[OK] ' .. req.short)
                    else
                        drawTextColored({ 1.00, 0.45, 0.45, 1.0 }, '[X] ' .. req.text)
                    end
                end
            else
                drawTextColored({ 1.0, 0.85, 0.35, 1.0 }, '[MAX] Maximum rank reached.')
            end
        else
            drawTextDisabled('Hover or click any talent node to inspect its full details.')
        end
    end
    imgui.EndChild()
end

local function drawSidebar()
    local pal = getPalette()
    local curSkillName = 'Equipped'
    for _, sk in ipairs(SKILL_LIST) do
        if sk.id == state.selectedSkill then
            curSkillName = sk.name
            break
        end
    end

    imgui.PushItemWidth(-1)
    local okFilter, errFilter = pcall(function()
        if imgui.BeginCombo('##skill_filter', curSkillName) then
            local okCombo, errCombo = pcall(function()
                for _, sk in ipairs(SKILL_LIST) do
                    local isSel = (sk.id == state.selectedSkill)
                    if imgui.Selectable(sk.name, isSel) then
                        state.selectedSkill = sk.id
                    end
                end
            end)
            imgui.EndCombo()
            if not okCombo then
                error(errCombo)
            end
        end
        imgui.InputText('##ws_search', state.searchBuf, 64)
        local rawQ = (state.searchBuf[1] or ''):gsub('%z.*$', '')
        local isActive = imgui.IsItemActive and imgui.IsItemActive() or false
        if rawQ == '' and not isActive then
            local dl = imgui.GetWindowDrawList()
            local rx, ry = toXY(imgui.GetItemRectMin())
            if dl then
                dl:AddText({ rx + 6, ry + 3 }, pal.muted, 'Search weaponskills...')
            end
        end
    end)
    imgui.PopItemWidth()
    if not okFilter then
        error(errFilter)
    end

    imgui.Checkbox('Invested Only', state.investedOnly)
    imgui.Separator()

    local filtered = getFilteredCatalog()
    if imgui.BeginChild('ox_ws_list', { 0, 0 }, CHILD_NONE) then
        local okList, errList = pcall(function()
            local dl = imgui.GetWindowDrawList()
            for _, ws in ipairs(filtered) do
                local pts = state.spentByWs[ws.id] or 0
                local unl = state.unlockedByWs[ws.id] == true
                local isEquipped = (ws.skill == state.mainSkill or (state.rangedSkill ~= 0 and ws.skill == state.rangedSkill))
                local prefix = isEquipped and '[EQ] ' or ''
                local statusTag = unl and string.format(' [%d]', pts) or (pts > 0 and string.format(' [%d L]', pts) or '')
                local label = string.format('  %s%s%s##ws_%u', prefix, ws.name, statusTag, ws.id)
                local isSelected = (state.selectedWsId == ws.id)

                if not unl and not isSelected then
                    imgui.PushStyleColor(COL_TEXT, { 0.62, 0.58, 0.54, 1.0 })
                elseif unl and not isSelected then
                    imgui.PushStyleColor(COL_TEXT, { 0.88, 0.92, 0.94, 1.0 })
                end
                local clicked = imgui.Selectable(label, isSelected)
                if not isSelected then
                    imgui.PopStyleColor()
                end
                if dl then
                    local rx, ry = toXY(imgui.GetItemRectMin())
                    local _, rmaxY = toXY(imgui.GetItemRectMax())
                    local midY = (ry + rmaxY) * 0.5
                    local dotCol = unl and pal.green or (pts > 0 and pal.cyan or pal.muted)
                    dl:AddCircleFilled({ rx + 5, midY }, 2.6, dotCol, 8)
                    if isSelected then
                        dl:AddRectFilled({ rx - 1, ry + 1 }, { rx + 2, rmaxY - 1 }, pal.gold, 1.0)
                    end
                end
                if clicked then
                    state.inspectedNodeKey = nil
                    requestWS(ws.id)
                end
            end
        end)
        if not okList then
            state.renderError = tostring(errList)
        end
    end
    imgui.EndChild()
end

local function drawMainContents()
    return premiumUI.draw(state, {
        send = sendTalentPacket,
        requestWS = requestWS,
        sync = requestFullSync,
        filtered = getFilteredCatalog,
        skills = SKILL_LIST,
    })
end

-- Retained legacy implementation for rollback/reference; not used by v2.
local function drawLegacyContents()
    local pal = getPalette()

    -- Top Header Bar
    drawTextColored({ 0.98, 0.86, 0.50, 1.0 }, string.format('%s (%s) Lv.%d', state.jobKey, state.specName, state.jobLevel))
    imgui.SameLine()
    drawTextDisabled('  |  ')
    imgui.SameLine()
    drawTextColored({ 0.45, 0.94, 0.58, 1.0 }, string.format('Available: %d pts', state.avail))
    imgui.SameLine()
    drawText(string.format('  (Spent: %d / %d)', state.spent, state.earned))
    imgui.SameLine()

    if imgui.Button('Sync') then
        requestFullSync()
    end
    imgui.SameLine()
    if not state.confirmResetAll then
        if imgui.Button('Reset Spec') then
            state.confirmResetAll = true
            state.confirmResetAt = os.clock()
        end
    else
        if os.clock() - state.confirmResetAt > 5.0 then
            state.confirmResetAll = false
        else
            if imgui.Button('Confirm Reset Spec!') then
                state.confirmResetAll = false
                sendTalentPacket(OP_RESET_ALL, 0, 0, 0)
                if state.selectedWsId ~= nil then
                    requestWS(state.selectedWsId)
                end
                setStatus(string.format('Reset all weaponskill talents for %s (%s).', state.jobKey, state.specName))
            end
            imgui.SameLine()
            if imgui.Button('Cancel') then
                state.confirmResetAll = false
            end
        end
    end

    -- Render Style Selector
    imgui.SameLine()
    drawTextDisabled('  |  Style:')
    imgui.SameLine()
    imgui.PushItemWidth(155)
    local curStyleName = (RENDER_STYLES[state.renderStyle] and RENDER_STYLES[state.renderStyle].name) or 'Crystal Lattice'
    local okStyle, errStyle = pcall(function()
        if imgui.BeginCombo('##render_style', curStyleName) then
            local okStyleItems, errStyleItems = pcall(function()
                for _, st in ipairs(RENDER_STYLES) do
                    if imgui.Selectable(st.name, state.renderStyle == st.id) then
                        state.renderStyle = st.id
                    end
                end
            end)
            imgui.EndCombo()
            if not okStyleItems then
                error(errStyleItems)
            end
        end
    end)
    imgui.PopItemWidth()
    if not okStyle then
        state.renderError = tostring(errStyle)
    end

    if state.statusText ~= nil then
        if os.clock() - state.statusTime > 4.0 then
            state.statusText = nil
        else
            imgui.SameLine()
            drawTextColored({ 1.0, 0.65, 0.35, 1.0 }, '  ' .. state.statusText)
        end
    end

    if state.renderError ~= nil then
        drawTextColored({ 1.0, 0.35, 0.35, 1.0 }, 'UI Error: ' .. state.renderError)
    end

    imgui.Separator()

    -- Left Sidebar: Weapon Type + WS List
    if imgui.BeginChild('ox_ws_sidebar', { 265, 0 }, CHILD_BORDERS) then
        local okSide, errSide = xpcall(drawSidebar, debug.traceback)
        if not okSide then
            state.renderError = tostring(errSide)
        end
    end
    imgui.EndChild()

    imgui.SameLine()

    -- Right Canvas: Selected WS Talent Tree
    if imgui.BeginChild('ox_ws_canvas', { 0, 0 }, CHILD_BORDERS) then
        local okCanvas, errCanvas = xpcall(drawTreeCanvas, debug.traceback)
        if not okCanvas then
            state.renderError = tostring(errCanvas)
        end
    end
    imgui.EndChild()
end

local function pushThemeStyles()
    local pushed = 0
    if not (imgui.PushStyleColor and imgui.PopStyleColor) then
        return 0
    end
    local pal = getPalette()
    local function pushCol(colId, rgba)
        if colId ~= nil and rgba ~= nil then
            imgui.PushStyleColor(colId, rgba)
            pushed = pushed + 1
        end
    end
    pushCol(ImGuiCol_WindowBg,       pal.winBg)
    pushCol(ImGuiCol_ChildBg,        pal.childBg)
    pushCol(ImGuiCol_PopupBg,        pal.popupBg)
    pushCol(ImGuiCol_Border,         pal.border)
    pushCol(ImGuiCol_TitleBg,        pal.titleBg)
    pushCol(ImGuiCol_TitleBgActive,  pal.titleBgAct)
    pushCol(ImGuiCol_FrameBg,        pal.frameBg)
    pushCol(ImGuiCol_FrameBgHovered, pal.frameBgHov)
    pushCol(ImGuiCol_Button,         pal.button)
    pushCol(ImGuiCol_ButtonHovered,  pal.buttonHov)
    pushCol(ImGuiCol_ButtonActive,   pal.buttonAct)
    pushCol(ImGuiCol_Header,         pal.header)
    pushCol(ImGuiCol_HeaderHovered,  pal.headerHov)
    pushCol(ImGuiCol_HeaderActive,   pal.headerAct)
    pushCol(ImGuiCol_Separator,      pal.separator)
    return pushed
end

ashita.events.register('d3d_present', 'ox_talents_present', function()
    -- Auto-detect job or level changes
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

    if not state.open[1] then
        return
    end

    if not state.synced and (now - (state.syncRequestedAt or 0)) >= 4.0 then
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        if player ~= nil and player:GetMainJob() > 0 then
            requestFullSync()
        end
    end

    local pushedCols = pushThemeStyles()
    -- 1360px authored surface plus normal ImGui window padding.
    imgui.SetNextWindowSize({ 1400, 940 }, ImGuiCond_FirstUseEver or 4)
    if imgui.Begin('SoulspireXI - Weaponskill Talents###OXTalentsWin', state.open) then
        local fontPushed = false
        if state.uiFont ~= nil and imgui.PushFont then
            -- Pass the intended pixel size explicitly; Ashita otherwise inherits
            -- host UI scaling and can render this font at inconsistent sizes.
            fontPushed = pcall(imgui.PushFont, state.uiFont, 17)
        end
        local okWin, errWin = xpcall(drawMainContents, debug.traceback)
        if fontPushed and imgui.PopFont then
            imgui.PopFont()
        end
        if not okWin then
            state.renderError = tostring(errWin)
            drawTextColored({ 1.0, 0.35, 0.35, 1.0 }, 'UI Error: ' .. state.renderError)
        end
    end
    imgui.End()
    if pushedCols > 0 then
        imgui.PopStyleColor(pushedCols)
    end
end)

ashita.events.register('unload', 'ox_talents_premium_unload', function()
    premiumUI.unload()
end)
