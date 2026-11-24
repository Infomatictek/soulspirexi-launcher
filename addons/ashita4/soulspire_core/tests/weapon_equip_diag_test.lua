-- Run from addons/ashita4/soulspire_core: luajit tests/weapon_equip_diag_test.lua
package.path = './?.lua;../crystalsocket/?.lua;' .. package.path

local bit = require('bit')
local WC = require('weapon_config')
local Diag = require('core.weapon_equip_diag')

local ALL_27_HOOKS_MASK = bit.lshift(1, 27) - 1
local MISSING_HOOK26_MASK = bit.band(ALL_27_HOOKS_MASK, bit.bnot(bit.lshift(1, 25)))

assert(WC.status().loaded == true, 'Authoritative soul-weapon-config.json must load')
local rules = WC.native_rules()
local reg_hash = WC.status().registry_hash

local main_ga = { item_id = 18480, name = 'Bronze Zaghnal Test GA', skill = 6, slots = 1, bag = 0, index = 1 }
local second_ga = { item_id = 18481, name = 'Brass Zaghnal Test GA', skill = 6, slots = 1, bag = 0, index = 2 }
local vanilla_grip = { item_id = 19024, name = 'Brass Grip', skill = 0, slots = 2, bag = 0, index = 3 }
local vanilla_shield = { item_id = 12289, name = 'Lauan Shield', skill = 0, slots = 2, bag = 0, index = 4 }
local great_sword = { item_id = 16900, name = 'Claymore', skill = 4, slots = 1, bag = 0, index = 5 }

-- 1. Must fail closed when diagnostics are disabled (disabled by default).
local ok_off, err_off = Diag.run_diagnostic({ diagnostics_enabled = false })
assert(ok_off == false and tostring(err_off):find('disabled by default', 1, true) ~= nil)

-- 2. Healthy WAR20/DRG10 Berserker with two Great Axes + Grip + Shield + Great Sword.
local ok_healthy, rep_healthy = Diag.run_diagnostic({
    diagnostics_enabled = true,
    rules_override = rules,
    config_registry_hash = reg_hash,
    weapon_config_hash = 'test-wc-hash',
    effective_level = 20,
    main_weapon = main_ga,
    candidates = { second_ga, vanilla_grip, vanilla_shield, great_sword },
    native_override = {
        dll_loaded = true,
        enabled = true,
        abi_version = 2,
        installed_hooks = 27,
        expected_hooks = 27,
        installed_mask = ALL_27_HOOKS_MASK,
        job = 1,
        branch = 2,
        known = true,
        weapon_rules_count = 2,
        weapon_allow_hits = 1,
        weapon_deny_hits = 0,
        compiled_registry_hash = reg_hash,
        active_registry_hash = reg_hash,
        last_error = 0,
    },
})
assert(ok_healthy == true)
assert(rep_healthy.native.equipHooksOk == true)
assert(rep_healthy.native.resolvedSoulId == 'war_dps')
assert(rep_healthy.sync.registryHashesMatch == true)
assert(rep_healthy.summary.allowedDual2h == 1, 'Second Great Axe must be ALLOW_DUAL_2H')
assert(rep_healthy.summary.allowedVanillaSub == 2, 'Grip and Shield must remain ALLOW_VANILLA_SUB')
assert(rep_healthy.summary.rejected == 1, 'Great Sword must be rejected for Berserker')
assert(rep_healthy.candidates[1].decision == 'ALLOW_DUAL_2H')
assert(rep_healthy.candidates[4].decision == 'REJECT')
assert(rep_healthy.candidates[4].rejection_reason:find('SUB_SKILL_MASK_MISMATCH', 1, true) ~= nil)

-- 3. Reproduce live failure mode A: Stale DLL without Hook #26 (25 hooks instead of 27).
local ok_stale, rep_stale = Diag.run_diagnostic({
    diagnostics_enabled = true,
    rules_override = rules,
    effective_level = 20,
    main_weapon = main_ga,
    candidates = { second_ga, vanilla_grip },
    native_override = {
        dll_loaded = true,
        enabled = true,
        installed_hooks = 25,
        expected_hooks = 25,
        installed_mask = MISSING_HOOK26_MASK,
        job = 1,
        branch = 2,
        known = true,
        weapon_rules_count = 2,
    },
})
assert(ok_stale == true)
assert(rep_stale.native.equipHooksOk == false)
assert(rep_stale.candidates[1].decision == 'REJECT')
assert(rep_stale.candidates[1].rejection_reason == 'EQUIPMENT_HOOKS_MISSING')
assert(rep_stale.candidates[2].decision == 'ALLOW_VANILLA_SUB',
    'Vanilla grips remain visible even when Hook #26 is missing (matches observed playtest failure!)')

-- 4. Reproduce live failure mode B: Wiped native weapon rule catalog (weapon_rules_count == 0).
local ok_wiped, rep_wiped = Diag.run_diagnostic({
    diagnostics_enabled = true,
    rules_override = rules,
    effective_level = 20,
    main_weapon = main_ga,
    candidates = { second_ga },
    native_override = {
        dll_loaded = true,
        enabled = true,
        installed_hooks = 27,
        expected_hooks = 27,
        installed_mask = ALL_27_HOOKS_MASK,
        job = 1,
        branch = 2,
        known = true,
        weapon_rules_count = 0,
    },
})
assert(ok_wiped == true)
assert(rep_wiped.candidates[1].decision == 'REJECT')
assert(rep_wiped.candidates[1].rejection_reason == 'NATIVE_WEAPON_RULE_CATALOG_EMPTY')

-- 5. Reproduce live failure mode C: Soul HUD showed BRZ, but native bridge has known == false.
local ok_unsynced, rep_unsynced = Diag.run_diagnostic({
    diagnostics_enabled = true,
    rules_override = rules,
    effective_level = 20,
    main_weapon = main_ga,
    candidates = { second_ga },
    native_override = {
        dll_loaded = true,
        enabled = true,
        installed_hooks = 27,
        expected_hooks = 27,
        installed_mask = ALL_27_HOOKS_MASK,
        job = 1,
        branch = 0,
        known = false,
        weapon_rules_count = 2,
    },
})
assert(ok_unsynced == true)
assert(rep_unsynced.candidates[1].decision == 'REJECT')
assert(rep_unsynced.candidates[1].rejection_reason == 'NATIVE_SOUL_NOT_SYNCED')

print('Soulspire Core weapon_equip_diag tests passed.')
