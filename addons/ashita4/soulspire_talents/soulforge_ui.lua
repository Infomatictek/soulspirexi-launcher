-- SoulspireXI — The Soulforge (Weapon Skill Talents UI)
-- Presentation layer only: preserves all server-authoritative protocols,
-- node topologies, unlock rules, costs, and skillchain forging mechanics.
--
-- Powered by SoulspireXI Core UI Foundations (../soulspire_core/core/foundations.lua).

local imgui = require('imgui')
local okArt, art = pcall(require, 'art')
if not okArt then art = nil end

-- Resolve shared Core UI Foundations from sibling soulspire_core addon.
local function loadFoundations()
    local okReq, mod = pcall(require, 'core.foundations')
    if okReq and type(mod) == 'table' then return mod end

    if type(addon) == 'table' and type(addon.path) == 'string' and addon.path ~= '' then
        local root = addon.path:gsub('[/\\]+$', ''):gsub('[/\\][^/\\]+$', '')
        local cand = root .. '/soulspire_core/core/foundations.lua'
        local loader = loadfile(cand)
        if loader then
            local ok, res = pcall(loader)
            if ok and type(res) == 'table' then return res end
        end
    end

    -- Relative fallback for headless LuaJIT test runs from addons/ashita4/soulspire_talents
    local loader = loadfile('../soulspire_core/core/foundations.lua')
    if loader then
        local ok, res = pcall(loader)
        if ok and type(res) == 'table' then return res end
    end
    error('SoulspireXI Core UI Foundations (soulspire_core/core/foundations.lua) not found.')
end

local F = loadFoundations()

local UI = {}

local EVO_STAGE_NAMES = {
    'AWAKENING',
    'REFINEMENT',
    'SYNERGY',
    'HYBRIDIZATION',
    'MASTERY',
}

local ROMAN = { 'I', 'II', 'III', 'IV', 'V' }

-- ---------------------------------------------------------------------------
-- Pure Helper Logic (exported for unit tests)
-- ---------------------------------------------------------------------------
function UI.isEvolutionTree(detail)
    if not detail or not detail.nodes then return false end
    for _, n in ipairs(detail.nodes) do
        local k = tostring(n.key or '')
        if (detail.id == 1 and k:match('^e_co_')) or (detail.id == 47 and k:match('^e_sg_')) then
            return true
        end
    end
    return false
end

function UI.isWsUnlocked(state)
    local d = state and state.wsDetail
    if not d then return false end
    if state.unlockedByWs and state.unlockedByWs[d.id] == true then
        return true
    end
    for _, n in ipairs(d.nodes or {}) do
        if (n.tier or 1) == 1 and (n.rank or 0) > 0 then
            return true
        end
    end
    return false
end

function UI.isSkillchainNode(node)
    local k = tostring(node and node.key or '')
    return k:match('^evsc_t%d+$') ~= nil or k:match('^sc_t%d+$') ~= nil
end

-- Build a deterministic 2D tier/column grid of navigable talent nodes for gamepad navigation.
function UI.getTreeGrid(detail)
    local tiers = {}
    if not detail or not detail.nodes then return tiers end
    local isEvo = UI.isEvolutionTree(detail)
    local byTier = {}
    local maxTier = 0
    for _, n in ipairs(detail.nodes) do
        if not (isEvo and UI.isSkillchainNode(n)) then
            local t = tonumber(n.tier) or 1
            if t > maxTier then maxTier = t end
            byTier[t] = byTier[t] or {}
            byTier[t][#byTier[t] + 1] = n
        end
    end
    for t = 1, maxTier do
        local arr = byTier[t]
        if arr and #arr > 0 then
            table.sort(arr, function(a, b)
                if (a.col or 0) ~= (b.col or 0) then
                    return (a.col or 0) < (b.col or 0)
                end
                return (a.idx or 0) < (b.idx or 0)
            end)
            tiers[#tiers + 1] = { tier = t, nodes = arr }
        end
    end
    return tiers
end

-- Extract the 4 Skillchain Forging slots (T1/T2 Lv1, T3 Lv2, T4 Lv3) from real server nodes,
-- accurately reflecting server unlock rules (Evo: wsSpent >= tier; Legacy: sc_tX.rank > 0).
local SC_TIER_LEVEL = { 'Lv1', 'Lv1', 'Lv2', 'Lv3' }

function UI.getSkillchainSlots(detail)
    local slots = {}
    if not detail or not detail.byKey then return slots end
    local isEvo = UI.isEvolutionTree(detail)
    local wsSpent = tonumber(detail.spent) or 0
    local prefix = isEvo and 'evsc_t' or 'sc_t'
    for tier = 1, 4 do
        local sc = detail.byKey[prefix .. tier] or detail.byKey['evsc_t' .. tier] or detail.byKey['sc_t' .. tier]
        if sc then
            local unlocked = isEvo and (wsSpent >= tier) or ((tonumber(sc.rank) or 0) > 0)
            local scId = tonumber(sc.scId) or 0
            slots[#slots + 1] = {
                tier     = tier,
                scLevel  = SC_TIER_LEVEL[tier] or 'Lv1',
                node     = sc,
                scId     = scId,
                scName   = scId > 0 and (sc.scName ~= '' and sc.scName or 'ACTIVE') or 'OFF',
                unlocked = unlocked,
                active   = unlocked and scId > 0,
                lockHint = isEvo and ('CH.' .. tier) or 'RANK 0',
            }
        end
    end
    return slots
end

-- Backward-compatible alias
UI.getMasterySlots = UI.getSkillchainSlots

-- Return the up-to-4 invested Weapon Skills for the current Soul/spec (server cap: 4 WS per spec).
UI.MAX_SPEC_WS_SLOTS = 4

function UI.getInvestedWeaponskills(state)
    local out = {}
    if not state or type(state.spentByWs) ~= 'table' then return out end
    for wsId, pts in pairs(state.spentByWs) do
        local nPts = tonumber(pts) or 0
        if nPts > 0 then
            local cat = state.catalogById and state.catalogById[wsId]
            local isEvoWs = (wsId == 1 or wsId == 47)
            local cap = isEvoWs and 5 or 56
            out[#out + 1] = {
                id       = wsId,
                name     = (cat and cat.name) or ('WS #' .. tostring(wsId)),
                spent    = nPts,
                cap      = cap,
                mastered = nPts >= cap,
            }
        end
    end
    table.sort(out, function(a, b)
        if a.spent ~= b.spent then return a.spent > b.spent end
        return a.id < b.id
    end)
    return out
end

function UI.resetTransientState(state)
    if not state then return end
    state.confirmResetAll = false
    if state.ui then
        state.ui.confirmAction  = nil
        state.ui.confirmResetWs = false
        state.ui.drawerOpen     = nil
    end
end

-- Evaluate node prerequisites & human-readable unavailability reason.
function UI.evaluateNode(state, detail, node, tierHasOtherChosen, now)
    now = now or os.clock()
    local rank    = tonumber(node.rank) or 0
    local maxRank = math.max(1, tonumber(node.maxRank) or 1)
    local cost    = math.max(1, tonumber(node.cost) or 1)
    local reqLvl  = tonumber(node.reqLevel) or 1
    local reqPts  = tonumber(node.reqWsPoints) or 0
    local curLvl  = tonumber(state.jobLevel) or 1
    local wsSpent = tonumber(detail and detail.spent) or 0
    local avail   = tonumber(state.avail) or 0

    local lvlOk = curLvl >= reqLvl
    local ptsOk = wsSpent >= reqPts
    local parentOk = true
    local parentNode = nil
    if node.reqKey and detail and detail.byKey and detail.byKey[node.reqKey] then
        parentNode = detail.byKey[node.reqKey]
        parentOk = (tonumber(parentNode.rank) or 0) >= math.max(1, tonumber(node.reqRank) or 1)
    end
    local availOk = avail >= cost

    local isPending = state.pendingOp ~= nil
        and state.pendingOp.wsId == (detail and detail.id)
        and state.pendingOp.nodeKey == node.key
        and (now - (state.pendingOp.sentAt or 0)) < 5.0

    local isRejected = state.rejectedNodeKey == node.key
        and state.rejectedAt ~= nil
        and (now - state.rejectedAt) < 4.5

    local stateKey, reason
    if isPending then
        stateKey = 'pending'
        reason   = 'Awaiting server confirmation...'
    elseif isRejected then
        stateKey = 'rejected'
        reason   = state.rejectedMsg or 'Upgrade rejected by server.'
    elseif rank >= maxRank then
        stateKey = 'maxed'
        reason   = 'Maximum rank reached.'
    elseif rank > 0 then
        stateKey = 'learned'
        if node.canLearn and availOk then
            reason = nil
        elseif not availOk then
            reason = string.format('Need %d available talent point(s) (have %d).', cost, avail)
        else
            reason = 'Further ranks locked by progression requirements.'
        end
    elseif tierHasOtherChosen then
        stateKey = 'locked'
        reason   = 'Another technique is already chosen in this chapter. Refund it first to switch paths.'
    elseif node.canLearn then
        stateKey = 'available'
        reason   = nil
    elseif (not lvlOk) or (not ptsOk) or (not parentOk) then
        stateKey = 'prereq_blocked'
        if not lvlOk then
            reason = string.format('Requires Job Level %d (currently Lv.%d).', reqLvl, curLvl)
        elseif not parentOk and parentNode then
            reason = string.format('Requires %s (Rank %d).', parentNode.name, math.max(1, tonumber(node.reqRank) or 1))
        elseif not ptsOk then
            reason = string.format('Requires %d points invested in this Weapon Skill (currently %d).', reqPts, wsSpent)
        end
    elseif not availOk then
        stateKey = 'locked'
        reason   = string.format('Insufficient talent points: need %d, have %d.', cost, avail)
    else
        stateKey = 'locked'
        reason   = 'Locked — unlock prerequisite stages or weapon skill chapter first.'
    end

    return {
        stateKey   = stateKey,
        spec       = F.NODE_STATES[stateKey] or F.NODE_STATES.locked,
        rank       = rank,
        maxRank    = maxRank,
        cost       = cost,
        lvlOk      = lvlOk,
        ptsOk      = ptsOk,
        parentOk   = parentOk,
        parentNode = parentNode,
        availOk    = availOk,
        canUpgrade = (not isPending) and (rank < maxRank) and (not tierHasOtherChosen) and node.canLearn == true,
        canRefund  = (not isPending) and (rank > 0),
        reason     = reason,
    }
end

local function drawAssetOrFallback(dl, assetName, x, y, w, h, tint)
    if art and art.draw then
        return art.draw(dl, assetName, x, y, w, h, tint)
    end
    return false
end

local function ensureUiState(state)
    state.ui = state.ui or {}
    if type(state.ui.scale) ~= 'number' then state.ui.scale = 1.0 end
    if type(state.ui.canvasZoom) ~= 'number' then state.ui.canvasZoom = 1.0 end
    if type(state.ui.panX) ~= 'number' then state.ui.panX = 0 end
    if type(state.ui.panY) ~= 'number' then state.ui.panY = 0 end
    if type(state.ui.lastViewportW) ~= 'number' then state.ui.lastViewportW = 0 end
    if type(state.ui.lastViewportH) ~= 'number' then state.ui.lastViewportH = 0 end
    return state.ui
end

-- ---------------------------------------------------------------------------
-- 1. Soul Identity Header
-- ---------------------------------------------------------------------------
local function drawHeader(state, action, L, x, y, w, h)
    local dl = imgui.GetWindowDrawList()
    local s  = L.uiScale
    local ui = ensureUiState(state)

    F.drawPanelFrame(dl, x, y, w, h, {
        fillTop  = F.u32.midnight_alt,
        fillBot  = F.u32.midnight_deep,
        border   = F.u32.soul_gold_dim,
        accent   = F.u32.soul_gold,
        rounding = 6,
        corners  = (L.ornamentLevel >= 1),
        shadow   = false,
    })

    -- Left: Soul Crystal Medallion + Title
    local medR = math.floor(math.min(24 * s, (h - 14) * 0.5))
    local medX = x + 16 * s + medR
    local medY = y + h * 0.5
    F.drawCrystalMedallion(dl, medX, medY, medR, {
        rim   = F.u32.soul_gold,
        core  = F.rgba.crystal_violet,
        studs = (L.ornamentLevel >= 1),
    })

    local titleX = medX + medR + 12 * s
    F.drawShadowText(imgui, dl, titleX, y + 10 * s, 'THE SOULFORGE', F.u32.soul_gold_bright, 1.08 * s, 'l')
    if L.mode ~= 'focused' then
        F.drawShadowText(imgui, dl, titleX, y + 32 * s, 'SOULSPIREXI WEAPON SKILL MASTERY', F.u32.text_secondary, 0.78 * s, 'l')
    else
        F.drawShadowText(imgui, dl, titleX, y + 32 * s, string.format('%s  |  %s  Lv.%d', state.specName or 'Base', state.jobKey or '---', state.jobLevel or 1), F.u32.crystal_violet_bright, 0.78 * s, 'l')
    end

    -- Center: Active Soul & Job Identity + Talent Points Ledger
    if L.mode ~= 'focused' then
        local idX = x + math.floor(w * 0.30)
        local specText = tostring(state.specName or 'Base')
        local pillW = F.drawBadgePill(imgui, dl, idX, y + 12 * s, 'SOUL: ' .. specText:upper(), {
            fill      = F.abgr(F.rgba.crystal_violet_wash, 0.95),
            border    = F.u32.crystal_violet,
            textCol   = F.u32.crystal_violet_bright,
            fontScale = 0.80 * s,
            height    = math.floor(22 * s),
        })
        F.drawShadowText(imgui, dl, idX + pillW + 10 * s, y + 16 * s,
            string.format('%s  Lv.%d', state.jobKey or '---', state.jobLevel or 1),
            F.u32.text_primary, 0.88 * s, 'l')

        -- Points & 4-WS Spec Mastery Slot counter
        local avail  = tonumber(state.avail) or 0
        local spent  = tonumber(state.spent) or 0
        local earned = math.max(1, tonumber(state.earned) or (avail + spent))
        local investedList = UI.getInvestedWeaponskills(state)
        local ptsText = string.format('%d AVAIL  |  %d/%d SPENT  |  WS SLOTS: %d/%d',
            avail, spent, earned, #investedList, UI.MAX_SPEC_WS_SLOTS)
        F.drawShadowText(imgui, dl, idX, y + 40 * s, ptsText,
            avail > 0 and F.u32.aether_cyan or F.u32.text_secondary, 0.82 * s, 'l')

        if L.mode == 'expanded' then
            local slotX = idX + 318 * s
            local maxSlotArea = (x + w - 265 * s) - slotX
            if maxSlotArea >= 180 * s then
                local sg = math.floor(4 * s)
                local sw = math.floor((math.min(340 * s, maxSlotArea) - sg * 3) / 4)
                local sh = math.floor(20 * s)
                local sy = y + 38 * s
                for i = 1, UI.MAX_SPEC_WS_SLOTS do
                    local sx = slotX + (i - 1) * (sw + sg)
                    local item = investedList[i]
                    local isCur = item and (state.selectedWsId == item.id)
                    local lbl = item and F.fitText(imgui, item.name, sw - 8 * s, 0.66 * s) or ('OPEN ' .. i)
                    local variant = isCur and 'gold' or (item and 'violet' or 'neutral')
                    if F.drawActionButton(imgui, dl, '##sf_spec_slot_' .. i, sx, sy, sw, sh, lbl, variant, {
                        fontScale = 0.66 * s, disabled = (item == nil), rounding = 3,
                    }) and item then
                        state.inspectedNodeKey = nil
                        ui.confirmAction = nil
                        action.requestWS(item.id)
                    end
                end
            end
        end
    else
        -- Compact points pill in Focused mode
        local avail = tonumber(state.avail) or 0
        F.drawBadgePill(imgui, dl, x + math.floor(w * 0.44), y + 18 * s,
            string.format('%d PTS', avail), {
                fill      = F.u32.abyss_solid,
                border    = avail > 0 and F.u32.aether_cyan or F.u32.border_strong,
                textCol   = avail > 0 and F.u32.aether_cyan or F.u32.text_secondary,
                fontScale = 0.82 * s,
                height    = math.floor(24 * s),
            })
    end

    -- Right: Focused drawers (if Focused), UI Scale controls, Sync, Close
    local btnH = math.floor(26 * s)
    local btnY = y + math.floor((h - btnH) * 0.5)
    local rx   = x + w - 12 * s

    -- Close button
    local closeW = math.floor(58 * s)
    rx = rx - closeW
    if F.drawActionButton(imgui, dl, '##sf_close', rx, btnY, closeW, btnH, 'CLOSE', 'neutral', { fontScale = 0.80 * s }) then
        UI.resetTransientState(state)
        state.open[1] = false
    end

    -- Sync button
    local syncW = math.floor(56 * s)
    rx = rx - syncW - 6 * s
    if F.drawActionButton(imgui, dl, '##sf_sync', rx, btnY, syncW, btnH, 'SYNC', 'cyan', { fontScale = 0.80 * s }) then
        action.sync()
    end

    -- Independent UI Scale control (- / % / +)
    local stepW = math.floor(24 * s)
    rx = rx - stepW - 8 * s
    if F.drawActionButton(imgui, dl, '##sf_scale_up', rx, btnY, stepW, btnH, '+', 'neutral', { fontScale = 0.85 * s }) then
        ui.scale = F.clamp(math.floor((ui.scale + 0.10) * 100 + 0.5) / 100, 0.75, 1.50)
        if action.savePrefs then action.savePrefs() end
    end
    local lblW = math.floor(42 * s)
    rx = rx - lblW - 2 * s
    F.drawShadowText(imgui, dl, rx + lblW * 0.5, btnY + 5 * s, string.format('%d%%', math.floor(ui.scale * 100 + 0.5)), F.u32.text_secondary, 0.78 * s, 'c')
    rx = rx - stepW - 2 * s
    if F.drawActionButton(imgui, dl, '##sf_scale_dn', rx, btnY, stepW, btnH, '-', 'neutral', { fontScale = 0.85 * s }) then
        ui.scale = F.clamp(math.floor((ui.scale - 0.10) * 100 + 0.5) / 100, 0.75, 1.50)
        if action.savePrefs then action.savePrefs() end
    end

    -- Drawer toggles in Focused mode
    if L.drawerMode then
        local dBtnW = math.floor(76 * s)
        rx = rx - dBtnW - 8 * s
        if F.drawActionButton(imgui, dl, '##sf_tog_insp', rx, btnY, dBtnW, btnH,
            ui.drawerOpen == 'inspector' and 'DETAILS*' or 'DETAILS',
            ui.drawerOpen == 'inspector' and 'gold' or 'neutral', { fontScale = 0.76 * s }) then
            ui.drawerOpen = (ui.drawerOpen == 'inspector') and nil or 'inspector'
        end
        rx = rx - dBtnW - 4 * s
        if F.drawActionButton(imgui, dl, '##sf_tog_ars', rx, btnY, dBtnW, btnH,
            ui.drawerOpen == 'arsenal' and 'ARSENAL*' or 'ARSENAL',
            ui.drawerOpen == 'arsenal' and 'gold' or 'neutral', { fontScale = 0.76 * s }) then
            ui.drawerOpen = (ui.drawerOpen == 'arsenal') and nil or 'arsenal'
        end
    end
end

local function resolveArsenalStatus(state, action, rows)
    if action and type(action.getArsenalStatus) == 'function' then
        return action.getArsenalStatus(rows)
    end
    local count = type(rows) == 'table' and #rows or 0
    if count > 0 then
        return { kind = 'ready', count = count }
    end
    if not state.synced then
        return {
            kind        = 'loading',
            title       = 'SYNCING ARSENAL...',
            body        = 'Requesting weapon skill catalog and mastery state from server...',
            action      = 'sync',
            actionLabel = 'RETRY SYNC',
        }
    end
    if (state.selectedSkill == -1) and (tonumber(state.mainSkill) or 0) == 0 and (tonumber(state.rangedSkill) or 0) == 0 then
        return {
            kind        = 'no_weapon_equipped',
            title       = 'NO WEAPON EQUIPPED',
            body        = 'No Main or Ranged weapon is equipped for the Equipped filter. Equip a weapon or switch to All Weapons.',
            action      = 'all_weapons',
            actionLabel = 'SHOW ALL WEAPONS',
        }
    end
    return {
        kind        = 'filter_empty',
        title       = 'NO ELIGIBLE SKILLS',
        body        = 'No weapon skills match the active filter.',
        action      = 'all_weapons',
        actionLabel = 'SHOW ALL WEAPONS',
    }
end

local function triggerArsenalRecovery(state, action, status, nav)
    if not status or not status.action then return end
    if action and type(action.applyFilterAction) == 'function' then
        action.applyFilterAction(status.action)
    elseif status.action == 'all_weapons' then
        state.selectedSkill = 0
    elseif status.action == 'clear_invested' and state.investedOnly then
        state.investedOnly[1] = false
    elseif status.action == 'clear_search' and state.searchBuf then
        state.searchBuf[1] = ''
    elseif status.action == 'sync' and action and action.sync then
        action.sync()
    end
    if nav and nav.on_focus then
        nav.on_focus('arsenal', 1)
    end
end

-- ---------------------------------------------------------------------------
-- 2. Left Rail: Arsenal Navigation
-- ---------------------------------------------------------------------------
local function drawArsenal(state, action, L, x, y, w, h, nav)
    local dl = imgui.GetWindowDrawList()
    local s  = L.uiScale
    local ui = ensureUiState(state)
    local regionFocused = (nav ~= nil and nav.region == 'arsenal')
    local filterFocused = regionFocused and (nav.arsenal_focus == 'filter')

    F.drawPanelFrame(dl, x, y, w, h, {
        fillTop  = F.u32.midnight,
        fillBot  = F.u32.abyss,
        border   = regionFocused and F.u32.aether_cyan or F.u32.border_subtle,
        accent   = regionFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        thickness = regionFocused and 1.6 or 1.1,
        corners  = (L.ornamentLevel >= 1),
        shadow   = false,
    })

    local pad = math.floor(12 * s)
    F.drawShadowText(imgui, dl, x + pad, y + 10 * s,
        regionFocused and '> ARSENAL' or 'ARSENAL',
        regionFocused and F.u32.aether_cyan or F.u32.soul_gold, 0.94 * s, 'l')
    local rows = action.filtered()
    local status = resolveArsenalStatus(state, action, rows)
    local countText = (status.kind == 'loading') and 'SYNCING...' or string.format('%d WS', #rows)
    local countCol  = (status.kind == 'loading') and F.u32.aether_cyan
        or (#rows > 0 and F.u32.text_muted or F.u32.soul_gold_dim)
    F.drawShadowText(imgui, dl, x + w - pad, y + 12 * s, countText, countCol, 0.78 * s, 'r')
    F.drawDivider(dl, x + pad, y + 32 * s, w - pad * 2, regionFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    -- Weapon family filter bar: [<] [Combo] [>] for mouse + gamepad filter navigation
    local ctrlW = w - pad * 2
    local filtY = y + 40 * s
    local filtH = math.floor(22 * s)
    local arrW  = math.floor(20 * s)
    local arrGap = math.floor(3 * s)
    local comboW = math.max(80, ctrlW - (arrW + arrGap) * 2)

    if filterFocused and dl and dl.AddRect then
        dl:AddRect({ x + pad - 2, filtY - 2 }, { x + pad + ctrlW + 2, filtY + filtH + 2 }, F.u32.aether_cyan, 4, 0, 1.8)
    end

    if F.drawActionButton(imgui, dl, '##sf_filter_prev', x + pad, filtY, arrW, filtH, '<',
        filterFocused and 'cyan' or 'neutral', { fontScale = 0.76 * s }) then
        if action.cycleSkillFilter then action.cycleSkillFilter(-1) end
        if nav and nav.on_focus then nav.on_focus('arsenal', 1) end
    end

    local skillName = 'Equipped'
    for _, sk in ipairs(action.skills or {}) do
        if sk.id == state.selectedSkill then skillName = sk.name; break end
    end
    if state.selectedSkill == -1 then
        local eqSum = action.getEquippedSummary and action.getEquippedSummary() or nil
        if eqSum then
            skillName = 'Equipped (' .. eqSum .. ')'
        elseif state.synced then
            skillName = 'Equipped (None)'
        end
    end
    imgui.SetCursorScreenPos({ x + pad + arrW + arrGap, filtY })
    imgui.PushItemWidth(comboW)
    if imgui.BeginCombo('##sf_skill_filter', skillName) then
        for _, sk in ipairs(action.skills or {}) do
            if imgui.Selectable(sk.name, sk.id == state.selectedSkill) then
                state.selectedSkill = sk.id
                if nav and nav.on_focus then nav.on_focus('arsenal', 1) end
            end
        end
        imgui.EndCombo()
    end
    imgui.PopItemWidth()

    if F.drawActionButton(imgui, dl, '##sf_filter_next', x + pad + arrW + arrGap + comboW + arrGap, filtY, arrW, filtH, '>',
        filterFocused and 'cyan' or 'neutral', { fontScale = 0.76 * s }) then
        if action.cycleSkillFilter then action.cycleSkillFilter(1) end
        if nav and nav.on_focus then nav.on_focus('arsenal', 1) end
    end

    imgui.SetCursorScreenPos({ x + pad, y + 70 * s })
    imgui.PushItemWidth(ctrlW)
    imgui.InputText('##sf_ws_search', state.searchBuf, 64)
    imgui.PopItemWidth()

    imgui.SetCursorScreenPos({ x + pad, y + 98 * s })
    imgui.Checkbox('Invested only##sf_inv', state.investedOnly)

    local listTop = y + 126 * s
    local overviewH = (L.mode ~= 'focused' and h >= 380 * s) and math.floor(84 * s) or 0
    local listH   = math.max(80, (y + h) - listTop - pad - (overviewH > 0 and (overviewH + math.floor(8 * s)) or 0))
    imgui.SetCursorScreenPos({ x + pad, listTop })

    if imgui.BeginChild('##sf_arsenal_list', { ctrlW, listH }, ImGuiChildFlags_None or 0) then
        local cdl = imgui.GetWindowDrawList()
        local rowH = math.floor(52 * s)
        local rowW = math.max(120, ctrlW - 14 * s)

        for idx, ws in ipairs(rows) do
            local rx, ry = F.toXY(imgui.GetCursorScreenPos())
            local selected = (state.selectedWsId == ws.id)
            local padFocused = regionFocused and (not filterFocused) and (nav.arsenal_index == idx)
            local pts      = tonumber(state.spentByWs[ws.id]) or 0
            local unlocked = state.unlockedByWs[ws.id] == true
            local isEvoWs  = (ws.id == 1 or ws.id == 47)
            local capPts   = isEvoWs and 5 or 56
            local mastered = unlocked and pts >= capPts

            imgui.InvisibleButton('##sf_ws_' .. ws.id, { rowW, rowH })
            local hovered = imgui.IsItemHovered()
            if imgui.IsItemClicked(0) then
                state.inspectedNodeKey = nil
                ui.confirmAction = nil
                ui.panX, ui.panY = 0, 0
                action.requestWS(ws.id)
                if nav and nav.on_focus then nav.on_focus('arsenal', idx, ws.id) end
                if L.drawerMode then ui.drawerOpen = nil end
            end

            local bg = (selected or padFocused) and F.u32.midnight_selected
                or (hovered and F.u32.midnight_alt or F.u32.midnight_deep)
            local border = padFocused and F.u32.aether_cyan
                or (selected and F.u32.soul_gold
                or (mastered and F.u32.soul_gold_dim
                or (unlocked and F.u32.aether_cyan_dim
                or (hovered and F.u32.aether_cyan or F.u32.border_subtle))))

            cdl:AddRectFilled({ rx, ry }, { rx + rowW, ry + rowH - 4 }, bg, 5)
            cdl:AddRect({ rx, ry }, { rx + rowW, ry + rowH - 4 }, border, 5, 0, (selected or padFocused) and 1.8 or 1.0)
            if selected or padFocused then
                cdl:AddRectFilled({ rx + 1, ry + 4 }, { rx + 4, ry + rowH - 8 },
                    padFocused and F.u32.aether_cyan or F.u32.soul_gold, 1)
            end

            -- Mini framed WS icon
            local icSz = math.floor(34 * s)
            local ix, iy = rx + 8 * s, ry + math.floor((rowH - 4 - icSz) * 0.5)
            cdl:AddRectFilled({ ix, iy }, { ix + icSz, iy + icSz }, F.u32.abyss_solid, 4)
            if not drawAssetOrFallback(cdl, 'ws_' .. ws.id, ix + 1, iy + 1, icSz - 2, icSz - 2) then
                F.drawCrystalMedallion(cdl, ix + icSz * 0.5, iy + icSz * 0.5, icSz * 0.40, {
                    rim   = selected and F.u32.soul_gold or (unlocked and F.u32.aether_cyan or F.u32.border_strong),
                    core  = mastered and F.rgba.soul_gold or (unlocked and F.rgba.aether_cyan or F.rgba.crystal_violet_dim),
                    studs = false,
                })
            end
            cdl:AddRect({ ix, iy }, { ix + icSz, iy + icSz }, selected and F.u32.soul_gold or border, 4, 0, 1.0)

            -- WS Name + Status symbol/text
            local tx = ix + icSz + 8 * s
            local nameStr = F.fitText(imgui, ws.name, rowW - (tx - rx) - 8 * s, 0.88 * s)
            F.drawShadowText(imgui, cdl, tx, ry + 6 * s, nameStr,
                selected and F.u32.soul_gold_bright or (unlocked and F.u32.text_primary or F.u32.text_secondary),
                0.88 * s, 'l')

            local statusStr, statusCol
            if mastered then
                statusStr = string.format('[#] MASTERED  |  %d PTS', pts)
                statusCol = F.u32.soul_gold
            elseif unlocked then
                statusStr = string.format('[*] ACTIVE  |  %d PTS', pts)
                statusCol = F.u32.aether_cyan
            else
                statusStr = '[x] LOCKED  |  CH.1 UNLOCK'
                statusCol = F.u32.text_muted
            end
            F.drawShadowText(imgui, cdl, tx, ry + 26 * s,
                F.fitText(imgui, statusStr, rowW - (tx - rx) - 8 * s, 0.72 * s),
                statusCol, 0.72 * s, 'l')
        end

        if #rows == 0 then
            local ex, ey = F.toXY(imgui.GetCursorScreenPos())
            local cardW  = math.max(120, ctrlW - 6 * s)
            local isLoading = (status.kind == 'loading')
            local accentCol = isLoading and F.u32.aether_cyan or F.u32.soul_gold_dim
            local titleCol  = isLoading and F.u32.aether_cyan or F.u32.soul_gold_bright
            local fillCol   = isLoading and F.u32.midnight_selected or F.u32.midnight_deep
            local chars     = math.max(18, math.floor((cardW - 20 * s) / (6.6 * s)))
            local bodyLines = F.wrapLines(status.body or 'No eligible weapon skills.', chars, 6)
            local btnH      = math.floor(24 * s)
            local hintH     = (nav ~= nil) and math.floor(18 * s) or 0
            local cardH     = math.floor(42 * s + #bodyLines * 15 * s + (status.action and (btnH + 14 * s) or 8 * s) + hintH)

            if cdl and cdl.AddRectFilled then
                cdl:AddRectFilled({ ex, ey + 2 }, { ex + cardW, ey + 2 + cardH }, fillCol, 5)
                cdl:AddRect({ ex, ey + 2 }, { ex + cardW, ey + 2 + cardH }, accentCol, 5, 0, isLoading and 1.5 or 1.1)
            end

            local dots = isLoading and string.rep('.', (math.floor((os.clock() or 0) * 2) % 3) + 1) or ''
            local badge = isLoading and ('[~] ' .. tostring(status.title or 'SYNCING ARSENAL') .. dots)
                or ('[!] ' .. tostring(status.title or 'NO ELIGIBLE SKILLS'))
            F.drawShadowText(imgui, cdl, ex + 10 * s, ey + 10 * s,
                F.fitText(imgui, badge, cardW - 20 * s, 0.78 * s), titleCol, 0.78 * s, 'l')

            local ty = ey + 30 * s
            for _, ln in ipairs(bodyLines) do
                F.drawShadowText(imgui, cdl, ex + 10 * s, ty, ln, F.u32.text_secondary, 0.74 * s, 'l')
                ty = ty + math.floor(15 * s)
            end

            if status.action and status.actionLabel then
                ty = ty + math.floor(6 * s)
                local bW = math.max(96, cardW - 20 * s)
                if F.drawActionButton(imgui, cdl, '##sf_ars_empty_act', ex + 10 * s, ty, bW, btnH,
                    status.actionLabel, isLoading and 'cyan' or 'gold', { fontScale = 0.72 * s }) then
                    triggerArsenalRecovery(state, action, status, nav)
                end
                ty = ty + btnH + math.floor(6 * s)
            end

            if nav ~= nil then
                local cue = isLoading and '[A] Retry Sync' or '[Left/Right] Filter  |  [A] ' .. tostring(status.actionLabel or 'Switch')
                F.drawShadowText(imgui, cdl, ex + 10 * s, ty,
                    F.fitText(imgui, cue, cardW - 20 * s, 0.68 * s), F.u32.aether_cyan, 0.68 * s, 'l')
            end
            if imgui.Dummy then
                imgui.Dummy({ cardW, cardH + 6 })
            end
        end
    end
    imgui.EndChild()

    -- Bottom Mastery Overview card with 4 rotated diamond sockets (matching approved Soulforge art)
    if overviewH > 0 then
        local oy = y + h - pad - overviewH
        local ow = w - pad * 2
        local investedList = UI.getInvestedWeaponskills(state)
        dl:AddRectFilled({ x + pad, oy }, { x + pad + ow, oy + overviewH }, F.u32.midnight_deep, 5)
        dl:AddRect({ x + pad, oy }, { x + pad + ow, oy + overviewH }, F.u32.soul_gold_dim, 5, 0, 1.0)
        F.drawShadowText(imgui, dl, x + pad + 10 * s, oy + 6 * s,
            string.format('MASTERY OVERVIEW  (%d / %d)', #investedList, UI.MAX_SPEC_WS_SLOTS),
            F.u32.soul_gold, 0.72 * s, 'l')
        local dr = math.floor(15 * s)
        local pitch = math.floor((ow - 24 * s) / UI.MAX_SPEC_WS_SLOTS)
        local startCx = x + pad + 12 * s + pitch * 0.5
        local dCy = oy + math.floor(54 * s)
        for i = 1, UI.MAX_SPEC_WS_SLOTS do
            local item = investedList[i]
            local dCx = startCx + (i - 1) * pitch
            local tex = item and art and art.get and art.get('ws_' .. tostring(item.id)) or nil
            F.drawDiamondSocket(dl, dCx, dCy, dr, {
                lit    = (item ~= nil),
                active = (item ~= nil and state.selectedWsId == item.id),
                texId  = tex,
                coreU32 = (item and item.mastered) and F.u32.soul_gold_bright or F.u32.crystal_violet_bright,
            })
            if item and imgui.SetCursorScreenPos and imgui.InvisibleButton then
                imgui.SetCursorScreenPos({ dCx - dr, dCy - dr })
                if imgui.InvisibleButton('##sf_ov_slot_' .. i, { dr * 2, dr * 2 }) then
                    state.inspectedNodeKey = nil
                    ui.confirmAction = nil
                    action.requestWS(item.id)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 3. Centerpiece: The Soulforge Canvas (WS Centerpiece + 4 Mastery Slots + Tree)
-- ---------------------------------------------------------------------------
local function drawSoulforgeCanvas(state, action, L, x, y, w, h, nav)
    local dl  = imgui.GetWindowDrawList()
    local s   = L.uiScale
    local ui  = ensureUiState(state)
    local d   = state.wsDetail
    local pad = math.floor(12 * s)
    local now = os.clock()
    local treeFocused = (nav ~= nil and nav.region == 'tree')
    local scFocused   = (nav ~= nil and nav.region == 'skillchains')

    F.drawPanelFrame(dl, x, y, w, h, {
        fillTop  = F.u32.midnight,
        fillBot  = F.u32.abyss,
        border   = (treeFocused or scFocused) and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent   = (treeFocused or scFocused) and F.u32.aether_cyan or F.u32.soul_gold,
        thickness = (treeFocused or scFocused) and 1.6 or 1.1,
        corners  = (L.ornamentLevel >= 1),
        shadow   = false,
    })

    if not d then
        local rows   = action.filtered()
        local status = resolveArsenalStatus(state, action, rows)
        local cx, cy = x + w * 0.5, y + h * 0.42

        if status.kind == 'loading' then
            F.drawCrystalMedallion(dl, cx, cy - 38 * s, 34 * s, {
                rim  = F.u32.aether_cyan,
                core = F.rgba.aether_cyan,
            })
            local dots = string.rep('.', (math.floor((now or 0) * 2) % 3) + 1)
            F.drawShadowText(imgui, dl, cx, cy + 10 * s, 'SYNCING SOULFORGE DATA' .. dots, F.u32.aether_cyan, 0.98 * s, 'c')
            F.drawShadowText(imgui, dl, cx, cy + 36 * s, 'Retrieving server-authoritative weapon skills and talent progression.', F.u32.text_secondary, 0.82 * s, 'c')
            local bW, bH = math.floor(136 * s), math.floor(28 * s)
            if F.drawActionButton(imgui, dl, '##sf_canvas_sync', cx - bW * 0.5, cy + 68 * s, bW, bH, 'RETRY SYNC', 'cyan', { fontScale = 0.78 * s }) then
                triggerArsenalRecovery(state, action, status, nav)
            end
        elseif state.selectedWsId ~= nil then
            local wsEntry = state.catalogById and state.catalogById[state.selectedWsId]
            local wsLabel = wsEntry and wsEntry.name or ('Weapon Skill #' .. tostring(state.selectedWsId))
            if state.wsError then
                F.drawCrystalMedallion(dl, cx, cy - 38 * s, 34 * s, {
                    rim  = F.u32.soul_gold_dim,
                    core = F.rgba.midnight_alt,
                })
                F.drawShadowText(imgui, dl, cx, cy + 10 * s, 'SYNC FAILED: ' .. string.upper(wsLabel), F.u32.soul_gold_bright, 0.96 * s, 'c')
                local maxChars = math.max(30, math.floor((w - 80 * s) / (7.6 * s)))
                local ly = cy + 36 * s
                for _, ln in ipairs(F.wrapLines(tostring(state.wsError), maxChars, 3)) do
                    F.drawShadowText(imgui, dl, cx, ly, ln, F.u32.text_secondary, 0.82 * s, 'c')
                    ly = ly + math.floor(18 * s)
                end
                local bW, bH = math.floor(148 * s), math.floor(28 * s)
                if F.drawActionButton(imgui, dl, '##sf_canvas_ws_retry', cx - bW * 0.5, ly + 12 * s, bW, bH, 'RETRY SYNC', 'gold', { fontScale = 0.78 * s }) then
                    action.requestWS(state.selectedWsId)
                end
            else
                F.drawCrystalMedallion(dl, cx, cy - 38 * s, 34 * s, {
                    rim  = F.u32.aether_cyan,
                    core = F.rgba.crystal_violet,
                })
                local dots = string.rep('.', (math.floor((now or 0) * 2) % 3) + 1)
                F.drawShadowText(imgui, dl, cx, cy + 10 * s, 'LOADING ' .. string.upper(wsLabel) .. dots, F.u32.aether_cyan, 0.96 * s, 'c')
                F.drawShadowText(imgui, dl, cx, cy + 36 * s, 'Confirming server-authoritative talent ranks.', F.u32.text_secondary, 0.82 * s, 'c')
                local bW, bH = math.floor(136 * s), math.floor(26 * s)
                if F.drawActionButton(imgui, dl, '##sf_canvas_ws_reload', cx - bW * 0.5, cy + 66 * s, bW, bH, 'RETRY', 'cyan', { fontScale = 0.76 * s }) then
                    action.requestWS(state.selectedWsId)
                end
            end
        elseif #rows == 0 then
            F.drawCrystalMedallion(dl, cx, cy - 42 * s, 34 * s, {
                rim  = F.u32.soul_gold_dim,
                core = F.rgba.midnight_alt,
            })
            F.drawShadowText(imgui, dl, cx, cy + 6 * s, tostring(status.title or 'NO ELIGIBLE WEAPON SKILLS'), F.u32.soul_gold_bright, 0.98 * s, 'c')
            local maxChars = math.max(30, math.floor((w - 80 * s) / (7.6 * s)))
            local ly = cy + 32 * s
            for _, ln in ipairs(F.wrapLines(status.body or 'No weapon skills match the current Arsenal filter.', maxChars, 3)) do
                F.drawShadowText(imgui, dl, cx, ly, ln, F.u32.text_secondary, 0.82 * s, 'c')
                ly = ly + math.floor(18 * s)
            end
            if status.action and status.actionLabel then
                local bW, bH = math.floor(172 * s), math.floor(28 * s)
                if F.drawActionButton(imgui, dl, '##sf_canvas_recover', cx - bW * 0.5, ly + 14 * s, bW, bH,
                    status.actionLabel, 'gold', { fontScale = 0.78 * s }) then
                    triggerArsenalRecovery(state, action, status, nav)
                end
            end
        else
            F.drawCrystalMedallion(dl, cx, cy - 36 * s, 34 * s, {
                rim  = F.u32.soul_gold,
                core = F.rgba.crystal_violet,
            })
            F.drawShadowText(imgui, dl, cx, cy + 12 * s, 'SELECT A WEAPON SKILL FROM YOUR ARSENAL', F.u32.soul_gold_bright, 0.96 * s, 'c')
            F.drawShadowText(imgui, dl, cx, cy + 36 * s, 'Choose a technique to awaken its Soulforge progression map.', F.u32.text_secondary, 0.84 * s, 'c')
        end
        return
    end

    local isEvo    = UI.isEvolutionTree(d)
    local unlocked = UI.isWsUnlocked(state)
    local totalPts = isEvo and 5 or 56
    local spentPts = tonumber(d.spent) or 0

    -- A. Central Weapon Skill Crystalline Centerpiece Banner
    local heroH = math.floor((L.mode == 'focused' and 92 or 106) * s)
    local hx, hy, hw = x + pad, y + pad, w - pad * 2
    F.drawPanelFrame(dl, hx, hy, hw, heroH, {
        fillTop  = F.u32.midnight_alt,
        fillBot  = F.u32.abyss_solid,
        border   = unlocked and F.u32.soul_gold or F.u32.crystal_violet,
        accent   = unlocked and F.u32.soul_gold_bright or F.u32.aether_cyan,
        rounding = 6,
        corners  = (L.ornamentLevel >= 1),
        shadow   = false,
    })

    -- Optional hero backdrop art with readable dark scrim
    if L.ornamentLevel >= 1 and drawAssetOrFallback(dl, 'hero_' .. d.id, hx + 2, hy + 2, hw - 4, heroH - 4, F.abgr(F.rgba.white, 0.28)) then
        dl:AddRectFilled({ hx + 2, hy + 2 }, { hx + hw - 2, hy + heroH - 2 }, F.u32.scrim, 5)
    end

    -- WS Crystalline Medallion
    local mR = math.floor(math.min(34 * s, (heroH - 20) * 0.5))
    local mCx, mCy = hx + 18 * s + mR, hy + heroH * 0.5
    local wsTex = art and art.get and art.get('ws_' .. tostring(d.id)) or nil
    F.drawCrystalMedallion(dl, mCx, mCy, mR, {
        texId = wsTex,
        rim   = unlocked and F.u32.soul_gold_bright or F.u32.crystal_violet,
        core  = unlocked and F.rgba.soul_gold or F.rgba.crystal_violet,
        studs = true,
    })

    local infoX = mCx + mR + 16 * s
    local rightCtrlW = math.floor(148 * s)
    local infoMaxW = math.max(120, hw - (infoX - hx) - rightCtrlW - 12 * s)

    -- WS Eyebrow & Title
    local eyeLabel = isEvo and 'EVOLUTION FORGE' or 'WEAPON SKILL MASTERY'
    F.drawShadowText(imgui, dl, infoX, hy + 10 * s, eyeLabel, F.u32.soul_gold, 0.76 * s, 'l')
    F.drawShadowText(imgui, dl, infoX, hy + 26 * s, F.fitText(imgui, d.name, infoMaxW, 1.12 * s), F.u32.text_primary, 1.12 * s, 'l')

    local metaLine = string.format('%s  |  %s%s',
        tostring(d.skillName or ''),
        string.upper(tostring(d.wsType or 'physical')),
        (d.orig and d.orig ~= '') and ('  |  Base SC: ' .. d.orig) or '')
    F.drawShadowText(imgui, dl, infoX, hy + 52 * s, F.fitText(imgui, metaLine, infoMaxW, 0.78 * s), F.u32.text_secondary, 0.78 * s, 'l')

    -- Mastery progress gauge inside centerpiece
    local gaugeW = math.max(110, math.min(280 * s, infoMaxW))
    F.drawSegmentedGauge(imgui, dl, infoX, hy + heroH - 24 * s, gaugeW, math.floor(15 * s), spentPts, totalPts, {
        fill      = unlocked and F.rgba.soul_gold or F.rgba.crystal_violet,
        border    = unlocked and F.u32.soul_gold_dim or F.u32.border_strong,
        notches   = isEvo and 5 or 4,
        label     = unlocked and 'MASTERY' or 'LOCKED (CH.1)',
        valueText = string.format('%d / %d', spentPts, totalPts),
        fontScale = 0.72 * s,
    })

    -- Top-right of centerpiece: Canvas Zoom controls (independent of UI Scale)
    local zY = hy + 12 * s
    local zBtnH = math.floor(22 * s)
    local zStep = math.floor(22 * s)
    local zRight = hx + hw - 12 * s

    if F.drawActionButton(imgui, dl, '##sf_zoom_fit', zRight - 36 * s, zY, 36 * s, zBtnH, 'FIT', 'neutral', { fontScale = 0.70 * s }) then
        ui.canvasZoom = 1.0
        ui.panX, ui.panY = 0, 0
        if action.savePrefs then action.savePrefs() end
    end
    if F.drawActionButton(imgui, dl, '##sf_zoom_in', zRight - 36 * s - zStep - 3 * s, zY, zStep, zBtnH, '+', 'neutral', { fontScale = 0.76 * s }) then
        ui.canvasZoom = F.clamp(math.floor((ui.canvasZoom + 0.10) * 100 + 0.5) / 100, 0.75, 1.35)
        if action.savePrefs then action.savePrefs() end
    end
    if F.drawActionButton(imgui, dl, '##sf_zoom_out', zRight - 36 * s - zStep * 2 - 42 * s, zY, zStep, zBtnH, '-', 'neutral', { fontScale = 0.76 * s }) then
        ui.canvasZoom = F.clamp(math.floor((ui.canvasZoom - 0.10) * 100 + 0.5) / 100, 0.75, 1.35)
        if action.savePrefs then action.savePrefs() end
    end
    F.drawShadowText(imgui, dl, zRight - 36 * s - zStep - 22 * s, zY + 4 * s,
        string.format('%d%%', math.floor(ui.canvasZoom * 100 + 0.5)), F.u32.text_secondary, 0.72 * s, 'c')

    -- Status pill below zoom
    F.drawBadgePill(imgui, dl, zRight - 116 * s, hy + heroH - 30 * s,
        unlocked and '[*] AWAKENED' or '[x] LOCKED', {
            width     = math.floor(116 * s),
            height    = math.floor(22 * s),
            fill      = F.u32.abyss_solid,
            border    = unlocked and F.u32.soul_gold or F.u32.danger,
            textCol   = unlocked and F.u32.soul_gold_bright or F.u32.danger,
            fontScale = 0.72 * s,
        })

    -- B. Four Skillchain Forging Tiers (T1/T2 Lv1, T3 Lv2, T4 Lv3 — distinct from the 4 Spec WS Slots)
    local slots = UI.getSkillchainSlots(d)
    local curY = hy + heroH + math.floor(8 * s)
    if #slots > 0 then
        local slotBarH = math.floor(46 * s)
        F.drawPanelFrame(dl, hx, curY, hw, slotBarH, {
            fillTop  = F.u32.midnight_deep,
            fillBot  = F.u32.abyss,
            border   = F.u32.border_subtle,
            accent   = F.u32.crystal_violet,
            rounding = 5,
            corners  = false,
            shadow   = false,
        })

        local labelW = (L.mode == 'focused') and math.floor(66 * s) or math.floor(124 * s)
        F.drawShadowText(imgui, dl, hx + 10 * s, curY + 8 * s,
            L.mode == 'focused' and 'SC FORGE' or 'SKILLCHAIN FORGING', F.u32.crystal_violet_bright, 0.74 * s, 'l')
        F.drawShadowText(imgui, dl, hx + 10 * s, curY + 24 * s,
            L.mode == 'focused' and 'Lv1-Lv3' or 'Optional (up to 3)', F.u32.text_muted, 0.68 * s, 'l')

        local slotsX = hx + labelW + 6 * s
        local slotsAvailW = math.max(160, hw - labelW - 14 * s)
        local slotGap = math.floor(6 * s)
        local slotW = math.floor((slotsAvailW - slotGap * (#slots - 1)) / #slots)
        local slotH = slotBarH - math.floor(10 * s)
        local slotY = curY + math.floor(5 * s)

        for idx, sl in ipairs(slots) do
            local sx = slotsX + (idx - 1) * (slotW + slotGap)
            local slotFocused = scFocused and (nav.sc_slot == idx)
            local border = slotFocused and F.u32.aether_cyan
                or (sl.active and F.u32.soul_gold
                or (sl.unlocked and F.u32.aether_cyan_dim or F.u32.border_subtle))
            local fill   = slotFocused and F.u32.midnight_selected
                or (sl.active and F.abgr(F.rgba.soul_gold_wash, 0.90) or F.u32.abyss_solid)
            dl:AddRectFilled({ sx, slotY }, { sx + slotW, slotY + slotH }, fill, 4)
            dl:AddRect({ sx, slotY }, { sx + slotW, slotY + slotH }, border, 4, 0, (slotFocused or sl.active) and 1.7 or 1.0)

            local headerStr = string.format('T%d %s%s', sl.tier, sl.scLevel, sl.unlocked and '' or (' [' .. sl.lockHint .. ']'))
            F.drawShadowText(imgui, dl, sx + 6 * s, slotY + 3 * s,
                F.fitText(imgui, headerStr, math.max(24, slotW - 44 * s), 0.66 * s),
                sl.active and F.u32.soul_gold or (sl.unlocked and F.u32.aether_cyan or F.u32.text_muted), 0.66 * s, 'l')
            local propMaxW = math.max(24, slotW - 44 * s)
            local propLabel = sl.unlocked and sl.scName or (sl.scId > 0 and (sl.scName .. ' (Locked)') or 'LOCKED')
            F.drawShadowText(imgui, dl, sx + 6 * s, slotY + 18 * s,
                F.fitText(imgui, propLabel, propMaxW, 0.76 * s),
                sl.active and F.u32.text_primary or F.u32.text_muted, 0.76 * s, 'l')

            -- Cycle buttons (< / >) using real OP_CYCLE_SC = 6
            local cBtnW = math.floor(16 * s)
            local cBtnH = math.floor(18 * s)
            local cBtnY = slotY + math.floor((slotH - cBtnH) * 0.5)
            local pendingSc = state.pendingOp ~= nil and (now - (state.pendingOp.sentAt or 0)) < 5.0
            if F.drawActionButton(imgui, dl, '##sf_scp_' .. sl.tier, sx + slotW - cBtnW * 2 - 6 * s, cBtnY, cBtnW, cBtnH, '<', 'neutral', {
                fontScale = 0.72 * s, disabled = pendingSc,
            }) then
                action.cycleSkillchain(d.id, sl.tier, 2)
            end
            if F.drawActionButton(imgui, dl, '##sf_scn_' .. sl.tier, sx + slotW - cBtnW - 4 * s, cBtnY, cBtnW, cBtnH, '>', 'neutral', {
                fontScale = 0.72 * s, disabled = pendingSc,
            }) then
                action.cycleSkillchain(d.id, sl.tier, 1)
            end
        end

        curY = curY + slotBarH + math.floor(8 * s)
    end

    -- C. Scrollable / Zoomable Progression Map Canvas
    local mapH = math.max(140, (y + h) - curY - pad)
    imgui.SetCursorScreenPos({ hx, curY })
    if imgui.BeginChild('##sf_forge_map', { hw, mapH }, ImGuiChildFlags_None or 0) then
        local mdl = imgui.GetWindowDrawList()
        local originX, originY = F.toXY(imgui.GetCursorScreenPos())

        -- Atmospheric concentric Astral Ring backdrop behind the Soulforge tree
        if F.drawAstralRing and L.ornamentLevel >= 1 then
            local ringR = math.min(hw, mapH) * 0.44
            F.drawAstralRing(mdl, originX + hw * 0.5, originY + mapH * 0.48, ringR, { alpha = 0.90 })
        end

        -- Allow middle-mouse drag panning on the map
        if imgui.IsWindowHovered() and imgui.IsMouseDragging and imgui.IsMouseDragging(2) then
            local dx, dy = F.toXY(imgui.GetMouseDragDelta(2))
            ui.panX = F.clamp((ui.panX or 0) + dx, -260, 260)
            ui.panY = F.clamp((ui.panY or 0) + dy, -260, 260)
            if imgui.ResetMouseDragDelta then imgui.ResetMouseDragDelta(2) end
        end

        -- Group real server nodes by tier (excluding evsc_t* skillchain meta-nodes)
        local nodesByTier = {}
        local maxTier = isEvo and 5 or 4
        for _, n in ipairs(d.nodes or {}) do
            if not (isEvo and UI.isSkillchainNode(n)) then
                local t = tonumber(n.tier) or 1
                if t > maxTier then maxTier = t end
                nodesByTier[t] = nodesByTier[t] or {}
                nodesByTier[t][#nodesByTier[t] + 1] = n
            end
        end

        local zoom   = ui.canvasZoom or 1.0
        local zs     = s * zoom
        local mapW   = math.max(300, hw - 18 * s)
        local tierGap = math.floor(28 * zs)
        local cardH  = math.floor((isEvo and 94 or 86) * zs)
        local cardGap = math.floor(14 * zs)
        local stagePadX = math.floor(16 * zs)
        local stageHeadH = math.floor(28 * zs)

        -- Pre-calculate node positions so we can draw parent-child dependency pathways UNDER the cards!
        local nodeRects = {}
        local tierMeta  = {}
        local cursorY   = originY + math.floor(8 * zs) + math.floor((ui.panY or 0))
        local baseX     = originX + math.floor((ui.panX or 0))

        for tier = 1, maxTier do
            local arr = nodesByTier[tier] or {}
            table.sort(arr, function(a, b) return (a.col or 0) < (b.col or 0) end)

            local cols = math.max(1, math.min(isEvo and 2 or 3, #arr))
            local rowsInTier = math.max(1, math.ceil(#arr / cols))
            local boxH = stageHeadH + rowsInTier * cardH + math.max(0, rowsInTier - 1) * cardGap + math.floor(14 * zs)
            local boxW = mapW

            local tierChosen = false
            for _, n in ipairs(arr) do
                if (n.rank or 0) > 0 then tierChosen = true; break end
            end

            tierMeta[tier] = {
                x = baseX, y = cursorY, w = boxW, h = boxH,
                arr = arr, chosen = tierChosen,
            }

            local cardW = math.floor((boxW - stagePadX * 2 - cardGap * (cols - 1)) / cols)
            for i, n in ipairs(arr) do
                local colIdx = (i - 1) % cols
                local rowIdx = math.floor((i - 1) / cols)
                local nx = baseX + stagePadX + colIdx * (cardW + cardGap)
                local ny = cursorY + stageHeadH + rowIdx * (cardH + cardGap)
                nodeRects[n.key] = {
                    node = n, x = nx, y = ny, w = cardW, h = cardH,
                    cx = nx + cardW * 0.5, cy = ny + cardH * 0.5,
                    tier = tier,
                }
            end

            cursorY = cursorY + boxH + tierGap
        end

        -- Pass 1: Draw Tier Chamber Backgrounds & Inter-Tier Spine Connectors
        for tier = 1, maxTier do
            local tm = tierMeta[tier]
            if tier > 1 then
                local prev = tierMeta[tier - 1]
                local spX = tm.x + tm.w * 0.5
                local spineState = prev.chosen and 'active' or (tier == 2 and unlocked and 'available' or 'locked')
                F.drawConnectionPath(mdl, spX, prev.y + prev.h, spX, tm.y, spineState, { stepped = false })
            end

            -- Subtle chamber band
            mdl:AddRectFilled({ tm.x, tm.y }, { tm.x + tm.w, tm.y + tm.h },
                F.abgr(F.rgba.midnight_deep, 0.72), 6)
            mdl:AddRect({ tm.x, tm.y }, { tm.x + tm.w, tm.y + tm.h },
                tm.chosen and F.u32.soul_gold_dim or F.u32.border_subtle, 6, 0, 1.0)

            local chapterTitle = isEvo and (EVO_STAGE_NAMES[tier] or ('STAGE ' .. tier)) or ('TIER ' .. tier)
            if tier == 1 and not unlocked then chapterTitle = 'UNLOCK WEAPON SKILL' end
            F.drawShadowText(imgui, mdl, tm.x + stagePadX, tm.y + 6 * zs,
                string.format('CHAPTER %02d  |  %s', tier, chapterTitle),
                tm.chosen and F.u32.soul_gold or F.u32.text_secondary, 0.78 * zs, 'l')

            if isEvo then
                F.drawShadowText(imgui, mdl, tm.x + tm.w - stagePadX, tm.y + 6 * zs,
                    tm.chosen and '[*] ACTIVATED' or 'UNCLAIMED',
                    tm.chosen and F.u32.soul_gold_bright or F.u32.text_muted, 0.74 * zs, 'r')
            end
        end

        -- Pass 2: Draw Explicit Parent -> Child Dependency Pathways (reqKey)
        for _, rect in pairs(nodeRects) do
            local n = rect.node
            if n.reqKey and nodeRects[n.reqKey] then
                local pRect = nodeRects[n.reqKey]
                local pRank = tonumber(pRect.node.rank) or 0
                local cRank = tonumber(n.rank) or 0
                local linkState = (pRank > 0 and cRank > 0) and 'active'
                    or (pRank > 0 and n.canLearn and 'available')
                    or 'locked'
                F.drawConnectionPath(mdl, pRect.cx, pRect.y + pRect.h, rect.cx, rect.y, linkState, { stepped = true })
            end
        end

        -- Pass 3: Draw Interactive Talent Nodes
        for tier = 1, maxTier do
            local tm = tierMeta[tier]
            for _, n in ipairs(tm.arr) do
                local r = nodeRects[n.key]
                local otherChosen = isEvo and tm.chosen and (n.rank or 0) == 0
                local eval = UI.evaluateNode(state, d, n, otherChosen, now)
                local selected = (state.inspectedNodeKey == n.key)

                imgui.SetCursorScreenPos({ r.x, r.y })
                imgui.InvisibleButton('##sf_node_' .. n.key, { r.w, r.h })
                local hovered = imgui.IsItemHovered()

                if imgui.IsItemClicked(0) then
                    state.inspectedNodeKey = n.key
                    ui.confirmAction = nil
                    if nav and nav.on_focus then nav.on_focus('tree', n.key) end
                    if L.drawerMode then ui.drawerOpen = 'inspector' end
                end

                local sp = eval.spec
                local padNodeFocused = treeFocused and (nav.node_key == n.key)
                local fillU32   = F.abgr(sp.fill)
                local borderU32 = (padNodeFocused or selected) and F.u32.aether_cyan
                    or (hovered and F.u32.soul_gold_bright or F.abgr(sp.border))
                local thick     = padNodeFocused and 2.5 or (selected and 2.2 or (hovered and 1.8 or sp.thickness))

                mdl:AddRectFilled({ r.x, r.y }, { r.x + r.w, r.y + r.h }, fillU32, 6)
                mdl:AddRect({ r.x, r.y }, { r.x + r.w, r.y + r.h }, borderU32, 6, 0, thick)
                if sp.doubleRim then
                    mdl:AddRect({ r.x + 3, r.y + 3 }, { r.x + r.w - 3, r.y + r.h - 3 },
                        F.abgr(sp.accent, 0.55), 4, 0, 1.0)
                end

                -- Left state accent strip
                if eval.stateKey == 'learned' or eval.stateKey == 'maxed' or eval.stateKey == 'available' then
                    mdl:AddRectFilled({ r.x + 1, r.y + 6 }, { r.x + 4, r.y + r.h - 6 }, F.abgr(sp.accent), 1)
                end

                -- Selection corner brackets
                if selected then
                    local bk = math.floor(8 * zs)
                    mdl:AddLine({ r.x - 2, r.y + bk }, { r.x - 2, r.y - 2 }, F.u32.aether_cyan, 2.0)
                    mdl:AddLine({ r.x - 2, r.y - 2 }, { r.x + bk, r.y - 2 }, F.u32.aether_cyan, 2.0)
                    mdl:AddLine({ r.x + r.w - bk, r.y - 2 }, { r.x + r.w + 2, r.y - 2 }, F.u32.aether_cyan, 2.0)
                    mdl:AddLine({ r.x + r.w + 2, r.y - 2 }, { r.x + r.w + 2, r.y + bk }, F.u32.aether_cyan, 2.0)
                end

                -- Framed node icon
                local icSz = math.floor(math.min(54 * zs, r.h - 18 * zs))
                local ix, iy = r.x + 10 * zs, r.y + math.floor((r.h - icSz) * 0.5)
                mdl:AddRectFilled({ ix, iy }, { ix + icSz, iy + icSz }, F.u32.abyss_solid, 5)
                local iconTint = (eval.stateKey == 'locked' or eval.stateKey == 'prereq_blocked')
                    and F.abgr(F.rgba.text_muted, 0.72) or 0xFFFFFFFF
                local drawnIcon = drawAssetOrFallback(mdl, 'node_' .. n.key, ix + 2, iy + 2, icSz - 4, icSz - 4, iconTint)
                if not drawnIcon then
                    drawnIcon = drawAssetOrFallback(mdl, 'ws_' .. tostring(d.id), ix + 2, iy + 2, icSz - 4, icSz - 4, iconTint)
                end
                if not drawnIcon then
                    F.drawCrystalMedallion(mdl, ix + icSz * 0.5, iy + icSz * 0.5, icSz * 0.40, {
                        rim   = F.abgr(sp.border),
                        core  = sp.accent,
                        studs = false,
                    })
                end
                mdl:AddRect({ ix, iy }, { ix + icSz, iy + icSz }, F.abgr(sp.border), 5, 0, 1.2)

                -- Node title, non-color state tag + symbol, rank pips, concise effect preview
                local tx = ix + icSz + 10 * zs
                local availTextW = math.max(40, (r.x + r.w) - tx - 10 * zs)
                F.drawShadowText(imgui, mdl, tx, r.y + 8 * zs,
                    F.fitText(imgui, n.name, availTextW - 56 * zs, 0.88 * zs),
                    F.abgr(sp.text), 0.88 * zs, 'l')

                -- Top-right state badge `[+]` / `[*]` / `[#]` / `[!]` / `[x]`
                local tagStr = string.format('[%s] %s', sp.symbol, sp.tag)
                F.drawShadowText(imgui, mdl, r.x + r.w - 8 * zs, r.y + 9 * zs,
                    tagStr, F.abgr(sp.accent), 0.70 * zs, 'r')

                -- Effect one-liner
                F.drawShadowText(imgui, mdl, tx, r.y + 29 * zs,
                    F.fitText(imgui, n.desc, availTextW, 0.74 * zs),
                    (eval.stateKey == 'locked') and F.u32.text_muted or F.u32.text_secondary, 0.74 * zs, 'l')

                -- Bottom row: Rank pips + numeric rank
                local pipY = r.y + r.h - math.floor(19 * zs)
                local pipMax = math.min(eval.maxRank, 5)
                F.drawPipRow(mdl, tx, pipY, eval.rank, pipMax, {
                    size  = math.floor(10 * zs),
                    pitch = math.floor(14 * zs),
                    lit   = (eval.stateKey == 'maxed') and F.rgba.soul_gold_bright or F.rgba.soul_gold,
                    glow  = (eval.stateKey == 'maxed'),
                })
                F.drawShadowText(imgui, mdl, r.x + r.w - 8 * zs, pipY - 1,
                    string.format('Rank %d/%d', eval.rank, eval.maxRank),
                    eval.rank > 0 and F.u32.soul_gold or F.u32.text_muted, 0.72 * zs, 'r')
            end
        end

        -- Grow scroll canvas cleanly
        imgui.SetCursorScreenPos({ originX, cursorY + 8 })
        imgui.Dummy({ mapW, 4 })
    end
    imgui.EndChild()
end

-- ---------------------------------------------------------------------------
-- 4. Right Panel: Talent Inspector & Deliberate Upgrade Confirmation
-- ---------------------------------------------------------------------------
local function drawInspector(state, action, L, x, y, w, h, nav)
    local dl  = imgui.GetWindowDrawList()
    local s   = L.uiScale
    local ui  = ensureUiState(state)
    local d   = state.wsDetail
    local pad = math.floor(14 * s)
    local now = os.clock()
    local inspFocused = (nav ~= nil and (nav.region == 'inspector' or nav.region == 'confirm'))

    F.drawPanelFrame(dl, x, y, w, h, {
        fillTop  = F.u32.midnight,
        fillBot  = F.u32.abyss,
        border   = inspFocused and F.u32.aether_cyan or F.u32.border_subtle,
        accent   = inspFocused and F.u32.aether_cyan or F.u32.aether_cyan_dim,
        thickness = inspFocused and 1.6 or 1.1,
        corners  = (L.ornamentLevel >= 1),
        shadow   = false,
    })

    F.drawShadowText(imgui, dl, x + pad, y + 10 * s,
        inspFocused and '> TALENT DETAILS' or 'TALENT DETAILS',
        inspFocused and F.u32.aether_cyan or F.u32.soul_gold, 0.94 * s, 'l')
    F.drawDivider(dl, x + pad, y + 32 * s, w - pad * 2, inspFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    if not d then
        F.drawShadowText(imgui, dl, x + pad, y + 48 * s, 'Select a Weapon Skill to inspect its techniques.', F.u32.text_secondary, 0.84 * s, 'l')
        return
    end

    local node = d.byKey and d.byKey[state.inspectedNodeKey]
    if not node then
        for _, cand in ipairs(d.nodes or {}) do
            if not UI.isSkillchainNode(cand) then
                node = cand
                state.inspectedNodeKey = cand.key
                break
            end
        end
    end
    if not node then
        F.drawShadowText(imgui, dl, x + pad, y + 48 * s, 'No inspectable talent nodes available.', F.u32.text_muted, 0.84 * s, 'l')
        return
    end

    local isEvo = UI.isEvolutionTree(d)
    local tierHasOtherChosen = false
    if isEvo then
        for _, sib in ipairs(d.nodes or {}) do
            if sib.tier == node.tier and sib.key ~= node.key and (sib.rank or 0) > 0 then
                tierHasOtherChosen = true
                break
            end
        end
    end

    local eval = UI.evaluateNode(state, d, node, tierHasOtherChosen, now)
    local sp   = eval.spec
    local cy   = y + 42 * s
    local innerW = w - pad * 2

    -- Node Title + Stage/Classification + State Pill
    F.drawShadowText(imgui, dl, x + pad, cy, F.fitText(imgui, node.name, innerW, 1.04 * s), F.abgr(sp.text), 1.04 * s, 'l')
    cy = cy + 24 * s

    local stageLabel = isEvo and (EVO_STAGE_NAMES[node.tier or 1] or ('STAGE ' .. (node.tier or 1)))
        or ('TIER ' .. (node.tier or 1))
    F.drawShadowText(imgui, dl, x + pad, cy + 2 * s, stageLabel, F.u32.crystal_violet_bright, 0.78 * s, 'l')
    F.drawBadgePill(imgui, dl, x + w - pad - 104 * s, cy - 2 * s,
        string.format('[%s] %s', sp.symbol, sp.tag), {
            width     = math.floor(104 * s),
            height    = math.floor(20 * s),
            fill      = F.u32.abyss_solid,
            border    = F.abgr(sp.border),
            textCol   = F.abgr(sp.accent),
            fontScale = 0.70 * s,
        })
    cy = cy + 26 * s

    -- Emblem + Rank & Cost Summary Card
    local cardH = math.floor(68 * s)
    dl:AddRectFilled({ x + pad, cy }, { x + w - pad, cy + cardH }, F.u32.abyss_solid, 5)
    dl:AddRect({ x + pad, cy }, { x + w - pad, cy + cardH }, F.abgr(sp.border), 5, 0, 1.1)

    local emSz = math.floor(52 * s)
    local emX, emY = x + pad + 8 * s, cy + math.floor((cardH - emSz) * 0.5)
    if not drawAssetOrFallback(dl, 'node_' .. node.key, emX, emY, emSz, emSz) then
        if not drawAssetOrFallback(dl, 'ws_' .. tostring(d.id), emX, emY, emSz, emSz) then
            F.drawCrystalMedallion(dl, emX + emSz * 0.5, emY + emSz * 0.5, emSz * 0.42, {
                rim = F.abgr(sp.border), core = sp.accent, studs = false,
            })
        end
    end
    dl:AddRect({ emX, emY }, { emX + emSz, emY + emSz }, F.abgr(sp.border), 4, 0, 1.1)

    local metaX = emX + emSz + 12 * s
    F.drawShadowText(imgui, dl, metaX, cy + 10 * s,
        string.format('RANK  %d / %d', eval.rank, eval.maxRank), F.u32.soul_gold_bright, 0.88 * s, 'l')
    F.drawPipRow(dl, metaX, cy + 31 * s, eval.rank, math.min(eval.maxRank, 5), {
        size = math.floor(11 * s), pitch = math.floor(15 * s), lit = F.rgba.soul_gold,
    })
    F.drawShadowText(imgui, dl, metaX, cy + 48 * s,
        string.format('COST: %d PT  |  AVAILABLE: %d', eval.cost, state.avail or 0),
        eval.availOk and F.u32.aether_cyan or F.u32.danger, 0.74 * s, 'l')
    cy = cy + cardH + 12 * s

    -- Current Effect & Highlighted Next-Rank Preview Cards (approved Soulforge visual direction)
    local charsPerLine = math.max(20, math.floor((innerW - 16 * s) / (7.6 * s)))
    local descLines = F.wrapLines(node.desc ~= '' and node.desc or 'No description provided by server.', charsPerLine, 4)
    local curBoxH = math.floor(26 * s + #descLines * 16 * s)
    dl:AddRectFilled({ x + pad, cy }, { x + w - pad, cy + curBoxH }, F.u32.midnight_deep, 5)
    dl:AddRect({ x + pad, cy }, { x + w - pad, cy + curBoxH }, F.u32.border_strong, 5, 0, 1.0)
    F.drawShadowText(imgui, dl, x + pad + 8 * s, cy + 5 * s,
        string.format('Current Effect (Rank %d)', eval.rank), F.u32.soul_gold, 0.76 * s, 'l')
    for i, line in ipairs(descLines) do
        F.drawShadowText(imgui, dl, x + pad + 8 * s, cy + 21 * s + (i - 1) * 16 * s, line, F.u32.text_primary, 0.78 * s, 'l')
    end
    cy = cy + curBoxH + 8 * s

    -- Highlighted Gold Next-Rank Preview Card
    if eval.rank < eval.maxRank then
        local nxtBoxH = math.floor(42 * s)
        dl:AddRectFilled({ x + pad, cy }, { x + w - pad, cy + nxtBoxH }, F.abgr(F.rgba.soul_gold_wash, 0.85), 5)
        dl:AddRect({ x + pad, cy }, { x + w - pad, cy + nxtBoxH }, F.u32.soul_gold, 5, 0, 1.3)
        F.drawShadowText(imgui, dl, x + pad + 8 * s, cy + 5 * s,
            string.format('-> Next Rank (Rank %d)', eval.rank + 1), F.u32.soul_gold_bright, 0.78 * s, 'l')
        local nextLine = string.format('Rank %d -> %d  (-%d pt, %d remaining)',
            eval.rank, eval.rank + 1, eval.cost, math.max(0, (state.avail or 0) - eval.cost))
        F.drawShadowText(imgui, dl, x + pad + 8 * s, cy + 22 * s,
            F.fitText(imgui, nextLine, innerW - 16 * s, 0.76 * s), F.u32.text_primary, 0.76 * s, 'l')
        cy = cy + nxtBoxH + 10 * s
    end

    -- Prerequisites Checklist
    F.drawDivider(dl, x + pad, cy, innerW, F.u32.border_strong)
    cy = cy + 10 * s
    F.drawShadowText(imgui, dl, x + pad, cy, 'REQUIREMENTS', F.u32.soul_gold, 0.78 * s, 'l')
    cy = cy + 18 * s

    local function reqRow(ok, label)
        F.drawShadowText(imgui, dl, x + pad, cy, (ok and '[OK] ' or '[REQ] ') .. label,
            ok and F.u32.success or F.u32.danger, 0.78 * s, 'l')
        cy = cy + math.floor(17 * s)
    end

    reqRow(eval.lvlOk, string.format('Job Level %d+ (Now %d)', node.reqLevel or 1, state.jobLevel or 1))
    if (node.reqWsPoints or 0) > 0 then
        reqRow(eval.ptsOk, string.format('%d+ WS Points (Now %d)', node.reqWsPoints, d.spent or 0))
    end
    if eval.parentNode then
        reqRow(eval.parentOk, F.fitText(imgui, string.format('%s (Rank %d+)', eval.parentNode.name, math.max(1, node.reqRank or 1)), innerW - 36 * s, 0.78 * s))
    end
    if eval.rank < eval.maxRank then
        reqRow(eval.availOk, string.format('%d Talent Point(s) Available', eval.cost))
        -- Point Cost footer row with glowing crystal star
        cy = cy + 4 * s
        F.drawDivider(dl, x + pad, cy, innerW, F.u32.border_subtle)
        cy = cy + 8 * s
        F.drawShadowText(imgui, dl, x + pad, cy + 2 * s, 'Point Cost', F.u32.text_secondary, 0.80 * s, 'l')
        if F.drawCrystalStar then
            F.drawCrystalStar(dl, x + w - pad - 24 * s, cy + 9 * s, 8 * s, F.u32.crystal_violet_bright, F.u32.white)
        end
        F.drawShadowText(imgui, dl, x + w - pad - 2 * s, cy + 1 * s, tostring(eval.cost),
            eval.availOk and F.u32.soul_gold_bright or F.u32.danger, 0.90 * s, 'r')
        cy = cy + 22 * s
    end

    -- Unavailability / Rejection Explanation Card
    if eval.reason then
        cy = cy + 6 * s
        local isErr = (eval.stateKey == 'rejected')
        local boxCol = isErr and F.abgr(F.rgba.danger_wash, 0.95) or F.u32.abyss_solid
        local boxRim = isErr and F.u32.danger or F.u32.border_strong
        local rLines = F.wrapLines(eval.reason, charsPerLine, 3)
        local rH = math.floor(14 * s + #rLines * 16 * s)
        dl:AddRectFilled({ x + pad, cy }, { x + w - pad, cy + rH }, boxCol, 4)
        dl:AddRect({ x + pad, cy }, { x + w - pad, cy + rH }, boxRim, 4, 0, 1.1)
        for i, rl in ipairs(rLines) do
            F.drawShadowText(imgui, dl, x + pad + 8 * s, cy + 6 * s + (i - 1) * 16 * s,
                rl, isErr and F.u32.danger or F.u32.text_secondary, 0.76 * s, 'l')
        end
        cy = cy + rH + 8 * s
    end

    -- Bottom Action Dock: Deliberate Confirmation Flow
    local actBtnH = math.floor(34 * s)
    local actY    = (y + h) - pad - actBtnH
    if ui.confirmAction and ui.confirmAction.nodeKey == node.key and ui.confirmAction.wsId == d.id then
        -- Two-step deliberate confirmation bar
        local confirmH = math.floor(66 * s)
        local cTop = (y + h) - pad - confirmH
        dl:AddRectFilled({ x + pad, cTop }, { x + w - pad, cTop + confirmH }, F.u32.midnight_alt, 5)
        dl:AddRect({ x + pad, cTop }, { x + w - pad, cTop + confirmH },
            ui.confirmAction.kind == 'refund' and F.u32.danger or F.u32.soul_gold, 5, 0, 1.4)

        local summary = ui.confirmAction.kind == 'refund'
            and string.format('Refund %s (Rank %d -> %d)?', node.name, eval.rank, eval.rank - 1)
            or string.format('Forge %s (Rank %d -> %d, -%d pt)?', node.name, eval.rank, eval.rank + 1, eval.cost)
        F.drawShadowText(imgui, dl, x + pad + 8 * s, cTop + 7 * s,
            F.fitText(imgui, summary, innerW - 16 * s, 0.78 * s), F.u32.soul_gold_bright, 0.78 * s, 'l')

        local halfW = math.floor((innerW - 22 * s) * 0.5)
        local bY = cTop + confirmH - math.floor(30 * s) - 6 * s
        local bH = math.floor(28 * s)
        local cGoFocused = (nav ~= nil and nav.region == 'confirm' and (nav.confirm_btn or 1) == 1)
        local cNoFocused = (nav ~= nil and nav.region == 'confirm' and nav.confirm_btn == 2)
        if F.drawActionButton(imgui, dl, '##sf_confirm_go', x + pad + 6 * s, bY, halfW, bH,
            (cGoFocused and '> ' or '') .. (ui.confirmAction.kind == 'refund' and 'CONFIRM REFUND' or 'CONFIRM FORGE'),
            ui.confirmAction.kind == 'refund' and 'danger' or 'gold', { fontScale = 0.78 * s }) then
            local kind = ui.confirmAction.kind
            ui.confirmAction = nil
            if kind == 'refund' then
                action.refundNode(d.id, node)
            else
                action.investNode(d.id, node)
            end
        end
        if cGoFocused and dl then
            dl:AddRect({ x + pad + 5 * s, bY - 1 }, { x + pad + 7 * s + halfW, bY + bH + 1 }, F.u32.aether_cyan, 5, 0, 2.0)
        end
        if F.drawActionButton(imgui, dl, '##sf_confirm_cancel', x + pad + 12 * s + halfW, bY, halfW, bH,
            (cNoFocused and '> ' or '') .. 'CANCEL', 'neutral', { fontScale = 0.78 * s }) then
            ui.confirmAction = nil
        end
        if cNoFocused and dl then
            dl:AddRect({ x + pad + 11 * s + halfW, bY - 1 }, { x + pad + 13 * s + halfW * 2, bY + bH + 1 }, F.u32.aether_cyan, 5, 0, 2.0)
        end
    else
        -- Primary Upgrade / Unlock button + optional Refund button
        local inspBtn = (nav ~= nil and nav.region == 'inspector') and (nav.inspector_btn or 1) or 0
        if eval.stateKey == 'pending' then
            F.drawActionButton(imgui, dl, '##sf_pending', x + pad, actY, innerW, actBtnH,
                'CONFIRMING WITH SERVER...', 'cyan', { disabled = true, fontScale = 0.82 * s })
        elseif eval.canUpgrade then
            local firstUnlock = (node.tier or 1) == 1 and not UI.isWsUnlocked(state)
            local lbl = firstUnlock and ('UNLOCK ' .. string.upper(d.name))
                or (eval.rank > 0 and string.format('UPGRADE TO RANK %d (-%d PT)', eval.rank + 1, eval.cost)
                or string.format('FORGE TECHNIQUE (-%d PT)', eval.cost))
            -- Ornate beveled Gold CTA button matching approved Soulforge visual direction
            local clickedUp, hoveredUp = false, false
            if imgui and imgui.SetCursorScreenPos and imgui.InvisibleButton then
                imgui.SetCursorScreenPos({ x + pad, actY })
                clickedUp = imgui.InvisibleButton('##sf_upgrade', { innerW, actBtnH })
                hoveredUp = imgui.IsItemHovered and imgui.IsItemHovered() or false
            end
            if F.drawBeveledPill then
                F.drawBeveledPill(dl, x + pad, actY, innerW, actBtnH, {
                    bevel     = math.floor(12 * s),
                    fillTop   = F.abgr(hoveredUp and F.hex('#5E4822', 0.98) or F.hex('#3E3018', 0.96)),
                    fillBot   = F.abgr(F.hex('#1F180B', 0.98)),
                    border    = (inspBtn == 1) and F.u32.aether_cyan or (hoveredUp and F.u32.soul_gold_bright or F.u32.soul_gold),
                    glow      = F.abgr(F.rgba.soul_gold, hoveredUp and 0.24 or 0.14),
                    highlight = F.abgr(F.rgba.soul_gold_bright, 0.45),
                    thickness = (inspBtn == 1) and 2.0 or 1.5,
                })
                F.drawShadowText(imgui, dl, x + pad + innerW * 0.5, actY + (actBtnH - 14 * 0.84 * s) * 0.5,
                    F.fitText(imgui, (inspBtn == 1 and '> ' or '') .. lbl, innerW - 24 * s, 0.84 * s),
                    F.u32.soul_gold_bright, 0.84 * s, 'c')
            else
                clickedUp = F.drawActionButton(imgui, dl, '##sf_upgrade_fb', x + pad, actY, innerW, actBtnH,
                    (inspBtn == 1 and '> ' or '') .. lbl, 'gold', { fontScale = 0.82 * s })
            end
            if clickedUp then
                ui.confirmAction = { kind = 'invest', wsId = d.id, nodeKey = node.key }
                if nav and nav.on_focus then nav.on_focus('confirm', 1) end
            end
            if eval.canRefund then
                local refY = actY - actBtnH - 6 * s
                local refH = math.floor(28 * s)
                if F.drawActionButton(imgui, dl, '##sf_refund_sec', x + pad, refY, innerW, refH,
                    (inspBtn == 2 and '> ' or '') .. 'REFUND 1 RANK', 'danger', { fontScale = 0.76 * s }) then
                    ui.confirmAction = { kind = 'refund', wsId = d.id, nodeKey = node.key }
                    if nav and nav.on_focus then nav.on_focus('confirm', 1) end
                end
                if inspBtn == 2 and dl then
                    dl:AddRect({ x + pad - 1, refY - 1 }, { x + pad + innerW + 1, refY + refH + 1 }, F.u32.aether_cyan, 5, 0, 2.0)
                end
            end
        elseif eval.canRefund then
            if F.drawActionButton(imgui, dl, '##sf_refund', x + pad, actY, innerW, actBtnH,
                (inspBtn == 1 and '> ' or '') .. 'REFUND TECHNIQUE', 'danger', { fontScale = 0.82 * s }) then
                ui.confirmAction = { kind = 'refund', wsId = d.id, nodeKey = node.key }
                if nav and nav.on_focus then nav.on_focus('confirm', 1) end
            end
            if inspBtn == 1 and dl then
                dl:AddRect({ x + pad - 1, actY - 1 }, { x + pad + innerW + 1, actY + actBtnH + 1 }, F.u32.aether_cyan, 5, 0, 2.0)
            end
        else
            F.drawActionButton(imgui, dl, '##sf_locked_btn', x + pad, actY, innerW, actBtnH,
                eval.stateKey == 'maxed' and 'MASTERY COMPLETE' or 'UNAVAILABLE', 'neutral',
                { disabled = true, fontScale = 0.82 * s })
        end
    end
end

-- ---------------------------------------------------------------------------
-- 5. Contextual Footer Bar
-- ---------------------------------------------------------------------------
local function drawFooter(state, action, L, x, y, w, h)
    local dl  = imgui.GetWindowDrawList()
    local s   = L.uiScale
    local ui  = ensureUiState(state)
    local now = os.clock()

    F.drawPanelFrame(dl, x, y, w, h, {
        fillTop  = F.u32.midnight_deep,
        fillBot  = F.u32.abyss_solid,
        border   = F.u32.border_subtle,
        corners  = false,
        shadow   = false,
    })

    -- Left: Status / Error / Mode feedback
    local msg, msgCol
    if state.renderError then
        msg, msgCol = 'UI Error: ' .. tostring(state.renderError), F.u32.danger
    elseif state.rejectedMsg and state.rejectedAt and (now - state.rejectedAt) < 5.0 then
        msg, msgCol = 'Server Rejected: ' .. tostring(state.rejectedMsg), F.u32.danger
    elseif state.statusText and (now - (state.statusTime or 0)) < 5.0 then
        msg, msgCol = tostring(state.statusText), F.u32.aether_cyan
    else
        msg = string.format('Layout: %s (%dx%d)  |  Click node to inspect  |  Middle-drag map to pan',
            string.upper(L.mode), L.viewW, L.viewH)
        msgCol = F.u32.text_muted
    end

    local btnH = math.floor(24 * s)
    local btnY = y + math.floor((h - btnH) * 0.5)
    local rightUsed = math.floor(230 * s)
    F.drawShadowText(imgui, dl, x + 12 * s, y + math.floor((h - 14 * s) * 0.5),
        F.fitText(imgui, msg, math.max(120, w - rightUsed - 24 * s), 0.78 * s), msgCol, 0.78 * s, 'l')

    -- Right: Reset WS (single WS) & Reset Spec (all WS) with 2-step confirmation
    local rx = x + w - 10 * s
    local specBtnW = math.floor(104 * s)
    rx = rx - specBtnW
    if not state.confirmResetAll then
        if F.drawActionButton(imgui, dl, '##sf_reset_all', rx, btnY, specBtnW, btnH, 'RESET SPEC', 'neutral', { fontScale = 0.74 * s }) then
            state.confirmResetAll = true
            state.confirmResetAt  = now
        end
    elseif (now - (state.confirmResetAt or 0)) > 5.0 then
        state.confirmResetAll = false
    else
        if F.drawActionButton(imgui, dl, '##sf_reset_all_ok', rx, btnY, specBtnW, btnH, 'CONFIRM ALL', 'danger', { fontScale = 0.74 * s }) then
            state.confirmResetAll = false
            action.resetAll()
        end
    end

    if state.wsDetail and (state.wsDetail.spent or 0) > 0 then
        local wsBtnW = math.floor(94 * s)
        rx = rx - wsBtnW - 6 * s
        if not ui.confirmResetWs then
            if F.drawActionButton(imgui, dl, '##sf_reset_ws', rx, btnY, wsBtnW, btnH, 'RESET WS', 'neutral', { fontScale = 0.74 * s }) then
                ui.confirmResetWs   = true
                ui.confirmResetWsAt = now
            end
        elseif (now - (ui.confirmResetWsAt or 0)) > 5.0 then
            ui.confirmResetWs = false
        else
            if F.drawActionButton(imgui, dl, '##sf_reset_ws_ok', rx, btnY, wsBtnW, btnH, 'CONFIRM WS', 'danger', { fontScale = 0.74 * s }) then
                ui.confirmResetWs = false
                action.resetWS(state.wsDetail.id)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Main Entry Point
-- ---------------------------------------------------------------------------
function UI.computeLayout(state, viewW, viewH)
    local ui = ensureUiState(state)
    return F.computeViewportLayout(viewW, viewH, ui.scale or 1.0, {
        maxLogicalW = 1920,
        maxLogicalH = 1160,
    })
end

-- Embedded entry point for SoulspireXI Core (renders inside Core's central content area
-- beneath the Dynamic Module Header, aligned to the approved Soulforge visual direction).
function UI.drawEmbedded(state, action, L, x, y, w, h, nav)
    local ui = ensureUiState(state)
    local dl = imgui.GetWindowDrawList()
    local s  = L.uiScale or 1.0
    local gap = L.gap or math.floor(8 * s)

    -- Ornate Gilded Soulforge Sub-Header Banner:
    --   Left: Job & Soul Identity | Center: THE SOULFORGE / WEAPON SKILL TALENTS
    --   Right: Mastery Slots (X / 4) Diamond Sockets + Glowing Talent Points Star
    local subH = math.floor(((L.mode == 'focused' and 52) or 68) * s)
    F.drawPanelFrame(dl, x, y, w, subH, {
        fillTop  = F.u32.midnight_alt,
        fillBot  = F.u32.midnight_deep,
        border   = F.u32.soul_gold_dim,
        accent   = F.u32.soul_gold,
        rounding = 6,
        corners  = true,
        shadow   = false,
    })

    local avail  = tonumber(state.avail) or 0
    local spent  = tonumber(state.spent) or 0
    local earned = math.max(1, tonumber(state.earned) or (avail + spent))
    local investedList = UI.getInvestedWeaponskills(state)
    local now = os.clock()

    -- Left: Job Crest + Job Lv & Active Soul Identity
    local medR = math.floor(math.min(20 * s, (subH - 14) * 0.5))
    local medX = x + 16 * s + medR
    local medY = y + subH * 0.5
    F.drawCrystalMedallion(dl, medX, medY, medR, {
        rim   = F.u32.soul_gold,
        core  = F.rgba.crystal_violet,
        studs = (L.ornamentLevel >= 1),
    })
    local idX = medX + medR + 12 * s
    F.drawShadowText(imgui, dl, idX, y + 10 * s,
        string.format('%s  Lv.%d', state.jobKey or '---', state.jobLevel or 1),
        F.u32.text_primary, 0.98 * s, 'l')
    F.drawShadowText(imgui, dl, idX, y + 32 * s,
        F.fitText(imgui, 'Soul: ' .. tostring(state.specName or 'Base'), math.floor(w * 0.24), 0.80 * s),
        F.u32.crystal_violet_bright, 0.80 * s, 'l')

    -- Center: "THE SOULFORGE / — WEAPON SKILL TALENTS —"
    local midX = x + w * 0.5
    if L.mode ~= 'focused' then
        F.drawShadowText(imgui, dl, midX, y + 10 * s, 'THE SOULFORGE', F.u32.soul_gold_bright, 1.24 * s, 'c')
        local subTitleY = y + 38 * s
        F.drawShadowText(imgui, dl, midX, subTitleY, 'WEAPON SKILL TALENTS', F.u32.soul_gold_dim, 0.74 * s, 'c')
        if dl and dl.AddLine then
            dl:AddLine({ midX - 104 * s, subTitleY + 6 * s }, { midX - 72 * s, subTitleY + 6 * s }, F.u32.soul_gold_dim, 1.0)
            dl:AddLine({ midX + 72 * s, subTitleY + 6 * s }, { midX + 104 * s, subTitleY + 6 * s }, F.u32.soul_gold_dim, 1.0)
        end
    else
        F.drawShadowText(imgui, dl, midX, y + 14 * s, 'THE SOULFORGE', F.u32.soul_gold_bright, 1.02 * s, 'c')
    end

    -- Far Right: Talent Points Star + Number, then Mastery Slots (X / 4) Diamond Sockets
    local rx = x + w - 16 * s
    local tpBlockW = math.floor(88 * s)
    local tpX = rx - tpBlockW
    F.drawShadowText(imgui, dl, tpX + tpBlockW * 0.5, y + 6 * s, 'Talent Points', F.u32.soul_gold, 0.70 * s, 'c')
    if F.drawCrystalStar then
        F.drawCrystalStar(dl, tpX + 22 * s, y + subH * 0.62, 11 * s, F.u32.crystal_violet_bright, F.u32.white)
    end
    F.drawShadowText(imgui, dl, tpX + 42 * s, y + subH * 0.44, tostring(avail),
        avail > 0 and F.u32.white or F.u32.text_muted, 1.28 * s, 'l')

    -- Vertical divider between Talent Points and Mastery Slots
    local divX = tpX - 10 * s
    if dl and dl.AddLine then
        dl:AddLine({ divX, y + 10 * s }, { divX, y + subH - 10 * s }, F.u32.border_strong, 1.0)
    end

    if L.mode ~= 'focused' then
        local msW = math.floor(168 * s)
        local msX = divX - msW - 12 * s
        F.drawShadowText(imgui, dl, msX + msW * 0.5, y + 6 * s,
            string.format('Mastery Slots (%d / %d)', #investedList, UI.MAX_SPEC_WS_SLOTS),
            F.u32.text_primary, 0.72 * s, 'c')
        local dr = math.floor(14 * s)
        local dPitch = math.floor(38 * s)
        local dStartX = msX + 26 * s
        local dY = y + math.floor(42 * s)
        for i = 1, UI.MAX_SPEC_WS_SLOTS do
            local item = investedList[i]
            local dCx = dStartX + (i - 1) * dPitch
            local tex = item and art and art.get and art.get('ws_' .. tostring(item.id)) or nil
            if F.drawDiamondSocket then
                F.drawDiamondSocket(dl, dCx, dY, dr, {
                    lit     = (item ~= nil),
                    active  = (item ~= nil and state.selectedWsId == item.id),
                    texId   = tex,
                    coreU32 = (item and item.mastered) and F.u32.soul_gold_bright or F.u32.crystal_violet_bright,
                })
            end
            if item and imgui.SetCursorScreenPos and imgui.InvisibleButton then
                imgui.SetCursorScreenPos({ dCx - dr, dY - dr })
                if imgui.InvisibleButton('##sf_hdr_slot_' .. i, { dr * 2, dr * 2 }) then
                    state.inspectedNodeKey = nil
                    ui.confirmAction = nil
                    action.requestWS(item.id)
                end
            end
        end

        -- Compact Sync / Reset WS utility controls to the left of Mastery Slots (only when space allows)
        local utilRight = msX - 14 * s
        local btnH = math.floor(20 * s)
        local btnY = y + subH - btnH - math.floor(8 * s)
        if utilRight > midX + 125 * s then
            local syncW = math.floor(46 * s)
            utilRight = utilRight - syncW
            if F.drawActionButton(imgui, dl, '##sf_emb_sync', utilRight, btnY, syncW, btnH, 'SYNC', 'cyan', { fontScale = 0.66 * s }) then
                action.sync()
            end
            if state.wsDetail and (state.wsDetail.spent or 0) > 0 and (utilRight - 72 * s) > midX + 110 * s then
                local wsBtnW = math.floor(68 * s)
                utilRight = utilRight - wsBtnW - 4 * s
                if not ui.confirmResetWs then
                    if F.drawActionButton(imgui, dl, '##sf_emb_reset_ws', utilRight, btnY, wsBtnW, btnH, 'RESPEC WS', 'neutral', { fontScale = 0.64 * s }) then
                        ui.confirmResetWs   = true
                        ui.confirmResetWsAt = now
                    end
                elseif (now - (ui.confirmResetWsAt or 0)) > 5.0 then
                    ui.confirmResetWs = false
                else
                    if F.drawActionButton(imgui, dl, '##sf_emb_reset_ws_ok', utilRight, btnY, wsBtnW, btnH, 'CONFIRM', 'danger', { fontScale = 0.64 * s }) then
                        ui.confirmResetWs = false
                        action.resetWS(state.wsDetail.id)
                    end
                end
            end
        end
    else
        -- Focused 720p drawer toggles
        local dBtnW = math.floor(66 * s)
        local btnH  = math.floor(22 * s)
        local btnY  = y + math.floor((subH - btnH) * 0.5)
        local dx    = divX - dBtnW - 8 * s
        if F.drawActionButton(imgui, dl, '##sf_emb_tog_insp', dx, btnY, dBtnW, btnH,
            ui.drawerOpen == 'inspector' and 'DETAILS*' or 'DETAILS',
            ui.drawerOpen == 'inspector' and 'gold' or 'neutral', { fontScale = 0.68 * s }) then
            ui.drawerOpen = (ui.drawerOpen == 'inspector') and nil or 'inspector'
        end
        dx = dx - dBtnW - 4 * s
        if F.drawActionButton(imgui, dl, '##sf_emb_tog_ars', dx, btnY, dBtnW, btnH,
            ui.drawerOpen == 'arsenal' and 'ARSENAL*' or 'ARSENAL',
            ui.drawerOpen == 'arsenal' and 'gold' or 'neutral', { fontScale = 0.68 * s }) then
            ui.drawerOpen = (ui.drawerOpen == 'arsenal') and nil or 'arsenal'
        end
    end

    local contentY = y + subH + gap
    local contentH = math.max(180, h - subH - gap)
    local arsW = L.arsenalW or math.floor(w * 0.22)
    local insW = L.inspectorW or math.floor(w * 0.27)
    local fgW  = math.max(300, w - arsW - insW - gap * 2)

    if not L.drawerMode then
        drawArsenal(state, action, L, x, contentY, arsW, contentH, nav)
        drawSoulforgeCanvas(state, action, L, x + arsW + gap, contentY, fgW, contentH, nav)
        drawInspector(state, action, L, x + arsW + fgW + gap * 2, contentY, insW, contentH, nav)
    else
        local drawer = ui.drawerOpen
        if nav and nav.region == 'arsenal' then
            drawer = 'arsenal'
        elseif nav and (nav.region == 'inspector' or nav.region == 'confirm') then
            drawer = 'inspector'
        end
        if drawer == 'arsenal' then
            drawArsenal(state, action, L, x, contentY, arsW, contentH, nav)
            drawSoulforgeCanvas(state, action, L, x + arsW + gap, contentY, math.max(200, w - arsW - gap), contentH, nav)
        elseif drawer == 'inspector' then
            drawSoulforgeCanvas(state, action, L, x, contentY, math.max(200, w - insW - gap), contentH, nav)
            drawInspector(state, action, L, x + (w - insW), contentY, insW, contentH, nav)
        else
            drawSoulforgeCanvas(state, action, L, x, contentY, w, contentH, nav)
        end
    end
end

function UI.draw(state, action)
    local ui = ensureUiState(state)
    local vw, vh = F.getViewportSize(imgui)
    local L = UI.computeLayout(state, vw, vh)

    -- Recalculate & recenter cleanly when FFXI viewport changes or resetview requested
    local resized = (ui.lastViewportW ~= vw or ui.lastViewportH ~= vh) or (ui.forceCenter == true)
    if resized then
        ui.lastViewportW = vw
        ui.lastViewportH = vh
        ui.forceCenter   = false
        if not L.drawerMode then ui.drawerOpen = nil end
    end

    local winFlags = 0
    local okBit, bit = pcall(require, 'bit')
    local flagList = {
        ImGuiWindowFlags_NoTitleBar or 1,
        ImGuiWindowFlags_NoResize or 2,
        ImGuiWindowFlags_NoScrollbar or 8,
        ImGuiWindowFlags_NoScrollWithMouse or 16,
        ImGuiWindowFlags_NoCollapse or 32,
        ImGuiWindowFlags_NoBackground or 128,
        ImGuiWindowFlags_NoSavedSettings or 256,
    }
    for _, fl in ipairs(flagList) do
        winFlags = (okBit and bit) and bit.bor(winFlags, fl) or (winFlags + fl)
    end

    imgui.SetNextWindowSize({ L.winW, L.winH }, ImGuiCond_Always or 1)
    imgui.SetNextWindowPos({ L.posX, L.posY }, resized and (ImGuiCond_Always or 1) or (ImGuiCond_FirstUseEver or 4))
    if imgui.PushStyleVar then imgui.PushStyleVar(ImGuiStyleVar_WindowPadding or 2, { 0, 0 }) end

    local opened = imgui.Begin('SoulspireXI - The Soulforge###OXTalentsWin', state.open, winFlags)
    if opened then
        local wx, wy = F.toXY(imgui.GetWindowPos())
        local dl = imgui.GetWindowDrawList()

        -- Outer Soulforge chamber frame
        F.drawPanelFrame(dl, wx, wy, L.winW, L.winH, {
            fillTop  = F.u32.midnight_deep,
            fillBot  = F.u32.abyss_solid,
            border   = F.u32.soul_gold,
            accent   = F.u32.soul_gold_bright,
            rounding = 8,
            corners  = true,
            shadow   = true,
        })

        local innerX = wx + L.pad
        local headerY = wy + L.pad
        drawHeader(state, action, L, innerX, headerY, L.innerW, L.headerH)

        local bodyY = headerY + L.headerH + L.gap
        if not L.drawerMode then
            -- Expanded / Balanced: Full 3-panel Soulforge
            drawArsenal(state, action, L, innerX, bodyY, L.arsenalW, L.bodyH)
            drawSoulforgeCanvas(state, action, L, innerX + L.arsenalW + L.gap, bodyY, L.forgeW, L.bodyH)
            drawInspector(state, action, L, innerX + L.arsenalW + L.forgeW + L.gap * 2, bodyY, L.inspectorW, L.bodyH)
        else
            -- Focused mode: Soulforge gets priority; Arsenal / Inspector open as contextual drawers
            if ui.drawerOpen == 'arsenal' then
                drawArsenal(state, action, L, innerX, bodyY, L.arsenalW, L.bodyH)
                drawSoulforgeCanvas(state, action, L, innerX + L.arsenalW + L.gap, bodyY, L.innerW - L.arsenalW - L.gap, L.bodyH)
            elseif ui.drawerOpen == 'inspector' then
                drawSoulforgeCanvas(state, action, L, innerX, bodyY, L.innerW - L.inspectorW - L.gap, L.bodyH)
                drawInspector(state, action, L, innerX + (L.innerW - L.inspectorW), bodyY, L.inspectorW, L.bodyH)
            else
                drawSoulforgeCanvas(state, action, L, innerX, bodyY, L.innerW, L.bodyH)
            end
        end

        local footerY = bodyY + L.bodyH + L.gap
        drawFooter(state, action, L, innerX, footerY, L.innerW, L.footerH)
    end
    imgui.End()
    if imgui.PopStyleVar then imgui.PopStyleVar() end
end

function UI.unload()
    if art and art.clear then
        art.clear()
    end
end

return UI
