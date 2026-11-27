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
        dev_mode = false,
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
    elseif action == 'context' and self.dev_mode and self.actions then
        self.actions:sync_to_native()
        return true
    end
    return false
end

function AbilitiesMod:handle_action(action)
    return self:on_action(action)
end

local function resolve_lbl(label_fn, action, dev, fallback)
    if type(label_fn) == 'function' then
        local ok, v = pcall(label_fn, action, dev)
        if ok and type(v) == 'string' and v ~= '' then return v end
    end
    return fallback
end

function AbilitiesMod:get_hints(label_fn)
    if self.dev_mode then
        return string.format('[%s] Browse Actions   [%s] Reload Actions   [%s] Switch Module   [%s] Close',
            resolve_lbl(label_fn, 'nav', 'gamepad', 'D-Pad'),
            resolve_lbl(label_fn, 'context', 'gamepad', 'X'),
            resolve_lbl(label_fn, 'modules', 'gamepad', 'LB/RB'),
            resolve_lbl(label_fn, 'cancel', 'gamepad', 'B'))
    end
    return string.format('[%s] Browse Actions   [%s] Switch Module   [%s] Close',
        resolve_lbl(label_fn, 'nav', 'gamepad', 'D-Pad'),
        resolve_lbl(label_fn, 'modules', 'gamepad', 'LB/RB'),
        resolve_lbl(label_fn, 'cancel', 'gamepad', 'B'))
end

function AbilitiesMod:get_prompt_pills(last_device, label_fn)
    if last_device == 'keyboard' or last_device == 'mouse' then
        local pills = {
            { 'Arrows', 'Browse' },
            { 'Q/E',    'Modules' },
            { 'Esc',    'Close' },
        }
        if self.dev_mode then
            table.insert(pills, 2, { 'X', 'Reload' })
        end
        return pills
    end
    local pills = {
        { resolve_lbl(label_fn, 'nav',     last_device, 'D-Pad'), 'Browse' },
        { resolve_lbl(label_fn, 'modules', last_device, 'LB/RB'), 'Modules' },
        { resolve_lbl(label_fn, 'cancel',  last_device, 'B'),     'Close' },
    }
    if self.dev_mode then
        table.insert(pills, 2, { resolve_lbl(label_fn, 'context', last_device, 'X'), 'Reload' })
    end
    return pills
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

        local title_text = self.dev_mode and 'SOUL ACTIONS & VISIBILITY (DEV DIAGNOSTICS)' or 'SOUL ACTIONS'
        if imgui.TextColored then
            imgui.TextColored({ 0.91, 0.74, 0.44, 1.0 }, title_text)
        else
            imgui.Text(title_text)
        end
        local eff_lvl = tonumber(id.effective_level) or 0
        if self.dev_mode then
            imgui.Text(string.format('Active Soul: %s (Job %d / Branch %d / Lv.%d)',
                tostring(id.full_name or id.soul_key or 'None'),
                tonumber(id.job) or 0, tonumber(id.branch) or 0, eff_lvl))
            imgui.Text(string.format('Catalog: %d actions | Visibility rules: %d | Row limit: %d chars | Native hooks: %d/%d',
                tonumber(diag.action_count) or 0, tonumber(diag.visibility_count) or 0,
                tonumber(diag.action_row_limit) or 16,
                tonumber(diag.hooks_installed) or 0, tonumber(diag.hooks_total) or 0))
            if imgui.Button('Reload Actions & Visibility##reload_actions') and self.actions then
                self.actions:sync_to_native()
            end
        else
            imgui.Text(string.format('Active Soul: %s%s',
                tostring(id.full_name or id.soul_key or 'Base Job'),
                eff_lvl > 0 and string.format(' (Lv.%d)', eff_lvl) or ''))
        end
        imgui.Separator()

        local rows = (self.actions and self.actions.search) and self.actions:search(self.query, 96) or {}
        if #rows == 0 then
            imgui.Text('No custom Soul actions active for your current Soul.')
        else
            local shown = 0
            for i, r in ipairs(rows) do
                local vis = self.actions:check_visibility(r.kind, r.id, eff_lvl)
                if self.dev_mode or vis ~= 'hide' then
                    shown = shown + 1
                    local kind_lbl = r.kind == 1 and 'Spell' or (r.kind == 3 and 'Weapon Skill' or 'Job Ability')
                    local prefix = (i == self.selected) and '> ' or '  '
                    if self.dev_mode then
                        imgui.Text(string.format('%s[%s #%d] %s  (vis=%s)', prefix, kind_lbl, tonumber(r.id) or 0, tostring(r.name), tostring(vis)))
                    else
                        imgui.Text(string.format('%s[%s] %s', prefix, kind_lbl, tostring(r.name)))
                    end
                    if r.description and r.description ~= '' then
                        if imgui.TextColored then
                            imgui.TextColored({ 0.72, 0.78, 0.88, 1.0 }, '      ' .. tostring(r.description))
                        else
                            imgui.Text('      ' .. tostring(r.description))
                        end
                    end
                end
            end
            if shown == 0 then
                imgui.Text('No Soul actions unlocked at your current level.')
            end
        end
        imgui.EndChild()
    end
end

return AbilitiesMod
