--[[
* SoulspireXI Soul HUD - Soul roster (key -> display name, 3-letter badge, role).
* Mirrors modules/custom/lua/soulspire_job_specs.lua. Roles drive the Crystal Job Gauge palette:
*   tank = cobalt/steel + burnished gold      healer  = emerald/pearl + silver-gold
*   support = royal violet/amber + brass      damage  = crimson/obsidian + ember gold
--]]

local M = {}

local list = {
    { 'commander', 'Commander', 'CDR', 'support' }, { 'berserker', 'Berserker', 'BRZ', 'damage' },
    { 'spartan', 'Spartan', 'SPT', 'tank' }, { 'sensei', 'Sensei', 'SEN', 'tank' },
    { 'chiweaver', 'Chi Weaver', 'CWV', 'healer' }, { 'blackbelt', 'Black Belt', 'BLK', 'damage' },
    { 'bishop', 'Bishop', 'BSH', 'healer' }, { 'zealot', 'Zealot', 'ZEL', 'damage' },
    { 'valkyrie', 'Valkyrie', 'VLK', 'support' }, { 'astromancer', 'Astromancer', 'AST', 'damage' },
    { 'channeler', 'Channeler', 'CHN', 'support' }, { 'necromancer', 'Necromancer', 'NEC', 'tank' },
    { 'crimsonduelist', 'Crimson Duelist', 'DLS', 'tank' }, { 'royaltactician', 'Royal Tactician', 'RYT', 'support' },
    { 'scarletweaver', 'Scarlet Weaver', 'SCW', 'damage' }, { 'trickster', 'Trickster', 'TRK', 'support' },
    { 'bandit', 'Bandit', 'BND', 'damage' }, { 'phantom', 'Phantom', 'PHN', 'tank' },
    { 'templar', 'Templar', 'TMP', 'healer' }, { 'defender', 'Defender', 'DFN', 'tank' },
    { 'oathbreaker', 'Oathbreaker', 'OTB', 'damage' }, { 'reaper', 'Reaper', 'RPR', 'damage' },
    { 'dreadnought', 'Dreadnought', 'DRN', 'tank' }, { 'scourge', 'Scourge', 'SCR', 'support' },
    { 'adventurer', 'Adventurer', 'ADV', 'damage' }, { 'musician', 'Musician', 'MUS', 'support' },
    { 'minstrel', 'Minstrel', 'MIN', 'tank' }, { 'sniper', 'Sniper', 'SNP', 'damage' },
    { 'huntsman', 'Huntsman', 'HNT', 'tank' }, { 'arcanearcher', 'Arcane Archer', 'ACA', 'support' },
    { 'ronin', 'Ronin', 'RON', 'tank' }, { 'imperialarcher', 'Imperial Archer', 'IMP', 'support' },
    { 'warlord', 'Warlord', 'WRL', 'support' }, { 'kurogane', 'Shinobi', 'KRG', 'damage' },
    { 'kagemusha', 'Kagemusha', 'KGM', 'tank' }, { 'nightblade', 'Nightblade', 'NGB', 'support' },
    { 'lancer', 'Lancer', 'LNC', 'damage' }, { 'skyborn', 'Skyborn', 'SKY', 'tank' },
    { 'wyvernheart', 'Wyvernheart', 'WYV', 'healer' }, { 'warmage', 'Warmage', 'WMG', 'damage' },
    { 'magus', 'Magus', 'MAG', 'healer' }, { 'azurebastion', 'Azure Bastion', 'AZB', 'tank' },
    { 'flintlock', 'Flintlock', 'FLT', 'damage' }, { 'gambler', 'Gambler', 'GMB', 'support' },
    { 'buccaneer', 'Buccaneer', 'BUC', 'tank' }, { 'freelancer', 'Freelancer', 'FRL', 'support' },
    { 'vampire', 'Vampire', 'VMP', 'healer' }, { 'bladewheel', 'Bladewheel', 'BLW', 'damage' },
    { 'miragesentinel', 'Mirage Sentinel', 'MRS', 'tank' }, { 'medic', 'Medic', 'MDC', 'healer' },
    { 'sage', 'Sage', 'SAG', 'damage' }, { 'archivist', 'Archivist', 'ARC', 'support' },
    { 'untamed', 'Untamed', 'UNT', 'damage' }, { 'alphawarden', 'Alpha Warden', 'ALW', 'tank' },
    { 'beastspeaker', 'Beastspeaker', 'BSP', 'support' }, { 'primalist', 'Primalist', 'PRM', 'damage' },
    { 'celestial', 'Celestial', 'CEL', 'healer' }, { 'herald', 'Herald', 'HLD', 'support' },
    { 'vanguard', 'Vanguard', 'VNG', 'tank' }, { 'animist', 'Animist', 'ANM', 'healer' },
    { 'pugilist', 'Pugilist', 'PGL', 'damage' }, { 'spellblade', 'Spellblade', 'SPB', 'damage' },
    { 'lifebinder', 'Lifebinder', 'LFB', 'healer' }, { 'inquisitor', 'Inquisitor', 'INQ', 'tank' },
    { 'diviner', 'Diviner', 'DIV', 'support' }, { 'verdant', 'Verdant', 'VRD', 'healer' },
    { 'terramancer', 'Terramancer', 'TRM', 'damage' },
    -- Keys that only appear in the custom status catalog / crystal art.
    { 'aegistemplar', 'Aegis Templar', 'AGT', 'tank' }, { 'gladiator', 'Gladiator', 'GLD', 'tank' },
}

local byKey = {}
M.list = {}

-- Prefer registry-generated roster (single source of truth: soulspirexi-src/registry/souls.json).
local okGen, genEntries = pcall(require, 'soulhud_roster_generated')
if okGen and type(genEntries) == 'table' and #genEntries > 0 then
    for _, r in ipairs(genEntries) do
        local e = { key = r.key, id = r.id, name = r.name, abr = r.abr, role = r.role }
        byKey[e.key] = e
        if r.primary then
            M.list[#M.list + 1] = e
        end
    end
else
    for _, r in ipairs(list) do
        local e = { key = r[1], name = r[2], abr = r[3], role = r[4] }
        byKey[e.key] = e
        M.list[#M.list + 1] = e
    end
end

M.ROLE_LABEL = { tank = 'Tank', healer = 'Healer', support = 'Support', damage = 'Damage' }

-- Always returns an entry (unknown soul keys fall back to a Support-styled medallion).
function M.get(key)
    local e = byKey[key]
    if e then return e end
    local k = tostring(key or '')
    if k == '' then return nil end
    return { key = k, name = (k:gsub('^%l', string.upper)), abr = string.upper(string.sub(k, 1, 3)), role = 'support' }
end

function M.known(key)
    return byKey[key] ~= nil
end

return M
