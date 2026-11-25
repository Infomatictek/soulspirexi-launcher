-- SoulspireXI Phase C — Native VanaCore Soul Actions Module
-- Loads authoritative `soul_actions.tsv` & `visibility.tsv` and pushes them directly to
-- `vana.soulspire` (zero Ashita compatibility shims required).

local M = {}

local KIND_MAP = {
    spell = 1,
    magic = 1,
    ability = 2,
    job_ability = 2,
    ja = 2,
    weaponskill = 3,
    ws = 3,
}

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function split_tabs(line)
    local out = {}
    local start = 1
    while true do
        local pos = string.find(line, '\t', start, true)
        if not pos then
            out[#out + 1] = string.sub(line, start)
            break
        end
        out[#out + 1] = string.sub(line, start, pos - 1)
        start = pos + 1
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

function M.new(install_dir, identity_mod)
    local self = {
        install_dir = tostring(install_dir or ''):gsub('[/\\]+$', ''),
        identity = identity_mod,
        action_count = 0,
        visibility_count = 0,
        row_limit = 16,
        actions_source = 'none',
        visibility_source = 'none',
        search_query = '',
    }

    local function resolve_soul_pair(token)
        local t = string.lower(trim(token))
        if self.identity and self.identity.by_key and self.identity.by_key[t] then
            local rec = self.identity.by_key[t]
            return rec.job_id, rec.branch_id
        end
        local j, b = t:match('^(%d+):(%d+)$')
        if j and b then
            return tonumber(j), tonumber(b)
        end
        return nil, nil
    end

    function self:sync_to_native()
        local base = self.install_dir
        local action_raw, action_path = read_first({
            base .. '/addons/vanacore/soulspire_core/data/soul_actions.tsv',
            base .. '/addons/ashita/soulspire_soul_actions/data/soul_actions.tsv',
            base .. '/plugins/data/soul_actions.tsv',
        })
        local vis_raw, vis_path = read_first({
            base .. '/addons/vanacore/soulspire_core/data/visibility.tsv',
            base .. '/addons/ashita/soulspire_soul_actions/data/visibility.tsv',
            base .. '/plugins/data/visibility.tsv',
        })
        local pres_raw = read_first({
            base .. '/addons/vanacore/soulspire_core/data/presentation.cfg',
            base .. '/addons/ashita/soulspire_soul_actions/data/presentation.cfg',
        })

        if pres_raw then
            local lim = tonumber(pres_raw:match('row_max_chars%s*=%s*(%d+)'))
            if lim and lim >= 8 and lim <= 48 then
                self.row_limit = lim
            end
        end

        local actions = {}
        if action_raw then
            self.actions_source = action_path or 'tsv'
            for line in (action_raw .. '\n'):gmatch('([^\r\n]*)\r?\n') do
                local cleaned = trim(line)
                if cleaned ~= '' and string.sub(cleaned, 1, 1) ~= '#' then
                    local cols = split_tabs(line)
                    local job, branch = resolve_soul_pair(cols[1])
                    local kind = KIND_MAP[string.lower(trim(cols[2]))] or tonumber(cols[2])
                    local id = tonumber(cols[3])
                    local name = trim(cols[4])
                    local desc = trim(cols[5])
                    local icon = tonumber(cols[6])
                    local icon_v2 = tonumber(cols[7])
                    if job and branch and kind and id and (name ~= '' or desc ~= '') then
                        actions[#actions + 1] = {
                            job = job,
                            branch = branch,
                            kind = kind,
                            id = id,
                            name = name,
                            description = desc,
                            icon_id = icon,
                            icon_id_v2 = icon_v2,
                        }
                    end
                end
            end
        end

        local vis = {}
        if vis_raw then
            self.visibility_source = vis_path or 'tsv'
            for line in (vis_raw .. '\n'):gmatch('([^\r\n]*)\r?\n') do
                local cleaned = trim(line)
                if cleaned ~= '' and string.sub(cleaned, 1, 1) ~= '#' then
                    local cols = split_tabs(line)
                    local job, branch = resolve_soul_pair(cols[1])
                    local kind = KIND_MAP[string.lower(trim(cols[2]))] or tonumber(cols[2])
                    local id = tonumber(cols[3])
                    local rule_str = string.lower(trim(cols[4]))
                    local min_lvl = tonumber(cols[5]) or 1
                    local rule = (rule_str == 'hide' or rule_str == 'hidden' or rule_str == '0') and 0 or 1
                    if job and branch and kind and id then
                        vis[#vis + 1] = {
                            job = job,
                            branch = branch,
                            kind = kind,
                            id = id,
                            min_level = min_lvl,
                            rule = rule,
                        }
                    end
                end
            end
        end

        if type(vana) == 'table' and vana.soulspire then
            if type(vana.soulspire.set_row_limit) == 'function' then
                vana.soulspire.set_row_limit(self.row_limit)
            end
            if type(vana.soulspire.replace_actions) == 'function' and #actions > 0 then
                self.action_count = vana.soulspire.replace_actions(actions)
            else
                self.action_count = #actions
            end
            if type(vana.soulspire.replace_visibility) == 'function' and #vis > 0 then
                self.visibility_count = vana.soulspire.replace_visibility(vis)
            else
                self.visibility_count = #vis
            end
        else
            self.action_count = #actions
            self.visibility_count = #vis
        end

        return self.action_count, self.visibility_count
    end

    function self:search(query, limit)
        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.search_actions) == 'function' then
            return vana.soulspire.search_actions(tostring(query or ''), limit or 64)
        end
        return {}
    end

    function self:check_visibility(kind, id, level_override)
        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.decide_visibility) == 'function' then
            return vana.soulspire.decide_visibility(kind, id, level_override or 0)
        end
        return 'unmanaged'
    end

    return self
end

return M
