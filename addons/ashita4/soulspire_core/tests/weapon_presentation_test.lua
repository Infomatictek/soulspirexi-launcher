-- SoulspireXI Core: Reusable Soul Weapon Presentation & Berserker Dual Great Axe test suite.
-- Run from addons/ashita4/soulspire_core: luajit tests/weapon_presentation_test.lua
package.path = './?.lua;./?/init.lua;' .. package.path

local WP = require('core.weapon_presentation')

local function u32(v)
    return string.char(
        v % 256,
        math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 16777216) % 256
    )
end

local function make_oxsi(op, actor, job, branch, name, soul)
    local raw = string.rep('\0', 4) .. 'OXSI' .. string.char(1, op)
        .. u32(actor) .. u32(actor)
        .. string.char(job, branch, #name, #soul) .. name .. soul
    local pad = (4 - (#raw % 4)) % 4
    return raw .. string.rep('\0', pad)
end

-- 1. Authoritative JSON file loads cleanly and has diagnostics disabled by default.
local wp = WP.new('../../../plugins/ashita4/data/soul-weapon-presentation.json')
assert(wp:is_diagnostics_enabled() == false, 'Diagnostics must be disabled by default')
local ok_load, err_load = wp:load_file()
assert(ok_load == true, 'Failed to load authoritative soul-weapon-presentation.json: ' .. tostring(err_load))
assert(wp:is_diagnostics_enabled() == false, 'Loading JSON must keep diagnostics disabled by default')

-- 2. All 8 playable character models verified for drawn symmetry & crossed-back X separation.
assert(#WP.RACE_KEYS == 8, 'Must define all 8 playable FFXI character models')
for race_id = 1, 8 do
    local rk = WP.RACE_ID_TO_KEY[race_id]
    assert(rk ~= nil and wp.races[rk] ~= nil, 'Missing race ' .. tostring(race_id))
    local r = wp.races[rk]
    assert(math.abs(r.drawn.main.translation.x + r.drawn.sub.translation.x) < 0.001, rk .. ' drawn X symmetry')
    assert(math.abs(r.drawn.main.rotationDeg.roll + r.drawn.sub.rotationDeg.roll) < 0.01, rk .. ' drawn roll symmetry')
    assert(math.abs(r.sheathed.main.translation.x + r.sheathed.sub.translation.x) < 0.001, rk .. ' sheathed X symmetry')
    assert(r.sheathed.main.rotationDeg.roll > 30 and r.sheathed.sub.rotationDeg.roll < -30, rk .. ' crossed-X roll')
    assert(math.abs(r.sheathed.main.rotationDeg.roll + r.sheathed.sub.rotationDeg.roll) < 0.01, rk .. ' crossed-X mirror')
    assert((r.sheathed.sub.backDepth - r.sheathed.main.backDepth) >= 0.025, rk .. ' back depth separation')
end

-- 3. Exhaustive 66-Soul + unsocketed + unknown Soul exclusivity (local actor).
local local_allowed = 0
for job = 1, 22 do
    -- Unsocketed base job fails closed (including WAR base job!)
    assert(wp:evaluate_actor({
        actor_id = 1001, is_local = true, soul_known = true, job = job, branch = 0, effective_level = 75,
        race_id = 1, is_engaged = false, is_dead = false,
        main_item_id = 16704, main_skill = 6, main_model_id = 94,
        sub_item_id = 16706, sub_skill = 6, sub_model_id = 93, distinct_items = true,
    }).state == 'vanilla', 'Unsocketed job ' .. tostring(job) .. ' must stay vanilla')

    for branch = 1, 3 do
        -- Unknown / unsynchronized identity fails closed
        assert(wp:evaluate_actor({
            actor_id = 1001, is_local = true, soul_known = false, job = job, branch = branch, effective_level = 75,
            race_id = 1, is_engaged = true, is_dead = false,
            main_item_id = 16704, main_skill = 6, main_model_id = 94,
            sub_item_id = 16706, sub_skill = 6, sub_model_id = 93, distinct_items = true,
        }).state == 'vanilla', 'Unsynchronized identity must fail closed')

        local sheathed = wp:evaluate_actor({
            actor_id = 1001, is_local = true, soul_known = true, job = job, branch = branch, effective_level = 75,
            race_id = 2, is_engaged = false, is_dead = false,
            main_item_id = 16704, main_skill = 6, main_model_id = 94,
            sub_item_id = 16706, sub_skill = 6, sub_model_id = 93, distinct_items = true,
        })
        local drawn = wp:evaluate_actor({
            actor_id = 1001, is_local = true, soul_known = true, job = job, branch = branch, effective_level = 75,
            race_id = 2, is_engaged = true, is_dead = false,
            main_item_id = 16704, main_skill = 6, main_model_id = 94,
            sub_item_id = 16706, sub_skill = 6, sub_model_id = 93, distinct_items = true,
        })
        if job == 1 and branch == 2 then
            assert(sheathed.state == 'sheathed_cross_x', 'Berserker disengaged must use crossed-back X')
            assert(drawn.state == 'drawn_dual_2h', 'Berserker engaged must use drawn dual 2H')
            assert(sheathed.main_model_id == 94 and sheathed.sub_model_id == 93, 'Actual GA models preserved independently')
            assert(drawn.main_model_id == 94 and drawn.sub_model_id == 93, 'Drawn GA models preserved independently')
            local_allowed = local_allowed + 1
        else
            assert(sheathed.state == 'vanilla' and drawn.state == 'vanilla',
                ('Non-Berserker Soul (%d,%d) must remain vanilla'):format(job, branch))
        end
    end
end
assert(local_allowed == 1, 'Exactly 1 of 66 Souls may activate Berserker presentation')

-- 4. State transitions: death, level sync < 10, unequip, non-GA, duplicate item, Soul switch.
local base_ber = {
    actor_id = 1001, is_local = true, soul_known = true, job = 1, branch = 2, effective_level = 75,
    race_id = 8, is_engaged = true, is_dead = false,
    main_item_id = 16704, main_skill = 6, main_model_id = 94,
    sub_item_id = 16705, sub_skill = 6, sub_model_id = 95, distinct_items = true,
}
assert(wp:evaluate_actor(base_ber).state == 'drawn_dual_2h')
base_ber.is_dead = true
assert(wp:evaluate_actor(base_ber).state == 'vanilla', 'Death must clear override')
base_ber.is_dead = false; base_ber.effective_level = 9
assert(wp:evaluate_actor(base_ber).state == 'vanilla', 'Level sync < 10 must clear override')
base_ber.effective_level = 75; base_ber.sub_item_id = 0
assert(wp:evaluate_actor(base_ber).state == 'vanilla', 'Unequipping Sub must restore vanilla')
base_ber.sub_item_id = 16705; base_ber.distinct_items = false
assert(wp:evaluate_actor(base_ber).state == 'vanilla', 'Non-distinct items must fail closed')
base_ber.distinct_items = true; base_ber.sub_skill = 8 -- Polearm
assert(wp:evaluate_actor(base_ber).state == 'vanilla', 'Non-Great-Axe sub must fail closed')

-- 5. Remote player isolation: evaluates observed peer OXSI Soul, NEVER local player's Soul.
local remote_ctx = {
    actor_id = 2002, is_local = false,
    -- Intentionally pass local Berserker fields to prove remote path ignores them!
    soul_known = true, job = 1, branch = 2, effective_level = 75,
    race_id = 7, is_engaged = false, is_dead = false,
    main_item_id = 16704, main_skill = 6, main_model_id = 94,
    sub_item_id = 16706, sub_skill = 6, sub_model_id = 93, distinct_items = true,
    now_sec = 100,
}
assert(wp:evaluate_actor(remote_ctx).state == 'vanilla', 'Unknown remote actor must fail closed')
assert(wp:observe_oxsi(make_oxsi(1, 2002, 1, 1, 'OtherWar', 'commander'), 100) == true)
assert(wp:evaluate_actor(remote_ctx).state == 'vanilla', 'Remote WAR Commander must stay vanilla')
assert(wp:observe_oxsi(make_oxsi(1, 2002, 1, 2, 'OtherWar', 'berserker'), 100) == true)
local rem_ok = wp:evaluate_actor(remote_ctx)
assert(rem_ok.state == 'sheathed_cross_x' and rem_ok.main_model_id == 94 and rem_ok.sub_model_id == 93,
    'Verified remote Berserker must resolve crossed-back X with independent models')
remote_ctx.now_sec = 221 -- > 120s TTL expiry
assert(wp:evaluate_actor(remote_ctx).state == 'vanilla', 'Expired remote OXSI peer must fail closed')
assert(wp:observe_oxsi(make_oxsi(1, 2002, 1, 2, 'OtherWar', 'berserker'), 300) == true)
remote_ctx.now_sec = 305
assert(wp:evaluate_actor(remote_ctx).state == 'sheathed_cross_x')
assert(wp:observe_oxsi(make_oxsi(0, 2002, 1, 0, 'OtherWar', ''), 306) == true)
assert(wp:evaluate_actor(remote_ctx).state == 'vanilla', 'Revoked remote peer must restore vanilla immediately')
wp:reset_peers()

-- 6. Developer live-adjustment controls: blocked when disabled, independent Main/Sub & JSON round-trip when enabled.
local denied_ok = wp:adjust_transform('hume_female', 'sheathed', 'sub', { backDepth = 0.21 })
assert(denied_ok == false, 'Adjustments must be rejected while diagnostics are disabled')
assert(wp:set_diagnostics_enabled(true) == true)
local adj_ok, adj_err = wp:adjust_transform('hume_female', 'sheathed', 'sub', {
    translation = { x = 0.048, y = 0.061 },
    rotationDeg = { pitch = 6.5, yaw = 8.5, roll = -42.5 },
    gripOffset  = { x = 0.002, y = -0.118, z = 0.004 },
    weaponSeparation = 0.096,
    backDepth = 0.192,
    scale = 0.93,
})
assert(adj_ok == true, 'Adjustment should succeed when diagnostics enabled: ' .. tostring(adj_err))
assert(wp.races.hume_female.sheathed.sub.backDepth == 0.192)
assert(wp.races.hume_female.sheathed.main.backDepth == 0.135, 'Main transform must remain independent from Sub edit')
assert(wp:mirror_main_to_sub('hume_female', 'sheathed', 0.04) == true)
assert(math.abs(wp.races.hume_female.sheathed.sub.backDepth - 0.175) < 0.0001)

local serialized = wp:serialize_json()
local wp2 = WP.new()
local rt_ok, rt_err = wp2:load_from_json(serialized)
assert(rt_ok == true, 'Round-trip JSON re-parse failed: ' .. tostring(rt_err))
assert(wp2:is_diagnostics_enabled() == false, 'Exported JSON must keep diagnostics disabled by default')
assert(math.abs(wp2.races.hume_female.sheathed.sub.backDepth - 0.175) < 0.0001, 'Round-trip must preserve tuned transforms')

print('SoulspireXI Core weapon presentation tests passed.')
