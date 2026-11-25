--[[
* SoulspireXI Soul HUD - custom buff strip + chat name substitution.
*
*   - Parses `ox_buffs=<iconId>:<power>:<remSec>,...` from the server HUD key/value stream.
*   - Exposes M.buffs for the Crystal Job Gauge status sub-strip (soulhud_gauge.lua draws icons,
*     badges, timers and tooltips).
*   - Substitutes the custom status name into 0x029 wear-off / gain chat lines for 789 and 815+.
--]]

local okIcons, icons = pcall(require, 'ox_icons')
if not okIcons then icons = nil end
local okCat, catalog = pcall(require, 'status_catalog')
if not okCat then catalog = { byEffectId = {}, byIconId = {}, list = {} } end
local okBit, bit = pcall(require, 'bit')

local M = {}

M.buffs = {}   -- list of { iconId, power, rem, expiresAt, entry }

local function splitChar(str, sep)
    local out, start = {}, 1
    while true do
        local pos = string.find(str, sep, start, true)
        if not pos then out[#out + 1] = string.sub(str, start); break end
        out[#out + 1] = string.sub(str, start, pos - 1)
        start = pos + 1
    end
    return out
end

function M.parse(raw, now)
    local list = {}
    if type(raw) == 'string' and raw ~= '' then
        for _, item in ipairs(splitChar(raw, ',')) do
            local f = splitChar(item, ':')
            local iconId = tonumber(f[1])
            if iconId ~= nil then
                local rem = tonumber(f[3]) or 0
                list[#list + 1] =
                {
                    iconId    = iconId,
                    power     = tonumber(f[2]) or 0,
                    rem       = rem,
                    expiresAt = rem > 0 and (now + rem) or nil,
                    entry     = catalog.byIconId[iconId],
                }
            end
        end
    end
    M.buffs = list
end

function M.applyKv(kvMap, now)
    M.parse(kvMap and kvMap.ox_buffs or '', now)
end

-- Rendering lives in soulhud_gauge.lua (status sub-strip of the Crystal Job Gauge).

-- ---------------------------------------------------------------------------
-- 0x029 chat-log substitution for custom status names (789, 815+, and iconIds)
-- ---------------------------------------------------------------------------
local WEAR = { [64] = true, [204] = true, [206] = true }
local GAIN = { [75] = false, [230] = true, [237] = true, [266] = true }

local pending = nil  -- { name=, kind=, at= }

local function u32(d, off)
    local a, b, c, e = string.byte(d, off + 1, off + 4)
    return (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (e or 0) * 16777216
end

function M.notePacket029(data)
    if type(data) ~= 'string' or #data < 0x1A then return end
    local param = u32(data, 0x0C)
    local message = ((string.byte(data, 0x19) or 0) + (string.byte(data, 0x1A) or 0) * 256) % 32768
    local entry = catalog.byEffectId[param] or catalog.byIconId[param]
    if entry == nil then return end
    if WEAR[message] then
        pending = { name = entry.name, kind = 'wear', at = os.clock() }
    elseif GAIN[message] then
        pending = { name = entry.name, kind = 'gain', at = os.clock() }
    end
end

-- Returns the substituted message, or nil when no change applies.
function M.fixChatLine(msg)
    if pending == nil or type(msg) ~= 'string' then return nil end
    if (os.clock() - pending.at) > 1.5 then pending = nil; return nil end

    local name = pending.name
    local out, n = msg, 0
    if pending.kind == 'wear' then
        out, n = msg:gsub("'s%s+[Ss][Tt]%d+%s+effect wears off", function() return "'s " .. name .. ' effect wears off' end, 1)
        if n == 0 then
            out, n = msg:gsub("'s%s+effect wears off", function() return "'s " .. name .. ' effect wears off' end, 1)
        end
    else
        out, n = msg:gsub('effect of%s+[Ss][Tt]%d+%.', function() return 'effect of ' .. name .. '.' end, 1)
        if n == 0 then
            out, n = msg:gsub('effect of%s*%.', function() return 'effect of ' .. name .. '.' end, 1)
        end
    end
    if n > 0 then
        pending = nil
        return out
    end
    return nil
end

return M
