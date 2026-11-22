-- SoulspireXI: Declarative Soul weapon configuration synced to crystaljobs.dll.
--
-- The native FFXI Equipment menu and /equip commands handle all equipment
-- selection (including full controller support). This module only defines the
-- per-Soul native offhand weapon rules pushed to crystaljobs.dll via
-- CrystalJobsReplaceWeaponRules so EquipMenu::TryEquipItem (0x133D56) allows
-- configured Souls to dual-wield directly through the original FFXI UI.
--
-- WAR Spartan/Gladiator Polearm + Size-1 Buckler already passes FFXiMain.dll
-- natively (Shields bypass the Dual Wield weapon gate at 0x133CFF) and is
-- enforced authoritatively by the server.
--
-- The server (soulspire_weapon_config.lua + patch 0073) remains 100%
-- authoritative for all equipment validation and combat rules.
local bit = require('bit')

local W = {}

W.JOBS = {
    WAR = 1,
    BRD = 10,
}

W.SKILLS = {
    HAND_TO_HAND = 1,
    DAGGER       = 2,
    SWORD        = 3,
    GREAT_SWORD  = 4,
    AXE          = 5,
    GREAT_AXE    = 6,
    SCYTHE       = 7,
    POLEARM      = 8,
    KATANA       = 9,
    GREAT_KATANA = 10,
    CLUB         = 11,
    STAFF        = 12,
}

-- Matches CRYSTALJOBS_WEAPON_MODE_* in native/crystaljobs/crystaljobs.h.
W.MODES = {
    DUAL_1H        = 1,
    DUAL_2H        = 2,
    TWOHAND_SHIELD = 3,
}

function W.skill_mask(skills)
    local mask = 0
    if type(skills) ~= 'table' then return 0 end
    for _, skill in ipairs(skills) do
        if type(skill) == 'number' and skill >= 1 and skill < 32 and skill % 1 == 0 then
            mask = bit.bor(mask, bit.lshift(1, skill))
        end
    end
    return mask
end

-- Declarative per-Soul weapon rules synchronized into crystaljobs.dll.
-- Only explicitly configured Souls receive client-side offhand exceptions;
-- all other Souls preserve vanilla FFXI Equipment menu behavior.
W.RULES = {
    -- Template 1 Reference (dual_1h): BRD Adventurer (job=10, branch=1, Lv10+)
    -- Permits Dagger/Sword Dual Wield natively in the FFXI Equipment menu.
    {
        job = W.JOBS.BRD,
        branch = 1,
        key = 'adventurer',
        min_effective_level = 10,
        mode = W.MODES.DUAL_1H,
        main_skills = { W.SKILLS.DAGGER, W.SKILLS.SWORD },
        sub_skills  = { W.SKILLS.DAGGER, W.SKILLS.SWORD },
        main_item_id = 0,
        sub_item_id  = 0,
    },
    -- Template 2 Prototype (dual_2h): WAR Berserker (job=1, branch=2, Lv10+)
    -- Permits Dual Great Axes natively in the FFXI Equipment menu.
    {
        job = W.JOBS.WAR,
        branch = 2,
        key = 'berserker',
        min_effective_level = 10,
        mode = W.MODES.DUAL_2H,
        main_skills = { W.SKILLS.GREAT_AXE },
        sub_skills  = { W.SKILLS.GREAT_AXE },
        main_item_id = 0,
        sub_item_id  = 0,
    },
}

-- Returns normalized C-ABI rule tables ready for CrystalJobsReplaceWeaponRules.
function W.native_rules()
    local out = {}
    for _, rule in ipairs(W.RULES) do
        local main_mask = rule.main_skill_mask or W.skill_mask(rule.main_skills)
        local sub_mask  = rule.sub_skill_mask or W.skill_mask(rule.sub_skills)
        if rule.job and rule.branch and rule.mode and main_mask ~= 0 and sub_mask ~= 0 then
            out[#out + 1] = {
                job = rule.job,
                branch = rule.branch,
                min_effective_level = rule.min_effective_level or 10,
                mode = rule.mode,
                main_skill_mask = main_mask,
                sub_skill_mask = sub_mask,
                main_item_id = rule.main_item_id or 0,
                sub_item_id = rule.sub_item_id or 0,
            }
        end
    end
    return out
end

return W
