-- SoulspireXI Phase C — Native VanaCore Weapon Mastery (Soulforge) UI Module
-- Renders the Arsenal list, Talent Node Tree, Inspector, and Skillchain controls
-- with Soulspire dark/gold palette and full mouse + gamepad navigation.

local M = {}

function M.new(soulforge)
    local self = {
        sf = soulforge,
        selected_node_key = nil,
        confirm_reset_ws = false,
        confirm_reset_all = false,
    }

    function self:render(imgui)
        local sf = self.sf
        if not sf or not imgui then return end

        -- Header bar: Spec, Level, Available/Spent/Earned Points, Sync & Reset
        imgui.TextColored({ 0.85, 0.70, 0.25, 1.0 },
            string.format('THE SOULFORGE  |  %s (%s Lv.%d)  |  Available Points: %d  (Spent: %d / Earned: %d)',
                tostring(sf.spec_name), tostring(sf.job_key), tonumber(sf.job_level) or 1,
                tonumber(sf.avail) or 0, tonumber(sf.spent) or 0, tonumber(sf.earned) or 0))
        imgui.SameLine()
        if imgui.SmallButton('Sync') then
            sf:request_sync()
        end
        if sf.last_error then
            imgui.TextColored({ 0.95, 0.35, 0.35, 1.0 }, 'Error: ' .. tostring(sf.last_error))
        else
            imgui.TextColored({ 0.65, 0.80, 0.95, 1.0 }, tostring(sf.status_text or ''))
        end
        imgui.Separator()

        -- Filter bar (Equipped / All Weapons / Skill family)
        for _, sk in ipairs(sf.SKILL_LIST or {}) do
            if sk.id == 0 or sk.id == -1 then
                local is_sel = (sf.selected_skill == sk.id)
                local lbl = is_sel and ('[' .. sk.name .. ']') or sk.name
                if imgui.SmallButton(lbl .. '##sf_flt_' .. sk.id) then
                    sf.selected_skill = sk.id
                end
                imgui.SameLine()
            end
        end
        if imgui.SmallButton((sf.invested_only and '[Invested Only]' or 'Invested Only') .. '##sf_inv') then
            sf.invested_only = not sf.invested_only
        end
        imgui.Separator()

        -- Two-column layout: Left Arsenal List, Right Talent Tree & Node Inspector
        if imgui.BeginChild('##sf_arsenal', { 250, 380 }, true) then
            local rows = sf:filtered_catalog()
            if #rows == 0 then
                imgui.Text('No matching weapon skills.')
                if imgui.Button('Sync Arsenal') then
                    sf:request_sync()
                end
            else
                for _, ws in ipairs(rows) do
                    local pts = sf.spent_by_ws[ws.id] or 0
                    local sel = (sf.selected_ws_id == ws.id)
                    local label = pts > 0
                        and string.format('%s (%d pts)##ws_%d', ws.name, pts, ws.id)
                        or string.format('%s##ws_%d', ws.name, ws.id)
                    if imgui.Selectable(label, sel) then
                        self.selected_node_key = nil
                        sf:request_ws(ws.id)
                    end
                end
            end
        end
        imgui.EndChild()

        imgui.SameLine()

        if imgui.BeginChild('##sf_detail', { 0, 380 }, true) then
            local d = sf.ws_detail
            if not d then
                imgui.Text('Select a Weapon Skill from the Arsenal to inspect and forge talents.')
            else
                imgui.TextColored({ 0.85, 0.70, 0.25, 1.0 },
                    string.format('%s (%s)  |  Spent: %d pts', tostring(d.name), tostring(d.skill_name), tonumber(d.spent) or 0))
                if d.summary and d.summary ~= '' then
                    imgui.Text(tostring(d.summary))
                end
                imgui.Separator()

                -- Node list grouped by tier
                local selected_node = nil
                for _, n in ipairs(d.nodes or {}) do
                    if n.sc_tier == 0 or (n.max_rank or 0) > 0 then
                        local is_sel = (self.selected_node_key == n.key)
                        if is_sel then selected_node = n end
                        local tag = n.can_learn and '[+]' or (n.rank >= n.max_rank and '[MAX]' or '[LOCK]')
                        local lbl = string.format('T%d %s %s (%d/%d)##node_%s',
                            n.tier or 1, tag, tostring(n.name), n.rank or 0, n.max_rank or 1, tostring(n.key))
                        if imgui.Selectable(lbl, is_sel) then
                            self.selected_node_key = n.key
                            selected_node = n
                        end
                    end
                end

                if not selected_node and d.nodes and d.nodes[1] then
                    selected_node = d.nodes[1]
                    self.selected_node_key = selected_node.key
                end

                if selected_node then
                    imgui.Separator()
                    imgui.TextColored({ 0.95, 0.85, 0.45, 1.0 },
                        string.format('%s  (Rank %d / %d, Lv.%d+)',
                            tostring(selected_node.name), selected_node.rank or 0,
                            selected_node.max_rank or 1, selected_node.req_level or 1))
                    imgui.TextWrapped(tostring(selected_node.desc or ''))

                    local busy = (sf.pending_op ~= nil)
                    if not busy and selected_node.can_learn then
                        if imgui.Button('Allocate Point (+1 Rank)##sf_invest_btn') then
                            sf:invest(d.id, selected_node)
                        end
                        imgui.SameLine()
                    end
                    if not busy and (selected_node.rank or 0) > 0 then
                        if imgui.Button('Refund (-1 Rank)##sf_refund_btn') then
                            sf:refund(d.id, selected_node)
                        end
                        imgui.SameLine()
                    end
                    if not busy and (d.spent or 0) > 0 then
                        if imgui.SmallButton('Reset WS##sf_reset_ws') then
                            sf:reset_ws(d.id)
                        end
                    end
                end
            end
        end
        imgui.EndChild()
    end

    return self
end

return M
