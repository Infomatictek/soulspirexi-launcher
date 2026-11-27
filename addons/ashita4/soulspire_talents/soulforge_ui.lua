-- SoulspireXI — The Soulforge (Weapon Skill Talents UI)
-- Approved Soulforge Visual Target Presentation Layer:
--   - Top Ornate "THE SOULFORGE" Banner with crystal skyline art, Soul identity portrait,
--     4 rotated diamond Mastery Slots, and glowing Talent Points star
--   - Left ARSENAL panel with gilded circular weapon-category buttons, large spacious
--     Weapon Skill entries with Mastered/Eligible/Locked hierarchy, and Mastery Overview
--   - Centerpiece Soulforge Sanctum with dramatic crystal broadsword backdrop, circular
--     interconnected orbital node tree representing real reqKey dependencies, compact
--     Skillchain Forging runic strip, and 3 distinct Path Summary cards (Offense/Mastery/Utility)
--   - Right TALENT DETAILS panel with diamond rank pips, Current Effect & gold Next Rank
--     cards, Requirements checklist, Point Cost star, and ornate beveled gold CTA with
--     hold-to-confirm and 2-step deliberate confirmation
--
-- Preserves 100% of server-authoritative OXTL v1/v2 protocols, unlock rules, costs,
-- Skillchain Forging mechanics, gamepad/keyboard focus navigation, and sync honesty.

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

local PATH_META = {
    { key = 'offense', title = 'Offense Path', subtitle = 'Increase damage and amplify potency.' },
    { key = 'mastery', title = 'Mastery Path', subtitle = 'Enhance core potency and skill performance.' },
    { key = 'utility', title = 'Utility Path', subtitle = 'Improve execution, consistency, and synergy.' },
}

local HOLD_CONFIRM_SEC = 0.45

-- ---------------------------------------------------------------------------
-- Pure Helper Logic (exported for unit tests & gamepad controllers)
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

function UI.getNodePathKey(node, isEvo)
    local col = tonumber(node and node.col) or 2
    if isEvo then
        return (col == 1) and 'offense' or 'mastery'
    end
    if col == 1 then return 'offense' end
    if col == 3 then return 'utility' end
    return 'mastery'
end

-- Build a deterministic 2D tier/column grid of navigable talent nodes for gamepad navigation.
function UI.getTreeGrid(detail)
    local tiers = {}
    if not detail or not detail.nodes then return tiers end
    local byTier = {}
    local maxTier = 0
    for _, n in ipairs(detail.nodes) do
        if not UI.isSkillchainNode(n) then
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

UI.getMasterySlots = UI.getSkillchainSlots
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
        state.ui.holdNodeKey    = nil
        state.ui.holdStartAt    = nil
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
    local isAuthoritative = (detail == nil) or (detail.authoritative ~= false)

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
        if not isAuthoritative then
            reason = 'Confirming live character state with server...'
        elseif node.canLearn and availOk then
            reason = nil
        elseif not availOk then
            reason = string.format('Need %d available talent point(s) (have %d).', cost, avail)
        else
            reason = 'Further ranks locked by progression requirements.'
        end
    elseif tierHasOtherChosen then
        stateKey = 'locked'
        reason   = 'Another technique is already chosen in this chapter. Refund it first to switch paths.'
    elseif not isAuthoritative then
        stateKey = 'locked'
        reason   = 'Syncing live state from server before forging...'
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
        stateKey        = stateKey,
        spec            = F.NODE_STATES[stateKey] or F.NODE_STATES.locked,
        rank            = rank,
        maxRank         = maxRank,
        cost            = cost,
        lvlOk           = lvlOk,
        ptsOk           = ptsOk,
        parentOk        = parentOk,
        parentNode      = parentNode,
        availOk         = availOk,
        isAuthoritative = isAuthoritative,
        canUpgrade      = isAuthoritative and (not isPending) and (rank < maxRank) and (not tierHasOtherChosen) and node.canLearn == true,
        canRefund       = isAuthoritative and (not isPending) and (rank > 0),
        reason          = reason,
    }
end

-- Helper to resolve textures cleanly across soulspire_talents, soulspire_core, and crystalsocket.
local function getTex(nav, name, siblingAddon)
    if siblingAddon then
        if nav and nav.assets and nav.assets.load_from_addon then
            local id = nav.assets:load_from_addon(siblingAddon, name)
            if id then return id end
        end
        if art and art.getFromAddon then
            return art.getFromAddon(siblingAddon, name)
        end
        return nil
    end
    if art and art.get then
        local id = art.get(name)
        if id then return id end
    end
    if nav and nav.assets and nav.assets.load_texture then
        local id = nav.assets:load_texture(name)
        if id then return id end
    end
    return nil
end

local function drawAssetOrFallback(dl, nav, assetName, x, y, w, h, tint)
    local id = getTex(nav, assetName)
    if id and dl and dl.AddImage then
        dl:AddImage(id, { x, y }, { x + w, y + h }, { 0, 0 }, { 1, 1 }, tint or 0xFFFFFFFF)
        return true
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

-- Helper: crisp vector crown icon for "Mastered" Arsenal rows
local function drawCrownGlyph(dl, cx, cy, r, colU32)
    if not dl or not dl.AddQuadFilled then return end
    local w = r * 1.15
    local h = r * 0.72
    dl:AddQuadFilled({ cx - w, cy + h }, { cx + w, cy + h }, { cx + w * 0.85, cy - h * 0.1 }, { cx - w * 0.85, cy - h * 0.1 }, colU32)
    if dl.AddTriangleFilled then
        dl:AddTriangleFilled({ cx - w * 0.90, cy + h * 0.1 }, { cx - w * 0.45, cy - h }, { cx - w * 0.15, cy + h * 0.1 }, colU32)
        dl:AddTriangleFilled({ cx - w * 0.30, cy + h * 0.1 }, { cx, cy - h * 1.15 }, { cx + w * 0.30, cy + h * 0.1 }, colU32)
        dl:AddTriangleFilled({ cx + w * 0.15, cy + h * 0.1 }, { cx + w * 0.45, cy - h }, { cx + w * 0.90, cy + h * 0.1 }, colU32)
    end
end

-- Helper: crisp vector checkmark / diamond icon for Requirements rows
local function drawReqIcon(dl, cx, cy, r, ok)
    if not dl then return end
    if ok and dl.AddLine then
        dl:AddLine({ cx - r * 0.7, cy + r * 0.05 }, { cx - r * 0.15, cy + r * 0.65 }, F.u32.success, 2.2)
        dl:AddLine({ cx - r * 0.15, cy + r * 0.65 }, { cx + r * 0.85, cy - r * 0.55 }, F.u32.success, 2.2)
    elseif dl.AddQuad then
        dl:AddQuad({ cx, cy - r * 0.7 }, { cx + r * 0.7, cy }, { cx, cy + r * 0.7 }, { cx - r * 0.7, cy }, F.u32.text_muted, 1.4)
    end
end

-- Helper: diamond rank pips (approved Soulforge Talent Details aesthetic)
local function drawDiamondPips(dl, x, cy, filled, total, s)
    if not dl or not dl.AddQuadFilled then return end
    local r = math.floor(6.5 * s)
    local pitch = math.floor(17 * s)
    local count = math.max(1, math.min(total or 1, 5))
    for i = 1, count do
        local cx = x + (i - 1) * pitch + r
        local isLit = i <= (filled or 0)
        if isLit then
            if dl.AddCircleFilled then
                dl:AddCircleFilled({ cx, cy }, r * 1.35, F.abgr(F.rgba.soul_gold, 0.25), 12)
            end
            dl:AddQuadFilled({ cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy }, F.u32.soul_gold_bright)
            if dl.AddQuad then
                dl:AddQuad({ cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy }, F.u32.white, 1.0)
            end
        else
            dl:AddQuadFilled({ cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy }, F.u32.abyss_solid)
            if dl.AddQuad then
                dl:AddQuad({ cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy }, F.u32.border_strong, 1.2)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- 1. Ornate "THE SOULFORGE" Banner (Shared between Embedded Core & Standalone)
-- ---------------------------------------------------------------------------
local function drawSoulforgeBanner(state, action, L, x, y, w, h, nav, standalone)
    local dl = imgui.GetWindowDrawList()
    local s  = L.uiScale or 1.0
    local ui = ensureUiState(state)

    local bannerTex = getTex(nav, 'soulforge_banner_bg') or getTex(nav, 'header_ornament')
    F.drawOrnatePanel(dl, x, y, w, h, {
        texId      = bannerTex,
        texTint    = F.abgr(F.rgba.white, 0.88),
        scrimAlpha = 0.28,
        fillTop    = F.abgr(F.hex('#141A32', 0.95)),
        fillBot    = F.abgr(F.hex('#090D1C', 0.98)),
        border     = F.u32.soul_gold,
        accent     = F.u32.soul_gold_bright,
        rounding   = 6,
        corners    = true,
        shadow     = false,
    })

    local avail = tonumber(state.avail) or 0
    local investedList = UI.getInvestedWeaponskills(state)

    -- Left: Framed Soul Portrait Medallion + Job / Soul / Role identity
    local medR = math.floor(math.min(30 * s, (h - 14) * 0.5))
    local medX = x + 18 * s + medR
    local medY = y + h * 0.5
    local soulIconName = nil
    if state.specKey and state.specKey ~= '' and state.specKey ~= 'base' then
        soulIconName = tostring(state.specKey)
    end
    local soulTex = soulIconName and getTex(nav, soulIconName, 'crystalsocket') or nil
    F.drawCrystalMedallion(dl, medX, medY, medR, {
        texId = soulTex,
        rim   = F.u32.soul_gold_bright,
        core  = F.rgba.crystal_violet,
        studs = true,
    })

    -- Ornamental antique-gold diamond clasp beside portrait
    if dl and dl.AddQuad and L.mode ~= 'focused' then
        local clX = medX + medR + 12 * s
        dl:AddLine({ clX, y + 14 * s }, { clX, y + h - 14 * s }, F.abgr(F.rgba.soul_gold, 0.55), 1.3)
        dl:AddQuadFilled({ clX, medY - 7 * s }, { clX + 6 * s, medY }, { clX, medY + 7 * s }, { clX - 6 * s, medY }, F.u32.midnight_deep)
        dl:AddQuad({ clX, medY - 7 * s }, { clX + 6 * s, medY }, { clX, medY + 7 * s }, { clX - 6 * s, medY }, F.u32.soul_gold_bright, 1.4)
    end

    local idX = medX + medR + (L.mode == 'focused' and 12 * s or 26 * s)
    local actualLvl = math.max(1, tonumber(state.jobLevel) or (nav and nav.identity and tonumber(nav.identity.actual_level)) or 1)
    local effLvl = math.max(1, tonumber(state.effectiveLevel) or (nav and nav.identity and tonumber(nav.identity.effective_level)) or actualLvl)
    local isSynced = (state.isLevelSynced == true) or (nav and nav.identity and nav.identity.is_level_synced == true) or (effLvl < actualLvl)
    local jobKey = (state.jobKey and state.jobKey ~= '---') and state.jobKey or ((nav and nav.identity and nav.identity.job_key) or '---')
    local jobLabel = isSynced
        and string.format('%s  Lv.%d (Sync %d)', jobKey, effLvl, actualLvl)
        or string.format('%s  Lv.%d', jobKey, actualLvl)
    F.drawShadowText(imgui, dl, idX, y + (L.mode == 'focused' and 10 or 12) * s,
        F.fitText(imgui, jobLabel, math.floor(w * 0.27), (L.mode == 'focused' and 1.02 or 1.24) * s),
        isSynced and F.u32.aether_cyan or F.u32.white, (L.mode == 'focused' and 1.02 or 1.24) * s, 'l')

    local specDisplay = tostring(state.specName or (nav and nav.identity and nav.identity.soul_name) or 'Base')
    local soulRowY = y + (L.mode == 'focused' and 34 or 42) * s
    if dl and dl.AddCircleFilled then
        dl:AddCircleFilled({ idX + 7 * s, soulRowY + 8 * s }, 6 * s, F.u32.crystal_violet_bright, 12)
        dl:AddCircleFilled({ idX + 7 * s, soulRowY + 8 * s }, 2.6 * s, F.u32.white, 8)
    end
    F.drawShadowText(imgui, dl, idX + 18 * s, soulRowY,
        F.fitText(imgui, 'Soul: ' .. specDisplay, math.floor(w * 0.24), 0.94 * s),
        F.u32.crystal_violet_bright, 0.94 * s, 'l')

    if L.mode ~= 'focused' and h >= 82 * s then
        local subKey = state.subJobKey or (nav and nav.identity and nav.identity.sub_job_key)
        local subLvl = tonumber(state.subLevel) or (nav and nav.identity and tonumber(nav.identity.sub_level)) or 0
        local roleStr = state.soulRole or (nav and nav.identity and nav.identity.soul_role)
        local roleHint
        if subKey and subKey ~= '' and roleStr and roleStr ~= '' then
            roleHint = string.format('%s  |  Sub: %s Lv.%d', roleStr, subKey, subLvl)
        elseif subKey and subKey ~= '' then
            roleHint = string.format('Subjob: %s Lv.%d  |  Authoritative Progression', subKey, subLvl)
        elseif roleStr and roleStr ~= '' then
            roleHint = string.format('%s  |  Authoritative Progression', roleStr)
        else
            roleHint = 'Weapon Skill Mastery & Progression'
        end
        F.drawShadowText(imgui, dl, idX, y + 66 * s,
            F.fitText(imgui, roleHint, math.floor(w * 0.26), 0.78 * s),
            F.u32.text_secondary, 0.78 * s, 'l')
    end

    -- Center: Prominent "THE SOULFORGE / — WEAPON SKILL TALENTS —"
    local midX = x + w * 0.5
    if L.mode ~= 'focused' then
        F.drawShadowText(imgui, dl, midX, y + 14 * s, 'THE SOULFORGE', F.u32.soul_gold_bright, 1.56 * s, 'c')
        local subY = y + 54 * s
        F.drawShadowText(imgui, dl, midX, subY, 'WEAPON SKILL TALENTS', F.u32.soul_gold, 0.84 * s, 'c')
        if dl and dl.AddLine then
            dl:AddLine({ midX - 134 * s, subY + 7 * s }, { midX - 92 * s, subY + 7 * s }, F.u32.soul_gold_dim, 1.2)
            dl:AddLine({ midX + 92 * s, subY + 7 * s }, { midX + 134 * s, subY + 7 * s }, F.u32.soul_gold_dim, 1.2)
        end
    else
        F.drawShadowText(imgui, dl, midX, y + 16 * s, 'THE SOULFORGE', F.u32.soul_gold_bright, 1.14 * s, 'c')
    end

    -- Far Right: Cleanly separated Talent Points block + Mastery Slots (X / 4) diamond sockets
    local rx = x + w - 16 * s
    if standalone then
        local closeW = math.floor(58 * s)
        local btnH = math.floor(26 * s)
        local btnY = y + math.floor((h - btnH) * 0.5)
        rx = rx - closeW
        if F.drawActionButton(imgui, dl, '##sf_close', rx, btnY, closeW, btnH, 'CLOSE', 'neutral', { fontScale = 0.80 * s }) then
            UI.resetTransientState(state)
            state.open[1] = false
        end
        rx = rx - 10 * s
    end

    local tpBlockW = math.floor(114 * s)
    local tpX = rx - tpBlockW
    F.drawShadowText(imgui, dl, tpX + tpBlockW * 0.5, y + 10 * s, 'Talent Points', F.u32.soul_gold_bright, 0.88 * s, 'c')
    local starCy = y + h * 0.62
    if F.drawCrystalStar then
        F.drawCrystalStar(dl, tpX + 28 * s, starCy, 15 * s, F.u32.crystal_violet_bright, F.u32.white)
    end
    F.drawShadowText(imgui, dl, tpX + 54 * s, starCy - 16 * s, tostring(avail),
        avail > 0 and F.u32.white or F.u32.text_muted, 1.66 * s, 'l')

    -- Vertical gilded divider between Talent Points and Mastery Slots
    local divX = tpX - 12 * s
    if dl and dl.AddLine then
        dl:AddLine({ divX, y + 12 * s }, { divX, y + h - 12 * s }, F.abgr(F.rgba.soul_gold_dim, 0.68), 1.2)
    end

    if L.mode ~= 'focused' then
        local msW = math.floor(216 * s)
        local msX = divX - msW - 14 * s
        F.drawShadowText(imgui, dl, msX + msW * 0.5, y + 10 * s,
            string.format('Mastery Slots (%d / %d)', #investedList, UI.MAX_SPEC_WS_SLOTS),
            F.u32.text_primary, 0.88 * s, 'c')
        local dr = math.floor(18 * s)
        local dPitch = math.floor(48 * s)
        local dStartX = msX + math.floor((msW - dPitch * 3) * 0.5)
        local dY = y + math.floor(h * 0.62)
        for i = 1, UI.MAX_SPEC_WS_SLOTS do
            local item = investedList[i]
            local dCx = dStartX + (i - 1) * dPitch
            local tex = item and getTex(nav, 'ws_' .. tostring(item.id)) or nil
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
    else
        -- Focused 720p drawer toggles
        local dBtnW = math.floor(72 * s)
        local btnH  = math.floor(24 * s)
        local btnY  = y + math.floor((h - btnH) * 0.5)
        local dx    = divX - dBtnW - 8 * s
        if F.drawActionButton(imgui, dl, '##sf_emb_tog_insp', dx, btnY, dBtnW, btnH,
            ui.drawerOpen == 'inspector' and 'DETAILS*' or 'DETAILS',
            ui.drawerOpen == 'inspector' and 'gold' or 'neutral', { fontScale = 0.74 * s }) then
            ui.drawerOpen = (ui.drawerOpen == 'inspector') and nil or 'inspector'
        end
        dx = dx - dBtnW - 4 * s
        if F.drawActionButton(imgui, dl, '##sf_emb_tog_ars', dx, btnY, dBtnW, btnH,
            ui.drawerOpen == 'arsenal' and 'ARSENAL*' or 'ARSENAL',
            ui.drawerOpen == 'arsenal' and 'gold' or 'neutral', { fontScale = 0.74 * s }) then
            ui.drawerOpen = (ui.drawerOpen == 'arsenal') and nil or 'arsenal'
        end
    end
end

-- ---------------------------------------------------------------------------
-- 2. Left Rail: Ornate ARSENAL Panel (Circular Weapon Bar + Spacious WS List)
-- ---------------------------------------------------------------------------
local function drawArsenal(state, action, L, x, y, w, h, nav)
    local dl = imgui.GetWindowDrawList()
    local s  = L.uiScale or 1.0
    local ui = ensureUiState(state)
    local regionFocused = (nav ~= nil and nav.region == 'arsenal')
    local filterFocused = regionFocused and (nav.arsenal_focus == 'filter')

    local panelTex = getTex(nav, 'panel_browser')
    F.drawOrnatePanel(dl, x, y, w, h, {
        texId      = panelTex,
        texTint    = F.abgr(F.rgba.white, 0.26),
        scrimAlpha = 0.72,
        border     = regionFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent     = regionFocused and F.u32.aether_cyan or F.u32.soul_gold,
        thickness  = regionFocused and 1.8 or 1.3,
        corners    = true,
        shadow     = false,
    })

    local pad = math.floor(14 * s)
    local rows = action.filtered()
    local status = resolveArsenalStatus(state, action, rows)

    F.drawShadowText(imgui, dl, x + pad, y + 12 * s,
        regionFocused and '> ARSENAL' or 'ARSENAL',
        regionFocused and F.u32.aether_cyan or F.u32.soul_gold_bright, 1.12 * s, 'l')
    local countText = (status.kind == 'loading') and 'SYNCING...' or string.format('%d WS', #rows)
    F.drawShadowText(imgui, dl, x + w - pad, y + 15 * s, countText,
        (status.kind == 'loading') and F.u32.aether_cyan or F.u32.text_secondary, 0.84 * s, 'r')

    F.drawShadowText(imgui, dl, x + pad, y + 36 * s,
        F.fitText(imgui, 'Select a weapon and Weapon Skill to refine.', w - pad * 2, 0.78 * s),
        F.u32.text_secondary, 0.78 * s, 'l')

    -- Gilded Circular Weapon-Category Icon Selector Bar (matching approved Soulforge mockup)
    local ctrlW = w - pad * 2
    local barY = y + 58 * s
    local iconR = math.floor(math.min(18 * s, (ctrlW - 56 * s) / 11.5))
    local barH = iconR * 2 + 4
    if filterFocused and dl and dl.AddRect then
        dl:AddRect({ x + pad - 3, barY - 3 }, { x + pad + ctrlW + 3, barY + barH + 3 }, F.u32.aether_cyan, 6, 0, 1.8)
    end

    local arrW = math.floor(20 * s)
    local arrH = math.floor(iconR * 1.5)
    local arrY = barY + math.floor((barH - arrH) * 0.5)
    if F.drawActionButton(imgui, dl, '##sf_filter_prev', x + pad, arrY, arrW, arrH, '<',
        filterFocused and 'cyan' or 'neutral', { fontScale = 0.82 * s }) then
        if action.cycleSkillFilter then action.cycleSkillFilter(-1) end
        if nav and nav.on_focus then nav.on_focus('arsenal', 1) end
    end
    if F.drawActionButton(imgui, dl, '##sf_filter_next', x + w - pad - arrW, arrY, arrW, arrH, '>',
        filterFocused and 'cyan' or 'neutral', { fontScale = 0.82 * s }) then
        if action.cycleSkillFilter then action.cycleSkillFilter(1) end
        if nav and nav.on_focus then nav.on_focus('arsenal', 1) end
    end

    -- Build 5 visible weapon-category circles centered around the active filter
    local allSkills = (action.getAvailableSkills and action.getAvailableSkills()) or action.skills or { { id = -1, name = 'Equipped' }, { id = 0, name = 'All' } }
    local activeSkillIdx = 1
    local activeSkillName = 'Equipped'
    for idx, sk in ipairs(allSkills) do
        if sk.id == state.selectedSkill then
            activeSkillIdx = idx
            activeSkillName = sk.name
            break
        end
    end
    if state.selectedSkill == -1 then
        local eqSum = action.getEquippedSummary and action.getEquippedSummary() or nil
        if eqSum then
            activeSkillName = 'Equipped (' .. eqSum .. ')'
        elseif state.synced then
            activeSkillName = 'Equipped (None)'
        end
    end

    local visCount = math.min(5, #allSkills)
    local startIdx = math.max(1, math.min(activeSkillIdx - 2, #allSkills - visCount + 1))
    local iconsAreaX = x + pad + arrW + 6 * s
    local iconsAreaW = math.max(80, ctrlW - (arrW + 6 * s) * 2)
    local pitch = iconsAreaW / math.max(1, visCount)
    local iconCy = barY + barH * 0.5

    for i = 0, visCount - 1 do
        local sk = allSkills[startIdx + i]
        if sk then
            local icx = iconsAreaX + pitch * (i + 0.5)
            local isSel = (sk.id == state.selectedSkill)
            imgui.SetCursorScreenPos({ icx - iconR, iconCy - iconR })
            if imgui.InvisibleButton('##sf_sk_ic_' .. tostring(sk.id), { iconR * 2, iconR * 2 }) then
                state.selectedSkill = sk.id
                if nav and nav.on_focus then nav.on_focus('arsenal', 1) end
            end
            local hov = imgui.IsItemHovered and imgui.IsItemHovered() or false

            if dl and dl.AddCircleFilled then
                if isSel then
                    dl:AddCircleFilled({ icx, iconCy }, iconR + 4, F.abgr(F.rgba.soul_gold, 0.24), 24)
                end
                dl:AddCircleFilled({ icx, iconCy }, iconR,
                    isSel and F.abgr(F.hex('#4B3718', 0.96)) or (hov and F.u32.midnight_alt or F.u32.abyss_solid), 24)
                dl:AddCircle({ icx, iconCy }, iconR,
                    isSel and F.u32.soul_gold_bright or (hov and F.u32.soul_gold or F.u32.border_strong),
                    24, isSel and 2.0 or 1.2)
            end
            F.drawWeaponIcon(dl, sk.id, icx, iconCy, iconR * 0.62,
                isSel and F.u32.soul_gold_bright or F.u32.text_secondary,
                isSel and F.u32.white or F.u32.soul_gold_dim)
        end
    end

    -- Section title: WEAPON SKILLS — <ACTIVE FAMILY> + compact filter pill
    local secY = barY + barH + math.floor(12 * s)
    F.drawDivider(dl, x + pad, secY - 4 * s, ctrlW, F.u32.soul_gold_dim)
    F.drawShadowText(imgui, dl, x + pad, secY + 2 * s,
        F.fitText(imgui, 'WEAPON SKILLS - ' .. string.upper(activeSkillName), ctrlW - 64 * s, 0.80 * s),
        F.u32.soul_gold, 0.80 * s, 'l')

    -- Compact Invested-Only toggle pill right-aligned on the section header
    local invActive = state.investedOnly and state.investedOnly[1] == true
    local invW = math.floor(72 * s)
    if F.drawActionButton(imgui, dl, '##sf_inv_tog', x + w - pad - invW, secY, invW, math.floor(18 * s),
        invActive and 'INVEST*' or 'ALL WS', invActive and 'gold' or 'neutral', { fontScale = 0.66 * s }) then
        if state.investedOnly then
            state.investedOnly[1] = not invActive
        end
    end

    local listTop = secY + math.floor(26 * s)
    local overviewH = (L.mode ~= 'focused' and h >= 410 * s) and math.floor(104 * s) or 0
    local listH = math.max(90, (y + h) - listTop - pad - (overviewH > 0 and (overviewH + math.floor(10 * s)) or 0))
    imgui.SetCursorScreenPos({ x + pad, listTop })

    if imgui.BeginChild('##sf_arsenal_list', { ctrlW, listH }, ImGuiChildFlags_None or 0) then
        local cdl = imgui.GetWindowDrawList()
        local rowH = math.floor(58 * s)
        local rowW = math.max(120, ctrlW - 10 * s)

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

            local rh = rowH - 5
            if selected or padFocused then
                if cdl.AddRectFilledMultiColor then
                    cdl:AddRectFilledMultiColor({ rx, ry }, { rx + rowW, ry + rh },
                        F.abgr(F.hex('#493618', 0.94)), F.abgr(F.hex('#2A1F0F', 0.94)),
                        F.abgr(F.hex('#261C0E', 0.96)), F.abgr(F.hex('#3C2C14', 0.96)))
                else
                    cdl:AddRectFilled({ rx, ry }, { rx + rowW, ry + rh }, F.abgr(F.hex('#3B2C15', 0.95)), 5)
                end
            else
                cdl:AddRectFilled({ rx, ry }, { rx + rowW, ry + rh },
                    hovered and F.u32.midnight_alt or F.abgr(F.hex('#0D1322', 0.88)), 5)
            end

            local border = padFocused and F.u32.aether_cyan
                or (selected and F.u32.soul_gold_bright
                or (mastered and F.u32.soul_gold_dim
                or (unlocked and F.u32.border_strong
                or (hovered and F.u32.soul_gold_dim or F.u32.border_subtle))))
            cdl:AddRect({ rx, ry }, { rx + rowW, ry + rh }, border, 5, 0, (selected or padFocused) and 1.9 or 1.0)

            -- Selected left gold diamond pointer (matching Savage Blade in approved mockup)
            if (selected or padFocused) and cdl.AddQuadFilled then
                local d = 4.5 * s
                local pCol = padFocused and F.u32.aether_cyan or F.u32.soul_gold_bright
                cdl:AddQuadFilled({ rx + 2, ry + rh * 0.5 - d }, { rx + 2 + d, ry + rh * 0.5 },
                    { rx + 2, ry + rh * 0.5 + d }, { rx + 2 - d, ry + rh * 0.5 }, pCol)
            end

            -- Framed WS icon (40px scaled)
            local icSz = math.floor(40 * s)
            local ix, iy = rx + 10 * s, ry + math.floor((rh - icSz) * 0.5)
            cdl:AddRectFilled({ ix, iy }, { ix + icSz, iy + icSz }, F.u32.abyss_solid, 4)
            if not drawAssetOrFallback(cdl, nav, 'ws_' .. ws.id, ix + 1, iy + 1, icSz - 2, icSz - 2) then
                F.drawNodeMedallion(cdl, ix + icSz * 0.5, iy + icSz * 0.5, icSz * 0.44, {
                    stateKey = mastered and 'maxed' or (unlocked and 'learned' or 'available'),
                    pathKey  = (ws.wsType == 'magical') and 'mastery' or 'offense',
                    showIconWhenLocked = true,
                })
            end
            cdl:AddRect({ ix, iy }, { ix + icSz, iy + icSz }, selected and F.u32.soul_gold_bright or border, 4, 0, 1.2)

            -- WS Name + clear right-aligned state label (Mastered / Eligible / Locked)
            local tx = ix + icSz + 10 * s
            local rightBadgeW = math.floor(86 * s)
            local nameMaxW = math.max(40, rowW - (tx - rx) - rightBadgeW - 8 * s)
            F.drawShadowText(imgui, cdl, tx, ry + math.floor(rh * 0.5 - 9 * s),
                F.fitText(imgui, ws.name, nameMaxW, 0.96 * s),
                selected and F.u32.white or (unlocked and F.u32.text_primary or F.u32.text_secondary),
                0.96 * s, 'l')

            local stRightX = rx + rowW - 10 * s
            local stCy = ry + rh * 0.5
            if mastered then
                local lbl = 'Mastered'
                local lblW = F.measureText(imgui, lbl, 0.82 * s)
                F.drawShadowText(imgui, cdl, stRightX, stCy - 7 * s, lbl, F.u32.soul_gold_bright, 0.82 * s, 'r')
                drawCrownGlyph(cdl, stRightX - lblW - 10 * s, stCy, 5.5 * s, F.u32.soul_gold_bright)
            elseif unlocked then
                local lbl = pts > 0 and string.format('%d pts', pts) or 'Mastered'
                local lblW = F.measureText(imgui, lbl, 0.82 * s)
                F.drawShadowText(imgui, cdl, stRightX, stCy - 7 * s, lbl, F.u32.soul_gold, 0.82 * s, 'r')
                drawCrownGlyph(cdl, stRightX - lblW - 10 * s, stCy, 5.2 * s, F.u32.soul_gold)
            elseif state.synced then
                F.drawShadowText(imgui, cdl, stRightX, stCy - 7 * s, 'Eligible', F.u32.text_secondary, 0.82 * s, 'r')
            else
                F.drawShadowText(imgui, cdl, stRightX, stCy - 7 * s, 'Locked', F.u32.text_muted, 0.80 * s, 'r')
            end
        end

        if #rows == 0 then
            local ex, ey = F.toXY(imgui.GetCursorScreenPos())
            local cardW  = math.max(120, ctrlW - 6 * s)
            local isLoading = (status.kind == 'loading')
            local accentCol = isLoading and F.u32.aether_cyan or F.u32.soul_gold_dim
            local titleCol  = isLoading and F.u32.aether_cyan or F.u32.soul_gold_bright
            local fillCol   = isLoading and F.u32.midnight_selected or F.u32.midnight_deep
            local chars     = math.max(18, math.floor((cardW - 20 * s) / (7.2 * s)))
            local bodyLines = F.wrapLines(status.body or 'No eligible weapon skills.', chars, 6)
            local btnH      = math.floor(28 * s)
            local hintH     = (nav ~= nil) and math.floor(20 * s) or 0
            local cardH     = math.floor(46 * s + #bodyLines * 17 * s + (status.action and (btnH + 16 * s) or 8 * s) + hintH)

            if cdl and cdl.AddRectFilled then
                cdl:AddRectFilled({ ex, ey + 2 }, { ex + cardW, ey + 2 + cardH }, fillCol, 5)
                cdl:AddRect({ ex, ey + 2 }, { ex + cardW, ey + 2 + cardH }, accentCol, 5, 0, isLoading and 1.6 or 1.2)
            end

            local dots = isLoading and string.rep('.', (math.floor((os.clock() or 0) * 2) % 3) + 1) or ''
            local badge = isLoading and ('[~] ' .. tostring(status.title or 'SYNCING ARSENAL') .. dots)
                or ('[!] ' .. tostring(status.title or 'NO ELIGIBLE SKILLS'))
            F.drawShadowText(imgui, cdl, ex + 10 * s, ey + 10 * s,
                F.fitText(imgui, badge, cardW - 20 * s, 0.86 * s), titleCol, 0.86 * s, 'l')

            local ty = ey + 34 * s
            for _, ln in ipairs(bodyLines) do
                F.drawShadowText(imgui, cdl, ex + 10 * s, ty, ln, F.u32.text_secondary, 0.80 * s, 'l')
                ty = ty + math.floor(17 * s)
            end

            if status.action and status.actionLabel then
                ty = ty + math.floor(8 * s)
                local bW = math.max(96, cardW - 20 * s)
                if F.drawBeveledCtaButton(imgui, cdl, '##sf_ars_empty_act', ex + 10 * s, ty, bW, btnH,
                    status.actionLabel, isLoading and 'cyan' or 'gold', { fontScale = 0.78 * s }) then
                    triggerArsenalRecovery(state, action, status, nav)
                end
                ty = ty + btnH + math.floor(6 * s)
            end

            if nav ~= nil then
                local cue = isLoading and '[A] Retry Sync' or '[Left/Right] Filter  |  [A] ' .. tostring(status.actionLabel or 'Switch')
                F.drawShadowText(imgui, cdl, ex + 10 * s, ty,
                    F.fitText(imgui, cue, cardW - 20 * s, 0.74 * s), F.u32.aether_cyan, 0.74 * s, 'l')
            end
            if imgui.Dummy then
                imgui.Dummy({ cardW, cardH + 6 })
            end
        end
    end
    imgui.EndChild()

    -- Bottom MASTERY OVERVIEW card with 4 rotated diamond sockets
    if overviewH > 0 then
        local oy = y + h - pad - overviewH
        local ow = w - pad * 2
        local investedList = UI.getInvestedWeaponskills(state)
        F.drawOrnatePanel(dl, x + pad, oy, ow, overviewH, {
            fillTop   = F.abgr(F.hex('#12182B', 0.94)),
            fillBot   = F.abgr(F.hex('#080C16', 0.98)),
            border    = F.u32.soul_gold_dim,
            accent    = F.u32.soul_gold,
            rounding  = 5,
            corners   = false,
            shadow    = false,
        })
        F.drawShadowText(imgui, dl, x + pad + 12 * s, oy + 8 * s,
            'MASTERY OVERVIEW', F.u32.soul_gold_bright, 0.82 * s, 'l')
        F.drawShadowText(imgui, dl, x + pad + ow - 12 * s, oy + 8 * s,
            string.format('Mastered: %d / %d', #investedList, UI.MAX_SPEC_WS_SLOTS),
            F.u32.text_secondary, 0.78 * s, 'r')

        local dr = math.floor(17 * s)
        local pitch = math.floor((ow - 24 * s) / UI.MAX_SPEC_WS_SLOTS)
        local startCx = x + pad + 12 * s + pitch * 0.5
        local dCy = oy + math.floor(64 * s)
        for i = 1, UI.MAX_SPEC_WS_SLOTS do
            local item = investedList[i]
            local dCx = startCx + (i - 1) * pitch
            local tex = item and getTex(nav, 'ws_' .. tostring(item.id)) or nil
            F.drawDiamondSocket(dl, dCx, dCy, dr, {
                lit     = (item ~= nil),
                active  = (item ~= nil and state.selectedWsId == item.id),
                texId   = tex,
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
-- 3. Centerpiece: The Soulforge Sanctum & Circular Interconnected Node Tree
-- ---------------------------------------------------------------------------
-- Compute circular orbital node positions representing real columns (paths) & tiers
-- while framing the dramatic central crystal broadsword unobstructed.
local function computeOrbitalPositions(grid, isEvo, cx, cy, R)
    local pos = {}
    local numTiers = #grid
    if numTiers == 0 then return pos end

    -- Standard 3-path x 4-tier Soulforge Constellation (exact match to approved 12-node mockup)
    local STD_COORDS = {
        -- col 1: Offense Path (Left Crimson/Gold Arc)
        [1] = {
            [1] = { -0.62, -0.70 },
            [2] = { -0.96, -0.22 },
            [3] = { -0.80,  0.34 },
            [4] = { -0.54,  0.76 },
        },
        -- col 2: Mastery Path (Center Crown -> Inner Flanks -> Bottom Altar Keystone)
        [2] = {
            [1] = {  0.00, -0.94 },
            [2] = { -0.40, -0.20 },
            [3] = {  0.40,  0.20 },
            [4] = {  0.00,  0.86 },
        },
        -- col 3: Utility Path (Right Aether Cyan Arc)
        [3] = {
            [1] = {  0.62, -0.70 },
            [2] = {  0.96, -0.22 },
            [3] = {  0.80,  0.34 },
            [4] = {  0.54,  0.76 },
        },
    }

    -- 2-column x 5-stage Evolution Constellation flanking the central Soulforge blade
    local EVO_COORDS = {
        [1] = {
            [1] = { -0.52, -0.84 },
            [2] = { -0.86, -0.44 },
            [3] = { -0.96,  0.04 },
            [4] = { -0.82,  0.52 },
            [5] = { -0.44,  0.86 },
        },
        [2] = {
            [1] = {  0.52, -0.84 },
            [2] = {  0.86, -0.44 },
            [3] = {  0.96,  0.04 },
            [4] = {  0.82,  0.52 },
            [5] = {  0.44,  0.86 },
        },
    }

    for ti, row in ipairs(grid) do
        local tier = row.tier or ti
        local arr = row.nodes or {}
        for ci, n in ipairs(arr) do
            local col = tonumber(n.col) or ci
            local ox, oy
            if isEvo and EVO_COORDS[col] and EVO_COORDS[col][tier] then
                ox, oy = EVO_COORDS[col][tier][1], EVO_COORDS[col][tier][2]
            elseif (not isEvo) and STD_COORDS[col] and STD_COORDS[col][tier] then
                ox, oy = STD_COORDS[col][tier][1], STD_COORDS[col][tier][2]
            else
                -- Graceful orbital fallback for arbitrary grid sizes (e.g., unit tests)
                local fracY = (numTiers > 1) and ((ti - 1) / (numTiers - 1) * 1.48 - 0.74) or 0
                local span = math.max(1, #arr)
                local fracX = (span > 1) and (((ci - 1) / (span - 1) - 0.5) * 1.50) or 0
                ox, oy = fracX, fracY
            end
            pos[n.key] = {
                node    = n,
                cx      = cx + ox * R,
                cy      = cy + oy * R,
                tier    = tier,
                col     = col,
                pathKey = UI.getNodePathKey(n, isEvo),
                keystone = (tier == 4 and col == 2) or (tier == 1 and col == 2) or (isEvo and tier == 5),
            }
        end
    end
    return pos
end

local function drawSoulforgeCanvas(state, action, L, x, y, w, h, nav)
    local dl  = imgui.GetWindowDrawList()
    local s   = L.uiScale or 1.0
    local ui  = ensureUiState(state)
    local d   = state.wsDetail
    local pad = math.floor(12 * s)
    local now = os.clock()
    local treeFocused = (nav ~= nil and nav.region == 'tree')
    local scFocused   = (nav ~= nil and nav.region == 'skillchains')

    -- Dramatic Soulforge Stone Sanctum & Crystal Broadsword Centerpiece Backdrop
    local chamberTex = getTex(nav, 'soulforge_chamber_center') or getTex(nav, 'background_main')
    F.drawOrnatePanel(dl, x, y, w, h, {
        texId      = chamberTex,
        texTint    = F.abgr(F.rgba.white, d and 0.92 or 0.55),
        scrimAlpha = d and 0.22 or 0.58,
        fillTop    = F.abgr(F.hex('#10152A', 0.94)),
        fillBot    = F.abgr(F.hex('#060914', 0.98)),
        border     = (treeFocused or scFocused) and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent     = (treeFocused or scFocused) and F.u32.aether_cyan or F.u32.soul_gold,
        thickness  = (treeFocused or scFocused) and 1.8 or 1.2,
        corners    = false,
        shadow     = false,
    })

    if not d then
        local rows   = action.filtered()
        local status = resolveArsenalStatus(state, action, rows)
        local cx, cy = x + w * 0.5, y + h * 0.44

        if status.kind == 'loading' then
            F.drawCrystalMedallion(dl, cx, cy - 42 * s, 38 * s, {
                rim  = F.u32.aether_cyan,
                core = F.rgba.aether_cyan,
            })
            local dots = string.rep('.', (math.floor((now or 0) * 2) % 3) + 1)
            F.drawShadowText(imgui, dl, cx, cy + 12 * s, 'SYNCING SOULFORGE DATA' .. dots, F.u32.aether_cyan, 1.12 * s, 'c')
            F.drawShadowText(imgui, dl, cx, cy + 40 * s, 'Retrieving server-authoritative weapon skills and talent progression.', F.u32.text_secondary, 0.88 * s, 'c')
            local bW, bH = math.floor(156 * s), math.floor(32 * s)
            if F.drawBeveledCtaButton(imgui, dl, '##sf_canvas_sync', cx - bW * 0.5, cy + 74 * s, bW, bH, 'RETRY SYNC', 'cyan', { fontScale = 0.84 * s }) then
                triggerArsenalRecovery(state, action, status, nav)
            end
        elseif state.selectedWsId ~= nil then
            local wsEntry = state.catalogById and state.catalogById[state.selectedWsId]
            local wsLabel = wsEntry and wsEntry.name or ('Weapon Skill #' .. tostring(state.selectedWsId))
            if state.wsError then
                F.drawCrystalMedallion(dl, cx, cy - 42 * s, 38 * s, {
                    rim  = F.u32.soul_gold_dim,
                    core = F.rgba.midnight_alt,
                })
                F.drawShadowText(imgui, dl, cx, cy + 12 * s, 'SYNC FAILED: ' .. string.upper(wsLabel), F.u32.soul_gold_bright, 1.08 * s, 'c')
                local maxChars = math.max(30, math.floor((w - 80 * s) / (8.0 * s)))
                local ly = cy + 40 * s
                for _, ln in ipairs(F.wrapLines(tostring(state.wsError), maxChars, 3)) do
                    F.drawShadowText(imgui, dl, cx, ly, ln, F.u32.text_secondary, 0.88 * s, 'c')
                    ly = ly + math.floor(20 * s)
                end
                local bW, bH = math.floor(168 * s), math.floor(32 * s)
                if F.drawBeveledCtaButton(imgui, dl, '##sf_canvas_ws_retry', cx - bW * 0.5, ly + 14 * s, bW, bH, 'RETRY SYNC', 'gold', { fontScale = 0.84 * s }) then
                    action.requestWS(state.selectedWsId)
                end
            else
                F.drawCrystalMedallion(dl, cx, cy - 42 * s, 38 * s, {
                    rim  = F.u32.aether_cyan,
                    core = F.rgba.crystal_violet,
                })
                local dots = string.rep('.', (math.floor((now or 0) * 2) % 3) + 1)
                F.drawShadowText(imgui, dl, cx, cy + 12 * s, 'LOADING ' .. string.upper(wsLabel) .. dots, F.u32.aether_cyan, 1.08 * s, 'c')
                F.drawShadowText(imgui, dl, cx, cy + 40 * s, 'Confirming server-authoritative talent ranks.', F.u32.text_secondary, 0.88 * s, 'c')
                local bW, bH = math.floor(156 * s), math.floor(30 * s)
                if F.drawBeveledCtaButton(imgui, dl, '##sf_canvas_ws_reload', cx - bW * 0.5, cy + 72 * s, bW, bH, 'RETRY', 'cyan', { fontScale = 0.82 * s }) then
                    action.requestWS(state.selectedWsId)
                end
            end
        elseif #rows == 0 then
            F.drawCrystalMedallion(dl, cx, cy - 44 * s, 38 * s, {
                rim  = F.u32.soul_gold_dim,
                core = F.rgba.midnight_alt,
            })
            F.drawShadowText(imgui, dl, cx, cy + 8 * s, tostring(status.title or 'NO ELIGIBLE WEAPON SKILLS'), F.u32.soul_gold_bright, 1.10 * s, 'c')
            local maxChars = math.max(30, math.floor((w - 80 * s) / (8.0 * s)))
            local ly = cy + 36 * s
            for _, ln in ipairs(F.wrapLines(status.body or 'No weapon skills match the current Arsenal filter.', maxChars, 3)) do
                F.drawShadowText(imgui, dl, cx, ly, ln, F.u32.text_secondary, 0.88 * s, 'c')
                ly = ly + math.floor(20 * s)
            end
            if status.action and status.actionLabel then
                local bW, bH = math.floor(194 * s), math.floor(32 * s)
                if F.drawBeveledCtaButton(imgui, dl, '##sf_canvas_recover', cx - bW * 0.5, ly + 16 * s, bW, bH,
                    status.actionLabel, 'gold', { fontScale = 0.84 * s }) then
                    triggerArsenalRecovery(state, action, status, nav)
                end
            end
        else
            F.drawCrystalMedallion(dl, cx, cy - 40 * s, 38 * s, {
                rim  = F.u32.soul_gold,
                core = F.rgba.crystal_violet,
            })
            F.drawShadowText(imgui, dl, cx, cy + 12 * s, 'SELECT A WEAPON SKILL FROM YOUR ARSENAL', F.u32.soul_gold_bright, 1.08 * s, 'c')
            F.drawShadowText(imgui, dl, cx, cy + 40 * s, 'Choose a technique to awaken its Soulforge constellation.', F.u32.text_secondary, 0.90 * s, 'c')
        end
        return
    end

    local isEvo = UI.isEvolutionTree(d)

    -- A. Top Centered Weapon Skill Hero Title (matching approved mockup: ◆ [Icon] Savage Blade ◆)
    local heroH = math.floor((L.mode == 'focused' and 54 or 64) * s)
    local heroY = y + math.floor(6 * s)
    local midX  = x + w * 0.5

    -- Subtle dark translucent veil behind the hero title so white/gold title pops effortlessly
    if dl then
        F.drawGradRect(dl, x + 4, y + 2, x + w - 4, heroY + heroH + 6 * s,
            F.abgr(F.hex('#070B16', 0.84)), F.abgr(F.hex('#070B16', 0.16)))
    end

    local wsIconSz = math.floor((L.mode == 'focused' and 38 or 48) * s)
    local titleFs = (L.mode == 'focused' and 1.18 or 1.46) * s
    local wsTitleW = F.measureText(imgui, d.name, titleFs)
    local wsTypeName = tostring(d.wsType or 'physical')
    wsTypeName = wsTypeName:sub(1, 1):upper() .. wsTypeName:sub(2)
    local subLine = string.format('%s Weapon Skill  |  %s', tostring(d.skillName or 'Weapon'), wsTypeName)
    local subW = F.measureText(imgui, subLine, 0.86 * s)
    local blockW = wsIconSz + 14 * s + math.max(wsTitleW, subW)
    local blockX = math.max(x + pad + 18 * s, midX - blockW * 0.5)

    -- Flanking antique-gold diamond ornaments
    if dl and dl.AddQuadFilled and blockX > x + 30 * s then
        local dCy = heroY + heroH * 0.45
        local dd = 5.5 * s
        local lx, rxD = blockX - 18 * s, blockX + blockW + 18 * s
        dl:AddQuadFilled({ lx, dCy - dd }, { lx + dd, dCy }, { lx, dCy + dd }, { lx - dd, dCy }, F.u32.soul_gold_bright)
        dl:AddQuadFilled({ rxD, dCy - dd }, { rxD + dd, dCy }, { rxD, dCy + dd }, { rxD - dd, dCy }, F.u32.soul_gold_bright)
    end

    local ix, iy = blockX, heroY + math.floor((heroH - wsIconSz) * 0.5)
    dl:AddRectFilled({ ix, iy }, { ix + wsIconSz, iy + wsIconSz }, F.u32.abyss_solid, 4)
    if not drawAssetOrFallback(dl, nav, 'ws_' .. tostring(d.id), ix + 2, iy + 2, wsIconSz - 4, wsIconSz - 4) then
        F.drawNodeMedallion(dl, ix + wsIconSz * 0.5, iy + wsIconSz * 0.5, wsIconSz * 0.44, {
            stateKey = 'maxed',
            pathKey  = (d.wsType == 'magical') and 'mastery' or 'offense',
        })
    end
    dl:AddRect({ ix, iy }, { ix + wsIconSz, iy + wsIconSz }, F.u32.soul_gold_bright, 4, 0, 1.6)

    local tx = ix + wsIconSz + 14 * s
    F.drawShadowText(imgui, dl, tx, heroY + 4 * s, d.name, F.u32.white, titleFs, 'l')
    F.drawShadowText(imgui, dl, tx, heroY + (L.mode == 'focused' and 28 or 36) * s, subLine, F.u32.text_secondary, 0.86 * s, 'l')

    -- Unobtrusive Honest Live Sync Indicator (upper-left) & Respec WS (upper-right)
    local isSyncing = (state.syncPending ~= nil) or (state.wsPending ~= nil) or (d.authoritative == false)
    local syncErr = state.wsError or state.lastSyncError
    if syncErr then
        if F.drawActionButton(imgui, dl, '##sf_sync_err_retry', x + pad, heroY + 4 * s, math.floor(112 * s), math.floor(22 * s),
            'SYNC ERR [RETRY]', 'danger', { fontScale = 0.66 * s }) then
            action.sync()
        end
    elseif isSyncing then
        local dots = string.rep('.', (math.floor((now or 0) * 2) % 3) + 1)
        F.drawBadgePill(imgui, dl, x + pad, heroY + 4 * s, 'Syncing' .. dots, {
            height = math.floor(20 * s), fill = F.abgr(F.rgba.abyss_solid, 0.85),
            border = F.u32.aether_cyan, textCol = F.u32.aether_cyan, fontScale = 0.68 * s,
        })
    elseif dl and dl.AddCircleFilled then
        -- Minimal unobtrusive green Live indicator
        dl:AddCircleFilled({ x + pad + 6 * s, heroY + 14 * s }, 3.8 * s, F.u32.success, 10)
        F.drawShadowText(imgui, dl, x + pad + 14 * s, heroY + 7 * s, 'Live', F.u32.text_muted, 0.70 * s, 'l')
    end

    if (tonumber(d.spent) or 0) > 0 then
        local resW = math.floor(102 * s)
        local resX = x + w - pad - resW
        if not ui.confirmResetWs then
            if F.drawActionButton(imgui, dl, '##sf_emb_reset_ws', resX, heroY + 4 * s, resW, math.floor(24 * s),
                'RESPEC [R]', 'neutral', { fontScale = 0.72 * s }) then
                ui.confirmResetWs   = true
                ui.confirmResetWsAt = now
            end
        elseif (now - (ui.confirmResetWsAt or 0)) > 5.0 then
            ui.confirmResetWs = false
        else
            if F.drawActionButton(imgui, dl, '##sf_emb_reset_ws_ok', resX, heroY + 4 * s, resW, math.floor(24 * s),
                'CONFIRM?', 'danger', { fontScale = 0.72 * s }) then
                ui.confirmResetWs = false
                action.resetWS(d.id)
            end
        end
    end

    -- B. Sleek Compact Skillchain Forging Runic Strip (T1..T4 — preserves real OP_CYCLE_SC)
    local curY = heroY + heroH + math.floor(2 * s)
    local slots = UI.getSkillchainSlots(d)
    if #slots > 0 then
        local scH = math.floor(34 * s)
        local scX = x + pad
        local scW = w - pad * 2
        dl:AddRectFilled({ scX, curY }, { scX + scW, curY + scH }, F.abgr(F.hex('#080C18', 0.78)), 5)
        dl:AddRect({ scX, curY }, { scX + scW, curY + scH },
            scFocused and F.u32.aether_cyan or F.abgr(F.rgba.soul_gold_dim, 0.55), 5, 0, scFocused and 1.6 or 1.0)

        local lblW = math.floor((L.mode == 'focused' and 56 or 116) * s)
        F.drawShadowText(imgui, dl, scX + 10 * s, curY + math.floor((scH - 12 * s) * 0.5),
            L.mode == 'focused' and 'SC' or 'SKILLCHAINS', F.u32.crystal_violet_bright, 0.74 * s, 'l')

        local sAreaX = scX + lblW + 4 * s
        local sAreaW = math.max(140, scW - lblW - 10 * s)
        local sGap   = math.floor(5 * s)
        local sW     = math.floor((sAreaW - sGap * (#slots - 1)) / #slots)
        local sH     = scH - math.floor(6 * s)
        local sY     = curY + math.floor(3 * s)
        local pendingSc = state.pendingOp ~= nil and (now - (state.pendingOp.sentAt or 0)) < 5.0

        for idx, sl in ipairs(slots) do
            local sx = sAreaX + (idx - 1) * (sW + sGap)
            local slotFocused = scFocused and (nav.sc_slot == idx)
            local border = slotFocused and F.u32.aether_cyan
                or (sl.active and F.u32.soul_gold or (sl.unlocked and F.u32.aether_cyan_dim or F.u32.border_subtle))
            local fill = slotFocused and F.u32.midnight_selected
                or (sl.active and F.abgr(F.rgba.soul_gold_wash, 0.85) or F.abgr(F.rgba.abyss_solid, 0.85))
            dl:AddRectFilled({ sx, sY }, { sx + sW, sY + sH }, fill, 4)
            dl:AddRect({ sx, sY }, { sx + sW, sY + sH }, border, 4, 0, (slotFocused or sl.active) and 1.5 or 1.0)

            -- Click slot body on legacy locked sc_tX to inspect/unlock that Skillchain node
            local cBtnW = math.floor(15 * s)
            local cBtnH = math.floor(18 * s)
            local cBtnY = sY + math.floor((sH - cBtnH) * 0.5)
            local bodyW = math.max(24, sW - cBtnW * 2 - 8 * s)
            if sl.node and imgui.SetCursorScreenPos and imgui.InvisibleButton then
                imgui.SetCursorScreenPos({ sx, sY })
                if imgui.InvisibleButton('##sf_sc_sel_' .. sl.tier, { bodyW, sH }) then
                    state.inspectedNodeKey = sl.node.key
                end
            end

            local scText = string.format('T%d: %s', sl.tier, sl.unlocked and sl.scName or sl.lockHint)
            F.drawShadowText(imgui, dl, sx + 6 * s, sY + math.floor((sH - 12 * s) * 0.5),
                F.fitText(imgui, scText, bodyW - 6 * s, 0.72 * s),
                sl.active and F.u32.soul_gold_bright or (sl.unlocked and F.u32.text_primary or F.u32.text_muted), 0.72 * s, 'l')

            if F.drawActionButton(imgui, dl, '##sf_scp_' .. sl.tier, sx + sW - cBtnW * 2 - 5 * s, cBtnY, cBtnW, cBtnH, '<', 'neutral', {
                fontScale = 0.68 * s, disabled = pendingSc,
            }) then
                action.cycleSkillchain(d.id, sl.tier, 2)
            end
            if F.drawActionButton(imgui, dl, '##sf_scn_' .. sl.tier, sx + sW - cBtnW - 3 * s, cBtnY, cBtnW, cBtnH, '>', 'neutral', {
                fontScale = 0.68 * s, disabled = pendingSc,
            }) then
                action.cycleSkillchain(d.id, sl.tier, 1)
            end
        end
        curY = curY + scH + math.floor(4 * s)
    end

    -- C. Bottom 3 Ornate Path Summary Cards (Offense Path / Mastery Path / Utility Path)
    local pathBarH = (L.mode ~= 'focused' and h >= 440 * s) and math.floor(88 * s) or 0
    local pathBarY = y + h - pad - pathBarH

    -- D. Circular Interconnected Orbital Talent Tree Arena
    local treeTop = curY
    local treeH   = math.max(160, (pathBarH > 0 and (pathBarY - math.floor(8 * s)) or (y + h - pad)) - treeTop)
    local treeCx  = x + w * 0.5
    local treeCy  = treeTop + treeH * 0.50
    local ringR   = math.max(76 * s, math.min((w - 86 * s) * 0.44, (treeH - 54 * s) * 0.48))

    -- Subtle golden Astral Ring reinforcement around the chamber sword
    if F.drawAstralRing then
        F.drawAstralRing(dl, treeCx, treeCy, ringR * 0.92, { alpha = 0.65 })
    end

    local grid = UI.getTreeGrid(d)
    local positions = computeOrbitalPositions(grid, isEvo, treeCx, treeCy, ringR)
    local activePathFilter = nav and nav.path_filter or nil

    -- Compute real invested / max points per path for the 3 bottom Path Summary cards
    local pathTotals = {
        offense = { spent = 0, max = 0 },
        mastery = { spent = 0, max = 0 },
        utility = { spent = 0, max = 0 },
    }
    local tierChosen = {}
    for _, row in ipairs(grid) do
        local chosen = false
        for _, n in ipairs(row.nodes) do
            local rk = tonumber(n.rank) or 0
            local mr = math.max(1, tonumber(n.maxRank) or 1)
            if rk > 0 then chosen = true end
            local pk = UI.getNodePathKey(n, isEvo)
            if pathTotals[pk] then
                pathTotals[pk].spent = pathTotals[pk].spent + rk
                pathTotals[pk].max   = pathTotals[pk].max + mr
            end
        end
        tierChosen[row.tier] = chosen
    end

    -- Pass 1: Draw Glowing 3-Layer Energy Conduits for REAL reqKey dependencies (+ subtle structural tier links)
    local drawnEdges = {}
    local function drawEdge(pA, pB, stateKey, pathKey, alpha)
        if not pA or not pB then return end
        local ek = pA.node.key .. '->' .. pB.node.key
        if drawnEdges[ek] then return end
        drawnEdges[ek] = true
        F.drawEnergyConduit(dl, pA.cx, pA.cy, pB.cx, pB.cy, stateKey, pathKey, {
            alpha = alpha,
            thickness = 2.8 * s,
        })
    end

    for _, p in pairs(positions) do
        local n = p.node
        local pAlpha = (activePathFilter == nil or activePathFilter == p.pathKey) and 1.0 or 0.22
        if n.reqKey and positions[n.reqKey] then
            local par = positions[n.reqKey]
            local pRank = tonumber(par.node.rank) or 0
            local cRank = tonumber(n.rank) or 0
            local linkState = (pRank > 0 and cRank > 0) and 'active'
                or (pRank > 0 and n.canLearn and 'available')
                or 'locked'
            drawEdge(par, p, linkState, p.pathKey, pAlpha)
        end
    end

    -- Subtle structural arc links connecting same-column consecutive tiers (when no direct reqKey already drew them)
    for ti = 2, #grid do
        local prevRow = grid[ti - 1]
        local curRow  = grid[ti]
        for _, cn in ipairs(curRow.nodes) do
            local pCur = positions[cn.key]
            if pCur and (not cn.reqKey or not positions[cn.reqKey]) then
                -- Link to same-column parent in previous tier
                local bestPar = nil
                for _, pn in ipairs(prevRow.nodes) do
                    if (pn.col or 0) == (cn.col or 0) then
                        bestPar = positions[pn.key]
                        break
                    end
                end
                if bestPar then
                    local pRank = tonumber(bestPar.node.rank) or 0
                    local cRank = tonumber(cn.rank) or 0
                    local linkState = (pRank > 0 and cRank > 0) and 'active'
                        or (pRank > 0 and cn.canLearn and 'available')
                        or 'locked'
                    local pAlpha = (activePathFilter == nil or activePathFilter == pCur.pathKey) and 0.72 or 0.16
                    drawEdge(bestPar, pCur, linkState, pCur.pathKey, pAlpha)
                end
            end
        end
    end

    -- Pass 2: Draw Circular Ornate Talent Node Medallions (interactive hit targets!)
    local baseNodeR = math.floor(F.clamp(ringR * 0.175, 20 * s, 32 * s))
    local hoveredInfo = nil

    for _, row in ipairs(grid) do
        for _, n in ipairs(row.nodes) do
            local p = positions[n.key]
            if p then
                local otherChosen = isEvo and tierChosen[row.tier] and (n.rank or 0) == 0
                local eval = UI.evaluateNode(state, d, n, otherChosen, now)
                local selected = (state.inspectedNodeKey == n.key)
                local padFocused = treeFocused and (nav.node_key == n.key)
                local r = p.keystone and math.floor(baseNodeR * 1.12) or baseNodeR
                local alpha = (activePathFilter == nil or activePathFilter == p.pathKey or selected or padFocused) and 1.0 or 0.28

                imgui.SetCursorScreenPos({ p.cx - r - 3, p.cy - r - 3 })
                imgui.InvisibleButton('##sf_node_' .. n.key, { (r + 3) * 2, (r + 3) * 2 })
                local hovered = imgui.IsItemHovered()
                if imgui.IsItemClicked(0) then
                    state.inspectedNodeKey = n.key
                    ui.confirmAction = nil
                    if nav and nav.on_focus then nav.on_focus('tree', n.key) end
                    if L.drawerMode then ui.drawerOpen = 'inspector' end
                end
                if hovered then
                    hoveredInfo = { p = p, node = n, eval = eval, r = r }
                end

                local nodeTex = getTex(nav, 'node_' .. n.key)
                F.drawNodeMedallion(dl, p.cx, p.cy, r, {
                    stateKey = eval.stateKey,
                    pathKey  = p.pathKey,
                    texId    = nodeTex,
                    selected = selected,
                    focused  = padFocused,
                    hovered  = hovered,
                    keystone = p.keystone,
                    alpha    = alpha,
                })

                -- Crisp compact rank pill below unlocked/available nodes (never crowds neighbors!)
                if eval.rank > 0 or selected or padFocused then
                    local rkStr = string.format('%d/%d', eval.rank, eval.maxRank)
                    local pw = math.floor(34 * s)
                    local ph = math.floor(15 * s)
                    local px = p.cx - pw * 0.5
                    local py = p.cy + r - math.floor(4 * s)
                    dl:AddRectFilled({ px, py }, { px + pw, py + ph }, F.abgr(F.rgba.abyss_solid, 0.94 * alpha), 4)
                    dl:AddRect({ px, py }, { px + pw, py + ph },
                        (selected or padFocused) and F.u32.soul_gold_bright or F.abgr(F.rgba.soul_gold_dim, 0.85 * alpha), 4, 0, 1.1)
                    F.drawShadowText(imgui, dl, p.cx, py + 1 * s, rkStr,
                        (eval.stateKey == 'maxed') and F.u32.soul_gold_bright or F.u32.white, 0.68 * s, 'c')
                end
            end
        end
    end

    -- Subtle floating name pill for hovered node so every medallion stays instantly readable
    if hoveredInfo and dl then
        local hn = hoveredInfo.node
        local hp = hoveredInfo.p
        local tagFs = 0.78 * s
        local tw = F.measureText(imgui, hn.name, tagFs) + 18 * s
        local th = math.floor(22 * s)
        local txP = F.clamp(hp.cx - tw * 0.5, x + pad, x + w - pad - tw)
        local tyP = hp.cy - hoveredInfo.r - th - 6 * s
        if tyP < treeTop then tyP = hp.cy + hoveredInfo.r + 14 * s end
        dl:AddRectFilled({ txP, tyP }, { txP + tw, tyP + th }, F.abgr(F.rgba.abyss_solid, 0.96), 4)
        dl:AddRect({ txP, tyP }, { txP + tw, tyP + th }, F.u32.soul_gold, 4, 0, 1.2)
        F.drawShadowText(imgui, dl, txP + tw * 0.5, tyP + 3 * s, hn.name, F.u32.soul_gold_bright, tagFs, 'c')
    end

    -- Render Bottom 3 Ornate Path Summary Cards
    if pathBarH > 0 then
        local pGap = math.floor(10 * s)
        local totalBarW = w - pad * 2
        local cardW = math.floor((totalBarW - pGap * 2) / 3)
        for idx, pm in ipairs(PATH_META) do
            local cxCard = x + pad + (idx - 1) * (cardW + pGap)
            local spec = F.PATHS[pm.key]
            local tot = pathTotals[pm.key] or { spent = 0, max = 0 }
            local isSpotlight = (activePathFilter == pm.key)
            local isDimmed = (activePathFilter ~= nil and not isSpotlight)
            local alpha = isDimmed and 0.52 or 1.0

            imgui.SetCursorScreenPos({ cxCard, pathBarY })
            if imgui.InvisibleButton('##sf_path_card_' .. pm.key, { cardW, pathBarH }) then
                if nav and type(nav.on_toggle_path) == 'function' then
                    nav.on_toggle_path(pm.key)
                end
            end
            local hov = imgui.IsItemHovered and imgui.IsItemHovered() or false

            if dl then
                if isSpotlight or (pm.key == 'mastery' and activePathFilter == nil) then
                    dl:AddRectFilled({ cxCard - 3, pathBarY - 3 }, { cxCard + cardW + 3, pathBarY + pathBarH + 3 },
                        F.abgr(spec.primary, (isSpotlight and 0.30 or 0.16) * alpha), 7)
                end
                F.drawGradRect(dl, cxCard, pathBarY, cxCard + cardW, pathBarY + pathBarH,
                    F.abgr(spec.deep, 0.94 * alpha), F.abgr(F.rgba.abyss_solid, 0.96 * alpha))
                dl:AddRect({ cxCard, pathBarY }, { cxCard + cardW, pathBarY + pathBarH },
                    F.abgr((isSpotlight or hov) and spec.bright or spec.primary, 0.90 * alpha),
                    6, 0, isSpotlight and 2.2 or 1.4)
                -- Luminous top edge bar
                dl:AddLine({ cxCard + 10, pathBarY + 1 }, { cxCard + cardW - 10, pathBarY + 1 },
                    F.abgr(spec.bright, 0.72 * alpha), 1.6)
            end

            -- Path emblem + title
            local titleFsC = 0.96 * s
            local tw = F.measureText(imgui, pm.title, titleFsC)
            local iconShift = 10 * s
            local headStartX = cxCard + (cardW - (tw + 20 * s)) * 0.5
            local headCy = pathBarY + 18 * s
            if pm.key == 'offense' and dl and dl.AddLine then
                dl:AddLine({ headStartX, headCy + 6 * s }, { headStartX + 12 * s, headCy - 6 * s }, F.abgr(spec.bright, alpha), 2.4)
            elseif pm.key == 'utility' and dl and dl.AddTriangleFilled then
                dl:AddTriangleFilled({ headStartX, headCy - 6 * s }, { headStartX + 10 * s, headCy - 6 * s }, { headStartX + 5 * s, headCy }, F.abgr(spec.bright, alpha))
                dl:AddTriangleFilled({ headStartX, headCy + 6 * s }, { headStartX + 10 * s, headCy + 6 * s }, { headStartX + 5 * s, headCy }, F.abgr(spec.primary, alpha))
            else
                F.drawCrystalStar(dl, headStartX + 5 * s, headCy, 7.5 * s, F.abgr(spec.bright, alpha), F.u32.white)
            end
            F.drawShadowText(imgui, dl, headStartX + iconShift + 8 * s, pathBarY + 9 * s,
                pm.title, F.abgr(F.rgba.white, alpha), titleFsC, 'l')

            -- Concise subtitle (up to 2 crisp centered lines, strictly bounded to card width)
            local subFs = 0.72 * s
            local charPx = math.max(7.2 * s, F.measureText(imgui, 'M', subFs))
            local chars = math.max(14, math.floor((cardW - 22 * s) / charPx))
            local subLines = F.wrapLines(pm.subtitle, chars, 2)
            local sy = pathBarY + 33 * s
            for _, ln in ipairs(subLines) do
                F.drawShadowText(imgui, dl, cxCard + cardW * 0.5, sy,
                    F.fitText(imgui, ln, cardW - 18 * s, subFs), F.abgr(F.rgba.text_secondary, alpha), subFs, 'c')
                sy = sy + math.floor(15 * s)
            end

            -- Real invested / max points counter
            F.drawShadowText(imgui, dl, cxCard + cardW * 0.5, pathBarY + pathBarH - 20 * s,
                string.format('%d / %d', tot.spent, math.max(1, tot.max)),
                F.abgr(spec.bright, alpha), 0.90 * s, 'c')
        end
    end
end

-- ---------------------------------------------------------------------------
-- 4. Right Panel: Ornate TALENT DETAILS Inspector & Beveled Hold-to-Confirm CTA
-- ---------------------------------------------------------------------------
local function drawInspector(state, action, L, x, y, w, h, nav)
    local dl  = imgui.GetWindowDrawList()
    local s   = L.uiScale or 1.0
    local ui  = ensureUiState(state)
    local d   = state.wsDetail
    local pad = math.floor(16 * s)
    local now = os.clock()
    local inspFocused = (nav ~= nil and (nav.region == 'inspector' or nav.region == 'confirm'))

    local panelTex = getTex(nav, 'panel_inspector')
    F.drawOrnatePanel(dl, x, y, w, h, {
        texId      = panelTex,
        texTint    = F.abgr(F.rgba.white, 0.26),
        scrimAlpha = 0.72,
        border     = inspFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent     = inspFocused and F.u32.aether_cyan or F.u32.soul_gold,
        thickness  = inspFocused and 1.8 or 1.3,
        corners    = true,
        shadow     = false,
    })

    F.drawShadowText(imgui, dl, x + pad, y + 12 * s,
        inspFocused and '> TALENT DETAILS' or 'TALENT DETAILS',
        inspFocused and F.u32.aether_cyan or F.u32.soul_gold_bright, 1.12 * s, 'l')
    F.drawDivider(dl, x + pad, y + 38 * s, w - pad * 2, inspFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    if not d then
        F.drawShadowText(imgui, dl, x + pad, y + 54 * s, 'Select a Weapon Skill to inspect its techniques.', F.u32.text_secondary, 0.88 * s, 'l')
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
        F.drawShadowText(imgui, dl, x + pad, y + 54 * s, 'No inspectable talent nodes available.', F.u32.text_muted, 0.88 * s, 'l')
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
    local pathKey = UI.getNodePathKey(node, isEvo)
    local innerW = w - pad * 2
    local cy = y + 50 * s

    -- Hero Node Icon + Bold Title + Rank X / Y + 5 Golden Diamond Pips (exact mockup match)
    local emSz = math.floor(64 * s)
    local emX, emY = x + pad, cy
    dl:AddRectFilled({ emX, emY }, { emX + emSz, emY + emSz }, F.u32.abyss_solid, 5)
    if not drawAssetOrFallback(dl, nav, 'node_' .. node.key, emX + 2, emY + 2, emSz - 4, emSz - 4) then
        if not drawAssetOrFallback(dl, nav, 'ws_' .. tostring(d.id), emX + 2, emY + 2, emSz - 4, emSz - 4) then
            F.drawNodeMedallion(dl, emX + emSz * 0.5, emY + emSz * 0.5, emSz * 0.44, {
                stateKey = eval.stateKey,
                pathKey  = pathKey,
                showIconWhenLocked = true,
            })
        end
    end
    dl:AddRect({ emX, emY }, { emX + emSz, emY + emSz }, F.u32.soul_gold_bright, 5, 0, 1.6)

    local metaX = emX + emSz + 14 * s
    local metaW = math.max(80, (x + w - pad) - metaX)
    F.drawShadowText(imgui, dl, metaX, cy + 4 * s,
        F.fitText(imgui, node.name, metaW, 1.16 * s), F.u32.white, 1.16 * s, 'l')
    F.drawShadowText(imgui, dl, metaX, cy + 32 * s,
        string.format('Rank %d / %d', eval.rank, eval.maxRank), F.u32.text_primary, 0.94 * s, 'l')

    -- 5 Golden Diamond Pips right beside Rank text (or cleanly below if narrow)
    local rkW = F.measureText(imgui, string.format('Rank %d / %d', eval.rank, eval.maxRank), 0.94 * s)
    if metaW - rkW >= 92 * s then
        drawDiamondPips(dl, metaX + rkW + 10 * s, cy + 40 * s, eval.rank, eval.maxRank, s)
    else
        drawDiamondPips(dl, metaX, cy + 56 * s, eval.rank, eval.maxRank, s)
    end
    cy = cy + emSz + 14 * s

    -- Description lead text (strictly bounded to inspector width)
    local descCharPx = math.max(8.8 * s, F.measureText(imgui, 'M', 0.86 * s))
    local charsPerLine = math.max(18, math.floor((innerW - 28 * s) / descCharPx))
    local descStr = (node.desc and node.desc ~= '') and node.desc or 'No description provided by server.'
    local leadLines = F.wrapLines(descStr, charsPerLine, 3)
    for _, line in ipairs(leadLines) do
        F.drawShadowText(imgui, dl, x + pad, cy, F.fitText(imgui, line, innerW - 4 * s, 0.86 * s), F.u32.text_primary, 0.86 * s, 'l')
        cy = cy + math.floor(19 * s)
    end
    cy = cy + 10 * s

    -- Current Effect Card (recessed dark card with gold diamond marker)
    local curBoxH = math.floor(28 * s + math.min(2, #leadLines) * 18 * s)
    dl:AddRectFilled({ x + pad, cy }, { x + w - pad, cy + curBoxH }, F.abgr(F.hex('#0D1322', 0.92)), 5)
    dl:AddRect({ x + pad, cy }, { x + w - pad, cy + curBoxH }, F.u32.border_strong, 5, 0, 1.1)
    if dl and dl.AddQuadFilled then
        local dx, dy = x + pad + 12 * s, cy + 14 * s
        dl:AddQuadFilled({ dx, dy - 4 * s }, { dx + 4 * s, dy }, { dx, dy + 4 * s }, { dx - 4 * s, dy }, F.u32.soul_gold_bright)
    end
    F.drawShadowText(imgui, dl, x + pad + 22 * s, cy + 6 * s,
        string.format('Current Effect (Rank %d)', eval.rank), F.u32.soul_gold, 0.86 * s, 'l')
    for i = 1, math.min(2, #leadLines) do
        F.drawShadowText(imgui, dl, x + pad + 22 * s, cy + 25 * s + (i - 1) * 18 * s,
            F.fitText(imgui, leadLines[i], innerW - 32 * s, 0.82 * s), F.u32.text_primary, 0.82 * s, 'l')
    end
    cy = cy + curBoxH + 10 * s

    -- Highlighted Warm-Gold Next-Rank Preview Card (exact approved Soulforge visual anchor)
    if eval.rank < eval.maxRank then
        local nextDesc = (node.nextDesc and node.nextDesc ~= '') and node.nextDesc
            or string.format('Upgrade to Rank %d  (-%d pt, %d remaining)', eval.rank + 1, eval.cost, math.max(0, (state.avail or 0) - eval.cost))
        local nxtLines = F.wrapLines(nextDesc, math.max(16, charsPerLine - 2), 2)
        local nxtBoxH = math.floor(28 * s + #nxtLines * 18 * s)
        F.drawGradRect(dl, x + pad, cy, x + w - pad, cy + nxtBoxH,
            F.abgr(F.hex('#493719', 0.90)), F.abgr(F.hex('#271D0D', 0.94)))
        dl:AddRect({ x + pad, cy }, { x + w - pad, cy + nxtBoxH }, F.u32.soul_gold_bright, 5, 0, 1.5)
        F.drawShadowText(imgui, dl, x + pad + 12 * s, cy + 6 * s,
            string.format('-> Next Rank (Rank %d)', eval.rank + 1), F.u32.soul_gold_bright, 0.88 * s, 'l')
        for i, nl in ipairs(nxtLines) do
            F.drawShadowText(imgui, dl, x + pad + 22 * s, cy + 25 * s + (i - 1) * 18 * s,
                F.fitText(imgui, nl, innerW - 32 * s, 0.82 * s), F.u32.white, 0.82 * s, 'l')
        end
        cy = cy + nxtBoxH + 12 * s
    end

    -- Requirements Checklist with crisp vector green checkmarks
    F.drawDivider(dl, x + pad, cy, innerW, F.u32.soul_gold_dim)
    cy = cy + 10 * s
    if dl and dl.AddQuadFilled then
        local dx, dy = x + pad + 6 * s, cy + 8 * s
        dl:AddQuadFilled({ dx, dy - 4 * s }, { dx + 4 * s, dy }, { dx, dy + 4 * s }, { dx - 4 * s, dy }, F.u32.soul_gold)
    end
    F.drawShadowText(imgui, dl, x + pad + 16 * s, cy, 'Requirements', F.u32.soul_gold_bright, 0.92 * s, 'l')
    cy = cy + 24 * s

    local function reqRow(ok, label)
        drawReqIcon(dl, x + pad + 8 * s, cy + 8 * s, 5.5 * s, ok)
        F.drawShadowText(imgui, dl, x + pad + 22 * s, cy,
            F.fitText(imgui, label, innerW - 24 * s, 0.84 * s),
            ok and F.u32.text_primary or F.u32.text_secondary, 0.84 * s, 'l')
        cy = cy + math.floor(20 * s)
    end

    reqRow(eval.lvlOk, string.format('Job Level %d+ (Current: Lv.%d)', node.reqLevel or 1, state.jobLevel or 1))
    if (node.reqWsPoints or 0) > 0 then
        reqRow(eval.ptsOk, string.format('%d+ WS Points Invested (Now %d)', node.reqWsPoints, d.spent or 0))
    end
    if eval.parentNode then
        reqRow(eval.parentOk, string.format('Rank %d: %s', math.max(1, node.reqRank or 1), eval.parentNode.name))
    end
    if eval.rank < eval.maxRank then
        reqRow(eval.availOk, string.format('Requires %d available point(s)', eval.cost))
    end

    -- Unavailability / Server Rejection Explanation (only when blocking action)
    if eval.reason and not eval.canUpgrade and eval.stateKey ~= 'maxed' then
        cy = cy + 4 * s
        local isErr = (eval.stateKey == 'rejected')
        local rLines = F.wrapLines(eval.reason, charsPerLine, 2)
        local rH = math.floor(14 * s + #rLines * 17 * s)
        local maxBottom = (y + h) - pad - math.floor(92 * s)
        if cy + rH < maxBottom then
            dl:AddRectFilled({ x + pad, cy }, { x + w - pad, cy + rH },
                isErr and F.abgr(F.rgba.danger_wash, 0.95) or F.abgr(F.rgba.abyss_solid, 0.90), 4)
            dl:AddRect({ x + pad, cy }, { x + w - pad, cy + rH },
                isErr and F.u32.danger or F.u32.border_strong, 4, 0, 1.1)
            for i, rl in ipairs(rLines) do
                F.drawShadowText(imgui, dl, x + pad + 10 * s, cy + 6 * s + (i - 1) * 17 * s,
                    rl, isErr and F.u32.danger or F.u32.text_secondary, 0.80 * s, 'l')
            end
            cy = cy + rH + 8 * s
        end
    end

    -- Bottom Action Dock: Point Cost Row + Ornate Beveled Gold CTA (Hold-to-Confirm + 2-Step Confirm)
    local actBtnH = math.floor(42 * s)
    local actY    = (y + h) - pad - actBtnH

    -- Point Cost row cleanly anchored above CTA button
    if eval.rank < eval.maxRank and not (ui.confirmAction and ui.confirmAction.nodeKey == node.key) then
        local pcY = actY - (eval.canRefund and math.floor(66 * s) or math.floor(34 * s))
        if pcY > cy + 4 * s then
            F.drawDivider(dl, x + pad, pcY - 6 * s, innerW, F.u32.border_subtle)
            F.drawShadowText(imgui, dl, x + pad + 4 * s, pcY + 2 * s, 'Point Cost', F.u32.text_primary, 0.90 * s, 'l')
            if F.drawCrystalStar then
                F.drawCrystalStar(dl, x + w - pad - 28 * s, pcY + 10 * s, 9.5 * s, F.u32.crystal_violet_bright, F.u32.white)
            end
            F.drawShadowText(imgui, dl, x + w - pad - 4 * s, pcY, tostring(eval.cost),
                eval.availOk and F.u32.white or F.u32.danger, 1.04 * s, 'r')
        end
    end

    if ui.confirmAction and ui.confirmAction.nodeKey == node.key and ui.confirmAction.wsId == d.id then
        local confirmH = math.floor(78 * s)
        local cTop = (y + h) - pad - confirmH
        F.drawOrnatePanel(dl, x + pad, cTop, innerW, confirmH, {
            fillTop  = F.u32.midnight_alt,
            fillBot  = F.u32.abyss_solid,
            border   = ui.confirmAction.kind == 'refund' and F.u32.danger or F.u32.soul_gold_bright,
            corners  = false,
            shadow   = false,
        })
        local summary = ui.confirmAction.kind == 'refund'
            and string.format('Refund %s (Rank %d -> %d)?', node.name, eval.rank, eval.rank - 1)
            or string.format('Forge %s (Rank %d -> %d, -%d pt)?', node.name, eval.rank, eval.rank + 1, eval.cost)
        F.drawShadowText(imgui, dl, x + pad + 10 * s, cTop + 9 * s,
            F.fitText(imgui, summary, innerW - 20 * s, 0.84 * s), F.u32.soul_gold_bright, 0.84 * s, 'l')

        local halfW = math.floor((innerW - 24 * s) * 0.5)
        local bY = cTop + confirmH - math.floor(34 * s) - 7 * s
        local bH = math.floor(32 * s)
        local cGoFocused = (nav ~= nil and nav.region == 'confirm' and (nav.confirm_btn or 1) == 1)
        local cNoFocused = (nav ~= nil and nav.region == 'confirm' and nav.confirm_btn == 2)
        if F.drawBeveledCtaButton(imgui, dl, '##sf_confirm_go', x + pad + 8 * s, bY, halfW, bH,
            ui.confirmAction.kind == 'refund' and 'CONFIRM REFUND' or 'CONFIRM FORGE',
            ui.confirmAction.kind == 'refund' and 'danger' or 'gold', {
                focused = cGoFocused, fontScale = 0.82 * s,
            }) then
            local kind = ui.confirmAction.kind
            ui.confirmAction = nil
            if kind == 'refund' then
                action.refundNode(d.id, node)
            else
                action.investNode(d.id, node)
            end
        end
        if F.drawActionButton(imgui, dl, '##sf_confirm_cancel', x + pad + 16 * s + halfW, bY, halfW, bH,
            (cNoFocused and '> ' or '') .. 'CANCEL', 'neutral', { fontScale = 0.82 * s }) then
            ui.confirmAction = nil
        end
        if cNoFocused and dl then
            dl:AddRect({ x + pad + 15 * s + halfW, bY - 1 }, { x + pad + 17 * s + halfW * 2, bY + bH + 1 }, F.u32.aether_cyan, 5, 0, 2.0)
        end
    else
        local inspBtn = (nav ~= nil and nav.region == 'inspector') and (nav.inspector_btn or 1) or 0
        if eval.stateKey == 'pending' then
            F.drawBeveledCtaButton(imgui, dl, '##sf_pending', x + pad, actY, innerW, actBtnH,
                'Confirming with Server...', 'cyan', { disabled = true, fontScale = 0.90 * s })
        elseif not eval.isAuthoritative then
            F.drawBeveledCtaButton(imgui, dl, '##sf_sync_gate', x + pad, actY, innerW, actBtnH,
                'Syncing Live State...', 'cyan', { disabled = true, fontScale = 0.90 * s })
        elseif eval.canUpgrade then
            local firstUnlock = (node.tier or 1) == 1 and not UI.isWsUnlocked(state)
            local lbl = firstUnlock and ('Unlock ' .. tostring(d.name))
                or (eval.rank > 0 and string.format('Upgrade to Rank %d', eval.rank + 1)
                or string.format('Upgrade to Rank 1'))

            -- Track hold-to-confirm progress for deliberate RPG feel
            local holdProg = 0
            if ui.holdNodeKey == node.key and ui.holdStartAt then
                holdProg = F.clamp((now - ui.holdStartAt) / HOLD_CONFIRM_SEC, 0, 1)
            end

            local clickedUp, _, heldUp = F.drawBeveledCtaButton(imgui, dl, '##sf_upgrade', x + pad, actY, innerW, actBtnH,
                lbl, 'gold', {
                    focused      = (inspBtn == 1),
                    holdProgress = holdProg,
                    fontScale    = 0.98 * s,
                })

            if heldUp then
                if ui.holdNodeKey ~= node.key then
                    ui.holdNodeKey = node.key
                    ui.holdStartAt = now
                elseif (now - ui.holdStartAt) >= HOLD_CONFIRM_SEC then
                    ui.holdNodeKey = nil
                    ui.holdStartAt = nil
                    action.investNode(d.id, node)
                end
            else
                if ui.holdNodeKey == node.key then
                    ui.holdNodeKey = nil
                    ui.holdStartAt = nil
                end
                if clickedUp then
                    ui.confirmAction = { kind = 'invest', wsId = d.id, nodeKey = node.key }
                    if nav and nav.on_focus then nav.on_focus('confirm', 1) end
                end
            end

            if eval.canRefund then
                local refH = math.floor(28 * s)
                local refY = actY - refH - math.floor(8 * s)
                if F.drawActionButton(imgui, dl, '##sf_refund_sec', x + pad, refY, innerW, refH,
                    (inspBtn == 2 and '> ' or '') .. 'Refund 1 Rank', 'danger', { fontScale = 0.80 * s }) then
                    ui.confirmAction = { kind = 'refund', wsId = d.id, nodeKey = node.key }
                    if nav and nav.on_focus then nav.on_focus('confirm', 1) end
                end
                if inspBtn == 2 and dl then
                    dl:AddRect({ x + pad - 1, refY - 1 }, { x + pad + innerW + 1, refY + refH + 1 }, F.u32.aether_cyan, 5, 0, 2.0)
                end
            end
        elseif eval.canRefund then
            if F.drawBeveledCtaButton(imgui, dl, '##sf_refund', x + pad, actY, innerW, actBtnH,
                'Refund Technique', 'danger', { focused = (inspBtn == 1), fontScale = 0.92 * s }) then
                ui.confirmAction = { kind = 'refund', wsId = d.id, nodeKey = node.key }
                if nav and nav.on_focus then nav.on_focus('confirm', 1) end
            end
        else
            F.drawBeveledCtaButton(imgui, dl, '##sf_locked_btn', x + pad, actY, innerW, actBtnH,
                eval.stateKey == 'maxed' and 'Mastery Complete' or 'Unavailable', 'gold',
                { disabled = true, fontScale = 0.92 * s })
        end
    end
end

-- ---------------------------------------------------------------------------
-- 5. Standalone Footer Bar (used only by standalone /talents window)
-- ---------------------------------------------------------------------------
local function drawFooter(state, action, L, x, y, w, h)
    local dl  = imgui.GetWindowDrawList()
    local s   = L.uiScale or 1.0
    local ui  = ensureUiState(state)
    local now = os.clock()

    F.drawPanelFrame(dl, x, y, w, h, {
        fillTop  = F.u32.midnight_deep,
        fillBot  = F.u32.abyss_solid,
        border   = F.u32.border_subtle,
        corners  = false,
        shadow   = false,
    })

    local msg, msgCol
    if state.renderError then
        msg, msgCol = 'UI Error: ' .. tostring(state.renderError), F.u32.danger
    elseif state.rejectedMsg and state.rejectedAt and (now - state.rejectedAt) < 5.0 then
        msg, msgCol = 'Server Rejected: ' .. tostring(state.rejectedMsg), F.u32.danger
    elseif state.statusText and (now - (state.statusTime or 0)) < 5.0 then
        msg, msgCol = tostring(state.statusText), F.u32.aether_cyan
    else
        msg = 'Click node to inspect  •  Hold Upgrade or click to confirm  •  [T] Toggle Paths'
        msgCol = F.u32.text_secondary
    end

    local btnH = math.floor(24 * s)
    local btnY = y + math.floor((h - btnH) * 0.5)
    local rightUsed = math.floor(240 * s)
    F.drawShadowText(imgui, dl, x + 12 * s, y + math.floor((h - 14 * s) * 0.5),
        F.fitText(imgui, msg, math.max(120, w - rightUsed - 24 * s), 0.80 * s), msgCol, 0.80 * s, 'l')

    local rx = x + w - 10 * s
    local specBtnW = math.floor(108 * s)
    rx = rx - specBtnW
    if not state.confirmResetAll then
        if F.drawActionButton(imgui, dl, '##sf_reset_all', rx, btnY, specBtnW, btnH, 'RESET SPEC', 'neutral', { fontScale = 0.74 * s }) then
            state.confirmResetAll = true
            state.confirmResetAllAt = now
        end
    elseif (now - (state.confirmResetAllAt or 0)) > 5.0 then
        state.confirmResetAll = false
    else
        if F.drawActionButton(imgui, dl, '##sf_reset_all_ok', rx, btnY, specBtnW, btnH, 'CONFIRM SPEC', 'danger', { fontScale = 0.74 * s }) then
            state.confirmResetAll = false
            action.resetAll()
        end
    end

    local syncW = math.floor(64 * s)
    rx = rx - syncW - 6 * s
    if F.drawActionButton(imgui, dl, '##sf_foot_sync', rx, btnY, syncW, btnH, 'SYNC', 'cyan', { fontScale = 0.74 * s }) then
        action.sync()
    end
end

-- ---------------------------------------------------------------------------
-- Main Entry Points
-- ---------------------------------------------------------------------------
function UI.computeLayout(state, viewW, viewH)
    local ui = ensureUiState(state)
    return F.computeViewportLayout(viewW, viewH, ui.scale or 1.0, {
        maxLogicalW = 2480,
        maxLogicalH = 1400,
    })
end

-- Embedded entry point for SoulspireXI Core (renders inside Core's full-screen viewport).
function UI.drawEmbedded(state, action, L, x, y, w, h, nav)
    local ui  = ensureUiState(state)
    local s   = L.uiScale or 1.0
    local gap = L.gap or math.floor(10 * s)

    local subH = math.floor(((L.mode == 'focused' and 64) or 94) * s)
    drawSoulforgeBanner(state, action, L, x, y, w, subH, nav, false)

    local contentY = y + subH + gap
    local contentH = math.max(200, h - subH - gap)
    local arsW = math.floor(w * (L.mode == 'expanded' and 0.235 or 0.240))
    local insW = math.floor(w * (L.mode == 'expanded' and 0.265 or 0.270))
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
            drawArsenal(state, action, L, x, contentY, math.max(260, arsW), contentH, nav)
            drawSoulforgeCanvas(state, action, L, x + math.max(260, arsW) + gap, contentY, math.max(200, w - math.max(260, arsW) - gap), contentH, nav)
        elseif drawer == 'inspector' then
            local dw = math.max(280, insW)
            drawSoulforgeCanvas(state, action, L, x, contentY, math.max(200, w - dw - gap), contentH, nav)
            drawInspector(state, action, L, x + (w - dw), contentY, dw, contentH, nav)
        else
            drawSoulforgeCanvas(state, action, L, x, contentY, w, contentH, nav)
        end
    end
end

-- Standalone /talents entry point (preserves full standalone parity).
function UI.draw(state, action)
    local ui = ensureUiState(state)
    local vw, vh = F.getViewportSize(imgui)
    local L = UI.computeLayout(state, vw, vh)

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
        local s = L.uiScale or 1.0

        F.drawOrnatePanel(dl, wx, wy, L.winW, L.winH, {
            texId      = getTex(nil, 'soulforge_backdrop'),
            texTint    = F.abgr(F.rgba.white, 0.50),
            scrimAlpha = 0.56,
            border     = F.u32.soul_gold,
            accent     = F.u32.soul_gold_bright,
            rounding   = 8,
            corners    = true,
            shadow     = true,
        })

        local innerX  = wx + L.pad
        local headerY = wy + L.pad
        local bannerH = math.floor(((L.mode == 'focused' and 64) or 94) * s)
        drawSoulforgeBanner(state, action, L, innerX, headerY, L.innerW, bannerH, nil, true)

        local footerH = math.floor(38 * s)
        local bodyY   = headerY + bannerH + L.gap
        local bodyH   = math.max(200, (wy + L.winH - L.pad) - bodyY - footerH - L.gap)
        local arsW    = math.floor(L.innerW * 0.24)
        local insW    = math.floor(L.innerW * 0.27)
        local fgW     = math.max(300, L.innerW - arsW - insW - L.gap * 2)

        if not L.drawerMode then
            drawArsenal(state, action, L, innerX, bodyY, arsW, bodyH)
            drawSoulforgeCanvas(state, action, L, innerX + arsW + L.gap, bodyY, fgW, bodyH)
            drawInspector(state, action, L, innerX + arsW + fgW + L.gap * 2, bodyY, insW, bodyH)
        else
            if ui.drawerOpen == 'arsenal' then
                drawArsenal(state, action, L, innerX, bodyY, math.max(260, arsW), bodyH)
                drawSoulforgeCanvas(state, action, L, innerX + math.max(260, arsW) + L.gap, bodyY, L.innerW - math.max(260, arsW) - L.gap, bodyH)
            elseif ui.drawerOpen == 'inspector' then
                local dw = math.max(280, insW)
                drawSoulforgeCanvas(state, action, L, innerX, bodyY, L.innerW - dw - L.gap, bodyH)
                drawInspector(state, action, L, innerX + (L.innerW - dw), bodyY, dw, bodyH)
            else
                drawSoulforgeCanvas(state, action, L, innerX, bodyY, L.innerW, bodyH)
            end
        end

        local footerY = bodyY + bodyH + L.gap
        drawFooter(state, action, L, innerX, footerY, L.innerW, footerH)
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
