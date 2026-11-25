--[[
* SoulspireXI Soul HUD - player-facing tooltip text (~40 implemented Souls).
*
* Plain-English mechanic explanations (no raw formulas). Every tooltip is structured as
*   Core Loop (Build -> Spend)  /  How It Scales  /  Right Now (live, resolved here from the 0x1FC kv map)
*   / Next Threshold.
* The server never sends computed text: the resolved numbers below are derived from `kv` quietly in Lua and
* only the clean outcome is shown.
*
* Public API
*   tips.soul(entry, ctx)               -> { weapon = '...', lines = { ... } }   Soul header / medallion / pill
*   tips.element(soulKey, which, ctx)   -> lines | nil     which = 'pips' | 'bar'  (all ~40 wired Souls)
*   tips.buff(b, now, fmtTime)          -> title, lines                              ox_buffs status icons
* A `line` is { head = 'Title', text = '...', color = {r,g,b}|nil } or { sep = true }.
* ctx = { kv = {}, lvl = number, boost = { stacks, remSec, at } | nil }
--]]

local M = {}

local GOLD  = { 232, 200, 110 }
local GREEN = { 120, 220, 150 }
local DIM   = { 184, 168, 156 }
local WARN  = { 238, 85, 68 }

-- ---------------------------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------------------------
local function num(kv, key)
    return tonumber(kv and kv[key]) or 0
end

local function str(kv, key)
    return tostring((kv and kv[key]) or '')
end

local function first(kv, ...)
    for i = 1, select('#', ...) do
        local v = tonumber(kv and kv[select(i, ...)])
        if v ~= nil then return v end
    end
    return 0
end

-- Level breakpoints used across the Soul kits: Lv10 / 30 / 50 / 70+.
local function tier(lvl, a, b, c, d)
    lvl = tonumber(lvl) or 0
    if lvl >= 70 then return d end
    if lvl >= 50 then return c end
    if lvl >= 30 then return b end
    return a
end

local function secs(n)
    n = math.max(0, math.ceil(tonumber(n) or 0))
    if n >= 60 then return ('%d:%02d'):format(math.floor(n / 60), n % 60) end
    return ('%ds'):format(n)
end

local function plural(n, one, many)
    return (n == 1) and one or many
end

local function L(head, text, color) return { head = head, text = text, color = color } end
local SEP = { sep = true }

-- ---------------------------------------------------------------------------------------------
-- role identity
-- ---------------------------------------------------------------------------------------------
local ROLE_NAME = { tank = 'Tank', healer = 'Healer', support = 'Support', damage = 'Damage' }

local ROLE_PLAY = {
    tank    = 'Stands in front, holds enemy attention and soaks hits so the party does not have to.',
    healer  = 'Keeps the party alive while still fighting, instead of standing back and only casting.',
    support = 'Strengthens the party and weakens enemies, so everyone else hits harder and lasts longer.',
    damage  = 'Turns every action into offense. No self-healing, all of the power goes into killing things.',
}

local ROLE_SCALE = {
    tank    = 'Barriers and mends scale off your Max HP and VIT, and you hold threat through Enmity rather than raw weapon damage.',
    healer  = 'Healing scales off your healing potency and Max HP, and melee or weaponskill tempo is converted into party healing.',
    support = 'Power scales with your level and support stats (potency and duration). You boost the party rather than deal damage.',
    damage  = 'All of it channels into offense with zero self-healing, so power scales with your damage stats and weaponskills.',
}

-- ---------------------------------------------------------------------------------------------
-- Soul header data (signature weapon + how it plays). Souls not listed fall back to their role text.
-- ---------------------------------------------------------------------------------------------
local SOULS = {
    commander      = { w = 'Any weapon', p = 'Battlefield tactician. Weaves short-cooldown party and mark abilities that grow stronger as you level, at the cost of some swing uptime.' },
    berserker      = { w = 'Any weapon', p = 'Unrelenting fury. Berserk, Blood Rage and Warcry are pushed into heavy Attack, Double Attack and weaponskill damage.' },
    spartan        = { w = 'Polearm + Buckler', p = 'Frontline wall. Damage you take and block turns into Grit, which Polearm weaponskills cash in for big barriers and heavy threat.' },
    gladiator      = { w = 'Polearm + Buckler', p = 'Frontline wall. Damage you take and block turns into Grit, which Polearm weaponskills cash in for big barriers and heavy threat.' },
    sensei         = { w = 'Staff', p = 'Agile staff master. Dodges and parries incoming blows, ripostes misses, and anchors threat through Counterstance.' },
    chiweaver      = { w = 'Bare fists only', p = 'Empty-handed healer. Landing melee Chi bolts and ranged hand-to-hand weaponskills builds Chi Flow, which powers party-wide Chi Blast heals. Runs on zero MP.', scale = 'Runs purely on melee Chi Flow with zero MP. More Chi means stronger healing and more debuffs cleansed.' },
    blackbelt      = { w = 'Hand-to-Hand', p = 'Pure hand-to-hand striker. Gives up weapon variety for relentless kicks, Double Attack, crits and constant weaponskill flow.' },
    bishop         = { w = 'Club (+ Shield)', p = 'Proactive white mage. Cure healing and overhealing become Solace Ward barriers, and Banish, Holy or Club weaponskills stack Sacred Grace.' },
    necromancer    = { w = 'Scythe', p = 'Commands undead thralls to tank and cast, drains life through weaponskills, and detonates thralls for burst damage.' },
    crimsonduelist = { w = '1H Sword, empty off-hand', p = 'Frontline duelist. Parries and ripostes, and gets tougher for every enfeeble on the enemy, backed by instant barriers.' },
    templar        = { w = 'Club + Shield', p = 'Holy frontliner healer. Single-target Cures splash to the whole party as heal-over-time, and melee hits pulse extra healing.' },
    aegistemplar   = { w = 'Club + Shield', p = 'Silver Aegis guardian. Intercepts damage for nearby allies and builds Zeal from blocks to power holy auras.' },
    defender       = { w = 'Club + Shield', p = 'Silver Aegis guardian. Intercepts damage for nearby allies and builds Zeal from blocks to power holy auras.' },
    dreadnought    = { w = 'Scythe', p = 'Abyssal blood-knight. Drains turn into an HP pool and Blood Tithe, which become Dread Spikes shields; Scythe weaponskills heal you back.' },
    adventurer     = { w = 'Dual Dagger / Sword', p = 'Wandering troubadour. Dual-wield melee that builds Cadence, follows weaponskills with Sonic strikes and hastes the party with Encore.' },
    musician       = { w = 'Instrument + songs', p = 'Lyrical mage. Turns Threnodies, Requiems and Elegies into fast elemental nukes that can Magic Burst.' },
    minstrel       = { w = 'Instrument + songs', p = 'Song tank. Lullaby, Elegy and Requiem draw heavy threat while Minne, Paeon and Scherzo keep you alive.' },
    alphawarden    = { w = '1H Axe + Guardian Beast', p = 'Tank bonded to a guardian beast. Splits damage with your pet, mirrors heals to it, and uses reworked Ready skills for threat.' },
    huntsman       = { w = 'Ranged weapon + pet', p = 'Pack ranger. Bond with a Glacial Tusker to hold bosses, or a Volcanic Saurian to boost the party\'s offense.' },
    flintlock      = { w = 'Gun', p = 'Pure damage Corsair. Chambers a shot, detonates Powder Marks with Quick Draw, never runs out of bullets and never heals.' },
    gambler        = { w = 'Gun', p = 'Pure support Corsair. Rolls are made safer, Lucky and XI rolls overdrive, and Quick Draw tightens party ability cooldowns.' },
    buccaneer      = { w = '1H Sword + Gun', p = 'Pure tank Corsair. Single-target pistol shots hold threat and charge Grapeshot, which Quick Draw turns into a Stoneskin barrier.' },
    vampire        = { w = 'Dagger / Throwing', p = 'Blood-dancer healer. Turns the damage you deal into party lifesteal and barriers, and detonates Finishing Moves on weaponskills. Zero MP.' },
    bladewheel     = { w = 'Chakram (throwing)', p = 'Ranged dancer. Throws your chakram from out of melee range and lets Steps, Flourishes and Sambas work at range.' },
    miragesentinel = { w = 'Dual Daggers', p = 'Acrobatic frontline dancer. Steps and Dagger weaponskills build Finishing Moves that Flourishes turn into barriers, with Fan Dance cutting damage.' },
    wyvernheart    = { w = 'Polearm + Wyvern', p = 'Dragoon healer. Polearm weaponskills, Jumps and Spirit Link build Wyrmscale that fuels party heals, while your wyvern patches up whoever is lowest.' },
    verdant        = { w = 'Club / Staff + Luopan', p = 'Nature healer. Your Luopan pulses heals, MP and Barkskin every few seconds, and weaponskills trigger an extra surge.' },
    magus          = { w = 'Dual-wield (Sword / Club)', p = 'Blue-magic healer. Healing spells splash to the party, dual-wield hits build Azure Catalyst, and linked blades siphon HP and MP to allies.' },
    azurebastion   = { w = 'Dual-wield (Sword / Club)', p = 'Monster-forged frontliner. Physical Blue Magic builds Chitin Carapace for mitigation while holding threat and weaving barriers.' },
    kurogane       = { w = 'Dual Katanas', p = 'Shadow-clone commander. Summon up to 5 offensive shadows with Shadow Squadron: Ichi/Ni, let 2 distinct clones land hits to build Feint, then sequence varied squad commands through Feint -> Switch -> Cascade for coordinated physical bursts.' },
    kagemusha      = { w = 'Dual Katanas', p = 'Shadow tank. Broken Utsusemi shadows turn into Kawarimi Ash, which Katana weaponskills spend to restore shadows and HP.' },
    ronin          = { w = 'Great Katana', p = 'Masterless tank. Mind\'s Eye counters incoming swings, and Mushin defers part of each hit into a Stagger pool you purify with Tachi skills.' },
    imperialarcher = { w = 'Bow + Great Katana', p = 'Skirmisher. Shoots from range when out of melee and chains Tachi and Archery weaponskills together.' },
    warlord        = { w = 'Great Katana', p = 'Battlefield supporter. Channels Ashura stacks and Onimaru skillchains into party-wide TP, HP and MP surges while sundering enemy armor.' },
    celestial      = { w = 'Staff / Club + Avatar', p = 'Summoner healer. Your avatar projects a healing sanctuary, resets your wards faster and pulses Starlight Mend.' },
    animist        = { w = 'Hand-to-Hand + Automaton', p = 'Martial automaton healer. Light, Water and Earth Maneuvers power a built-in white-magic automaton.' },
    vanguard       = { w = 'Hand-to-Hand + Valoredge', p = 'Automaton tank. Your Valoredge puppet draws threat on single targets and shares damage with you through Clockwork Bulwark.' },
    pugilist       = { w = 'Hand-to-Hand + Automaton', p = 'Tandem striker. Hand-to-hand weaponskills open a window where you and your automaton hit together.' },
    inquisitor     = { w = 'Rune sword / Great Sword', p = 'Ward tank. Carries three runes that are never lost to your abilities, ripostes when you parry and switches between physical and elemental stances.' },
    spellblade     = { w = 'Great Sword', p = 'Elemental spellweaver. Rune Edge strikes build Conduction and MP, which prime Runic Bolt and Runic Sever for faster, cheaper, harder spells. Damage only.' },
    lifebinder     = { w = 'Rune sword', p = 'Rune healer. Vivacious Pulse becomes a short-cooldown party heal, with runes driving Regen, Refresh, Stoneskin and cleanses.' },
    medic          = { w = 'Staff / Light Arts + Eos', p = 'Light Arts scholar. Calls the Eos faerie, sublimates safely, and auto-applies Accession to Cure and Regen spells.' },
    sage           = { w = 'Staff / Dark Arts + Titania', p = 'Dark Arts scholar. Calls the Titania faerie, keeps Ebullience up and hits harder with Helix and elemental magic.' },
}

local function resolveSoul(entry)
    local d = SOULS[entry.key]
    local role = entry.role
    local p = d and d.p or ROLE_PLAY[role]
    local scale = d and d.scale or ROLE_SCALE[role]
    return d and d.w or nil, p, scale
end

function M.soul(entry, ctx)
    local weapon, play, scale = resolveSoul(entry)
    local lines = {
        L('How It Plays', play),
        L('How It Scales', scale),
    }
    local lvl = tonumber(ctx and ctx.lvl) or 0
    if lvl > 0 and lvl < 10 then
        lines[#lines + 1] = L('Locked', 'Soul abilities unlock at level 10.', WARN)
    end
    return { weapon = weapon, lines = lines, role = ROLE_NAME[entry.role] }
end

-- ---------------------------------------------------------------------------------------------
-- Gauge / pip tooltips for all ~40 wired Souls
-- ---------------------------------------------------------------------------------------------
local E = {}

local WAR_STANCE_NAMES = {
    [0] = 'No Stance',
    [1] = 'Berserk (+15% party Attack on Warcry)',
    [2] = 'Defender (+20% party Defense & -8% damage taken on Warcry)',
    [3] = 'Aggressor (+25 party Accuracy & +8% Double Attack on Warcry)',
    [4] = 'Retaliation (+12% party Counter & +10 Store TP on Warcry)',
    [5] = 'Restraint (+12% party Weaponskill Damage & +200 TP Bonus on Warcry)',
}

E.commander = {
    pips = {
        core  = 'Build: activate one Warrior stance (Berserk, Defender, Aggressor, Retaliation or Restraint). Spend: Warcry shares that stance\'s tactical bonus with the whole party, while Bulwark, Cadence and Rallying Horn layer extra party orders.',
        scale = 'Order potency scales across level milestones (Lv10, 30, 50, 70+). Only one Warrior stance stays active at a time so you can swap orders cleanly.',
        live  = function(c)
            local st = math.floor(num(c.kv, 'stance'))
            local orders = math.floor(num(c.kv, 'orders'))
            return ('%d/4 orders active. Current stance: %s.'):format(orders, WAR_STANCE_NAMES[st] or 'No Stance')
        end,
        nxt   = function(c)
            if num(c.kv, 'stance') <= 0 then return 'Activate Berserk, Defender, Aggressor, Retaliation or Restraint before using Warcry.' end
            if num(c.kv, 'warcry_rem') <= 0 then return 'Press Warcry to share your active stance bonus with the party.' end
            return 'Weave Formation: Bulwark, Battle Cadence and Tactical Breach between swings.'
        end,
    },
    bar = {
        core  = 'Tactical Breach marks your target for 10s so every ally deals more Skillchain, Magic Burst and critical damage, and gains bonus TP when closing a Skillchain.',
        scale = 'At Lv10/30/50/70+, Breach boosts Skillchains by +12/18/24/30%, Magic Bursts and crits by +8/12/16/20%, and refunds +100/150/200/250 TP to the closer.',
        live  = function(c)
            local br = num(c.kv, 'breach_rem')
            if br > 0 then
                return ('Tactical Breach is on your target for %s (+%d%% Skillchain damage, +%d%% Magic Burst/crit).'):format(
                    secs(br), tier(c.lvl, 12, 18, 24, 30), tier(c.lvl, 8, 12, 16, 20))
            end
            local wc = num(c.kv, 'warcry_rem')
            if wc > 0 then return ('Warcry Banner is active for %s.'):format(secs(wc)) end
            local bn = math.max(num(c.kv, 'bulwark_rem'), num(c.kv, 'cadence_rem'), num(c.kv, 'regroup_rem'))
            if bn > 0 then return ('Formation order active for %s.'):format(secs(bn)) end
            return 'No Tactical Breach mark or banner timer running.'
        end,
        nxt   = function(c)
            if num(c.kv, 'breach_rem') <= 0 then return 'Use Tactical Breach before your party closes a Skillchain or Magic Burst.' end
            return 'Close a Skillchain or Magic Burst while Tactical Breach is active.'
        end,
    },
}

E.berserker = {
    pips = {
        core  = 'Build: layer Berserk (+300 TP on use), Aggressor (+5% Crit, zero Evasion loss), Blood Rage, Warcry and Bloodlust Surge. Spend: unleash heavy weaponskills and Savage Cleave during your overlap window.',
        scale = 'Pure damage: every cooldown multiplies your Attack%, Double Attack damage and critical hit rate with zero self-healing.',
        live  = function(c)
            local f = math.floor(num(c.kv, 'fury'))
            if f <= 0 then return 'No fury buffs active. Pop Berserk (+300 TP) and Aggressor to start.' end
            return ('%d/4 fury buffs active. Your swings and weaponskills are running at heightened offense.'):format(f)
        end,
        nxt   = function(c)
            if num(c.kv, 'berserk_rem') <= 0 then return 'Activate Berserk for +300 instant TP and heavy Attack.' end
            if num(c.kv, 'surge_rem') <= 0 then return 'Trigger Bloodlust Surge before your next weaponskill or Savage Cleave.' end
            return 'All fury windows aligned — fire your hardest weaponskill.'
        end,
    },
    bar = {
        core  = 'Bloodlust Surge supercharges Attack% and Double Attack damage for 10s on a short 25s cooldown.',
        scale = 'Scales to +10/14/18/24% Attack and +15/22/30/40% Double Attack damage at Lv10/30/50/70+.',
        live  = function(c)
            local s = num(c.kv, 'surge_rem')
            if s > 0 then
                return ('Bloodlust Surge is up for %s (+%d%% Attack, +%d%% Double Attack damage).'):format(
                    secs(s), tier(c.lvl, 10, 14, 18, 24), tier(c.lvl, 15, 22, 30, 40))
            end
            local b = num(c.kv, 'berserk_rem')
            if b > 0 then return ('Berserk is active for %s.'):format(secs(b)) end
            return 'Bloodlust Surge and Berserk are currently idle.'
        end,
        nxt   = function(c)
            if num(c.kv, 'surge_rem') > 0 then return 'Weave Savage Cleave and a weaponskill before the 10s surge ends.' end
            return 'Use Bloodlust Surge (25s cooldown) whenever you have TP ready.'
        end,
    },
}

E.spartan = {
    pips = {
        core  = 'Build: taking hits and blocking grants Grit. Spend: any Polearm weaponskill burns all your Grit into a protective barrier and heavy Enmity.',
        scale = 'The barrier is a share of your Max HP (and VIT makes you tougher), not weapon damage. Enmity keeps enemies pointed at you.',
        live  = function(c)
            local g = math.floor(num(c.kv, 'grit'))
            local br = math.floor(num(c.kv, 'brace'))
            local brTxt = br >= 2 and ' Heavy Brace is armed (-50% next hit, fills Grit to 5).'
                or (br == 1 and ' Light Brace is armed (-25% next hit, +1 Grit).' or '')
            if g <= 0 then return 'No Grit yet. Take a hit or block to start building.' .. brTxt end
            local per = tier(c.lvl, 4, 5, 6, 7)
            return ('%d Grit: a Polearm weaponskill now would raise a barrier of about %d%% of your Max HP.%s'):format(g, math.min(g * per, 40), brTxt)
        end,
        nxt   = function(c)
            local g = math.floor(num(c.kv, 'grit'))
            if g >= 5 then return 'Grit is full. Use a Polearm weaponskill to cash it in.' end
            return ('Each Grit adds about %d%% more barrier. At 5 Grit the barrier is as big as it gets.'):format(tier(c.lvl, 4, 5, 6, 7))
        end,
    },
    bar = {
        core  = 'Spend 2 Grit on Phalanx Ward for a short window of heavy blocking and reduced damage while you hold the enemy\'s attention.',
        scale = 'Block chance, damage reduction and threat all grow with your level and Max HP/VIT.',
        live  = function(c)
            local r = num(c.kv, 'ward_rem')
            if r > 0 then return ('Phalanx Ward is up for %s: you block more, take less damage and cannot be knocked back.'):format(secs(r)) end
            return 'Phalanx Ward is not active.'
        end,
        nxt   = function(c)
            if num(c.kv, 'ward_rem') > 0 then return 'Keep taking hits. Landing blocks while it is up refills Grit.' end
            if num(c.kv, 'grit') >= 2 then return 'You have the 2 Grit needed. Phalanx Ward is ready when its cooldown allows.' end
            return 'Reach 2 Grit to use Phalanx Ward.'
        end,
    },
}
E.gladiator = E.spartan

E.sensei = {
    pips = {
        core  = 'Build: equip a Staff and keep Iron Counterstance, Dodge and Focus active. Spend: every evaded or parried attack automatically fires a Staff Riposte that heals you, builds TP and snaps threat.',
        scale = 'Iron Counterstance has no Defense penalty on Sensei (-10% damage taken, +30% Counter). Riposte healing scales with your Max HP.',
        live  = function(c)
            local staff = num(c.kv, 'staff') > 0
            local st = math.floor(num(c.kv, 'stances'))
            if not staff then return 'No Staff equipped! Equip a Staff in your main hand to unlock Staff Riposte and +12% Parry.' end
            return ('Staff equipped (%d/4 defensive forms active). Parries heal 2%% Max HP (+75 TP); dodges heal 1.5%% Max HP (+50 TP).'):format(st)
        end,
        nxt   = function(c)
            if num(c.kv, 'staff') <= 0 then return 'Equip a Staff immediately.' end
            if num(c.kv, 'counter_rem') <= 0 then return 'Activate Counterstance for +30% Counter and -10% damage taken with zero DEF loss.' end
            return 'Layer Dodge, Focus and Perfect Counter against heavy attacks.'
        end,
    },
    bar = {
        core  = 'Perfect Counter (45s CD) and Inner Strength supercharge your counter-attacks, self-healing and mitigation.',
        scale = 'Counterstance, Dodge and Focus run for 60-300s to keep your evasion and parry rates near cap.',
        live  = function(c)
            local inr = num(c.kv, 'inner_rem')
            if inr > 0 then return ('Inner Strength active for %s (-25%% damage taken, +20%% Evasion, +50 Enmity).'):format(secs(inr)) end
            local pc = num(c.kv, 'pcounter_rem')
            if pc > 0 then return ('Perfect Counter ready for %s (+25 Counter Damage, +25 Enmity).'):format(secs(pc)) end
            local cs = num(c.kv, 'counter_rem')
            if cs > 0 then return ('Iron Counterstance active for %s.'):format(secs(cs)) end
            return 'No defensive form timer running.'
        end,
        nxt   = function(c)
            if num(c.kv, 'counter_rem') <= 0 then return 'Put up Counterstance to anchor frontline threat.' end
            return 'Use Perfect Counter on cooldown (45s) for a free 5% Max HP heal and guaranteed counter.'
        end,
    },
}

E.blackbelt = {
    pips = {
        core  = 'Build: rotate Focus (+10% Crit, +15% Crit DMG), Footwork (+Kick Rate/DMG, +10% Attack), Boost (+100 TP, +15% next WSD) and Dodge (+10% Ability Haste). Spend: chain Hand-to-Hand weaponskills that refund +75 TP each.',
        scale = 'Pure hand-to-hand damage: scales with H2H skill, STR/DEX, Kick Attacks and Multi-Attack. Restricted strictly to H2H or bare fists.',
        live  = function(c)
            local st = math.floor(num(c.kv, 'stances'))
            return ('%d/4 martial forms active. Every Hand-to-Hand weaponskill refunds +75 TP on hit.'):format(st)
        end,
        nxt   = function(c)
            if num(c.kv, 'focus_rem') <= 0 then return 'Activate Focus for +10% Crit Rate, +15% Crit Damage and +25 Accuracy.' end
            if num(c.kv, 'footwork_rem') <= 0 then return 'Activate Footwork for +10% Attack and harder Kick Attacks.' end
            return 'Tap Boost before every weaponskill for +100 TP and +15% weaponskill damage.'
        end,
    },
    bar = {
        core  = 'Hundred Fists and Footwork drive rapid multi-hit combos that feed constant weaponskills.',
        scale = 'Hundred Fists also grants +25% Attack, +15% Crit Rate, +20% Double Attack and +20 Store TP on Black Belt.',
        live  = function(c)
            local hf = num(c.kv, 'hf_rem')
            if hf > 0 then return ('Hundred Fists overdrive active for %s!'):format(secs(hf)) end
            local fw = num(c.kv, 'footwork_rem')
            if fw > 0 then return ('Footwork active for %s (+15 Kick DMG, +10%% Kick Rate, +10%% Attack).'):format(secs(fw)) end
            local fc = math.max(num(c.kv, 'focus_rem'), num(c.kv, 'boost_rem'), num(c.kv, 'dodge_rem'))
            if fc > 0 then return ('Martial buff window active for %s.'):format(secs(fc)) end
            return 'No active form timer.'
        end,
        nxt   = function()
            return 'Weave Boost and Chi Blast (+100 TP, -15% enemy DEF) between weaponskills.'
        end,
    },
}

E.chiweaver = {
    pips = {
        core  = 'Build: each landed bare-handed Chi bolt adds +1 Chi, ranged H2H weaponskills add +3 to +5, and Boost adds +5. Spend: Chi Blast (5s CD) consumes all Chi to heal and cleanse the party within 20y.',
        scale = 'Cleanse tiers unlock at 25 Chi (1 debuff), 50 Chi (2 debuffs), 80 Chi (3 debuffs) and 100 Chi (maximum 2.5x healing multiplier).',
        live  = function(c)
            local s = math.floor(math.max(first(c.kv, 'chi_stacks', 'chi'), (c.boost and c.boost.stacks) or 0))
            local cl = (s >= 80 and 3) or (s >= 50 and 2) or (s >= 25 and 1) or 0
            return ('%d/100 Chi banked: Chi Blast will currently cleanse %d %s on every ally within 20y.'):format(s, cl, plural(cl, 'debuff', 'debuffs'))
        end,
        nxt   = function(c)
            local s = math.floor(math.max(first(c.kv, 'chi_stacks', 'chi'), (c.boost and c.boost.stacks) or 0))
            if s < 25 then return ('%d more Chi unlocks 1-debuff party cleanse on Chi Blast.'):format(25 - s) end
            if s < 50 then return ('%d more Chi unlocks 2-debuff party cleanse.'):format(50 - s) end
            if s < 80 then return ('%d more Chi unlocks 3-debuff party cleanse.'):format(80 - s) end
            return 'Max cleanse tier reached! Press Chi Blast whenever the party needs a big heal.'
        end,
    },
    bar = {
        core  = 'Build: every landed Chi bolt adds a stack, ranged hand-to-hand weaponskills add several, and the Boost ability adds more. Spend: Chi Blast heals the whole party and cleanses debuffs.',
        scale = 'Runs purely on melee Chi Flow with zero MP. More Chi means stronger healing power and more debuffs cleansed, and Chi fades when Boost runs out.',
        live  = function(c)
            local s = math.floor(math.max(first(c.kv, 'chi_stacks', 'chi'), (c.boost and c.boost.stacks) or 0))
            local pot = math.floor(s / 5)
            local cl = (s >= 80 and 3) or (s >= 50 and 2) or (s >= 25 and 1) or 0
            local mult = 0.50 + (s * 0.045) + ((s * s) / 10000.0) * 1.55
            local out = ('%d Chi: +%d%% Healing Power, +%d Magic Accuracy and Attack. Chi Blast heals about %.1fx its base amount'):format(s, pot, pot, mult)
            if cl > 0 then
                out = out .. (' and cleanses %d %s.'):format(cl, plural(cl, 'debuff', 'debuffs'))
            else
                out = out .. ' but cleanses nothing yet.'
            end
            local rem = c.boost and c.boost.remSec or num(c.kv, 'boost_rem')
            if rem > 0 and c.boost and c.boost.at then
                rem = math.max(0, rem - (os.clock() - c.boost.at))
            end
            if rem > 0 then out = out .. (' Boost lasts %s.'):format(secs(rem)) end
            return out
        end,
        nxt   = function(c)
            local s = math.floor(math.max(first(c.kv, 'chi_stacks', 'chi'), (c.boost and c.boost.stacks) or 0))
            if s >= 100 then return 'Chi is maxed out. Spend it with Chi Blast.' end
            for _, step in ipairs({ { 25, 'cleanse 1 debuff' }, { 50, 'cleanse 2 debuffs' }, { 80, 'cleanse 3 debuffs' }, { 100, 'reach maximum power' } }) do
                if s < step[1] then
                    return ('Reach %d Chi (%d more) to %s.'):format(step[1], step[1] - s, step[2])
                end
            end
            return ''
        end,
    },
}

E.bishop = {
    pips = {
        core  = 'Build: casting Banish, Holy or landing a Club/Staff weaponskill grants +1 Sacred Grace (up to 3) and restores 6% Max MP. Spend: at 3 stacks, your next Curaga, Esuna or Auspice consumes Sacred Grace to pulse a 15y party Regen.',
        scale = 'Single-target Cures also wrap the target in a Solace Ward Stoneskin (35-50% of heal, up to 30% Max HP) and -8% damage taken.',
        live  = function(c)
            local g = math.floor(num(c.kv, 'grace'))
            local sol = math.floor(num(c.kv, 'solace'))
            local stance = sol == 1 and 'Afflatus Solace active (100% SIRD).' or (sol == 2 and 'Afflatus Misery active (100% SIRD).' or 'No Afflatus stance active.')
            return ('%d/3 Sacred Grace. %s'):format(g, stance)
        end,
        nxt   = function(c)
            local g = math.floor(num(c.kv, 'grace'))
            if g >= 3 then return 'Sacred Grace is full! Cast Curaga, Esuna or Auspice to trigger the party Regen pulse.' end
            return ('Cast Banish/Holy or use a Club weaponskill (%d more) to reach 3 Sacred Grace.'):format(3 - g)
        end,
    },
    bar = {
        core  = 'Divine Veil wraps the party in Stoneskin + -12% damage taken and makes your next single-target Cure or Erase splash across the whole party.',
        scale = 'Barrier size and Sanctuary Pulse healing scale off your Max HP, MND and Cure Potency.',
        live  = function(c)
            local v = num(c.kv, 'veil_rem')
            if v > 0 then return ('Divine Veil is active for %s: your next Cure or Erase splashes to the whole party!'):format(secs(v)) end
            local w = num(c.kv, 'ward_rem')
            if w > 0 then return ('Solace Ward (-8%% damage taken + Stoneskin) is active for %s.'):format(secs(w)) end
            local g = num(c.kv, 'grace_rem')
            if g > 0 then return ('Sacred Grace stacks last %s.'):format(secs(g)) end
            return 'Divine Veil and Solace Ward are currently idle.'
        end,
        nxt   = function(c)
            if num(c.kv, 'veil_rem') > 0 then return 'Cast a high-tier single-target Cure or Erase now to splash it party-wide.' end
            return 'Use Divine Veil before heavy AoE damage.'
        end,
    },
}

E.necromancer = {
    pips = {
        core  = 'Build: summon an Undead Warrior / Dullahan (Tank mode) to hold bosses and receive 100% of your single-target threat, or an Undead Mage / Corse (Caster mode) for party offense. Spend: command your thrall via Grim Reaping / Grim Incantations, or detonate it with Corpse Explosion.',
        scale = 'While any thrall lives, Dark Pact grants you +8/12/16/20% Double Attack, +10/15/20/25 Store TP and +10/20/35/50 Accuracy, and Grim Conversion turns your Magic stats into melee Accuracy, Attack, Haste and Weaponskill Damage.',
        live  = function(c)
            local mode = str(c.kv, 'thrall_mode')
            if mode == 'dullahan' or mode == 'warrior' then
                return ('Tank Thrall (%s) active: Dark Pact is online, your single-target threat funnels to your thrall, and Cures on you forward 80%% to it.'):format(mode)
            elseif mode == 'corse' or mode == 'mage' then
                return ('Caster Thrall (%s) active: Dark Pact is online and Grim Incantations are unlocked.'):format(mode)
            end
            return 'No Undead Thrall summoned. Dark Pact is offline.'
        end,
        nxt   = function(c)
            if num(c.kv, 'thrall_id') <= 0 then return 'Summon Undead Warrior/Dullahan to tank, or Undead Mage/Corse for caster support.' end
            return 'Use Scythe weaponskills to drain life into you and your thrall.'
        end,
    },
    bar = {
        core  = 'Tracks your active Undead Thrall\'s remaining HP%. Scythe weaponskills and Cures cast on you keep your Tank Thrall topped up.',
        scale = 'Tank Thralls gain massive Max HP, -30% damage taken and AoE immunity.',
        live  = function(c)
            local id = num(c.kv, 'thrall_id')
            local hpp = math.floor(num(c.kv, 'thrall_hpp'))
            if id <= 0 then return 'No thrall is currently active.' end
            return ('Thrall is at %d%% HP.'):format(hpp)
        end,
        nxt   = function(c)
            if num(c.kv, 'thrall_id') <= 0 then return 'Call an Undead Thrall to activate your companion bar.' end
            if num(c.kv, 'thrall_hpp') < 50 then return 'Land a Scythe weaponskill or use Blood Saber / Bone Aegis to mend your thrall.' end
            return 'Command your thrall with Grim Reaping or Grim Incantations.'
        end,
    },
}

E.crimsonduelist = {
    pips = {
        core  = 'Build: land enfeebles (Dia, Slow, Paralyze, Blind, Hex Volley) on your enemy while wielding a 1H Sword with an empty off-hand. Spend: each active enfeeble cuts the enemy\'s damage dealt by 5% (up to -25%) and boosts your Parry Rate by +3% (up to +15%).',
        scale = 'Parrying triggers Crimson Riposte (Light/Ice counter-damage, heavy threat and +4% Max MP). Sword weaponskills grant Crimson Flow so your next Enfeeble, Stoneskin or Phalanx casts instantly for 0 MP.',
        live  = function(c)
            local h = math.floor(num(c.kv, 'hexes'))
            local f = num(c.kv, 'fencer') > 0
            if not f then return 'Equip a 1H Sword with an empty off-hand to activate Crimson Fencer Mastery.' end
            return ('%d/5 enfeebles on target: target deals -%d%% damage and you gain +%d%% bonus Parry Rate.'):format(h, h * 5, h * 3)
        end,
        nxt   = function(c)
            if num(c.kv, 'fencer') <= 0 then return 'Unequip your off-hand and wield a 1H Sword.' end
            local h = math.floor(num(c.kv, 'hexes'))
            if h < 5 then return ('Land %d more enfeeble(s) (or press Hex Volley) to reach the -25%% damage cap.'):format(5 - h) end
            return 'Target is fully hexed (-25% damage dealt). Maintain Stoneskin and Phalanx.'
        end,
    },
    bar = {
        core  = 'Tracks Crimson Flow (instant 0-MP spell proc after a Sword weaponskill), Crimson Fleche (+35% Parry window), or your active Stoneskin barrier.',
        scale = 'Stoneskin scales up to 25% of your Max HP and is automatically refreshed by Convert (30s CD) and Crimson Fleche.',
        live  = function(c)
            local fl = num(c.kv, 'flow_rem')
            if fl > 0 then return ('Crimson Flow active for %s: your next Enfeeble, Stoneskin or Phalanx is instant and costs 0 MP!'):format(secs(fl)) end
            local fc = num(c.kv, 'fleche_rem')
            if fc > 0 then return ('Crimson Fleche active for %s (+35%% Parry Rate; next WS/Enfeeble raises a full Stoneskin).'):format(secs(fc)) end
            local ss = math.floor(num(c.kv, 'stoneskin'))
            if ss > 0 then return ('Stoneskin barrier absorbing up to %d damage.'):format(ss) end
            return 'No active Crimson Flow or Stoneskin barrier.'
        end,
        nxt   = function(c)
            if num(c.kv, 'flow_rem') > 0 then return 'Cast Stoneskin, Phalanx or an Enfeeble immediately for an instant 0-MP cast.' end
            return 'Land a Sword weaponskill to trigger Crimson Flow, or press Crimson Fleche.'
        end,
    },
}

E.aegistemplar = {
    pips = {
        core  = 'Build: blocking with a Shield, casting Flash, or using Shield Bash with Club + Shield equipped builds Aegis Zeal (up to 5). Spend: at 5 Zeal (or on Judgment Gavel / Club weaponskills), you detonate Holy Nova for AoE Light threat, +8% Max MP and a party -10% damage taken aura.',
        scale = 'Divine Intercept passively redirects 25% of damage taken by nearby allies (40% during Aegis Consecration) onto you at a 20% discount.',
        live  = function(c)
            local z = math.floor(num(c.kv, 'zeal'))
            if z <= 0 then return 'No Aegis Zeal yet. Block attacks, cast Flash or use Shield Bash with Club + Shield.' end
            return ('%d/5 Aegis Zeal active.'):format(z)
        end,
        nxt   = function(c)
            local z = math.floor(num(c.kv, 'zeal'))
            if z >= 5 then return 'Zeal is full! Detonate Holy Nova with a Club weaponskill or Judgment Gavel.' end
            return ('%d more Zeal reaches the 5-stack Holy Nova threshold.'):format(5 - z)
        end,
    },
    bar = {
        core  = 'Aegis Consecration increases your Divine Intercept redirect to 40% while granting party mitigation, and Holy Retribution protects nearby allies with -10% damage taken.',
        scale = 'Scales with your Max HP, VIT, MND and Shield Block Rate.',
        live  = function(c)
            local cr = num(c.kv, 'consec_rem')
            if cr > 0 then return ('Aegis Consecration active for %s (40%% ally damage intercept).'):format(secs(cr)) end
            local rr = num(c.kv, 'retrib_rem')
            if rr > 0 then return ('Holy Retribution aura (-10%% party damage taken) active for %s.'):format(secs(rr)) end
            local zr = num(c.kv, 'zeal_rem')
            if zr > 0 then return ('Aegis Zeal lasts %s.'):format(secs(zr)) end
            return 'No active Consecration or Retribution window.'
        end,
        nxt   = function(c)
            if num(c.kv, 'consec_rem') <= 0 then return 'Use Aegis Consecration before a party-wide attack to intercept 40% of ally damage.' end
            return 'Keep blocking and weaving Club weaponskills to refresh Holy Retribution.'
        end,
    },
}
E.defender = E.aegistemplar

E.templar = {
    pips = {
        core  = 'Build: Perpetual Majesty is always active at Lv10+, making every single-target Cure splash to the party within 15y at 100% power. Spend: melee hits and Club weaponskills pulse Beacon of Light heals to the lowest-HP ally and restore 5% Max MP.',
        scale = 'Overhealing with Cure wraps allies in Light\'s Grace (heal-over-time). Wearing a Shield grants 100% Spell Interruption Rate Down.',
        live  = function(c)
            local sh = num(c.kv, 'shield') > 0
            local aeg = num(c.kv, 'aegis_rem')
            return ('Perpetual Majesty active (%s).%s'):format(
                sh and 'Shield equipped: 100% SIRD' or 'Equip a Shield for 100% SIRD',
                aeg > 0 and ' Crusader\'s Aegis is doubling your Beacon pulses!' or '')
        end,
        nxt   = function(c)
            if num(c.kv, 'shield') <= 0 then return 'Equip a Club and Shield for 100% SIRD and Holy Radiance.' end
            return 'Cast single-target Cures for party-wide splash + Light\'s Grace HoTs, and stay in melee for Beacon pulses.'
        end,
    },
    bar = {
        core  = 'Crusader\'s Aegis (25s CD) grants the party -15% damage taken, Knockback Immunity and doubles your Beacon of Light healing pulses for 10s.',
        scale = 'Beacon heals 8/11/14/18% of your Max HP (doubled to 16/22/28/36% during Crusader\'s Aegis).',
        live  = function(c)
            local a = num(c.kv, 'aegis_rem')
            if a > 0 then return ('Crusader\'s Aegis active for %s (-15%% party DT, Knockback Immune, 2x Beacon heals).'):format(secs(a)) end
            local g = num(c.kv, 'grace_rem')
            if g > 0 then return ('Light\'s Grace heal-over-time active for %s.'):format(secs(g)) end
            return 'Crusader\'s Aegis is ready when its cooldown allows.'
        end,
        nxt   = function(c)
            if num(c.kv, 'aegis_rem') > 0 then return 'Swing and use Club weaponskills now while Beacon healing is doubled.' end
            return 'Use Holy Radiance (20s CD) or Crusader\'s Aegis (25s CD) when the party takes pressure.'
        end,
    },
}

E.dreadnought = {
    pips = {
        core  = 'Build: Absorb spells and Abyssal Cleave add Blood Tithe (up to 3). Spend: Dread Spikes consumes Tithe to grow its HP shield from 25% up to 40% of your Max HP.',
        scale = 'Drain II overcaps your Max HP by +25%, and Vampiric Scythe weaponskills cash in Blood Reap for heavy self-healing.',
        live  = function(c)
            local t = math.floor(num(c.kv, 'tithe'))
            local reap = num(c.kv, 'reap_rem')
            local s = ('%d/3 Blood Tithe: Dread Spikes will shield %d%% of your Max HP.'):format(t, 25 + 5 * t)
            if reap > 0 then s = s .. (' Blood Reap is active for %s.'):format(secs(reap)) end
            return s
        end,
        nxt   = function(c)
            local t = math.floor(num(c.kv, 'tithe'))
            if t >= 3 then return 'Blood Tithe is full (40% Max HP Dread Spikes). Cast Dread Spikes now.' end
            return ('Cast an Absorb spell or Abyssal Cleave (%d more) to max out Blood Tithe.'):format(3 - t)
        end,
    },
    bar = {
        core  = 'Tracks your remaining Dread Spikes blood-shield HP, Dread Bastion / Blood Carapace ward timer, or Blood Reap window.',
        scale = 'Shields and drains scale off your Max HP and VIT, and each physical hit absorbed by Dread Spikes adds volatile threat.',
        live  = function(c)
            local sp = math.floor(num(c.kv, 'spikes_hp'))
            if sp > 0 then return ('Dread Spikes has %d HP of physical absorption remaining.'):format(sp) end
            local b = math.max(num(c.kv, 'bastion_rem'), num(c.kv, 'carapace_rem'))
            if b > 0 then return ('Defensive ward active for %s.'):format(secs(b)) end
            local r = num(c.kv, 'reap_rem')
            if r > 0 then return ('Blood Reap window open for %s: land a Scythe weaponskill for bonus drain healing.'):format(secs(r)) end
            return 'No active Dread Spikes shield.'
        end,
        nxt   = function(c)
            if num(c.kv, 'spikes_hp') <= 0 then return 'Keep Dread Spikes and Drain II (+25% Max HP overcap) up at all times.' end
            return 'Use Scythe weaponskills while Blood Reap is active to refill your HP.'
        end,
    },
}

local BST_BEAST_INFO = {
    [1] = 'CourierCarrie (Armored Crab)',
    [2] = 'PanzerGalahad (Rhinoceros Beetle)',
    [3] = 'CrudeRaphie (Plated Tortoise)',
    [4] = 'SaberSiravarde (Sabertooth Tiger)',
}

E.alphawarden = {
    pips = {
        core  = 'Build: summon one of your 4 whitelisted Guardian Beasts (zero jug items consumed) and wield a 1H Axe. Spend: Symbiotic Soul-Link splits 50% of all damage you take onto your beast (mitigated by its -30% DT), and 100% of pet threat funnels onto you.',
        scale = 'Soul-Link stays active as long as your Guardian Beast is at 15% HP or higher. Cures and Regen on you mirror 60% (+100% overheal) to your beast.',
        live  = function(c)
            local idx = math.max(1, math.min(4, math.floor(first(c.kv, 'beast_idx') > 0 and first(c.kv, 'beast_idx') or 1)))
            local alive = num(c.kv, 'pet_alive') > 0
            local link = num(c.kv, 'soullink') > 0
            if not alive then return ('Selected Guardian #%d: %s (currently unsummoned).'):format(idx, BST_BEAST_INFO[idx]) end
            return ('%s active. Symbiotic Soul-Link (50%% damage split): %s.'):format(
                BST_BEAST_INFO[idx], link and 'ONLINE' or 'PAUSED (pet below 15% HP)')
        end,
        nxt   = function(c)
            if num(c.kv, 'pet_alive') <= 0 then return 'Press Call Beast or Bestial Loyalty to summon your Guardian Beast.' end
            if num(c.kv, 'soullink') <= 0 then return 'Use Reward or land a 1H Axe weaponskill (heals pet 15-25%) to bring your pet above 15% HP.' end
            return 'Weave 1H Axe weaponskills and Ready skills (funnel threat + grant you +100 TP).'
        end,
    },
    bar = {
        core  = 'Tracks your Guardian Beast\'s HP%. 1H Axe weaponskills heal your beast for 15-25% Max HP, and Reward / Soul Bond keep it healthy.',
        scale = 'Your Guardian Beast spawns at 100% of your level with +14-26% Max HP, -30% damage taken and 100% immunity to mob AoE/conal collateral.',
        live  = function(c)
            if num(c.kv, 'pet_alive') <= 0 then return 'No Guardian Beast active.' end
            return ('Guardian Beast is at %d%% HP.'):format(math.floor(num(c.kv, 'pet_hpp')))
        end,
        nxt   = function(c)
            if num(c.kv, 'pet_alive') <= 0 then return 'Summon your Guardian Beast to enable 50% Soul-Link mitigation.' end
            return 'Keep your beast above 15% HP so Symbiotic Soul-Link never drops.'
        end,
    },
}

E.adventurer = {
    pips = {
        core  = 'Build: dual-wield Dagger or Sword melee hits build Adventurer\'s Cadence (up to 5 stacks, +2% Crit Rate per stack). Spend: any Dagger or Sword weaponskill consumes all Cadence for a bonus Light/Sonic strike and grants Troubadour\'s Encore (+15% Haste, +10% Crit, +12% WSD).',
        scale = 'Sonic follow-up damage and Lunge & Flourish scale with your CHR, DEX and up to 4 active buff songs (+8-10% per song).',
        live  = function(c)
            local cad = math.floor(num(c.kv, 'cadence'))
            local songs = math.floor(num(c.kv, 'songs'))
            return ('%d/5 Cadence (+%d%% Crit Rate) with %d active buff %s (+%d%% Sonic bonus).'):format(
                cad, cad * 2, songs, plural(songs, 'song', 'songs'), songs * 8)
        end,
        nxt   = function(c)
            local cad = math.floor(num(c.kv, 'cadence'))
            if cad >= 5 then return 'Cadence is full! Fire a Dagger or Sword weaponskill to detonate Sonic damage and trigger Encore.' end
            return ('Land %d more melee hit(s) to reach 5 Cadence.'):format(5 - cad)
        end,
    },
    bar = {
        core  = 'Troubadour\'s Encore triggers for 12s after spending Cadence on a weaponskill (or via the Encore ability), giving +15% Ability Haste, +10% Crit and +12% WSD.',
        scale = 'Keeps your melee tempo fast so you rebuild 5 Cadence before the next weaponskill.',
        live  = function(c)
            local e = num(c.kv, 'encore_rem')
            if e > 0 then return ('Troubadour\'s Encore is active for %s (+15%% Haste, +10%% Crit, +12%% WSD).'):format(secs(e)) end
            local r = num(c.kv, 'cadence_rem')
            if r > 0 then return ('Cadence stacks last %s.'):format(secs(r)) end
            return 'No active Encore or Cadence timer.'
        end,
        nxt   = function(c)
            if num(c.kv, 'encore_rem') > 0 then return 'Keep swinging during Encore to rapidly refill Cadence.' end
            return 'Spend Cadence with a Dagger/Sword weaponskill or press Troubadour\'s Encore.'
        end,
    },
}

E.musician = {
    pips = {
        core  = 'Build: casting Threnodies, Requiems and Elegies deals direct elemental magic damage (capable of Magic Bursting) and builds Musician\'s Resonance (up to 3 stacks, +5 MAB per stack). Spend: Grand Finale consumes Resonance for heavy nuke damage.',
        scale = 'Song nukes scale with your Level, CHR, Singing + Instrument skill and Magic Attack Bonus, and songs cannot be interrupted by melee hits.',
        live  = function(c)
            local r = math.floor(num(c.kv, 'resonance'))
            return ('%d/3 Resonance (+%d Magic Attack Bonus).'):format(r, r * 5)
        end,
        nxt   = function(c)
            local r = math.floor(num(c.kv, 'resonance'))
            if r >= 3 then return 'Resonance is full! Cast Grand Finale or Magic Burst an elemental Threnody.' end
            return ('Cast %d more offensive song(s) (Threnody/Requiem/Elegy) to reach 3 Resonance.'):format(3 - r)
        end,
    },
    bar = {
        core  = 'Lyrical Overdrive boosts your song nuke damage by +30% and Magic Burst multiplier by +25%.',
        scale = 'Works alongside your 3 Resonance stacks for peak Magic Burst windows.',
        live  = function(c)
            local o = num(c.kv, 'overdrive_rem')
            if o > 0 then return ('Lyrical Overdrive active for %s (+30%% song damage, +25%% Magic Burst bonus)!'):format(secs(o)) end
            local r = num(c.kv, 'resonance_rem')
            if r > 0 then return ('Resonance stacks last %s.'):format(secs(r)) end
            return 'Lyrical Overdrive is currently idle.'
        end,
        nxt   = function(c)
            if num(c.kv, 'overdrive_rem') > 0 then return 'Chain elemental Threnodies and Grand Finale while Overdrive is active.' end
            return 'Activate Lyrical Overdrive when a Skillchain Magic Burst window opens.'
        end,
    },
}

E.minstrel = {
    pips = {
        core  = 'Build: maintain Minne (-6% extra Physical Damage Taken), Paeon (+3/5/8/12 extra Regen) and Scherzo (dampens hits >35% Max HP by 45%) without needing to spam-recast buff songs. Spend: cast Lullaby, Elegy, Requiem and Finale for heavy pre-nerf tank threat.',
        scale = 'Defensive song auras stay active as long as the buff song is on you, leaving your cast bar free for high-enmity offensive songs and Dissonant Chord.',
        live  = function(c)
            local m = num(c.kv, 'minne') > 0
            local p = num(c.kv, 'paeon') > 0
            local s = num(c.kv, 'scherzo') > 0
            local h = (m and 1 or 0) + (p and 1 or 0) + (s and 1 or 0)
            return ('%d/3 tank hymns active: Minne=%s, Paeon=%s, Scherzo=%s.'):format(
                h, m and 'ON (-6% PDT)' or 'off', p and 'ON (+Regen)' or 'off', s and 'ON (anti-tankbuster)' or 'off')
        end,
        nxt   = function(c)
            if num(c.kv, 'minne') <= 0 then return 'Sing Knight\'s Minne for -6% bonus Physical Damage Taken.' end
            if num(c.kv, 'paeon') <= 0 then return 'Sing Army\'s Paeon for bonus passive Regen.' end
            if num(c.kv, 'scherzo') <= 0 then return 'Sing Sentinel\'s Scherzo when available to cushion tankbusters.' end
            return 'All 3 defensive hymns active — hold hate with Lullaby, Elegy and Requiem.'
        end,
    },
    bar = {
        core  = 'Iron Aria wraps you in a sonic ward that reduces damage taken and reflects Light damage + threat back at every attacker.',
        scale = 'Reflected damage scales with your VIT and CHR.',
        live  = function(c)
            local a = num(c.kv, 'iron_aria_rem')
            if a > 0 then return ('Iron Aria is reflecting Light damage and threat for %s.'):format(secs(a)) end
            return 'Iron Aria is not currently active.'
        end,
        nxt   = function(c)
            if num(c.kv, 'iron_aria_rem') > 0 then return 'Stay in front while attackers take reflected Light damage.' end
            return 'Press Iron Aria before a multi-hit flurry or tankbuster.'
        end,
    },
}

E.huntsman = {
    pips = {
        core  = 'Build: call a Glacial Tusker (Wild Raaz / Cehuetzi) to enter Tank mode, or a Volcanic Saurian (Stalker Raptor / Gabbrath) to enter Hybrid Pack Support mode. Spend: ranged attacks and weaponskills transfer 100% of your single-target threat to a Tusker, or pulse a 15y Attack/Accuracy aura from a Saurian.',
        scale = '100% ammo recycle and zero ranged distance penalty at Lv10+. Ranged weaponskills heal your active beast for 15-22% Max HP and grant it +250 TP.',
        live  = function(c)
            local pid = math.floor(num(c.kv, 'pet_id'))
            if pid == 1 or pid == 3 then
                return 'Glacial Tusker Mode (Tank): your beast has +40-70% HP, -30% DT and AoE immunity, and receives 100% of your single-target threat + 80% of Cures cast on you.'
            elseif pid == 2 or pid == 4 then
                return 'Volcanic Saurian Mode (Hybrid Support): projects a 15y Primeval Pack aura (+8-20 ACC/RACC & +8-15% ATK/RATK) with -25 Enmity.'
            end
            return 'No Huntsman companion summoned.'
        end,
        nxt   = function(c)
            if num(c.kv, 'pet_id') <= 0 then return 'Call Wild Raaz/Cehuetzi to tank bosses, or Stalker Raptor/Gabbrath for party DPS.' end
            return 'Fire Ranged weaponskills to heal your companion (15-22% HP) and feed it +250 TP.'
        end,
    },
    bar = {
        core  = 'Tracks your active Tusker or Saurian companion\'s HP%. Warden\'s Ration heals your beast every time you land an Archery or Marksmanship weaponskill.',
        scale = 'Cures cast on you while a Tusker is out also forward 80% of the heal (+100% overheal) directly to the Tusker.',
        live  = function(c)
            if num(c.kv, 'pet_id') <= 0 then return 'No companion out.' end
            return ('Companion is at %d%% HP.'):format(math.floor(num(c.kv, 'pet_hpp')))
        end,
        nxt   = function(c)
            if num(c.kv, 'pet_id') <= 0 then return 'Summon a Tusker or Saurian companion.' end
            return 'Use Rimetusk Gore, Saurian Rend and Primeval Takedown on cooldown.'
        end,
    },
}

E.ronin = {
    pips = {
        core  = 'Build: Third Eye and Meditate charge Mind\'s Eye. Spend: each charge counters one melee swing or single-target enemy skill, gaining TP and heavy Enmity.',
        scale = 'You hold threat through counters and Enmity, not weapon damage. Needs a Great Katana equipped.',
        live  = function(c)
            local m = math.floor(num(c.kv, 'minds_eye'))
            if m <= 0 then return 'No Mind\'s Eye charges. Use Third Eye.' end
            return ('%d %s ready: the next %d %s will be countered.'):format(m, plural(m, 'charge', 'charges'), m, plural(m, 'attack', 'attacks'))
        end,
        nxt   = function(c)
            local m = math.floor(num(c.kv, 'minds_eye'))
            if m >= 3 then return 'Mind\'s Eye is full.' end
            return ('Third Eye or Meditate can add %d more %s.'):format(3 - m, plural(3 - m, 'charge', 'charges'))
        end,
    },
    bar = {
        core  = 'Mushin defers part of every hit you take into a Stagger pool that bleeds over time. Tachi weaponskills, Blade Bash and Meditate purify it.',
        scale = 'The pool is a share of the damage you are hit for, so tougher hits defer more. Purifying removes it before it lands.',
        live  = function(c)
            local pool = math.floor(num(c.kv, 'stagger_pool'))
            local ticks = math.floor(num(c.kv, 'stagger_ticks'))
            if pool <= 0 then return 'Steady: no damage is being deferred.' end
            return ('%d damage is deferred and will land over %d %s.'):format(pool, ticks, plural(ticks, 'tick', 'ticks'))
        end,
        nxt   = function(c)
            if num(c.kv, 'stagger_pool') > 0 then return 'Use a Tachi weaponskill, Blade Bash or Meditate to purify it.' end
            return 'Nothing to purify.'
        end,
    },
}

E.imperialarcher = {
    pips = {
        core  = 'Build: Tachi weaponskills grant Drawn Oisoya (empowers your next Archery weaponskill and refunds +125 TP); Archery weaponskills grant Cosmic Brand (empowers your next Tachi weaponskill and Skillchain damage); Oisoya Shot primes both at once.',
        scale = 'Raises Archery to A+ rank with 100% arrow recycle, auto-shoots with your Bow up to 20y outside melee range, and removes point-blank Bow penalties.',
        live  = function(c)
            local o = num(c.kv, 'oisoya_rem')
            local b = num(c.kv, 'cosmic_rem')
            if o > 0 and b > 0 then return ('Both Drawn Oisoya (%s) and Cosmic Brand (%s) are primed!'):format(secs(o), secs(b)) end
            if o > 0 then return ('Drawn Oisoya primed for %s: your next Archery weaponskill hits harder and refunds +125 TP.'):format(secs(o)) end
            if b > 0 then return ('Cosmic Brand primed for %s: your next Tachi weaponskill and Skillchain hit harder.'):format(secs(b)) end
            return 'Neither Drawn Oisoya nor Cosmic Brand is currently primed.'
        end,
        nxt   = function(c)
            if num(c.kv, 'oisoya_rem') > 0 then return 'Fire an Archery weaponskill (Sidewinder, Arching Arrow, Namas Arrow) to cash in Drawn Oisoya.' end
            if num(c.kv, 'cosmic_rem') > 0 then return 'Land a Tachi weaponskill to cash in Cosmic Brand.' end
            return 'Use Oisoya Shot (25s CD) or land a Tachi/Archery weaponskill to start the chain.'
        end,
    },
    bar = {
        core  = 'Tracks the remaining window on Drawn Oisoya (15s), Cosmic Brand (15s) or Hasso.',
        scale = 'Alternating Tachi <-> Archery weaponskills keeps both buffs rolling and chains self-Skillchains with Konzen-ittai and Oisoya Shot.',
        live  = function(c)
            local o = num(c.kv, 'oisoya_rem')
            local b = num(c.kv, 'cosmic_rem')
            if o >= b and o > 0 then return ('Drawn Oisoya window open for %s.'):format(secs(o)) end
            if b > 0 then return ('Cosmic Brand window open for %s.'):format(secs(b)) end
            local h = num(c.kv, 'hasso_rem')
            if h > 0 then return ('Hasso active for %s (works with both Bow and Great Katana).'):format(secs(h)) end
            return 'No active Oisoya or Cosmic Brand timer.'
        end,
        nxt   = function()
            return 'Keep Hasso up and alternate Blade and Bow weaponskills.'
        end,
    },
}

E.warlord = {
    pips = {
        core  = 'Build: Tachi weaponskills, Onimaru Tithe and Meikyo Shisui build Ashura\'s Edge (up to 3 stacks, 20s). Spend: Ashura\'s Edge radiates a 15y party aura (+10/16/24% Subtle Blow, +6/10/15% WSD, +8/14/20 Acc/MAcc, +8/12/16 Regain), and at 3 stacks your swings restore +15 HP & +5 MP to the party.',
        scale = 'Closing a Skillchain triggers Onimaru Blood-Quench (+20-35% SC damage and restores 10% Max HP, 8% Max MP & +250 TP to the party within 15y).',
        live  = function(c)
            local a = math.floor(num(c.kv, 'ashura'))
            if a <= 0 then return 'No Ashura\'s Edge stacks. Use a Tachi weaponskill or Onimaru Tithe.' end
            local sb = (a == 3 and 24) or (a == 2 and 16) or 10
            local wsd = (a == 3 and 15) or (a == 2 and 10) or 6
            return ('%d/3 Ashura\'s Edge: party gains +%d%% Subtle Blow and +%d%% WSD.%s'):format(
                a, sb, wsd, a >= 3 and ' Melee swings are siphoning HP & MP to the party!' or '')
        end,
        nxt   = function(c)
            local a = math.floor(num(c.kv, 'ashura'))
            if a >= 3 then return 'Ashura\'s Edge is maxed! Keep swinging and close Skillchains for Onimaru Blood-Quench.' end
            return ('%d more stack(s) unlocks the 3-stack party HP/MP siphon.'):format(3 - a)
        end,
    },
    bar = {
        core  = 'Hagakure (20s CD) sheathes your blade into Noto stance (15s), turning your next Tachi into an Iaijutsu Draw-Slash (+35-100% Crit, +250-600 TP Bonus, Save TP, Chainbound) that sunders enemy armor (-15% DEF, -10% MDEF, -25 EVA).',
        scale = 'Onimaru Tithe (25s CD) surges the party with +350 TP, +12% WSD and +15% Lifesteal while filling Ashura\'s Edge to 3.',
        live  = function(c)
            local n = num(c.kv, 'noto_rem')
            if n > 0 then return ('Noto Iaijutsu stance primed for %s: your next Tachi will Draw-Slash and sunder armor!'):format(secs(n)) end
            local a = num(c.kv, 'ashura_rem')
            if a > 0 then return ('Ashura\'s Edge party aura lasts %s.'):format(secs(a)) end
            return 'Noto and Ashura\'s Edge are currently idle.'
        end,
        nxt   = function(c)
            if num(c.kv, 'noto_rem') > 0 then return 'Unleash a Tachi weaponskill now to trigger the Iaijutsu Draw-Slash.' end
            return 'Press Hagakure (20s CD) before your next Tachi, or Onimaru Tithe to surge party TP.'
        end,
    },
}

E.kurogane = {
    pips = {
        core  = 'Shinobi — Shadow Commander. Cast Shadow Squadron: Ichi (Lv10, 2 clones) or Ni (Lv37, 3 clones) while engaged to field up to 5 offensive shadows (25-30s lifetime, up to 170 HP at Lv75).',
        scale = '2 distinct living clones landing real hits within 6s build Feint Ready (20s). Sequence different squad commands (False Assault, Mirror Step, Crosscut, Shadow Pin, Thunder Relay, Final Mirage, Shadow Legion, Phantom Assault) through Feint -> Switch -> Cascade.',
        live  = function(c)
            local n   = math.floor(num(c.kv, 'clones'))
            local eng = math.floor(num(c.kv, 'engaged'))
            local ph  = math.floor(num(c.kv, 'phase'))
            local pr  = math.ceil(num(c.kv, 'phase_rem'))
            local fh  = math.floor(num(c.kv, 'feint_hits'))
            local op  = math.ceil(num(c.kv, 'opening_rem'))
            local lc  = type(c.kv.last_cmd) == 'string' and c.kv.last_cmd or ''
            local phaseNames = { [0] = 'Building (' .. fh .. '/2 hits)', [1] = 'Feint Ready (' .. pr .. 's)', [2] = 'Switch Ready (' .. pr .. 's)', [3] = 'Cascade Ready (' .. pr .. 's)' }
            local phStr = phaseNames[ph] or 'Building'
            if lc ~= '' and ph >= 2 then phStr = phStr .. ' [avoid repeating ' .. lc .. ']' end
            if op > 0 then phStr = phStr .. ' | Opening ' .. op .. 's' end
            return ('%d/5 Shadows (%d engaged) | Phase: %s'):format(n, eng, phStr)
        end,
        nxt   = function(c)
            local n  = math.floor(num(c.kv, 'clones'))
            local ph = math.floor(num(c.kv, 'phase'))
            local lc = type(c.kv.last_cmd) == 'string' and c.kv.last_cmd or ''
            if n == 0 then return 'Engage your target and cast Shadow Squadron: Ichi (or Ni at Lv37) to summon clones.' end
            if ph == 3 then
                return lc ~= '' and ('Cascade Ready! Use any squad command other than %s (or Final Mirage at Lv70) to unleash Cascade!'):format(lc)
                    or 'Cascade Ready! Execute a qualifying squad command for a coordinated Cascade strike!'
            end
            if ph == 2 then
                return lc ~= '' and ('Switch Ready! Use a different squad command than %s to advance to Cascade Ready.'):format(lc)
                    or 'Switch Ready! Use a different squad command to advance to Cascade Ready.'
            end
            if ph == 1 then return 'Feint Ready! Cast False Assault, Mirror Step, Crosscut, or another squad command to advance to Switch.' end
            if n < 2 then return 'Summon at least 2 clones so two distinct shadows can land hits within 6s to build Feint.' end
            return 'Let 2 distinct living clones land hits within 6s to build Feint Ready.'
        end,
    },
    bar = {
        core  = 'Displays time remaining on your active tactical phase (Feint / Switch / Cascade, 20s window), or Phantom Assault (8s) / oldest shadow expiry when building.',
        scale = 'Shadow Pin (Lv30) extends active phase time by +4s (cap 20s). Phase resets on target change, disengage, death, zoning, Soul change, or loss of all clones.',
        live  = function(c)
            local ph = math.floor(num(c.kv, 'phase'))
            local pr = num(c.kv, 'phase_rem')
            if ph == 3 and pr > 0 then return ('Cascade Ready for %s: next different command triggers Cascade strike!'):format(secs(pr)) end
            if ph == 2 and pr > 0 then return ('Switch Ready for %s: use a different command to unlock Cascade.'):format(secs(pr)) end
            if ph == 1 and pr > 0 then return ('Feint Ready for %s: use any squad command to advance to Switch.'):format(secs(pr)) end
            local pa = num(c.kv, 'phantom_rem')
            if pa > 0 then return ('Phantom Assault active for %s: living shadows strike 33%% faster.'):format(secs(pa)) end
            local ex = num(c.kv, 'clone_exp')
            if ex > 0 then return ('Building Feint (%d/2 hits). Next shadow expires in %s.'):format(math.floor(num(c.kv, 'feint_hits')), secs(ex)) end
            return 'No active shadows.'
        end,
        nxt   = function(c)
            local ph = math.floor(num(c.kv, 'phase'))
            if ph == 3 then return 'Trigger Cascade before the phase timer expires!' end
            if ph == 2 then return 'Use a different squad command before Switch expires.' end
            if ph == 1 then return 'Use False Assault to set Opening or Crosscut/Mirror Step to advance to Switch.' end
            if num(c.kv, 'clone_exp') > 0 and num(c.kv, 'clone_exp') <= 6 then return 'Refresh Shadow Squadron to keep clone uptime steady.' end
            return 'Summon shadows with Shadow Squadron: Ichi/Ni while engaged.'
        end,
    },
}

E.kagemusha = {
    pips = {
        core  = 'Build: whenever an Utsusemi shadow breaks (or you cast Ninjutsu / Smoke Lotus) you gain Kawarimi Ash (up to 4) and blind the attacker with Shadow Smoke. Spend: Katana weaponskills spend 3 Ash to restore +1 shadow and heal 8-14% Max HP.',
        scale = 'Healing is a share of your Max HP, and your protection comes from keeping shadows up (Ichi gives 3, Ni gives 4, Kage Bunshin adds +3 up to 5). Zero ninja tools needed.',
        live  = function(c)
            local a = math.floor(num(c.kv, 'ash'))
            local sh = math.floor(num(c.kv, 'shadows'))
            if a >= 3 then
                return ('%d/4 Ash (%d active %s): a Katana weaponskill now restores +1 shadow and heals %d%% of your Max HP.'):format(
                    a, sh, plural(sh, 'shadow', 'shadows'), tier(c.lvl, 8, 10, 12, 14))
            end
            return ('%d/4 Ash (%d active %s): need 3 Ash to trigger the weaponskill heal-and-shadow.'):format(
                a, sh, plural(sh, 'shadow', 'shadows'))
        end,
        nxt   = function(c)
            local a = math.floor(num(c.kv, 'ash'))
            if a >= 3 then return 'Spend 3 Ash on your next Katana weaponskill.' end
            return ('%d more Ash unlocks the shadow-and-heal on your Katana weaponskill.'):format(3 - a)
        end,
    },
    bar = {
        core  = 'Tracks Migawari Intercept (Mijin Gakure, 120s CD: 12s ward that negates any hit >30% Max HP, heals 25% HP and spawns 4 shadows) or your Kawarimi Ash timer.',
        scale = 'At 0 shadows while Yonin is up, you automatically gain -18% damage taken and +15% Parry Rate.',
        live  = function(c)
            local m = num(c.kv, 'migawari_rem')
            if m > 0 then return ('Migawari Intercept active for %s: the next tankbuster (>30%% Max HP) is completely negated!'):format(secs(m)) end
            local r = num(c.kv, 'ash_rem')
            if r > 0 then return ('Your Kawarimi Ash fades in %s.'):format(secs(r)) end
            return 'No Ash banked.'
        end,
        nxt   = function(c)
            if num(c.kv, 'migawari_rem') > 0 then return 'Hold the boss — Migawari will catch the next heavy hit.' end
            if num(c.kv, 'ash_rem') > 0 then return 'Use a Katana weaponskill before Ash fades.' end
            return 'Keep Utsusemi shadows and Yonin active.'
        end,
    },
}

E.wyvernheart = {
    pips = {
        core  = 'Build: Polearm weaponskills, Jumps and Spirit Link add Wyrmscale (up to 3). Spend: Restoring Breath or Wyrmblood Pulse spends your stacks to heal the whole party and wrap them in Dragonscale Stoneskin.',
        scale = 'Healing is a share of your Max HP, boosted by VIT/MND, not weapon damage. Your wyvern separately tops up the lowest-HP ally on every Polearm weaponskill.',
        live  = function(c)
            local n = math.floor(num(c.kv, 'wyrmscale'))
            local wHpp = math.floor(num(c.kv, 'wyvern_hpp'))
            local wTxt = wHpp > 0 and (' Wyvern is at %d%% HP.'):format(wHpp) or ' Call Wyvern is ready (15s CD).'
            return ('%d/3 Wyrmscale: Restoring Breath heals the party for about %d%% of your Max HP%s.%s'):format(
                n, tier(c.lvl, 14, 20, 26, 32), n >= 3 and ' + Stoneskin' or '', wTxt)
        end,
        nxt   = function(c)
            local n = math.floor(num(c.kv, 'wyrmscale'))
            if n >= 3 then return 'Wyrmscale is full. Spend it with Restoring Breath or Wyrmblood Pulse for the Stoneskin bonus.' end
            return ('Reach 3 Wyrmscale (%d more via Jump, Spirit Link or Polearm WS) for the Stoneskin bonus.'):format(3 - n)
        end,
    },
    bar = {
        core  = 'Dragonscale Sanctuary grants the party -15% damage taken and Knockback Immunity for 12s.',
        scale = 'While Wyrmscale is banked, the bar tracks its 30s expiry timer.',
        live  = function(c)
            local s = num(c.kv, 'sanct_rem')
            if s > 0 then return ('Dragonscale Sanctuary active for %s (-15%% party DT, Knockback Immune).'):format(secs(s)) end
            local r = num(c.kv, 'wyrmscale_rem')
            if r > 0 then return ('Wyrmscale stacks fade in %s.'):format(secs(r)) end
            return 'No active Sanctuary or Wyrmscale timer.'
        end,
        nxt   = function(c)
            if num(c.kv, 'wyrmscale') >= 3 then return 'Trigger Restoring Breath or Wyrmblood Pulse before Wyrmscale expires.' end
            return 'Weave Jump (mends 2 allies), High Jump (party cleanse + Stoneskin) and Polearm WSs.'
        end,
    },
}

E.celestial = {
    pips = {
        core  = 'Build: keep any Avatar summoned (0 perpetuation cost) to project a 15y Celestial Sanctuary aura (Regen, +4-10/t Refresh, -10% DT). Spend: Blood Pact: Ward (flat 12s CD; 6s in Apogee; 5s in Astral Flow) and Staff/Club weaponskills trigger Starlight Mend (15% Max HP party heal + 50% Avatar heal).',
        scale = 'Elemental Siphon (20s CD) restores 45% Max MP without dismissing your Avatar and pulses a 20% party heal.',
        live  = function(c)
            if num(c.kv, 'avatar') <= 0 then return 'No Avatar summoned. Summon an Avatar to activate the 15y Celestial Sanctuary aura.' end
            return ('Avatar active (%d%% HP): projecting Celestial Sanctuary (Regen + Refresh + -10%% DT) to all allies within 15y.'):format(
                math.floor(num(c.kv, 'avatar_hpp')))
        end,
        nxt   = function(c)
            if num(c.kv, 'avatar') <= 0 then return 'Summon an Avatar immediately (perpetuation cost is -100%).' end
            return 'Use Blood Pact: Ward every 12s and weave Staff/Club weaponskills for Starlight Mend pulses.'
        end,
    },
    bar = {
        core  = 'Celestial Convergence (25s CD) grants the party -18% damage taken, +30 Magic Evasion and +10% Max MP restored on every Ward or weaponskill for 12s.',
        scale = 'When Convergence is idle, the bar monitors your Avatar conduit\'s HP%.',
        live  = function(c)
            local cv = num(c.kv, 'conv_rem')
            if cv > 0 then return ('Celestial Convergence active for %s (-18%% party DT, +30 MEVA, +10%% MP per Ward/WS).'):format(secs(cv)) end
            if num(c.kv, 'avatar') > 0 then return ('Avatar Conduit HP: %d%%.'):format(math.floor(num(c.kv, 'avatar_hpp'))) end
            return 'No Avatar active.'
        end,
        nxt   = function(c)
            if num(c.kv, 'conv_rem') > 0 then return 'Cast a Blood Pact: Ward or Staff/Club WS during Convergence to restore +10% party MP.' end
            return 'Use Astral Benediction (32% AoE heal + 3-cleanse + Reraise III) or Celestial Convergence as needed.'
        end,
    },
}

E.magus = {
    pips = {
        core  = 'Build: dual-wield hits add Azure Catalyst. Spend: at 5 stacks, or on a Sword/Club weaponskill, an Azure Mending Wave heals the whole party.',
        scale = 'You heal through melee tempo: the wave scales with your Max HP and healing potency, and you draw little threat.',
        live  = function(c)
            local n = math.floor(first(c.kv, 'catalyst', 'catalyst_stacks'))
            local pct = tier(c.lvl, 12, 16, 20, 24)
            local s = ('%d/5 Catalyst: the next Mending Wave heals the party for about %d%% of your Max HP and restores some MP.'):format(n, pct)
            if n >= 5 then s = s .. ' It fires on your next hit.' end
            return s
        end,
        nxt   = function(c)
            local n = math.floor(first(c.kv, 'catalyst', 'catalyst_stacks'))
            if n >= 5 then return 'Catalyst is full. Keep swinging to release the wave.' end
            return ('%d more dual-wield %s will release a Mending Wave.'):format(5 - n, plural(5 - n, 'hit', 'hits'))
        end,
    },
    bar = {
        core  = 'Osmotic Conduit links your blades to the party so your swings feed them HP and MP.',
        scale = 'The siphon is a share of your Max HP and MP per swing, so more swings means more healing.',
        live  = function(c)
            local r = num(c.kv, 'conduit_rem')
            if r > 0 then return ('Conduit is up for %s: each swing siphons HP and MP to the party and you take less magic damage.'):format(secs(r)) end
            return 'Conduit is not active.'
        end,
        nxt   = function(c)
            if num(c.kv, 'conduit_rem') > 0 then return 'Keep attacking while it lasts.' end
            return 'Use Osmotic Conduit when the party needs sustain.'
        end,
    },
}

E.azurebastion = {
    pips = {
        core  = 'Build: physical Blue Magic such as Head Butt and Sudden Lunge grants Chitin Carapace. Spend: the stacks harden you passively, and at 3 or more your defensive spells get stronger.',
        scale = 'Protection scales off Max HP and VIT, and the physical spells you build with also generate heavy threat.',
        live  = function(c)
            local n = math.floor(first(c.kv, 'carapace', 'chitin_stacks'))
            if n <= 0 then return 'No Carapace. Cast a physical Blue Magic spell to start.' end
            local s = ('%d Carapace: about %d%% more defense and %d%% less damage taken.'):format(n, 4 * n, 3 * n)
            if n >= 3 then s = s .. ' Your defensive spells are also stronger.' end
            return s
        end,
        nxt   = function(c)
            local n = math.floor(first(c.kv, 'carapace', 'chitin_stacks'))
            if n >= 5 then return 'Carapace is full. Keep casting to hold it before it fades.' end
            if n < 3 then return ('Reach 3 Carapace (%d more) to power up your defensive spells.'):format(3 - n) end
            return 'Each extra stack adds more defense and damage reduction, up to 5.'
        end,
    },
    bar = {
        core  = 'Diamond Shell is a protective ward you keep up while tanking.',
        scale = 'It leans on your Max HP and defense to keep damage off you.',
        live  = function(c)
            local r = num(c.kv, 'shell_rem')
            if r > 0 then return ('Diamond Shell is protecting you for %s.'):format(secs(r)) end
            return 'Diamond Shell is not active.'
        end,
        nxt   = function(c)
            if num(c.kv, 'shell_rem') > 0 then return 'Refresh it before it ends if the fight continues.' end
            return 'Recast it before a big hit comes.'
        end,
    },
}

E.flintlock = {
    pips = {
        core  = 'Build: Phantom Roll chambers Deadeye (+15/20/25/30% WSD & +15% Ranged Crit DMG for 30s), Quick Draw plants a Powder Mark (10s) on your target, and Hair Trigger adds +30% Snapshot & +25% WSD. Spend: any Marksmanship weaponskill detonates Powder Mark for bonus elemental damage and refunds +150 TP.',
        scale = 'Pure damage Gun Corsair with 100% Bullet/Card recycle and zero self-healing. Broadside Salvo (22s CD) deals 2.0-3.2x ranged damage, grants +250 TP and refunds +1 Quick Draw charge.',
        live  = function(c)
            local ch = num(c.kv, 'chamber_rem')
            local wsd = math.floor(num(c.kv, 'chamber_wsd'))
            local mk = num(c.kv, 'mark_rem')
            local hr = num(c.kv, 'hair_rem')
            return ('Deadeye Chamber: %s | Hair Trigger: %s | Target Powder Mark: %s.'):format(
                ch > 0 and ('+' .. wsd .. '% WSD (' .. secs(ch) .. ')') or 'off',
                hr > 0 and secs(hr) or 'off',
                mk > 0 and secs(mk) or 'none')
        end,
        nxt   = function(c)
            if num(c.kv, 'chamber_rem') <= 0 then return 'Press Phantom Roll (15s CD) to load Deadeye Chamber (+15-30% WSD).' end
            if num(c.kv, 'mark_rem') <= 0 then return 'Fire an Elemental Shot (Quick Draw) to plant a Powder Mark before your weaponskill.' end
            return 'Target is marked! Fire a Marksmanship weaponskill now to detonate Powder Mark (+150 TP refund).'
        end,
    },
    bar = {
        core  = 'Tracks your active Powder Mark window (10s), Hair Trigger window (10s) or Deadeye Chamber duration (30s).',
        scale = 'Detonating Powder Mark with a Marksmanship weaponskill deals bonus Fire damage based on your Gun DMG + AGI and refunds +150 TP.',
        live  = function(c)
            local mk = num(c.kv, 'mark_rem')
            if mk > 0 then return ('Powder Mark on target for %s — detonate it with a Gun weaponskill!'):format(secs(mk)) end
            local hr = num(c.kv, 'hair_rem')
            if hr > 0 then return ('Hair Trigger active for %s (+30%% Snapshot, +25%% WSD).'):format(secs(hr)) end
            local ch = num(c.kv, 'chamber_rem')
            if ch > 0 then return ('Deadeye Chamber active for %s (+%d%% WSD).'):format(secs(ch), math.floor(num(c.kv, 'chamber_wsd'))) end
            return 'No active Chamber or Powder Mark timer.'
        end,
        nxt   = function(c)
            if num(c.kv, 'mark_rem') > 0 then return 'Use Slug Shot, Leaden Salute or Wildfire before the 10s mark fades.' end
            return 'Keep Deadeye Chamber up and weave Broadside Salvo -> Quick Draw -> Gun WS.'
        end,
    },
}

E.gambler = {
    pips = {
        core  = 'Build: each Phantom Roll you land fills a roll slot (up to 3 at once). Spend: rolls run until they expire, and Lucky or XI rolls trigger Overdrive.',
        scale = 'Roll strength scales with your level, CHR and AGI. It is pure support, so you boost the party instead of dealing damage.',
        live  = function(c)
            local r = math.floor(num(c.kv, 'rolls'))
            local s = ('%d/3 rolls active.'):format(r)
            if num(c.kv, 'overdrive') > 0 then
                s = s .. ' Overdrive is on, so your rolls are working at 150% strength.'
            end
            return s
        end,
        nxt   = function(c)
            local r = math.floor(num(c.kv, 'rolls'))
            if r >= 3 then return 'All three roll slots are in use. Keep them refreshed.' end
            return ('Roll again to fill another slot (%d open).'):format(3 - r)
        end,
    },
    bar = {
        core  = 'Double-Up lets you push a roll for a better result. Pushing too far can bust it, which costs House Debt.',
        scale = 'The roll total decides how strong the buff is. Safe Standing keeps rolls of 8 and 9 from being wasted.',
        live  = function(c)
            local debt = num(c.kv, 'debt_rem')
            if debt > 0 then return ('House Debt for %s: the house is collecting for your last gamble.'):format(secs(debt)) end
            local du = num(c.kv, 'du_rem')
            local tot = math.floor(num(c.kv, 'roll_tot'))
            if du > 0 then return ('Double-Up window open for %s (roll total %d).'):format(secs(du), tot) end
            return 'No Double-Up window open.'
        end,
        nxt   = function(c)
            if num(c.kv, 'debt_rem') > 0 then return 'Wait it out (or press Fold) before gambling again.' end
            if num(c.kv, 'du_rem') > 0 then return 'Double-Up now, or hold if your total is already good.' end
            return 'Roll to open a Double-Up window.'
        end,
    },
}

E.buccaneer = {
    pips = {
        core  = 'Build: Point-Blank Pistol weaponskills and Grapeshot Broadside add Grapeshot. Spend: Quick Draw consumes it into a Salt Spray Stoneskin barrier.',
        scale = 'The barrier is a share of your Max HP. Single-target pistol shots generate threat through Enmity, not raw damage.',
        live  = function(c)
            local g = math.floor(num(c.kv, 'grapeshot'))
            if g <= 0 then return 'No Grapeshot loaded. Land a Point-Blank Pistol weaponskill to build it.' end
            return ('%d Grapeshot: Quick Draw would raise a barrier of about %d%% of your Max HP.'):format(g, g * 6)
        end,
        nxt   = function(c)
            local g = math.floor(num(c.kv, 'grapeshot'))
            if g >= 3 then return 'Grapeshot is full (18% Max HP barrier). Use Quick Draw.' end
            return ('Each Grapeshot adds 6%% more barrier. %d more fills it.'):format(3 - g)
        end,
    },
    bar = {
        core  = 'Salt Spray is the Stoneskin barrier your Quick Draw raised from Grapeshot.',
        scale = 'Its size comes from your Max HP and how much Grapeshot you spent.',
        live  = function(c)
            local ss = num(c.kv, 'saltspray')
            if ss > 0 then return ('Salt Spray will absorb the next %d damage you take.'):format(math.floor(ss)) end
            return 'No barrier up.'
        end,
        nxt   = function() return 'Build Grapeshot, then Quick Draw to raise a new barrier.' end,
    },
}

E.vanguard = {
    pips = {
        core  = 'Build: deploy your Valoredge Automaton (100% Overload immune) and maintain 3 Maneuvers. Spend: H2H weaponskills heal your Valoredge for 18% HP and grant you a 10% Max HP Alloy Plating Stoneskin; Ventriloquy swaps threat and grants -18% DT.',
        scale = 'Valoredge gains +14-28% HP, +14-32% DEF, -35% damage taken, +60-120 Enmity, 100% AoE/conal immunity, and single-target Strobe / Shield Bash / Cannibal Blade AI.',
        live  = function(c)
            local alive = num(c.kv, 'pet_alive') > 0
            local man = math.floor(num(c.kv, 'maneuvers'))
            if not alive then return 'Valoredge Automaton is offline. Use Activate or Deus Ex Automata.' end
            return ('Valoredge active (%d/3 Maneuvers). Repair (25s CD, 0 oil) heals Valoredge 50%% and you 18%%.'):format(man)
        end,
        nxt   = function(c)
            if num(c.kv, 'pet_alive') <= 0 then return 'Activate your Valoredge Automaton.' end
            local man = math.floor(num(c.kv, 'maneuvers'))
            if man < 3 then return ('Put up %d more Maneuver(s) (Fire/Earth/Light recommended).'):format(3 - man) end
            return 'Weave H2H weaponskills and Hydraulic Slam (22s CD stun + armor breach).'
        end,
    },
    bar = {
        core  = 'Clockwork Bulwark (35s CD) links you and your Valoredge for 12s, splitting 50% of damage at a 25% discount while granting -15% DT and Knockback Immunity.',
        scale = 'When Bulwark is idle, the bar monitors your Valoredge Automaton\'s HP%.',
        live  = function(c)
            local b = num(c.kv, 'bulwark_rem')
            if b > 0 then return ('Clockwork Bulwark active for %s (50%% damage split, -15%% DT, Knockback Immune).'):format(secs(b)) end
            if num(c.kv, 'pet_alive') > 0 then return ('Valoredge Automaton is at %d%% HP.'):format(math.floor(num(c.kv, 'pet_hpp'))) end
            return 'Valoredge Automaton is not active.'
        end,
        nxt   = function(c)
            if num(c.kv, 'bulwark_rem') <= 0 then return 'Press Clockwork Bulwark before a heavy boss skill.' end
            return 'Use Repair or a Hand-to-Hand weaponskill if Valoredge HP dips.'
        end,
    },
}

E.pugilist = {
    pips = {
        core  = 'Build: fight alongside your Valoredge or Sharpshot Automaton with 3 Maneuvers active (100% Overload immune). Spend: every H2H weaponskill feeds your Automaton +350 TP and opens an 8s Tandem Opening (+25% Automaton WS damage and +3s Skillchain window).',
        scale = 'Pure damage: both you and your Automaton gain +15/22/30/38% Attack & Ranged Attack, +10/15/20/25% Double Attack / Haste, and +8/12/16/20% Crit Rate.',
        live  = function(c)
            local alive = num(c.kv, 'pet_alive') > 0
            local man = math.floor(num(c.kv, 'maneuvers'))
            if not alive then return 'Automaton is offline. Activate your Valoredge or Sharpshot puppet.' end
            return ('Automaton active (%d/3 Maneuvers). Land an H2H weaponskill to feed +350 Pet TP and trigger Tandem Opening.'):format(man)
        end,
        nxt   = function(c)
            if num(c.kv, 'pet_alive') <= 0 then return 'Activate your Automaton immediately.' end
            return 'Use Tandem Barrage (25s CD: +300 TP to both & -15% target DEF) to chain instant pet weaponskills.'
        end,
    },
    bar = {
        core  = 'Tracks your 8s Tandem Opening window after an H2H weaponskill, your 12s Limiter Release burst window (+22% ATK/RATK, +15% DA), or Automaton HP%.',
        scale = 'Overdrive grants +50 Store TP to your Automaton and 0s Maneuver cooldowns.',
        live  = function(c)
            local op = num(c.kv, 'opening_rem')
            if op > 0 then return ('Tandem Opening active on target for %s (+25%% Automaton WS damage, +3s Skillchain window)!'):format(secs(op)) end
            local lr = num(c.kv, 'limiter_rem')
            if lr > 0 then return ('Limiter Release active for %s (+22%% ATK/RATK, +15%% Double Attack/Rapid Shot).'):format(secs(lr)) end
            if num(c.kv, 'pet_alive') > 0 then return ('Tandem Automaton is at %d%% HP.'):format(math.floor(num(c.kv, 'pet_hpp'))) end
            return 'No active Tandem Opening window.'
        end,
        nxt   = function(c)
            if num(c.kv, 'opening_rem') > 0 then return 'Your Automaton will close the Skillchain with +25% bonus WS damage!' end
            return 'Land a Hand-to-Hand weaponskill to open the next Tandem window.'
        end,
    },
}

E.animist = {
    pips = {
        core  = 'Build: Hand-to-Hand weaponskills add Soulspark (Aether Cells, up to 3), restore 10% Automaton MP and shave 4s off Automaton spell recasts. Spend: Aether Overhaul consumes all cells for a massive party heal + cleanse, while Light, Water and Earth Maneuvers trigger direct heals, Regen mist and Stoneskin.',
        scale = 'Your Stormwaker / Soulsoother Automaton is imbued with full White Magic (Cure I-V, -na spells, Erase, Haste, Protect/Shell IV) and stays safely at 12y backline range.',
        live  = function(c)
            local s = math.floor(first(c.kv, 'soulspark', 'cells'))
            local alive = num(c.kv, 'pet_alive') > 0
            if not alive then return ('%d/3 Soulspark cells banked (Automaton offline).'):format(s) end
            return ('%d/3 Soulspark cells. Medical Automaton is at %d%% HP / %d%% MP.'):format(
                s, math.floor(num(c.kv, 'pet_hpp')), math.floor(num(c.kv, 'pet_mpp')))
        end,
        nxt   = function(c)
            local s = math.floor(first(c.kv, 'soulspark', 'cells'))
            if s >= 3 then return 'Soulspark is full (3/3)! Use Aether Overhaul or an H2H weaponskill for a supercharged party heal.' end
            return ('Land %d more H2H weaponskill(s) to reach 3 Soulspark cells.'):format(3 - s)
        end,
    },
    bar = {
        core  = 'Monitors Clockwork Aegis (12s party -15% damage taken + Magic Evasion) or your Medical Automaton\'s MP pool.',
        scale = 'Water Maneuver pulses a 12y Regen mist around your Automaton every 3s and restores 12% of its MP on use.',
        live  = function(c)
            local a = num(c.kv, 'aegis_rem')
            if a > 0 then return ('Clockwork Aegis protecting the party for %s (-15%% DT).'):format(secs(a)) end
            if num(c.kv, 'pet_alive') > 0 then
                return ('Medical Automaton: %d%% HP, %d%% MP.'):format(math.floor(num(c.kv, 'pet_hpp')), math.floor(num(c.kv, 'pet_mpp')))
            end
            return 'Medical Automaton is not active.'
        end,
        nxt   = function(c)
            if num(c.kv, 'pet_alive') <= 0 then return 'Activate your Automaton to start backline White Magic and Maneuver pulses.' end
            return 'Rotate Light Maneuver (spot heal), Water Maneuver (MP + Regen mist + cleanse) and Earth Maneuver (Stoneskin).'
        end,
    },
}

E.bladewheel = {
    pips = {
        core  = 'Build: Steps (working up to 20y at range) build Finishing Moves (up to 5), while Throwing Stance toggles full-time ranged Chakram auto-attacks at all distances. Spend: spend Finishing Moves on ranged Flourishes and unleash 12 custom Chakram Throwing weaponskills.',
        scale = 'Drain, Aspir and Haste Samba proc on ranged Chakram throws, and high-tier Chakram weaponskills grant Chakram Aftermath.',
        live  = function(c)
            local st = num(c.kv, 'throw_stance') > 0
            local fm = math.floor(num(c.kv, 'fm'))
            return ('%d/5 Finishing Moves. Throwing Stance is %s.'):format(
                fm, st and 'ON (throws chakram at all ranges)' or 'AUTO (melee close, throws chakram at range)')
        end,
        nxt   = function(c)
            local fm = math.floor(num(c.kv, 'fm'))
            if fm < 2 then return 'Use Quickstep, Box Step or Stutter Step (up to 20y) to build Finishing Moves.' end
            return 'Spend Finishing Moves on Building/Wild/Climactic Flourish before a Chakram weaponskill.'
        end,
    },
    bar = {
        core  = 'Tracks your active Chakram Aftermath duration from signature Bladewheel Throwing weaponskills.',
        scale = 'Scales with Ranged Accuracy, Ranged Attack, Throwing skill, AGI and CHR.',
        live  = function(c)
            local am = num(c.kv, 'am_rem')
            if am > 0 then return ('Chakram Aftermath active for %s.'):format(secs(am)) end
            return 'No Chakram Aftermath currently active.'
        end,
        nxt   = function()
            return 'Build 1000+ TP with ranged Chakram throws and fire a Throwing weaponskill.'
        end,
    },
}

E.vampire = {
    pips = {
        core  = 'Build: Steps grant +2 Finishing Moves and an instant 10% Max HP party heal; Nocturne Feast drains 15% enemy HP into party HP, +250 party TP and 5 FMs. Spend: any Dagger or Throwing weaponskill consumes up to 5 FMs for a 6%-per-FM party heal (up to 30% Max HP) + party debuff cleanse.',
        scale = 'Crimson Drain Samba passively heals the party within 15y for 18/24/30/36% of all physical damage you deal (doubled during Trance), turning overheal into a 20% Max HP Stoneskin.',
        live  = function(c)
            local fm = math.floor(num(c.kv, 'fm'))
            local tr = num(c.kv, 'trance_rem')
            if tr > 0 then return ('Trance active (%s): Waltzes cost 0 TP, FMs are infinite (5/5), and Drain Samba lifesteal is doubled!'):format(secs(tr)) end
            return ('%d/5 Finishing Moves: a Dagger or Throwing weaponskill now heals the party for %d%% Max HP + cleanses.'):format(fm, fm * 6)
        end,
        nxt   = function(c)
            local fm = math.floor(num(c.kv, 'fm'))
            if fm >= 5 then return 'Finishing Moves are full (30% party heal ready)! Land a Dagger or Throwing weaponskill.' end
            return ('Use a Step (+2 FM + 10%% party heal) or Nocturne Feast (+5 FM) to fill the gauge.'):format()
        end,
    },
    bar = {
        core  = 'Sanguine Waltz (18s CD, 200 TP) heals the party for 30% Max HP, cleanses 2 debuffs and applies Sanguine Waltz Regen. Contradance (15s CD) doubles your next Waltz and grants the party Crimson Veil (-15% damage taken for 10s).',
        scale = 'Zero MP healer: all healing runs on melee damage, TP and Finishing Moves.',
        live  = function(c)
            local s = num(c.kv, 'sanguine_rem')
            if s > 0 then return ('Sanguine Waltz Regen active for %s.'):format(secs(s)) end
            local v = num(c.kv, 'veil_rem')
            if v > 0 then return ('Crimson Veil (-15%% party damage taken) active for %s.'):format(secs(v)) end
            local t = math.max(num(c.kv, 'trance_rem'), num(c.kv, 'contra_rem'))
            if t > 0 then return ('Dance buff window active for %s.'):format(secs(t)) end
            return 'Crimson Drain Samba is active on every melee and ranged hit.'
        end,
        nxt   = function(c)
            if num(c.kv, 'contra_rem') > 0 then return 'Cast any Waltz now to trigger Crimson Veil (-15% party DT for 10s).' end
            return 'Weave Contradance (15s CD), Sanguine Waltz (18s CD) and Nocturne Feast (25s CD).'
        end,
    },
}

E.miragesentinel = {
    pips = {
        core  = 'Build: Steps and Dagger weaponskills add Finishing Moves. Spend: Flourishes turn them into a Stoneskin barrier and a cleanse.',
        scale = 'Barriers are a share of your Max HP per Finishing Move. Steps draw threat, and VIT/DEX keep you standing.',
        live  = function(c)
            local fm = math.floor(num(c.kv, 'fm'))
            if fm <= 0 then return 'No Finishing Moves. Land a Step or a Dagger weaponskill.' end
            return ('%d Finishing %s: a Flourish now would shield about %d%% of your Max HP.'):format(fm, plural(fm, 'Move', 'Moves'), 3 * fm)
        end,
        nxt   = function(c)
            local fm = math.floor(num(c.kv, 'fm'))
            if fm >= 5 then return 'Finishing Moves are full. Spend them with a Flourish.' end
            return ('Each Finishing Move adds 3%% more barrier. %d more fills the gauge.'):format(5 - fm)
        end,
    },
    bar = {
        core  = 'Aegis Waltz is the Stoneskin barrier your Flourishes raised.',
        scale = 'Its size comes from your Max HP and how many Finishing Moves you spent.',
        live  = function(c)
            local hp = num(c.kv, 'aegis_hp')
            if hp > 0 then return ('Aegis Waltz will absorb the next %d damage.'):format(math.floor(hp)) end
            return 'No barrier up.'
        end,
        nxt   = function() return 'Build Finishing Moves, then Flourish to raise a new barrier.' end,
    },
}

E.medic = {
    pips = {
        core  = 'Build: activate Light Arts / Addendum: White (2-hour duration) and summon your Eos faerie companion (Call Eos). Spend: Cure and Regen spells automatically project as 10y party AoE without consuming Strategems, while Sublimation charges MP at 2x speed.',
        scale = 'Eos casts percentage-based Eos Regen (789) and party Cures/cleanses alongside you.',
        live  = function(c)
            local eos = num(c.kv, 'eos') > 0
            local arts = math.floor(num(c.kv, 'arts'))
            local aTxt = (arts == 2 and 'Addendum: White active') or (arts == 1 and 'Light Arts active') or 'No Arts active'
            return ('%s | %s.'):format(eos and ('Eos Companion active (' .. math.floor(num(c.kv, 'eos_hpp')) .. '% HP)') or 'Eos not summoned', aTxt)
        end,
        nxt   = function(c)
            if num(c.kv, 'eos') <= 0 then return 'Use Call Eos to summon your healing faerie companion.' end
            if num(c.kv, 'arts') < 2 then return 'Activate Light Arts and Addendum: White.' end
            return 'Cast Cure or Regen to heal the entire party within 10y automatically.'
        end,
    },
    bar = {
        core  = 'Monitors Eos Faerie HP% (or stored Sublimation MP when Eos is not out).',
        scale = 'Sublimation charges twice as fast on Medic and stores up to 50% of your Max HP as MP.',
        live  = function(c)
            local sub = math.floor(num(c.kv, 'subl_state'))
            local mp = math.floor(num(c.kv, 'subl_mp'))
            local subTxt = (sub == 2 and (' Sublimation Complete (%d MP ready to claim)!'):format(mp))
                or (sub == 1 and (' Sublimation charging (%d MP stored).'):format(mp)) or ''
            if num(c.kv, 'eos') > 0 then
                return ('Eos is at %d%% HP.%s'):format(math.floor(num(c.kv, 'eos_hpp')), subTxt)
            end
            return ('Eos unsummoned.%s'):format(subTxt ~= '' and subTxt or ' Activate Sublimation for fast MP recovery.')
        end,
        nxt   = function(c)
            if math.floor(num(c.kv, 'subl_state')) == 2 then return 'Press Sublimation when you need to claim your stored MP pool.' end
            return 'Keep Sublimation charging and let Eos maintain Eos Regen on the party.'
        end,
    },
}

E.sage = {
    pips = {
        core  = 'Build: activate Dark Arts / Addendum: Black (2-hour duration) and summon your Titania faerie companion (Call Titania). Spend: Ebullience is maintained permanently on every Black Magic nuke (+20%+ damage), Helix spells deal 1.5x damage and last 2 hours, and Elemental Magic bypasses 10% of target Magic Evasion.',
        scale = 'Every offensive spell gains +30 bonus Magic Attack and directs Titania to focus your target with elemental and enfeebling magic.',
        live  = function(c)
            local tit = num(c.kv, 'titania') > 0
            local arts = math.floor(num(c.kv, 'arts'))
            local aTxt = (arts == 2 and 'Addendum: Black + Perpetual Ebullience') or (arts == 1 and 'Dark Arts + Perpetual Ebullience') or 'No Arts active'
            return ('%s | %s.'):format(tit and ('Titania Companion active (' .. math.floor(num(c.kv, 'titania_hpp')) .. '% HP)') or 'Titania not summoned', aTxt)
        end,
        nxt   = function(c)
            if num(c.kv, 'titania') <= 0 then return 'Use Call Titania to summon your offensive faerie companion.' end
            if num(c.kv, 'arts') < 2 then return 'Activate Dark Arts and Addendum: Black.' end
            return 'Land a 1.5x Helix DoT and chain Ebullience-boosted elemental nukes.'
        end,
    },
    bar = {
        core  = 'Monitors your Titania Faerie companion\'s HP%.',
        scale = 'Titania automatically engages whichever enemy you cast offensive or enfeebling magic on.',
        live  = function(c)
            if num(c.kv, 'titania') > 0 then return ('Titania is at %d%% HP.'):format(math.floor(num(c.kv, 'titania_hpp'))) end
            return 'Titania is not currently summoned.'
        end,
        nxt   = function(c)
            if num(c.kv, 'titania') <= 0 then return 'Press Call Titania to deploy your faerie.' end
            return 'Cast a Helix or Elemental nuke to mark your target for Titania.'
        end,
    },
}

E.verdant = {
    pips = {
        core  = 'Build: place a Geocolure Luopan (-50% Luopan HP drain) and maintain an Indicolure aura. Spend: every 3s in combat your Luopan pulses Verdant Bloom (6/8/10/12% Max HP party heal, +15 MP, and Barkskin overheal Stoneskin up to 25% Max HP; doubled during Bolster).',
        scale = 'Casting any Indi, Geo or Cure spell — or landing a Club/Staff weaponskill — triggers Nature\'s Surge (heals Luopan to 100% HP, heals party for 16% Max HP and cleanses 1 debuff).',
        live  = function(c)
            local luo = num(c.kv, 'luopan') > 0
            local bol = num(c.kv, 'bolster_rem') > 0
            if not luo then return 'No Luopan active. Cast a Geo- spell to establish your Living Luopan Sanctuary.' end
            return ('Luopan active (%d%% HP): pulsing Verdant Bloom every 3s%s.'):format(
                math.floor(num(c.kv, 'luopan_hpp')), bol and ' at DOUBLE potency (Bolster)!' or '')
        end,
        nxt   = function(c)
            if num(c.kv, 'luopan') <= 0 then return 'Place a Luopan with any Geo- spell.' end
            return 'Cast Cure/Indi/Geo or use a Club/Staff WS to trigger Nature\'s Surge (refills Luopan to 100% HP + 16% party heal).'
        end,
    },
    bar = {
        core  = 'Canopy of the Ancients (25s CD) grants the party -18% damage taken, Knockback Immunity and an extra 10% Max HP party heal on every spell or weaponskill for 12s.',
        scale = 'When Canopy is idle, the bar monitors your Living Luopan\'s HP%. Life Cycle (15s CD) costs 0 self-HP, refills the Luopan to 100% and heals the party for 25% Max HP.',
        live  = function(c)
            local cn = num(c.kv, 'canopy_rem')
            if cn > 0 then return ('Canopy of the Ancients active for %s (-18%% party DT, Knockback Immune, +10%% AoE heal per spell/WS).'):format(secs(cn)) end
            if num(c.kv, 'luopan') > 0 then return ('Living Luopan is at %d%% HP.'):format(math.floor(num(c.kv, 'luopan_hpp'))) end
            return 'No Luopan placed.'
        end,
        nxt   = function(c)
            if num(c.kv, 'canopy_rem') > 0 then return 'Cast spells or Club/Staff WSs during Canopy for bonus 10% party heals.' end
            return 'Use Verdant Renewal (20s CD: 30% AoE heal + 3-cleanse + Regen/Refresh) or Life Cycle (15s CD).'
        end,
    },
}

E.inquisitor = {
    pips = {
        core  = 'Build: harbor 3 Elemental Runes at Lv10+ (Swipe, Lunge, Gambit and Rayke never consume your Runes and add heavy threat). Spend: weave Iron Battuta (Physical Parry stance) and Runic Aegis (Elemental Ward stance), or fuse both with Runic Convergence.',
        scale = 'Parrying triggers Runic Riposte (heals 1.5% Max HP, restores 1% Max MP, grants +50 TP, threat and an elemental counter-slash).',
        live  = function(c)
            local r = math.floor(num(c.kv, 'runes'))
            local st = math.floor(num(c.kv, 'stance'))
            local stTxt = (st == 3 and 'Runic Convergence (Both Stances Fused)')
                or (st == 2 and 'Runic Aegis (-MDT/BDT, +MEVA, Magic Absorb)')
                or (st == 1 and 'Iron Battuta (+Parry, -PDT, +DEF)')
                or 'No Ward Stance'
            return ('%d/3 Runes active. Current stance: %s.'):format(r, stTxt)
        end,
        nxt   = function(c)
            if num(c.kv, 'runes') < 3 then return ('Inscribe %d more Rune(s) to reach 3/3 Runes.'):format(3 - math.floor(num(c.kv, 'runes'))) end
            if num(c.kv, 'stance') <= 0 then return 'Activate Iron Battuta (15s CD) for physical fights or Runic Aegis (15s CD) for magic fights.' end
            return 'Swap stances for Steel Flash (Stoneskin + threat) or Odyllic Pulse (heal + cleanse + threat).'
        end,
    },
    bar = {
        core  = 'Runic Convergence (30s CD) fuses Iron Battuta and Runic Aegis for 10s (-12 to -25% DT, +20 to +50% Parry, +30 to +80 MEVA) and heals 3% Max HP per active Rune.',
        scale = 'Tracks your active Convergence, Iron Battuta or Runic Aegis timer.',
        live  = function(c)
            local cv = num(c.kv, 'converge_rem')
            if cv > 0 then return ('Runic Convergence active for %s (both stances fused)!'):format(secs(cv)) end
            local a = num(c.kv, 'aegis_rem')
            local b = num(c.kv, 'battuta_rem')
            if a >= b and a > 0 then return ('Runic Aegis stance active for %s.'):format(secs(a)) end
            if b > 0 then return ('Iron Battuta stance active for %s.'):format(secs(b)) end
            return 'No active ward stance timer.'
        end,
        nxt   = function(c)
            if num(c.kv, 'converge_rem') <= 0 then return 'Press Runic Convergence (30s CD) before heavy hybrid damage.' end
            return 'Use Swipe, Lunge, Gambit and Rayke freely — Inquisitor never loses Runes!'
        end,
    },
}

E.spellblade = {
    pips = {
        core  = 'Build: Rune Edge strikes on your Great Sword (and Effusion Slash) build Prepared Conduction charges (up to 3) and recover MP. Spend: Runic Bolt and Runic Sever consume the charges to cast faster, cost less MP and hit harder.',
        scale = 'Damage only: your power scales with INT, STR, Great Sword skill, Elemental skill and how many runes you carry (one Rune activation fills all unlocked slots).',
        live  = function(c)
            local p = math.floor(first(c.kv, 'prep_stacks', 'prep'))
            local r = math.floor(num(c.kv, 'runes'))
            if p <= 0 then return ('0/3 Prepared (%d active %s). Land Rune Edge hits or Effusion Slash to build Conduction.'):format(r, plural(r, 'Rune', 'Runes')) end
            return ('%d/3 Prepared (%d %s): Runic Bolt hits +%d%% harder (Sever +%d%%), casts %.1fs faster and costs -%d%% MP.'):format(
                p, r, plural(r, 'Rune', 'Runes'), 10 * p, 12 * p, 0.5 * p, 15 * p)
        end,
        nxt   = function(c)
            if num(c.kv, 'runes') <= 0 then return 'Inscribe a Rune first (one press fills all unlocked Rune slots on Spellblade).' end
            local p = math.floor(first(c.kv, 'prep_stacks', 'prep'))
            if p >= 3 then return 'Prepared is full (3/3). Fire Runic Bolt or Runic Sever!' end
            return ('%d more Prepared charge(s) maximizes your next Runic Bolt or Runic Sever.'):format(3 - p)
        end,
    },
    bar = {
        core  = 'Landing Runic Bolt, Runic Sever or Effusion Slash grants Edgeflare (+25% Rune Edge elemental damage for 12s). Overcharge Runes (30s CD) grants 12s of +MAB, +Attack%, +MB Bonus and 2x Rune Edge damage.',
        scale = 'Creates a tight loop: Melee Rune Edge -> 3 Conduction -> Runic Bolt/Sever -> Edgeflare -> stronger Rune Edge.',
        live  = function(c)
            local oc = num(c.kv, 'overcharge_rem')
            if oc > 0 then return ('Overcharge Runes active for %s (2x Rune Edge damage, +MAB, +Attack%%, +MB Bonus)!'):format(secs(oc)) end
            local ef = num(c.kv, 'edgeflare_rem')
            if ef > 0 then return ('Edgeflare active for %s (+25%% Rune Edge additional damage).'):format(secs(ef)) end
            return 'Edgeflare and Overcharge Runes are currently idle.'
        end,
        nxt   = function(c)
            if num(c.kv, 'edgeflare_rem') <= 0 then return 'Cast Runic Bolt, Runic Sever or Effusion Slash to ignite Edgeflare (+25% Rune Edge).' end
            return 'Keep swinging while Edgeflare is up to build Conduction and MP.'
        end,
    },
}

E.lifebinder = {
    pips = {
        core  = 'Build: harbor 3 Runes at Lv10+ (Lux for +25% heal & Regen, Unda for party cleanse, Tenebrae for MP & party Refresh, Elemental for 25% Stoneskin). Spend: Vivacious Pulse (15s CD) becomes a 12y party AoE heal that triggers every active Rune\'s boon without consuming your Runes.',
        scale = 'Melee hits and weaponskills while holding Runes trigger Runic Lifetap (heals the most injured ally for 2.5-5% HP and restores 1-3% Max MP). Regen I-IV spells project as 10y party AoE with +50% potency and +60s duration.',
        live  = function(c)
            local r = math.floor(num(c.kv, 'runes'))
            if r <= 0 then return 'No Runes inscribed. Inscribe Lux, Unda or Tenebrae to power Vivacious Pulse and Runic Lifetap.' end
            return ('%d/3 Sacred Runes active: melee swings mend the lowest-HP ally and Vivacious Pulse (15s CD) is ready to project Rune boons.'):format(r)
        end,
        nxt   = function(c)
            local r = math.floor(num(c.kv, 'runes'))
            if r < 3 then return ('Inscribe %d more Rune(s) so Vivacious Pulse fires all 3 Rune boons at once.'):format(3 - r) end
            return 'Press Vivacious Pulse every 15s for a party AoE heal + Rune boons.'
        end,
    },
    bar = {
        core  = 'Sanctified Ward (35s CD) heals the party for 10-22% Max HP and projects a 15s Sanctuary (Regen, -8 to -20% DT, +15 to +50 MEVA). Font of Life (20s CD) heals an ally for 22-48% HP, cleanses 2 debuffs and grants -10 to -22% DT + Cure Received.',
        scale = 'One for All (60s CD) also heals the party for 18% of your Max HP, and Valiance (60s CD) adds +15% Cure Received and Fast Cast.',
        live  = function(c)
            local s = num(c.kv, 'sanct_rem')
            if s > 0 then return ('Sanctified Ward party sanctuary active for %s (Regen, -DT, +MEVA).'):format(secs(s)) end
            local f = num(c.kv, 'font_rem')
            if f > 0 then return ('Font of Life ward active for %s (-DT, +Cure Received).'):format(secs(f)) end
            local v = num(c.kv, 'valiance_rem')
            if v > 0 then return ('Valiance party ward active for %s (+15%% Cure Received & Fast Cast).'):format(secs(v)) end
            return 'Sanctified Ward and Font of Life are ready when their cooldowns allow.'
        end,
        nxt   = function(c)
            if num(c.kv, 'sanct_rem') <= 0 then return 'Use Sanctified Ward (35s CD) or Font of Life (20s CD) when the party takes heavy damage.' end
            return 'Stay in melee with 3 Runes up to feed Runic Lifetap mends and MP.'
        end,
    },
}

local KEY_GEM = { pips = true, bar = true }

local function build(def, which, ctx)
    local d = def[which]
    if not d then return nil end
    local lines = {
        L('Core Loop', d.core),
        L('How It Scales', d.scale),
        SEP,
    }
    local okL, live = pcall(d.live, ctx)
    local okN, nxt = pcall(d.nxt, ctx)
    if okL and live then lines[#lines + 1] = L('Right Now', live, GOLD) end
    if okN and nxt and nxt ~= '' then lines[#lines + 1] = L('Next Threshold', nxt, GREEN) end
    return lines
end

function M.element(soulKey, which, ctx)
    local def = E[soulKey]
    if not def or not KEY_GEM[which] then return nil end
    if not def[which] then which = def.pips and 'pips' or 'bar' end
    ctx = ctx or {}
    ctx.kv = ctx.kv or {}
    return build(def, which, ctx)
end

function M.isWired(soulKey)
    return E[soulKey] ~= nil
end

-- ---------------------------------------------------------------------------------------------
-- ox_buffs status icons
-- ---------------------------------------------------------------------------------------------
function M.buff(b, now, fmtTime)
    local e = b.entry
    local title = e and e.name or ('Effect #' .. tostring(b.iconId))
    local lines = {}
    local rem = b.expiresAt and math.max(0, b.expiresAt - now) or nil
    lines[#lines + 1] = { text = rem and ('Remaining: ' .. fmtTime(rem)) or 'Lasts until removed', color = DIM }
    if e and e.tooltip and e.tooltip ~= '' then
        lines[#lines + 1] = { text = e.tooltip }
    else
        lines[#lines + 1] = { text = 'A custom SoulspireXI effect is active.' }
    end
    if e then
        local who
        if e.isDebuff then who = 'Harmful effect.' elseif e.isShared then who = 'Shared with your party.' else who = 'Affects you.' end
        lines[#lines + 1] = { text = who, color = e.isDebuff and WARN or DIM }
    end
    return title, lines
end

return M
