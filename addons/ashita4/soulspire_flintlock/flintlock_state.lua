-- Pure-Lua state, registry-driven Soul gating, 0x0028 action decoding, and auto-facing logic
-- for ranged-only dual-pistol Souls (configured in registry/weapon_configs.json -> soul-weapon-config.json).
-- Client-only and visual-only; never modifies combat, equipment, or unconfigured Souls.
-- Zero hardcoded Soul job/branch numbers in gating logic; fails closed if registry config is missing.

local bit = require('bit')
local M = {}

M.FIREARM_SKILLS = {
    [26] = true, -- Marksmanship (guns/crossbows; narrowed by firearm check when item metadata available)
}

local function read_u32_le(data, offset)
    local b1, b2, b3, b4 = data:byte(offset, offset + 3)
    if not b4 then return nil end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function read_u16_le(data, offset)
    local b1, b2 = data:byte(offset, offset + 1)
    if not b2 then return nil end
    return b1 + b2 * 256
end

-- Minimal JSON reader for loading rangedOnly rules from soul-weapon-config.json without external deps.
local function parse_json(src)
    if type(src) ~= 'string' or #src == 0 then return nil end
    local pos, len = 1, #src
    local function skip_ws()
        local _, e = src:find('^[ \t\r\n]*', pos)
        if e then pos = e + 1 end
    end
    local parse_value
    local function parse_string()
        pos = pos + 1
        local out = {}
        while pos <= len do
            local ch = src:sub(pos, pos)
            if ch == '"' then pos = pos + 1; return table.concat(out)
            elseif ch == '\\' then
                pos = pos + 1
                local esc = src:sub(pos, pos)
                local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
                out[#out + 1] = map[esc] or esc
                pos = pos + 1
            else
                out[#out + 1] = ch
                pos = pos + 1
            end
        end
        return nil
    end
    local function parse_number()
        local s, e = src:find('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos)
        if not s then return nil end
        pos = e + 1
        return tonumber(src:sub(s, e))
    end
    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if src:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        while pos <= len do
            local v = parse_value()
            arr[#arr + 1] = v
            skip_ws()
            local c = src:sub(pos, pos)
            if c == ']' then pos = pos + 1; return arr end
            if c ~= ',' then return nil end
            pos = pos + 1
            skip_ws()
        end
        return nil
    end
    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if src:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while pos <= len do
            skip_ws()
            if src:sub(pos, pos) ~= '"' then return nil end
            local k = parse_string()
            if not k then return nil end
            skip_ws()
            if src:sub(pos, pos) ~= ':' then return nil end
            pos = pos + 1
            obj[k] = parse_value()
            skip_ws()
            local c = src:sub(pos, pos)
            if c == '}' then pos = pos + 1; return obj end
            if c ~= ',' then return nil end
            pos = pos + 1
        end
        return nil
    end
    parse_value = function()
        skip_ws()
        local c = src:sub(pos, pos)
        if c == '{' then return parse_object()
        elseif c == '[' then return parse_array()
        elseif c == '"' then return parse_string()
        elseif c == 't' and src:sub(pos, pos + 3) == 'true' then pos = pos + 4; return true
        elseif c == 'f' and src:sub(pos, pos + 4) == 'false' then pos = pos + 5; return false
        elseif c == 'n' and src:sub(pos, pos + 3) == 'null' then pos = pos + 4; return nil
        else return parse_number() end
    end
    return parse_value()
end

local ranged_only_by_jb = {}
local ranged_only_by_key = {}
local ranged_only_jobs = {}
local config_loaded = false

local function reset_registry()
    ranged_only_by_jb = {}
    ranged_only_by_key = {}
    ranged_only_jobs = {}
    config_loaded = false
end

function M.load_registry_from_string(json_str)
    reset_registry()
    local doc = parse_json(json_str)
    if type(doc) ~= 'table' or doc.schemaVersion ~= 1 or type(doc.rangedOnly) ~= 'table' then
        return false
    end
    for _, g in ipairs(doc.rangedOnly) do
        if type(g) == 'table' and type(g.jobId) == 'number' and type(g.branch) == 'number' then
            local rec = {
                soul_id     = tostring(g.soulId or ''),
                soul_key    = tostring(g.soulKey or ''):lower(),
                job         = g.jobId,
                branch      = g.branch,
                firearm_only = g.firearmOnly == true,
                auto_facing  = g.autoFacing == true,
                overlay_id   = tostring(g.overlayId or ''),
            }
            ranged_only_by_jb[rec.job] = ranged_only_by_jb[rec.job] or {}
            ranged_only_by_jb[rec.job][rec.branch] = rec
            ranged_only_by_key[rec.job] = ranged_only_by_key[rec.job] or {}
            if rec.soul_key ~= '' then
                ranged_only_by_key[rec.job][rec.soul_key] = rec
            end
            ranged_only_jobs[rec.job] = true
        end
    end
    config_loaded = true
    return true
end

function M.load_registry_default(base_dir)
    local candidates = {}
    if type(base_dir) == 'string' and base_dir ~= '' then
        local clean = base_dir:gsub('[/\\]+$', '')
        candidates[#candidates + 1] = clean .. '/../../plugins/data/soul-weapon-config.json'
        candidates[#candidates + 1] = clean .. '/../../../plugins/ashita4/data/soul-weapon-config.json'
    end
    local src = debug and debug.getinfo and debug.getinfo(1, 'S') and debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then
        local dir = src:sub(2):match('^(.*)[/\\][^/\\]+$')
        if dir then
            candidates[#candidates + 1] = dir .. '/../../plugins/data/soul-weapon-config.json'
            candidates[#candidates + 1] = dir .. '/../../../plugins/ashita4/data/soul-weapon-config.json'
        end
    end
    candidates[#candidates + 1] = 'plugins/data/soul-weapon-config.json'
    candidates[#candidates + 1] = 'plugins/ashita4/data/soul-weapon-config.json'
    candidates[#candidates + 1] = '../../../plugins/ashita4/data/soul-weapon-config.json'
    for _, p in ipairs(candidates) do
        local f = io.open(p, 'rb')
        if f then
            local content = f:read('*a')
            f:close()
            if M.load_registry_from_string(content) then
                return true
            end
        end
    end
    reset_registry()
    return false
end

function M.ranged_only_rule(job, branch)
    if not config_loaded or type(job) ~= 'number' or type(branch) ~= 'number' then return nil end
    local by_job = ranged_only_by_jb[job]
    return by_job and by_job[branch] or nil
end

function M.ranged_only_rule_by_key(job, soul_key)
    if not config_loaded or type(job) ~= 'number' or type(soul_key) ~= 'string' then return nil end
    local by_job = ranged_only_by_key[job]
    return by_job and by_job[soul_key:lower()] or nil
end

-- Auto-load authoritative registry config (fails closed if absent).
M.load_registry_default()

-- Unpack little-endian bitfield from 1-based byte string, 0-based bit offset.
function M.unpack_bits(data, bit_offset, bit_len)
    if type(data) ~= 'string' or bit_offset < 0 or bit_len <= 0 or bit_len > 32 then
        return nil
    end
    local value = 0
    local mul = 1
    for i = 0, bit_len - 1 do
        local pos = bit_offset + i
        local byte_idx = math.floor(pos / 8) + 1
        local b = data:byte(byte_idx)
        if not b then return nil end
        local bit_idx = pos % 8
        local bit_val = bit.band(bit.rshift(b, bit_idx), 1)
        if bit_val == 1 then
            value = value + mul
        end
        mul = mul * 2
    end
    return value
end

-- Decode SoulspireXI 0x1FC ('OXHD') HUD packet for fallback Soul identity.
function M.decode_soul_packet(data, expected_job)
    if type(data) ~= 'string' or #data < 16 or #data > 4096 or data:sub(5, 8) ~= 'OXHD' then
        return nil
    end
    local version, unlocked, packet_job, key_len, kv_lo, kv_hi = data:byte(9, 14)
    if version ~= 1 or (unlocked ~= 0 and unlocked ~= 1)
        or not packet_job or packet_job < 1 or packet_job > 22
        or not key_len or key_len > 64 or not kv_lo or not kv_hi then
        return nil
    end
    if expected_job ~= nil and packet_job ~= expected_job then
        return nil
    end
    if #data < 16 + key_len + kv_lo + kv_hi * 256 then
        return nil
    end
    if key_len == 0 then
        return { job = packet_job, branch = 0, soul = nil }
    end
    local soul = data:sub(17, 16 + key_len):lower()
    if not soul:match('^[%w_%-]+$') then
        return nil
    end
    local rule = M.ranged_only_rule_by_key(packet_job, soul)
    local branch = rule and rule.branch or 0
    return { job = packet_job, branch = branch, soul = soul }
end

-- Resolve active ranged-only Soul from soulspire_native.dll status struct via registry rules.
function M.is_flintlock_from_crystaljobs(status, job, character_id)
    if type(status) ~= 'table' or type(job) ~= 'number' or type(character_id) ~= 'number' then
        return false
    end
    if character_id <= 0 or status.enabled ~= 1 or status.known ~= 1
        or status.character_id ~= character_id or status.job ~= job then
        return false
    end
    local rule = M.ranged_only_rule(job, status.branch)
    return rule ~= nil and rule.auto_facing == true
end

-- Parse outgoing 0x01A action packet for ranged attack (category == 0x10).
function M.parse_outgoing_ra_target(data)
    if type(data) ~= 'string' or #data < 12 then
        return nil
    end
    local category = read_u16_le(data, 11)
    if category ~= 0x10 then
        return nil
    end
    local target_id = read_u32_le(data, 5)
    if not target_id or target_id == 0 then
        return nil
    end
    return target_id
end

-- Parse incoming 0x0028 action packet header + first target ID.
function M.parse_action_packet(data)
    if type(data) ~= 'string' or #data < 23 then
        return nil
    end
    local actor_id = M.unpack_bits(data, 40, 32)
    local target_count = M.unpack_bits(data, 72, 10)
    local category = M.unpack_bits(data, 82, 4)
    local param = M.unpack_bits(data, 86, 32)
    local first_target_id = nil
    if target_count and target_count >= 1 then
        first_target_id = M.unpack_bits(data, 150, 32)
    end
    return {
        actor_id = actor_id,
        target_count = target_count or 0,
        category = category,
        param = param or 0,
        target_id = first_target_id,
    }
end

-- Compute FFXI horizontal yaw (radians) facing from (me_x, me_z) to (target_x, target_z).
function M.compute_facing_yaw(me_x, me_z, target_x, target_z)
    if type(me_x) ~= 'number' or type(me_z) ~= 'number'
        or type(target_x) ~= 'number' or type(target_z) ~= 'number' then
        return nil
    end
    local dx = target_x - me_x
    local dz = target_z - me_z
    if (dx * dx + dz * dz) <= 0.0001 then
        return nil
    end
    return -math.atan2(dz, dx)
end

-- Classify whether an equipped ranged weapon is a firearm (Gun/Cannon) vs Bow/Crossbow/Thrown.
function M.is_firearm_item(item_info)
    if type(item_info) ~= 'table' then
        return false
    end
    if type(item_info.range_type) == 'string' then
        local rt = item_info.range_type:lower()
        return rt == 'gun' or rt == 'cannon'
    end
    if item_info.skill == 26 then
        local name = type(item_info.name) == 'string' and item_info.name:lower() or ''
        if name:find('crossbow', 1, true) or name:find('arbalest', 1, true)
            or name:find('ziska', 1, true) or name:find('xbow', 1, true)
            or name:find('bow', 1, true) then
            return false
        end
        return true
    end
    return false
end

function M.new()
    local self = {
        aim_enabled = true,
        character_id = 0,
        job = 0,
        branch = 0,
        soul = nil,
        active_rule = nil,
        flintlock_active = false,
        requested_target = nil,
        hud_fallback = nil,
        last_advisory_key = nil,
    }

    function self:reset(reason)
        self.requested_target = nil
        if reason == 'logout' or reason == 'character_change' then
            self.character_id = 0
            self.job = 0
            self.branch = 0
            self.soul = nil
            self.active_rule = nil
            self.flintlock_active = false
            self.hud_fallback = nil
            self.last_advisory_key = nil
        end
    end

    function self:on_soul_packet(data, current_job)
        local decoded = M.decode_soul_packet(data, current_job)
        if decoded then
            self.hud_fallback = decoded
        end
        return decoded
    end

    function self:update_context(character_id, job, crystal_status)
        if type(character_id) ~= 'number' or character_id <= 0 or type(job) ~= 'number' or job <= 0 then
            self:reset('logout')
            return false
        end
        if self.character_id ~= 0 and self.character_id ~= character_id then
            self:reset('character_change')
        end

        local prev_active = self.flintlock_active
        self.character_id = character_id
        self.job = job

        local matched_rule = nil
        if type(crystal_status) == 'table' and crystal_status.enabled == 1 and crystal_status.known == 1
            and crystal_status.character_id == character_id and crystal_status.job == job then
            self.branch = crystal_status.branch or 0
            matched_rule = M.ranged_only_rule(job, self.branch)
            self.active_rule = matched_rule
            self.flintlock_active = (matched_rule ~= nil and matched_rule.auto_facing == true)
            self.soul = matched_rule and matched_rule.soul_key or nil
        elseif self.hud_fallback and self.hud_fallback.job == job then
            self.branch = self.hud_fallback.branch or 0
            self.soul = self.hud_fallback.soul
            matched_rule = M.ranged_only_rule(job, self.branch)
                or (self.soul and M.ranged_only_rule_by_key(job, self.soul) or nil)
            self.active_rule = matched_rule
            self.flintlock_active = (matched_rule ~= nil and matched_rule.auto_facing == true)
        else
            self.branch = 0
            self.soul = nil
            self.active_rule = nil
            self.flintlock_active = false
        end

        if prev_active ~= self.flintlock_active then
            self.requested_target = nil
        end
        return prev_active ~= self.flintlock_active
    end

    function self:record_outgoing_ra(data)
        if not self.flintlock_active or not self.aim_enabled then
            return nil
        end
        local target_id = M.parse_outgoing_ra_target(data)
        if target_id then
            self.requested_target = target_id
        end
        return target_id
    end

    function self:resolve_auto_face_target(action, is_firearm)
        if not self.flintlock_active or not self.aim_enabled or not is_firearm then
            return nil
        end
        if type(action) ~= 'table' then
            return nil
        end
        if action.category ~= 12 and action.category ~= 2 then
            return nil
        end
        if self.character_id <= 0 or action.actor_id ~= self.character_id then
            return nil
        end

        local target_id = action.target_id
        if action.category == 12 and target_id == self.character_id then
            target_id = self.requested_target
        end
        self.requested_target = nil

        if action.category == 12 and ((action.param or 0) % 65536 == 0x7073) then
            return nil
        end
        if not target_id or target_id == 0 or target_id == self.character_id then
            return nil
        end
        return target_id
    end

    function self:check_overlay_advisory(overlay_installed, overlay_enabled_at_boot)
        if self.character_id <= 0 or self.job <= 0 then
            return nil
        end
        local key = nil
        local msg = nil
        if self.flintlock_active and overlay_installed and not overlay_enabled_at_boot then
            key = 'flintlock_overlay_off'
            msg = 'COR Flintlock active: dual-pistol DAT overlay is installed but inactive this session. Run /flintlock overlay on (or enable in Launcher) and restart FFXI.'
        elseif not self.flintlock_active and overlay_enabled_at_boot and ranged_only_jobs[self.job] then
            key = 'non_flintlock_cor_overlay_on'
            msg = 'Non-Flintlock COR Soul active while dual-pistol DAT overlay is loaded for this session. Run /flintlock overlay off and restart FFXI for vanilla single-gun visuals.'
        end
        if key and key ~= self.last_advisory_key then
            self.last_advisory_key = key
            return msg
        end
        if not key then
            self.last_advisory_key = nil
        end
        return nil
    end

    return self
end

return M
