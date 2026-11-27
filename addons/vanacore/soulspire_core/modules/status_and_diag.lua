-- SoulspireXI Core Module (VanaCore-Native): Flintlock, Mob Status & Native Diagnostics
-- Renders Flintlock weapon status, live native 0x1FE/[OXMOB] mob debuff snapshots,
-- VanaCore hook matrix, texture cache stats, UI input ownership state, and Ashita-compat status.

local F = require('core.foundations')

local StatusDiagMod = {}
StatusDiagMod.__index = StatusDiagMod

function StatusDiagMod.new(flintlock_svc, mob_status_svc, startup_report, identity_svc, actions_svc, runtime_diag)
    return setmetatable({
        flintlock      = flintlock_svc,
        mob_status     = mob_status_svc,
        startup_report = startup_report,
        identity       = identity_svc,
        actions        = actions_svc,
        runtime_diag   = runtime_diag,
        subtab         = 'diag', -- 'diag' | 'mobs' | 'flintlock'
    }, StatusDiagMod)
end

function StatusDiagMod:on_open() end
function StatusDiagMod:on_activate() end
function StatusDiagMod:on_close() end

function StatusDiagMod:on_action(action)
    if action == 'left' or action == 'right' then
        local order = { 'diag', 'mobs', 'flintlock' }
        local idx = 1
        for i, v in ipairs(order) do
            if v == self.subtab then idx = i break end
        end
        idx = (action == 'right') and ((idx % #order) + 1) or (((idx - 2) % #order) + 1)
        self.subtab = order[idx]
        return true
    elseif action == 'context' then
        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.reload) == 'function' then
            pcall(vana.soulspire.reload)
        end
        return true
    end
    return false
end

function StatusDiagMod:handle_action(action)
    return self:on_action(action)
end

function StatusDiagMod:get_hints()
    return '[D-Pad Left/Right] Switch Subtab   [X] Reload Native   [LB/RB] Switch Module   [B] Close'
end

function StatusDiagMod:get_prompt_pills(last_device)
    if last_device == 'keyboard' or last_device == 'mouse' then
        return {
            { 'Left/Right', 'Subtab' },
            { 'X',          'Reload' },
            { 'Q/E',        'Modules' },
            { 'Esc',        'Close' },
        }
    end
    return {
        { 'D-Pad', 'Subtab' },
        { 'X',     'Reload' },
        { 'LB/RB', 'Modules' },
        { 'B',     'Close' },
    }
end

function StatusDiagMod:draw(imgui, dl, F_arg, L, x, y, w, h, _ctx)
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
    if imgui.BeginChild and imgui.BeginChild('##native_diag_panel', { w - pad * 2, h - pad * 2 }, false) then
        if imgui.Button((self.subtab == 'diag' and '[Diagnostics]' or 'Diagnostics') .. '##sub_diag') then self.subtab = 'diag' end
        imgui.SameLine()
        if imgui.Button((self.subtab == 'mobs' and '[Mob Status]' or 'Mob Status') .. '##sub_mobs') then self.subtab = 'mobs' end
        imgui.SameLine()
        if imgui.Button((self.subtab == 'flintlock' and '[Flintlock]' or 'Flintlock') .. '##sub_flint') then self.subtab = 'flintlock' end
        imgui.Separator()

        if self.subtab == 'mobs' and self.mob_status then
            self.mob_status:render(imgui)
        elseif self.subtab == 'flintlock' and self.flintlock then
            self.flintlock:render(imgui)
        else
            local d = (type(vana) == 'table' and vana.soulspire and vana.soulspire.diagnostics)
                and vana.soulspire.diagnostics() or {}
            local ui_in = (type(vana) == 'table' and vana.soulspire and vana.soulspire.ui_input_state)
                and vana.soulspire.ui_input_state() or {}
            local tstats = (type(vana) == 'table' and vana.soulspire and vana.soulspire.texture_stats)
                and vana.soulspire.texture_stats() or {}

            if imgui.TextColored then
                imgui.TextColored({ 0.91, 0.74, 0.44, 1.0 }, 'VANACORE-NATIVE RUNTIME DIAGNOSTICS (DEC-028 / API v2)')
            else
                imgui.Text('VANACORE-NATIVE RUNTIME DIAGNOSTICS (DEC-028 / API v2)')
            end
            imgui.Text(string.format('Native Engine: enabled=%s | API v%d | Caps=0x%X | Hooks=%d/%d | Ashita Compat=%s',
                tostring(d.enabled), tonumber(d.api_version) or 0, tonumber(d.capabilities) or 0,
                tonumber(d.hooks_installed) or 0, tonumber(d.hooks_total) or 0,
                tostring(d.ashita_compat_enabled)))
            imgui.Text(string.format('Registry: %d Souls (hash=%s) | Weapon Rules: %d (hash=%s)',
                tonumber(d.registry_soul_count) or (self.identity and #(self.identity.souls or {}) or 0),
                tostring((d.registry_hash and d.registry_hash ~= '') and d.registry_hash or (self.identity and self.identity.registry_hash or '')),
                tonumber(d.weapon_rule_count) or 0, tostring(d.weapon_config_hash or '')))
            local sr = self.startup_report or {}
            imgui.Text(string.format('Core Catalogs: startup_ok=%s | Souls=%d | Actions=%d | Visibility=%d',
                tostring(sr.ok),
                self.identity and #(self.identity.souls or {}) or 0,
                self.actions and (self.actions.parsed_actions or #(self.actions.actions or {})) or 0,
                self.actions and (self.actions.parsed_visibility or #(self.actions.visibility or {})) or 0))
            if self.identity and self.identity.registry_source then
                imgui.Text('  souls.json: ' .. tostring(self.identity.registry_source))
            end
            if self.actions and self.actions.actions_source then
                imgui.Text('  actions.tsv: ' .. tostring(self.actions.actions_source))
            end
            if self.actions and self.actions.visibility_source then
                imgui.Text('  visibility.tsv: ' .. tostring(self.actions.visibility_source))
            end
            if type(sr.errors) == 'table' and #sr.errors > 0 then
                for _, err in ipairs(sr.errors) do
                    if imgui.TextColored then
                        imgui.TextColored({ 0.94, 0.33, 0.31, 1.0 }, '  [STARTUP ERROR] ' .. tostring(err))
                    else
                        imgui.Text('  [STARTUP ERROR] ' .. tostring(err))
                    end
                end
            end
            imgui.Text(string.format('UI Input Ownership: active=%s owners=%d block_mouse=%s gamepad=%s cursor=%s acq=%d rel=%d last=%s',
                tostring(ui_in.active), tonumber(ui_in.owner_count) or 0,
                tostring(ui_in.block_mouse), tostring(ui_in.capture_gamepad), tostring(ui_in.show_cursor),
                tonumber(ui_in.acquire_count) or 0, tonumber(ui_in.release_count) or 0,
                tostring(ui_in.last_release_reason or '')))
            imgui.Text(string.format('Native Textures: loaded=%d bytes=%d hits=%d misses=%d failures=%d device_ready=%s',
                tonumber(tstats.loaded) or 0, tonumber(tstats.bytes) or 0,
                tonumber(tstats.hits) or 0, tonumber(tstats.misses) or 0,
                tonumber(tstats.failures) or 0, tostring(tstats.device_ready)))
            imgui.Text(string.format('Packets (Binary): 1FF=%d 1FC=%d 1FD=%d 1FE=%d | Legacy 0x017 Chat: OXHUD=%d OXMOB=%d OXTAL=%d Suppressed=%d',
                tonumber(d.packets_1ff) or 0, tonumber(d.packets_1fc) or 0,
                tonumber(d.packets_1fd) or 0, tonumber(d.packets_1fe) or 0,
                tonumber(d.packets_oxhud) or 0, tonumber(d.packets_oxmob) or 0,
                tonumber(d.packets_oxtal) or 0, tonumber(d.suppressed_chat_frames) or 0))
            local rd = self.runtime_diag
            if type(rd) == 'table' then
                imgui.Text(string.format('Soul Sync (Lua): req_sent=%d crys_rx=%d oxhd_rx=%d | Controller: xinput=%d dinput=%d actions=%d last=%s (%s)',
                    tonumber(rd.crys_req_sent) or 0, tonumber(rd.crys_rx) or 0, tonumber(rd.oxhd_rx) or 0,
                    tonumber(rd.xinput_events) or 0, tonumber(rd.dinput_events) or 0,
                    tonumber(rd.actions_dispatched) or 0,
                    tostring(rd.last_action or 'none'), tostring(rd.last_device or 'gamepad')))
            end
            imgui.Text('Note: [OK] hooks and active input ownership indicate installation/claim only, not live Windows certification.')
            imgui.Separator()
            for _, h in ipairs(d.hooks or {}) do
                imgui.Text(string.format('[%s] %-24s (%s / %s) +0x%X hits=%d — %s',
                    h.installed and 'OK' or 'FAIL', tostring(h.id), tostring(h.owner),
                    tostring(h.disposition or ''), tonumber(h.rva) or 0,
                    tonumber(h.hit_count) or 0, tostring(h.detail or '')))
            end
        end
        imgui.EndChild()
    end
end

return StatusDiagMod
