-- SoulspireXI Phase C — Native VanaCore Soul HUD Module
-- Renders live Soul telemetry (Shinobi shadows/Feint Ready & universal Soul gauges)
-- directly from `vana.soulspire.hud()` using native `vana.imgui`.

local M = {}

function M.new(identity_mod)
    local self = {
        identity = identity_mod,
        visible = true,
        locked = false,
    }

    function self:snapshot()
        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.hud) == 'function' then
            return vana.soulspire.hud()
        end
        return { soul_key = '', kv = {}, packet_count = 0, updated_ms = 0 }
    end

    function self:render(imgui)
        if not self.visible or not imgui then
            return
        end
        local snap = self:snapshot()
        local active = self.identity and self.identity:active() or {}
        local soul_key = (snap and snap.soul_key and snap.soul_key ~= '') and snap.soul_key or (active.soul_key or '')
        if soul_key == '' and (not snap or (snap.packet_count or 0) == 0) then
            return
        end

        local title = (active.full_name and active.full_name ~= '') and (active.full_name .. ' HUD###soulspire_native_hud')
            or 'Soul HUD###soulspire_native_hud'
        local flags = 64 -- ImGuiWindowFlags_AlwaysAutoResize
        if self.locked then
            flags = flags + 4 -- ImGuiWindowFlags_NoMove
        end

        if imgui.Begin(title, true, flags) then
            local kv = (snap and snap.kv) or {}
            local sh = tonumber(kv.sh)
            local shmax = tonumber(kv.shmax)
            if sh ~= nil and shmax ~= nil and shmax > 0 then
                -- Shinobi Offensive Shadow Squadron pips
                local pips = {}
                for i = 1, shmax do
                    pips[i] = (i <= sh) and '[*]' or '[ ]'
                end
                imgui.Text(string.format('Shadows (%d/%d): %s', sh, shmax, table.concat(pips, ' ')))
                if tonumber(kv.feint) == 1 then
                    imgui.TextColored({ 0.98, 0.80, 0.25, 1.0 }, 'FEINT READY')
                end
            end

            -- Render remaining universal Soul telemetry key/values cleanly
            local keys = {}
            for k in pairs(kv) do
                if k ~= 'sh' and k ~= 'shmax' and k ~= 'feint' then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys)
            for _, k in ipairs(keys) do
                imgui.Text(string.format('%s: %s', tostring(k), tostring(kv[k])))
            end

            if #keys == 0 and sh == nil then
                imgui.Text(string.format('Active Soul: %s (Lv.%d)', tostring(active.full_name or soul_key), tonumber(active.effective_level) or 0))
            end
        end
        imgui.End()
    end

    return self
end

return M
