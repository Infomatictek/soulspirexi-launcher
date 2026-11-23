--[[
* SoulspireXI - The Soulforge (Weaponskill Talent Tree Addon for Ashita v4)
*
* Communicates silently with the LandSandBoat !talent system using
* 0x11F C2S / 0x1FD S2C ("OXTL") and [OXTAL]|... tagged 0x017 packets.
* Shares soulforge_state.lua and soulforge_ui.lua with SoulspireXI Core.
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
addon.version = '3.1.0'
addon.desc    = 'The Soulforge: unified Weaponskill Mastery & Talent Tree UI for SoulspireXI.'

require('common')
local imgui          = require('imgui')
local soulforgeState = require('soulforge_state')
local soulforgeUI    = require('soulforge_ui')

local okReg, soulRegistry = pcall(require, 'soul_registry_generated')
if not okReg or type(soulRegistry) ~= 'table' then soulRegistry = nil end
local okWsReg, wsRegistry = pcall(require, 'ws_registry_generated')
if not okWsReg or type(wsRegistry) ~= 'table' then wsRegistry = nil end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local state, actions

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
        if not folder or not path or not state then return end
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
        if not path or not state then return end
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

state, actions = soulforgeState.new({
    soulRegistry = soulRegistry,
    wsRegistry   = wsRegistry,
    savePrefs    = savePrefs,
})

local function pushSoulforgeImGuiStyle()
    local pushed = 0
    if not (imgui.PushStyleColor and imgui.PopStyleColor) then return 0 end
    local function pc(id, col)
        if id ~= nil and col ~= nil then
            imgui.PushStyleColor(id, col)
            pushed = pushed + 1
        end
    end
    pc(ImGuiCol_PopupBg,        { 0.043, 0.063, 0.098, 0.98 })
    pc(ImGuiCol_Border,         { 0.910, 0.741, 0.439, 0.75 })
    pc(ImGuiCol_FrameBg,        { 0.082, 0.098, 0.157, 0.98 })
    pc(ImGuiCol_FrameBgHovered, { 0.125, 0.157, 0.247, 1.00 })
    pc(ImGuiCol_FrameBgActive,  { 0.157, 0.196, 0.302, 1.00 })
    pc(ImGuiCol_Header,         { 0.141, 0.173, 0.267, 0.95 })
    pc(ImGuiCol_HeaderHovered,  { 0.224, 0.812, 0.898, 0.28 })
    pc(ImGuiCol_HeaderActive,   { 0.910, 0.741, 0.439, 0.35 })
    pc(ImGuiCol_CheckMark,      { 0.910, 0.741, 0.439, 1.00 })
    pc(ImGuiCol_Text,           { 0.945, 0.961, 0.976, 1.00 })
    return pushed
end

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
        actions.sync()
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
        actions.sync()
        actions.setStatus('Syncing weaponskill talents from server...')
        return
    elseif sub == 'scale' then
        local n = tonumber(args[3])
        if n then
            state.ui.scale = clamp(n, 0.75, 1.50)
            savePrefs()
            actions.setStatus(string.format('Soulforge UI scale set to %d%%.', math.floor(state.ui.scale * 100 + 0.5)))
        end
        return
    elseif sub == 'zoom' then
        local n = tonumber(args[3])
        if n then
            state.ui.canvasZoom = clamp(n, 0.75, 1.35)
            savePrefs()
            actions.setStatus(string.format('Soulforge canvas zoom set to %d%%.', math.floor(state.ui.canvasZoom * 100 + 0.5)))
        end
        return
    elseif sub == 'resetview' then
        state.ui.scale = 1.0
        state.ui.canvasZoom = 1.0
        state.ui.panX, state.ui.panY = 0, 0
        state.ui.drawerOpen = nil
        state.ui.forceCenter = true
        savePrefs()
        actions.setStatus('Soulforge view reset to defaults.')
        return
    end

    state.open[1] = not state.open[1]
    if not state.open[1] then
        soulforgeUI.resetTransientState(state)
    else
        if not state.synced then
            actions.sync()
        else
            actions.refreshState()
            if state.selectedWsId ~= nil then
                actions.requestWS(state.selectedWsId)
            end
        end
    end
end)

ashita.events.register('packet_in', 'ox_talents_packet_in', function(e)
    local buf = e.data_modified or e.data
    if actions.handlePacketIn(e.id, buf, e.size) then
        e.blocked = true
    end
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
                    actions.refreshState()
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
            actions.sync()
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
