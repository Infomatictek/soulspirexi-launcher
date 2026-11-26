-- SoulspireXI Core (VanaCore-Native): Authoritative 66-Soul Identity Registry
-- Parses `soul-identities.json` via VanaCore's native `vana.json.decode` (with `core.json` fallback),
-- reconciles canonical keys against `core.soul_registry_generated`, validates 66 Souls & hash,
-- and exposes actionable diagnostics when required data is missing or invalid.

local M = {}
M.EXPECTED_SOUL_COUNT = 66

local okJson, fallbackJson = pcall(require, 'core.json')
if not okJson then fallbackJson = nil end

local okReg, generatedReg = pcall(require, 'core.soul_registry_generated')
if not okReg then generatedReg = nil end

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function normalize_key(name)
    return string.lower(tostring(name or '')):gsub('[^%w]', '')
end

local function decode_json(text)
    if type(vana) == 'table' and vana.json and type(vana.json.decode) == 'function' then
        local val, err = vana.json.decode(text)
        if type(val) == 'table' then return val, nil end
        return nil, err or 'vana.json.decode failed'
    end
    if fallbackJson and type(fallbackJson.decode) == 'function' then
        local ok, val = pcall(fallbackJson.decode, text)
        if ok and type(val) == 'table' then return val, nil end
        return nil, tostring(val)
    end
    return nil, 'no JSON decoder available'
end

local function build_generated_key_map()
    local by_pair = {}
    if type(generatedReg) ~= 'table' then return by_pair end
    local function add_entry(entry)
        if type(entry) ~= 'table' then return end
        local j = tonumber(entry.jobId or entry.job_id)
        local b = tonumber(entry.branchId or entry.branch_id or entry.branch)
        if not (j and b) then return end
        local pair = j .. ':' .. b
        local primary = string.lower(tostring(entry.canonicalKey or entry.internalKey or entry.key or normalize_key(entry.displayName or entry.name)))
        local aliases = {}
        local function add_alias(v)
            if type(v) == 'string' and v ~= '' then
                aliases[#aliases + 1] = string.lower(trim(v))
                local norm = normalize_key(v)
                if norm ~= '' then aliases[#aliases + 1] = norm end
            end
        end
        add_alias(primary)
        add_alias(entry.internalKey)
        add_alias(entry.canonicalKey)
        add_alias(entry.key)
        add_alias(entry.id)
        add_alias(entry.displayName)
        add_alias(entry.name)
        if type(entry.legacyAliases) == 'table' then
            for _, al in ipairs(entry.legacyAliases) do
                add_alias(al)
            end
        end
        by_pair[pair] = { primary = primary, aliases = aliases }
    end
    if type(generatedReg.ordered) == 'table' then
        for _, entry in ipairs(generatedReg.ordered) do add_entry(entry) end
    end
    if type(generatedReg.SOULS) == 'table' then
        for _, entry in pairs(generatedReg.SOULS) do add_entry(entry) end
    end
    return by_pair
end

local function read_first(paths)
    local tried = {}
    for _, p in ipairs(paths) do
        tried[#tried + 1] = p
        local f = io.open(p, 'rb')
        if f then
            local data = f:read('*a')
            f:close()
            if data and #data > 0 then
                return data, p, tried
            end
        end
    end
    return nil, nil, tried
end

function M.new(install_dir, addon_dir)
    local self = {
        install_dir     = tostring(install_dir or ''):gsub('[/\\]+$', ''),
        addon_dir       = tostring(addon_dir or ''):gsub('[/\\]+$', ''),
        registry_hash   = '',
        registry_source = 'none',
        last_error      = nil,
        tried_paths     = {},
        souls           = {},
        by_key          = {},
        by_pair         = {},
    }

    local gen_keys = build_generated_key_map()

    function self:reload()
        self.souls = {}
        self.by_key = {}
        self.by_pair = {}
        self.registry_hash = ''
        self.registry_source = 'none'
        self.last_error = nil

        local base = self.install_dir
        local candidates = {}
        if self.addon_dir ~= '' then
            candidates[#candidates + 1] = self.addon_dir .. '/data/soul-identities.json'
        end
        candidates[#candidates + 1] = base .. '/data/soul-identities.json'
        candidates[#candidates + 1] = base .. '/addons/vanacore/soulspire_core/data/soul-identities.json'
        candidates[#candidates + 1] = base .. '/plugins/ashita4/data/soul-identities.json'
        candidates[#candidates + 1] = base .. '/plugins/ashita/data/soul-identities.json'
        candidates[#candidates + 1] = base .. '/plugins/data/soul-identities.json'

        local raw, used, tried = read_first(candidates)
        self.tried_paths = tried
        if not raw then
            self.last_error = 'soul-identities.json not found (searched: ' .. table.concat(tried, ', ') .. ')'
            return false, self.last_error
        end

        local decoded, derr = decode_json(raw)
        if not decoded or type(decoded.souls) ~= 'table' then
            self.last_error = 'Failed to parse ' .. tostring(used) .. ': ' .. tostring(derr or 'missing souls array')
            return false, self.last_error
        end

        self.registry_hash = tostring(decoded.registryHash or '')
        self.registry_source = used

        for _, item in ipairs(decoded.souls) do
            if type(item) == 'table' then
                local j = tonumber(item.jobId or item.job_id or item.job)
                local b = tonumber(item.branch or item.branchId or item.branch_id)
                local name = trim(item.name)
                local abbr = trim(item.abbr)
                local pair = (j and b) and (j .. ':' .. b) or nil
                local gen_meta = pair and gen_keys[pair] or nil
                local key = trim(item.key)
                if key == '' and gen_meta and gen_meta.primary and gen_meta.primary ~= '' then
                    key = gen_meta.primary
                end
                if key == '' and name ~= '' then
                    key = normalize_key(name)
                end
                key = string.lower(key)

                if j and b and name ~= '' and key ~= '' then
                    local rec = {
                        job_id    = j,
                        branch_id = b,
                        key       = key,
                        name      = name,
                        abbr      = abbr ~= '' and abbr or string.upper(string.sub(key, 1, 3)),
                    }
                    self.souls[#self.souls + 1] = rec
                    self.by_key[key] = rec
                    -- Index canonicalKey, internalKey, legacyAliases, and normalized display name
                    local norm_name = normalize_key(name)
                    if norm_name ~= '' and not self.by_key[norm_name] then
                        self.by_key[norm_name] = rec
                    end
                    if gen_meta and type(gen_meta.aliases) == 'table' then
                        for _, al in ipairs(gen_meta.aliases) do
                            if al ~= '' and not self.by_key[al] then
                                self.by_key[al] = rec
                            end
                        end
                    end
                    self.by_pair[pair] = rec
                end
            end
        end

        if #self.souls ~= M.EXPECTED_SOUL_COUNT then
            self.last_error = string.format('soul-identities.json (%s) loaded %d Souls, expected %d (hash=%s)',
                tostring(used), #self.souls, M.EXPECTED_SOUL_COUNT, self.registry_hash)
            return false, self.last_error
        end
        if self.registry_hash == '' then
            self.last_error = string.format('soul-identities.json (%s) missing registryHash', tostring(used))
            return false, self.last_error
        end
        return true, nil
    end

    function self:active()
        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.identity) == 'function' then
            local id = vana.soulspire.identity()
            if type(id) == 'table' then
                local pair = (tonumber(id.job) or 0) .. ':' .. (tonumber(id.branch) or 0)
                local rec = self.by_pair[pair]
                if rec then
                    id.soul_key = (id.soul_key and id.soul_key ~= '') and id.soul_key or rec.key
                    id.full_name = (id.full_name and id.full_name ~= '') and id.full_name or rec.name
                    id.short_name = (id.short_name and id.short_name ~= '') and id.short_name or rec.abbr
                end
                return id
            end
        end
        return {
            character_id    = 0,
            job             = 0,
            branch          = 0,
            effective_level = 0,
            known           = false,
            source          = 'unavailable',
        }
    end

    function self:souls_for_job(job_id)
        local list = {}
        local jid = tonumber(job_id) or 0
        for _, rec in ipairs(self.souls) do
            if jid == 0 or rec.job_id == jid then
                list[#list + 1] = rec
            end
        end
        table.sort(list, function(a, b)
            if a.job_id ~= b.job_id then return a.job_id < b.job_id end
            return a.branch_id < b.branch_id
        end)
        return list
    end

    function self:resolve(job_id, branch_id)
        return self.by_pair[(tonumber(job_id) or 0) .. ':' .. (tonumber(branch_id) or 0)]
    end

    function self:resolve_key(key)
        local k = normalize_key(key)
        return self.by_key[string.lower(trim(key))] or self.by_key[k]
    end

    self:reload()
    return self
end

return M
