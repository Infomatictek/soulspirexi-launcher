-- SoulspireXI Job Labels Bridge (VanaCore-Native)
-- Directly delegates to VanaCore's native `vana.soulspire` subsystem with zero legacy DLL FFI.

local M = {}

function M.is_available()
    return type(vana) == 'table' and vana.soulspire ~= nil and type(vana.soulspire.enabled) == 'function' and vana.soulspire.enabled() == true
end

function M.set_active_soul(char_id, job, branch, effective_level)
    if not (type(vana) == 'table' and vana.soulspire and type(vana.soulspire.set_identity) == 'function') then
        return false
    end
    return vana.soulspire.set_identity(tonumber(job) or 0, tonumber(branch) or 0, tonumber(char_id) or 0, tonumber(effective_level) or 0) == true
end

function M.clear_active_soul()
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.clear_identity) == 'function' then
        return vana.soulspire.clear_identity() == true
    end
    return false
end

function M.get_active_soul()
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.identity) == 'function' then
        return vana.soulspire.identity()
    end
    return nil
end

function M.sync_peer_soul(_char_id, _job, _branch)
    -- Handled natively by src/core/soulspire/packets.cpp on 0x1FC.
    return true
end

function M.clear()
    M.clear_active_soul()
end

return M
