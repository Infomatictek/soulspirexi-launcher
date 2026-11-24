-- SoulspireXI Core: Process-Local Addon Packet Coexistence Coordinator
--
-- Solves the Ashita v4 multi-addon packet_in load-order and reload-order bugs where
-- standalone addons (soulspire_talents, soulspire_soulhud, crystalsocket) and
-- soulspire_core subscribe to the same custom S2C packets (0x1FD OXTL, 0x1FF CRYS,
-- 0x017 [OXHUD]):
--   1. Tracks the exact LIVE set of active listeners per channel inside Win32
--      process-local environment variables (zero disk I/O, zero DLL changes).
--   2. Re-registering the same addon_name (e.g. /addon reload soulspire_talents)
--      replaces its prior slot cleanly instead of leaking stale sequence IDs.
--   3. Only the highest active listener slot sets e.blocked = true so every earlier
--      listener observes the packet while stock FFXI never sees custom packets.
--   4. Exposes has_listener() / is_primary_owner() so standalone addons stay passive
--      when soulspire_core is active and their standalone windows are closed
--      (eliminating duplicate 6.8MB cache parses and duplicate sync bursts).

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
            local buf = ffi.new('char[512]')
            local n = ffi.C.GetEnvironmentVariableA(name, buf, 512)
            if n == 0 or n >= 512 then return nil end
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

local function seq_key(channel)
    return 'SOULSPIRE_PKT_SEQ_' .. string.upper(tostring(channel or 'DEFAULT'))
end

local function list_key(channel)
    return 'SOULSPIRE_PKT_LIST_' .. string.upper(tostring(channel or 'DEFAULT'))
end

local function last_key(channel)
    return 'SOULSPIRE_PKT_LAST_' .. string.upper(tostring(channel or 'DEFAULT'))
end

local function sanitize_name(name)
    return (tostring(name or 'addon'):gsub('[^%w_%-]', ''))
end

local function parse_list(raw)
    local out = {}
    if type(raw) ~= 'string' or raw == '' then return out end
    for entry in string.gmatch(raw, '([^,]+)') do
        local s, n = string.match(entry, '^(%d+):(.+)$')
        if s and n then
            out[#out + 1] = { seq = tonumber(s) or 0, name = n }
        end
    end
    return out
end

local function write_list(channel, entries)
    if #entries == 0 then
        set_env(list_key(channel), nil)
        set_env(last_key(channel), nil)
        return
    end
    local parts = {}
    local max_seq = 0
    for _, e in ipairs(entries) do
        parts[#parts + 1] = tostring(e.seq) .. ':' .. e.name
        if e.seq > max_seq then max_seq = e.seq end
    end
    set_env(list_key(channel), table.concat(parts, ','))
    set_env(last_key(channel), tostring(max_seq))
end

function M.register_listener(channel, addon_name)
    local clean = sanitize_name(addon_name)
    local next_seq = (tonumber(get_env(seq_key(channel))) or 0) + 1
    set_env(seq_key(channel), tostring(next_seq))

    local entries = parse_list(get_env(list_key(channel)))
    local filtered = {}
    for _, e in ipairs(entries) do
        if e.name ~= clean then
            filtered[#filtered + 1] = e
        end
    end
    filtered[#filtered + 1] = { seq = next_seq, name = clean }
    write_list(channel, filtered)

    return {
        channel    = channel,
        addon_name = clean,
        seq        = next_seq,
    }
end

function M.has_listener(channel, addon_name)
    local clean = sanitize_name(addon_name)
    local entries = parse_list(get_env(list_key(channel)))
    for _, e in ipairs(entries) do
        if e.name == clean then
            return true
        end
    end
    return false
end

function M.list_listeners(channel)
    return parse_list(get_env(list_key(channel)))
end

-- Returns true if addon_name is the designated primary request owner for channel.
-- soulspire_core always takes precedence when active; otherwise any registered listener owns it.
function M.is_primary_owner(channel, addon_name)
    local clean = sanitize_name(addon_name)
    if clean == 'soulspire_core' then
        return true
    end
    return not M.has_listener(channel, 'soulspire_core')
end

function M.should_block(token)
    if type(token) ~= 'table' or not token.channel then
        return true
    end
    local entries = parse_list(get_env(list_key(token.channel)))
    if #entries == 0 then
        local last = tonumber(get_env(last_key(token.channel))) or 0
        return last <= 0 or token.seq >= last
    end
    local max_seq = 0
    for _, e in ipairs(entries) do
        if e.seq > max_seq then max_seq = e.seq end
    end
    return max_seq <= 0 or token.seq >= max_seq
end

function M.unregister_listener(token)
    if type(token) ~= 'table' or not token.channel then return end
    local entries = parse_list(get_env(list_key(token.channel)))
    local filtered = {}
    for _, e in ipairs(entries) do
        if e.seq ~= token.seq then
            filtered[#filtered + 1] = e
        end
    end
    write_list(token.channel, filtered)
end

function M.reset_for_tests()
    fallback_env = {}
end

return M
