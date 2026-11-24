-- SoulspireXI Core: Process-Local Addon Packet Coexistence Coordinator
--
-- Solves the Ashita v4 multi-addon packet_in load-order bug where earlier-loaded
-- standalone addons (soulspire_talents, soulspire_soulhud, crystalsocket) set
-- e.blocked = true on custom S2C packets (0x1FD OXTL, 0x1FF CRYS, 0x017 [OXHUD])
-- before later-loaded soulspire_core can observe them.
--
-- Mechanism:
--   All Ashita v4 LuaJIT addons execute inside the same pol.exe process.
--   Using Win32 process-local environment variables (zero disk I/O, zero DLL changes),
--   each listener on a channel registers a monotonically increasing slot number.
--   Only the LAST-loaded listener sets e.blocked = true; earlier listeners process
--   the packet without prematurely blocking downstream addons.
--   Falls back cleanly to in-memory Lua table for headless Linux/CI tests.

local M = {}

local okFfi, ffi = pcall(require, 'ffi')
local is_windows = okFfi and ffi ~= nil and ffi.os == 'Windows'

if is_windows then
    pcall(ffi.cdef, [[
        uint32_t __stdcall GetEnvironmentVariableA(const char* lpName, char* lpBuffer, uint32_t nSize);
        int      __stdcall SetEnvironmentVariableA(const char* lpName, const char* lpValue);
    ]])
end

-- In-process fallback store for non-Windows / headless LuaJIT tests
local fallback_env = {}

local function get_env(name)
    if is_windows then
        local ok, val = pcall(function()
            local buf = ffi.new('char[64]')
            local n = ffi.C.GetEnvironmentVariableA(name, buf, 64)
            if n == 0 or n >= 64 then return nil end
            return ffi.string(buf, n)
        end)
        if ok then return val end
    end
    return fallback_env[name]
end

local function set_env(name, value)
    if is_windows then
        local ok = pcall(function()
            ffi.C.SetEnvironmentVariableA(name, value)
        end)
        if ok then return end
    end
    fallback_env[name] = value
end

local function channel_key(channel)
    return 'SOULSPIRE_PKT_LAST_' .. string.upper(tostring(channel or 'DEFAULT'))
end

local function count_key(channel)
    return 'SOULSPIRE_PKT_SEQ_' .. string.upper(tostring(channel or 'DEFAULT'))
end

function M.register_listener(channel, addon_name)
    local ckey = count_key(channel)
    local lkey = channel_key(channel)
    local next_seq = (tonumber(get_env(ckey)) or 0) + 1
    set_env(ckey, tostring(next_seq))
    set_env(lkey, tostring(next_seq))
    return {
        channel    = channel,
        addon_name = tostring(addon_name or ''),
        seq        = next_seq,
    }
end

function M.should_block(token)
    if type(token) ~= 'table' or not token.channel then
        return true
    end
    local last = tonumber(get_env(channel_key(token.channel))) or 0
    -- Only the last-registered active listener blocks the packet so every earlier
    -- listener receives it first, while FFXI's stock client dispatcher never sees it.
    return last <= 0 or token.seq >= last
end

function M.unregister_listener(token)
    if type(token) ~= 'table' or not token.channel then return end
    local lkey = channel_key(token.channel)
    local last = tonumber(get_env(lkey)) or 0
    if last == token.seq then
        local prev = token.seq - 1
        set_env(lkey, prev > 0 and tostring(prev) or nil)
    end
end

function M.reset_for_tests()
    fallback_env = {}
end

return M
