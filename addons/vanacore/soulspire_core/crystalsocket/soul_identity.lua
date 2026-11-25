-- Soul identity decoder for existing SoulspireXI 0x1FC HUD packets.
-- Used only as a client-side visual label fallback when crystal catalog sync is absent.
-- Keep the job/branch map aligned with native/crystaljobs/labels.h.
local M = {}
local names = {
    [1]={'commander','berserker','spartan'},
    [2]={'sensei','chiweaver','blackbelt'},
    [3]={'bishop','zealot','valkyrie'},
    [4]={'astromancer','channeler','necromancer'},
    [5]={'crimsonduelist','royaltactician','scarletweaver'},
    [6]={'trickster','bandit','phantom'},
    [7]={'templar','defender','oathbreaker'},
    [8]={'reaper','dreadnought','scourge'},
    [9]={'untamed','soulbeast','beastspeaker'},
    [10]={'adventurer','musician','minstrel'},
    [11]={'sniper','huntsman','arcanearcher'},
    [12]={'ronin','imperialarcher','warlord'},
    [13]={'shinobi','kagemusha','nightblade'},
    [14]={'lancer','skyborn','wyvernheart'},
    [15]={'primalist','celestial','herald'},
    [16]={'warmage','magus','azurebastion'},
    [17]={'flintlock','gambler','buccaneer'},
    [18]={'vanguard','pugilist','animist'},
    [19]={'miragesentinel','vampire','bladewheel'},
    [20]={'medic','sage','archivist'},
    [21]={'diviner','verdant','terramancer'},
    [22]={'spellblade','lifebinder','inquisitor'},
}
local aliases = { kurogane = 'shinobi' }
function M.decode(data, job)
    if type(data) ~= 'string' or #data < 16 or #data > 4096 or data:sub(5, 8) ~= 'OXHD' then return nil end
    local version, unlocked, packetJob, keyLength, kvLo, kvHi = data:byte(9, 14)
    if version ~= 1 or (unlocked ~= 0 and unlocked ~= 1) or not packetJob or packetJob < 1 or packetJob > 22
        or not keyLength or keyLength > 64 or not kvLo or not kvHi or packetJob ~= job then return nil end
    if #data < 16 + keyLength + kvLo + kvHi * 256 then return nil end
    if keyLength == 0 then return { job = packetJob, branch = 0, soul = nil } end
    local soul = data:sub(17, 16 + keyLength):lower()
    if not soul:match('^[%w_%-]+$') then return nil end
    soul = aliases[soul] or soul
    for branch, key in ipairs(names[packetJob] or {}) do
        if key == soul then return { job = packetJob, branch = branch, soul = soul } end
    end
    return nil
end
return M
