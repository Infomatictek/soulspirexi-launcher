-- SoulspireXI: Declarative Soul weapon configuration synced to soulspire_native.dll.
--
-- The native FFXI Equipment menu and /equip commands handle all equipment
-- selection (including full controller support). This module defines the
-- per-Soul native offhand weapon rules pushed to soulspire_native.dll via
-- SoulspireNativeReplaceWeaponRules so:
--   * Hook #26 (0x21DF85) exposes permitted DUAL_2H weapons in the native Sub menu
--   * Hook #25 (0x133D56) permits configured Souls past the vanilla DW trait gate
--   * Hook #27 (0x133DD3) permits configured 2H Main + Sub combinations
--   * Hook #22 (0x133E33) permits Main-slot 2H weapons in Sub only when Main
--     eligibility passes and an active DUAL_2H Soul rule matches
--
-- WAR Spartan/Gladiator Polearm + Size-1 Buckler already passes FFXiMain.dll
-- natively (Shields bypass the Dual Wield weapon gate at 0x133CFF) and is
-- enforced authoritatively by the server.
--
-- The server (soulspire_weapon_config.lua + patches 0073/0075) remains 100%
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

-- Matches SOULSPIRE_NATIVE_WEAPON_MODE_* in soulspire_native/core/api.h.
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

-- Declarative per-Soul weapon rules synchronized into soulspire_native.dll.
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
    -- Template 2 Exclusive (dual_2h): WAR Berserker (job=1, branch=2, Lv10+)
    -- Exclusively permits Dual Great Axes natively in the FFXI Sub equipment menu.
    -- Never inferred from WAR base job; gated strictly on confirmed Berserker Soul identity.
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

-- Fail-closed check for client-side DUAL_2H Sub-menu eligibility.
-- Returns true ONLY when active Soul identity is confirmed and matches a DUAL_2H rule.
function W.allows_dual_2h_sub_menu(known, job, branch, effective_level, sub_skill)
    if known ~= true then return false end
    if type(job) ~= 'number' or type(branch) ~= 'number' or branch <= 0 then return false end
    if type(effective_level) ~= 'number' or effective_level < 1 then return false end
    if type(sub_skill) ~= 'number' or sub_skill < 1 or sub_skill >= 32 or sub_skill % 1 ~= 0 then
        return false
    end
    local sub_bit = bit.lshift(1, sub_skill)
    for _, rule in ipairs(W.RULES) do
        if rule.mode == W.MODES.DUAL_2H
            and rule.job == job
            and rule.branch == branch
            and effective_level >= (rule.min_effective_level or 10)
        then
            local mask = rule.sub_skill_mask or W.skill_mask(rule.sub_skills)
            if bit.band(mask, sub_bit) ~= 0 then
                return true
            end
        end
    end
    return false
end

-- Returns normalized C-ABI rule tables ready for SoulspireNativeReplaceWeaponRules.
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
