-- SoulspireXI Phase C — Native VanaCore CrystalSocket & Weapon Config Module
-- Sends `0x11F` CRYS Soul selection/sync packets natively via `vana.packets.inject`
-- and displays the active Soul & authoritative weapon configuration hash.

local M = {}

M.PACKET_C2S_ID = 0x11F
M.OP_SYNC   = 1
M.OP_SELECT = 2

function M.encode_crys(op, job, branch)
    return string.char(0x1F, 0x09, 0x00, 0x00)
        .. 'CRYS'
        .. string.char(1, (tonumber(op) or 1) % 256, 0, 0, (tonumber(job) or 0) % 256, (tonumber(branch) or 0) % 256, 0, 0)
end

function M.new(identity_mod)
    local self = {
        identity = identity_mod,
        status_text = 'Ready',
    }

    function self:sync()
        if type(vana) == 'table' and vana.packets and type(vana.packets.inject) == 'function' then
            vana.packets.inject(false, M.PACKET_C2S_ID, M.encode_crys(M.OP_SYNC, 0, 0))
            self.status_text = 'Requested Soul identity sync...'
            return true
        end
        return false
    end

    function self:select_soul(job_id, branch_id)
        if type(vana) == 'table' and vana.packets and type(vana.packets.inject) == 'function' then
            vana.packets.inject(false, M.PACKET_C2S_ID, M.encode_crys(M.OP_SELECT, job_id, branch_id))
            self.status_text = string.format('Requested Soul switch (job=%d, branch=%d)...', job_id, branch_id)
            return true
        end
        return false
    end

    function self:render(imgui)
        local active = self.identity and self.identity:active() or {}
        imgui.TextColored({ 0.85, 0.70, 0.25, 1.0 }, 'CRYSTAL SOCKET — SOUL IDENTITY')
        imgui.Text(string.format('Active Soul: %s [%s] (Job %d / Branch %d, Lv.%d, source=%s)',
            tostring(active.full_name or 'Base Job'), tostring(active.short_name or '---'),
            tonumber(active.job) or 0, tonumber(active.branch) or 0,
            tonumber(active.effective_level) or 0, tostring(active.source or 'none')))
        imgui.Text(string.format('Registry Hash: %s (%d Souls loaded)',
            tostring(self.identity and self.identity.registry_hash or ''),
            self.identity and #(self.identity.souls or {}) or 0))
        if imgui.SmallButton('Sync Identity') then
            self:sync()
        end
        imgui.Separator()

        local job_id = tonumber(active.job) or 0
        local list = self.identity and self.identity:souls_for_job(job_id) or {}
        if #list == 0 then
            imgui.Text('Log in to a job to view available Soul Crystals.')
        else
            for _, s in ipairs(list) do
                local is_cur = (active.known and active.job == s.job_id and active.branch == s.branch_id)
                local lbl = string.format('%s [%s] (Branch %d)%s##cs_%d_%d',
                    s.name, s.abbr, s.branch_id, is_cur and '  [ACTIVE]' or '', s.job_id, s.branch_id)
                if imgui.Selectable(lbl, is_cur) then
                    self:select_soul(s.job_id, s.branch_id)
                end
            end
        end
        imgui.TextColored({ 0.65, 0.80, 0.95, 1.0 }, tostring(self.status_text))
    end

    return self
end

return M
