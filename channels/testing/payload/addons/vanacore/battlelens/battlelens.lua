-- BattleLens is a separately loaded, per-character, client-only chat display addon.
addon.name = 'battlelens'
addon.author = 'SoulspireXI'
addon.version = '0.1.0'
addon.desc = 'Optional battle log filtering and formatting; off by default.'

local root = addon.path:gsub('[/\\]+$', '')
local rules = assert(loadfile(root .. '/rules.lua'))()
local store = vana.settings.register({ scope = 'character', defaults = rules.defaults() })

vana.events.on('command', function(e)
    local handled, reply, changed = rules.command(store.data, e.command)
    if not handled then return end
    if changed and store.ready then
        local ok, why = store:save()
        if not ok then print('[BattleLens] Settings could not be saved: ' .. tostring(why)) end
    end
    print('[BattleLens] ' .. reply)
    return true
end)

vana.events.on('text_in', function(e)
    local current = type(e.message_modified) == 'string' and e.message_modified or e.message
    local result = rules.apply(store.data, current, e.mode, e.injected, e.blocked)
    if not result then return end
    if result.blocked then return true end
    if result.message then e.message_modified = result.message end
    if result.mode then e.mode_modified = (e.mode_modified or e.mode) - ((e.mode_modified or e.mode) % 256) + result.mode end
end)
