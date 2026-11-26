-- SoulspireXI Core (VanaCore-Native): Authoritative Soul Actions & Visibility Loader
-- Loads `soul_actions.tsv`, `visibility.tsv`, and `presentation.cfg`, validates counts,
-- and pushes them directly to `vana.soulspire` (zero Ashita compatibility shims).

local M = {}
M.MIN_EXPECTED_ACTIONS    = 100
M.MIN_EXPECTED_VISIBILITY = 100

local KIND_MAP = {
    spell       = 1,
    magic       = 1,
    ability     = 2,
    job_ability = 2,
    ja          = 2,
    weaponskill = 3,
    ws          = 3,
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

function M.new(install_dir, identity_mod, addon_dir)
    local self = {
        install_dir        = tostring(install_dir or ''):gsub('[/\\]+$', ''),
        addon_dir          = tostring(addon_dir or ''):gsub('[/\\]+$', ''),
        identity           = identity_mod,
        action_count       = 0,
        visibility_count   = 0,
        parsed_actions     = 0,
        parsed_visibility  = 0,
        skipped_actions    = 0,
        skipped_visibility = 0,
        row_limit          = 16,
        actions_source     = 'none',
        visibility_source  = 'none',
        errors             = {},
        search_query       = '',
    }

    local function resolve_soul_pair(token)
        local t = string.lower(trim(token))
        if t == '' then return nil, nil end
        if self.identity then
            local rec = (type(self.identity.resolve_key) == 'function' and self.identity:resolve_key(t))
                or (self.identity.by_key and self.identity.by_key[t])
            if rec then
                return rec.job_id, rec.branch_id
            end
        end
        local j, b = t:match('^(%d+):(%d+)$')
        if j and b then
            return tonumber(j), tonumber(b)
        end
        return nil, nil
    end

    local function candidate_paths(filename)
        local base = self.install_dir
        local out = {}
        if self.addon_dir ~= '' then
            out[#out + 1] = self.addon_dir .. '/data/' .. filename
        end
        out[#out + 1] = base .. '/addons/vanacore/soulspire_core/data/' .. filename
        out[#out + 1] = base .. '/data/' .. filename
        out[#out + 1] = base .. '/addons/ashita4/soulspire_soul_actions/data/' .. filename
        out[#out + 1] = base .. '/addons/ashita/soulspire_soul_actions/data/' .. filename
        out[#out + 1] = base .. '/plugins/data/' .. filename
        return out
    end

    function self:sync_to_native()
        self.errors = {}
        self.parsed_actions = 0
        self.parsed_visibility = 0
        self.skipped_actions = 0
        self.skipped_visibility = 0

        local action_raw, action_path, action_tried = read_first(candidate_paths('soul_actions.tsv'))
        local vis_raw, vis_path, vis_tried = read_first(candidate_paths('visibility.tsv'))
        local pres_raw = read_first(candidate_paths('presentation.cfg'))

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
                            job         = job,
                            branch      = branch,
                            kind        = kind,
                            id          = id,
                            name        = name,
                            description = desc,
                            icon_id     = icon,
                            icon_id_v2  = icon_v2,
                        }
                    else
                        self.skipped_actions = self.skipped_actions + 1
                    end
                end
            end
        else
            self.actions_source = 'missing'
            self.errors[#self.errors + 1] = 'soul_actions.tsv not found (searched: ' .. table.concat(action_tried, ', ') .. ')'
        end
        self.parsed_actions = #actions

        -- Authoritative visibility.tsv format:
        --   soul<TAB>kind<TAB>id<TAB>min_effective_level<TAB>rule   (rule: unlock | hidden)
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
                    -- Support canonical order (col4=min_level, col5=rule) and gracefully detect swapped legacy rows
                    local c4_num = tonumber(trim(cols[4]))
                    local min_lvl, rule_str
                    if c4_num ~= nil then
                        min_lvl = c4_num
                        rule_str = string.lower(trim(cols[5]))
                    else
                        rule_str = string.lower(trim(cols[4]))
                        min_lvl = tonumber(trim(cols[5])) or 1
                    end
                    local rule = (rule_str == 'hide' or rule_str == 'hidden' or rule_str == '0') and 0 or 1
                    if job and branch and kind and id then
                        vis[#vis + 1] = {
                            job       = job,
                            branch    = branch,
                            kind      = kind,
                            id        = id,
                            min_level = min_lvl,
                            rule      = rule,
                        }
                    else
                        self.skipped_visibility = self.skipped_visibility + 1
                    end
                end
            end
        else
            self.visibility_source = 'missing'
            self.errors[#self.errors + 1] = 'visibility.tsv not found (searched: ' .. table.concat(vis_tried, ', ') .. ')'
        end
        self.parsed_visibility = #vis

        if #actions < M.MIN_EXPECTED_ACTIONS then
            self.errors[#self.errors + 1] = string.format(
                'soul_actions.tsv (%s) parsed %d actions (skipped=%d), expected >= %d',
                self.actions_source, #actions, self.skipped_actions, M.MIN_EXPECTED_ACTIONS)
        end
        if #vis < M.MIN_EXPECTED_VISIBILITY then
            self.errors[#self.errors + 1] = string.format(
                'visibility.tsv (%s) parsed %d rules (skipped=%d), expected >= %d',
                self.visibility_source, #vis, self.skipped_visibility, M.MIN_EXPECTED_VISIBILITY)
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
