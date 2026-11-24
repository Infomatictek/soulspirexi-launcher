-- SoulspireXI Core: Reusable Soul Weapon Presentation & Developer Alignment Studio.
--
-- Integrated directly inside soulspire_core (no standalone player-facing addon).
-- Consumes and exports the authoritative configuration at:
--   plugins/ashita4/data/soul-weapon-presentation.json
--
-- Guarantees:
--   * Fail-closed if active Soul identity is unknown, expired, or unsynchronized.
--   * Never infers Berserker eligibility from Warrior base job alone.
--   * Evaluates remote characters strictly from the observed actor's verified OXSI
--     peer Soul + equipment, never the local player's Soul.
--   * Preserves each equipped Great Axe's actual model ID independently.
--   * Developer live-adjustment diagnostics are disabled by default.

local M = {}

M.WAR_JOB_ID           = 1
M.BERSERKER_BRANCH     = 2
M.BERSERKER_MIN_LEVEL  = 10
M.GREAT_AXE_SKILL      = 6
M.PEER_TTL_SECONDS     = 120
M.MAX_PEERS            = 128

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

M.RACE_META = {
    hume_male       = { raceId = 1, displayName = 'Hume Male',       skeletonDat = 'ROM/27/82.DAT' },
    hume_female     = { raceId = 2, displayName = 'Hume Female',     skeletonDat = 'ROM/32/58.DAT' },
    elvaan_male     = { raceId = 3, displayName = 'Elvaan Male',     skeletonDat = 'ROM/37/31.DAT' },
    elvaan_female   = { raceId = 4, displayName = 'Elvaan Female',   skeletonDat = 'ROM/42/4.DAT'  },
    tarutaru_male   = { raceId = 5, displayName = 'Tarutaru Male',   skeletonDat = 'ROM/46/93.DAT' },
    tarutaru_female = { raceId = 6, displayName = 'Tarutaru Female', skeletonDat = 'ROM/46/93.DAT' },
    mithra          = { raceId = 7, displayName = 'Mithra',          skeletonDat = 'ROM/51/89.DAT' },
    galka           = { raceId = 8, displayName = 'Galka',           skeletonDat = 'ROM/56/59.DAT' },
}

local function round4(v)
    if type(v) ~= 'number' or v ~= v then return 0 end
    return math.floor(v * 10000 + 0.5) / 10000
end

local function make_race_set(dtx, dty, dtz, dpitch, droll, dgrip_y, scale, dsep,
                             stx, sty, stz, spitch, syaw, sroll, sgrip_y, ssep, depth_sep)
    return {
        drawn = {
            main = {
                translation      = { x = -dtx, y = dty, z = dtz },
                rotationDeg      = { pitch = dpitch, yaw = 0.0, roll = -droll },
                gripOffset       = { x = 0.0, y = dgrip_y, z = 0.0 },
                scale            = scale,
                weaponSeparation = dsep,
                backDepth        = 0.0,
            },
            sub = {
                translation      = { x = dtx, y = dty, z = dtz },
                rotationDeg      = { pitch = dpitch, yaw = 0.0, roll = droll },
                gripOffset       = { x = 0.0, y = dgrip_y, z = 0.0 },
                scale            = scale,
                weaponSeparation = dsep,
                backDepth        = 0.0,
            },
        },
        sheathed = {
            main = {
                translation      = { x = -stx, y = sty, z = stz },
                rotationDeg      = { pitch = spitch, yaw = -syaw, roll = sroll },
                gripOffset       = { x = 0.0, y = sgrip_y, z = 0.0 },
                scale            = scale,
                weaponSeparation = ssep,
                backDepth        = stz,
            },
            sub = {
                translation      = { x = stx, y = sty, z = round4(stz + depth_sep) },
                rotationDeg      = { pitch = spitch, yaw = syaw, roll = -sroll },
                gripOffset       = { x = 0.0, y = sgrip_y, z = 0.0 },
                scale            = scale,
                weaponSeparation = ssep,
                backDepth        = round4(stz + depth_sep),
            },
        },
    }
end

function M.default_races()
    return {
        hume_male       = make_race_set(0.012, 0.008, -0.015,  8.0, 6.0, -0.180, 0.94, 0.040, 0.045, 0.060, 0.145, 6.0, 8.0, 42.0, -0.120, 0.090, 0.038),
        hume_female     = make_race_set(0.010, 0.006, -0.014,  8.0, 5.5, -0.165, 0.90, 0.036, 0.040, 0.055, 0.135, 5.5, 7.5, 41.0, -0.110, 0.080, 0.036),
        elvaan_male     = make_race_set(0.014, 0.010, -0.016,  7.5, 6.0, -0.200, 0.96, 0.044, 0.050, 0.075, 0.155, 6.5, 8.0, 43.0, -0.130, 0.100, 0.040),
        elvaan_female   = make_race_set(0.012, 0.008, -0.015,  7.5, 5.5, -0.185, 0.92, 0.038, 0.044, 0.068, 0.145, 6.0, 7.5, 42.0, -0.120, 0.088, 0.038),
        tarutaru_male   = make_race_set(0.008, 0.012, -0.012, 11.0, 7.0, -0.115, 0.78, 0.030, 0.032, 0.045, 0.115, 7.0, 9.0, 39.0, -0.080, 0.064, 0.032),
        tarutaru_female = make_race_set(0.008, 0.012, -0.012, 11.0, 7.0, -0.115, 0.78, 0.030, 0.032, 0.045, 0.118, 7.0, 9.0, 39.0, -0.080, 0.064, 0.032),
        mithra          = make_race_set(0.011, 0.007, -0.015,  8.5, 6.0, -0.170, 0.91, 0.038, 0.042, 0.058, 0.142, 6.0, 8.0, 41.5, -0.115, 0.084, 0.036),
        galka           = make_race_set(0.018, 0.014, -0.020,  7.0, 6.5, -0.220, 1.04, 0.055, 0.062, 0.085, 0.205, 8.0, 9.5, 44.0, -0.145, 0.124, 0.044),
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

local function fmt_num(n)
    local r = round4(n)
    if r == 0 then return '0.0' end
    local s = string.format('%.4f', r):gsub('0+$', '')
    if s:sub(-1) == '.' then s = s .. '0' end
    return s
end

local function read_u32_le(data, i)
    local a, b, c, d = data:byte(i, i + 3)
    if not d then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
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

-- Minimal strict JSON decoder (sufficient for soul-weapon-presentation.json without external deps).
local function parse_json(src)
    if type(src) ~= 'string' then return nil, 'expected string' end
    local pos = 1
    local len = #src
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
            if ch == '"' then
                pos = pos + 1
                return table.concat(out)
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
    local val, err = parse_value()
    if err then return nil, err end
    return val, nil
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

function M.new(config_path)
    local self = {
        config_path         = config_path,
        races               = M.default_races(),
        diagnostics_enabled = false, -- Strictly disabled by default!
        peers_by_actor      = {},
        peer_count          = 0,
        selected_race_idx   = 1,
        selected_stance     = 'sheathed', -- 'drawn' | 'sheathed'
        selected_hand       = 'main',     -- 'main' | 'sub'
        last_export_status  = nil,
    }

    function self:is_diagnostics_enabled()
        return self.diagnostics_enabled == true
    end

    function self:set_diagnostics_enabled(flag)
        self.diagnostics_enabled = (flag == true)
        return self.diagnostics_enabled
    end

    function self:reset_peers()
        self.peers_by_actor = {}
        self.peer_count = 0
    end

    function self:reset_transforms()
        self.races = M.default_races()
    end

    -- Observe authoritative OXSI packet for remote player Soul tracking.
    function self:observe_oxsi(raw_packet, now_sec)
        local dec = M.decode_oxsi(raw_packet)
        if not dec then return false end
        local ts = type(now_sec) == 'number' and now_sec or 0
        local prev = self.peers_by_actor[dec.actor]
        if dec.op == 0 then
            if prev then
                self.peers_by_actor[dec.actor] = nil
                self.peer_count = math.max(0, self.peer_count - 1)
            end
            return true
        end
        if not prev then
            if self.peer_count >= M.MAX_PEERS then
                self:reset_peers()
            end
            self.peer_count = self.peer_count + 1
        end
        self.peers_by_actor[dec.actor] = {
            actor     = dec.actor,
            character = dec.character,
            job       = dec.job,
            branch    = dec.branch,
            name      = dec.name,
            soul      = dec.soul,
            expires   = ts + M.PEER_TTL_SECONDS,
        }
        return true
    end

    function self:get_peer(actor_id, now_sec)
        local rec = self.peers_by_actor[actor_id]
        if not rec then return nil end
        if type(now_sec) == 'number' and now_sec > rec.expires then
            self.peers_by_actor[actor_id] = nil
            self.peer_count = math.max(0, self.peer_count - 1)
            return nil
        end
        return rec
    end

    -- Evaluate local or remote character weapon presentation.
    -- Strictly fail-closed when Soul identity is unknown/unsynced or not WAR Berserker.
    function self:evaluate_actor(ctx)
        if type(ctx) ~= 'table' or ctx.is_dead == true or ctx.distinct_items == false then
            return { state = 'vanilla' }
        end
        local race_key = M.RACE_ID_TO_KEY[ctx.race_id]
        if not race_key or not self.races[race_key] then
            return { state = 'vanilla' }
        end
        if (ctx.main_item_id or 0) <= 0 or (ctx.sub_item_id or 0) <= 0 then
            return { state = 'vanilla' }
        end
        if (ctx.main_model_id or 0) <= 0 or (ctx.sub_model_id or 0) <= 0 then
            return { state = 'vanilla' }
        end
        if ctx.main_skill ~= M.GREAT_AXE_SKILL or ctx.sub_skill ~= M.GREAT_AXE_SKILL then
            return { state = 'vanilla' }
        end

        local job, branch, lvl = 0, 0, 0
        if ctx.is_local == true then
            if ctx.soul_known ~= true then
                return { state = 'vanilla' }
            end
            job    = ctx.job or 0
            branch = ctx.branch or 0
            lvl    = ctx.effective_level or 0
        else
            -- Remote character rendering MUST evaluate observed character's peer Soul, NEVER local Soul.
            local peer = self:get_peer(ctx.actor_id, ctx.now_sec)
            if not peer then
                return { state = 'vanilla' }
            end
            job    = peer.job or 0
            branch = peer.branch or 0
            lvl    = ctx.effective_level or M.BERSERKER_MIN_LEVEL
        end

        if job ~= M.WAR_JOB_ID or branch ~= M.BERSERKER_BRANCH or lvl < M.BERSERKER_MIN_LEVEL then
            return { state = 'vanilla' }
        end

        local rset = self.races[race_key]
        if ctx.is_engaged == true then
            return {
                state          = 'drawn_dual_2h',
                profile        = 'war_berserker_dual_great_axe',
                race_key       = race_key,
                main_model_id  = ctx.main_model_id,
                sub_model_id   = ctx.sub_model_id,
                main_transform = clone_transform(rset.drawn.main),
                sub_transform  = clone_transform(rset.drawn.sub),
            }
        else
            return {
                state          = 'sheathed_cross_x',
                profile        = 'war_berserker_dual_great_axe',
                race_key       = race_key,
                main_model_id  = ctx.main_model_id,
                sub_model_id   = ctx.sub_model_id,
                main_transform = clone_transform(rset.sheathed.main),
                sub_transform  = clone_transform(rset.sheathed.sub),
            }
        end
    end

    -- Developer-only independent Main/Sub transform adjustment (rejected when diagnostics disabled).
    function self:adjust_transform(race_key, stance, hand, patch)
        if not self.diagnostics_enabled then
            return false, 'diagnostics disabled'
        end
        local rset = self.races[race_key]
        if not rset or (stance ~= 'drawn' and stance ~= 'sheathed') or (hand ~= 'main' and hand ~= 'sub') then
            return false, 'invalid target'
        end
        if type(patch) ~= 'table' then return false, 'invalid patch' end
        local dst = rset[stance][hand]
        if type(patch.translation) == 'table' then
            if type(patch.translation.x) == 'number' then dst.translation.x = round4(patch.translation.x) end
            if type(patch.translation.y) == 'number' then dst.translation.y = round4(patch.translation.y) end
            if type(patch.translation.z) == 'number' then dst.translation.z = round4(patch.translation.z) end
        end
        if type(patch.rotationDeg) == 'table' then
            if type(patch.rotationDeg.pitch) == 'number' then dst.rotationDeg.pitch = round4(patch.rotationDeg.pitch) end
            if type(patch.rotationDeg.yaw) == 'number'   then dst.rotationDeg.yaw   = round4(patch.rotationDeg.yaw) end
            if type(patch.rotationDeg.roll) == 'number'  then dst.rotationDeg.roll  = round4(patch.rotationDeg.roll) end
        end
        if type(patch.gripOffset) == 'table' then
            if type(patch.gripOffset.x) == 'number' then dst.gripOffset.x = round4(patch.gripOffset.x) end
            if type(patch.gripOffset.y) == 'number' then dst.gripOffset.y = round4(patch.gripOffset.y) end
            if type(patch.gripOffset.z) == 'number' then dst.gripOffset.z = round4(patch.gripOffset.z) end
        end
        if type(patch.scale) == 'number' and patch.scale >= 0.25 and patch.scale <= 2.5 then
            dst.scale = round4(patch.scale)
        end
        if type(patch.weaponSeparation) == 'number' then
            dst.weaponSeparation = round4(patch.weaponSeparation)
        end
        if type(patch.backDepth) == 'number' then
            dst.backDepth = round4(patch.backDepth)
            if stance == 'sheathed' then
                dst.translation.z = dst.backDepth
            end
        end
        return true, nil
    end

    -- Sagittal symmetry mirror helper (Main -> Sub), preserving non-zero crossed-back depth separation.
    function self:mirror_main_to_sub(race_key, stance, depth_sep)
        if not self.diagnostics_enabled then
            return false, 'diagnostics disabled'
        end
        local rset = self.races[race_key]
        if not rset or (stance ~= 'drawn' and stance ~= 'sheathed') then
            return false, 'invalid target'
        end
        local m = rset[stance].main
        local s = rset[stance].sub
        local sep = (stance == 'sheathed') and (type(depth_sep) == 'number' and depth_sep or 0.038) or 0.0
        s.translation.x      = round4(-m.translation.x)
        s.translation.y      = round4(m.translation.y)
        s.translation.z      = round4(m.translation.z + sep)
        s.rotationDeg.pitch  = round4(m.rotationDeg.pitch)
        s.rotationDeg.yaw    = round4(-m.rotationDeg.yaw)
        s.rotationDeg.roll   = round4(-m.rotationDeg.roll)
        s.gripOffset.x       = round4(-m.gripOffset.x)
        s.gripOffset.y       = round4(m.gripOffset.y)
        s.gripOffset.z       = round4(m.gripOffset.z)
        s.scale              = round4(m.scale)
        s.weaponSeparation   = round4(m.weaponSeparation)
        s.backDepth          = (stance == 'sheathed') and round4(m.backDepth + sep) or 0.0
        return true, nil
    end

    function self:load_from_json(json_text)
        local doc, err = parse_json(json_text)
        if not doc or type(doc) ~= 'table' then
            return false, err or 'parse failure'
        end
        if doc.schemaVersion ~= 1 then
            return false, 'unsupported schemaVersion'
        end
        local ber = doc.profiles and doc.profiles.war_berserker_dual_great_axe
        if type(ber) ~= 'table' or type(ber.races) ~= 'table' then
            return false, 'missing war_berserker_dual_great_axe.races'
        end
        local next_races = M.default_races()
        for _, rk in ipairs(M.RACE_KEYS) do
            local r = ber.races[rk]
            if type(r) == 'table' and type(r.drawn) == 'table' and type(r.sheathed) == 'table' then
                for _, st in ipairs({ 'drawn', 'sheathed' }) do
                    for _, hand in ipairs({ 'main', 'sub' }) do
                        local src = r[st][hand]
                        if type(src) == 'table' and type(src.translation) == 'table'
                            and type(src.rotationDeg) == 'table' and type(src.gripOffset) == 'table'
                        then
                            next_races[rk][st][hand] = clone_transform(src)
                        end
                    end
                end
            end
        end
        self.races = next_races
        -- Never auto-enable developer diagnostics from a config file unless explicitly toggled in session.
        self.diagnostics_enabled = false
        return true, nil
    end

    function self:load_file(path)
        local target = path or self.config_path
        if type(target) ~= 'string' or target == '' then return false, 'no config path' end
        local f = io.open(target, 'rb')
        if not f then return false, 'file not found: ' .. target end
        local raw = f:read('*a')
        f:close()
        return self:load_from_json(raw)
    end

    function self:serialize_json()
        local lines = {
            '{',
            '  "schemaVersion": 1,',
            '  "contract": "SOULSPIRE_WEAPON_PRESENTATION_V1",',
            '  "description": "Authoritative, reusable Soul weapon presentation configuration for Soulspire Native and Soulspire Core. Covers all 8 playable FFXI character models with independent Main/Sub drawn and crossed-back sheathed transforms. Visual certification requires live Windows Ashita v4 screenshots across all 8 races.",',
            '  "coordinateSystem": {',
            '    "handedness": "ffxi_local_skeleton",',
            '    "xAxis": "+X character-left, -X character-right (sagittal mirror plane X=0)",',
            '    "yAxis": "+Y vertical up",',
            '    "zAxis": "+Z rear/back clearance, -Z forward/chest (verified from Flintlock 7-skeleton audit)",',
            '    "rotationUnits": "degrees",',
            '    "translationUnits": "ffxi_meters"',
            '  },',
            '  "diagnostics": {',
            '    "enabled": false,',
            '    "requireDevCommand": true,',
            '    "command": "/soulspire weapondiag"',
            '  },',
            '  "profiles": {',
            '    "war_berserker_dual_great_axe": {',
            '      "enabled": true,',
            '      "visualCertified": false,',
            '      "soulGate": {',
            '        "job": 1,',
            '        "branch": 2,',
            '        "soulKey": "berserker",',
            '        "minEffectiveLevel": 10,',
            '        "failClosedWhenUnknown": true,',
            '        "neverInferFromBaseJob": true',
            '      },',
            '      "equipmentGate": {',
            '        "mode": "dual_2h",',
            '        "mainSkills": [6],',
            '        "subSkills": [6],',
            '        "requireDistinctItems": true,',
            '        "preserveActualWeaponModels": true',
            '      },',
            '      "animationPolicy": {',
            '        "drawnStance": "dual_wield_1h_adapted",',
            '        "sheathedFormation": "crossed_back_x",',
            '        "combatSwingPolicy": "independent_main_right_sub_left",',
            '        "weaponSkillPolicy": "main_hand_great_axe_ws_preserve_sub",',
            '        "castingPolicy": "stock_cast_lowered",',
            '        "deathPolicy": "clear_override_vanilla",',
            '        "fallbackWhenInactive": "vanilla",',
            '        "globalDatModification": false',
            '      },',
            '      "races": {',
        }
        for i, rk in ipairs(M.RACE_KEYS) do
            local meta = M.RACE_META[rk]
            local r = self.races[rk]
            local comma = (i < #M.RACE_KEYS) and ',' or ''
            lines[#lines + 1] = ('        "%s": {'):format(rk)
            lines[#lines + 1] = ('          "raceId": %d,'):format(meta.raceId)
            lines[#lines + 1] = ('          "displayName": "%s",'):format(meta.displayName)
            lines[#lines + 1] = ('          "skeletonDat": "%s",'):format(meta.skeletonDat)
            lines[#lines + 1] = '          "drawn": {'
            lines[#lines + 1] = '            "main": ' .. serialize_transform(r.drawn.main, '            ') .. ','
            lines[#lines + 1] = '            "sub": ' .. serialize_transform(r.drawn.sub, '            ')
            lines[#lines + 1] = '          },'
            lines[#lines + 1] = '          "sheathed": {'
            lines[#lines + 1] = '            "main": ' .. serialize_transform(r.sheathed.main, '            ') .. ','
            lines[#lines + 1] = '            "sub": ' .. serialize_transform(r.sheathed.sub, '            ')
            lines[#lines + 1] = '          }'
            lines[#lines + 1] = '        }' .. comma
        end
        lines[#lines + 1] = '      }'
        lines[#lines + 1] = '    },'
        lines[#lines + 1] = '    "cor_flintlock_dual_pistols": {'
        lines[#lines + 1] = '      "enabled": true,'
        lines[#lines + 1] = '      "visualCertified": false,'
        lines[#lines + 1] = '      "soulGate": {'
        lines[#lines + 1] = '        "job": 17,'
        lines[#lines + 1] = '        "branch": 1,'
        lines[#lines + 1] = '        "soulKey": "flintlock",'
        lines[#lines + 1] = '        "minEffectiveLevel": 10,'
        lines[#lines + 1] = '        "failClosedWhenUnknown": true,'
        lines[#lines + 1] = '        "neverInferFromBaseJob": true'
        lines[#lines + 1] = '      },'
        lines[#lines + 1] = '      "equipmentGate": {'
        lines[#lines + 1] = '        "mode": "ranged_dual_pistol",'
        lines[#lines + 1] = '        "rangeSkills": [26],'
        lines[#lines + 1] = '        "hideMainSubGrap": true,'
        lines[#lines + 1] = '        "optionalOverlayId": "flintlock-akimbo-compact"'
        lines[#lines + 1] = '      },'
        lines[#lines + 1] = '      "animationPolicy": {'
        lines[#lines + 1] = '        "drawnStance": "akimbo_ra_lc07_ls07",'
        lines[#lines + 1] = '        "sheathedFormation": "hip_holsters_sagittal_mirrored",'
        lines[#lines + 1] = '        "fallbackWhenInactive": "vanilla",'
        lines[#lines + 1] = '        "globalDatModification": false'
        lines[#lines + 1] = '      }'
        lines[#lines + 1] = '    }'
        lines[#lines + 1] = '  }'
        lines[#lines + 1] = '}'
        return table.concat(lines, '\n') .. '\n'
    end

    function self:export_file(path)
        if not self.diagnostics_enabled then
            return false, 'diagnostics disabled'
        end
        local target = path or self.config_path
        if type(target) ~= 'string' or target == '' then
            return false, 'no export path configured'
        end
        local payload = self:serialize_json()
        local f, err = io.open(target, 'wb')
        if not f then return false, tostring(err) end
        f:write(payload)
        f:close()
        self.last_export_status = 'Exported to ' .. target
        return true, target
    end

    -- Developer-only live alignment ImGui window (strictly inert when diagnostics_enabled == false).
    function self:draw_diagnostics_panel(imgui)
        if not self.diagnostics_enabled or not imgui then return false end
        local open_flag = { true }
        if imgui.Begin('Soulspire Weapon Alignment Diagnostics (Dev Only)###soulspire_wpn_diag', open_flag) then
            local rk = M.RACE_KEYS[self.selected_race_idx] or 'hume_male'
            local meta = M.RACE_META[rk]
            imgui.TextUnformatted(('Race: %s (%s) | Stance: %s | Hand: %s'):format(
                meta.displayName, meta.skeletonDat, self.selected_stance, self.selected_hand))
            if imgui.Button and imgui.Button('Prev Race') then
                self.selected_race_idx = ((self.selected_race_idx - 2) % #M.RACE_KEYS) + 1
            end
            if imgui.SameLine then imgui.SameLine() end
            if imgui.Button and imgui.Button('Next Race') then
                self.selected_race_idx = (self.selected_race_idx % #M.RACE_KEYS) + 1
            end
            if imgui.SameLine then imgui.SameLine() end
            if imgui.Button and imgui.Button('Toggle Drawn/Sheathed') then
                self.selected_stance = (self.selected_stance == 'sheathed') and 'drawn' or 'sheathed'
            end
            if imgui.SameLine then imgui.SameLine() end
            if imgui.Button and imgui.Button('Toggle Main/Sub') then
                self.selected_hand = (self.selected_hand == 'main') and 'sub' or 'main'
            end

            rk = M.RACE_KEYS[self.selected_race_idx] or 'hume_male'
            local xform = self.races[rk][self.selected_stance][self.selected_hand]
            local function slider(label, cur, lo, hi, apply)
                if not imgui.SliderFloat then return end
                local v = { cur }
                if imgui.SliderFloat(label, v, lo, hi, '%.4f') then
                    apply(round4(v[1]))
                end
            end
            slider('Translate X', xform.translation.x, -0.5, 0.5, function(v) xform.translation.x = v end)
            slider('Translate Y', xform.translation.y, -0.5, 0.5, function(v) xform.translation.y = v end)
            slider('Translate Z', xform.translation.z, -0.5, 0.5, function(v) xform.translation.z = v end)
            slider('Pitch (deg)', xform.rotationDeg.pitch, -180.0, 180.0, function(v) xform.rotationDeg.pitch = v end)
            slider('Yaw (deg)',   xform.rotationDeg.yaw,   -180.0, 180.0, function(v) xform.rotationDeg.yaw   = v end)
            slider('Roll (deg)',  xform.rotationDeg.roll,  -180.0, 180.0, function(v) xform.rotationDeg.roll  = v end)
            slider('Grip Offset X', xform.gripOffset.x, -0.5, 0.5, function(v) xform.gripOffset.x = v end)
            slider('Grip Offset Y', xform.gripOffset.y, -0.5, 0.5, function(v) xform.gripOffset.y = v end)
            slider('Grip Offset Z', xform.gripOffset.z, -0.5, 0.5, function(v) xform.gripOffset.z = v end)
            slider('Weapon Separation', xform.weaponSeparation, 0.0, 0.4, function(v) xform.weaponSeparation = v end)
            slider('Back Attachment Depth', xform.backDepth, 0.0, 0.5, function(v)
                xform.backDepth = v
                if self.selected_stance == 'sheathed' then xform.translation.z = v end
            end)
            slider('Weapon Scale', xform.scale, 0.4, 1.8, function(v) xform.scale = v end)

            if imgui.Button and imgui.Button('Mirror Main -> Sub') then
                self:mirror_main_to_sub(rk, self.selected_stance)
            end
            if imgui.SameLine then imgui.SameLine() end
            if imgui.Button and imgui.Button('Export Authoritative JSON') then
                self:export_file()
            end
            if imgui.SameLine then imgui.SameLine() end
            if imgui.Button and imgui.Button('Reset Defaults') then
                self:reset_transforms()
            end
            if self.last_export_status then
                imgui.TextUnformatted(self.last_export_status)
            end
        end
        imgui.End()
        if open_flag[1] == false then
            self.diagnostics_enabled = false
        end
        return true
    end

    return self
end

return M
