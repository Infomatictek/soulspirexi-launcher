-- Run from addons/ashita4/soulspire_core: luajit tests/weapon_presentation_test.lua
package.path = './?.lua;../?.lua;' .. package.path

local WP = require('core.weapon_presentation')

-- 1. Unloaded manager MUST fail closed to vanilla!
local unloaded = WP.new()
assert(unloaded:is_loaded() == false)
assert(unloaded:is_diagnostics_enabled() == false)
assert(unloaded:evaluate({
    actor_id = 1001, is_local = true, soul_known = true, job = 1, branch = 2,
    effective_level = 75, race = 1, is_engaged = true,
    main_item_id = 16704, main_skill = 6, main_model_id = 94,
    sub_item_id = 16706, sub_skill = 6, sub_model_id = 93,
}).state == 'vanilla')

-- 2. Load authoritative registry-generated plugins/ashita4/data/soul-weapon-config.json.
local config_path = '../../../plugins/ashita4/data/soul-weapon-config.json'
local tmp_cal = '/tmp/soulspire_weapon_calibration_test.json'
local tmp_exp = '/tmp/soulspire_weapon_export_test.json'
local native_reloads = 0
local mgr = WP.new(config_path, tmp_cal, function()
    native_reloads = native_reloads + 1
    return true
end)
local ok_load, err_load = mgr:load_file(config_path)
assert(ok_load == true, 'Failed to load authoritative soul-weapon-config.json: ' .. tostring(err_load))
assert(mgr:is_loaded() == true)
assert(mgr:is_diagnostics_enabled() == false)

local st = mgr:status()
assert(st.binding_count == 2 and st.profile_count >= 1)
assert(#st.registry_hash == 16)

-- 3. Fail-closed on tampered JSON, stale hash, or unsupported schema.
do
    local f = assert(io.open(config_path, 'rb'))
    local raw = f:read('*a')
    f:close()
    local bad = WP.new()
    assert(bad:load_json_string(raw, '0000000000000000') == false and bad:is_loaded() == false)
    assert(bad:load_json_string(raw:gsub('"schemaVersion": 1', '"schemaVersion": 2', 1)) == false)
    assert(bad:load_json_string(raw:gsub('"minEffectiveLevel": 10', '"minEffectiveLevel": 12', 1)) == false)
end

-- 4. Verify all 8 playable character models have valid drawn & crossed-back X transforms.
for idx, rk in ipairs(WP.RACE_KEYS) do
    local dm = mgr:get_transform(rk, 'drawn', 'main')
    local ds = mgr:get_transform(rk, 'drawn', 'sub')
    local sm = mgr:get_transform(rk, 'sheathed', 'main')
    local ss = mgr:get_transform(rk, 'sheathed', 'sub')
    assert(dm and ds and sm and ss, 'Missing transforms for ' .. rk)
    assert(math.abs(dm.translation.x + ds.translation.x) < 0.001)
    assert(math.abs(sm.translation.x + ss.translation.x) < 0.001)
    assert(sm.rotationDeg.roll > 30 and ss.rotationDeg.roll < -30)
    assert((ss.backDepth - sm.backDepth) >= 0.025)
    local dec = mgr:evaluate({
        actor_id = 1001, is_local = true, soul_known = true, job = 1, branch = 2,
        effective_level = 75, race = idx, is_engaged = false,
        main_item_id = 16704, main_skill = 6, main_model_id = 94,
        sub_item_id = 16706, sub_skill = 6, sub_model_id = 93,
    })
    assert(dec.state == 'sheathed_cross_x' and dec.soul_id == 'war_dps' and dec.profile_id == 'dual_2h_crossed_back_x')
    assert(dec.main_model_id == 94 and dec.sub_model_id == 93)
end

-- 5. Exhaustive 66-Soul + unsocketed + unknown Soul exclusivity.
local active_count = 0
for job = 1, 22 do
    assert(mgr:evaluate({
        actor_id = 1001, is_local = true, soul_known = true, job = job, branch = 0,
        effective_level = 75, race = 1, is_engaged = true,
        main_item_id = 16704, main_skill = 6, main_model_id = 94,
        sub_item_id = 16706, sub_skill = 6, sub_model_id = 93,
    }).state == 'vanilla')
    for branch = 1, 3 do
        assert(mgr:evaluate({
            actor_id = 1001, is_local = true, soul_known = false, job = job, branch = branch,
            effective_level = 75, race = 1, is_engaged = true,
            main_item_id = 16704, main_skill = 6, main_model_id = 94,
            sub_item_id = 16706, sub_skill = 6, sub_model_id = 93,
        }).state == 'vanilla')
        local drawn = mgr:evaluate({
            actor_id = 1001, is_local = true, soul_known = true, job = job, branch = branch,
            effective_level = 75, race = 1, is_engaged = true,
            main_item_id = 16704, main_skill = 6, main_model_id = 94,
            sub_item_id = 16706, sub_skill = 6, sub_model_id = 93,
        })
        if job == 1 and branch == 2 then
            assert(drawn.state == 'drawn_dual_2h')
            active_count = active_count + 1
        else
            assert(drawn.state == 'vanilla')
        end
    end
end
assert(active_count == 1)

-- 6. Remote OXSI peer isolation (never leaks local Berserker Soul to remote players).
local function build_oxsi(op, actor, char_id, job, branch, name, soul)
    local function u32(v)
        return string.char(v % 256, math.floor(v / 256) % 256, math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
    end
    local payload = string.char(0xFC, 0x00, 0x00, 0x00) .. 'OXSI' .. string.char(1, op)
        .. u32(actor) .. u32(char_id) .. string.char(job, branch, #name, #soul) .. name .. soul
    local pad = (4 - (#payload % 4)) % 4
    return payload .. string.rep('\0', pad)
end

local remote_q = {
    actor_id = 2002, is_local = false, soul_known = true, job = 1, branch = 2,
    effective_level = 75, race = 7, is_engaged = false,
    main_item_id = 16704, main_skill = 6, main_model_id = 94,
    sub_item_id = 16706, sub_skill = 6, sub_model_id = 93,
    now_sec = 100,
}
assert(mgr:evaluate(remote_q).state == 'vanilla')
assert(mgr:observe_oxsi_packet(build_oxsi(1, 2002, 2002, 1, 1, 'PeerWar', 'commander'), 100) == true)
assert(mgr:evaluate(remote_q).state == 'vanilla')
assert(mgr:observe_oxsi_packet(build_oxsi(1, 2002, 2002, 1, 2, 'PeerWar', 'berserker'), 100) == true)
assert(mgr:evaluate(remote_q).state == 'sheathed_cross_x')
remote_q.now_sec = 221
assert(mgr:evaluate(remote_q).state == 'vanilla')
remote_q.now_sec = 110
assert(mgr:observe_oxsi_packet(build_oxsi(0, 2002, 2002, 1, 0, 'PeerWar', ''), 110) == true)
assert(mgr:evaluate(remote_q).state == 'vanilla')

-- 7. Alignment Studio: disabled by default, persistent calibration save/load + native reload sync + reset + export.
local ef_sub = mgr:get_transform('elvaan_female', 'sheathed', 'sub')
local modified = {
    translation = { x = ef_sub.translation.x, y = ef_sub.translation.y, z = 0.215 },
    rotationDeg = { pitch = ef_sub.rotationDeg.pitch, yaw = ef_sub.rotationDeg.yaw, roll = ef_sub.rotationDeg.roll },
    gripOffset = { x = ef_sub.gripOffset.x, y = ef_sub.gripOffset.y, z = ef_sub.gripOffset.z },
    scale = ef_sub.scale,
    weaponSeparation = ef_sub.weaponSeparation,
    backDepth = 0.215,
}
assert(mgr:set_transform('elvaan_female', 'sheathed', 'sub', modified) == false)
mgr:set_diagnostics_enabled(true)
assert(mgr:set_transform('elvaan_female', 'sheathed', 'sub', modified) == true)
local ok_save, _, ok_sync = mgr:save_calibration_and_sync_native(tmp_cal)
assert(ok_save == true and ok_sync == true and native_reloads == 1)

-- Fresh instance reloads persistent developer calibration profile cleanly!
local mgr2 = WP.new(config_path, tmp_cal)
assert(mgr2:load_file(config_path) == true)
assert(mgr2:is_diagnostics_enabled() == false)
assert(mgr2:load_calibration_file(tmp_cal) == true)
assert(mgr2:is_diagnostics_enabled() == true)
assert(math.abs(mgr2:get_transform('elvaan_female', 'sheathed', 'sub').backDepth - 0.215) < 0.0001)
assert(math.abs(mgr2:get_transform('elvaan_female', 'sheathed', 'main').backDepth - 0.145) < 0.0001)

-- Export & reset work cleanly.
assert(mgr2:export_file(tmp_exp) == true)
mgr2:reset_transforms()
assert(math.abs(mgr2:get_transform('elvaan_female', 'sheathed', 'sub').backDepth - 0.183) < 0.0001)
mgr2:set_diagnostics_enabled(false)
os.remove(tmp_cal)
os.remove(tmp_exp)

print('Soulspire Core generic registry-driven weapon_presentation tests passed.')
