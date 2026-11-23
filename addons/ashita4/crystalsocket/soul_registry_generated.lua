-- AUTO-GENERATED FILE — DO NOT EDIT DIRECTLY.
-- Source of truth: soulspirexi-src/registry/souls.json
-- Registry version: 2026.11.22-66-souls-approved (schema 1.0.0)

local M = { byId = {}, byKey = {}, byJobBranch = {}, ordered = {} }
M.registryVersion = '2026.11.22-66-souls-approved'

local entries = {
    { id = 'war_support', jobId = 1, jobKey = 'WAR', branchId = 1, internalKey = 'commander', canonicalKey = 'commander', roleCategory = 'support', displayName = 'Commander', abbreviation = 'CDR', roleLabel = 'Active Tactical Buffer', icon = 'blue_crystal', legacyAliases = {  } },
    { id = 'war_dps', jobId = 1, jobKey = 'WAR', branchId = 2, internalKey = 'berserker', canonicalKey = 'berserker', roleCategory = 'dps', displayName = 'Berserker', abbreviation = 'BRZ', roleLabel = 'Fury / Heavy Burst DPS', icon = 'crimson_shard', legacyAliases = {  } },
    { id = 'war_tank', jobId = 1, jobKey = 'WAR', branchId = 3, internalKey = 'spartan', canonicalKey = 'spartan', roleCategory = 'tank', displayName = 'Spartan', abbreviation = 'SPT', roleLabel = 'Phalanx Spear-Wall & Grit Barrier Tank', icon = 'amber_crescent', legacyAliases = { 'gladiator' } },
    { id = 'mnk_tank', jobId = 2, jobKey = 'MNK', branchId = 1, internalKey = 'sensei', canonicalKey = 'sensei', roleCategory = 'tank', displayName = 'Sensei', abbreviation = 'SEN', roleLabel = 'Staff Evasion & Counter Tank', icon = 'jade_orb', legacyAliases = {  } },
    { id = 'mnk_healer', jobId = 2, jobKey = 'MNK', branchId = 2, internalKey = 'chiweaver', canonicalKey = 'chiweaver', roleCategory = 'healer', displayName = 'Stillwater', abbreviation = 'STW', roleLabel = 'Unarmed Ranged Chi & Pulse Healer', icon = 'chiweaver', legacyAliases = {  } },
    { id = 'mnk_dps', jobId = 2, jobKey = 'MNK', branchId = 3, internalKey = 'blackbelt', canonicalKey = 'blackbelt', roleCategory = 'dps', displayName = 'Wayfarer', abbreviation = 'WAY', roleLabel = 'Hand-to-Hand Martial DPS', icon = 'blackbelt', legacyAliases = {  } },
    { id = 'whm_healer', jobId = 3, jobKey = 'WHM', branchId = 1, internalKey = 'bishop', canonicalKey = 'bishop', roleCategory = 'healer', displayName = 'Bishop', abbreviation = 'BSH', roleLabel = 'Healer', icon = 'bishop', legacyAliases = {  } },
    { id = 'whm_dps', jobId = 3, jobKey = 'WHM', branchId = 2, internalKey = 'zealot', canonicalKey = 'zealot', roleCategory = 'dps', displayName = 'Penitent', abbreviation = 'PEN', roleLabel = 'Damage', icon = 'zealot', legacyAliases = {  } },
    { id = 'whm_support', jobId = 3, jobKey = 'WHM', branchId = 3, internalKey = 'valkyrie', canonicalKey = 'valkyrie', roleCategory = 'support', displayName = 'Intercessor', abbreviation = 'INC', roleLabel = 'Support', icon = 'valkyrie', legacyAliases = {  } },
    { id = 'blm_dps', jobId = 4, jobKey = 'BLM', branchId = 1, internalKey = 'astromancer', canonicalKey = 'astromancer', roleCategory = 'dps', displayName = 'Goetist', abbreviation = 'GOE', roleLabel = 'Damage', icon = 'astromancer', legacyAliases = {  } },
    { id = 'blm_support', jobId = 4, jobKey = 'BLM', branchId = 2, internalKey = 'channeler', canonicalKey = 'channeler', roleCategory = 'support', displayName = 'Channeler', abbreviation = 'CHN', roleLabel = 'Support', icon = 'channeler', legacyAliases = {  } },
    { id = 'blm_tank', jobId = 4, jobKey = 'BLM', branchId = 3, internalKey = 'necromancer', canonicalKey = 'necromancer', roleCategory = 'tank', displayName = 'Necromancer', abbreviation = 'NEC', roleLabel = 'Scythe & Undead Summoner', icon = 'onyx_tome', legacyAliases = {  } },
    { id = 'rdm_tank', jobId = 5, jobKey = 'RDM', branchId = 1, internalKey = 'crimsonduelist', canonicalKey = 'crimsonduelist', roleCategory = 'tank', displayName = 'Thornveil', abbreviation = 'THV', roleLabel = 'Hex-Crippling Fencer & Barrier Weaver', icon = 'crimsonduelist', legacyAliases = {  } },
    { id = 'rdm_support', jobId = 5, jobKey = 'RDM', branchId = 2, internalKey = 'royaltactician', canonicalKey = 'royaltactician', roleCategory = 'support', displayName = 'Arbiter', abbreviation = 'ARB', roleLabel = 'Support', icon = 'royaltactician', legacyAliases = {  } },
    { id = 'rdm_dps', jobId = 5, jobKey = 'RDM', branchId = 3, internalKey = 'scarletweaver', canonicalKey = 'scarletweaver', roleCategory = 'dps', displayName = 'Conflux', abbreviation = 'CFX', roleLabel = 'Damage', icon = 'scarletweaver', legacyAliases = {  } },
    { id = 'thf_support', jobId = 6, jobKey = 'THF', branchId = 1, internalKey = 'trickster', canonicalKey = 'trickster', roleCategory = 'support', displayName = 'Trickster', abbreviation = 'TRK', roleLabel = 'Support', icon = 'trickster', legacyAliases = {  } },
    { id = 'thf_dps', jobId = 6, jobKey = 'THF', branchId = 2, internalKey = 'bandit', canonicalKey = 'bandit', roleCategory = 'dps', displayName = 'Opportunist', abbreviation = 'OPP', roleLabel = 'Damage', icon = 'bandit', legacyAliases = {  } },
    { id = 'thf_tank', jobId = 6, jobKey = 'THF', branchId = 3, internalKey = 'phantom', canonicalKey = 'phantom', roleCategory = 'tank', displayName = 'Phantom', abbreviation = 'PHN', roleLabel = 'Tank', icon = 'phantom', legacyAliases = {  } },
    { id = 'pld_healer', jobId = 7, jobKey = 'PLD', branchId = 1, internalKey = 'templar', canonicalKey = 'templar', roleCategory = 'healer', displayName = 'Lightkeeper', abbreviation = 'LTK', roleLabel = 'Healer', icon = 'templar', legacyAliases = {  } },
    { id = 'pld_tank', jobId = 7, jobKey = 'PLD', branchId = 2, internalKey = 'aegistemplar', canonicalKey = 'defender', roleCategory = 'tank', displayName = 'Martyr', abbreviation = 'MRT', roleLabel = 'Party-Intercepting Holy Bastion', icon = 'aegistemplar', legacyAliases = {  } },
    { id = 'pld_dps', jobId = 7, jobKey = 'PLD', branchId = 3, internalKey = 'oathbreaker', canonicalKey = 'oathbreaker', roleCategory = 'dps', displayName = 'Oathbreaker', abbreviation = 'OTB', roleLabel = 'Damage', icon = 'oathbreaker', legacyAliases = {  } },
    { id = 'drk_dps', jobId = 8, jobKey = 'DRK', branchId = 1, internalKey = 'reaper', canonicalKey = 'reaper', roleCategory = 'dps', displayName = 'Harbinger', abbreviation = 'HRB', roleLabel = 'Damage', icon = 'reaper', legacyAliases = {  } },
    { id = 'drk_tank', jobId = 8, jobKey = 'DRK', branchId = 2, internalKey = 'dreadnought', canonicalKey = 'dreadnought', roleCategory = 'tank', displayName = 'Dreadnought', abbreviation = 'DRN', roleLabel = 'Blood-Pool & Dread Spikes Tank', icon = 'dreadnought', legacyAliases = {  } },
    { id = 'drk_support', jobId = 8, jobKey = 'DRK', branchId = 3, internalKey = 'scourge', canonicalKey = 'scourge', roleCategory = 'support', displayName = 'Maleficar', abbreviation = 'MLF', roleLabel = 'Support', icon = 'scourge', legacyAliases = {  } },
    { id = 'bst_dps', jobId = 9, jobKey = 'BST', branchId = 1, internalKey = 'untamed', canonicalKey = 'untamed', roleCategory = 'dps', displayName = 'Packmate', abbreviation = 'PKM', roleLabel = 'Damage', icon = 'untamed', legacyAliases = {  } },
    { id = 'bst_tank', jobId = 9, jobKey = 'BST', branchId = 2, internalKey = 'alphawarden', canonicalKey = 'alphawarden', roleCategory = 'tank', displayName = 'Alpha Warden', abbreviation = 'ALW', roleLabel = 'Tank', icon = 'alphawarden', legacyAliases = { 'soulbeast' } },
    { id = 'bst_support', jobId = 9, jobKey = 'BST', branchId = 3, internalKey = 'beastspeaker', canonicalKey = 'beastspeaker', roleCategory = 'support', displayName = 'Wildsavant', abbreviation = 'WSV', roleLabel = 'Support', icon = 'beastspeaker', legacyAliases = {  } },
    { id = 'brd_dps', jobId = 10, jobKey = 'BRD', branchId = 1, internalKey = 'adventurer', canonicalKey = 'adventurer', roleCategory = 'dps', displayName = 'Skald', abbreviation = 'SKL', roleLabel = 'Melee Damage (Dagger / Sword)', icon = 'crimson_blade', legacyAliases = {  } },
    { id = 'brd_support', jobId = 10, jobKey = 'BRD', branchId = 2, internalKey = 'musician', canonicalKey = 'musician', roleCategory = 'support', displayName = 'Cantor', abbreviation = 'CNT', roleLabel = 'Magical Song Nuker', icon = 'onyx_tome', legacyAliases = {  } },
    { id = 'brd_tank', jobId = 10, jobKey = 'BRD', branchId = 3, internalKey = 'minstrel', canonicalKey = 'minstrel', roleCategory = 'tank', displayName = 'Provocateur', abbreviation = 'PRV', roleLabel = 'Pre-Nerf Lv.75 Song Tank', icon = 'bastion_shield', legacyAliases = {  } },
    { id = 'rng_dps', jobId = 11, jobKey = 'RNG', branchId = 1, internalKey = 'sniper', canonicalKey = 'sniper', roleCategory = 'dps', displayName = 'Sniper', abbreviation = 'SNP', roleLabel = 'Damage', icon = 'sniper', legacyAliases = {  } },
    { id = 'rng_tank', jobId = 11, jobKey = 'RNG', branchId = 2, internalKey = 'huntsman', canonicalKey = 'huntsman', roleCategory = 'tank', displayName = 'Fangbound', abbreviation = 'FGB', roleLabel = 'Modal Beastmaster Ranger', icon = 'huntsman', legacyAliases = {  } },
    { id = 'rng_support', jobId = 11, jobKey = 'RNG', branchId = 3, internalKey = 'arcanearcher', canonicalKey = 'arcanearcher', roleCategory = 'support', displayName = 'Spellfletcher', abbreviation = 'SFL', roleLabel = 'Support', icon = 'arcanearcher', legacyAliases = {  } },
    { id = 'sam_tank', jobId = 12, jobKey = 'SAM', branchId = 1, internalKey = 'ronin', canonicalKey = 'ronin', roleCategory = 'tank', displayName = 'Ronin', abbreviation = 'RON', roleLabel = 'Mushin Seigan & Stagger Tank', icon = 'ronin', legacyAliases = {  } },
    { id = 'sam_ranged_dps', jobId = 12, jobKey = 'SAM', branchId = 2, internalKey = 'imperialarcher', canonicalKey = 'imperialarcher', roleCategory = 'dps', displayName = 'Amatsu', abbreviation = 'AMT', roleLabel = 'Oisoya Bow & Blade Skirmisher', icon = 'imperialarcher', legacyAliases = {  } },
    { id = 'sam_support', jobId = 12, jobKey = 'SAM', branchId = 3, internalKey = 'warlord', canonicalKey = 'warlord', roleCategory = 'support', displayName = 'Kensei', abbreviation = 'KEN', roleLabel = 'Cursed Onimaru & Iaijutsu Tactical Support', icon = 'warlord', legacyAliases = {  } },
    { id = 'nin_dps', jobId = 13, jobKey = 'NIN', branchId = 1, internalKey = 'kurogane', canonicalKey = 'kurogane', roleCategory = 'dps', displayName = 'Shinobi', abbreviation = 'SHN', roleLabel = 'Damage', icon = 'kurogane', legacyAliases = { 'shinobi' } },
    { id = 'nin_tank', jobId = 13, jobKey = 'NIN', branchId = 2, internalKey = 'kagemusha', canonicalKey = 'kagemusha', roleCategory = 'tank', displayName = 'Kagemusha', abbreviation = 'KGM', roleLabel = 'Shadow & Ninjutsu Tank', icon = 'onyx_tome', legacyAliases = {  } },
    { id = 'nin_support', jobId = 13, jobKey = 'NIN', branchId = 3, internalKey = 'nightblade', canonicalKey = 'nightblade', roleCategory = 'support', displayName = 'Fūin', abbreviation = 'FUI', roleLabel = 'Support', icon = 'nightblade', legacyAliases = {  } },
    { id = 'drg_dps', jobId = 14, jobKey = 'DRG', branchId = 1, internalKey = 'lancer', canonicalKey = 'lancer', roleCategory = 'dps', displayName = 'Highlancer', abbreviation = 'HLC', roleLabel = 'Damage', icon = 'lancer', legacyAliases = {  } },
    { id = 'drg_tank', jobId = 14, jobKey = 'DRG', branchId = 2, internalKey = 'skyborn', canonicalKey = 'skyborn', roleCategory = 'tank', displayName = 'Drachenward', abbreviation = 'DRW', roleLabel = 'Tank', icon = 'skyborn', legacyAliases = {  } },
    { id = 'drg_healer', jobId = 14, jobKey = 'DRG', branchId = 3, internalKey = 'wyvernheart', canonicalKey = 'wyvernheart', roleCategory = 'healer', displayName = 'Wyvernheart', abbreviation = 'WYV', roleLabel = 'Healer', icon = 'wyvernheart', legacyAliases = {  } },
    { id = 'smn_dps', jobId = 15, jobKey = 'SMN', branchId = 1, internalKey = 'primalist', canonicalKey = 'primalist', roleCategory = 'dps', displayName = 'Eidolarch', abbreviation = 'EID', roleLabel = 'Damage', icon = 'primalist', legacyAliases = {  } },
    { id = 'smn_healer', jobId = 15, jobKey = 'SMN', branchId = 2, internalKey = 'celestial', canonicalKey = 'celestial', roleCategory = 'healer', displayName = 'Celestial', abbreviation = 'CEL', roleLabel = 'Healer', icon = 'celestial', legacyAliases = { 'caller' } },
    { id = 'smn_support', jobId = 15, jobKey = 'SMN', branchId = 3, internalKey = 'herald', canonicalKey = 'herald', roleCategory = 'support', displayName = 'Accordant', abbreviation = 'ACD', roleLabel = 'Support', icon = 'herald', legacyAliases = {  } },
    { id = 'blu_dps', jobId = 16, jobKey = 'BLU', branchId = 1, internalKey = 'warmage', canonicalKey = 'warmage', roleCategory = 'dps', displayName = 'Assimilator', abbreviation = 'ASM', roleLabel = 'Damage', icon = 'warmage', legacyAliases = {  } },
    { id = 'blu_healer', jobId = 16, jobKey = 'BLU', branchId = 2, internalKey = 'magus', canonicalKey = 'magus', roleCategory = 'healer', displayName = 'Magus', abbreviation = 'MAG', roleLabel = 'Healer', icon = 'magus', legacyAliases = {  } },
    { id = 'blu_tank', jobId = 16, jobKey = 'BLU', branchId = 3, internalKey = 'azurebastion', canonicalKey = 'azurebastion', roleCategory = 'tank', displayName = 'Chrysalis', abbreviation = 'CHY', roleLabel = 'Monster-Core Assimilator & Dual-Wield Tank', icon = 'azurebastion', legacyAliases = {  } },
    { id = 'cor_ranged_dps', jobId = 17, jobKey = 'COR', branchId = 1, internalKey = 'flintlock', canonicalKey = 'flintlock', roleCategory = 'dps', displayName = 'Flintlock', abbreviation = 'FLT', roleLabel = 'Damage', icon = 'flintlock', legacyAliases = {  } },
    { id = 'cor_support', jobId = 17, jobKey = 'COR', branchId = 2, internalKey = 'gambler', canonicalKey = 'gambler', roleCategory = 'support', displayName = 'Gambler', abbreviation = 'GMB', roleLabel = 'Support', icon = 'gambler', legacyAliases = {  } },
    { id = 'cor_tank', jobId = 17, jobKey = 'COR', branchId = 3, internalKey = 'buccaneer', canonicalKey = 'buccaneer', roleCategory = 'tank', displayName = 'Blackwake', abbreviation = 'BKW', roleLabel = 'Tank', icon = 'buccaneer', legacyAliases = {  } },
    { id = 'pup_tank', jobId = 18, jobKey = 'PUP', branchId = 1, internalKey = 'vanguard', canonicalKey = 'vanguard', roleCategory = 'tank', displayName = 'Ironlink', abbreviation = 'IRN', roleLabel = 'Tank', icon = 'vanguard', legacyAliases = { 'marionettist' } },
    { id = 'pup_healer', jobId = 18, jobKey = 'PUP', branchId = 2, internalKey = 'animist', canonicalKey = 'animist', roleCategory = 'healer', displayName = 'Patchwork', abbreviation = 'PTW', roleLabel = 'Healer', icon = 'animist', legacyAliases = {  } },
    { id = 'pup_dps', jobId = 18, jobKey = 'PUP', branchId = 3, internalKey = 'pugilist', canonicalKey = 'pugilist', roleCategory = 'dps', displayName = 'Tandem', abbreviation = 'TDM', roleLabel = 'Damage', icon = 'pugilist', legacyAliases = {  } },
    { id = 'dnc_healer', jobId = 19, jobKey = 'DNC', branchId = 1, internalKey = 'vampire', canonicalKey = 'vampire', roleCategory = 'healer', displayName = 'Revel', abbreviation = 'RVL', roleLabel = 'Healer', icon = 'vampire', legacyAliases = {  } },
    { id = 'dnc_dps', jobId = 19, jobKey = 'DNC', branchId = 2, internalKey = 'bladewheel', canonicalKey = 'bladewheel', roleCategory = 'dps', displayName = 'Bladewheel', abbreviation = 'BLW', roleLabel = 'Ranged Chakram Dancer', icon = 'chakram_crystal', legacyAliases = {  } },
    { id = 'dnc_tank', jobId = 19, jobKey = 'DNC', branchId = 3, internalKey = 'miragesentinel', canonicalKey = 'miragesentinel', roleCategory = 'tank', displayName = 'Dervish', abbreviation = 'DRV', roleLabel = 'Fan-Dance Rhythm & Waltz-Shield Tank', icon = 'miragesentinel', legacyAliases = {  } },
    { id = 'sch_healer', jobId = 20, jobKey = 'SCH', branchId = 1, internalKey = 'medic', canonicalKey = 'medic', roleCategory = 'healer', displayName = 'Chirurgeon', abbreviation = 'CHG', roleLabel = 'Light Arts / Eos Support', icon = 'white_prism', legacyAliases = {  } },
    { id = 'sch_dps', jobId = 20, jobKey = 'SCH', branchId = 2, internalKey = 'sage', canonicalKey = 'sage', roleCategory = 'dps', displayName = 'Heliarch', abbreviation = 'HEL', roleLabel = 'Dark Arts / Titania & Helix', icon = 'onyx_tome', legacyAliases = {  } },
    { id = 'sch_support', jobId = 20, jobKey = 'SCH', branchId = 3, internalKey = 'archivist', canonicalKey = 'archivist', roleCategory = 'support', displayName = 'Archivist', abbreviation = 'ARC', roleLabel = 'Support', icon = 'archivist', legacyAliases = {  } },
    { id = 'geo_support', jobId = 21, jobKey = 'GEO', branchId = 1, internalKey = 'diviner', canonicalKey = 'diviner', roleCategory = 'support', displayName = 'Meridian', abbreviation = 'MRD', roleLabel = 'Support', icon = 'diviner', legacyAliases = {  } },
    { id = 'geo_healer', jobId = 21, jobKey = 'GEO', branchId = 2, internalKey = 'verdant', canonicalKey = 'verdant', roleCategory = 'healer', displayName = 'Verdant', abbreviation = 'VRD', roleLabel = 'Healer', icon = 'verdant', legacyAliases = {  } },
    { id = 'geo_dps', jobId = 21, jobKey = 'GEO', branchId = 3, internalKey = 'terramancer', canonicalKey = 'terramancer', roleCategory = 'dps', displayName = 'Seismancer', abbreviation = 'SEI', roleLabel = 'Damage', icon = 'terramancer', legacyAliases = {  } },
    { id = 'run_dps', jobId = 22, jobKey = 'RUN', branchId = 1, internalKey = 'spellblade', canonicalKey = 'spellblade', roleCategory = 'dps', displayName = 'Spellblade', abbreviation = 'SPB', roleLabel = 'Greatsword & Conduction Spellweaver DPS', icon = 'spellblade', legacyAliases = {  } },
    { id = 'run_healer', jobId = 22, jobKey = 'RUN', branchId = 2, internalKey = 'lifebinder', canonicalKey = 'lifebinder', roleCategory = 'healer', displayName = 'Lifebinder', abbreviation = 'LFB', roleLabel = 'Vivacious Pulse & Runic Mending Healer', icon = 'lifebinder', legacyAliases = {  } },
    { id = 'run_tank', jobId = 22, jobKey = 'RUN', branchId = 3, internalKey = 'inquisitor', canonicalKey = 'inquisitor', roleCategory = 'tank', displayName = 'Runeweft', abbreviation = 'RNW', roleLabel = 'Hybrid Stance-Swapping Ward Tank', icon = 'inquisitor', legacyAliases = {  } },
}

for _, e in ipairs(entries) do
    M.ordered[#M.ordered + 1] = e
    M.byId[e.id] = e
    M.byKey[e.internalKey] = e
    M.byKey[e.canonicalKey] = e
    for _, alias in ipairs(e.legacyAliases) do
        if M.byKey[alias] == nil then M.byKey[alias] = e end
    end
    M.byJobBranch[e.jobId] = M.byJobBranch[e.jobId] or {}
    M.byJobBranch[e.jobId][e.branchId] = e
end

function M.resolve(keyOrId)
    if keyOrId == nil then return nil end
    local k = string.lower(tostring(keyOrId))
    return M.byId[k] or M.byKey[k]
end

function M.byJob(jobId, branchId)
    return M.byJobBranch[jobId] and M.byJobBranch[jobId][branchId] or nil
end

function M.displayName(keyOrId, fallback)
    local e = M.resolve(keyOrId)
    if e ~= nil then return e.displayName end
    return fallback or keyOrId
end

return M
