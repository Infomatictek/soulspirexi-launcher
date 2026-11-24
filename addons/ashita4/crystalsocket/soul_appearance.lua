-- Reusable registry-driven Soul-specific visual appearance rules for Ashita v4.
-- Client-side visual presentation only:
--   * Masks selected GrapIDTbl slots in incoming 0x0051 / 0x000A / self 0x000D packets.
--   * Never sends outgoing equipment packets, never unequips items, never alters stats.
--   * Caches the server's real GrapIDTbl so switching Souls, changing gear, zoning,
--     relogging, or unloading immediately restores exact equipped appearances.
--   * Zero hardcoded Soul IDs or job/branch numbers: loads appearanceMasks from
--     authoritative registry-generated plugins/ashita4/data/soul-weapon-config.json
--     via weapon_config.lua and fails closed if config is missing or invalid.

local WeaponConfig = require('weapon_config')

local M = {}

-- Offset of GrapIDTbl[0..8] (18 bytes = 9 x uint16_t) in each incoming packet (0-based):
--   0x0051 (GP_SERV_COMMAND_GRAP_LIST): header(4) -> offset 4 (Lua 1-based: 5..22)
--   0x000A (GP_SERV_COMMAND_LOGIN):     header(4) + pos_head(44) + zone/time/map(20) -> offset 68 (Lua 1-based: 69..86)
--   0x000D (GP_SERV_COMMAND_CHAR_PC):   header(4) + pos_head(44) + extra(24) -> offset 72 (Lua 1-based: 73..90)
M.OFFSET_0X51_GRAP = 4
M.OFFSET_0X0A_GRAP = 68
M.OFFSET_0X0D_GRAP = 72
M.GRAP_BYTES       = 18

-- Slot indices within GrapIDTbl (0-based, each 2 bytes):
--   [6] = Main   (empty = 0x6000)
--   [7] = Sub    (empty = 0x7000)
--   [8] = Ranged (empty = 0x8000; 0xFFFF = Costume2 / Monstrosity sentinel)
local EMPTY_MAIN_BYTES = string.char(0x00, 0x60)
local EMPTY_SUB_BYTES  = string.char(0x00, 0x70)

local function read_u16_le(data, pos1)
    local lo, hi = data:byte(pos1, pos1 + 1)
    if not hi then return nil end
    return lo + hi * 256
end

local function read_u32_le(data, pos1)
    local b1, b2, b3, b4 = data:byte(pos1, pos1 + 3)
    if not b4 then return nil end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

-- Queries authoritative registry-loaded appearanceMasks (fail-closed if unavailable).
function M.rule_for(job, branch)
    if type(job) ~= 'number' or type(branch) ~= 'number' then
        return nil
    end
    return WeaponConfig.appearance_mask_for(job, branch)
end

function M.apply_rule_to_grap(grap18, rule)
    if type(grap18) ~= 'string' or #grap18 ~= M.GRAP_BYTES then
        return grap18, false
    end
    if not rule then
        return grap18, false
    end
    -- Never override Costume2 / Monstrosity models (GrapIDTbl[8] == 0xFFFF).
    local ranged_word = read_u16_le(grap18, 17)
    if ranged_word == 0xFFFF then
        return grap18, false
    end

    local main_bytes = rule.hide_main and EMPTY_MAIN_BYTES or grap18:sub(13, 14)
    local sub_bytes  = rule.hide_sub  and EMPTY_SUB_BYTES  or grap18:sub(15, 16)
    local masked = grap18:sub(1, 12) .. main_bytes .. sub_bytes .. grap18:sub(17, 18)
    return masked, (masked ~= grap18)
end

function M.build_grap_list_packet(grap18)
    if type(grap18) ~= 'string' or #grap18 ~= M.GRAP_BYTES then
        return nil
    end
    -- 24-byte 0x0051 GP_SERV_COMMAND_GRAP_LIST:
    --   [1..2] id=0x0051 | size_words=12 (24/2 => 0x0C << 9 = 0x1800 => 0x1851)
    --   [3..4] sync=0x0000
    --   [5..22] GrapIDTbl[0..8]
    --   [23..24] padding00=0x0000
    return string.char(0x51, 0x18, 0x00, 0x00) .. grap18 .. string.char(0x00, 0x00)
end

local function splice_grap(packet, offset0, new_grap18)
    local head = packet:sub(1, offset0)
    local tail = packet:sub(offset0 + M.GRAP_BYTES + 1)
    return head .. new_grap18 .. tail
end

local function rule_key(rule)
    if not rule then return 'none' end
    return (rule.hide_main and 'M' or '-') .. (rule.hide_sub and 'S' or '-')
end

function M.new()
    local self = {
        active_job    = 0,
        active_branch = 0,
        active_rule   = nil,
        applied_key   = 'none',
        raw_grap      = nil,
    }

    function self:reset()
        self.active_job    = 0
        self.active_branch = 0
        self.active_rule   = nil
        self.applied_key   = 'none'
        self.raw_grap      = nil
    end

    -- Process incoming 0x0051 (GP_SERV_COMMAND_GRAP_LIST).
    -- Returns modified packet string if masked, or nil to leave untouched.
    function self:on_grap_list(data)
        if type(data) ~= 'string' or #data < (M.OFFSET_0X51_GRAP + M.GRAP_BYTES) then
            return nil
        end
        local grap = data:sub(M.OFFSET_0X51_GRAP + 1, M.OFFSET_0X51_GRAP + M.GRAP_BYTES)
        self.raw_grap = grap
        local masked, changed = M.apply_rule_to_grap(grap, self.active_rule)
        self.applied_key = rule_key(self.active_rule)
        if not changed then
            return nil
        end
        return splice_grap(data, M.OFFSET_0X51_GRAP, masked)
    end

    -- Process incoming 0x000A (GP_SERV_COMMAND_LOGIN / zone-in).
    -- Caches the fresh zone-in GrapIDTbl and masks if a rule is already active.
    function self:on_zone_in(data)
        if type(data) ~= 'string' or #data < (M.OFFSET_0X0A_GRAP + M.GRAP_BYTES) then
            return nil
        end
        local grap = data:sub(M.OFFSET_0X0A_GRAP + 1, M.OFFSET_0X0A_GRAP + M.GRAP_BYTES)
        self.raw_grap = grap
        local masked, changed = M.apply_rule_to_grap(grap, self.active_rule)
        self.applied_key = rule_key(self.active_rule)
        if not changed then
            return nil
        end
        return splice_grap(data, M.OFFSET_0X0A_GRAP, masked)
    end

    -- Process incoming 0x000D (GP_SERV_COMMAND_CHAR_PC).
    -- Only inspects/masks the local player when SendFlg.Model (bit 0x10) is present.
    function self:on_char_update(data, local_char_id)
        if type(data) ~= 'string' or type(local_char_id) ~= 'number' or local_char_id <= 0 then
            return nil
        end
        if #data < (M.OFFSET_0X0D_GRAP + M.GRAP_BYTES) then
            return nil
        end
        local server_id = read_u32_le(data, 5)
        if server_id ~= local_char_id then
            return nil
        end
        local send_flg = data:byte(11) or 0
        -- SendFlg.Model is bit 4 (0x10).
        if math.floor(send_flg / 16) % 2 == 0 then
            return nil
        end
        local grap = data:sub(M.OFFSET_0X0D_GRAP + 1, M.OFFSET_0X0D_GRAP + M.GRAP_BYTES)
        self.raw_grap = grap
        local masked, changed = M.apply_rule_to_grap(grap, self.active_rule)
        self.applied_key = rule_key(self.active_rule)
        if not changed then
            return nil
        end
        return splice_grap(data, M.OFFSET_0X0D_GRAP, masked)
    end

    -- Update active Soul identity. If the effective visual rule changed and we have a
    -- cached GrapIDTbl, immediately invoke inject_fn(packet_bytes) with an updated 0x0051.
    function self:set_active_soul(job, branch, inject_fn)
        local next_job    = (type(job) == 'number' and job > 0) and job or 0
        local next_branch = (type(branch) == 'number' and branch > 0) and branch or 0
        local next_rule   = M.rule_for(next_job, next_branch)
        local next_key    = rule_key(next_rule)

        self.active_job    = next_job
        self.active_branch = next_branch
        self.active_rule   = next_rule

        if next_key == self.applied_key then
            return false
        end
        if not self.raw_grap then
            -- Wait until 0x000A / 0x0051 / 0x000D populates raw_grap.
            return false
        end

        local effective = M.apply_rule_to_grap(self.raw_grap, next_rule)
        local packet = M.build_grap_list_packet(effective)
        self.applied_key = next_key
        if packet and type(inject_fn) == 'function' then
            inject_fn(packet)
            return true
        end
        return false
    end

    -- Restore original unmasked Main/Sub appearance (e.g., on addon unload).
    function self:restore(inject_fn)
        local was_masked = (self.applied_key ~= 'none')
        self.active_job    = 0
        self.active_branch = 0
        self.active_rule   = nil
        if was_masked and self.raw_grap then
            local packet = M.build_grap_list_packet(self.raw_grap)
            self.applied_key = 'none'
            if packet and type(inject_fn) == 'function' then
                inject_fn(packet)
                return true
            end
        end
        self.applied_key = 'none'
        return false
    end

    return self
end

return M
