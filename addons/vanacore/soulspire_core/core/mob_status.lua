-- SoulspireXI Phase C — Native VanaCore Mob Status Module
-- Reads live `[OXMOB]|` & `0x1FE` `OXKE` state from `vana.soulspire.all_mob_statuses()`.

local M = {}

function M.new()
    local self = {
        visible = false,
    }

    function self:list()
        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.all_mob_statuses) == 'function' then
            return vana.soulspire.all_mob_statuses()
        end
        return {}
    end

    function self:render(imgui)
        local rows = self:list()
        imgui.TextColored({ 0.85, 0.70, 0.25, 1.0 }, string.format('MOB STATUS TRACKER (%d tracked)', #rows))
        imgui.Separator()
        if #rows == 0 then
            imgui.Text('No active mob status telemetry received in this zone yet.')
            return
        end
        for _, m in ipairs(rows) do
            imgui.Text(string.format('Mob #%u  (pkts=%d): %s',
                tonumber(m.server_id) or 0, tonumber(m.packet_count) or 0, tostring(m.payload or '')))
        end
    end

    return self
end

return M
