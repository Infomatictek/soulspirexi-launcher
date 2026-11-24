-- Run from the crystalsocket directory: luajit tests/weapon_config_test.lua
package.path = './?.lua;../?.lua;' .. package.path

local bit = require('bit')
local WC = require('weapon_config')
local Labels = require('job_labels')
local UI = require('ui')

-- 1. Authoritative registry-generated soul-weapon-config.json loaded cleanly.
local st = WC.status()
assert(st.loaded == true, 'Expected soul-weapon-config.json to load: ' .. tostring(st.error))
assert(st.schema_version == 1)
assert(type(st.registry_hash) == 'string' and #st.registry_hash == 16)
assert(st.rule_count == 2, 'Expected 2 registry native weapon rules (BRD Adventurer + WAR Berserker), got ' .. tostring(st.rule_count))

local rules = WC.native_rules()
assert(#rules == 2)

local brd_rule, ber_rule
for _, r in ipairs(rules) do
    if r.job == 10 and r.branch == 1 then brd_rule = r end
    if r.job == 1 and r.branch == 2 then ber_rule = r end
end
assert(brd_rule ~= nil, 'Missing registry rule for BRD Adventurer (job=10, branch=1)')
assert(brd_rule.soul_id == 'brd_dps')
assert(brd_rule.min_effective_level == 10)
assert(brd_rule.mode == WC.MODES.DUAL_1H)
assert(brd_rule.main_skill_mask == bit.bor(bit.lshift(1, WC.SKILLS.DAGGER), bit.lshift(1, WC.SKILLS.SWORD)))
assert(brd_rule.sub_skill_mask == brd_rule.main_skill_mask)

assert(ber_rule ~= nil, 'Missing registry rule for WAR Berserker (job=1, branch=2)')
assert(ber_rule.soul_id == 'war_dps')
assert(ber_rule.min_effective_level == 10)
assert(ber_rule.mode == WC.MODES.DUAL_2H)
assert(ber_rule.main_skill_mask == bit.lshift(1, WC.SKILLS.GREAT_AXE))
assert(ber_rule.sub_skill_mask == bit.lshift(1, WC.SKILLS.GREAT_AXE))

-- Appearance mask & rangedOnly loaded from same authoritative file (COR Flintlock).
local mask = WC.appearance_mask_for(17, 1)
assert(mask ~= nil and mask.soul_id == 'cor_ranged_dps' and mask.hide_main == true and mask.hide_sub == true)
assert(WC.appearance_mask_for(17, 2) == nil)
local ranged = WC.ranged_only_for(17, 1)
assert(ranged ~= nil and ranged.soul_id == 'cor_ranged_dps' and ranged.auto_facing == true)
assert(WC.ranged_only_for(17, 3) == nil)

-- 2. Exhaustive 66-Soul + unsocketed + unsynchronized exclusivity for DUAL_2H Sub menu.
local allowed_souls = 0
for job = 1, 22 do
    assert(WC.allows_dual_2h_sub_menu(true, job, 0, 75, WC.SKILLS.GREAT_AXE) == false,
        'Unsocketed base job ' .. job .. ' must fail closed')
    for branch = 1, 3 do
        assert(WC.allows_dual_2h_sub_menu(false, job, branch, 75, WC.SKILLS.GREAT_AXE) == false,
            'Unknown Soul identity must fail closed')
        local ok = WC.allows_dual_2h_sub_menu(true, job, branch, 75, WC.SKILLS.GREAT_AXE)
        if job == 1 and branch == 2 then
            assert(ok == true, 'WAR Berserker Lv75 must allow Great Axe in Sub menu')
            allowed_souls = allowed_souls + 1
        else
            assert(ok == false, 'Non-Berserker Soul (' .. job .. ',' .. branch .. ') must NOT allow Great Axe in Sub menu')
        end
    end
end
assert(allowed_souls == 1, 'Exactly 1 of 66 Souls may allow Great Axe in Sub menu')

-- Lv9 Berserker and non-Great-Axe 2H weapons remain rejected.
assert(WC.allows_dual_2h_sub_menu(true, 1, 2, 9, WC.SKILLS.GREAT_AXE) == false)
for _, other_skill in ipairs({
    WC.SKILLS.GREAT_SWORD, WC.SKILLS.SCYTHE, WC.SKILLS.POLEARM,
    WC.SKILLS.GREAT_KATANA, WC.SKILLS.STAFF, WC.SKILLS.SWORD, WC.SKILLS.AXE,
}) do
    assert(WC.allows_dual_2h_sub_menu(true, 1, 2, 75, other_skill) == false)
end

-- 3. Fail-closed verification: tampered integrity, stale hash, or bad schema yields 0 rules!
local orig_path = st.source_path
local f = assert(io.open(orig_path, 'rb'))
local raw_json = f:read('*a')
f:close()

local ok_stale = WC.load_from_string(raw_json, '0000000000000000')
assert(ok_stale == false and #WC.native_rules() == 0)
assert(WC.allows_dual_2h_sub_menu(true, 1, 2, 75, WC.SKILLS.GREAT_AXE) == false)
-- Fail-closed disables custom overrides cleanly so vanilla FFXI equipment/appearance remains unaffected
assert(WC.appearance_mask_for(17, 1) == nil and WC.ranged_only_for(17, 1) == nil)

local tampered = raw_json:gsub('"minEffectiveLevel": 10', '"minEffectiveLevel": 11', 1)
local ok_tamper = WC.load_from_string(tampered)
assert(ok_tamper == false and #WC.native_rules() == 0)

local bad_schema = raw_json:gsub('"schemaVersion": 1', '"schemaVersion": 99', 1)
assert(WC.load_from_string(bad_schema) == false and #WC.native_rules() == 0)

-- Reload clean authoritative file.
assert(WC.load_from_string(raw_json, st.registry_hash) == true)
assert(#WC.native_rules() == 2)

-- 4. Labels:sync_weapon_rules packs exact 24-byte C ABI struct for SoulspireNativeReplaceWeaponRules.
local labels = Labels.new(function() return function() return 0 end end)
local captured_count, captured_rules
local ok_sync, err_sync = labels:sync_weapon_rules(WC.native_rules(), function(buf, count)
    captured_count = count
    captured_rules = {}
    for i = 0, count - 1 do
        captured_rules[i + 1] = {
            size = tonumber(buf[i].size),
            job = tonumber(buf[i].job),
            branch = tonumber(buf[i].branch),
            min_effective_level = tonumber(buf[i].min_effective_level),
            mode = tonumber(buf[i].mode),
            main_skill_mask = tonumber(buf[i].main_skill_mask),
            sub_skill_mask = tonumber(buf[i].sub_skill_mask),
            main_item_id = tonumber(buf[i].main_item_id),
            sub_item_id = tonumber(buf[i].sub_item_id),
            reserved = tonumber(buf[i].reserved),
        }
    end
    return 0
end)
assert(ok_sync == true and err_sync == nil and captured_count == 2)
for i = 1, 2 do
    assert(captured_rules[i].size == 24 and captured_rules[i].reserved == 0)
end

-- 4b. Regression: empty Lua weapon rule table must NOT wipe C++-loaded native rules.
local wipe_called = false
local ok_empty, err_empty = labels:sync_weapon_rules({}, function()
    wipe_called = true
    return 0
end)
assert(ok_empty == false and wipe_called == false,
    'Empty weapon_config sync must refuse to call SoulspireNativeReplaceWeaponRules(NULL, 0)')
assert(type(err_empty) == 'string' and err_empty:find('preserve', 1, true) ~= nil)

-- 4c. Regression: WAR Lv20 / DRG10 Berserker (job=1, branch=2, lvl=20) with Great Axe
-- must pass Sub-menu DUAL_2H eligibility while other WAR Souls and Lv9 fail closed.
assert(WC.allows_dual_2h_sub_menu(true, 1, 2, 20, WC.SKILLS.GREAT_AXE) == true)
assert(WC.allows_dual_2h_sub_menu(true, 1, 0, 20, WC.SKILLS.GREAT_AXE) == false)
assert(WC.allows_dual_2h_sub_menu(true, 1, 1, 20, WC.SKILLS.GREAT_AXE) == false)
assert(WC.allows_dual_2h_sub_menu(true, 1, 3, 20, WC.SKILLS.GREAT_AXE) == false)

-- 5. Verify no custom Sub picker or 0x050 injection helpers exist.
assert(WC.pick_sub_weapon == nil and WC.inject_equip == nil and UI.draw_sub_picker == nil)

print('Crystal Socket registry-driven weapon_config & UI tests passed.')
