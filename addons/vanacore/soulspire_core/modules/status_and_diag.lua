-- SoulspireXI Core Module (VanaCore-Native): Flintlock, Mob Status & Native Diagnostics
-- Renders Flintlock weapon status, live native 0x1FE/[OXMOB] mob debuff snapshots,
-- VanaCore hook matrix, texture cache stats, UI input ownership state, and Ashita-compat status.

local F = require('core.foundations')

local StatusDiagMod = {}
StatusDiagMod.__index = StatusDiagMod

function StatusDiagMod.new(flintlock_svc, mob_status_svc, startup_report)
    return setmetatable({
        flintlock      = flintlock_svc,
        mob_status     = mob_status_svc,
        startup_report = startup_report,
        subtab         = 'diag', -- 'diag' | 'mobs' | 'flintlock'
    }, StatusDiagMod)
end

function StatusDiagMod:on_open() end
function StatusDiagMod:on_activate() end
function StatusDiagMod:on_close() end

function StatusDiagMod:handle_action(action)
    if action == 'left' or action == 'right' then
        local order = { 'diag', 'mobs', 'flintlock' }
        local idx = 1
        for i, v in ipairs(order) do
            if v == self.subtab then idx = i break end
        end
        idx = (action == 'right') and ((idx % #order) + 1) or (((idx - 2) % #order) + 1)
        self.subtab = order[idx]
        return true
    end
    return false
end

function StatusDiagMod:draw(imgui, dl, L, x, y, w, h)
    if not imgui then return end
    local s = (L and L.uiScale) or 1.0
    local pad = math.floor(18 * s)

    if dl then
        F.drawOrnatePanel(dl, x, y, w, h, {
            fillTop  = F.abgr(F.hex('#101628', 0.94)),
            fillBot  = F.abgr(F.hex('#070B14', 0.96)),
            border   = F.u32.soul_gold_dim,
            accent   = F.u32.aether_cyan,
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
                tonumber(d.registry_soul_count) or 0, tostring(d.registry_hash or ''),
                tonumber(d.weapon_rule_count) or 0, tostring(d.weapon_config_hash or '')))
            imgui.Text(string.format('UI Input Ownership: active=%s owners=%d block_mouse=%s gamepad=%s cursor=%s acq=%d rel=%d last=%s',
                tostring(ui_in.active), tonumber(ui_in.owner_count) or 0,
                tostring(ui_in.block_mouse), tostring(ui_in.capture_gamepad), tostring(ui_in.show_cursor),
                tonumber(ui_in.acquire_count) or 0, tonumber(ui_in.release_count) or 0,
                tostring(ui_in.last_release_reason or '')))
            imgui.Text(string.format('Native Textures: loaded=%d bytes=%d hits=%d misses=%d failures=%d device_ready=%s',
                tonumber(tstats.loaded) or 0, tonumber(tstats.bytes) or 0,
                tonumber(tstats.hits) or 0, tonumber(tstats.misses) or 0,
                tonumber(tstats.failures) or 0, tostring(tstats.device_ready)))
            imgui.Text(string.format('Packets: 1FF=%d 1FC=%d 1FD=%d 1FE=%d | OXHUD=%d OXMOB=%d OXTAL=%d | Suppressed=%d',
                tonumber(d.packets_1ff) or 0, tonumber(d.packets_1fc) or 0,
                tonumber(d.packets_1fd) or 0, tonumber(d.packets_1fe) or 0,
                tonumber(d.packets_oxhud) or 0, tonumber(d.packets_oxmob) or 0,
                tonumber(d.packets_oxtal) or 0, tonumber(d.suppressed_chat_frames) or 0))
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
