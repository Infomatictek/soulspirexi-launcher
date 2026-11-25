-- SoulspireXI Phase C — Native VanaCore Soul Identity Module
-- Synchronizes the authoritative 66-Soul registry (`soul-identities.json`) with `vana.soulspire.identity()`.

local M = {}

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function parse_identities_json(text)
    local out = {
        registry_hash = '',
        souls = {},
        by_key = {},
        by_pair = {},
    }
    if type(text) ~= 'string' or text == '' then
        return out
    end
    out.registry_hash = text:match('"registryHash"%s*:%s*"([^"]+)"') or ''
    for block in text:gmatch('%b{}') do
        local j = tonumber(block:match('"jobId"%s*:%s*(%d+)'))
        local b = tonumber(block:match('"branchId"%s*:%s*(%d+)'))
        local key = block:match('"key"%s*:%s*"([^"]+)"')
        local name = block:match('"name"%s*:%s*"([^"]+)"')
        local abbr = block:match('"abbr"%s*:%s*"([^"]+)"')
        if j and b and key and name then
            local rec = {
                job_id = j,
                branch_id = b,
                key = string.lower(trim(key)),
                name = name,
                abbr = abbr or string.upper(string.sub(key, 1, 3)),
            }
            out.souls[#out.souls + 1] = rec
            out.by_key[rec.key] = rec
            out.by_pair[j .. ':' .. b] = rec
        end
    end
    return out
end

local function read_first(paths)
    for _, p in ipairs(paths) do
        local f = io.open(p, 'rb')
        if f then
            local data = f:read('*a')
            f:close()
            if data and #data > 0 then
                return data, p
            end
        end
    end
    return nil, nil
end

function M.new(install_dir)
    local self = {
        install_dir = tostring(install_dir or ''):gsub('[/\\]+$', ''),
        registry_hash = '',
        registry_source = 'none',
        souls = {},
        by_key = {},
        by_pair = {},
    }

    function self:reload()
        local base = self.install_dir
        local candidates = {
            base .. '/plugins/data/soul-identities.json',
            base .. '/plugins/ashita/data/soul-identities.json',
            base .. '/data/soul-identities.json',
            base .. '/addons/vanacore/soulspire_core/data/soul-identities.json',
        }
        local raw, used = read_first(candidates)
        if not raw then
            return false
        end
        local parsed = parse_identities_json(raw)
        self.registry_hash = parsed.registry_hash
        self.registry_source = used or 'json'
        self.souls = parsed.souls
        self.by_key = parsed.by_key
        self.by_pair = parsed.by_pair
        return #self.souls > 0
    end

    function self:active()
        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.identity) == 'function' then
            local id = vana.soulspire.identity()
            if type(id) == 'table' then
                local pair = (id.job or 0) .. ':' .. (id.branch or 0)
                local rec = self.by_pair[pair]
                if rec then
                    id.soul_key = id.soul_key or rec.key
                    id.full_name = id.full_name or rec.name
                    id.short_name = id.short_name or rec.abbr
                end
                return id
            end
        end
        return {
            character_id = 0,
            job = 0,
            branch = 0,
            effective_level = 0,
            known = false,
            source = 'unavailable',
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

    self:reload()
    return self
end

return M
