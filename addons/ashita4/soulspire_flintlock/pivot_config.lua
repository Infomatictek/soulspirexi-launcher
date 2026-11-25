-- Pure-Lua parser and reversible updater for BOTH:
--   1. Ashita v4 XIPivot soulspirexi.ini ([overlays] section)
--   2. VanaCore built-in Pivot vanacore.ini ([pivot.order] section)
-- Never touches live FFXI DATs in memory; changes apply cleanly on the next client launch / zone.

local M = {}

M.FLINTLOCK_OVERLAY = 'flintlock-akimbo-compact'
M.BASE_OVERLAY = 'soulspirexi'

local function trim(s)
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function M.detect_section_name(ini_text)
    if type(ini_text) ~= 'string' then
        return 'overlays'
    end
    for raw_line in (ini_text .. '\n'):gmatch('(.-)\r?\n') do
        local section = trim(raw_line):match('^%[(.-)%]$')
        if section then
            local lower = section:lower()
            if lower == 'pivot.order' or lower == 'pivot' then
                return 'pivot.order'
            elseif lower == 'overlays' then
                return 'overlays'
            end
        end
    end
    return 'overlays'
end

-- Parse [overlays] (Ashita XIPivot) or [pivot.order] (VanaCore Pivot) entries into an ordered list.
function M.parse_overlays(ini_text)
    if type(ini_text) ~= 'string' then
        return {}
    end
    local target_section = M.detect_section_name(ini_text)
    local in_overlays = false
    local indexed = {}
    for raw_line in (ini_text .. '\n'):gmatch('(.-)\r?\n') do
        local line = trim(raw_line)
        local section = line:match('^%[(.-)%]$')
        if section then
            in_overlays = (section:lower() == target_section)
        elseif in_overlays and line ~= '' and line:sub(1, 1) ~= ';' and line:sub(1, 1) ~= '#' then
            local k, v = line:match('^([^=]+)=(.*)$')
            if k and v then
                local idx = tonumber(trim(k))
                local val = trim(v)
                if idx ~= nil and val ~= '' then
                    indexed[#indexed + 1] = { idx = idx, name = val }
                end
            end
        end
    end
    table.sort(indexed, function(a, b) return a.idx < b.idx end)
    local out = {}
    for _, item in ipairs(indexed) do
        out[#out + 1] = item.name
    end
    return out
end

function M.is_flintlock_enabled(ini_text)
    local overlays = M.parse_overlays(ini_text)
    for _, name in ipairs(overlays) do
        if name:lower() == M.FLINTLOCK_OVERLAY then
            return true
        end
    end
    return false
end

-- Return updated INI text with flintlock-akimbo-compact enabled or removed, preserving all other sections.
-- Under VanaCore ([pivot.order]), soulspirexi remains priority 0 (server-first) with flintlock directly after;
-- under Ashita XIPivot ([overlays]), flintlock is placed at priority 0 matching existing behavior.
function M.set_flintlock_enabled(ini_text, enabled)
    if type(ini_text) ~= 'string' or ini_text == '' then
        return nil, 'Empty pivot INI content.'
    end

    local target_section = M.detect_section_name(ini_text)
    local is_vanacore = (target_section == 'pivot.order')
    local current = M.parse_overlays(ini_text)
    local filtered = {}
    for _, name in ipairs(current) do
        if name:lower() ~= M.FLINTLOCK_OVERLAY then
            filtered[#filtered + 1] = name
        end
    end
    if #filtered == 0 then
        filtered[1] = M.BASE_OVERLAY
    end

    local next_overlays = {}
    if enabled then
        if is_vanacore then
            local has_base = false
            for _, name in ipairs(filtered) do
                if name:lower() == M.BASE_OVERLAY then
                    has_base = true
                end
            end
            if has_base then
                next_overlays[1] = M.BASE_OVERLAY
                next_overlays[2] = M.FLINTLOCK_OVERLAY
                for _, name in ipairs(filtered) do
                    if name:lower() ~= M.BASE_OVERLAY then
                        next_overlays[#next_overlays + 1] = name
                    end
                end
            else
                next_overlays[1] = M.FLINTLOCK_OVERLAY
                for _, name in ipairs(filtered) do
                    next_overlays[#next_overlays + 1] = name
                end
            end
        else
            next_overlays[1] = M.FLINTLOCK_OVERLAY
            for _, name in ipairs(filtered) do
                next_overlays[#next_overlays + 1] = name
            end
        end
    else
        next_overlays = filtered
    end

    local out_lines = {}
    local in_overlays = false
    local wrote_overlays = false

    local function emit_overlays()
        for i, name in ipairs(next_overlays) do
            out_lines[#out_lines + 1] = tostring(i - 1) .. '=' .. name
        end
        wrote_overlays = true
    end

    for raw_line in (ini_text .. '\n'):gmatch('(.-)\r?\n') do
        local line = trim(raw_line)
        local section = line:match('^%[(.-)%]$')
        if section then
            if in_overlays and not wrote_overlays then
                emit_overlays()
            end
            in_overlays = (section:lower() == target_section)
            out_lines[#out_lines + 1] = raw_line
            if in_overlays then
                emit_overlays()
            end
        elseif not in_overlays then
            out_lines[#out_lines + 1] = raw_line
        end
    end

    if not wrote_overlays then
        if #out_lines > 0 and trim(out_lines[#out_lines]) ~= '' then
            out_lines[#out_lines + 1] = ''
        end
        out_lines[#out_lines + 1] = '[' .. target_section .. ']'
        emit_overlays()
    end

    -- Trim trailing duplicate blank lines, keep single LF newline.
    while #out_lines > 0 and trim(out_lines[#out_lines]) == '' do
        table.remove(out_lines)
    end
    return table.concat(out_lines, '\n') .. '\n', nil
end

return M
