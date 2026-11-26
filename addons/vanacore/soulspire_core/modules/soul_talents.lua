-- SoulspireXI Core Module: Soul Talents
-- Presents the active Soul's Talent Point Ledger, 4-WS Spec Mastery Loadout Slots,
-- all invested talent nodes across synced Weapon Skills, live Soul HUD mechanics
-- telemetry, and server-authoritative Reset Spec confirmation.
--
-- Reuses shared soulforge_state (0x11F/0x1FD OXTL), soul_registry_generated.lua,
-- and passive [OXHUD]| telemetry observation with zero duplicated progression logic.

local SoulTalents = {}
SoulTalents.__index = SoulTalents

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function SoulTalents.new(sf_state, sf_actions, sf_ui, opts)
    opts = opts or {}
    return setmetatable({
        state            = sf_state,
        actions          = sf_actions,
        ui               = sf_ui,
        soul_registry    = opts.soul_registry,
        data_service     = opts.data_service,
        assets           = opts.assets,
        on_jump_to_ws    = opts.on_jump_to_ws, -- fn(wsId, nodeKey)
        region           = 'slots', -- 'slots' | 'nodes' | 'confirm_reset'
        slot_index       = 1,
        node_index       = 1,
        confirm_btn      = 1,
        hud_soul_key     = '',
        hud_kv           = {},
        hud_synced_at    = 0,
    }, SoulTalents)
end

function SoulTalents:has_modal()
    return self.region == 'confirm_reset'
end

-- Passive observer for Universal Soul HUD [OXHUD]| packets (0x017) so Soul Talents
-- can surface live Soul resource/mechanic telemetry read-only.
function SoulTalents:observe_hud_line(payload, now)
    if type(payload) ~= 'string' or payload == '' then return false end
    local parts = {}
    local start = 1
    while true do
        local pos = string.find(payload, '|', start, true)
        if not pos then
            parts[#parts + 1] = string.sub(payload, start)
            break
        end
        parts[#parts + 1] = string.sub(payload, start, pos - 1)
        start = pos + 1
    end
    local soul = parts[1]
    if not soul or soul == '' then return false end
    self.hud_soul_key = soul
    local kv = {}
    for i = 2, #parts do
        local k, v = string.match(parts[i], '^([^=]+)=(.*)$')
        if k and k ~= '' then
            kv[k] = v
        end
    end
    self.hud_kv = kv
    self.hud_synced_at = now or os.clock()
    return true
end

function SoulTalents:get_invested_nodes()
    local list = {}
    local details = self.state.wsDetailsById or {}
    local seen = {}
    local function collect_from(detail)
        if not detail or not detail.nodes or seen[detail.id] then return end
        seen[detail.id] = true
        for _, n in ipairs(detail.nodes) do
            if not self.ui.isSkillchainNode(n) and (tonumber(n.rank) or 0) > 0 then
                list[#list + 1] = {
                    wsId    = detail.id,
                    wsName  = detail.name or ('WS #' .. tostring(detail.id)),
                    key     = n.key,
                    name    = n.name or n.key,
                    tier    = tonumber(n.tier) or 1,
                    rank    = tonumber(n.rank) or 0,
                    maxRank = math.max(1, tonumber(n.maxRank) or 1),
                    desc    = n.desc or '',
                }
            end
        end
    end
    if self.state.wsDetail then
        collect_from(self.state.wsDetail)
    end
    for _, detail in pairs(details) do
        collect_from(detail)
    end
    table.sort(list, function(a, b)
        if a.wsId ~= b.wsId then return a.wsId < b.wsId end
        if a.tier ~= b.tier then return a.tier < b.tier end
        return a.key < b.key
    end)
    return list
end

function SoulTalents:on_open()
    if not self.state.synced or #(self.state.catalog or {}) == 0 then
        self.actions.sync()
    else
        self.actions.refreshState(true)
    end
end

function SoulTalents:on_activate(_focus, opts)
    if not (opts and opts.from_open) then
        if not self.state.synced or #(self.state.catalog or {}) == 0 then
            self.actions.sync()
        else
            -- Freshness-guarded refresh on tab switch: avoids duplicate sync storms!
            self.actions.refreshState(false)
        end
    end
    if self.region == 'confirm_reset' then
        self.region = 'slots'
    end
end

function SoulTalents:on_deactivate()
    if self.region == 'confirm_reset' then
        self.region = 'slots'
    end
end

function SoulTalents:on_close()
    self:on_deactivate()
end

function SoulTalents:on_action(action, ctx)
    local slots = self.ui.getInvestedWeaponskills(self.state)
    local nodes = self:get_invested_nodes()
    self.slot_index = clamp(self.slot_index, 1, math.max(1, self.ui.MAX_SPEC_WS_SLOTS))
    self.node_index = clamp(self.node_index, 1, math.max(1, #nodes))

    if self.region == 'confirm_reset' then
        if action == 'left' or action == 'up' then
            self.confirm_btn = 1
            return true
        elseif action == 'right' or action == 'down' then
            self.confirm_btn = 2
            return true
        elseif action == 'cancel' then
            self.region = 'slots'
            return true
        elseif action == 'confirm' then
            self.region = 'slots'
            if self.confirm_btn == 1 then
                self.actions.resetAll()
            end
            return true
        end
        return true
    end

    if action == 'focus_dock' then
        self.region = (self.region == 'slots' and #nodes > 0) and 'nodes' or 'slots'
        return true
    end

    if self.region == 'slots' then
        if action == 'up' then
            self.slot_index = ((self.slot_index - 2) % self.ui.MAX_SPEC_WS_SLOTS) + 1
            return true
        elseif action == 'down' then
            self.slot_index = (self.slot_index % self.ui.MAX_SPEC_WS_SLOTS) + 1
            return true
        elseif action == 'right' then
            if #nodes > 0 then
                self.region = 'nodes'
            end
            return true
        elseif action == 'confirm' then
            local sl = slots[self.slot_index]
            if sl and type(self.on_jump_to_ws) == 'function' then
                self.on_jump_to_ws(sl.id, nil, ctx)
            elseif not sl and type(self.on_jump_to_ws) == 'function' then
                self.on_jump_to_ws(nil, nil, ctx)
            end
            return true
        elseif action == 'context' then
            if (tonumber(self.state.spent) or 0) > 0 then
                self.region = 'confirm_reset'
                self.confirm_btn = 2 -- default to Cancel for destructive Reset Spec safety
            else
                self.actions.sync()
            end
            return true
        elseif action == 'cancel' then
            return false
        end
        return true
    end

    if self.region == 'nodes' then
        if action == 'up' then
            if #nodes > 0 then
                self.node_index = ((self.node_index - 2) % #nodes) + 1
            end
            return true
        elseif action == 'down' then
            if #nodes > 0 then
                self.node_index = (self.node_index % #nodes) + 1
            end
            return true
        elseif action == 'left' or action == 'cancel' then
            self.region = 'slots'
            return true
        elseif action == 'confirm' then
            local nd = nodes[self.node_index]
            if nd and type(self.on_jump_to_ws) == 'function' then
                self.on_jump_to_ws(nd.wsId, nd.key, ctx)
            end
            return true
        elseif action == 'context' then
            self.actions.sync()
            return true
        end
        return true
    end

    return false
end

function SoulTalents:get_hints()
    if self.region == 'confirm_reset' then
        return '[D-Pad] Confirm/Cancel   [A] Execute Reset Spec   [B] Cancel'
    elseif self.region == 'nodes' then
        return '[D-Pad] Inspect Talent   [A] Open in Soulforge   [Left/B] Spec Slots   [X] Sync   [LB/RB] Modules'
    else
        return '[D-Pad] Select Slot   [A] Open in Soulforge   [Right] Invested Nodes   [X] Reset Spec / Sync   [LB/RB] Modules'
    end
end

function SoulTalents:get_prompt_pills(last_device)
    if self.region == 'confirm_reset' then
        return {
            { 'D-Pad', 'Confirm / Cancel' },
            { 'A',     'Reset Spec' },
            { 'B',     'Cancel' },
        }
    end
    if last_device == 'keyboard' or last_device == 'mouse' then
        return {
            { 'Arrows', 'Select' },
            { 'Enter',  'Open Soulforge' },
            { 'X',      'Reset / Sync' },
            { 'Q/E',    'Modules' },
            { 'Esc',    'Close' },
        }
    end
    return {
        { 'D-Pad', 'Select Slot / Node' },
        { 'A',     'Open in Soulforge' },
        { 'X',     'Reset Spec / Sync' },
        { 'LB/RB', 'Modules' },
        { 'B',     'Close' },
    }
end

function SoulTalents:draw(imgui, dl, F, L, x, y, w, h, ctx)
    local s   = L.uiScale or 1.0
    local gap = L.gap or math.floor(10 * s)
    local pad = math.floor(16 * s)
    local st  = self.state

    local slots = self.ui.getInvestedWeaponskills(st)
    local nodes = self:get_invested_nodes()
    self.slot_index = clamp(self.slot_index, 1, self.ui.MAX_SPEC_WS_SLOTS)
    self.node_index = clamp(self.node_index, 1, math.max(1, #nodes))

    local soulEntry = nil
    if self.data_service and self.data_service:is_cache_usable() then
        soulEntry = self.data_service:get_soul_by_key(st.specKey)
            or self.data_service:get_soul_by_key(st.rawSpecKey)
            or self.data_service:get_soul_by_key(st.specName)
    end
    if not soulEntry and self.soul_registry and self.soul_registry.resolve then
        soulEntry = self.soul_registry.resolve(st.rawSpecKey) or self.soul_registry.resolve(st.specName)
    end
    local soulName = (soulEntry and soulEntry.displayName) or st.specName or 'Base'
    local soulRole = (soulEntry and soulEntry.roleLabel) or 'Base Adventurer'

    local assetsRef  = self.assets or (ctx and ctx.assets)
    local bannerTex  = assetsRef and assetsRef:load_texture('soulforge_banner_bg') or nil
    local browserTex = assetsRef and assetsRef:load_from_addon('soulspire_talents', 'panel_browser') or nil
    local inspTex    = assetsRef and assetsRef:load_from_addon('soulspire_talents', 'panel_inspector') or nil

    -- Top Ornate Soul Talents Banner matching Weapon Mastery & Character
    local avail  = tonumber(st.avail) or 0
    local spent  = tonumber(st.spent) or 0
    local earned = math.max(1, tonumber(st.earned) or (avail + spent))

    local bannerH = math.floor(((L.mode == 'focused' and 56) or 78) * s)
    F.drawOrnatePanel(dl, x, y, w, bannerH, {
        texId      = bannerTex,
        texTint    = F.abgr(F.rgba.white, 0.82),
        scrimAlpha = 0.34,
        border     = F.u32.soul_gold,
        accent     = F.u32.soul_gold_bright,
        rounding   = 6,
        corners    = true,
        shadow     = false,
    })

    local actLvl = math.max(1, tonumber(st.jobLevel) or 1)
    local effLvl = math.max(1, tonumber(st.effectiveLevel) or actLvl)
    local isSynced = (st.isLevelSynced == true) or (effLvl < actLvl)
    local lvlLabel = isSynced and string.format('Lv.%d (Sync %d)', effLvl, actLvl) or string.format('Lv.%d', actLvl)
    F.drawShadowText(imgui, dl, x + 20 * s, y + 12 * s,
        F.fitText(imgui, soulName, math.floor(w * 0.28), 1.24 * s), F.u32.white, 1.24 * s, 'l')
    F.drawShadowText(imgui, dl, x + 20 * s, y + 42 * s,
        F.fitText(imgui, string.format('%s %s  |  %s', st.jobKey or '---', lvlLabel, soulRole), math.floor(w * 0.30), 0.90 * s),
        isSynced and F.u32.aether_cyan or F.u32.crystal_violet_bright, 0.90 * s, 'l')

    local midX = x + w * 0.5
    F.drawShadowText(imgui, dl, midX, y + 12 * s, 'SOUL TALENTS', F.u32.soul_gold_bright, (L.mode == 'focused' and 1.12 or 1.46) * s, 'c')
    if L.mode ~= 'focused' then
        F.drawShadowText(imgui, dl, midX, y + 48 * s, 'ACTIVE SPEC LOADOUT & TELEMETRY', F.u32.soul_gold, 0.80 * s, 'c')
    end

    -- Far right: Talent Points star + Spent summary
    local tpX = x + w - 128 * s
    F.drawShadowText(imgui, dl, tpX + 54 * s, y + 8 * s, 'Talent Points', F.u32.soul_gold_bright, 0.82 * s, 'c')
    if F.drawCrystalStar then
        F.drawCrystalStar(dl, tpX + 24 * s, y + bannerH * 0.64, 13 * s, F.u32.crystal_violet_bright, F.u32.white)
    end
    F.drawShadowText(imgui, dl, tpX + 46 * s, y + bannerH * 0.42, tostring(avail),
        avail > 0 and F.u32.white or F.u32.text_muted, 1.44 * s, 'l')

    local bodyY = y + bannerH + gap
    local bodyH = math.max(200, h - bannerH - gap)
    local leftW  = math.floor(w * (L.mode == 'focused' and 0.42 or 0.31))
    local rightW = math.floor(w * (L.mode == 'focused' and 0.00 or 0.28))
    local midW   = math.max(200, w - leftW - rightW - (rightW > 0 and gap * 2 or gap))

    -- 1. Left Panel: Active Soul Spec Ledger & 4-WS Mastery Loadout Slots
    local slotsFocused = (self.region == 'slots')
    F.drawOrnatePanel(dl, x, bodyY, leftW, bodyH, {
        texId      = browserTex,
        texTint    = F.abgr(F.rgba.white, 0.24),
        scrimAlpha = 0.74,
        border     = slotsFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent     = slotsFocused and F.u32.aether_cyan or F.u32.soul_gold,
        thickness  = slotsFocused and 1.8 or 1.3,
        corners    = true,
        shadow     = false,
    })

    F.drawShadowText(imgui, dl, x + pad, bodyY + 12 * s,
        slotsFocused and '> SOUL SPEC LOADOUT' or 'SOUL SPEC LOADOUT',
        slotsFocused and F.u32.aether_cyan or F.u32.soul_gold_bright, 1.04 * s, 'l')
    F.drawDivider(dl, x + pad, bodyY + 38 * s, leftW - pad * 2, slotsFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    local cy = bodyY + 48 * s
    F.drawSegmentedGauge(imgui, dl, x + pad, cy, leftW - pad * 2, math.floor(22 * s), spent, earned, {
        fill      = avail > 0 and F.rgba.aether_cyan or F.rgba.soul_gold,
        border    = F.u32.soul_gold_dim,
        notches   = 4,
        label     = string.format('%d AVAIL', avail),
        valueText = string.format('%d / %d SPENT', spent, earned),
        fontScale = 0.80 * s,
    })
    cy = cy + 34 * s

    F.drawShadowText(imgui, dl, x + pad, cy,
        string.format('MASTERY SLOTS (%d / %d)', #slots, self.ui.MAX_SPEC_WS_SLOTS),
        F.u32.soul_gold, 0.84 * s, 'l')
    cy = cy + 24 * s

    local slotH = math.floor(66 * s)
    local slotW = leftW - pad * 2
    for i = 1, self.ui.MAX_SPEC_WS_SLOTS do
        local sl = slots[i]
        local focused = slotsFocused and (self.slot_index == i)
        local sy = cy + (i - 1) * (slotH + math.floor(10 * s))

        imgui.SetCursorScreenPos({ x + pad, sy })
        if imgui.InvisibleButton('##st_slot_' .. i, { slotW, slotH }) then
            self.region = 'slots'
            self.slot_index = i
            if type(self.on_jump_to_ws) == 'function' then
                self.on_jump_to_ws(sl and sl.id or nil, nil)
            end
        end
        local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false
        local border = focused and F.u32.aether_cyan
            or (sl and (sl.mastered and F.u32.soul_gold_bright or F.u32.crystal_violet) or F.u32.border_subtle)

        if focused or (sl and sl.mastered) then
            F.drawGradRect(dl, x + pad, sy, x + pad + slotW, sy + slotH,
                F.abgr(F.hex('#3C2D15', 0.92)), F.abgr(F.hex('#141826', 0.96)))
        else
            dl:AddRectFilled({ x + pad, sy }, { x + pad + slotW, sy + slotH },
                hovered and F.u32.midnight_alt or F.abgr(F.hex('#0D1221', 0.90)), 5)
        end
        dl:AddRect({ x + pad, sy }, { x + pad + slotW, sy + slotH }, border, 5, 0, focused and 1.9 or 1.1)

        local dr = math.floor(16 * s)
        local dCx = x + pad + 12 * s + dr
        local dCy = sy + slotH * 0.5
        F.drawDiamondSocket(dl, dCx, dCy, dr, {
            lit     = (sl ~= nil),
            active  = focused,
            coreU32 = (sl and sl.mastered) and F.u32.soul_gold_bright or F.u32.crystal_violet_bright,
        })

        local tx = dCx + dr + 12 * s
        local tw = math.max(80, slotW - (tx - (x + pad)) - 10 * s)
        if sl then
            F.drawShadowText(imgui, dl, tx, sy + 10 * s,
                F.fitText(imgui, string.format('SLOT %d  |  %s', i, sl.name), tw, 0.94 * s),
                focused and F.u32.soul_gold_bright or F.u32.white, 0.94 * s, 'l')
            F.drawSegmentedGauge(imgui, dl, tx, sy + 36 * s, tw, math.floor(17 * s), sl.spent, sl.cap, {
                fill      = sl.mastered and F.rgba.soul_gold or F.rgba.crystal_violet,
                label     = sl.mastered and 'MASTERED' or 'IN PROGRESS',
                valueText = string.format('%d / %d', sl.spent, sl.cap),
                fontScale = 0.74 * s,
            })
        else
            F.drawShadowText(imgui, dl, tx, sy + 12 * s,
                string.format('SLOT %d  |  OPEN MASTERY SLOT', i), F.u32.text_secondary, 0.88 * s, 'l')
            F.drawShadowText(imgui, dl, tx, sy + 36 * s,
                F.fitText(imgui, 'Press [A] or click to forge in The Soulforge.', tw, 0.76 * s), F.u32.text_muted, 0.76 * s, 'l')
        end
    end

    -- Reset Spec action button at bottom of Left panel
    local actH = math.floor(38 * s)
    local actY = bodyY + bodyH - pad - actH
    if self.region == 'confirm_reset' then
        local cH = math.floor(72 * s)
        local cY = bodyY + bodyH - pad - cH
        F.drawOrnatePanel(dl, x + pad, cY, slotW, cH, {
            fillTop = F.u32.midnight_alt, fillBot = F.u32.abyss_solid,
            border = F.u32.danger, corners = false, shadow = false,
        })
        F.drawShadowText(imgui, dl, x + pad + 10 * s, cY + 8 * s,
            F.fitText(imgui, 'Reset ALL Soulforge talents for ' .. soulName .. '?', slotW - 20 * s, 0.80 * s),
            F.u32.soul_gold_bright, 0.80 * s, 'l')
        local halfW = math.floor((slotW - 22 * s) * 0.5)
        local by = cY + cH - math.floor(30 * s) - 7 * s
        local bh = math.floor(28 * s)
        if F.drawBeveledCtaButton(imgui, dl, '##st_rst_ok', x + pad + 8 * s, by, halfW, bh,
            'CONFIRM', 'danger', { focused = (self.confirm_btn == 1), fontScale = 0.80 * s }) then
            self.region = 'slots'
            self.actions.resetAll()
        end
        if F.drawActionButton(imgui, dl, '##st_rst_no', x + pad + 14 * s + halfW, by, halfW, bh,
            (self.confirm_btn == 2 and '> ' or '') .. 'CANCEL', 'neutral', { fontScale = 0.80 * s }) then
            self.region = 'slots'
        end
    else
        if F.drawBeveledCtaButton(imgui, dl, '##st_rst_btn', x + pad, actY, slotW, actH,
            spent > 0 and 'Reset Spec Talents [X]' or 'Sync Talents [X]',
            spent > 0 and 'danger' or 'cyan', { fontScale = 0.88 * s }) then
            if spent > 0 then
                self.region = 'confirm_reset'
                self.confirm_btn = 2
            else
                self.actions.sync()
            end
        end
    end

    -- 2. Center Panel: Invested Talent Nodes across synced Weapon Skills
    local midPanelX = x + leftW + gap
    local nodesFocused = (self.region == 'nodes')
    F.drawOrnatePanel(dl, midPanelX, bodyY, midW, bodyH, {
        fillTop   = F.abgr(F.hex('#101628', 0.94)),
        fillBot   = F.abgr(F.hex('#080C17', 0.97)),
        border    = nodesFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent    = nodesFocused and F.u32.aether_cyan or F.u32.soul_gold,
        thickness = nodesFocused and 1.8 or 1.3,
        corners   = true,
        shadow    = false,
    })

    F.drawShadowText(imgui, dl, midPanelX + pad, bodyY + 12 * s,
        nodesFocused and '> INVESTED TALENT NODES' or 'INVESTED TALENT NODES',
        nodesFocused and F.u32.aether_cyan or F.u32.soul_gold_bright, 1.04 * s, 'l')
    F.drawShadowText(imgui, dl, midPanelX + midW - pad, bodyY + 15 * s,
        string.format('%d ACTIVE', #nodes), F.u32.aether_cyan, 0.84 * s, 'r')
    F.drawDivider(dl, midPanelX + pad, bodyY + 38 * s, midW - pad * 2, nodesFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    local listY = bodyY + 48 * s
    local listH = math.max(100, bodyH - 64 * s)
    imgui.SetCursorScreenPos({ midPanelX + pad, listY })
    if imgui.BeginChild('##st_nodes_list', { midW - pad * 2, listH }, 0) then
        local cdl = imgui.GetWindowDrawList()
        local rowW = math.max(160, midW - pad * 2 - 12 * s)
        local rowH = math.floor(66 * s)
        if #nodes == 0 then
            F.drawShadowText(imgui, cdl, midPanelX + pad + 10 * s, listY + 16 * s,
                'No invested talent nodes loaded yet.', F.u32.text_primary, 0.94 * s, 'l')
            F.drawShadowText(imgui, cdl, midPanelX + pad + 10 * s, listY + 42 * s,
                'Open Weapon Mastery to awaken techniques on the Soulforge constellation.',
                F.u32.text_secondary, 0.84 * s, 'l')
        else
            for idx, nd in ipairs(nodes) do
                local rx, ry = F.toXY(imgui.GetCursorScreenPos())
                local focused = nodesFocused and (self.node_index == idx)
                imgui.InvisibleButton('##st_nd_' .. nd.wsId .. '_' .. nd.key, { rowW, rowH })
                local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false
                if imgui.IsItemClicked and imgui.IsItemClicked(0) then
                    self.region = 'nodes'
                    self.node_index = idx
                    if type(self.on_jump_to_ws) == 'function' then
                        self.on_jump_to_ws(nd.wsId, nd.key)
                    end
                end
                local maxed = nd.rank >= nd.maxRank
                local rh = rowH - 6
                local bg = focused and F.u32.midnight_selected or (hovered and F.u32.midnight_alt or F.abgr(F.hex('#0D1221', 0.90)))
                local border = focused and F.u32.aether_cyan or (maxed and F.u32.soul_gold or F.u32.border_strong)
                cdl:AddRectFilled({ rx, ry }, { rx + rowW, ry + rh }, bg, 5)
                cdl:AddRect({ rx, ry }, { rx + rowW, ry + rh }, border, 5, 0, focused and 1.9 or 1.1)
                if focused then
                    cdl:AddRectFilled({ rx + 1, ry + 5 }, { rx + 4, ry + rh - 5 }, F.u32.aether_cyan, 1)
                end

                F.drawShadowText(imgui, cdl, rx + 12 * s, ry + 8 * s,
                    F.fitText(imgui, nd.name, rowW - 120 * s, 0.96 * s),
                    maxed and F.u32.soul_gold_bright or F.u32.white, 0.96 * s, 'l')
                F.drawShadowText(imgui, cdl, rx + rowW - 12 * s, ry + 10 * s,
                    string.format('Rank %d / %d', nd.rank, nd.maxRank),
                    maxed and F.u32.soul_gold_bright or F.u32.aether_cyan, 0.82 * s, 'r')
                F.drawShadowText(imgui, cdl, rx + 12 * s, ry + 32 * s,
                    F.fitText(imgui, string.format('%s (Tier %d) | %s', nd.wsName, nd.tier, nd.desc), rowW - 32 * s, 0.78 * s),
                    F.u32.text_secondary, 0.78 * s, 'l')
            end
        end
    end
    imgui.EndChild()

    -- 3. Right Panel: Focused Talent & Live Soul Telemetry Inspector
    if rightW > 0 then
        local rx = midPanelX + midW + gap
        F.drawOrnatePanel(dl, rx, bodyY, rightW, bodyH, {
            texId      = inspTex,
            texTint    = F.abgr(F.rgba.white, 0.26),
            scrimAlpha = 0.72,
            border     = F.u32.soul_gold_dim,
            accent     = F.u32.crystal_violet,
            corners    = true,
            shadow     = false,
        })

        F.drawShadowText(imgui, dl, rx + pad, bodyY + 12 * s, 'TALENT & SOUL DETAILS', F.u32.soul_gold_bright, 1.04 * s, 'l')
        F.drawDivider(dl, rx + pad, bodyY + 38 * s, rightW - pad * 2, F.u32.crystal_violet)

        local iy = bodyY + 50 * s
        local innerW = rightW - pad * 2
        local focusedNode = nodes[self.node_index]
        if focusedNode then
            F.drawShadowText(imgui, dl, rx + pad, iy, F.fitText(imgui, focusedNode.name, innerW, 1.12 * s), F.u32.white, 1.12 * s, 'l')
            iy = iy + 26 * s
            F.drawShadowText(imgui, dl, rx + pad, iy,
                string.format('%s  |  Tier %d  |  Rank %d/%d', focusedNode.wsName, focusedNode.tier, focusedNode.rank, focusedNode.maxRank),
                F.u32.aether_cyan, 0.84 * s, 'l')
            iy = iy + 24 * s
            local chars = math.max(20, math.floor(innerW / (7.8 * s)))
            for _, line in ipairs(F.wrapLines(focusedNode.desc, chars, 5)) do
                F.drawShadowText(imgui, dl, rx + pad, iy, line, F.u32.text_primary, 0.86 * s, 'l')
                iy = iy + math.floor(19 * s)
            end
            iy = iy + 14 * s
        else
            F.drawShadowText(imgui, dl, rx + pad, iy, 'Select a Mastery Slot or Talent Node to inspect.', F.u32.text_secondary, 0.86 * s, 'l')
            iy = iy + 28 * s
        end

        F.drawDivider(dl, rx + pad, iy, innerW, F.u32.soul_gold_dim)
        iy = iy + 14 * s
        F.drawShadowText(imgui, dl, rx + pad, iy, 'LIVE SOUL TELEMETRY', F.u32.crystal_violet_bright, 0.90 * s, 'l')
        iy = iy + 24 * s

        local kvCount = 0
        local keys = {}
        for k in pairs(self.hud_kv) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            if kvCount < 6 then
                dl:AddRectFilled({ rx + pad, iy - 2 }, { rx + rightW - pad, iy + 22 * s }, F.abgr(F.hex('#0B101E', 0.85)), 4)
                F.drawShadowText(imgui, dl, rx + pad + 8 * s, iy + 2 * s,
                    F.fitText(imgui, string.upper(tostring(k)), innerW * 0.55, 0.80 * s), F.u32.text_secondary, 0.80 * s, 'l')
                F.drawShadowText(imgui, dl, rx + rightW - pad - 8 * s, iy + 2 * s,
                    F.fitText(imgui, tostring(self.hud_kv[k]), innerW * 0.42, 0.84 * s), F.u32.soul_gold_bright, 0.84 * s, 'r')
                iy = iy + math.floor(28 * s)
                kvCount = kvCount + 1
            end
        end
        if kvCount == 0 then
            F.drawShadowText(imgui, dl, rx + pad, iy, 'Waiting for live [OXHUD] server telemetry.', F.u32.text_muted, 0.82 * s, 'l')
        end
    end
end

return SoulTalents
