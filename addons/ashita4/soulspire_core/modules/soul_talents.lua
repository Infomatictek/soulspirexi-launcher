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
    local self = setmetatable({
        state            = sf_state,
        actions          = sf_actions,
        ui               = sf_ui,
        soul_registry    = opts.soul_registry,
        data_service     = opts.data_service,
        character_state  = opts.character_state,
        on_jump_to_ws    = opts.on_jump_to_ws, -- fn(wsId, nodeKey)
        region           = 'slots', -- 'slots' | 'nodes' | 'confirm_reset'
        slot_index       = 1,
        node_index       = 1,
        confirm_btn      = 1,
        hud_soul_key     = '',
        hud_kv           = {},
        hud_synced_at    = 0,
        _sub_ids         = {},
    }, SoulTalents)

    if self.character_state then
        self.character_state:onSessionReset(function()
            self.hud_soul_key = ''
            self.hud_kv = {}
            self.hud_synced_at = 0
            self.slot_index = 1
            self.node_index = 1
            self.region = 'slots'
        end)
        self._sub_ids[#self._sub_ids + 1] = self.character_state:subscribe(
            function(snap)
                local hud = snap.confirmed and snap.confirmed.hud or {}
                return { soulKey = hud.soulKey, syncedAt = hud.syncedAt }
            end,
            function(_val, _prev, snap)
                local hud = snap.confirmed and snap.confirmed.hud
                if hud then
                    self.hud_soul_key = hud.soulKey or ''
                    self.hud_kv = hud.kv or {}
                    self.hud_synced_at = hud.syncedAt or 0
                end
            end,
            { owner = 'soul_talents' }
        )
    end

    return self
end

function SoulTalents:destroy()
    if self.character_state and self.character_state.unsubscribe then
        for _, id in ipairs(self._sub_ids or {}) do
            self.character_state:unsubscribe(id)
        end
    end
    self._sub_ids = {}
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
    if self.character_state then
        self.character_state:observeHudTelemetry(soul, kv, self.hud_synced_at)
    end
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
    if self.character_state then
        -- Route through shared CharacterState SyncCoordinator: zero network traffic when fresh!
        self.character_state:requestRefresh('progression', 'high', { reason = 'soul_talents_open' })
    else
        if not self.state.synced or #(self.state.catalog or {}) == 0 then
            self.actions.sync()
        else
            self.actions.refreshState()
        end
    end
end

function SoulTalents:on_activate(_focus, opts)
    if not (opts and opts.from_open) then
        self:on_open()
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

function SoulTalents:draw(imgui, dl, F, L, x, y, w, h)
    local s   = L.uiScale or 1.0
    local gap = L.gap or math.floor(8 * s)
    local pad = math.floor(14 * s)
    local st  = self.state

    local slots = self.ui.getInvestedWeaponskills(st)
    local nodes = self:get_invested_nodes()
    self.slot_index = clamp(self.slot_index, 1, self.ui.MAX_SPEC_WS_SLOTS)
    self.node_index = clamp(self.node_index, 1, math.max(1, #nodes))

    -- Resolve canonical Soul metadata (prefer verified local cache via DataService)
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

    local leftW  = math.floor(w * (L.mode == 'focused' and 0.42 or 0.31))
    local rightW = math.floor(w * (L.mode == 'focused' and 0.00 or 0.28))
    local midW   = math.max(200, w - leftW - rightW - (rightW > 0 and gap * 2 or gap))

    -- 1. Left Panel: Active Soul Spec Ledger & 4-WS Mastery Loadout Slots
    local slotsFocused = (self.region == 'slots')
    F.drawPanelFrame(dl, x, y, leftW, h, {
        fillTop   = F.u32.midnight,
        fillBot   = F.u32.abyss,
        border    = slotsFocused and F.u32.aether_cyan or F.u32.border_subtle,
        accent    = slotsFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        thickness = slotsFocused and 1.6 or 1.1,
        corners   = (L.ornamentLevel >= 1),
        shadow    = false,
    })

    F.drawShadowText(imgui, dl, x + pad, y + 10 * s,
        slotsFocused and '> SOUL SPEC LOADOUT' or 'SOUL SPEC LOADOUT',
        slotsFocused and F.u32.aether_cyan or F.u32.soul_gold, 0.94 * s, 'l')
    F.drawDivider(dl, x + pad, y + 32 * s, leftW - pad * 2, slotsFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    -- Soul identity banner
    local cy = y + 42 * s
    F.drawShadowText(imgui, dl, x + pad, cy, F.fitText(imgui, soulName:upper(), leftW - pad * 2, 1.02 * s), F.u32.soul_gold_bright, 1.02 * s, 'l')
    cy = cy + 20 * s
    F.drawShadowText(imgui, dl, x + pad, cy,
        F.fitText(imgui, string.format('%s  Lv.%d  |  %s', st.jobKey or '---', st.jobLevel or 1, soulRole), leftW - pad * 2, 0.76 * s),
        F.u32.crystal_violet_bright, 0.76 * s, 'l')
    cy = cy + 22 * s

    -- Points progress gauge
    local avail  = tonumber(st.avail) or 0
    local spent  = tonumber(st.spent) or 0
    local earned = math.max(1, tonumber(st.earned) or (avail + spent))
    F.drawSegmentedGauge(imgui, dl, x + pad, cy, leftW - pad * 2, math.floor(18 * s), spent, earned, {
        fill      = avail > 0 and F.rgba.aether_cyan or F.rgba.soul_gold,
        border    = F.u32.border_strong,
        notches   = 4,
        label     = string.format('%d AVAIL', avail),
        valueText = string.format('%d / %d SPENT', spent, earned),
        fontScale = 0.74 * s,
    })
    cy = cy + 28 * s

    -- 4 Spec WS Mastery Slots
    F.drawShadowText(imgui, dl, x + pad, cy,
        string.format('MASTERY SLOTS (%d / %d)', #slots, self.ui.MAX_SPEC_WS_SLOTS),
        F.u32.text_secondary, 0.76 * s, 'l')
    cy = cy + 20 * s

    local slotH = math.floor(54 * s)
    local slotW = leftW - pad * 2
    for i = 1, self.ui.MAX_SPEC_WS_SLOTS do
        local sl = slots[i]
        local focused = slotsFocused and (self.slot_index == i)
        local sy = cy + (i - 1) * (slotH + math.floor(6 * s))

        imgui.SetCursorScreenPos({ x + pad, sy })
        if imgui.InvisibleButton('##st_slot_' .. i, { slotW, slotH }) then
            self.region = 'slots'
            self.slot_index = i
            if type(self.on_jump_to_ws) == 'function' then
                self.on_jump_to_ws(sl and sl.id or nil, nil)
            end
        end
        local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false
        local bg = focused and F.u32.midnight_selected or (hovered and F.u32.midnight_alt or F.u32.midnight_deep)
        local border = focused and F.u32.aether_cyan
            or (sl and (sl.mastered and F.u32.soul_gold or F.u32.crystal_violet) or F.u32.border_subtle)

        dl:AddRectFilled({ x + pad, sy }, { x + pad + slotW, sy + slotH }, bg, 5)
        dl:AddRect({ x + pad, sy }, { x + pad + slotW, sy + slotH }, border, 5, 0, focused and 1.8 or 1.1)
        if focused then
            dl:AddRectFilled({ x + pad + 1, sy + 5 }, { x + pad + 4, sy + slotH - 5 }, F.u32.aether_cyan, 1)
        end

        if sl then
            F.drawShadowText(imgui, dl, x + pad + 10 * s, sy + 7 * s,
                F.fitText(imgui, string.format('SLOT %d  |  %s', i, sl.name), slotW - 20 * s, 0.86 * s),
                focused and F.u32.soul_gold_bright or F.u32.text_primary, 0.86 * s, 'l')
            F.drawSegmentedGauge(imgui, dl, x + pad + 10 * s, sy + 29 * s, slotW - 20 * s, math.floor(15 * s), sl.spent, sl.cap, {
                fill      = sl.mastered and F.rgba.soul_gold or F.rgba.crystal_violet,
                label     = sl.mastered and 'MASTERED' or 'IN PROGRESS',
                valueText = string.format('%d / %d', sl.spent, sl.cap),
                fontScale = 0.68 * s,
            })
        else
            F.drawShadowText(imgui, dl, x + pad + 10 * s, sy + 10 * s,
                string.format('SLOT %d  |  OPEN MASTERY SLOT', i), F.u32.text_muted, 0.82 * s, 'l')
            F.drawShadowText(imgui, dl, x + pad + 10 * s, sy + 28 * s,
                'Press [A] or click to forge a Weapon Skill in The Soulforge.', F.u32.text_disabled, 0.70 * s, 'l')
        end
    end

    -- Reset Spec action button at bottom of Left panel
    local actH = math.floor(30 * s)
    local actY = y + h - pad - actH
    if self.region == 'confirm_reset' then
        local cH = math.floor(62 * s)
        local cY = y + h - pad - cH
        dl:AddRectFilled({ x + pad, cY }, { x + leftW - pad, cY + cH }, F.u32.midnight_alt, 5)
        dl:AddRect({ x + pad, cY }, { x + leftW - pad, cY + cH }, F.u32.danger, 5, 0, 1.5)
        F.drawShadowText(imgui, dl, x + pad + 8 * s, cY + 6 * s,
            'Reset ALL Soulforge talents for ' .. soulName .. '?', F.u32.soul_gold_bright, 0.74 * s, 'l')
        local halfW = math.floor((slotW - 18 * s) * 0.5)
        local by = cY + cH - math.floor(26 * s) - 6 * s
        local bh = math.floor(24 * s)
        if F.drawActionButton(imgui, dl, '##st_rst_ok', x + pad + 6 * s, by, halfW, bh,
            (self.confirm_btn == 1 and '> ' or '') .. 'CONFIRM', 'danger', { fontScale = 0.74 * s }) then
            self.region = 'slots'
            self.actions.resetAll()
        end
        if F.drawActionButton(imgui, dl, '##st_rst_no', x + pad + 12 * s + halfW, by, halfW, bh,
            (self.confirm_btn == 2 and '> ' or '') .. 'CANCEL', 'neutral', { fontScale = 0.74 * s }) then
            self.region = 'slots'
        end
    else
        if F.drawActionButton(imgui, dl, '##st_rst_btn', x + pad, actY, slotW, actH,
            spent > 0 and 'RESET SPEC TALENTS [X]' or 'SYNC TALENTS [X]',
            spent > 0 and 'danger' or 'cyan', { fontScale = 0.78 * s }) then
            if spent > 0 then
                self.region = 'confirm_reset'
                self.confirm_btn = 2
            else
                self.actions.sync()
            end
        end
    end

    -- 2. Center Panel: Invested Talent Nodes across synced Weapon Skills
    local midX = x + leftW + gap
    local nodesFocused = (self.region == 'nodes')
    F.drawPanelFrame(dl, midX, y, midW, h, {
        fillTop   = F.u32.midnight,
        fillBot   = F.u32.abyss,
        border    = nodesFocused and F.u32.aether_cyan or F.u32.soul_gold_dim,
        accent    = nodesFocused and F.u32.aether_cyan or F.u32.soul_gold,
        thickness = nodesFocused and 1.6 or 1.1,
        corners   = (L.ornamentLevel >= 1),
        shadow    = false,
    })

    F.drawShadowText(imgui, dl, midX + pad, y + 10 * s,
        nodesFocused and '> INVESTED TALENT NODES' or 'INVESTED TALENT NODES',
        nodesFocused and F.u32.aether_cyan or F.u32.soul_gold, 0.94 * s, 'l')
    F.drawShadowText(imgui, dl, midX + midW - pad, y + 12 * s,
        string.format('%d ACTIVE', #nodes), F.u32.aether_cyan, 0.78 * s, 'r')
    F.drawDivider(dl, midX + pad, y + 32 * s, midW - pad * 2, nodesFocused and F.u32.aether_cyan or F.u32.soul_gold_dim)

    local listY = y + 42 * s
    local listH = math.max(100, h - 56 * s)
    imgui.SetCursorScreenPos({ midX + pad, listY })
    if imgui.BeginChild('##st_nodes_list', { midW - pad * 2, listH }, ImGuiChildFlags_None or 0) then
        local cdl = imgui.GetWindowDrawList()
        local rowW = math.max(160, midW - pad * 2 - 12 * s)
        local rowH = math.floor(54 * s)
        if #nodes == 0 then
            F.drawShadowText(imgui, cdl, midX + pad + 8 * s, listY + 12 * s,
                'No talent nodes loaded yet.', F.u32.text_secondary, 0.86 * s, 'l')
            F.drawShadowText(imgui, cdl, midX + pad + 8 * s, listY + 34 * s,
                'Select a Weapon Skill in Weapon Mastery to inspect or forge techniques.',
                F.u32.text_muted, 0.76 * s, 'l')
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
                local bg = focused and F.u32.midnight_selected or (hovered and F.u32.midnight_alt or F.u32.midnight_deep)
                local border = focused and F.u32.aether_cyan or (maxed and F.u32.soul_gold or F.u32.border_subtle)
                cdl:AddRectFilled({ rx, ry }, { rx + rowW, ry + rowH - 4 }, bg, 5)
                cdl:AddRect({ rx, ry }, { rx + rowW, ry + rowH - 4 }, border, 5, 0, focused and 1.8 or 1.0)
                if focused then
                    cdl:AddRectFilled({ rx + 1, ry + 4 }, { rx + 4, ry + rowH - 8 }, F.u32.aether_cyan, 1)
                end

                F.drawShadowText(imgui, cdl, rx + 10 * s, ry + 6 * s,
                    F.fitText(imgui, nd.name, rowW - 110 * s, 0.88 * s),
                    maxed and F.u32.soul_gold_bright or F.u32.text_primary, 0.88 * s, 'l')
                F.drawShadowText(imgui, cdl, rx + rowW - 10 * s, ry + 7 * s,
                    string.format('Rank %d/%d', nd.rank, nd.maxRank),
                    maxed and F.u32.soul_gold or F.u32.aether_cyan, 0.74 * s, 'r')
                F.drawShadowText(imgui, cdl, rx + 10 * s, ry + 26 * s,
                    F.fitText(imgui, string.format('%s (Ch.%d)  |  %s', nd.wsName, nd.tier, nd.desc), rowW - 20 * s, 0.72 * s),
                    F.u32.text_secondary, 0.72 * s, 'l')
            end
        end
    end
    imgui.EndChild()

    -- 3. Right Panel: Focused Talent / Live Soul Mechanics Inspector
    if rightW > 0 then
        local rx = midX + midW + gap
        F.drawPanelFrame(dl, rx, y, rightW, h, {
            fillTop  = F.u32.midnight,
            fillBot  = F.u32.abyss,
            border   = F.u32.border_subtle,
            accent   = F.u32.crystal_violet,
            corners  = (L.ornamentLevel >= 1),
            shadow   = false,
        })

        F.drawShadowText(imgui, dl, rx + pad, y + 10 * s, 'TALENT & SOUL DETAILS', F.u32.soul_gold, 0.94 * s, 'l')
        F.drawDivider(dl, rx + pad, y + 32 * s, rightW - pad * 2, F.u32.crystal_violet)

        local iy = y + 44 * s
        local innerW = rightW - pad * 2
        local focusedNode = nodes[self.node_index]
        if focusedNode then
            F.drawShadowText(imgui, dl, rx + pad, iy, F.fitText(imgui, focusedNode.name, innerW, 0.96 * s), F.u32.soul_gold_bright, 0.96 * s, 'l')
            iy = iy + 22 * s
            F.drawShadowText(imgui, dl, rx + pad, iy,
                string.format('%s  |  Chapter %d  |  Rank %d/%d', focusedNode.wsName, focusedNode.tier, focusedNode.rank, focusedNode.maxRank),
                F.u32.aether_cyan, 0.76 * s, 'l')
            iy = iy + 20 * s
            local chars = math.max(18, math.floor(innerW / (7.6 * s)))
            for _, line in ipairs(F.wrapLines(focusedNode.desc, chars, 5)) do
                F.drawShadowText(imgui, dl, rx + pad, iy, line, F.u32.text_primary, 0.78 * s, 'l')
                iy = iy + math.floor(16 * s)
            end
            iy = iy + 12 * s
        else
            F.drawShadowText(imgui, dl, rx + pad, iy, 'Select a Spec Slot or Talent Node to inspect.', F.u32.text_secondary, 0.80 * s, 'l')
            iy = iy + 26 * s
        end

        F.drawDivider(dl, rx + pad, iy, innerW, F.u32.border_strong)
        iy = iy + 12 * s
        F.drawShadowText(imgui, dl, rx + pad, iy, 'LIVE SOUL TELEMETRY', F.u32.crystal_violet_bright, 0.80 * s, 'l')
        iy = iy + 20 * s

        local kvCount = 0
        local keys = {}
        for k in pairs(self.hud_kv) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            if kvCount < 6 then
                F.drawShadowText(imgui, dl, rx + pad, iy,
                    F.fitText(imgui, string.format('%s: %s', tostring(k), tostring(self.hud_kv[k])), innerW, 0.76 * s),
                    F.u32.text_secondary, 0.76 * s, 'l')
                iy = iy + math.floor(16 * s)
                kvCount = kvCount + 1
            end
        end
        if kvCount == 0 then
            F.drawShadowText(imgui, dl, rx + pad, iy, 'Waiting for live [OXHUD] server telemetry.', F.u32.text_muted, 0.74 * s, 'l')
        end
    end
end

return SoulTalents
