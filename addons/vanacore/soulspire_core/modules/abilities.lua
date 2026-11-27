-- SoulspireXI Core Module (VanaCore-Native): Soul Actions & Visibility Inspector
-- Integrates `core/actions.lua` directly into the Core navigation ribbon (`abilities` module)
-- with full dark-fantasy framing and zero Ashita dependencies.

local F = require('core.foundations')

local AbilitiesMod = {}
AbilitiesMod.__index = AbilitiesMod

function AbilitiesMod.new(actions_svc, identity_svc)
    return setmetatable({
        actions  = actions_svc,
        identity = identity_svc,
        selected = 1,
        query    = '',
    }, AbilitiesMod)
end

function AbilitiesMod:on_open() end
function AbilitiesMod:on_activate() end
function AbilitiesMod:on_close() end

function AbilitiesMod:on_action(action)
    if action == 'up' then
        self.selected = math.max(1, self.selected - 1)
        return true
    elseif action == 'down' then
        local rows = (self.actions and self.actions.search) and self.actions:search(self.query, 96) or {}
        local max_idx = math.max(1, #rows)
        self.selected = math.min(max_idx, self.selected + 1)
        return true
    elseif action == 'context' and self.actions then
        self.actions:sync_to_native()
        return true
    end
    return false
end

function AbilitiesMod:handle_action(action)
    return self:on_action(action)
end

function AbilitiesMod:get_hints()
    return '[D-Pad] Browse Actions   [X] Reload Actions   [LB/RB] Switch Module   [B] Close'
end

function AbilitiesMod:get_prompt_pills(last_device)
    if last_device == 'keyboard' or last_device == 'mouse' then
        return {
            { 'Arrows', 'Browse' },
            { 'X',      'Reload' },
            { 'Q/E',    'Modules' },
            { 'Esc',    'Close' },
        }
    end
    return {
        { 'D-Pad', 'Browse' },
        { 'X',     'Reload' },
        { 'LB/RB', 'Modules' },
        { 'B',     'Close' },
    }
end

function AbilitiesMod:draw(imgui, dl, F_arg, L, x, y, w, h, _ctx)
    if not imgui then return end
    local Fn = F_arg or F
    local s = (L and L.uiScale) or 1.0
    local pad = math.floor(18 * s)

    if dl and Fn and Fn.drawOrnatePanel then
        Fn.drawOrnatePanel(dl, x, y, w, h, {
            fillTop  = Fn.abgr(Fn.hex('#101628', 0.94)),
            fillBot  = Fn.abgr(Fn.hex('#070B14', 0.96)),
            border   = Fn.u32.soul_gold_dim,
            accent   = Fn.u32.aether_cyan,
            corners  = true,
            shadow   = false,
        })
    end

    if imgui.SetCursorScreenPos then
        imgui.SetCursorScreenPos({ x + pad, y + pad })
    end
    if imgui.BeginChild and imgui.BeginChild('##native_soul_actions_panel', { w - pad * 2, h - pad * 2 }, false) then
        local diag = (type(vana) == 'table' and vana.soulspire and vana.soulspire.diagnostics)
            and vana.soulspire.diagnostics() or {}
        local id = (self.identity and self.identity.active) and self.identity:active() or {}

        if imgui.TextColored then
            imgui.TextColored({ 0.91, 0.74, 0.44, 1.0 }, 'SOUL ACTIONS & VISIBILITY (VANACORE NATIVE)')
        else
            imgui.Text('SOUL ACTIONS & VISIBILITY (VANACORE NATIVE)')
        end
        imgui.Text(string.format('Active Soul: %s (Job %d / Branch %d / Lv.%d)',
            tostring(id.full_name or id.soul_key or 'None'),
            tonumber(id.job) or 0, tonumber(id.branch) or 0, tonumber(id.effective_level) or 0))
        imgui.Text(string.format('Catalog: %d actions | Visibility rules: %d | Row limit: %d chars | Native hooks: %d/%d',
            tonumber(diag.action_count) or 0, tonumber(diag.visibility_count) or 0,
            tonumber(diag.action_row_limit) or 16,
            tonumber(diag.hooks_installed) or 0, tonumber(diag.hooks_total) or 0))

        if imgui.Button('Reload Actions & Visibility##reload_actions') and self.actions then
            self.actions:sync_to_native()
        end
        imgui.Separator()

        local rows = (self.actions and self.actions.search) and self.actions:search(self.query, 96) or {}
        if #rows == 0 then
            imgui.Text('No custom Soul actions active for current Soul.')
        else
            for i, r in ipairs(rows) do
                local vis = self.actions:check_visibility(r.kind, r.id, tonumber(id.effective_level) or 0)
                local kind_lbl = r.kind == 1 and 'Spell' or (r.kind == 3 and 'WS' or 'JA')
                local prefix = (i == self.selected) and '> ' or '  '
                imgui.Text(string.format('%s[%s #%d] %s  (vis=%s)', prefix, kind_lbl, tonumber(r.id) or 0, tostring(r.name), tostring(vis)))
                if r.description and r.description ~= '' then
                    if imgui.TextColored then
                        imgui.TextColored({ 0.72, 0.78, 0.88, 1.0 }, '      ' .. tostring(r.description))
                    else
                        imgui.Text('      ' .. tostring(r.description))
                    end
                end
            end
        end
        imgui.EndChild()
    end
end

return AbilitiesMod
