-- SoulspireXI: Registry-Driven Soul Weapon Configuration Loader for Ashita v4.
--
-- Loads authoritative weapon rules, appearance masks, ranged-only flags, and
-- presentation metadata compiled from registry/weapon_configs.json into:
--   plugins/ashita4/data/soul-weapon-config.json
--
-- Design guarantees:
--   * Zero hardcoded Soul IDs, job/branch rules, or weapon classifications.
--   * Strict schemaVersion (1), registryHash, and FNV-1a32 integrity validation.
--   * Fail-closed: missing, malformed, stale, or tampered config yields ZERO
--     rules (preserving vanilla FFXI equipment & appearance behavior).
--   * Cached in memory; never queries SQL or disk during menu/render operations.
local bit = require('bit')

local W = {}

W.SCHEMA_VERSION = 1

-- Matches SOULSPIRE_NATIVE_WEAPON_MODE_* in soulspire_native/core/api.h.
W.MODES = {
    VANILLA        = 0,
    DUAL_1H        = 1,
    DUAL_2H        = 2,
    TWOHAND_SHIELD = 3,
}

W.SKILLS = {
    HAND_TO_HAND = 1,
    DAGGER       = 2,
    SWORD        = 3,
    GREAT_SWORD  = 4,
    AXE          = 5,
    GREAT_AXE    = 6,
    SCYTHE       = 7,
    POLEARM      = 8,
    KATANA       = 9,
    GREAT_KATANA = 10,
    CLUB         = 11,
    STAFF        = 12,
}

-- Minimal strict JSON parser (zero external dependencies).
local function parse_json(src)
    if type(src) ~= 'string' or #src == 0 then return nil, 'empty input' end
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
        local n = tonumber(src:sub(s, e))
        if n == nil then return nil, 'invalid number value' end
        return n
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

local function round_int(v)
    if v >= 0 then return math.floor(v + 0.5) end
    return math.ceil(v - 0.5)
end

-- Exact 32-bit unsigned FNV-1a matching tools/registry_compiler.py (_fnv1a32_bytes).
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

local function is_lower_hex(s, n)
    return type(s) == 'string' and #s == n and s:match('^[0-9a-f]+$') ~= nil
end

-- In-memory cached state (fail-closed until validated).
local state = {
    loaded             = false,
    schema_version     = 0,
    registry_hash      = '',
    weapon_config_hash = '',
    source_path        = nil,
    error              = 'not loaded',
    rules              = {},
    appearance_masks   = {},
    ranged_only        = {},
    profiles_by_id     = {},
}

W.RULES = state.rules

local function reset_state(reason)
    state.loaded             = false
    state.schema_version     = 0
    state.registry_hash      = ''
    state.weapon_config_hash = ''
    state.error              = reason or 'unloaded'
    state.rules              = {}
    state.appearance_masks   = {}
    state.ranged_only        = {}
    state.profiles_by_id     = {}
    W.RULES                  = state.rules
end

function W.skill_mask(skills)
    local mask = 0
    if type(skills) ~= 'table' then return 0 end
    for _, skill in ipairs(skills) do
        if type(skill) == 'number' and skill >= 1 and skill < 32 and skill % 1 == 0 then
            mask = bit.bor(mask, bit.lshift(1, skill))
        end
    end
    return mask
end

function W.parse_and_validate(json_str, expected_registry_hash)
    if type(json_str) ~= 'string' or #json_str == 0 then
        return nil, 'empty weapon config payload'
    end
    local doc, err = parse_json(json_str)
    if not doc or type(doc) ~= 'table' then
        return nil, 'json parse error: ' .. tostring(err)
    end
    if doc.schemaVersion ~= W.SCHEMA_VERSION then
        return nil, 'unsupported schemaVersion: ' .. tostring(doc.schemaVersion)
    end
    if not is_lower_hex(doc.registryHash, 16) then
        return nil, 'invalid registryHash'
    end
    if type(expected_registry_hash) == 'string' and expected_registry_hash ~= ''
        and doc.registryHash ~= expected_registry_hash then
        return nil, 'stale registryHash'
    end
    if not is_lower_hex(doc.integrityFnv1a32, 8) then
        return nil, 'missing or invalid integrityFnv1a32'
    end
    local payload = canonical_digest_payload(doc)
    if not payload then
        return nil, 'malformed presentation profile transforms'
    end
    local computed32 = fnv1a32_hex(payload)
    if computed32 ~= doc.integrityFnv1a32 then
        return nil, 'integrityFnv1a32 mismatch'
    end

    local rules = {}
    for _, r in ipairs(doc.rules or {}) do
        if type(r) ~= 'table'
            or type(r.jobId) ~= 'number' or r.jobId < 1 or r.jobId > 22
            or type(r.branch) ~= 'number' or r.branch < 1 or r.branch > 3
            or type(r.modeId) ~= 'number' or r.modeId < 1 or r.modeId > 3
            or type(r.mainSkillMask) ~= 'number' or r.mainSkillMask <= 0
            or type(r.subSkillMask) ~= 'number' or r.subSkillMask <= 0
        then
            return nil, 'invalid weapon rule entry'
        end
        rules[#rules + 1] = {
            soul_id             = tostring(r.soulId or ''),
            key                 = tostring(r.soulKey or ''),
            job                 = r.jobId,
            branch              = r.branch,
            min_effective_level = tonumber(r.minEffectiveLevel) or 10,
            mode                = r.modeId,
            mode_name           = tostring(r.mode or ''),
            main_skill_mask     = r.mainSkillMask,
            sub_skill_mask      = r.subSkillMask,
            main_item_id        = tonumber(r.mainItemId) or 0,
            sub_item_id         = tonumber(r.subItemId) or 0,
            presentation_profile = tostring(r.presentationProfile or ''),
        }
    end

    local masks = {}
    for _, a in ipairs(doc.appearanceMasks or {}) do
        if type(a) == 'table' and type(a.jobId) == 'number' and type(a.branch) == 'number' then
            masks[a.jobId] = masks[a.jobId] or {}
            masks[a.jobId][a.branch] = {
                soul_id   = tostring(a.soulId or ''),
                soul_key  = tostring(a.soulKey or ''),
                hide_main = a.hideMain == true,
                hide_sub  = a.hideSub == true,
            }
        end
    end

    local ranged = {}
    for _, g in ipairs(doc.rangedOnly or {}) do
        if type(g) == 'table' and type(g.jobId) == 'number' and type(g.branch) == 'number' then
            ranged[g.jobId] = ranged[g.jobId] or {}
            ranged[g.jobId][g.branch] = {
                soul_id              = tostring(g.soulId or ''),
                soul_key             = tostring(g.soulKey or ''),
                job                  = g.jobId,
                branch               = g.branch,
                firearm_only         = g.firearmOnly == true,
                auto_facing          = g.autoFacing == true,
                overlay_id           = tostring(g.overlayId or ''),
                presentation_profile = tostring(g.presentationProfile or ''),
            }
        end
    end

    local profiles = {}
    for _, p in ipairs(doc.presentationProfiles or {}) do
        if type(p) == 'table' and type(p.id) == 'string' and p.id ~= '' then
            profiles[p.id] = p
        end
    end

    return {
        doc              = doc,
        rules            = rules,
        appearance_masks = masks,
        ranged_only      = ranged,
        profiles_by_id   = profiles,
    }, nil
end

function W.load_from_string(json_str, expected_registry_hash)
    local parsed, err = W.parse_and_validate(json_str, expected_registry_hash)
    if not parsed then
        reset_state(err)
        return false, err
    end
    state.loaded             = true
    state.schema_version     = parsed.doc.schemaVersion
    state.registry_hash      = parsed.doc.registryHash
    state.weapon_config_hash = tostring(parsed.doc.weaponConfigHash or '')
    state.error              = nil
    state.rules              = parsed.rules
    state.appearance_masks   = parsed.appearance_masks
    state.ranged_only        = parsed.ranged_only
    state.profiles_by_id     = parsed.profiles_by_id
    W.RULES                  = state.rules
    return true, nil
end

function W.load_from_file(path, expected_registry_hash)
    if type(path) ~= 'string' or path == '' then
        reset_state('missing config path')
        return false, 'missing config path'
    end
    local f = io.open(path, 'rb')
    if not f then
        reset_state('file not found: ' .. path)
        return false, 'file not found: ' .. path
    end
    local content = f:read('*a')
    f:close()
    local ok, err = W.load_from_string(content, expected_registry_hash)
    if ok then
        state.source_path = path
    end
    return ok, err
end

function W.resolve_default_paths(base_dir)
    local candidates = {}
    if type(base_dir) == 'string' and base_dir ~= '' then
        local clean = base_dir:gsub('[/\\]+$', '')
        -- Classic Ashita layout: <root>/addons/<addon> -> <root>/plugins/data/
        candidates[#candidates + 1] = clean .. '/../../plugins/data/soul-weapon-config.json'
        -- Modern VanaCore layout: <root>/addons/ashita/<addon> -> <root>/plugins/ashita/data/ and <root>/plugins/data/
        candidates[#candidates + 1] = clean .. '/../../../plugins/ashita/data/soul-weapon-config.json'
        candidates[#candidates + 1] = clean .. '/../../../plugins/data/soul-weapon-config.json'
        -- Repo dev layout
        candidates[#candidates + 1] = clean .. '/../../../plugins/ashita4/data/soul-weapon-config.json'
        candidates[#candidates + 1] = clean .. '/../../plugins/ashita4/data/soul-weapon-config.json'
    end
    local src = debug and debug.getinfo and debug.getinfo(1, 'S') and debug.getinfo(1, 'S').source or ''
    if src:sub(1, 1) == '@' then
        local dir = src:sub(2):match('^(.*)[/\\][^/\\]+$')
        if dir then
            candidates[#candidates + 1] = dir .. '/../../plugins/data/soul-weapon-config.json'
            candidates[#candidates + 1] = dir .. '/../../../plugins/ashita/data/soul-weapon-config.json'
            candidates[#candidates + 1] = dir .. '/../../../plugins/data/soul-weapon-config.json'
            candidates[#candidates + 1] = dir .. '/../../../plugins/ashita4/data/soul-weapon-config.json'
        end
    end
    if type(AshitaCore) == 'userdata' or type(AshitaCore) == 'table' then
        local ok_inst, inst = pcall(function() return AshitaCore:GetInstallPath() end)
        if ok_inst and type(inst) == 'string' and inst ~= '' then
            local clean_inst = inst:gsub('[/\\]+$', '')
            candidates[#candidates + 1] = clean_inst .. '/plugins/ashita/data/soul-weapon-config.json'
            candidates[#candidates + 1] = clean_inst .. '/plugins/data/soul-weapon-config.json'
        end
    end
    candidates[#candidates + 1] = 'plugins/ashita/data/soul-weapon-config.json'
    candidates[#candidates + 1] = 'plugins/data/soul-weapon-config.json'
    candidates[#candidates + 1] = 'plugins/ashita4/data/soul-weapon-config.json'
    candidates[#candidates + 1] = '../../../plugins/ashita4/data/soul-weapon-config.json'
    return candidates
end

function W.load_default(base_dir, expected_registry_hash)
    for _, p in ipairs(W.resolve_default_paths(base_dir)) do
        local f = io.open(p, 'rb')
        if f then
            f:close()
            return W.load_from_file(p, expected_registry_hash)
        end
    end
    reset_state('soul-weapon-config.json not found')
    return false, 'soul-weapon-config.json not found'
end

function W.clear()
    reset_state('cleared')
end

function W.status()
    return {
        loaded             = state.loaded,
        schema_version     = state.schema_version,
        registry_hash      = state.registry_hash,
        weapon_config_hash = state.weapon_config_hash,
        source_path        = state.source_path,
        rule_count         = #state.rules,
        error              = state.error,
    }
end

function W.appearance_mask_for(job, branch)
    if not state.loaded or type(job) ~= 'number' or type(branch) ~= 'number' then
        return nil
    end
    local by_job = state.appearance_masks[job]
    return by_job and by_job[branch] or nil
end

function W.ranged_only_for(job, branch)
    if not state.loaded or type(job) ~= 'number' or type(branch) ~= 'number' then
        return nil
    end
    local by_job = state.ranged_only[job]
    return by_job and by_job[branch] or nil
end

function W.ranged_only_by_key(job, soul_key)
    if not state.loaded or type(job) ~= 'number' or type(soul_key) ~= 'string' then
        return nil
    end
    local needle = soul_key:lower()
    local by_job = state.ranged_only[job]
    if not by_job then return nil end
    for _, rec in pairs(by_job) do
        if rec.soul_key == needle then
            return rec
        end
    end
    return nil
end

function W.presentation_profile(profile_id)
    if not state.loaded or type(profile_id) ~= 'string' then return nil end
    return state.profiles_by_id[profile_id]
end

-- Fail-closed check for client-side DUAL_2H Sub-menu eligibility.
-- Returns true ONLY when authoritative config is loaded, active Soul identity
-- is confirmed, and a registry DUAL_2H rule matches.
function W.allows_dual_2h_sub_menu(known, job, branch, effective_level, sub_skill)
    if not state.loaded or known ~= true then return false end
    if type(job) ~= 'number' or type(branch) ~= 'number' or branch <= 0 then return false end
    if type(effective_level) ~= 'number' or effective_level < 1 then return false end
    if type(sub_skill) ~= 'number' or sub_skill < 1 or sub_skill >= 32 or sub_skill % 1 ~= 0 then
        return false
    end
    local sub_bit = bit.lshift(1, sub_skill)
    for _, rule in ipairs(state.rules) do
        if rule.mode == W.MODES.DUAL_2H
            and rule.job == job
            and rule.branch == branch
            and effective_level >= (rule.min_effective_level or 10)
            and bit.band(rule.sub_skill_mask or 0, sub_bit) ~= 0
        then
            return true
        end
    end
    return false
end

-- Returns normalized C-ABI rule tables ready for SoulspireNativeReplaceWeaponRules.
function W.native_rules()
    if not state.loaded then return {} end
    local out = {}
    for _, rule in ipairs(state.rules) do
        if rule.job and rule.branch and rule.mode
            and (rule.main_skill_mask or 0) ~= 0 and (rule.sub_skill_mask or 0) ~= 0
        then
            out[#out + 1] = {
                soul_id             = rule.soul_id,
                job                 = rule.job,
                branch              = rule.branch,
                min_effective_level = rule.min_effective_level or 10,
                mode                = rule.mode,
                main_skill_mask     = rule.main_skill_mask,
                sub_skill_mask      = rule.sub_skill_mask,
                main_item_id        = rule.main_item_id or 0,
                sub_item_id         = rule.sub_item_id or 0,
            }
        end
    end
    return out
end

-- Auto-load authoritative registry-compiled config on module load (fails closed if absent).
W.load_default()

return W
