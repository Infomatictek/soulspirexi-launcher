--[[
* SoulspireXI - Universal Soul HUD Addon for Ashita v4
*
* Modular, data-driven HUD supporting all 66 SoulspireXI Soul Crystals.
* Receives silent [OXHUD]|... 0x017 sync packets from the server and reads
* native Ashita v4 ability recasts for zero-overhead cooldown/charge tracking.
*
* Commands:
*   /soulhud lock [on|off]        lock / unlock window dragging (hover tooltips stay active)
*   /soulhud autohide <on|off>    hide while any FFXI menu / map / cutscene is open (default on)
*   /soulhud pill [on|off]        compact Soul header pill for Souls without a custom gauge
*   /soulhud menuname             print the native menu currently detected (diagnostics)
* Also receives the Chi Weaver Boost stream ([OXBST]) formerly handled by the retired overlords_boost addon.
*   /soulhud [toggle|show|hide|auto|compact|expanded|lock|unlock|config|sync|status|reset]
*   /soulhud scale <0.75-2.0>
*   /soulhud opacity <0.25-1.0>
*   /soulhud demo <soulKey|cycle|off>
--]]

addon.name    = 'soulspire_soulhud'
addon.author  = 'SoulspireXI'
addon.version = '1.0.0'
addon.desc    = 'Universal configurable Soul Crystal HUD for SoulspireXI.'
addon.link    = 'https://github.com/Infomatictek/soulspirexi-launcher'

pcall(require, 'common')
local okChat, chat   = pcall(require, 'chat')
local okFfi, ffi     = pcall(require, 'ffi')
local okImgui, imgui = pcall(require, 'imgui')

local settingsMod = require('soulhud_settings')
local registry    = require('soulhud_registry')
local renderer    = require('soulhud_renderer')   -- config window only
local gauge       = require('soulhud_gauge')      -- Crystal Job Gauge
local roster      = require('soulhud_roster')
local demo        = require('soulhud_demo')
local okIcons, icons = pcall(require, 'ox_icons')
if not okIcons then icons = nil end
local loadSouls   = require('souls.init')
local okStrip, strip  = pcall(require, 'soulhud_buffstrip')
if not okStrip then strip = nil end
local okMenu, menu    = pcall(require, 'soulhud_menu')
if not okMenu then menu = nil end

local hudCoreIpc, oxhudIpcToken = nil, nil
do
    if type(addon) == 'table' and type(addon.path) == 'string' and addon.path ~= '' then
        local root = addon.path:gsub('[/\\]+$', ''):gsub('[/\\][^/\\]+$', '')
        local prev = package.path
        package.path = root .. '/soulspire_core/?.lua;' .. root .. '/soulspire_core/?/init.lua;' .. prev
        local okIpc, ipcMod = pcall(require, 'core.ipc')
        package.path = prev
        if okIpc and type(ipcMod) == 'table' then
            hudCoreIpc = ipcMod
            oxhudIpcToken = ipcMod.register_listener('OXHUD', 'soulspire_soulhud')
        end
    end
end

loadSouls(registry)

local PROTO_TAG = '[OXHUD]|'
local BOOST_TAG = '[OXBST]|'   -- Chi Weaver Boost stream (ported from the retired overlords_boost addon)
local cfg = settingsMod.new()

local crystal_status_t = nil
if okFfi and ffi then
    pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char* name);')
    pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void* module, const char* name);')
    local okType, stType = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, enabled, hooks, character_id, job, known, branch;
        uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
        uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
    }[1]]=])
    if okType then
        crystal_status_t = stType
    end
end

local state = {
    transitioning   = false,
    synced          = false,
    stale           = false,
    lastSyncAt      = 0,
    lastSyncReqAt   = 0,
    lastDllPollAt   = 0,
    lastJobId       = 0,
    activeSoulKey   = '',
    activeUnlocked  = false,
    kv              = {},
    runtime         = nil,
    demoRt          = nil,
    demoRtKey       = nil,
    configOpen      = false,
    resetPosPending = false,
    recastCache     = {},
    boost           = nil,    -- { active, stacks, max, remSec, at }  from [OXBST]
    lastBoostReqAt  = -100,
    boostReqs       = 0,
    hiddenReason    = nil,
}

local function logMessage(msg)
    if okChat and chat and chat.header and chat.message then
        print(chat.header(addon.name):append(chat.message(msg)))
    else
        print(('[%s] %s'):format(addon.name, tostring(msg)))
    end
end

local function splitChar(str, sep)
    local out = {}
    local start = 1
    while true do
        local pos = string.find(str, sep, start, true)
        if not pos then
            out[#out + 1] = string.sub(str, start)
            break
        end
        out[#out + 1] = string.sub(str, start, pos - 1)
        start = pos + 1
    end
    return out
end

local function parseCommandArgs(cmd)
    if type(cmd) ~= 'string' then return {} end
    local out = {}
    for token in string.gmatch(cmd, '%S+') do
        out[#out + 1] = token
    end
    return out
end

local function isPlayerInGame()
    if AshitaCore == nil or not AshitaCore.GetMemoryManager then
        return false, 0
    end
    local ok, inGame, jobId = pcall(function()
        local mem = AshitaCore:GetMemoryManager()
        if not mem then return false, 0 end
        local party = mem:GetParty()
        local player = mem:GetPlayer()
        if not party or not player then return false, 0 end
        local sid = party:GetMemberServerId(0) or 0
        local tidx = party:GetMemberTargetIndex(0) or 0
        local name = party:GetMemberName(0)
        local job = player:GetMainJob() or 0
        if state.transitioning or sid < 1 or tidx == 0 or not name or name == '' or job < 1 then
            return false, 0
        end
        return true, job
    end)
    if not ok then return false, 0 end
    return inGame == true, jobId or 0
end

local function getPlayerLevel()
    local ok, lvl = pcall(function()
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        return player and player:GetMainJobLevel() or 0
    end)
    return ok and tonumber(lvl) or 0
end

-- Entity status of the local player (4 == in an NPC event / cutscene).
local function getPlayerStatus()
    local ok, st = pcall(function()
        local mem = AshitaCore:GetMemoryManager()
        local idx = mem:GetParty():GetMemberTargetIndex(0)
        if not idx or idx == 0 then return nil end
        return mem:GetEntity():GetStatus(idx)
    end)
    return ok and st or nil
end

-- Reasons the HUD is suppressed (nil == visible). Demo mode bypasses this.
local function computeHiddenReason(inGame, now)
    if not inGame then return 'zoning' end
    if cfg.autoHideOnMenu == false or menu == nil then return nil end
    local ok, reason = pcall(menu.hiddenReason, getPlayerStatus(), now)
    return ok and reason or nil
end

local function pollCrystalDll()
    if not (okFfi and ffi and crystal_status_t) then return nil end
    local now = os.clock()
    if (now - state.lastDllPollAt) < 1.0 then return nil end
    state.lastDllPollAt = now

    local soul = nil
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
            soul = registry.getSoulByJobBranch(tonumber(st[0].job), tonumber(st[0].branch))
        end
    end)
    return soul
end

local function switchActiveSoul(soulKey, unlocked)
    if state.activeSoulKey ~= soulKey then
        registry.cleanupState(state.runtime)
        state.activeSoulKey = soulKey or ''
        local def = registry.getSoul(state.activeSoulKey)
        state.runtime = def and registry.newRuntimeState(def) or nil
    end
    state.activeUnlocked = unlocked == true
end

local function requestServerSync(_force)
    -- Server pushes 0x1FC ("OXHD") binary packets automatically; no chat command needed.
end

local function applyOxBuffsFromRaw(kvRaw)
    if strip == nil or demo.active() then return end
    local v = type(kvRaw) == 'string' and kvRaw:match('ox_buffs=([^;]*)') or ''
    strip.parse(v, os.clock())
end

local function parseKv(kvRaw)
    local kvMap = {}
    if type(kvRaw) == 'string' and kvRaw ~= '' then
        for _, pair in ipairs(splitChar(kvRaw, ';')) do
            local eq = string.find(pair, '=', 1, true)
            if eq then
                kvMap[string.sub(pair, 1, eq - 1)] = string.sub(pair, eq + 1)
            end
        end
    end
    return kvMap
end

local function applyHudState(jobId, soulKey, unlocked, kvRaw)
    state.lastJobId = jobId or 0
    applyOxBuffsFromRaw(kvRaw)
    switchActiveSoul(soulKey, unlocked)

    local kvMap = parseKv(kvRaw)
    state.kv = kvMap

    local def = registry.getSoul(soulKey)
    if def and state.runtime then
        registry.applyServerData(def, state.runtime, kvMap, os.clock())
    end

    state.synced = true
    state.stale = false
    state.lastSyncAt = os.clock()
end

local function decodeBinaryHudPacket(data)
    if type(data) ~= 'string' or #data < 16 then
        return false
    end
    if string.sub(data, 5, 8) ~= 'OXHD' then
        return false
    end
    local ver, unlockedByte, jobId, keyLen, kvLo, kvHi = string.byte(data, 9, 14)
    if ver ~= 1 then
        return false
    end
    local kvLen = (kvLo or 0) + (kvHi or 0) * 256
    local totalNeeded = 16 + (keyLen or 0) + kvLen
    if #data < totalNeeded then
        return false
    end
    local soulKey = keyLen > 0 and string.sub(data, 17, 16 + keyLen) or ''
    local kvRaw   = kvLen > 0 and string.sub(data, 17 + keyLen, 16 + keyLen + kvLen) or ''
    applyHudState(jobId or 0, soulKey, unlockedByte == 1, kvRaw)
    return true
end

local function extractProtoPayload(msg)
    if type(msg) ~= 'string' or msg == '' then return nil end
    local idx = string.find(msg, PROTO_TAG, 1, true)
    if not idx then return nil end
    return string.sub(msg, idx + #PROTO_TAG):gsub('[%z\r\n]+$', '')
end

local function applyProtoPayload(payload)
    local parts = splitChar(payload, '|')
    if #parts < 4 then return end
    applyHudState(tonumber(parts[1]) or 0, parts[2] or '', tonumber(parts[3]) == 1, parts[4] or '')
end

local function parseBoostPayload(payload)
    local parts = splitChar(payload, '|')
    local maxStacks = math.max(1, math.floor(tonumber(parts[3]) or 100))
    local stacks = math.max(0, math.min(maxStacks, math.floor(tonumber(parts[2]) or 0)))
    state.boost = {
        active = (tonumber(parts[1]) or 0) == 1,
        stacks = stacks,
        max    = maxStacks,
        remSec = math.max(0, math.floor(tonumber(parts[4]) or 0)),
        at     = os.clock(),
    }
end

local function extractBoostPayload(msg)
    if type(msg) ~= 'string' or msg == '' then return nil end
    local idx = string.find(msg, BOOST_TAG, 1, true)
    if not idx then return nil end
    return (string.sub(msg, idx + #BOOST_TAG):gsub('[%z\r\n]+$', ''))
end

-- Chi Weaver asks the server for its Boost state once on load/job change (same request overlords_boost made).
local function requestBoostSync(force)
    local now = os.clock()
    if not force and (state.boostReqs >= 3 or (now - state.lastBoostReqAt) < 10.0) then return end
    state.lastBoostReqAt = now
    state.boostReqs = state.boostReqs + 1
    pcall(function()
        local cm = AshitaCore:GetChatManager()
        if cm ~= nil then cm:QueueCommand(1, '/say !spec boost') end
    end)
end

local function refreshNativeRecasts(soulDef, rt, now)
    if not soulDef or not rt or AshitaCore == nil or not AshitaCore.GetMemoryManager then
        return
    end
    local cache = state.recastCache
    for k, _ in pairs(cache) do cache[k] = nil end

    pcall(function()
        local mem = AshitaCore:GetMemoryManager()
        local recast = mem and mem:GetRecast()
        if not recast then return end
        for i = 0, 31 do
            local id = recast:GetAbilityTimerId(i)
            if id and id > 0 or i == 0 then
                local timer = recast:GetAbilityTimer(i) or 0
                if timer > 0 then
                    cache[id] = timer / 60.0
                end
            end
        end
    end)

    registry.updateNativeRecasts(soulDef, rt, cache, now)
end

local hudCallbacks = {
    onMove = function() settingsMod.save(cfg) end,
    onSave = function() settingsMod.save(cfg) end,
    isConfigOpen = function() return state.configOpen end,
    setConfigOpen = function(v) state.configOpen = v == true end,
    onToggleConfig = function() state.configOpen = not state.configOpen end,
}

ashita.events.register('load', 'ox_soulhud_load', function()
    settingsMod.load(cfg)
    if menu then pcall(menu.init) end
    -- overlords_boost was retired into this addon: make sure a stale copy is not still loaded.
    pcall(function() AshitaCore:GetChatManager():QueueCommand(1, '/addon unload overlords_boost') end)
    local inGame = isPlayerInGame()
    if inGame then
        requestServerSync(true)
    end
end)

ashita.events.register('unload', 'ox_soulhud_unload', function()
    if hudCoreIpc and oxhudIpcToken then
        hudCoreIpc.unregister_listener(oxhudIpcToken)
        oxhudIpcToken = nil
    end
    settingsMod.save(cfg)
    registry.cleanupState(state.runtime)
    gauge.reset()
    if icons and icons.release then pcall(icons.release) end  -- release every cached D3D8 texture
end)

ashita.events.register('packet_in', 'ox_soulhud_packet_in', function(e)
    if e == nil then return end

    if e.id == 0x00B then
        state.transitioning = true
        state.synced = false
        return
    elseif e.id == 0x00A then
        state.transitioning = false
        state.synced = false
        state.stale = false
        state.boostReqs = 0
        return
    end

    if e.id == 0x1FC then
        decodeBinaryHudPacket(e.data)
        return
    end

    if e.id == 0x029 then
        if strip then pcall(strip.notePacket029, e.data) end
        return
    end

    if e.id ~= 0x017 then return end

    local payload, boostPayload = nil, nil
    for _, raw in ipairs({ e.data, e.data_modified }) do
        if type(raw) == 'string' and #raw >= 25 then
            local msg = string.sub(raw, 24):match('^([^%z]*)')
            payload = extractProtoPayload(msg)
            if payload then break end
            boostPayload = extractBoostPayload(msg)
            if boostPayload then break end
        end
    end

    if payload then
        if not hudCoreIpc or hudCoreIpc.should_block(oxhudIpcToken) then
            e.blocked = true
        end
        applyProtoPayload(payload)
    elseif boostPayload then
        e.blocked = true
        parseBoostPayload(boostPayload)
    end
end)

ashita.events.register('text_in', 'ox_soulhud_text_in', function(e)
    if e == nil then return end
    local boostPayload = extractBoostPayload(e.message_modified) or extractBoostPayload(e.message)
    if boostPayload then
        e.blocked = true
        parseBoostPayload(boostPayload)
        return
    end
    local payload = extractProtoPayload(e.message_modified) or extractProtoPayload(e.message)
    if payload then
        e.blocked = true
        applyProtoPayload(payload)
        return
    end

    if strip then
        local okFix, fixed = pcall(strip.fixChatLine, e.message_modified or e.message)
        if okFix and fixed then
            e.message_modified = fixed
        end
    end
end)

ashita.events.register('command', 'ox_soulhud_command', function(e)
    if e == nil or type(e.command) ~= 'string' then return end
    local args = parseCommandArgs(e.command)
    if #args == 0 then return end

    local root = string.lower(args[1] or '')
    if root ~= '/soulhud' and root ~= '/shud' then return end
    e.blocked = true

    local sub = string.lower(args[2] or '')
    if sub == '' or sub == 'toggle' then
        cfg.mode = (cfg.mode == 'hide') and 'auto' or 'hide'
        settingsMod.save(cfg)
        logMessage('Mode: ' .. cfg.mode)
    elseif sub == 'show' or sub == 'hide' or sub == 'auto' then
        cfg.mode = sub
        settingsMod.save(cfg)
        logMessage('Mode: ' .. cfg.mode)
    elseif sub == 'minimal' or sub == 'standard' or sub == 'compact' or sub == 'expanded' then
        cfg.layout = (sub == 'compact') and 'standard' or sub
        settingsMod.save(cfg)
        logMessage('Layout: ' .. cfg.layout)
    elseif sub == 'lock' or sub == 'unlock' then
        local arg = string.lower(args[3] or '')
        if sub == 'unlock' or arg == 'off' then
            cfg.locked = false
        elseif arg == 'on' then
            cfg.locked = true
        else
            cfg.locked = (sub == 'lock') and not cfg.locked
        end
        settingsMod.save(cfg)
        logMessage(cfg.locked and 'HUD locked (dragging disabled, tooltips still work).' or 'HUD unlocked (drag to move).')
    elseif sub == 'autohide' then
        local arg = string.lower(args[3] or '')
        if arg == 'on' or arg == 'off' then
            cfg.autoHideOnMenu = (arg == 'on')
            settingsMod.save(cfg)
        elseif arg ~= '' then
            logMessage('Usage: /soulhud autohide <on|off>')
            return
        end
        logMessage('Auto-hide in FFXI menus / maps / cutscenes: ' .. (cfg.autoHideOnMenu and 'on' or 'off') .. ' (bypassed by /soulhud demo).')
    elseif sub == 'pill' then
        local arg = string.lower(args[3] or '')
        if arg == 'on' or arg == 'off' then
            cfg.pill = (arg == 'on')
        elseif arg == '' then
            cfg.pill = not cfg.pill
        else
            logMessage('Usage: /soulhud pill [on|off]')
            return
        end
        settingsMod.save(cfg)
        logMessage('Soul header pill: ' .. (cfg.pill and 'on' or 'off'))
    elseif sub == 'menuname' then
        local name = menu and menu.currentMenu() or ''
        logMessage(('Native menu: "%s"  hidden=%s  detector=%s'):format(
            name, tostring(state.hiddenReason), (menu and menu.available()) and 'ok' or 'unavailable'))
    elseif sub == 'config' then
        state.configOpen = not state.configOpen
    elseif sub == 'scale' then
        local n = tonumber(args[3])
        if n then
            cfg.scale = n
            settingsMod.save(cfg)
            logMessage(('Scale: %.2f'):format(cfg.scale))
        else
            logMessage('Usage: /soulhud scale <0.75-2.0>')
        end
    elseif sub == 'opacity' then
        local n = tonumber(args[3])
        if n then
            cfg.opacity = n
            settingsMod.save(cfg)
            logMessage(('Opacity: %.2f'):format(cfg.opacity))
        else
            logMessage('Usage: /soulhud opacity <0.25-1.0>')
        end
    elseif sub == 'demo' or sub == 'preview' then
        local arg = args[3]
        if arg == nil then
            logMessage('Usage: /soulhud demo <soulKey|cycle|off>')
        else
            local ok, msg = demo.set(arg, roster)
            if ok and string.lower(arg) ~= 'off' and cfg.mode == 'hide' then
                cfg.mode = 'auto'
            end
            if strip and (not ok or string.lower(arg) == 'off') then
                strip.parse('', os.clock())
            end
            gauge.reset()
            logMessage(msg)
        end
    elseif sub == 'sync' then
        requestServerSync(true)
        logMessage('Requested Soul HUD sync from server.')
    elseif sub == 'reset' then
        settingsMod.reset(cfg)
        state.resetPosPending = true
        settingsMod.save(cfg)
        logMessage('Settings reset to defaults.')
    elseif sub == 'status' then
        logMessage(('mode=%s layout=%s soul=%s unlocked=%s synced=%s stale=%s locked=%s autohide=%s pill=%s hidden=%s'):format(
            cfg.mode, cfg.layout, state.activeSoulKey ~= '' and state.activeSoulKey or 'none',
            tostring(state.activeUnlocked), tostring(state.synced), tostring(state.stale),
            tostring(cfg.locked), tostring(cfg.autoHideOnMenu), tostring(cfg.pill), tostring(state.hiddenReason)
        ))
    else
        logMessage('Usage: /soulhud [toggle|show|hide|auto|minimal|standard|expanded|lock|unlock|autohide|pill|menuname|config|scale|opacity|demo|sync|status|reset]')
    end
end)

local loggedErrors = {}
local function guard(tag, fn)
    local ok, err = pcall(fn)
    if not ok and not loggedErrors[tag] then
        loggedErrors[tag] = true
        logMessage(('Error in %s: %s'):format(tostring(tag), tostring(err)))
    end
end

ashita.events.register('d3d_present', 'ox_soulhud_present', function()
    guard('d3d_present', function()
        if not (okImgui and imgui) then return end

    local inGame, jobId = isPlayerInGame()
    if not inGame then return end

    if state.lastJobId ~= jobId and jobId > 0 then
        state.lastJobId = jobId
        state.synced = false
        requestServerSync(true)
    end

    if state.activeSoulKey == '' then
        local dllSoul = pollCrystalDll()
        if dllSoul then
            switchActiveSoul(dllSoul.key, true)
        end
    end

    if not state.synced then
        requestServerSync(false)
    end

    local now = os.clock()
    if state.synced and (now - state.lastSyncAt) > 20.0 then
        state.stale = true
    end

    local demoOn = demo.active()
    local targetKey = state.activeSoulKey
    local kv, rt, soulDef, syncAt = state.kv, state.runtime, nil, state.lastSyncAt

    if demoOn then
        targetKey = demo.tick(now, roster) or targetKey
        soulDef = registry.getSoul(targetKey)
        if soulDef and (state.demoRtKey ~= targetKey or not state.demoRt) then
            state.demoRt = registry.newRuntimeState(soulDef)
            state.demoRtKey = targetKey
        end
        rt = soulDef and state.demoRt or nil
        kv = demo.kv(targetKey, now)
        if rt then demo.fillRuntime(soulDef, rt, now) end
        syncAt = now
        local seed = demo.buffs(targetKey, now)
        if seed and strip then strip.parse(seed, now) end
    else
        soulDef = registry.getSoul(targetKey)
        if soulDef and state.runtime then
            registry.tickTimers(soulDef, state.runtime, now)
            refreshNativeRecasts(soulDef, state.runtime, now)
        end
    end

    local shouldShow = false
    if demoOn then
        shouldShow = targetKey ~= nil and targetKey ~= ''
    elseif cfg.mode == 'show' then
        shouldShow = targetKey ~= ''
    elseif cfg.mode == 'auto' then
        shouldShow = targetKey ~= '' and state.activeUnlocked
    end

    -- Auto-hide while any native FFXI menu / map / event-cutscene is up, or while zoning (demo bypasses).
    state.hiddenReason = (not demoOn) and computeHiddenReason(true, now) or nil
    if state.hiddenReason then shouldShow = false end

    local boost = nil
    if targetKey == 'chiweaver' then
        boost = state.boost
        if boost == nil or (not demoOn and not state.synced) then requestBoostSync(false) end
        if boost and not demoOn and kv and kv.chi_stacks == nil and kv.chi == nil then
            -- 0x1FC not yet carrying Chi: fall back to the Boost stream so the gauge is never empty.
            local merged = {}
            for k, v in pairs(kv) do merged[k] = v end
            merged.chi_stacks = tostring(boost.stacks)
            kv = merged
        end
    end

    if shouldShow then
        gauge.render(imgui, {
            soulKey   = targetKey,
            kv        = kv,
            def       = soulDef,
            rt        = rt,
            buffs     = strip and strip.buffs or {},
            now       = now,
            syncAt    = syncAt,
            cfg       = cfg,
            callbacks = hudCallbacks,
            resetPos  = state.resetPosPending,
            onResetPosApplied = function() state.resetPosPending = false end,
            demo      = demoOn,
            level     = getPlayerLevel(),
            boost     = boost,
        })
    end
    if state.configOpen then
        renderer.renderConfig(imgui, soulDef, cfg, settingsMod, hudCallbacks)
    end
    end)
end)
