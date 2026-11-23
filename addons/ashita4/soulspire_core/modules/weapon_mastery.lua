-- SoulspireXI Core Module: Weapon Mastery (The Soulforge)
-- Reuses soulspire_talents/soulforge_state.lua and soulspire_talents/soulforge_ui.lua
-- with full directional gamepad, keyboard, and mouse navigation.

local WeaponMastery = {}
WeaponMastery.__index = WeaponMastery

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

function WeaponMastery.new(sf_state, sf_actions, sf_ui)
    return setmetatable({
        state         = sf_state,
        actions       = sf_actions,
        ui            = sf_ui,
        region        = 'arsenal', -- 'arsenal' | 'skillchains' | 'tree' | 'inspector' | 'confirm'
        arsenal_index = 1,
        sc_slot       = 1,
        node_key      = nil,
        inspector_btn = 1,
        confirm_btn   = 1,
        prev_region   = 'tree',
    }, WeaponMastery)
end

function WeaponMastery:has_modal()
    return self.state and self.state.ui and self.state.ui.confirmAction ~= nil
end

function WeaponMastery:_ensure_valid_focus()
    local rows = self.actions.filtered()
    if #rows == 0 then
        self.arsenal_index = 1
    else
        self.arsenal_index = clamp(self.arsenal_index, 1, #rows)
        -- Keep arsenal cursor aligned with selectedWsId if nothing explicit was moved
        if self.state.selectedWsId ~= nil then
            for i, ws in ipairs(rows) do
                if ws.id == self.state.selectedWsId then
                    if self.region ~= 'arsenal' then
                        self.arsenal_index = i
                    end
                    break
                end
            end
        end
    end

    local d = self.state.wsDetail
    if d then
        local grid = self.ui.getTreeGrid(d)
        local valid_node = (self.node_key ~= nil and d.byKey and d.byKey[self.node_key] ~= nil)
            and not (self.ui.isEvolutionTree(d) and self.ui.isSkillchainNode(d.byKey[self.node_key]))
        if not valid_node then
            if self.state.inspectedNodeKey and d.byKey and d.byKey[self.state.inspectedNodeKey] then
                self.node_key = self.state.inspectedNodeKey
            elseif grid[1] and grid[1].nodes[1] then
                self.node_key = grid[1].nodes[1].key
            else
                self.node_key = nil
            end
        end
        if self.node_key then
            self.state.inspectedNodeKey = self.node_key
        end

        local slots = self.ui.getSkillchainSlots(d)
        if #slots > 0 then
            self.sc_slot = clamp(self.sc_slot, 1, #slots)
        else
            self.sc_slot = 1
        end
    else
        self.node_key = nil
    end

    if self:has_modal() then
        self.region = 'confirm'
    elseif self.region == 'confirm' then
        self.region = self.prev_region or 'tree'
    end
end

function WeaponMastery:_find_grid_pos(grid, key)
    for ti, t in ipairs(grid) do
        for ci, n in ipairs(t.nodes) do
            if n.key == key then
                return ti, ci
            end
        end
    end
    return 1, 1
end

function WeaponMastery:_evaluate_focused_node()
    local d = self.state.wsDetail
    if not d or not self.node_key or not d.byKey then return nil, nil end
    local node = d.byKey[self.node_key]
    if not node then return nil, nil end
    local isEvo = self.ui.isEvolutionTree(d)
    local otherChosen = false
    if isEvo then
        for _, sib in ipairs(d.nodes or {}) do
            if sib.tier == node.tier and sib.key ~= node.key and (sib.rank or 0) > 0 then
                otherChosen = true
                break
            end
        end
    end
    return node, self.ui.evaluateNode(self.state, d, node, otherChosen)
end

function WeaponMastery:focus_ws_and_node(ws_id, node_key)
    if ws_id ~= nil then
        self.actions.requestWS(ws_id)
    end
    if node_key then
        self.node_key = node_key
        self.state.inspectedNodeKey = node_key
        self.region = 'tree'
    elseif self.state.wsDetail then
        self.region = 'tree'
    else
        self.region = 'arsenal'
    end
    self:_ensure_valid_focus()
end

function WeaponMastery:on_open()
    if not self.state.synced then
        self.actions.sync()
    else
        self.actions.refreshState()
        if self.state.selectedWsId ~= nil then
            self.actions.requestWS(self.state.selectedWsId)
        end
    end
    self:_ensure_valid_focus()
end

function WeaponMastery:on_activate()
    self:on_open()
end

function WeaponMastery:on_deactivate()
    self.ui.resetTransientState(self.state)
    if self.region == 'confirm' then
        self.region = self.prev_region or 'tree'
    end
end

function WeaponMastery:on_close()
    self:on_deactivate()
end

function WeaponMastery:on_action(action)
    self:_ensure_valid_focus()
    local st = self.state
    local ui = st.ui

    -- 1. Confirmation Modal captures all directional/confirm/cancel inputs exclusively
    if self:has_modal() then
        local ca = ui.confirmAction
        if action == 'left' or action == 'up' then
            self.confirm_btn = 1
            return true
        elseif action == 'right' or action == 'down' then
            self.confirm_btn = 2
            return true
        elseif action == 'cancel' then
            ui.confirmAction = nil
            self.region = self.prev_region or 'inspector'
            return true
        elseif action == 'confirm' then
            local d = st.wsDetail
            local node = d and d.byKey and d.byKey[ca.nodeKey]
            ui.confirmAction = nil
            self.region = self.prev_region or 'tree'
            if self.confirm_btn == 1 and d and node then
                if ca.kind == 'refund' then
                    self.actions.refundNode(d.id, node)
                else
                    self.actions.investNode(d.id, node)
                end
            end
            return true
        end
        return true
    end

    -- Tab cycles focus regions cleanly on keyboard
    if action == 'focus_dock' then
        local order = { 'arsenal', 'skillchains', 'tree', 'inspector' }
        local cur = 1
        for i, r in ipairs(order) do
            if r == self.region then cur = i; break end
        end
        local nxt = (cur % #order) + 1
        if order[nxt] == 'skillchains' and #(self.ui.getSkillchainSlots(st.wsDetail)) == 0 then
            nxt = (nxt % #order) + 1
        end
        if not st.wsDetail and order[nxt] ~= 'arsenal' then
            self.region = 'arsenal'
        else
            self.region = order[nxt]
        end
        return true
    end

    -- 2. Arsenal Region (left rail WS browser)
    if self.region == 'arsenal' then
        local rows = self.actions.filtered()
        if action == 'up' then
            if #rows > 0 then
                self.arsenal_index = ((self.arsenal_index - 2) % #rows) + 1
            end
            return true
        elseif action == 'down' then
            if #rows > 0 then
                self.arsenal_index = (self.arsenal_index % #rows) + 1
            end
            return true
        elseif action == 'confirm' or action == 'right' then
            local ws = rows[self.arsenal_index]
            if ws then
                if st.selectedWsId ~= ws.id or not st.wsDetail then
                    st.inspectedNodeKey = nil
                    ui.confirmAction = nil
                    ui.panX, ui.panY = 0, 0
                    self.node_key = nil
                    self.actions.requestWS(ws.id)
                end
                if st.wsDetail or action == 'confirm' then
                    self.region = 'tree'
                    self:_ensure_valid_focus()
                end
            end
            return true
        elseif action == 'context' then
            local sk = self.actions.cycleSkillFilter(1)
            self.arsenal_index = 1
            if sk and self.actions.setStatus then
                self.actions.setStatus('Arsenal Filter: ' .. tostring(sk.name))
            end
            return true
        elseif action == 'left' then
            return true
        elseif action == 'cancel' then
            return false -- let Core close cleanly
        end
        return false
    end

    -- 3. Skillchain Forging Tiers (T1..T4)
    if self.region == 'skillchains' then
        local d = st.wsDetail
        local slots = self.ui.getSkillchainSlots(d)
        if #slots == 0 then
            self.region = 'tree'
            return true
        end
        if action == 'left' then
            if self.sc_slot > 1 then
                self.sc_slot = self.sc_slot - 1
            else
                self.region = 'arsenal'
            end
            return true
        elseif action == 'right' then
            if self.sc_slot < #slots then
                self.sc_slot = self.sc_slot + 1
            else
                self.region = 'inspector'
                self.inspector_btn = 1
            end
            return true
        elseif action == 'down' then
            self.region = 'tree'
            return true
        elseif action == 'up' then
            return true
        elseif action == 'confirm' then
            local sl = slots[self.sc_slot]
            if d and sl then
                self.actions.cycleSkillchain(d.id, sl.tier, 1)
            end
            return true
        elseif action == 'context' then
            local sl = slots[self.sc_slot]
            if d and sl then
                self.actions.cycleSkillchain(d.id, sl.tier, 2)
            end
            return true
        elseif action == 'cancel' then
            self.region = 'tree'
            return true
        end
        return false
    end

    -- 4. Talent Tree 2D Grid
    if self.region == 'tree' then
        local d = st.wsDetail
        local grid = self.ui.getTreeGrid(d)
        if #grid == 0 then
            self.region = 'arsenal'
            return true
        end
        local ti, ci = self:_find_grid_pos(grid, self.node_key)
        local row = grid[ti]

        if action == 'left' then
            if ci > 1 then
                self.node_key = row.nodes[ci - 1].key
                st.inspectedNodeKey = self.node_key
            else
                self.region = 'arsenal'
            end
            return true
        elseif action == 'right' then
            if ci < #row.nodes then
                self.node_key = row.nodes[ci + 1].key
                st.inspectedNodeKey = self.node_key
            else
                self.region = 'inspector'
                self.inspector_btn = 1
            end
            return true
        elseif action == 'up' then
            if ti > 1 then
                local prevRow = grid[ti - 1]
                local targetCol = clamp(ci, 1, #prevRow.nodes)
                self.node_key = prevRow.nodes[targetCol].key
                st.inspectedNodeKey = self.node_key
            else
                local slots = self.ui.getSkillchainSlots(d)
                if #slots > 0 then
                    self.region = 'skillchains'
                    self.sc_slot = clamp(ci, 1, #slots)
                end
            end
            return true
        elseif action == 'down' then
            if ti < #grid then
                local nextRow = grid[ti + 1]
                local targetCol = clamp(ci, 1, #nextRow.nodes)
                self.node_key = nextRow.nodes[targetCol].key
                st.inspectedNodeKey = self.node_key
            end
            return true
        elseif action == 'confirm' then
            local node, eval = self:_evaluate_focused_node()
            if node and eval then
                st.inspectedNodeKey = node.key
                self.region = 'inspector'
                self.inspector_btn = 1
            end
            return true
        elseif action == 'context' then
            local node, eval = self:_evaluate_focused_node()
            if node and eval and eval.canRefund and d then
                self.prev_region = 'tree'
                ui.confirmAction = { kind = 'refund', wsId = d.id, nodeKey = node.key }
                self.region = 'confirm'
                self.confirm_btn = 1
            else
                self.actions.sync()
            end
            return true
        elseif action == 'cancel' then
            self.region = 'arsenal'
            return true
        end
        return false
    end

    -- 5. Talent Inspector Region
    if self.region == 'inspector' then
        local d = st.wsDetail
        local node, eval = self:_evaluate_focused_node()
        local has_two_btns = (eval ~= nil and eval.canUpgrade and eval.canRefund)

        if action == 'left' or action == 'cancel' then
            self.region = 'tree'
            return true
        elseif action == 'up' then
            self.inspector_btn = has_two_btns and 2 or 1
            return true
        elseif action == 'down' then
            self.inspector_btn = 1
            return true
        elseif action == 'right' then
            return true
        elseif action == 'confirm' then
            if d and node and eval then
                if eval.canUpgrade and self.inspector_btn == 1 then
                    self.prev_region = 'inspector'
                    ui.confirmAction = { kind = 'invest', wsId = d.id, nodeKey = node.key }
                    self.region = 'confirm'
                    self.confirm_btn = 1
                elseif eval.canRefund and ((not eval.canUpgrade) or self.inspector_btn == 2) then
                    self.prev_region = 'inspector'
                    ui.confirmAction = { kind = 'refund', wsId = d.id, nodeKey = node.key }
                    self.region = 'confirm'
                    self.confirm_btn = 1
                end
            end
            return true
        elseif action == 'context' then
            self.actions.sync()
            return true
        end
        return false
    end

    return false
end

function WeaponMastery:get_hints()
    if self:has_modal() then
        return '[D-Pad] Confirm/Cancel   [A] Execute   [B] Cancel'
    elseif self.region == 'arsenal' then
        return '[D-Pad] Select WS   [A] Open Tree   [X] Filter Weapon   [LB/RB] Switch Module   [Y] Help   [B] Close'
    elseif self.region == 'skillchains' then
        return '[D-Pad] Select Slot/Tree   [A] Next SC   [X] Prev SC   [B] Back to Tree   [LB/RB] Switch Module'
    elseif self.region == 'inspector' then
        return '[A] Forge / Refund   [D-Pad] Select Action   [Left/B] Back to Tree   [X] Sync   [Y] Help'
    else
        return '[D-Pad/Stick] Navigate Tree   [A] Inspect/Upgrade   [X] Refund/Sync   [B] Arsenal   [LB/RB] Modules   [Y] Help'
    end
end

function WeaponMastery:draw(_imgui, _dl, _F, L, x, y, w, h)
    self:_ensure_valid_focus()
    local nav = {
        region        = self.region,
        arsenal_index = self.arsenal_index,
        sc_slot       = self.sc_slot,
        node_key      = self.node_key,
        inspector_btn = self.inspector_btn,
        confirm_btn   = self.confirm_btn,
        on_focus      = function(reg, arg1)
            self.region = reg
            if reg == 'arsenal' and type(arg1) == 'number' then
                self.arsenal_index = arg1
            elseif reg == 'tree' and type(arg1) == 'string' then
                self.node_key = arg1
            elseif reg == 'confirm' and type(arg1) == 'number' then
                self.confirm_btn = arg1
            end
        end,
    }
    self.ui.drawEmbedded(self.state, self.actions, L, x, y, w, h, nav)
end

return WeaponMastery
