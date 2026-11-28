-- BattleLens display rules. Pure Lua so the host adapters can be tested without a game client.
local M = {}

M.categories = { melee = true, miss = true, evade = true }

function M.defaults()
    return {
        enabled = false,
        condense = true,
        show = { melee = true, miss = true, evade = true },
        color = { melee = 0, miss = 0, evade = 0 },
    }
end

local function protected(message, injected)
    if injected then return true end
    -- Server/client protocols and Echo/Soul output must never be hidden or rewritten.
    if message:find('%[OX[%w_]+%]') or message:find('%[Soulspire')
        or message:find('%[Echo') or message:find('%[BattleLens') then return true end
    if message:find('[\30\31\253]') then return true end -- game colors / auto-translate
    local lower = message:lower()
    for _, marker in ipairs({
        'skillchain', 'magic burst', 'critical hit', 'defeated', 'incapacitated',
        'interrupted', 'starts casting', ' casts ', ' uses ', ' readies ',
        ' gains ', ' loses ', ' wears off', ' recovers ', 'experience points',
        'treasure hunter',
    }) do
        if lower:find(marker, 1, true) then return true end
    end
    return false
end

function M.apply(config, message, mode, injected, blocked)
    if blocked or type(message) ~= 'string' or type(config) ~= 'table'
        or config.enabled ~= true or type(mode) ~= 'number' or mode % 256 ~= 9
        or protected(message, injected) then return nil end

    local actor, target, amount = message:match('^(.+) hits (.+) for (%d+) points? of damage%.$')
    local category, replacement
    if actor and target then
        category = 'melee'
        if config.condense == true then
            replacement = actor .. ' -> ' .. target .. ': ' .. amount
        end
    else
        actor, target = message:match('^(.+) misses (.+)%.$')
        if actor and target then
            category = 'miss'
            if config.condense == true then replacement = actor .. ' -> ' .. target .. ': miss' end
        else
            actor = message:match('^(.+) evades the attack%.$')
            if actor then
                category = 'evade'
                if config.condense == true then replacement = actor .. ': evade' end
            end
        end
    end
    if not category then return nil end
    if type(config.show) == 'table' and config.show[category] == false then
        return { blocked = true, category = category }
    end
    local color = type(config.color) == 'table' and tonumber(config.color[category]) or nil
    if color and (color < 1 or color > 255 or color % 1 ~= 0) then color = nil end
    if replacement or color then
        return { message = replacement, mode = color, category = category }
    end
    return nil
end

function M.command(config, line)
    if type(line) ~= 'string' then return false end
    local args = {}
    for word in line:gmatch('%S+') do args[#args + 1] = word:lower() end
    if args[1] ~= '/battlelens' and args[1] ~= '/blens' then return false end
    local action = args[2] or 'status'
    if action == 'on' or action == 'off' then
        config.enabled = action == 'on'
        return true, 'BattleLens ' .. (config.enabled and 'on' or 'off') .. '.', true
    elseif action == 'status' then
        return true, 'BattleLens ' .. (config.enabled and 'on' or 'off')
            .. '; condense ' .. (config.condense and 'on' or 'off') .. '.', false
    elseif action == 'condense' and (args[3] == 'on' or args[3] == 'off') then
        config.condense = args[3] == 'on'
        return true, 'Condensed text ' .. args[3] .. '.', true
    elseif action == 'show' and M.categories[args[3]] and (args[4] == 'on' or args[4] == 'off') then
        config.show = config.show or {}
        config.show[args[3]] = args[4] == 'on'
        return true, args[3] .. ' lines ' .. args[4] .. '.', true
    elseif action == 'color' and M.categories[args[3]] then
        local value = args[4] == 'default' and 0 or tonumber(args[4])
        if value and value >= 0 and value <= 255 and value % 1 == 0 then
            config.color = config.color or {}
            config.color[args[3]] = value
            return true, args[3] .. ' color ' .. (value == 0 and 'default' or tostring(value)) .. '.', true
        end
    end
    return true, 'Usage: /battlelens on|off|status|condense on|off|show melee|miss|evade on|off|color melee|miss|evade 1-255|default', false
end

return M
