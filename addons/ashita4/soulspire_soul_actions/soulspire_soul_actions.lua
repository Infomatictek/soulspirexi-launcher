-- SoulspireXI Soul Actions: native Soul action synchronization, macro resolution,
-- local combat-log presentation, and optional ImGui inspector for Ashita v4.
addon.name = 'soulspire_soul_actions'
addon.author = 'SoulspireXI'
addon.version = '0.5.0'
addon.desc = 'Soul-specific spell, ability, and weapon skill native presentation.'
addon.link = 'https://github.com/Infomatictek/soulspirexi-launcher'
require('common')
local imgui = require('imgui')
local catalog = require('catalog')
local builtinProfiles = require('builtin_profiles')
local profiles = require('profiles')
local presentation = require('presentation')
local soulBridge = require('soul_bridge')
local soulPacket = require('soul_packet')
local resourceAudit = require('resource_audit')
local nativeActions = require('native_actions')
local presentationConfig = require('presentation_config')
local visibility = require('visibility')
local macroResolver = require('macro_resolver')
local combatLog = require('combat_log')
local peerSouls = require('peer_souls')
local peerCache = peerSouls.new()

local state = {
    soul = nil,
    visible = false,
    lastJob = 0,
    lastCharacter = 0,
    lastPlayerName = nil,
    lastPoll = -100,
    selected = nil,
    preview = false,
    source = 'none',
    packetSoul = nil,
    packetJob = 0,
    lastDllStatus = nil,
    lastActionStatus = nil,
    catalogSynced = false,
    visibilityPolicy = nil,
    visibilitySynced = false,
    lastSyncedSoul = nil,
    textSeen = 0,
    textRewritten = 0,
    castNameMisses = 0,
    localCastCandidates = 0,
    otherActorCastLines = 0,
    castPrefixDiagnostics = nil,
    logMissReasons = {},
    peerRewritten = 0,
    peerPacketsSeen = 0,
    peerPacketsAccepted = 0,
    peerUpserts = 0,
    peerRevokes = 0,
    peerRejectReasons = {},
    peerEnvelopeSamples = {},
    -- Rewriting is scoped to the exact local actor or a verified OXSI peer.
    chatNamesEnabled = true,
}

local vanillaCache = { spell = {}, ability = {}, weaponskill = {} }
local vanillaAliasCache = { spell = {}, ability = {}, weaponskill = {} }

local function log(message) print('[Soul Actions] ' .. tostring(message)) end

local function readVanillaName(kind, id)
    local bucket = vanillaCache[kind]
    if bucket and bucket[id] ~= nil then
        return bucket[id] or nil
    end
    local ok, name = pcall(function()
        local rm = AshitaCore:GetResourceManager()
        if not rm then return nil end
        local rec = (kind == 'spell') and rm:GetSpellById(id) or rm:GetAbilityById(id)
        if not rec or not rec.Name then return nil end
        for _, idx in ipairs({ 3, 1, 2 }) do
            local v = rec.Name[idx]
            if type(v) == 'string' and v ~= '' then return v end
        end
        return nil
    end)
    local resolved = (ok and type(name) == 'string' and name ~= '') and name or false
    if bucket then bucket[id] = resolved end
    return resolved or nil
end

-- Collect every resource-provided spelling for local log matching. Unlike macro
-- dispatch, combat lines may use a different language/name index.
local function readVanillaAliases(kind, id)
    local bucket = vanillaAliasCache[kind]
    if bucket and bucket[id] then return bucket[id] end
    local primary = readVanillaName(kind, id)
    local result, seen = {}, {}
    local function append(value)
        if type(value) == 'string' and value ~= '' and not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end
    append(primary)
    pcall(function()
        local rm = AshitaCore:GetResourceManager()
        local rec = rm and ((kind == 'spell') and rm:GetSpellById(id) or rm:GetAbilityById(id))
        if not rec then return end
        for _, key in ipairs({ 'Name', 'NameReal' }) do
            local names = rec[key]
            if names then
                for index = 0, 4 do append(names[index]) end
            end
        end
    end)
    if bucket then bucket[id] = result end
    return result
end

-- Record only formatting bytes preceding an exact local cast phrase. No
-- chat payload, target, caster name, or personal data is captured.
local function safePrefixHex(message, player)
    if type(message) ~= 'string' or type(player) ~= 'string' then return 'unavailable' end
    local at = message:find(player .. ' starts casting ', 1, true)
    if not at then return 'marker_not_found' end
    local count = at - 1
    if count == 0 then return 'none' end
    if count > 64 then return 'too_long:' .. tostring(count) end
    local prefix = message:sub(1, count)
    local parts = {}
    for i = 1, #prefix do
        parts[#parts + 1] = string.format('%02X', prefix:byte(i))
    end
    return table.concat(parts, '-') .. ' (' .. tostring(count) .. ' bytes)'
end

local function syncNativeCatalog()
    local ok, countOrErr = nativeActions.syncCatalog(catalog)
    state.catalogSynced = ok == true
    -- Presentation width is a separate optional native capability. Existing
    -- clients without this export retain the old rendering path unchanged.
    -- Log capability unavailability once per state transition (never per-tick spam).
    local rowLimit, why = presentationConfig.load(addon.path)
    if rowLimit then
        if nativeActions.setActionRowLimit(rowLimit) then
            if state.rowLimitCapState == 'unavailable' then
                log('Native menu-row width configuration is now active (limit=' .. tostring(rowLimit) .. ').')
            end
            state.rowLimitCapState = 'available'
        else
            if state.rowLimitCapState ~= 'unavailable' then
                state.rowLimitCapState = 'unavailable'
                log('Native menu-row width configuration not available in the loaded DLL (will retry automatically if soulspire_native.dll loads).')
            end
        end
    elseif why then
        if state.rowLimitConfigWarn ~= tostring(why) then
            state.rowLimitConfigWarn = tostring(why)
            log('Presentation configuration warning: ' .. tostring(why))
        end
    end
    -- Load and sync external Soul action visibility policy (data/visibility.tsv).
    -- Unspecified actions remain unmanaged (fail-open to vanilla FFXI behavior).
    if type(addon.path) == 'string' and addon.path ~= '' then
        local visPath = addon.path:gsub('[/\\]+$', '') .. '/data/visibility.tsv'
        local policy, visErr = visibility.load(visPath)
        if policy then
            state.visibilityPolicy = policy
            local vok = nativeActions.syncVisibility(policy)
            state.visibilitySynced = vok == true
        else
            state.visibilityPolicy = nil
            state.visibilitySynced = false
            nativeActions.clearVisibility()
            if visErr ~= 'cannot_open_policy' then
                log('Visibility policy warning (' .. visPath .. '): ' .. tostring(visErr))
            end
        end
    end
    return ok, countOrErr
end

local function loadExternalDefaults()
    local count, why, path = builtinProfiles.install(catalog, addon.path)
    if why then
        log('External definitions warning (' .. tostring(path) .. '): ' .. tostring(why))
    end
    syncNativeCatalog()
    return count, why, path
end

local function inGame()
    local ok, job, character, name = pcall(function()
        local m = AshitaCore:GetMemoryManager()
        if not m then return 0, 0, nil end
        local p, party = m:GetPlayer(), m:GetParty()
        if not p or not party or not party:GetMemberName(0) or party:GetMemberTargetIndex(0) == 0 then
            return 0, 0, nil
        end
        return p:GetMainJob() or 0, party:GetMemberServerId(0) or 0, party:GetMemberName(0)
    end)
    return ok and tonumber(job) or 0, ok and tonumber(character) or 0, ok and name or nil
end

local function reset()
    peerSouls.clear(peerCache)
    state.soul = nil
    state.selected = nil
    state.preview = false
    state.source = 'none'
    state.packetSoul, state.packetJob = nil, 0
    state.lastDllStatus = nil
    state.lastSyncedSoul = nil
    nativeActions.clearActiveSoul()
end

-- Initial external data load + native catalog sync.
loadExternalDefaults()

-- Slash commands and active-Soul macro translation.
ashita.events.register('command', 'osa_command', function(e)
    local raw = tostring(e.command or '')
    -- Translate active Soul action names in /ma, /nin, /ja, /ws commands and macros.
    if not state.preview and state.soul then
        local rewritten = macroResolver.translate(raw, catalog, state.soul, readVanillaName)
        if rewritten then
            e.command = rewritten
            return
        end
    end

    local args = {}
    for word in raw:gmatch('%S+') do args[#args + 1] = word end
    if not args[1] or args[1]:lower() ~= '/soulactions' then return end
    e.blocked = true
    local op = (args[2] or 'help'):lower()
    if op == 'show' then state.visible = true
    elseif op == 'hide' then state.visible = false
    elseif op == 'toggle' then state.visible = not state.visible
    elseif op == 'clear' then
        reset()
        catalog.clear()
        loadExternalDefaults()
        log('Cleared preview and reloaded external Soul action definitions.')
    elseif op == 'reload' or op == 'reset' then
        local count, why, path = loadExternalDefaults()
        if why then log('Reload failed: ' .. tostring(why))
        else log(('Reloaded %d external Soul action definitions from %s (native sync=%s).'):format(
            count, tostring(path), tostring(state.catalogSynced))) end
    elseif op == 'status' then
        local d = state.lastDllStatus
        local a = nativeActions.readStatus()
        local v = nativeActions.readVisibilityStatus()
        state.lastActionStatus = a
        log('Soul=' .. tostring(state.soul or 'unknown') .. ', source=' .. state.source ..
            ', DLL=' .. (d and ('enabled=' .. tostring(d.enabled) .. ', known=' .. tostring(d.known) ..
            ', job=' .. tostring(d.job) .. ', branch=' .. tostring(d.branch) ..
            ', character=' .. tostring(d.character_id)) or 'unavailable') ..
            ', NativeActions=' .. (a and ('hooks=' .. tostring(a.total_hooks) .. '/' .. tostring(a.expected_hooks) ..
            ', catalog=' .. tostring(a.catalog_count) .. ', gen=' .. tostring(a.catalog_generation) ..
            ', caps=0x' .. string.format('%x', a.capabilities)) or 'unavailable') ..
            ', Visibility=' .. (v and ('rules=' .. tostring(v.policy_count) .. ', effLv=' .. tostring(v.effective_level) ..
            ', hidden=' .. tostring(v.magic_hidden_count) .. '/' .. tostring(v.ability_hidden_count)) or 'unavailable'))
    elseif op == 'chatnames' then
        local choice = (args[3] or 'status'):lower()
        if choice == 'on' then
            state.chatNamesEnabled = true
            log('Combat-log Soul name substitution ENABLED for this session.')
        elseif choice == 'off' then
            state.chatNamesEnabled = false
            log('Combat-log Soul name substitution DISABLED; stock messages preserved.')
        else
            log('Combat-log Soul name substitution: ' .. (state.chatNamesEnabled and 'ON' or 'OFF'))
            log('Usage: /soulactions chatnames on|off|status')
        end
    elseif op == 'logstatus' then
        log('Combat-log substitution=' .. (state.chatNamesEnabled and 'ON' or 'OFF'))
        log(('Combat log: seen=%d rewritten=%d cast_lines_unmodified=%d soul=%s player=%s'):format(
            state.textSeen, state.textRewritten, state.castNameMisses,
            tostring(state.soul), tostring(state.lastPlayerName)))
        local reasons = {}
        for reason, count in pairs(state.logMissReasons) do
            reasons[#reasons + 1] = tostring(reason) .. '=' .. tostring(count)
        end
        table.sort(reasons)
        log('Combat match diagnostics: ' .. (#reasons > 0 and table.concat(reasons, ', ') or 'none'))
        log(('Cast attribution: local_candidates=%d other_or_unrecognized=%d'):format(
            state.localCastCandidates, state.otherActorCastLines))
        log('Local cast prefix diagnostic: ' .. tostring(state.castPrefixDiagnostics or 'none captured'))
        log(('Nearby Soul identities: %d current, packets=%d accepted=%d, peer messages rewritten=%d'):format(
            peerCache.count, state.peerPacketsSeen, state.peerPacketsAccepted,
            state.peerRewritten))
        log(('OXSI accepted operations: upserts=%d revokes=%d'):format(
            state.peerUpserts, state.peerRevokes))
        local rejected = {}
        for reason, count in pairs(state.peerRejectReasons) do
            rejected[#rejected + 1] = tostring(reason) .. '=' .. tostring(count)
        end
        table.sort(rejected)
        log('OXSI rejection reasons: ' .. (#rejected > 0 and table.concat(rejected, ', ') or 'none'))
        local samples = {}
        for length, count in pairs(state.peerEnvelopeSamples) do
            samples[#samples + 1] = tostring(length) .. 'B=' .. tostring(count)
        end
        table.sort(samples)
        log('OXSI received buffer sizes: ' .. (#samples > 0 and table.concat(samples, ', ') or 'none'))
    elseif op == 'capabilities' then
        local a = nativeActions.readStatus()
        state.lastActionStatus = a
        if not a then
            log('Native Action API unavailable (crystaljobs.dll not loaded or unsupported build).')
            return
        end
        log(('Native hooks: %d/%d, catalog=%d (gen=%d), hits: mag=%d/%d/%d abi=%d/%d/%d'):format(
            a.total_hooks, a.expected_hooks, a.catalog_count, a.catalog_generation,
            a.magic_name_hits, a.magic_desc_hits, a.magic_icon_hits,
            a.ability_name_hits, a.ability_desc_hits, a.ability_icon_hits))
        for _, cap in ipairs(nativeActions.CAPABILITIES) do
            local active = math.floor(a.capabilities / cap.bit) % 2 == 1
            log(('  [%s] %s'):format(active and 'OK' or '--', cap.name))
        end
    elseif op == 'preview' and args[3] and args[3]:match('^[%w_%-]+$') then
        state.soul = soulPacket.canonicalKey(args[3])
        state.preview = true
        state.source = 'manual preview'
        state.visible = true
        log('Preview mode; Soul identity has NOT been verified by the server.')
    elseif op == 'load' then
        local path = type(addon.path) == 'string' and (addon.path .. '/actions.tsv') or nil
        if not path then log('Addon path unavailable.'); return end
        local count, why = profiles.load(path, catalog)
        if count then
            state.selected = nil
            syncNativeCatalog()
            log('Loaded ' .. tostring(count) .. ' local action identities and synced to native DLL.')
        else log('Profile rejected: ' .. tostring(why)) end
    elseif op == 'inspect' then
        local kind, id = args[3], tonumber(args[4])
        local entry = presentation.resolve(catalog, state.soul, kind, id)
        if entry then log(entry.name .. ': ' .. entry.description)
        else log('No client identity for the current Soul and action.') end
    else
        log('Commands: /soulactions show|hide|toggle|chatnames on|off')
    end
end)

-- Local-player and verified-peer in-place combat-log action-name presentation (zero duplicate lines).
ashita.events.register('text_in', 'osa_text_in', function(e)
    if not state.chatNamesEnabled or e.blocked or state.preview or not state.lastPlayerName then return end
    -- In Ashita an empty message_modified is truthy in Lua. Prefer its content
    -- only when populated, otherwise inspect the original message.
    local current = type(e.message_modified) == 'string' and e.message_modified ~= ''
        and e.message_modified or e.message
    if type(current) ~= 'string' or current == '' then return end
    state.textSeen = state.textSeen + 1
    local rewritten, reason = nil, 'soul_unknown'
    if state.soul then
        rewritten, reason = combatLog.rewriteLine(current,
            state.lastPlayerName, catalog, state.soul, readVanillaAliases)
        if rewritten then
            state.textRewritten = state.textRewritten + 1
            e.message_modified = rewritten
            return
        end
    end
    -- Other players have independent Soul identities. Only server-announced,
    -- unexpired peers can have action names substituted in chat.
    -- Never infer a Soul from the shared vanilla spell ID.
    if current:find('starts casting ', 1, true) or current:find(' uses ', 1, true)
        or current:find(' casts ', 1, true) or current:find(' readies ', 1, true) then
        local now = os.time()
        for _, peer in pairs(peerCache.byActor) do
            if peer.name ~= state.lastPlayerName and peerSouls.get(peerCache, peer.name, now) then
                local replacement = combatLog.rewriteLine(current, peer.name,
                    catalog, peer.soul, readVanillaAliases)
                if replacement then
                    e.message_modified = replacement
                    state.peerRewritten = state.peerRewritten + 1
                    return
                end
            end
        end
    end
    if state.soul and current:find('starts casting ', 1, true) then
        -- An actor mismatch is NORMAL when another player casts. Do not
        -- report it as a failed local Soul rename.
        -- This deliberately avoids guessing who cast when the actor prefix
        -- contains unexpected game text controls.
        local localMarker = state.lastPlayerName .. ' starts casting '
        if current:find(localMarker, 1, true) then
            if reason == 'actor_mismatch' and not state.castPrefixDiagnostics then
                state.castPrefixDiagnostics = 'selected=' .. safePrefixHex(current, state.lastPlayerName)
                    .. ' original=' .. safePrefixHex(e.message, state.lastPlayerName)
                    .. ' modified=' .. safePrefixHex(e.message_modified, state.lastPlayerName)
            end
            state.localCastCandidates = state.localCastCandidates + 1
            state.castNameMisses = state.castNameMisses + 1
            local code = reason or 'unknown'
            state.logMissReasons[code] = (state.logMissReasons[code] or 0) + 1
        else
            state.otherActorCastLines = state.otherActorCastLines + 1
        end
    end
end)

ashita.events.register('load', 'osa_load', function()
    syncNativeCatalog()
    log('Native Soul Actions loaded. Use /soulactions capabilities to inspect active hooks.')
end)

ashita.events.register('unload', 'osa_unload', function()
    resourceAudit.cancel()
    reset()
end)

ashita.events.register('packet_in', 'osa_zone', function(e)
    -- 0x00A / 0x00B zone transitions: never retain stale identities.
    if e.id == 0x00B or e.id == 0x00A then reset(); return end
    if e.id == 0x1FC then
        -- OXSI packets are optional future server identity announcements.
        -- The current self-only OXHD packet remains unchanged.
        if type(e.data) == 'string' and e.data:sub(5,8) == 'OXSI' then
            state.peerPacketsSeen = state.peerPacketsSeen + 1
            -- Only aggregate buffer lengths; no character, chat, or Soul data.
            local length = #e.data
            state.peerEnvelopeSamples[length] = (state.peerEnvelopeSamples[length] or 0) + 1
            local ok, reason = peerSouls.observe(peerCache, e.data, os.time(),
                nativeActions.soulToPair, soulPacket.canonicalKey)
            if ok then
                state.peerPacketsAccepted = state.peerPacketsAccepted + 1
                if reason == 'revoked' then
                    state.peerRevokes = state.peerRevokes + 1
                elseif reason == 'accepted' then
                    state.peerUpserts = state.peerUpserts + 1
                end
            else
                local category = reason or 'unclassified'
                state.peerRejectReasons[category] = (state.peerRejectReasons[category] or 0) + 1
            end
            return
        end
        local job, character = inGame()
        local payload = soulPacket.decode(e.data, job)
        if payload then
            state.packetSoul, state.packetJob = payload.soul, payload.job
            if not state.preview then
                state.soul = payload.soul
                state.source = payload.soul and 'Soul HUD packet' or 'no active Soul'
                state.selected = nil
                if state.soul then nativeActions.setActiveSoul(state.soul, character)
                else nativeActions.clearActiveSoul() end
                state.lastSyncedSoul = state.soul
            end
        end
    end
end)

ashita.events.register('d3d_present', 'osa_render', function()
    local job, character, playerName = inGame()
    if job == 0 or character == 0 then
        if state.lastJob ~= 0 then reset() end
        state.lastJob, state.lastCharacter, state.lastPlayerName = 0, 0, nil
        return
    end
    if (state.lastJob ~= 0 and job ~= state.lastJob)
        or (state.lastCharacter ~= 0 and character ~= state.lastCharacter) then
        reset()
    end
    state.lastJob, state.lastCharacter, state.lastPlayerName = job, character, playerName
    local now = os.clock()
    if not state.preview and now - state.lastPoll >= 1 then
        state.lastPoll = now
        if not state.catalogSynced then syncNativeCatalog() end
        local dllStatus = soulBridge.read()
        state.lastDllStatus = dllStatus
        local active = soulBridge.resolve(dllStatus, job, character)
        if active then
            if state.soul ~= active then state.selected = nil end
            state.soul = active
            state.source = 'Crystal Jobs client state'
        elseif state.packetJob == job and state.packetSoul then
            state.soul = state.packetSoul
            state.source = 'Soul HUD packet'
        else
            state.soul = nil
            state.source = dllStatus and 'DLL has no valid active Soul' or 'Crystal Jobs DLL unavailable'
        end
        if state.soul ~= state.lastSyncedSoul then
            state.lastSyncedSoul = state.soul
            if state.soul then nativeActions.setActiveSoul(state.soul, character)
            else nativeActions.clearActiveSoul() end
        end
    end
    if resourceAudit.running() then
        local progress = resourceAudit.step(20)
        if progress and progress.complete then
            log(('Client resource inventory complete: %d records. File: %s'):format(
                progress.count, progress.path))
        end
    end
    if not state.visible then return end
    local open = { true }
    if imgui.Begin('SoulspireXI Soul Actions', open) then
        imgui.Text('Soul: ' .. (soulBridge.displayName(state.soul) or 'Not synchronized'))
        imgui.Separator()
        local soul = catalog.souls[state.soul] or {}
        local count = 0
        for _, kind in ipairs({ 'spell', 'ability', 'weaponskill' }) do
            local entries = soul[kind] or {}
            local ids = {}
            for id in pairs(entries) do ids[#ids + 1] = id end
            table.sort(ids)
            if #ids > 0 then imgui.Text(kind:upper()) end
            for _, id in ipairs(ids) do
                local entry = entries[id]
                count = count + 1
                if imgui.Selectable(entry.name .. '##' .. kind .. id, state.selected == kind .. ':' .. id) then
                    state.selected = kind .. ':' .. id
                end
                if state.selected == kind .. ':' .. id then
                    imgui.TextWrapped(entry.description)
                    if entry.castTime then imgui.Text('Cast: ' .. tostring(entry.castTime) .. 's') end
                    if entry.recastTime then imgui.Text('Recast: ' .. tostring(entry.recastTime) .. 's') end
                    if entry.mpCost then imgui.Text('MP: ' .. tostring(entry.mpCost)) end
                    if entry.tpCost then imgui.Text('TP: ' .. tostring(entry.tpCost)) end
                end
            end
        end
        if count == 0 then imgui.TextWrapped('No custom client action definitions available for this Soul yet.') end
    end
    imgui.End()
    if not open[1] then state.visible = false end
end)
