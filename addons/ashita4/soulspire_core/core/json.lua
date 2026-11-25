-- SoulspireXI Core: Safe Pure-Lua JSON Decoder (Zero loadstring / Zero eval)
-- Used exclusively for parsing locally verified static cache JSON packages.
-- Never executes code from cached files.

local M = {}

local byte   = string.byte
local sub    = string.sub
local find   = string.find
local char   = string.char
local floor  = math.floor
local concat = table.concat

local ESCAPE_MAP = {
    ['"']  = '"',
    ['\\'] = '\\',
    ['/']  = '/',
    ['b']  = '\b',
    ['f']  = '\f',
    ['n']  = '\n',
    ['r']  = '\r',
    ['t']  = '\t',
}

local function encode_utf8(cp)
    if cp <= 0x7F then
        return char(cp)
    elseif cp <= 0x7FF then
        return char(0xC0 + floor(cp / 0x40), 0x80 + (cp % 0x40))
    elseif cp <= 0xFFFF then
        return char(
            0xE0 + floor(cp / 0x1000),
            0x80 + (floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    elseif cp <= 0x10FFFF then
        return char(
            0xF0 + floor(cp / 0x40000),
            0x80 + (floor(cp / 0x1000) % 0x40),
            0x80 + (floor(cp / 0x40) % 0x40),
            0x80 + (cp % 0x40)
        )
    end
    return '?'
end

local function skip_ws(str, pos)
    local _, end_pos = find(str, '^[ \t\r\n]+', pos)
    return end_pos and (end_pos + 1) or pos
end

local parse_value

local function parse_string(str, pos)
    -- pos points to opening '"'
    local i = pos + 1
    local len = #str
    local start = i
    local parts = nil

    while i <= len do
        local c = byte(str, i)
        if c == 34 then -- '"'
            if parts then
                if i > start then
                    parts[#parts + 1] = sub(str, start, i - 1)
                end
                return concat(parts), i + 1
            end
            return sub(str, start, i - 1), i + 1
        elseif c == 92 then -- '\'
            parts = parts or {}
            if i > start then
                parts[#parts + 1] = sub(str, start, i - 1)
            end
            local esc = sub(str, i + 1, i + 1)
            if esc == '' then
                error('Unterminated escape sequence in JSON string at byte ' .. tostring(i))
            end
            local mapped = ESCAPE_MAP[esc]
            if mapped then
                parts[#parts + 1] = mapped
                i = i + 2
            elseif esc == 'u' then
                local hex = sub(str, i + 2, i + 5)
                local cp = tonumber(hex, 16)
                if not cp or #hex ~= 4 then
                    error('Invalid \\u escape in JSON string at byte ' .. tostring(i))
                end
                i = i + 6
                -- Handle UTF-16 surrogate pairs
                if cp >= 0xD800 and cp <= 0xDBFF and sub(str, i, i + 1) == '\\u' then
                    local hex2 = sub(str, i + 2, i + 5)
                    local cp2 = tonumber(hex2, 16)
                    if cp2 and #hex2 == 4 and cp2 >= 0xDC00 and cp2 <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (cp2 - 0xDC00)
                        i = i + 6
                    end
                end
                parts[#parts + 1] = encode_utf8(cp)
            else
                error('Invalid escape character \\' .. esc .. ' at byte ' .. tostring(i))
            end
            start = i
        elseif c < 32 then
            error('Unescaped control character in JSON string at byte ' .. tostring(i))
        else
            i = i + 1
        end
    end
    error('Unterminated JSON string starting at byte ' .. tostring(pos))
end

local function parse_number(str, pos)
    local s, e = find(str, '^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    if not s then
        error('Invalid JSON number at byte ' .. tostring(pos))
    end
    local token = sub(str, s, e)
    local num = tonumber(token)
    if num == nil then
        error('Malformed JSON number "' .. token .. '" at byte ' .. tostring(pos))
    end
    return num, e + 1
end

local function parse_array(str, pos, depth)
    if depth > 64 then error('JSON nesting depth limit exceeded') end
    local arr = {}
    local idx = 0
    pos = skip_ws(str, pos + 1)
    if byte(str, pos) == 93 then -- ']'
        return arr, pos + 1
    end
    while true do
        local val
        val, pos = parse_value(str, pos, depth + 1)
        idx = idx + 1
        arr[idx] = val
        pos = skip_ws(str, pos)
        local c = byte(str, pos)
        if c == 44 then -- ','
            pos = skip_ws(str, pos + 1)
        elseif c == 93 then -- ']'
            return arr, pos + 1
        else
            error('Expected "," or "]" in JSON array at byte ' .. tostring(pos))
        end
    end
end

local function parse_object(str, pos, depth)
    if depth > 64 then error('JSON nesting depth limit exceeded') end
    local obj = {}
    pos = skip_ws(str, pos + 1)
    if byte(str, pos) == 125 then -- '}'
        return obj, pos + 1
    end
    while true do
        if byte(str, pos) ~= 34 then
            error('Expected string key in JSON object at byte ' .. tostring(pos))
        end
        local key
        key, pos = parse_string(str, pos)
        pos = skip_ws(str, pos)
        if byte(str, pos) ~= 58 then -- ':'
            error('Expected ":" after JSON object key at byte ' .. tostring(pos))
        end
        pos = skip_ws(str, pos + 1)
        local val
        val, pos = parse_value(str, pos, depth + 1)
        obj[key] = val
        pos = skip_ws(str, pos)
        local c = byte(str, pos)
        if c == 44 then -- ','
            pos = skip_ws(str, pos + 1)
        elseif c == 125 then -- '}'
            return obj, pos + 1
        else
            error('Expected "," or "}" in JSON object at byte ' .. tostring(pos))
        end
    end
end

parse_value = function(str, pos, depth)
    pos = skip_ws(str, pos)
    local c = byte(str, pos)
    if not c then
        error('Unexpected end of JSON input')
    elseif c == 123 then -- '{'
        return parse_object(str, pos, depth)
    elseif c == 91 then -- '['
        return parse_array(str, pos, depth)
    elseif c == 34 then -- '"'
        return parse_string(str, pos)
    elseif c == 116 then -- 't'
        if sub(str, pos, pos + 3) == 'true' then
            return true, pos + 4
        end
        error('Invalid token at byte ' .. tostring(pos))
    elseif c == 102 then -- 'f'
        if sub(str, pos, pos + 4) == 'false' then
            return false, pos + 5
        end
        error('Invalid token at byte ' .. tostring(pos))
    elseif c == 110 then -- 'n'
        if sub(str, pos, pos + 3) == 'null' then
            return nil, pos + 4
        end
        error('Invalid token at byte ' .. tostring(pos))
    elseif c == 45 or (c >= 48 and c <= 57) then
        return parse_number(str, pos)
    else
        error('Unexpected character "' .. sub(str, pos, pos) .. '" at byte ' .. tostring(pos))
    end
end

function M.skip_ws(str, pos)
    return skip_ws(str, pos)
end

function M.decode_string_at(str, pos)
    local ok, val, next_pos = pcall(parse_string, str, pos)
    if not ok then
        return nil, pos, tostring(val)
    end
    return val, next_pos, nil
end

function M.decode_value_at(str, pos)
    local ok, val, next_pos = pcall(parse_value, str, pos, 0)
    if not ok then
        return nil, pos, tostring(val)
    end
    return val, next_pos, nil
end

function M.decode(str)
    if type(str) ~= 'string' then
        return nil, 'JSON input must be a string'
    end
    -- Strip optional UTF-8 BOM
    if sub(str, 1, 3) == '\239\187\191' then
        str = sub(str, 4)
    end
    local ok, val, next_pos = pcall(function()
        local v, p = parse_value(str, 1, 0)
        p = skip_ws(str, p)
        if p <= #str then
            error('Trailing data after JSON root value at byte ' .. tostring(p))
        end
        return v, p
    end)
    if not ok then
        return nil, tostring(val)
    end
    return val, nil
end

return M
