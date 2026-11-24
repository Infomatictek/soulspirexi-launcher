-- SoulspireXI Core: Generic Registry-Driven Soul Weapon Presentation & Developer Alignment Studio.
--
-- Integrated directly inside soulspire_core (no standalone player-facing addon).
-- Consumes authoritative registry-generated configuration from:
--   plugins/ashita4/data/soul-weapon-config.json
-- Persists optional developer-only calibration profiles to:
--   plugins/ashita4/data/soul-weapon-calibration.local.json
--
-- Guarantees:
--   * Zero hardcoded Soul names, job IDs, branch IDs, levels, or weapon skills.
--   * Strict schemaVersion (1), registryHash, and FNV-1a32 integrity validation.
--   * Fail-closed if config is missing/stale/invalid or active Soul is unknown.
--   * Evaluates remote characters strictly from observed OXSI peer Soul, never local Soul.
--   * Resolves each equipped weapon's actual model ID independently.
--   * Developer alignment controls and calibration overrides are DISABLED by default.

local bit = require('bit')

local M = {}

M.SCHEMA_VERSION   = 1
M.PEER_TTL_SECONDS = 120
M.MAX_PEERS        = 128

M.RACE_KEYS = {
    'hume_male',
    'hume_female',
    'elvaan_male',
    'elvaan_female',
    'tarutaru_male',
    'tarutaru_female',
    'mithra',
    'galka',
}

M.RACE_ID_TO_KEY = {
    [1] = 'hume_male',
    [2] = 'hume_female',
    [3] = 'elvaan_male',
    [4] = 'elvaan_female',
    [5] = 'tarutaru_male',
    [6] = 'tarutaru_female',
    [7] = 'mithra',
    [8] = 'galka',
}

local function round4(v)
    if type(v) ~= 'number' or v ~= v then return 0 end
    return math.floor(v * 10000 + 0.5) / 10000
end

local function round_int(v)
    if v >= 0 then return math.floor(v + 0.5) end
    return math.ceil(v - 0.5)
end

local function fmt_num(n)
    local r = round4(n)
    if r == 0 then return '0.0' end
    local s = string.format('%.4f', r):gsub('0+$', '')
    if s:sub(-1) == '.' then s = s .. '0' end
    return s
end

local function vec12_to_transform(arr)
    if type(arr) ~= 'table' or #arr ~= 12 then return nil end
    for i = 1, 12 do
        if type(arr[i]) ~= 'number' then return nil end
    end
    return {
        translation      = { x = arr[1], y = arr[2], z = arr[3] },
        rotationDeg      = { pitch = arr[4], yaw = arr[5], roll = arr[6] },
        gripOffset       = { x = arr[7], y = arr[8], z = arr[9] },
        scale            = arr[10],
        weaponSeparation = arr[11],
        backDepth        = arr[12],
    }
end

local function transform_to_vec12(t)
    return {
        round4(t.translation.x),
        round4(t.translation.y),
        round4(t.translation.z),
        round4(t.rotationDeg.pitch),
        round4(t.rotationDeg.yaw),
        round4(t.rotationDeg.roll),
        round4(t.gripOffset.x),
        round4(t.gripOffset.y),
        round4(t.gripOffset.z),
        round4(t.scale),
        round4(t.weaponSeparation),
        round4(t.backDepth),
    }
end

local function clone_transform(t)
    return {
        translation      = { x = t.translation.x, y = t.translation.y, z = t.translation.z },
        rotationDeg      = { pitch = t.rotationDeg.pitch, yaw = t.rotationDeg.yaw, roll = t.rotationDeg.roll },
        gripOffset       = { x = t.gripOffset.x, y = t.gripOffset.y, z = t.gripOffset.z },
        scale            = t.scale,
        weaponSeparation = t.weaponSeparation,
        backDepth        = t.backDepth,
    }
end

local function clone_races(races)
    local out = {}
    for rk, r in pairs(races or {}) do
        out[rk] = {
            raceId      = r.raceId,
            displayName = r.displayName,
            skeletonDat = r.skeletonDat,
            drawn       = { main = clone_transform(r.drawn.main), sub = clone_transform(r.drawn.sub) },
            sheathed    = { main = clone_transform(r.sheathed.main), sub = clone_transform(r.sheathed.sub) },
        }
    end
    return out
end

local function read_u32_le(data, i)
    local a, b, c, d = data:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
end

local function mul_u32(a, b)
    local a_lo = bit.band(a, 0xFFFF)
    local a_hi = bit.rshift(a, 16)
    local b_lo = bit.band(b, 0xFFFF)
    local b_hi = bit.rshift(b, 16)
    local lo = a_lo * b_lo
    local mid = (a_hi * b_lo + a_lo * b_hi) % 65536
    return bit.tobit(lo + mid * 65536)
end

local function fnv1a32_hex(payload)
    local h = bit.tobit(0x811C9DC5)
    local prime = bit.tobit(0x01000193)
    for i = 1, #payload do
        h = bit.bxor(h, payload:byte(i))
        h = mul_u32(h, prime)
    end
    if h < 0 then h = h + 4294967296 end
    return string.format('%08x', h)
end

local function is_lower_hex(s, n)
    return type(s) == 'string' and #s == n and s:match('^[0-9a-f]+$') ~= nil
end

local function canonical_digest_payload(doc)
    local lines = {}
    for _, r in ipairs(doc.rules or {}) do
        lines[#lines + 1] = string.format(
            'R:%s:%d:%d:%d:%d:%d:%d:%d:%d:%s\n',
            tostring(r.soulId or ''),
            tonumber(r.jobId) or 0,
            tonumber(r.branch) or 0,
            tonumber(r.minEffectiveLevel) or 0,
            tonumber(r.modeId) or 0,
            tonumber(r.mainSkillMask) or 0,
            tonumber(r.subSkillMask) or 0,
            tonumber(r.mainItemId) or 0,
            tonumber(r.subItemId) or 0,
            tostring(r.presentationProfile or '')
        )
    end
    for _, a in ipairs(doc.appearanceMasks or {}) do
        lines[#lines + 1] = string.format(
            'A:%s:%d:%d:%d:%d\n',
            tostring(a.soulId or ''),
            tonumber(a.jobId) or 0,
            tonumber(a.branch) or 0,
            a.hideMain and 1 or 0,
            a.hideSub and 1 or 0
        )
    end
    for _, g in ipairs(doc.rangedOnly or {}) do
        lines[#lines + 1] = string.format(
            'G:%s:%d:%d:%d:%d:%s\n',
            tostring(g.soulId or ''),
            tonumber(g.jobId) or 0,
            tonumber(g.branch) or 0,
            g.firearmOnly and 1 or 0,
            g.autoFacing and 1 or 0,
            tostring(g.overlayId or '')
        )
    end
    for _, p in ipairs(doc.presentationProfiles or {}) do
        local races = type(p.races) == 'table' and p.races or {}
        lines[#lines + 1] = string.format(
            'P:%s:%s:%d:%d\n',
            tostring(p.id or ''),
            tostring(p.kind or ''),
            p.visualCertified and 1 or 0,
            #races
        )
        for _, rc in ipairs(races) do
            local ints = {}
            for _, field in ipairs({ 'drawnMain', 'drawnSub', 'sheathedMain', 'sheathedSub' }) do
                local arr = rc[field]
                if type(arr) ~= 'table' or #arr ~= 12 then return nil end
                for i = 1, 12 do
                    local v = tonumber(arr[i])
                    if not v then return nil end
                    ints[#ints + 1] = tostring(round_int(v * 10000.0))
                end
            end
            lines[#lines + 1] = string.format('T:%d:%s\n', tonumber(rc.raceId) or 0, table.concat(ints, ','))
        end
    end
    return table.concat(lines)
end

-- Strict OXSI v1 decoder matching soulspire_soul_action_peers.cpp and peer_souls.lua.
function M.decode_oxsi(data)
    if type(data) ~= 'string' or #data < 24 or #data > 512 then return nil end
    if data:sub(5, 8) ~= 'OXSI' then return nil end
    local ver, op = data:byte(9, 10)
    local actor = read_u32_le(data, 11)
    local character = read_u32_le(data, 15)
    local job, branch, nlen, slen = data:byte(19, 22)
    if ver ~= 1 or (op ~= 0 and op ~= 1) then return nil end
    if not actor or actor == 0 or not character or character == 0 then return nil end
    if not job or job < 1 or job > 22 or not branch or branch > 3 or not nlen or nlen > 24 or not slen or slen > 64 then
        return nil
    end
    local payload_size = 22 + nlen + slen
    local aligned_size = math.floor((payload_size + 3) / 4) * 4
    if #data < aligned_size then return nil end
    if data:sub(payload_size + 1, aligned_size):find('[^%z]') then return nil end
    if #data > aligned_size then
        if #data ~= 512 or data:sub(aligned_size + 1):find('[^%z]') then return nil end
    end
    local name = data:sub(23, 22 + nlen)
    local soul = data:sub(23 + nlen, 22 + nlen + slen)
    if #name < 2 or not name:match('^[%a][%w_%-]*$') then return nil end
    if op == 1 and (branch == 0 or #soul < 2 or not soul:match('^[%w_%-]+$')) then return nil end
    if op == 0 and (branch ~= 0 or slen ~= 0) then return nil end
    return {
        op        = op,
        actor     = actor,
        character = character,
        job       = job,
        branch    = branch,
        name      = name,
        soul      = (op == 1) and soul:lower() or nil,
    }
end

-- Minimal strict JSON parser (zero external deps).
local function parse_json(src)
    if type(src) ~= 'string' or #src == 0 then return nil, 'expected non-empty string' end
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
        return nil, 'unterminated string'
    end
    local function parse_number()
        local s, e = src:find('^%-?%d+%.?%d*[eE]?[%+%-]?%d*', pos)
        if not s then return nil, 'invalid number' end
        pos = e + 1
        return tonumber(src:sub(s, e))
    end
    local function parse_array()
        pos = pos + 1
        local arr = {}
        skip_ws()
        if src:sub(pos, pos) == ']' then pos = pos + 1; return arr end
        while pos <= len do
            local v, err = parse_value()
            if err then return nil, err end
            arr[#arr + 1] = v
            skip_ws()
            local c = src:sub(pos, pos)
            if c == ']' then pos = pos + 1; return arr end
            if c ~= ',' then return nil, 'expected comma or ]' end
            pos = pos + 1
            skip_ws()
        end
        return nil, 'unterminated array'
    end
    local function parse_object()
        pos = pos + 1
        local obj = {}
        skip_ws()
        if src:sub(pos, pos) == '}' then pos = pos + 1; return obj end
        while pos <= len do
            skip_ws()
            if src:sub(pos, pos) ~= '"' then return nil, 'expected key string' end
            local k, kerr = parse_string()
            if kerr then return nil, kerr end
            skip_ws()
            if src:sub(pos, pos) ~= ':' then return nil, 'expected :' end
            pos = pos + 1
            local v, verr = parse_value()
            if verr then return nil, verr end
            obj[k] = v
            skip_ws()
            local c = src:sub(pos, pos)
            if c == '}' then pos = pos + 1; return obj end
            if c ~= ',' then return nil, 'expected comma or }' end
            pos = pos + 1
        end
        return nil, 'unterminated object'
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

local function serialize_vec12(arr)
    local parts = {}
    for i = 1, 12 do
        parts[i] = fmt_num(arr[i])
    end
    return '[' .. table.concat(parts, ', ') .. ']'
end

local function serialize_transform(t, indent)
    local p = indent .. '  '
    return table.concat({
        '{',
        p .. ('"translation": { "x": %s, "y": %s, "z": %s },'):format(fmt_num(t.translation.x), fmt_num(t.translation.y), fmt_num(t.translation.z)),
        p .. ('"rotationDeg": { "pitch": %s, "yaw": %s, "roll": %s },'):format(fmt_num(t.rotationDeg.pitch), fmt_num(t.rotationDeg.yaw), fmt_num(t.rotationDeg.roll)),
        p .. ('"gripOffset": { "x": %s, "y": %s, "z": %s },'):format(fmt_num(t.gripOffset.x), fmt_num(t.gripOffset.y), fmt_num(t.gripOffset.z)),
        p .. ('"scale": %s,'):format(fmt_num(t.scale)),
        p .. ('"weaponSeparation": %s,'):format(fmt_num(t.weaponSeparation)),
        p .. ('"backDepth": %s'):format(fmt_num(t.backDepth)),
        indent .. '}',
    }, '\n')
end

-- Optional live bridge to trigger SoulspireNativeReloadConfig() when soulspire_native.dll is loaded.
local function default_native_reload()
    local ok_ffi, ffi = pcall(require, 'ffi')
    if not ok_ffi or not ffi then return false, 'ffi unavailable' end
    local ok, res = pcall(function()
        pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char*);')
        pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void*, const char*);')
        local mod = ffi.C.GetModuleHandleA('soulspire_native.dll')
        if mod == nil then return false, 'soulspire_native.dll not loaded' end
        local addr = ffi.C.GetProcAddress(mod, 'SoulspireNativeReloadConfig')
        if addr == nil then return false, 'SoulspireNativeReloadConfig export missing' end
        local fn = ffi.cast('uint32_t (__stdcall *)(void)', addr)
        return fn() == 0, nil
    end)
    if not ok then return false, tostring(res) end
    return res == true, nil
end

function M.new(config_path, calibration_path, native_reload_fn)
    local self = {
        config_path         = config_path,
        calibration_path    = calibration_path,
        native_reload_fn    = native_reload_fn or default_native_reload,
        loaded              = false,
        registry_hash       = '',
        weapon_config_hash  = '',
        load_error          = 'not loaded',
        bindings            = {},
        base_profiles       = {},
        profiles            = {},
        profile_order       = {},
        diagnostics_enabled = false, -- Strictly disabled by default!
        peers_by_actor      = {},
        peer_count          = 0,
        selected_profile_idx = 1,
        selected_race_idx   = 1,
        selected_stance     = 'sheathed',
        selected_hand       = 'main',
        last_export_status  = nil,
        native_sync_count   = 0,
    }

    function self:is_loaded()
        return self.loaded == true
    end

    function self:is_diagnostics_enabled()
        return self.diagnostics_enabled == true
    end

    function self:set_diagnostics_enabled(flag)
        self.diagnostics_enabled = (flag == true)
        if not self.diagnostics_enabled then
            -- Restoring baseline presentation immediately when diagnostics are turned off.
            for pid, prof in pairs(self.base_profiles) do
                if self.profiles[pid] and prof.races then
                    self.profiles[pid].races = clone_races(prof.races)
                end
            end
        end
    end

    function self:active_profile_id()
        return self.profile_order[self.selected_profile_idx]
    end

    function self:active_profile()
        local pid = self:active_profile_id()
        return pid and self.profiles[pid] or nil
    end

    function self:reset_transforms()
        for pid, prof in pairs(self.base_profiles) do
            if self.profiles[pid] and prof.races then
                self.profiles[pid].races = clone_races(prof.races)
            end
        end
    end

    function self:clear()
        self.loaded = false
        self.registry_hash = ''
        self.weapon_config_hash = ''
        self.load_error = 'cleared'
        self.bindings = {}
        self.base_profiles = {}
        self.profiles = {}
        self.profile_order = {}
    end

    function self:load_json_string(src, expected_registry_hash)
        local doc, err = parse_json(src)
        if not doc or type(doc) ~= 'table' then
            self:clear()
            self.load_error = 'parse error: ' .. tostring(err)
            return false, self.load_error
        end
        if doc.schemaVersion ~= M.SCHEMA_VERSION then
            self:clear()
            self.load_error = 'unsupported schemaVersion: ' .. tostring(doc.schemaVersion)
            return false, self.load_error
        end
        if not is_lower_hex(doc.registryHash, 16) then
            self:clear()
            self.load_error = 'invalid registryHash'
            return false, self.load_error
        end
        if type(expected_registry_hash) == 'string' and expected_registry_hash ~= ''
            and doc.registryHash ~= expected_registry_hash then
            self:clear()
            self.load_error = 'stale registryHash'
            return false, self.load_error
        end
        if not is_lower_hex(doc.integrityFnv1a32, 8) then
            self:clear()
            self.load_error = 'missing integrityFnv1a32'
            return false, self.load_error
        end
        local payload = canonical_digest_payload(doc)
        if not payload or fnv1a32_hex(payload) ~= doc.integrityFnv1a32 then
            self:clear()
            self.load_error = 'integrityFnv1a32 mismatch'
            return false, self.load_error
        end

        local profiles = {}
        local base_profiles = {}
        local order = {}
        for _, p in ipairs(doc.presentationProfiles or {}) do
            if type(p) == 'table' and type(p.id) == 'string' and p.id ~= '' then
                local races_map = nil
                if type(p.races) == 'table' and #p.races == 8 then
                    races_map = {}
                    for _, rc in ipairs(p.races) do
                        local rk = rc.key or M.RACE_ID_TO_KEY[rc.raceId]
                        local dm = vec12_to_transform(rc.drawnMain)
                        local ds = vec12_to_transform(rc.drawnSub)
                        local sm = vec12_to_transform(rc.sheathedMain)
                        local ss = vec12_to_transform(rc.sheathedSub)
                        if not rk or not dm or not ds or not sm or not ss then
                            self:clear()
                            self.load_error = 'malformed race transform in profile ' .. p.id
                            return false, self.load_error
                        end
                        races_map[rk] = {
                            raceId      = rc.raceId,
                            displayName = rc.displayName or rk,
                            skeletonDat = rc.skeletonDat or '',
                            drawn       = { main = dm, sub = ds },
                            sheathed    = { main = sm, sub = ss },
                        }
                    end
                    order[#order + 1] = p.id
                end
                local entry = {
                    id                      = p.id,
                    kind                    = p.kind,
                    visualCertified         = p.visualCertified == true,
                    requiresNative3dBoneHook = p.requiresNative3dBoneHook == true,
                    races                   = races_map,
                }
                base_profiles[p.id] = {
                    id                      = p.id,
                    kind                    = p.kind,
                    visualCertified         = p.visualCertified == true,
                    requiresNative3dBoneHook = p.requiresNative3dBoneHook == true,
                    races                   = races_map and clone_races(races_map) or nil,
                }
                profiles[p.id] = entry
            end
        end

        local bindings = {}
        for _, r in ipairs(doc.rules or {}) do
            if type(r) == 'table' and type(r.jobId) == 'number' and type(r.branch) == 'number'
                and type(r.mainSkillMask) == 'number' and type(r.subSkillMask) == 'number' then
                bindings[#bindings + 1] = {
                    soul_id              = tostring(r.soulId or ''),
                    soul_key             = tostring(r.soulKey or ''),
                    job                  = r.jobId,
                    branch               = r.branch,
                    min_effective_level  = tonumber(r.minEffectiveLevel) or 10,
                    mode                 = tostring(r.mode or ''),
                    mode_id              = tonumber(r.modeId) or 0,
                    main_skill_mask      = r.mainSkillMask,
                    sub_skill_mask       = r.subSkillMask,
                    main_item_id         = tonumber(r.mainItemId) or 0,
                    sub_item_id          = tonumber(r.subItemId) or 0,
                    presentation_profile = tostring(r.presentationProfile or ''),
                }
            end
        end

        self.bindings           = bindings
        self.base_profiles      = base_profiles
        self.profiles           = profiles
        self.profile_order      = order
        self.registry_hash      = doc.registryHash
        self.weapon_config_hash = tostring(doc.weaponConfigHash or '')
        self.loaded             = true
        self.load_error         = nil
        self.selected_profile_idx = 1
        return true, nil
    end

    function self:load_file(path, expected_registry_hash)
        local target = path or self.config_path
        if type(target) ~= 'string' or target == '' then
            self:clear()
            self.load_error = 'missing config path'
            return false, self.load_error
        end
        local f = io.open(target, 'rb')
        if not f then
            self:clear()
            self.load_error = 'file not found: ' .. target
            return false, self.load_error
        end
        local content = f:read('*a')
        f:close()
        local ok, err = self:load_json_string(content, expected_registry_hash)
        if ok then
            self.config_path = target
        end
        return ok, err
    end

    -- Peer Soul tracking (OXSI 0x1FC) — strictly isolated per observed actor.
    function self:reset_peers()
        self.peers_by_actor = {}
        self.peer_count = 0
    end

    function self:observe_oxsi_packet(packet_bytes, now_sec)
        local decoded = M.decode_oxsi(packet_bytes)
        if not decoded then return false end
        local ts = tonumber(now_sec) or 0
        if decoded.op == 0 then
            if self.peers_by_actor[decoded.actor] then
                self.peers_by_actor[decoded.actor] = nil
                self.peer_count = math.max(0, self.peer_count - 1)
            end
            return true
        end
        if not self.peers_by_actor[decoded.actor] then
            if self.peer_count >= M.MAX_PEERS then
                local oldest_id, oldest_ts = nil, math.huge
                for aid, rec in pairs(self.peers_by_actor) do
                    if (rec.updated_at or 0) < oldest_ts then
                        oldest_id, oldest_ts = aid, rec.updated_at or 0
                    end
                end
                if oldest_id then
                    self.peers_by_actor[oldest_id] = nil
                    self.peer_count = math.max(0, self.peer_count - 1)
                end
            end
            self.peer_count = self.peer_count + 1
        end
        self.peers_by_actor[decoded.actor] = {
            actor           = decoded.actor,
            character       = decoded.character,
            job             = decoded.job,
            branch          = decoded.branch,
            soul            = decoded.soul,
            effective_level = 75,
            updated_at      = ts,
        }
        return true
    end
    self.observe_oxsi = self.observe_oxsi_packet

    function self:get_peer(actor_id, now_sec)
        local rec = self.peers_by_actor[actor_id]
        if not rec then return nil end
        local ts = tonumber(now_sec) or 0
        if (ts - (rec.updated_at or 0)) > M.PEER_TTL_SECONDS then
            return nil
        end
        return rec
    end

    -- Generic, zero-hardcode evaluation using authoritative loaded bindings & profiles.
    function self:evaluate(query)
        if not self.loaded or type(query) ~= 'table' then return { state = 'vanilla' } end
        if query.is_dead or query.distinct_items == false then return { state = 'vanilla' } end

        local race_key = type(query.race) == 'number' and M.RACE_ID_TO_KEY[query.race] or query.race
        if type(race_key) ~= 'string' then return { state = 'vanilla' } end

        local main_skill = tonumber(query.main_skill) or 0
        local sub_skill  = tonumber(query.sub_skill) or 0
        if (query.main_item_id or 0) <= 0 or (query.sub_item_id or 0) <= 0
            or (query.main_model_id or 0) <= 0 or (query.sub_model_id or 0) <= 0
            or main_skill < 1 or main_skill >= 32 or sub_skill < 1 or sub_skill >= 32 then
            return { state = 'vanilla' }
        end

        local job, branch, lvl
        if query.is_local then
            if query.soul_known ~= true then return { state = 'vanilla' } end
            job, branch, lvl = query.job, query.branch, query.effective_level or 0
        else
            local peer = self:get_peer(query.actor_id, query.now_sec or 0)
            if not peer then return { state = 'vanilla' } end
            job, branch = peer.job, peer.branch
            lvl = query.effective_level or peer.effective_level or 0
        end

        local main_bit = bit.lshift(1, main_skill)
        local sub_bit  = bit.lshift(1, sub_skill)
        local matched = nil
        for _, b in ipairs(self.bindings) do
            if b.job == job and b.branch == branch and lvl >= b.min_effective_level
                and bit.band(b.main_skill_mask, main_bit) ~= 0
                and bit.band(b.sub_skill_mask, sub_bit) ~= 0
                and (b.main_item_id == 0 or b.main_item_id == query.main_item_id)
                and (b.sub_item_id == 0 or b.sub_item_id == query.sub_item_id)
                and b.presentation_profile ~= ''
            then
                matched = b
                break
            end
        end
        if not matched then return { state = 'vanilla' } end

        local prof = self.profiles[matched.presentation_profile]
        if not prof or not prof.races or not prof.races[race_key] then
            return { state = 'vanilla' }
        end

        local rset = prof.races[race_key]
        local drawn_state, sheathed_state
        if prof.kind == 'dual_2h_attachments' then
            drawn_state, sheathed_state = 'drawn_dual_2h', 'sheathed_cross_x'
        elseif prof.kind == 'twohand_shield_attachments' then
            drawn_state, sheathed_state = 'drawn_twohand_shield', 'sheathed_twohand_shield'
        elseif prof.kind == 'dual_1h_attachments' then
            drawn_state, sheathed_state = 'drawn_dual_1h', 'sheathed_dual_1h'
        else
            return { state = 'vanilla' }
        end

        if query.is_engaged then
            return {
                state          = drawn_state,
                soul_id        = matched.soul_id,
                profile_id     = prof.id,
                race_key       = race_key,
                main_model_id  = query.main_model_id,
                sub_model_id   = query.sub_model_id,
                main_transform = clone_transform(rset.drawn.main),
                sub_transform  = clone_transform(rset.drawn.sub),
            }
        end
        return {
            state          = sheathed_state,
            soul_id        = matched.soul_id,
            profile_id     = prof.id,
            race_key       = race_key,
            main_model_id  = query.main_model_id,
            sub_model_id   = query.sub_model_id,
            main_transform = clone_transform(rset.sheathed.main),
            sub_transform  = clone_transform(rset.sheathed.sub),
        }
    end

    -- Developer-only live transform adjustment (strictly gated on diagnostics_enabled).
    function self:set_transform(race_key, stance, hand, xform, profile_id)
        if not self.diagnostics_enabled or not self.loaded then
            return false, 'diagnostics disabled or config unloaded'
        end
        local pid = profile_id or self:active_profile_id()
        local prof = pid and self.profiles[pid] or nil
        if not prof or not prof.races or not prof.races[race_key] then
            return false, 'invalid profile or race'
        end
        if stance ~= 'drawn' and stance ~= 'sheathed' then return false, 'invalid stance' end
        if hand ~= 'main' and hand ~= 'sub' then return false, 'invalid hand' end
        if type(xform) ~= 'table' or type(xform.scale) ~= 'number' or xform.scale < 0.25 or xform.scale > 2.5 then
            return false, 'invalid scale'
        end
        prof.races[race_key][stance][hand] = clone_transform(xform)
        return true, nil
    end

    function self:get_transform(race_key, stance, hand, profile_id)
        local pid = profile_id or self:active_profile_id()
        local prof = pid and self.profiles[pid] or nil
        if not prof or not prof.races or not prof.races[race_key] then return nil end
        return prof.races[race_key][stance] and prof.races[race_key][stance][hand] or nil
    end

    -- Serialize persistent developer calibration profile (consumed by C++ apply_weapon_calibration_json).
    function self:serialize_calibration_json()
        local ov_lines = {}
        for _, pid in ipairs(self.profile_order) do
            local prof = self.profiles[pid]
            if prof and prof.races then
                for idx, rk in ipairs(M.RACE_KEYS) do
                    local r = prof.races[rk]
                    if r then
                        ov_lines[#ov_lines + 1] = table.concat({
                            '    {',
                            ('      "profileId": "%s",'):format(pid),
                            ('      "raceId": %d,'):format(r.raceId or idx),
                            ('      "drawnMain": %s,'):format(serialize_vec12(transform_to_vec12(r.drawn.main))),
                            ('      "drawnSub": %s,'):format(serialize_vec12(transform_to_vec12(r.drawn.sub))),
                            ('      "sheathedMain": %s,'):format(serialize_vec12(transform_to_vec12(r.sheathed.main))),
                            ('      "sheathedSub": %s'):format(serialize_vec12(transform_to_vec12(r.sheathed.sub))),
                            '    }',
                        }, '\n')
                    end
                end
            end
        end
        return table.concat({
            '{',
            '  "schemaVersion": 1,',
            ('  "diagnosticsEnabled": %s,'):format(self.diagnostics_enabled and 'true' or 'false'),
            ('  "registryHash": "%s",'):format(self.registry_hash),
            '  "overrides": [',
            table.concat(ov_lines, ',\n'),
            '  ]',
            '}',
            '',
        }, '\n')
    end

    function self:save_calibration_and_sync_native(path)
        local target = path or self.calibration_path
        if type(target) ~= 'string' or target == '' then
            return false, 'calibration_path is not configured'
        end
        local f, err = io.open(target, 'wb')
        if not f then return false, tostring(err) end
        f:write(self:serialize_calibration_json())
        f:close()
        local ok_native = false
        if type(self.native_reload_fn) == 'function' then
            ok_native = self.native_reload_fn() == true
            if ok_native then self.native_sync_count = self.native_sync_count + 1 end
        end
        return true, target, ok_native
    end

    function self:load_calibration_file(path)
        local target = path or self.calibration_path
        if type(target) ~= 'string' or target == '' then return false, 'no calibration path' end
        local f = io.open(target, 'rb')
        if not f then return false, 'calibration file not found' end
        local content = f:read('*a')
        f:close()
        local doc, err = parse_json(content)
        if not doc or type(doc) ~= 'table' or doc.diagnosticsEnabled ~= true then
            return false, err or 'diagnostics disabled in calibration file'
        end
        self.diagnostics_enabled = true
        for _, ov in ipairs(doc.overrides or {}) do
            local rk = M.RACE_ID_TO_KEY[ov.raceId]
            local prof = ov.profileId and self.profiles[ov.profileId] or nil
            if rk and prof and prof.races and prof.races[rk] then
                local dm = vec12_to_transform(ov.drawnMain)
                local ds = vec12_to_transform(ov.drawnSub)
                local sm = vec12_to_transform(ov.sheathedMain)
                local ss = vec12_to_transform(ov.sheathedSub)
                if dm and ds and sm and ss then
                    prof.races[rk].drawn.main = dm
                    prof.races[rk].drawn.sub = ds
                    prof.races[rk].sheathed.main = sm
                    prof.races[rk].sheathed.sub = ss
                end
            end
        end
        return true, nil
    end

    -- Export finalized profile transforms in registry/weapon_configs.json format.
    function self:export_profile_json(profile_id)
        local pid = profile_id or self:active_profile_id()
        local prof = pid and self.profiles[pid] or nil
        if not prof or not prof.races then return nil, 'no active presentation profile' end
        local race_blocks = {}
        for _, rk in ipairs(M.RACE_KEYS) do
            local r = prof.races[rk]
            race_blocks[#race_blocks + 1] = table.concat({
                ('    "%s": {'):format(rk),
                ('      "raceId": %d,'):format(r.raceId),
                ('      "displayName": "%s",'):format(r.displayName),
                ('      "skeletonDat": "%s",'):format(r.skeletonDat),
                '      "drawn": {',
                '        "main": ' .. serialize_transform(r.drawn.main, '        ') .. ',',
                '        "sub": ' .. serialize_transform(r.drawn.sub, '        '),
                '      },',
                '      "sheathed": {',
                '        "main": ' .. serialize_transform(r.sheathed.main, '        ') .. ',',
                '        "sub": ' .. serialize_transform(r.sheathed.sub, '        '),
                '      }',
                '    }',
            }, '\n')
        end
        return table.concat({
            '{',
            ('  "profileId": "%s",'):format(prof.id),
            ('  "kind": "%s",'):format(prof.kind),
            ('  "registryHash": "%s",'):format(self.registry_hash),
            '  "visualCertified": false,',
            '  "races": {',
            table.concat(race_blocks, ',\n'),
            '  }',
            '}',
            '',
        }, '\n'), nil
    end

    function self:export_file(path, profile_id)
        local target = path or (self.calibration_path and (self.calibration_path .. '.export.json'))
        if type(target) ~= 'string' or target == '' then
            self.last_export_status = 'error: no export path'
            return false, self.last_export_status
        end
        local payload, perr = self:export_profile_json(profile_id)
        if not payload then
            self.last_export_status = 'error: ' .. tostring(perr)
            return false, self.last_export_status
        end
        local f, err = io.open(target, 'wb')
        if not f then
            self.last_export_status = 'error: ' .. tostring(err)
            return false, self.last_export_status
        end
        f:write(payload)
        f:close()
        self.last_export_status = 'exported: ' .. target
        return true, target
    end

    function self:status()
        return {
            loaded              = self.loaded,
            registry_hash       = self.registry_hash,
            weapon_config_hash  = self.weapon_config_hash,
            binding_count       = #self.bindings,
            profile_count       = #self.profile_order,
            diagnostics_enabled = self.diagnostics_enabled,
            peer_count          = self.peer_count,
            native_sync_count   = self.native_sync_count,
            error               = self.load_error,
        }
    end

    -- Developer-only ImGui alignment studio (strictly hidden unless diagnostics_enabled == true).
    function self:draw_diagnostics_panel(imgui)
        if not self.diagnostics_enabled or not imgui then return end
        local open = { true }
        if imgui.Begin('SoulspireXI Weapon Alignment Studio (Dev Only)', open) then
            if not self.loaded then
                imgui.Text('Config NOT loaded (fail-closed): ' .. tostring(self.load_error))
                imgui.End()
                return
            end
            local pid = self:active_profile_id()
            local prof = self:active_profile()
            local rk = M.RACE_KEYS[self.selected_race_idx] or 'hume_male'
            local r = prof and prof.races and prof.races[rk] or nil
            imgui.Text(('Profile: %s | Hash: %s | Peers: %d'):format(
                tostring(pid), self.weapon_config_hash, self.peer_count))
            imgui.Text(('Race: %s (%s) | Stance: %s | Slot: %s'):format(
                r and r.displayName or rk, r and r.skeletonDat or '?', self.selected_stance, self.selected_hand))
            imgui.Separator()

            if #self.profile_order > 1 then
                if imgui.Button('Prev Profile') then
                    self.selected_profile_idx = ((self.selected_profile_idx - 2) % #self.profile_order) + 1
                end
                imgui.SameLine()
                if imgui.Button('Next Profile') then
                    self.selected_profile_idx = (self.selected_profile_idx % #self.profile_order) + 1
                end
            end

            if imgui.Button('Prev Race') then
                self.selected_race_idx = ((self.selected_race_idx - 2) % #M.RACE_KEYS) + 1
            end
            imgui.SameLine()
            if imgui.Button('Next Race') then
                self.selected_race_idx = (self.selected_race_idx % #M.RACE_KEYS) + 1
            end
            imgui.SameLine()
            if imgui.Button(self.selected_stance == 'drawn' and 'Switch -> Sheathed' or 'Switch -> Drawn') then
                self.selected_stance = (self.selected_stance == 'drawn') and 'sheathed' or 'drawn'
            end
            imgui.SameLine()
            if imgui.Button(self.selected_hand == 'main' and 'Edit Sub' or 'Edit Main') then
                self.selected_hand = (self.selected_hand == 'main') and 'sub' or 'main'
            end

            local xform = self:get_transform(rk, self.selected_stance, self.selected_hand, pid)
            if xform and imgui.SliderFloat then
                local changed = false
                local function slider(label, val, lo, hi)
                    local buf = { val }
                    if imgui.SliderFloat(label, buf, lo, hi) then
                        changed = true
                        return round4(buf[1])
                    end
                    return val
                end
                xform.translation.x     = slider('Pos X', xform.translation.x, -0.5, 0.5)
                xform.translation.y     = slider('Pos Y', xform.translation.y, -0.5, 0.5)
                xform.translation.z     = slider('Pos Z', xform.translation.z, -0.5, 0.5)
                xform.rotationDeg.pitch = slider('Pitch (deg)', xform.rotationDeg.pitch, -180.0, 180.0)
                xform.rotationDeg.yaw   = slider('Yaw (deg)', xform.rotationDeg.yaw, -180.0, 180.0)
                xform.rotationDeg.roll  = slider('Roll (deg)', xform.rotationDeg.roll, -180.0, 180.0)
                xform.gripOffset.x      = slider('Grip X', xform.gripOffset.x, -0.5, 0.5)
                xform.gripOffset.y      = slider('Grip Y', xform.gripOffset.y, -0.5, 0.5)
                xform.gripOffset.z      = slider('Grip Z', xform.gripOffset.z, -0.5, 0.5)
                xform.scale             = slider('Scale', xform.scale, 0.5, 1.5)
                xform.weaponSeparation  = slider('Weapon Separation', xform.weaponSeparation, 0.0, 0.3)
                xform.backDepth         = slider('Back Attachment Depth', xform.backDepth, 0.0, 0.4)
                if changed and self.calibration_path then
                    self:save_calibration_and_sync_native()
                end
            end

            imgui.Separator()
            if imgui.Button('Mirror Main -> Sub') and r then
                local src = r[self.selected_stance].main
                local dst = clone_transform(src)
                dst.translation.x    = -src.translation.x
                dst.rotationDeg.yaw  = -src.rotationDeg.yaw
                dst.rotationDeg.roll = -src.rotationDeg.roll
                if self.selected_stance == 'sheathed' then
                    dst.translation.z = round4(src.translation.z + 0.038)
                    dst.backDepth     = dst.translation.z
                end
                r[self.selected_stance].sub = dst
                if self.calibration_path then self:save_calibration_and_sync_native() end
            end
            imgui.SameLine()
            if imgui.Button('Save Calibration') then
                local ok, path, synced = self:save_calibration_and_sync_native()
                self.last_export_status = ok and ('saved: ' .. tostring(path) .. ' (native=' .. tostring(synced) .. ')') or ('err: ' .. tostring(path))
            end
            imgui.SameLine()
            if imgui.Button('Reset All') then
                self:reset_transforms()
                if self.calibration_path then self:save_calibration_and_sync_native() end
            end
            imgui.SameLine()
            if imgui.Button('Export JSON') then
                self:export_file()
            end
            if self.last_export_status then
                imgui.Text(self.last_export_status)
            end
        end
        imgui.End()
        if not open[1] then
            self:set_diagnostics_enabled(false)
            if self.calibration_path then self:save_calibration_and_sync_native() end
        end
    end

    return self
end

return M
