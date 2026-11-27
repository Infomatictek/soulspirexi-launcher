--[[
* SoulspireXI Soul HUD - bespoke mechanics per Soul (~40 implemented Souls).
*
* build(soulKey, kv, def, rt, role) -> { pips = {...}|nil, bar = {...}|nil }
*   pips = { label, cur, max, gem = 'gold|crimson|azure|emerald|violet', glow = bool,
*            right = 'custom right text'|nil, badge = bool (stance/mode pill) }
*   bar  = { key, label, cur, max|nil(peak-tracked), countdown = bool, fmt = 'sec|num|frac|pct',
*            notches = n, warn = bool, idle = 'text', right = 'custom value text'|nil }
* Souls without a BESPOKE entry (~26 unbuilt Souls) return `{}` so they render only the
* Soul Crystal medallion + compact Soul header pill.
--]]

local M = {}

local ROLE_GEM = { tank = 'azure', healer = 'emerald', support = 'violet', damage = 'crimson' }

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

local function pips(label, cur, max, gem, glow, right)
    return {
        label = label,
        cur   = math.max(0, math.min(max, math.floor((tonumber(cur) or 0) + 0.5))),
        max   = max,
        gem   = gem,
        glow  = glow == true,
        right = right,
    }
end

local function badge(label, right, glow)
    return {
        badge = true,
        label = label,
        right = right or '',
        cur   = glow and 1 or 0,
        max   = 1,
        glow  = glow == true,
    }
end

local function timerBar(key, label, remaining, idle, maxDur)
    return {
        key       = key,
        label     = label,
        cur       = remaining,
        max       = maxDur,
        countdown = true,
        fmt       = 'sec',
        idle      = idle or 'Idle',
    }
end

local WAR_STANCE_NAMES = {
    [0] = 'NO STANCE',
    [1] = 'BERSERK',
    [2] = 'DEFENDER',
    [3] = 'AGGRESSOR',
    [4] = 'RETALIATE',
    [5] = 'RESTRAINT',
}

local BST_BEAST_NAMES = {
    [1] = 'CARRIE',
    [2] = 'GALAHAD',
    [3] = 'RAPHIE',
    [4] = 'SIRAVARDE',
}

local PUP_HEAD_NAMES = {
    [1] = 'HARLEQUIN',
    [2] = 'VALOREDGE',
    [3] = 'SHARPSHOT',
    [4] = 'STORMWAKER',
    [5] = 'SOULSOOTH',
    [6] = 'SPIRITREAV',
}

local BESPOKE = {}

-- =============================================================================
-- 1. WAR: commander, berserker, spartan (gladiator)
-- =============================================================================
BESPOKE.commander = function(kv)
    local stCode  = math.floor(num(kv, 'stance'))
    local stName  = WAR_STANCE_NAMES[stCode] or 'NO STANCE'
    local breach  = num(kv, 'breach_rem')
    local warcry  = num(kv, 'warcry_rem')
    local banner  = math.max(warcry, num(kv, 'bulwark_rem'), num(kv, 'cadence_rem'), num(kv, 'regroup_rem'))
    local orders  = first(kv, 'orders')
    if orders == 0 then
        orders = (stCode > 0 and 1 or 0) + (warcry > 0 and 1 or 0) + (banner > 0 and 1 or 0) + (breach > 0 and 1 or 0)
    end
    local bar
    if breach > 0 then
        bar = timerBar('breach', 'Tactical Breach', breach, 'No Mark', 10)
    elseif banner > 0 then
        bar = timerBar('banner', warcry > 0 and 'Warcry Banner' or 'Formation Order', banner, 'Idle', 45)
    else
        bar = timerBar('stance', 'Active Command', num(kv, 'stance_rem'), 'Ready', 180)
    end
    return {
        pips = pips('Orders', orders, 4, 'violet', breach > 0 or warcry > 0, stName),
        bar  = bar,
    }
end

BESPOKE.berserker = function(kv)
    local bRem  = num(kv, 'berserk_rem')
    local aRem  = num(kv, 'aggressor_rem')
    local sRem  = num(kv, 'surge_rem')
    local brRem = math.max(num(kv, 'bloodrage_rem'), num(kv, 'warcry_rem'), num(kv, 'retal_rem'))
    local fury  = first(kv, 'fury')
    if fury == 0 then
        fury = (bRem > 0 and 1 or 0) + (aRem > 0 and 1 or 0) + (sRem > 0 and 1 or 0) + (brRem > 0 and 1 or 0)
    end
    local bar
    if sRem > 0 then
        bar = timerBar('surge', 'Bloodlust Surge', sRem, 'Idle', 10)
    elseif brRem > 0 then
        bar = timerBar('rage', 'Blood Rage', brRem, 'Idle', 45)
    else
        bar = timerBar('berserk', 'Berserk Fury', bRem, 'Ready', 240)
    end
    return {
        pips = pips('Fury', fury, 4, 'crimson', sRem > 0),
        bar  = bar,
    }
end

BESPOKE.spartan = function(kv)
    local brace = math.floor(num(kv, 'brace'))
    local right = brace >= 2 and 'HVY BRACE' or (brace == 1 and 'LGT BRACE' or nil)
    return {
        pips = pips('Grit', num(kv, 'grit'), 5, 'gold', brace > 0, right),
        bar  = timerBar('ward', 'Phalanx Ward', num(kv, 'ward_rem'), 'Idle', 12),
    }
end
BESPOKE.gladiator = BESPOKE.spartan

-- =============================================================================
-- 2. MNK: sensei, blackbelt, chiweaver
-- =============================================================================
BESPOKE.sensei = function(kv)
    local staff    = num(kv, 'staff') > 0
    local csRem    = num(kv, 'counter_rem')
    local dodgeRem = num(kv, 'dodge_rem')
    local focusRem = num(kv, 'focus_rem')
    local pcRem    = math.max(num(kv, 'pcounter_rem'), num(kv, 'inner_rem'))
    local stances  = first(kv, 'stances')
    if stances == 0 then
        stances = (csRem > 0 and 1 or 0) + (dodgeRem > 0 and 1 or 0) + (focusRem > 0 and 1 or 0) + (pcRem > 0 and 1 or 0)
    end
    local bar
    if pcRem > 0 then
        bar = timerBar('pc', num(kv, 'inner_rem') > 0 and 'Inner Strength' or 'Perfect Counter', pcRem, 'Idle', 30)
    elseif dodgeRem > 0 or focusRem > 0 then
        bar = timerBar('df', dodgeRem >= focusRem and 'Dodge Riposte' or 'Focus Guard', math.max(dodgeRem, focusRem), 'Idle', 60)
    else
        bar = timerBar('cs', 'Counterstance', csRem, 'Ready', 300)
    end
    return {
        pips = pips('Kata', stances, 4, 'azure', pcRem > 0, staff and 'STAFF ON' or 'NO STAFF'),
        bar  = bar,
    }
end

BESPOKE.blackbelt = function(kv)
    local focusRem = num(kv, 'focus_rem')
    local footRem  = num(kv, 'footwork_rem')
    local boostRem = num(kv, 'boost_rem')
    local hfRem    = num(kv, 'hf_rem')
    local dodgeRem = num(kv, 'dodge_rem')
    local stances  = first(kv, 'stances')
    if stances == 0 then
        stances = (focusRem > 0 and 1 or 0) + (footRem > 0 and 1 or 0) + (boostRem > 0 and 1 or 0) + (math.max(dodgeRem, hfRem) > 0 and 1 or 0)
    end
    local bar
    if hfRem > 0 then
        bar = timerBar('hf', 'Hundred Fists', hfRem, 'Idle', 45)
    elseif footRem > 0 then
        bar = timerBar('fw', 'Footwork Stance', footRem, 'Idle', 60)
    else
        bar = timerBar('focus', 'Focus / Boost', math.max(focusRem, boostRem, dodgeRem), 'Ready', 60)
    end
    return {
        pips = pips('Forms', stances, 4, 'crimson', hfRem > 0 or boostRem > 0),
        bar  = bar,
    }
end

BESPOKE.chiweaver = function(kv)
    local chi      = first(kv, 'chi_stacks', 'chi')
    local tierPips = (chi >= 100 and 4) or (chi >= 80 and 3) or (chi >= 50 and 2) or (chi >= 25 and 1) or 0
    local hRem     = num(kv, 'harmony_rem')
    local lRem     = num(kv, 'lotus_rem')
    local right    = hRem > 0 and ('HARM ' .. math.ceil(hRem) .. 's')
        or (lRem > 0 and ('LOTUS ' .. math.ceil(lRem) .. 's') or ('CLEANSE x' .. math.min(3, tierPips)))
    return {
        pips = pips('Cleanse', tierPips, 4, 'emerald', chi >= 80, right),
        bar  = { key = 'chi', label = 'Chi Flow', cur = chi, max = 100, fmt = 'frac', idle = '0/100', notches = 4 },
    }
end

-- =============================================================================
-- 3. WHM: bishop
-- =============================================================================
BESPOKE.zealot = function(kv)
    local seal = num(kv, 'seal_rem')
    local recast = num(kv, 'seal_cd')
    local communion = num(kv, 'communion_cd')
    local staff = num(kv, 'staff') > 0
    local status = staff and (communion > 0 and 'COMMUNION WAIT' or 'COMMUNION READY') or 'EQUIP STAFF'
    return {
        pips = pips('Consecration', seal > 0 and 1 or 0, 1, 'gold', seal > 0, status),
        bar = seal > 0 and timerBar('seal', 'Consecration', seal, 'Ready', 20)
            or timerBar('seal_cd', 'Consecration Recast', recast, 'Ready', 90),
    }
end

BESPOKE.valkyrie = function(kv)
    local interrupt = num(kv, 'interrupt_rem')
    local retry = num(kv, 'retry_rem')
    local escort = num(kv, 'escort_cd')
    local status = num(kv, 'polearm') == 0 and 'EQUIP POLEARM'
        or (num(kv, 'wingmate') > 0 and 'WINGMATE SET' or 'SELECT WINGMATE')
    local bar = timerBar('escort_cd', 'Escort Recast', escort, 'Ready', 25)
    if retry > 0 then
        bar = timerBar('escort_open', 'Escorted Retry', retry, 'Idle', 6)
    elseif interrupt > 0 then
        bar = timerBar('escort_interrupt', 'Interrupt Window', interrupt, 'Idle', 6)
    end
    return {
        pips = pips('Escort', interrupt > 0 and escort == 0 and 1 or 0, 1, 'azure', retry > 0, status),
        bar = bar,
    }
end

BESPOKE.bishop = function(kv)
    local grace   = num(kv, 'grace')
    local solace  = math.floor(num(kv, 'solace'))
    local vRem    = num(kv, 'veil_rem')
    local wRem    = num(kv, 'ward_rem')
    local gRem    = num(kv, 'grace_rem')
    local right   = solace == 1 and 'SOLACE ON' or (solace == 2 and 'MISERY ON' or string.format('GRACE %d/3', grace))
    local bar
    if vRem > 0 then
        bar = timerBar('veil', 'Divine Veil', vRem, 'Idle', 15)
    elseif wRem > 0 then
        bar = timerBar('ward', 'Solace Ward', wRem, 'Idle', 8)
    else
        bar = timerBar('grace', 'Sacred Grace', gRem, 'Ready', 30)
    end
    return {
        pips = pips('Grace', grace, 3, 'emerald', grace >= 3, right),
        bar  = bar,
    }
end

-- =============================================================================
-- 4. BLM: necromancer
-- =============================================================================
BESPOKE.astromancer = function(kv)
    local elements = { 'FIRE', 'ICE', 'WIND', 'EARTH', 'THUNDER', 'WATER' }
    local element = elements[num(kv, 'element')] or 'EARTH'
    local recovery = num(kv, 'recovery_cd')
    local saturation = num(kv, 'sat_rem')
    local aether = num(kv, 'aether_cd')
    local status = saturation > 0 and string.format('%s · SAT %ds', element, saturation) or element
    return {
        pips = pips('Ancient Magic', recovery == 0 and 1 or 0, 1, 'azure', recovery == 0 and saturation == 0, status),
        bar = recovery > 0 and timerBar('ancient', 'Ancient Recovery', recovery, 'Ready', 18)
            or timerBar('aether', 'Gather Aether', aether, 'Ready', 90),
    }
end

BESPOKE.channeler = function(kv)
    local link = num(kv, 'link_rem')
    local casting = num(kv, 'casting') > 0
    local recast = num(kv, 'link_cd')
    return {
        pips = pips('Conduit Link', (link > 0 or casting) and 1 or 0, 1, 'azure', casting,
            casting and 'ALLY CASTING' or nil),
        bar = link > 0 and timerBar('conduit', 'Conduit Link', link, 'Idle', 8)
            or timerBar('conduit_cd', 'Conduit Recast', recast, 'Ready', 24),
    }
end

BESPOKE.necromancer = function(kv)
    local mode   = str(kv, 'thrall_mode')
    local role   = str(kv, 'thrall_role')
    local hpp    = num(kv, 'thrall_hpp')
    local mpp    = num(kv, 'thrall_mpp')
    local pact   = num(kv, 'dark_pact') > 0
    local reanim = num(kv, 'reanimate_ready') > 0
    local reRem  = num(kv, 'reanimate_rem')
    local ceCd   = num(kv, 'ce_cd')
    local capCd  = num(kv, 'cap_cd')
    local buffs  = str(kv, 'active_buffs')

    local title, rText
    if mode == 'dullahan' or mode == 'warrior' then
        title = 'DULLAHAN [WARRIOR]'
        rText = buffs ~= '' and buffs or (pact and 'DARK PACT' or 'ACTIVE')
    elseif mode == 'corse' or mode == 'mage' then
        title = string.format('CORSE [MAGE] MP %d%%', mpp)
        rText = buffs ~= '' and buffs or (pact and 'DARK PACT' or 'ACTIVE')
    elseif reanim then
        title = string.format('REANIMATE READY (%ds)', reRem)
        rText = 'CAST REANIMATE'
    else
        title = 'NO UNDEAD'
        rText = ceCd > 0 and string.format('CE %ds', ceCd) or 'RAISE WARRIOR/MAGE'
    end

    local barLabel = 'Undead HP'
    if mode == 'dullahan' or mode == 'warrior' then
        barLabel = capCd > 0 and string.format('Dullahan HP · DM %ds', capCd) or 'Dullahan HP'
    elseif mode == 'corse' or mode == 'mage' then
        barLabel = capCd > 0 and string.format('Corse HP · AA %ds', capCd) or 'Corse HP'
    elseif reanim then
        barLabel = string.format('Reanimate Window (%ds)', reRem)
    end

    return {
        pips = badge(title, rText, role == 'warrior' or role == 'mage' or pact or reanim),
        bar  = {
            key   = 'thrall',
            label = barLabel,
            cur   = reanim and math.min(100, math.floor((reRem / 120) * 100)) or hpp,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
            warn  = (hpp > 0 and hpp < 25) or reanim,
        },
    }
end

-- =============================================================================
-- 5. RDM: crimsonduelist
-- =============================================================================
BESPOKE.scarletweaver = function(kv)
    local form = num(kv, 'form')
    local recovery = num(kv, 'recovery_rem')
    local recast = num(kv, 'switch_cd')
    local aspect = form == 1 and 'YIN · SPELLS' or 'YANG · SWORD'
    return {
        pips = pips('Aspect', form > 0 and 1 or 0, 1, form == 1 and 'azure' or 'crimson',
            recovery == 0, string.format('%s +%d%%', aspect, num(kv,'bonus'))),
        bar = recovery > 0 and timerBar('recover', 'Aspect Recovery', recovery, 'Idle', 2)
            or timerBar('switch', 'Aspect Change', recast, 'Ready', 12),
    }
end

BESPOKE.oathbreaker = function(kv)
    local vow = num(kv, 'vow')
    local retaliation = num(kv, 'retaliate_rem')
    local reckoning = num(kv, 'reckoning_cd')
    local switching = num(kv, 'vow_cd')
    local label = vow == 1 and 'CONDEMN' or (vow == 2 and 'ABSOLVE' or 'CHOOSE VOW')
    local bar = timerBar('reckon', 'Reckoning', reckoning, 'Ready', 18)
    if retaliation > 0 then
        bar = timerBar('retaliate', 'Retaliation', retaliation, 'Idle', 7)
    elseif switching > 0 then
        bar = timerBar('vow', 'Vow Change', switching, 'Ready', 5)
    end
    return { pips = pips('Vow', vow > 0 and 1 or 0, 1, 'crimson', retaliation > 0, label), bar = bar }
end

BESPOKE.phantom = function(kv)
    local guard = num(kv, 'guard_rem')
    local dare = num(kv, 'dare_cd')
    local activeWeapon = num(kv, 'weapon') > 0
    return {
        pips = pips('Evasion Threat', activeWeapon and num(kv, 'evade_cd') == 0 and 1 or 0, 1, 'azure', guard > 0,
            activeWeapon and (guard > 0 and 'GUARD READY' or nil) or 'EQUIP DAGGER OR KATANA'),
        bar = guard > 0 and timerBar('guard', 'Dare Guard', guard, 'Idle', 6)
            or timerBar('dare', "Phantom's Dare", dare, 'Ready', 18),
    }
end

BESPOKE.trickster = function(kv)
    local suppression = num(kv, 'suppress_cd')
    local blamed = num(kv, 'blame_ready') > 0
    local down = num(kv, 'target_down') > 0
    return {
        pips = pips('Suppression', suppression == 0 and 1 or 0, 1, 'azure', blamed,
            blamed and 'ALIGN WITH ALLY' or (down and 'ATTACK DOWN' or nil)),
        bar = suppression > 0 and timerBar('suppress', 'Suppression', suppression, 'Ready', 20)
            or timerBar('blame_cd', 'Pass the Blame', num(kv, 'blame_cd'), 'Ready', 35),
    }
end

BESPOKE.bandit = function(kv)
    local gap = num(kv, 'gap_rem')
    local cooldown = num(kv, 'exploit_cd')
    local exposed = gap > 0 or num(kv, 'exposed') > 0
    return {
        pips = pips('Opportunism', exposed and 1 or 0, 1, 'gold', exposed and cooldown == 0,
            gap > 0 and 'PERSONAL GAP' or (exposed and 'DEFENSE DOWN' or 'NO OPENING')),
        bar = cooldown > 0 and timerBar('exploit', 'Opportunism', cooldown, 'Ready', 12)
            or (gap > 0 and timerBar('gap', 'Personal Gap', gap, 'Idle', 15)
                or timerBar('gap_cd', 'Find the Gap', num(kv, 'gap_cd'), 'Ready', 24)),
    }
end

BESPOKE.royaltactician = function(kv)
    local pending = num(kv, 'pending')
    local duration = num(kv, 'pending_rem')
    local cooldown = num(kv, 'order_cd')
    local label = pending == 1 and 'Advance' or (pending == 2 and 'Recompose' or 'No order')
    if num(kv, 'half') > 0 then label = label .. ' (half)' end
    return {
        pips = pips('Order', pending > 0 and 1 or 0, 1, 'gold', pending > 0 and cooldown == 0, label),
        bar = duration > 0 and timerBar('order', 'Pending Order', duration, 'Idle', 6)
            or timerBar('order_cd', 'Issue Order', cooldown, 'Ready', 18),
    }
end

BESPOKE.crimsonduelist = function(kv)
    local hexes     = num(kv, 'hexes')
    local fencer    = num(kv, 'fencer') > 0
    local flowRem   = num(kv, 'flow_rem')
    local flecheRem = num(kv, 'fleche_rem')
    local right     = flowRem > 0 and 'FLOW!' or (fencer and ('HEX -' .. (hexes * 5) .. '%') or '1H SWORD')
    local bar
    if flowRem > 0 then
        bar = timerBar('flow', 'Crimson Flow', flowRem, 'Idle', 6)
    elseif flecheRem > 0 then
        bar = timerBar('fleche', 'Crimson Fleche', flecheRem, 'Idle', 6)
    else
        bar = { key = 'skin', label = 'Stoneskin', cur = num(kv, 'stoneskin'), fmt = 'num', idle = 'Idle' }
    end
    return {
        pips = pips('Hexes', hexes, 5, 'crimson', flowRem > 0 or hexes >= 5, right),
        bar  = bar,
    }
end

-- =============================================================================
-- 6. PLD: aegistemplar (defender), templar
-- =============================================================================
BESPOKE.aegistemplar = function(kv)
    local zeal  = num(kv, 'zeal')
    local cRem  = num(kv, 'consec_rem')
    local rRem  = num(kv, 'retrib_rem')
    local zRem  = num(kv, 'zeal_rem')
    local bar
    if cRem > 0 then
        bar = timerBar('consec', 'Consecration', cRem, 'Idle', 15)
    elseif rRem > 0 then
        bar = timerBar('retrib', 'Holy Retribution', rRem, 'Idle', 8)
    else
        bar = timerBar('zeal', 'Aegis Zeal', zRem, 'Idle', 30)
    end
    return {
        pips = pips('Zeal', zeal, 5, 'gold', zeal >= 5),
        bar  = bar,
    }
end
BESPOKE.defender = BESPOKE.aegistemplar

BESPOKE.templar = function(kv)
    local aRem   = num(kv, 'aegis_rem')
    local gRem   = num(kv, 'grace_rem')
    local dRem   = num(kv, 'dseal_rem')
    local shield = num(kv, 'shield') > 0
    local right  = aRem > 0 and '2x BEACON' or (shield and '100% SIRD' or 'ACTIVE')
    local bar
    if aRem > 0 then
        bar = timerBar('aegis', "Crusader's Aegis", aRem, 'Idle', 15)
    elseif gRem > 0 then
        bar = timerBar('grace', "Light's Grace", gRem, 'Idle', 10)
    else
        bar = timerBar('dseal', 'Divine Seal', dRem, 'Ready', 60)
    end
    return {
        pips = badge('MAJESTY AURA', right, aRem > 0 or gRem > 0),
        bar  = bar,
    }
end

-- =============================================================================
-- 7. DRK: dreadnought
-- =============================================================================
BESPOKE.reaper = function(kv)
    local recovery = num(kv, 'recovery')
    local rounds = num(kv, 'enemy_rounds')
    local cooldown = num(kv, 'finality_cd')
    local bar = recovery > 0 and timerBar('opening', 'Recovery', recovery, 'Closed', 5)
        or timerBar('finality', 'Finality', cooldown, 'Ready', 16)
    local label = recovery > 0 and (cooldown > 0 and ('FINALITY %ds'):format(math.ceil(cooldown)) or 'FINALITY READY')
        or ('ENEMY ROUNDS %d/6'):format(rounds)
    return { pips = pips('Enemy Rounds', recovery > 0 and 6 or rounds, 6, 'crimson', recovery > 0 and cooldown == 0, label), bar = bar }
end

BESPOKE.scourge = function(kv)
    local names = { 'Withering', 'Ash', 'Famine' }
    local curse = num(kv, 'curse_rem')
    local ward = num(kv, 'ward_rem')
    local cooldown = num(kv, 'curse_cd')
    local rite = num(kv, 'rite_cd')
    local bar = timerBar('curse', 'Curse Recast', cooldown, 'Ready', 12)
    if ward > 0 then
        bar = timerBar('ward', (names[num(kv, 'ward_kind')] or 'Immunity') .. ' Ward', ward, 'Spent', 8)
    elseif curse > 0 then
        bar = timerBar('curse', names[num(kv, 'curse_kind')] or 'Curse', curse, 'Expired', 24)
    end
    local label = (cooldown > 0 and ('CURSE %ds'):format(math.ceil(cooldown)) or 'CURSE READY')
        .. (rite > 0 and ('  RITE %ds'):format(math.ceil(rite)) or '  RITE READY')
    return { pips = pips('Curse', curse > 0 and 1 or 0, 1, 'crimson', ward > 0, label), bar = bar }
end

BESPOKE.dreadnought = function(kv)
    local tithe  = num(kv, 'tithe')
    local reap   = num(kv, 'reap_rem')
    local bRem   = num(kv, 'bastion_rem')
    local cRem   = num(kv, 'carapace_rem')
    local spikes = num(kv, 'spikes_hp')
    local right  = reap > 0 and ('REAP ' .. math.ceil(reap) .. 's') or ('TITHE %d/3'):format(tithe)
    local bar
    if spikes > 0 then
        bar = { key = 'spikes', label = 'Dread Spikes', cur = spikes, fmt = 'num', idle = 'Idle' }
    elseif bRem > 0 or cRem > 0 then
        bar = timerBar('ward', bRem >= cRem and 'Dread Bastion' or 'Blood Carapace', math.max(bRem, cRem), 'Idle', 15)
    else
        bar = timerBar('tithe', reap > 0 and 'Blood Reap' or 'Blood Tithe',
            math.max(reap, num(kv, 'tithe_rem')), 'Idle', 30)
    end
    return {
        pips = pips('Tithe', tithe, 3, 'crimson', tithe >= 3 or reap > 0, right),
        bar  = bar,
    }
end

-- =============================================================================
-- 8. BST: alphawarden
-- =============================================================================
BESPOKE.alphawarden = function(kv)
    local idx   = math.max(1, math.min(4, math.floor(first(kv, 'beast_idx') > 0 and first(kv, 'beast_idx') or 1)))
    local alive = num(kv, 'pet_alive') > 0
    local hpp   = num(kv, 'pet_hpp')
    local link  = num(kv, 'soullink') > 0 or (alive and hpp >= 15)
    local right = link and 'LINK 50%' or (alive and 'LOW HP' or (BST_BEAST_NAMES[idx] or 'BEAST #1'))
    return {
        pips = pips('Beast', idx, 4, 'azure', link, right),
        bar  = {
            key   = 'pet_hp',
            label = (BST_BEAST_NAMES[idx] or 'Guardian') .. ' HP',
            cur   = alive and hpp or 0,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
            warn  = alive and hpp < 25,
        },
    }
end

-- =============================================================================
-- 9. BRD: adventurer, musician, minstrel
-- =============================================================================
BESPOKE.adventurer = function(kv)
    local cad   = num(kv, 'cadence')
    local cRem  = num(kv, 'cadence_rem')
    local eRem  = num(kv, 'encore_rem')
    local songs = num(kv, 'songs')
    local right = ('%d/5 • %dSNG'):format(cad, songs)
    local bar   = eRem > 0
        and timerBar('encore', 'Encore (+15% Haste)', eRem, 'Idle', 12)
        or timerBar('cadence', 'Cadence', cRem, 'Idle', 20)
    return {
        pips = pips('Cadence', cad, 5, 'crimson', eRem > 0 or cad >= 5, right),
        bar  = bar,
    }
end

BESPOKE.musician = function(kv)
    local res   = num(kv, 'resonance')
    local rRem  = num(kv, 'resonance_rem')
    local oRem  = num(kv, 'overdrive_rem')
    local right = oRem > 0 and 'OVERDRIVE!' or ('RES %d/3'):format(res)
    local bar   = oRem > 0
        and timerBar('overdrive', 'Lyrical Overdrive', oRem, 'Idle', 15)
        or timerBar('res', 'Resonance', rRem, 'Idle', 30)
    return {
        pips = pips('Resonance', res, 3, 'violet', oRem > 0 or res >= 3, right),
        bar  = bar,
    }
end

BESPOKE.minstrel = function(kv)
    local minne   = num(kv, 'minne') > 0
    local paeon   = num(kv, 'paeon') > 0
    local scherzo = num(kv, 'scherzo') > 0
    local hymns   = (minne and 1 or 0) + (paeon and 1 or 0) + (scherzo and 1 or 0)
    local parts   = {}
    if minne then parts[#parts + 1] = 'MIN' end
    if paeon then parts[#parts + 1] = 'PAE' end
    if scherzo then parts[#parts + 1] = 'SCH' end
    local right = #parts > 0 and table.concat(parts, '+') or 'NO HYMNS'
    return {
        pips = pips('Hymns', hymns, 3, 'azure', scherzo, right),
        bar  = timerBar('aria', 'Iron Aria', num(kv, 'iron_aria_rem'), 'Ready', 15),
    }
end

-- =============================================================================
-- 10. RNG: huntsman
-- =============================================================================
local HUNTSMAN_PETS = {
    [0] = { 'NO COMPANION', 'CALL BEAST' },
    [1] = { 'WILD RAAZ', 'TANK' },
    [2] = { 'RAPTOR', 'PACK DPS' },
    [3] = { 'CEHUETZI', 'APEX TANK' },
    [4] = { 'GABBRATH', 'APEX DPS' },
}

BESPOKE.sniper = function(kv)
    local aim = num(kv, 'aim_rem')
    local cooldown = num(kv, 'shot_cd')
    local deep = num(kv, 'deep') > 0
    local bar = aim > 0 and timerBar('aim', 'Sightline Aim', aim, 'Fire', deep and 4 or 3)
        or timerBar('shot', 'Sightline Shot', cooldown, 'Ready', 12)
    return {
        pips = pips('Sightline', cooldown == 0 and 1 or 0, 1, 'azure', aim > 0, deep and 'DEEP SIGHT' or 'STEADY SIGHT'),
        bar = bar,
    }
end

BESPOKE.arcanearcher = function(kv)
    local elements = { 'Fire', 'Ice', 'Wind', 'Earth', 'Lightning', 'Water' }
    local selected = elements[num(kv, 'element')] or 'Fire'
    local marked = elements[num(kv, 'mark_element')]
    local mark = num(kv, 'mark_rem')
    local cooldown = num(kv, 'arrow_cd')
    local bar = mark > 0 and timerBar('mark', (marked or 'Elemental') .. ' Mark', mark, 'Expired', 14)
        or timerBar('arrow', 'Attunement Arrow', cooldown, 'Ready', 16)
    local label = selected:upper() .. (cooldown > 0 and ('  ARROW %ds'):format(math.ceil(cooldown)) or '  ARROW READY')
    return { pips = pips('Attunement', mark > 0 and 1 or 0, 1, 'azure', mark > 0, label), bar = bar }
end

BESPOKE.huntsman = function(kv)
    local pid  = math.floor(num(kv, 'pet_id'))
    local hpp  = num(kv, 'pet_hpp')
    local info = HUNTSMAN_PETS[pid] or HUNTSMAN_PETS[0]
    return {
        pips = badge(info[1], info[2], pid > 0),
        bar  = {
            key   = 'pet_hp',
            label = pid > 0 and (info[1] .. ' HP') or 'Companion',
            cur   = pid > 0 and hpp or 0,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
            warn  = pid > 0 and hpp < 25,
        },
    }
end

-- =============================================================================
-- 11. SAM: ronin, imperialarcher, warlord
-- =============================================================================
BESPOKE.ronin = function(kv)
    local ticks = num(kv, 'stagger_ticks')
    return {
        pips = pips("Mind's Eye", num(kv, 'minds_eye'), 3, 'azure', num(kv, 'seigan') > 0),
        bar  = {
            key     = 'stagger',
            label   = ticks > 0 and ('Stagger  x' .. math.floor(ticks)) or 'Stagger',
            cur     = num(kv, 'stagger_pool'),
            fmt     = 'num',
            idle    = 'Steady',
            notches = ticks > 1 and math.min(10, math.floor(ticks)) or 0,
        },
    }
end

BESPOKE.imperialarcher = function(kv)
    local oRem   = num(kv, 'oisoya_rem')
    local cRem   = num(kv, 'cosmic_rem')
    local primes = (oRem > 0 and 1 or 0) + (cRem > 0 and 1 or 0)
    local right  = (oRem > 0 and cRem > 0 and 'BOW + BLADE')
        or (oRem > 0 and 'OISOYA (BOW)')
        or (cRem > 0 and 'BRAND (TACHI)')
        or 'WEAVE WS'
    local bar
    if oRem >= cRem and oRem > 0 then
        bar = timerBar('oisoya', 'Drawn Oisoya', oRem, 'Idle', 15)
    elseif cRem > 0 then
        bar = timerBar('cosmic', 'Cosmic Brand', cRem, 'Idle', 15)
    else
        bar = timerBar('hasso', 'Hasso Stance', num(kv, 'hasso_rem'), 'Ready', 300)
    end
    return {
        pips = pips('Primes', primes, 2, 'violet', primes > 0, right),
        bar  = bar,
    }
end

BESPOKE.warlord = function(kv)
    local ashura = num(kv, 'ashura')
    local aRem   = num(kv, 'ashura_rem')
    local nRem   = num(kv, 'noto_rem')
    local right  = nRem > 0 and ('NOTO ' .. math.ceil(nRem) .. 's') or ('ASHURA %d/3'):format(ashura)
    local bar    = nRem > 0
        and timerBar('noto', 'Noto Sheathe', nRem, 'Idle', 15)
        or timerBar('ashura', "Ashura's Edge", aRem, 'Idle', 20)
    return {
        pips = pips('Ashura', ashura, 3, 'violet', ashura >= 3 or nRem > 0, right),
        bar  = bar,
    }
end

-- =============================================================================
-- 12. NIN: kurogane (Shinobi), kagemusha
-- =============================================================================
BESPOKE.kurogane = function(kv)
    local clones     = num(kv, 'clones')
    local cloneExp   = num(kv, 'clone_exp')
    local phase      = math.floor(num(kv, 'phase'))
    local phaseRem   = num(kv, 'phase_rem')
    local feintHits  = math.floor(num(kv, 'feint_hits'))
    local openRem    = num(kv, 'opening_rem')
    local lastCmd    = type(kv.last_cmd) == 'string' and kv.last_cmd or ''
    local legionCd   = num(kv, 'legion_cd')
    local phantomRem = num(kv, 'phantom_rem')

    local openTag = openRem > 0 and ' • OPEN' or ''
    local diffTag = (lastCmd ~= '' and (phase == 2 or phase == 3)) and (' (!' .. lastCmd .. ')') or ''

    local right
    if clones <= 0 then
        right = 'SUMMON SQUAD'
    elseif phase == 3 then
        right = 'CASCADE RDY' .. diffTag .. openTag
    elseif phase == 2 then
        right = 'SWITCH RDY' .. diffTag .. openTag
    elseif phase == 1 then
        right = 'FEINT RDY' .. openTag
    elseif openRem > 0 then
        right = ('BUILD %d/2 • OPEN %ds'):format(feintHits, math.ceil(openRem))
    elseif phantomRem > 0 then
        right = ('BUILD %d/2 • PA %ds'):format(feintHits, math.ceil(phantomRem))
    else
        right = ('BUILD %d/2'):format(feintHits)
    end

    local bar
    if phase == 3 and phaseRem > 0 then
        bar = timerBar('cascade', 'Cascade Ready', phaseRem, 'Building', 20)
    elseif phase == 2 and phaseRem > 0 then
        bar = timerBar('switch', 'Switch Ready', phaseRem, 'Building', 20)
    elseif phase == 1 and phaseRem > 0 then
        bar = timerBar('feint', 'Feint Ready', phaseRem, 'Building', 20)
    elseif phantomRem > 0 then
        bar = timerBar('phantom', 'Phantom Assault', phantomRem, 'Idle', 8)
    else
        bar = timerBar('clone', 'Next Shadow', cloneExp, 'No Shadows', 30)
    end

    local glow = (phase >= 1 and clones > 0) or phantomRem > 0 or (clones >= 1 and legionCd <= 0)
    return {
        pips = pips('Shadows', clones, 5, 'violet', glow, right),
        bar  = bar,
    }
end

BESPOKE.nightblade = function(kv)
    local tell = num(kv, 'tell')
    local sealed = num(kv, 'sealed') > 0
    local cooldown = num(kv, 'seal_cd')
    local quick = num(kv, 'quick_rem')
    local quickCd = num(kv, 'quick_cd')
    local label = tell == 1 and 'SPELL' or (tell == 2 and 'TECHNIQUE' or 'WATCHING')
    if sealed then label = label .. ' SEALED' end
    if quick > 0 then label = label .. '  QUICK READ' end
    local bar = timerBar('seal', 'Seal Recast', cooldown, 'Ready', 20)
    if quick > 0 then
        bar = timerBar('quick', 'Quick Read', quick, 'Spent', 8)
    elseif cooldown == 0 and quickCd > 0 then
        bar = timerBar('quickRecast', 'Quick Read Recast', quickCd, 'Ready', 45)
    end
    return { pips = pips('Enemy Tell', tell > 0 and 1 or 0, 1, 'azure', tell > 0 and cooldown == 0 and not sealed, label), bar = bar }
end

BESPOKE.kagemusha = function(kv)
    local ash     = num(kv, 'ash')
    local shadows = num(kv, 'shadows')
    local migRem  = num(kv, 'migawari_rem')
    local right   = ('ASH %d/4 • %d SHD'):format(ash, shadows)
    local bar     = migRem > 0
        and timerBar('migawari', 'Migawari Ward', migRem, 'Idle', 12)
        or timerBar('ash', 'Kawarimi Ash', num(kv, 'ash_rem'), '0s', 30)
    return {
        pips = pips('Ash', ash, 4, 'violet', ash >= 3 or migRem > 0, right),
        bar  = bar,
    }
end

-- =============================================================================
-- 13. DRG: wyvernheart
-- =============================================================================
BESPOKE.lancer = function(kv)
    local lane = num(kv, 'lane')
    local followup = num(kv, 'followup')
    local cooldown = num(kv, 'vault_cd')
    local label = lane == 2 and 'LONG LANE' or (lane == 1 and 'SHORT LANE' or 'OUTSIDE VAULT RANGE')
    local bar = followup > 0 and timerBar('followup', 'Piercing Jump Follow-up', followup, 'Expired', 5)
        or timerBar('vault', 'Spineshatter Vault', cooldown, 'Ready', 18)
    return { pips = pips('Launch Lane', lane > 0 and lane <= 2 and lane or 0, 2, 'crimson', followup > 0, label), bar = bar }
end

BESPOKE.skyborn = function(kv)
    local guard = num(kv, 'guard_ms') / 1000
    local ward = num(kv, 'ward_ms') / 1000
    local wardHP = num(kv, 'ward_hp')
    local cooldown = num(kv, 'guard_cd')
    local cry = num(kv, 'cry_cd')
    local bar = timerBar('guard', 'Skyward Guard', cooldown, 'Ready', 20)
    if guard > 0 then
        bar = timerBar('intercept', 'Guard Window', guard, 'Landed', 1.5)
    elseif ward > 0 then
        bar = timerBar('ward', ('Landing Ward (%d HP)'):format(wardHP), ward, 'Expired', 5)
    end
    local label = cry > 0 and ('CRY %ds'):format(math.ceil(cry)) or 'CRY READY'
    return { pips = pips('Guard', guard > 0 and 1 or 0, 1, 'azure', guard > 0, label), bar = bar }
end

BESPOKE.wyvernheart = function(kv)
    local scale = num(kv, 'wyrmscale')
    local rem   = num(kv, 'wyrmscale_rem')
    local sRem  = num(kv, 'sanct_rem')
    local wHpp  = num(kv, 'wyvern_hpp')
    local right = wHpp > 0 and ('WYV ' .. math.floor(wHpp) .. '%') or ('SCALE %d/3'):format(scale)
    local bar   = sRem > 0
        and timerBar('sanct', 'Dragon Sanctuary', sRem, 'Idle', 12)
        or timerBar('wyrm', 'Wyrmscale', rem, 'Idle', 30)
    return {
        pips = pips('Wyrmscale', scale, 3, 'emerald', scale >= 3, right),
        bar  = bar,
    }
end

-- =============================================================================
-- 14. SMN: celestial
-- =============================================================================
BESPOKE.celestial = function(kv)
    local alive = num(kv, 'avatar') > 0
    local hpp   = num(kv, 'avatar_hpp')
    local cRem  = num(kv, 'conv_rem')
    local aRem  = num(kv, 'astral_rem')
    local right = cRem > 0 and ('CONV ' .. math.ceil(cRem) .. 's')
        or (aRem > 0 and 'ASTRAL FLOW' or (alive and 'AURA 15Y' or 'SUMMON'))
    local bar = cRem > 0
        and timerBar('conv', 'Convergence', cRem, 'Idle', 12)
        or {
            key   = 'avatar_hp',
            label = 'Avatar HP',
            cur   = alive and hpp or 0,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
        }
    return {
        pips = badge(alive and 'AVATAR CONDUIT' or 'NO AVATAR', right, alive),
        bar  = bar,
    }
end

-- =============================================================================
-- 15. BLU: magus, azurebastion
-- =============================================================================
BESPOKE.magus = function(kv)
    return {
        pips = pips('Catalyst', first(kv, 'catalyst', 'catalyst_stacks'), 5, 'azure'),
        bar  = timerBar('conduit', 'Osmotic Conduit', num(kv, 'conduit_rem')),
    }
end

BESPOKE.warmage = function(kv)
    local mask = num(kv, 'match')
    local window = num(kv, 'window')
    local cooldown = num(kv, 'assess_cd')
    local labels = {}
    for index, label in ipairs({ 'BLUNT', 'SLASH', 'PIERCE', 'ELEMENTAL' }) do
        if math.floor(mask / (2 ^ (index - 1))) % 2 == 1 then labels[#labels + 1] = label end
    end
    local bar = window > 0 and timerBar('window', 'Assessment', window, 'Expired', 8)
        or timerBar('assess', 'Assess Prey', cooldown, 'Ready', 12)
    local label = #labels > 0 and table.concat(labels, ' / ') or 'ASSESS YOUR TARGET'
    return { pips = pips('Weakness Categories', #labels, 4, 'crimson', window > 0, label), bar = bar }
end

BESPOKE.azurebastion = function(kv)
    return {
        pips = pips('Carapace', first(kv, 'carapace', 'chitin_stacks'), 5, 'azure'),
        bar  = timerBar('shell', 'Diamond Shell', num(kv, 'shell_rem')),
    }
end

-- =============================================================================
-- 16. COR: flintlock, gambler, buccaneer
-- =============================================================================
BESPOKE.flintlock = function(kv)
    local chRem   = num(kv, 'chamber_rem')
    local chWsd   = num(kv, 'chamber_wsd')
    local hairRem = num(kv, 'hair_rem')
    local markRem = num(kv, 'mark_rem')
    local primed  = (chRem > 0 and 1 or 0) + (hairRem > 0 and 1 or 0) + (markRem > 0 and 1 or 0)
    local right   = markRem > 0 and ('MARK ' .. math.ceil(markRem) .. 's')
        or (chWsd > 0 and ('+' .. math.floor(chWsd) .. '% WSD') or 'READY')
    local bar
    if markRem > 0 then
        bar = timerBar('mark', 'Powder Mark', markRem, 'No Mark', 10)
    elseif hairRem > 0 then
        bar = timerBar('hair', 'Hair Trigger', hairRem, 'Idle', 10)
    else
        bar = timerBar('chamber', 'Deadeye Chamber', chRem, 'Idle', 30)
    end
    return {
        pips = pips('Primed', primed, 3, 'crimson', markRem > 0 or hairRem > 0, right),
        bar  = bar,
    }
end

BESPOKE.gambler = function(kv)
    local debt = num(kv, 'debt_rem')
    local bar
    if debt > 0 then
        bar = { key = 'debt', label = 'HOUSE DEBT', cur = debt, max = 12, countdown = true, fmt = 'sec', warn = true }
    else
        local tot = num(kv, 'roll_tot')
        bar = {
            key = 'du', label = tot > 0 and ('Double-Up  ' .. math.floor(tot)) or 'Double-Up',
            cur = num(kv, 'du_rem'), max = 45, countdown = true, fmt = 'sec', idle = 'Idle',
            warn = num(kv, 'roll_lock') > 0,
        }
    end
    return { pips = pips('Rolls', num(kv, 'rolls'), 3, 'gold', num(kv, 'overdrive') > 0), bar = bar }
end

BESPOKE.buccaneer = function(kv)
    return {
        pips = pips('Grapeshot', num(kv, 'grapeshot'), 3, 'crimson'),
        bar  = { key = 'salt', label = 'Salt Spray', cur = num(kv, 'saltspray'), fmt = 'num', idle = 'No Shield' },
    }
end

-- =============================================================================
-- 17. PUP: vanguard, pugilist, animist
-- =============================================================================
BESPOKE.vanguard = function(kv)
    local alive   = num(kv, 'pet_alive') > 0
    local hpp     = num(kv, 'pet_hpp')
    local man     = num(kv, 'maneuvers')
    local bulRem  = num(kv, 'bulwark_rem')
    local odRem   = num(kv, 'overdrive_rem')
    local right   = bulRem > 0 and ('BULWARK ' .. math.ceil(bulRem) .. 's')
        or (odRem > 0 and 'OVERDRIVE!' or (alive and 'VALOREDGE' or 'OFFLINE'))
    local bar = bulRem > 0
        and timerBar('bulwark', 'Clockwork Bulwark', bulRem, 'Idle', 12)
        or {
            key   = 'auto_hp',
            label = 'Valoredge HP',
            cur   = alive and hpp or 0,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
            warn  = alive and hpp < 25,
        }
    return {
        pips = pips('Maneuvers', man, 3, 'azure', bulRem > 0 or odRem > 0, right),
        bar  = bar,
    }
end

BESPOKE.pugilist = function(kv)
    local alive   = num(kv, 'pet_alive') > 0
    local hpp     = num(kv, 'pet_hpp')
    local man     = num(kv, 'maneuvers')
    local openRem = num(kv, 'opening_rem')
    local limRem  = num(kv, 'limiter_rem')
    local head    = PUP_HEAD_NAMES[math.floor(num(kv, 'head'))] or 'AUTOMATON'
    local right   = openRem > 0 and ('TANDEM ' .. math.ceil(openRem) .. 's')
        or (limRem > 0 and ('LIMITER ' .. math.ceil(limRem) .. 's') or head)
    local bar
    if openRem > 0 then
        bar = timerBar('open', 'Tandem Opening', openRem, 'Idle', 8)
    elseif limRem > 0 then
        bar = timerBar('lim', 'Limiter Release', limRem, 'Idle', 12)
    else
        bar = {
            key   = 'auto_hp',
            label = 'Automaton HP',
            cur   = alive and hpp or 0,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
        }
    end
    return {
        pips = pips('Maneuvers', man, 3, 'crimson', openRem > 0 or limRem > 0, right),
        bar  = bar,
    }
end

BESPOKE.animist = function(kv)
    local spark  = first(kv, 'soulspark', 'cells')
    local alive  = num(kv, 'pet_alive') > 0
    local hpp    = num(kv, 'pet_hpp')
    local mpp    = num(kv, 'pet_mpp')
    local aegis  = num(kv, 'aegis_rem')
    local head   = PUP_HEAD_NAMES[math.floor(num(kv, 'head'))] or 'SOULSOOTH'
    local right  = alive and ('%s %d%%'):format(head, math.floor(mpp)) or ('SPARK %d/3'):format(spark)
    local bar    = aegis > 0
        and timerBar('aegis', 'Clockwork Aegis', aegis, 'Idle', 12)
        or {
            key   = 'auto_mp',
            label = alive and ('Auto HP ' .. math.floor(hpp) .. '% • MP') or 'Automaton',
            cur   = alive and mpp or num(kv, 'soulspark_rem'),
            max   = alive and 100 or 30,
            fmt   = alive and 'pct' or 'sec',
            idle  = 'Offline',
        }
    return {
        pips = pips('Soulspark', spark, 3, 'emerald', spark >= 3, right),
        bar  = bar,
    }
end

-- =============================================================================
-- 18. DNC: bladewheel, vampire, miragesentinel
-- =============================================================================
BESPOKE.bladewheel = function(kv)
    local stance = num(kv, 'throw_stance') > 0
    local fm     = num(kv, 'fm')
    local amRem  = num(kv, 'am_rem')
    local right  = stance and 'THROW: ON' or 'THROW: AUTO'
    return {
        pips = pips('FM', fm, 5, 'crimson', stance, right),
        bar  = timerBar('am', 'Chakram Aftermath', amRem, 'Ready', 60),
    }
end

BESPOKE.vampire = function(kv)
    local fm       = num(kv, 'fm')
    local tRem     = num(kv, 'trance_rem')
    local cRem     = num(kv, 'contra_rem')
    local vRem     = num(kv, 'veil_rem')
    local sRem     = num(kv, 'sanguine_rem')
    local right    = tRem > 0 and 'TRANCE' or (cRem > 0 and 'CONTRA' or ('FM %d/5'):format(fm))
    local bar
    if sRem > 0 then
        bar = timerBar('sang', 'Sanguine Waltz', sRem, 'Idle', 15)
    elseif vRem > 0 then
        bar = timerBar('veil', 'Crimson Veil', vRem, 'Idle', 10)
    else
        bar = timerBar('trance', tRem >= cRem and 'Trance' or 'Contradance', math.max(tRem, cRem), 'Drain Active', 30)
    end
    return {
        pips = pips('FM', fm, 5, 'emerald', tRem > 0 or fm >= 5, right),
        bar  = bar,
    }
end

BESPOKE.miragesentinel = function(kv)
    return {
        pips = pips('FM', num(kv, 'fm'), 5, 'gold'),
        bar  = { key = 'aegis', label = 'Aegis Waltz', cur = num(kv, 'aegis_hp'), fmt = 'num', idle = 'No Shield' },
    }
end

-- =============================================================================
-- 19. SCH: medic, sage
-- =============================================================================
BESPOKE.medic = function(kv)
    local eos   = num(kv, 'eos') > 0
    local hpp   = num(kv, 'eos_hpp')
    local arts  = math.floor(num(kv, 'arts'))
    local subl  = math.floor(num(kv, 'subl_state'))
    local subMp = math.floor(num(kv, 'subl_mp'))
    local lText = eos and 'EOS ACTIVE' or 'CALL EOS'
    local rText = (arts == 2 and 'ADD: WHITE') or (arts == 1 and 'LIGHT ARTS') or 'NO ARTS'
    if subl == 2 then
        rText = ('SUBL %dMP'):format(subMp)
    elseif subl == 1 and subMp > 0 then
        rText = ('SUBL %d'):format(subMp)
    end
    return {
        pips = badge(lText, rText, eos or arts == 2),
        bar  = {
            key   = 'eos_hp',
            label = eos and 'Eos Faerie HP' or 'Sublimation MP',
            cur   = eos and hpp or subMp,
            max   = eos and 100 or nil,
            fmt   = eos and 'pct' or 'num',
            idle  = 'Offline',
        },
    }
end

BESPOKE.untamed = function(kv)
    if num(kv, 'pet') == 0 then return { pips = badge('NO PACKMATE', 'CALL PACKMATE', false) } end
    local shared = num(kv, 'shared') == 1
    local petTP = num(kv, 'pet_tp')
    local petCD, masterCD = num(kv, 'to_pet'), num(kv, 'to_master')
    local function linkTime(seconds)
        return seconds > 0 and ('%ds'):format(seconds) or 'Ready'
    end
    return {
        pips = badge(shared and 'SHARED QUARRY' or 'SET QUARRY',
            ('Hare %d TP · You %d TP'):format(petTP, num(kv, 'master_tp')), shared),
        bar = {
            key = 'pack_link', label = 'Feral Synchronization', cur = math.max(petCD, masterCD),
            max = 8, countdown = true, fmt = 'sec', idle = 'Ready',
            right = ('To hare %s · To you %s'):format(linkTime(petCD), linkTime(masterCD)),
        },
    }
end

BESPOKE.beastspeaker = function(kv)
    local family, weakness = str(kv, 'family'), str(kv, 'weakness')
    local pending, exposed = num(kv, 'pending'), num(kv, 'exposed')
    local label = weakness ~= '' and weakness or 'READ QUARRY'
    local detail = family
    if num(kv, 'pet') == 0 then detail = 'CALL TRACKER' end
    local bar
    if exposed > 0 then
        bar = timerBar('exposure', ('Exposure +%d%%'):format(num(kv, 'bonus')), exposed, 'Expired', 10)
    elseif pending > 0 then
        bar = timerBar('tracker', 'Waiting for Tracker', pending, 'Expired', 6)
    elseif str(kv, 'learned') ~= '' then
        label, detail = label .. ' · ' .. family, str(kv, 'learned')
    end
    return { pips = badge(label, detail, exposed > 0), bar = bar }
end

BESPOKE.primalist = function(kv)
    local avatar, choices = str(kv, 'avatar'), str(kv, 'choice')
    local window, cost = num(kv, 'window'), num(kv, 'pact_mp')
    local match = num(kv, 'match') == 1
    local detail = avatar == '' and choices or ('%d MP per pact'):format(cost)
    local bar
    if window > 0 then
        bar = timerBar('challenge', match and 'Aspect Matched' or 'Aspect Resisted', window, 'Expired', 15)
    end
    return { pips = badge(avatar ~= '' and avatar or 'CALL AVATAR', detail, window > 0 and match), bar = bar }
end

BESPOKE.herald = function(kv)
    local avatar = str(kv, 'avatar')
    local element = str(kv, 'element')
    local remaining = num(kv, 'window')
    local open, total = num(kv, 'ready'), num(kv, 'total')
    if remaining == 0 then
        return { pips = badge(avatar == '' and 'INVITE ENVOY' or avatar, ('Accord %d MP'):format(num(kv, 'mp')), false) }
    end
    return {
        pips = pips('Open Claims', open, math.max(1, total), 'violet', open > 0, avatar),
        bar = timerBar('accord', ('%s Accord +%d%%'):format(element, num(kv, 'pct')), remaining, 'Expired', 10),
    }
end

BESPOKE.terramancer = function(kv)
    local fuse, cooldown = num(kv, 'fuse'), num(kv, 'cooldown')
    local inside = num(kv, 'inside') == 1
    if fuse > 0 then
        local kind, quarry = str(kv, 'kind'), str(kv, 'quarry')
        return {
            pips = badge(kind, quarry ~= '' and quarry or 'CLAIM LOST', inside),
            bar = timerBar('fault_fuse', inside and 'Quarry Inside' or 'Quarry Outside', fuse, 'Erupted', kind == 'Deep Fault' and 4 or 2),
        }
    end
    return { bar = timerBar('fault_cd', 'Fault Recast', cooldown, 'Ready', 8) }
end

BESPOKE.diviner = function(kv)
    local duration = num(kv, 'duration')
    if duration == 0 then return { pips = badge('NO MERIDIAN', 'LAY MERIDIAN', false) } end
    local length = num(kv, 'length') / 10
    local live = num(kv, 'live') == 1
    local label
    if live then label = ('%d Covered · +%d ACC/MACC'):format(num(kv, 'count'), num(kv, 'bonus'))
    elseif num(kv, 'floor') == 0 then label = 'Return to Anchor Floor'
    elseif length < 3 then label = 'Move Away from Anchor'
    else label = 'Move Closer to Anchor' end
    return {
        pips = badge(label, ('%.1fy'):format(length), live),
        bar = timerBar('meridian_duration', 'Meridian', duration, 'Expired', num(kv, 'max_duration')),
    }
end

BESPOKE.archivist = function(kv)
    local entries = num(kv, 'entries')
    local slots = math.max(1, num(kv, 'slots'))
    local recording = num(kv, 'recording')
    local page = num(kv, 'page_rem')
    local cooldown = num(kv, 'file_cd')
    local recordCd = num(kv, 'record_cd')
    local name = kv.record and kv.record ~= '' and kv.record or nil
    local bar = timerBar('record', 'Record', recordCd, 'Ready', 6)
    if recording > 0 then
        bar = timerBar('watch', 'Watching Enemy', recording, 'Expired', 12)
    elseif page > 0 then
        bar = timerBar('page', 'Countermeasure', page, 'Spent', 25)
    elseif cooldown > 0 then
        bar = timerBar('file', 'File Countermeasure', cooldown, 'Ready', 15)
    elseif name then
        bar = timerBar('entry', 'Selected Record', num(kv, 'record_rem'), 'Expired', 60)
    end
    return { pips = pips('Records', entries, slots, 'azure', page > 0, name or 'NO RECORD'), bar = bar }
end

BESPOKE.sage = function(kv)
    local tit   = num(kv, 'titania') > 0
    local hpp   = num(kv, 'titania_hpp')
    local arts  = math.floor(num(kv, 'arts'))
    local ebul  = num(kv, 'ebullience') > 0
    local lText = tit and 'TITANIA ACTIVE' or 'CALL TITANIA'
    local rText = (arts == 2 and 'ADD: BLACK') or (arts == 1 and 'DARK ARTS') or (ebul and 'EBULLIENCE' or 'NO ARTS')
    return {
        pips = badge(lText, rText, tit or ebul),
        bar  = {
            key   = 'tit_hp',
            label = 'Titania Faerie HP',
            cur   = tit and hpp or 0,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
        },
    }
end

-- =============================================================================
-- 20. GEO: verdant
-- =============================================================================
BESPOKE.verdant = function(kv)
    local luo   = num(kv, 'luopan') > 0
    local hpp   = num(kv, 'luopan_hpp')
    local bRem  = num(kv, 'bolster_rem')
    local cRem  = num(kv, 'canopy_rem')
    local lText = luo and 'LUOPAN ACTIVE' or 'NO LUOPAN'
    local rText = cRem > 0 and ('CANOPY ' .. math.ceil(cRem) .. 's')
        or (bRem > 0 and 'BOLSTER 2x' or (luo and 'BLOOM 3s' or 'CAST GEO'))
    local bar = cRem > 0
        and timerBar('canopy', 'Ancient Canopy', cRem, 'Idle', 12)
        or {
            key   = 'luo_hp',
            label = 'Living Luopan HP',
            cur   = luo and hpp or 0,
            max   = 100,
            fmt   = 'pct',
            idle  = 'Offline',
        }
    return {
        pips = badge(lText, rText, luo or cRem > 0),
        bar  = bar,
    }
end

-- =============================================================================
-- 21. RUN: inquisitor, spellblade, lifebinder
-- =============================================================================
local INQ_STANCES = {
    [0] = 'NO STANCE',
    [1] = 'BATTUTA',
    [2] = 'AEGIS',
    [3] = 'CONVERGE',
}

BESPOKE.inquisitor = function(kv)
    local runes  = num(kv, 'runes')
    local stance = math.floor(num(kv, 'stance'))
    local cRem   = num(kv, 'converge_rem')
    local bRem   = num(kv, 'battuta_rem')
    local aRem   = num(kv, 'aegis_rem')
    local bar
    if cRem > 0 then
        bar = timerBar('conv', 'Runic Convergence', cRem, 'Idle', 10)
    elseif aRem >= bRem and aRem > 0 then
        bar = timerBar('aegis', 'Runic Aegis', aRem, 'Idle', 60)
    else
        bar = timerBar('bat', 'Iron Battuta', bRem, 'Idle', 60)
    end
    return {
        pips = pips('Runes', runes, 3, 'azure', stance == 3 or runes >= 3, INQ_STANCES[stance] or 'NO STANCE'),
        bar  = bar,
    }
end

BESPOKE.spellblade = function(kv)
    local prep  = first(kv, 'prep_stacks', 'prep')
    local runes = num(kv, 'runes')
    local eRem  = num(kv, 'edgeflare_rem')
    local oRem  = num(kv, 'overcharge_rem')
    local aRem  = num(kv, 'ascend_rem')
    local right = ('PREP %d/3 • %d RUNES'):format(prep, runes)
    local bar
    if oRem > 0 or aRem > 0 then
        bar = timerBar('oc', aRem > oRem and 'Ascendance' or 'Overcharge (2x)', math.max(oRem, aRem), 'Idle', 12)
    else
        bar = timerBar('edge', 'Edgeflare (+25%)', eRem, 'Idle', 12)
    end
    return {
        pips = pips('Prep', prep, 3, 'crimson', prep >= 3 or oRem > 0, right),
        bar  = bar,
    }
end

BESPOKE.lifebinder = function(kv)
    local runes = num(kv, 'runes')
    local sRem  = num(kv, 'sanct_rem')
    local fRem  = num(kv, 'font_rem')
    local vRem  = num(kv, 'valiance_rem')
    local bar
    if sRem > 0 then
        bar = timerBar('sanct', 'Sanctified Ward', sRem, 'Idle', 15)
    elseif fRem > 0 then
        bar = timerBar('font', 'Font of Life', fRem, 'Idle', 12)
    else
        bar = timerBar('val', 'Valiance Ward', vRem, 'Pulse Ready', 60)
    end
    return {
        pips = pips('Runes', runes, 3, 'emerald', runes >= 3),
        bar  = bar,
    }
end

function M.build(soulKey, kv, _def, _rt, _role)
    kv = kv or {}
    local fn = BESPOKE[soulKey]
    if fn then
        local ok, res = pcall(fn, kv)
        if ok and type(res) == 'table' then return res end
    end
    -- Unbuilt Souls (~26 Souls without custom server spec code) intentionally return `{}`
    -- so they render only the Soul Crystal medallion + compact Soul header pill.
    return {}
end

function M.hasBespoke(soulKey)
    return BESPOKE[soulKey] ~= nil
end

M.ROLE_GEM = ROLE_GEM

return M
