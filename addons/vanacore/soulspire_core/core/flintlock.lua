-- SoulspireXI Phase C — Native VanaCore Flintlock State Module
-- Tracks Corsair Flintlock dual-pistol stance, ammo telemetry, and weapon config hash.

local M = {}

function M.new(identity_mod)
    local self = {
        identity = identity_mod,
        holster_mode = 'auto',
    }

    function self:is_flintlock_active()
        local active = self.identity and self.identity:active() or {}
        return active.known and string.lower(tostring(active.soul_key or '')) == 'flintlock'
    end

    function self:render(imgui)
        local active = self.identity and self.identity:active() or {}
        local is_fl = self:is_flintlock_active()
        local diag = (type(vana) == 'table' and vana.soulspire and vana.soulspire.diagnostics)
            and vana.soulspire.diagnostics() or {}

        imgui.TextColored({ 0.85, 0.70, 0.25, 1.0 }, 'FLINTLOCK STATE')
        imgui.Text('Active Soul: ' .. tostring(active.full_name or 'None') .. (is_fl and ' (Flintlock Active)' or ''))
        imgui.Text('Weapon Config Hash: ' .. tostring(diag.weapon_config_hash or 'not loaded'))
        imgui.Text('Weapon Eligibility Rules: ' .. tostring(diag.weapon_rule_count or 0))
        imgui.Text('Holster Mode: ' .. tostring(self.holster_mode))
        imgui.TextWrapped('Protected Core COR DAT overlay (flintlock-akimbo-compact, 278 DATs) and Phase D native weapon hooks provide dual-pistol rendering while preserving other COR Souls.')
    end

    return self
end

return M
