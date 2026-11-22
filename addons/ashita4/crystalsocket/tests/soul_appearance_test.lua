package.path = './?.lua;./addons/ashita4/crystalsocket/?.lua;' .. package.path

local Appearance = require('soul_appearance')

local function eq(actual, expected, label)
    if actual ~= expected then
        error(string.format('%s: expected %s, got %s', label, tostring(expected), tostring(actual)), 2)
    end
end

local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
    return string.char(
        v % 256,
        math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 16777216) % 256
    )
end

local function read_u16(s, pos1)
    local lo, hi = s:byte(pos1, pos1 + 1)
    return lo + hi * 256
end

local function make_grap(main_id, sub_id, ranged_id)
    return u16(0x0201) -- face/race
        .. u16(0x1010) -- head
        .. u16(0x2020) -- body
        .. u16(0x3030) -- hands
        .. u16(0x4040) -- legs
        .. u16(0x5050) -- feet
        .. u16(0x6000 + main_id)
        .. u16(0x7000 + sub_id)
        .. u16(ranged_id == 0xFFFF and 0xFFFF or (0x8000 + ranged_id))
end

local function make_0x51(grap)
    return string.char(0x51, 0x18, 0x00, 0x00) .. grap .. string.char(0x00, 0x00)
end

local function make_0x0a(grap)
    return string.rep('\0', 68) .. grap .. string.rep('\0', 16)
end

local function make_0x0d(server_id, send_flg, grap)
    return string.char(0x0D, 0x38, 0x00, 0x00)
        .. u32(server_id)
        .. u16(1)
        .. string.char(send_flg)
        .. string.rep('\0', 61)
        .. grap
        .. string.rep('\0', 16)
end

-- 1. Soul rule gating: only COR Flintlock (job=17, branch=1) hides Main/Sub.
do
    local r_flt = Appearance.rule_for(17, 1)
    assert(r_flt and r_flt.hide_main and r_flt.hide_sub, 'COR Flintlock rule hides Main/Sub')
    eq(Appearance.rule_for(17, 2), nil, 'COR Gambler has no hide rule')
    eq(Appearance.rule_for(17, 3), nil, 'COR Buccaneer has no hide rule')
    eq(Appearance.rule_for(1, 2), nil, 'WAR Berserker has no hide rule')
    eq(Appearance.rule_for(11, 1), nil, 'RNG Sniper has no hide rule')
end

-- 2. Soul switching & immediate visual hide / restore via injected 0x0051.
do
    local ap = Appearance.new()
    local injected = {}
    local function inject(pkt) injected[#injected + 1] = pkt end

    -- Initial login look: Sword (42), Shield/Dagger (19), Silver Gun (139)
    local orig = make_grap(42, 19, 139)
    eq(ap:on_zone_in(make_0x0a(orig)), nil, 'Zone-in before Soul sync leaves look untouched')

    -- Equip COR Flintlock -> immediately injects 0x0051 with Main=0x6000, Sub=0x7000, Ranged=0x808B
    eq(ap:set_active_soul(17, 1, inject), true, 'Activating Flintlock injects masked 0x0051')
    eq(#injected, 1, 'One packet injected on Flintlock activation')
    eq(read_u16(injected[1], 17), 0x6000, 'Main slot hidden (0x6000)')
    eq(read_u16(injected[1], 19), 0x7000, 'Sub slot hidden (0x7000)')
    eq(read_u16(injected[1], 21), 0x8000 + 139, 'Ranged gun preserved (Silver Gun)')

    -- Repeated sync with same Soul -> no redundant injection
    eq(ap:set_active_soul(17, 1, inject), false, 'No redundant injection when Soul unchanged')
    eq(#injected, 1, 'Still one packet')

    -- Switch from Flintlock -> Gambler -> immediately restores original Main (42) and Sub (19)
    eq(ap:set_active_soul(17, 2, inject), true, 'Switching to Gambler restores original look')
    eq(#injected, 2, 'Second packet injected on Soul switch')
    eq(read_u16(injected[2], 17), 0x6000 + 42, 'Main sword restored')
    eq(read_u16(injected[2], 19), 0x7000 + 19, 'Sub dagger restored')
    eq(read_u16(injected[2], 21), 0x8000 + 139, 'Ranged gun still preserved')
end

-- 3. Weapon changes while Flintlock is active: new gear stays hidden, then restores NEW gear on switch.
do
    local ap = Appearance.new()
    local injected = {}
    local function inject(pkt) injected[#injected + 1] = pkt end

    ap:on_zone_in(make_0x0a(make_grap(42, 19, 139)))
    ap:set_active_soul(17, 1, inject)

    -- Player swaps Main to Sword 77, Sub to Dagger 88, Ranged to Death Penalty (107)
    local updated_pkt = ap:on_grap_list(make_0x51(make_grap(77, 88, 107)))
    assert(updated_pkt ~= nil, 'Incoming 0x0051 during Flintlock is masked')
    eq(read_u16(updated_pkt, 17), 0x6000, 'New Main hidden while Flintlock active')
    eq(read_u16(updated_pkt, 19), 0x7000, 'New Sub hidden while Flintlock active')
    eq(read_u16(updated_pkt, 21), 0x8000 + 107, 'New Ranged gun (Death Penalty) shown')

    -- Switch to Buccaneer -> restores NEW Main (77) and NEW Sub (88)
    eq(ap:set_active_soul(17, 3, inject), true, 'Switch to Buccaneer restores new weapons')
    local restored = injected[#injected]
    eq(read_u16(restored, 17), 0x6000 + 77, 'Restored updated Main (77)')
    eq(read_u16(restored, 19), 0x7000 + 88, 'Restored updated Sub (88)')
    eq(read_u16(restored, 21), 0x8000 + 107, 'Preserved updated Ranged (107)')
end

-- 4. Zoning & relogging: reset clears stale state so characters never bleed appearance.
do
    local ap = Appearance.new()
    local injected = {}
    local function inject(pkt) injected[#injected + 1] = pkt end

    ap:on_zone_in(make_0x0a(make_grap(42, 19, 139)))
    ap:set_active_soul(17, 1, inject)
    eq(#injected, 1, 'Flintlock masked in zone 1')

    -- Zone out / logout -> reset
    ap:reset()
    eq(ap.raw_grap, nil, 'Reset clears cached GrapIDTbl')
    eq(ap.active_rule, nil, 'Reset clears active rule')
    -- Switching Soul before 0x000A arrives must not inject stale look
    eq(ap:set_active_soul(17, 1, inject), false, 'No injection before fresh 0x000A arrives')
    eq(#injected, 1, 'No stale injection')

    -- Zone into zone 2 while Flintlock is active -> 0x000A masked inline
    local z2 = ap:on_zone_in(make_0x0a(make_grap(55, 66, 139)))
    assert(z2 ~= nil, 'Zone 2 0x000A masked immediately when Flintlock already known')
    eq(read_u16(z2, 81), 0x6000, '0x000A Main hidden')
    eq(read_u16(z2, 83), 0x7000, '0x000A Sub hidden')
    eq(read_u16(z2, 85), 0x8000 + 139, '0x000A Ranged preserved')
end

-- 5. Self 0x000D PC update vs other players' 0x000D & Costume2 safety.
do
    local ap = Appearance.new()
    ap:set_active_soul(17, 1, nil)

    -- Other player (server_id 9999 ~= local 1001) -> never modified
    eq(ap:on_char_update(make_0x0d(9999, 0x1F, make_grap(12, 34, 139)), 1001), nil, 'Other player 0x000D untouched')

    -- Local player without SendFlg.Model (0x01) -> untouched
    eq(ap:on_char_update(make_0x0d(1001, 0x01, make_grap(12, 34, 139)), 1001), nil, '0x000D without Model flag untouched')

    -- Local player with SendFlg.Model (0x10) -> Main/Sub hidden
    local mod = ap:on_char_update(make_0x0d(1001, 0x10, make_grap(12, 34, 139)), 1001)
    assert(mod ~= nil, 'Self 0x000D with Model flag masked')
    eq(read_u16(mod, 85), 0x6000, '0x000D Main hidden')
    eq(read_u16(mod, 87), 0x7000, '0x000D Sub hidden')
    eq(read_u16(mod, 89), 0x8000 + 139, '0x000D Ranged preserved')

    -- Costume2 / Monstrosity (GrapIDTbl[8] == 0xFFFF) -> never modified
    eq(ap:on_grap_list(make_0x51(make_grap(12, 34, 0xFFFF))), nil, 'Costume2/Monstrosity 0x0051 untouched')
end

-- 6. Unload cleanup restores original appearance.
do
    local ap = Appearance.new()
    local injected = {}
    local function inject(pkt) injected[#injected + 1] = pkt end

    ap:on_zone_in(make_0x0a(make_grap(31, 41, 139)))
    ap:set_active_soul(17, 1, inject)
    eq(ap:restore(inject), true, 'Unload restore injects original 0x0051')
    local last = injected[#injected]
    eq(read_u16(last, 17), 0x6000 + 31, 'Unload restores Main')
    eq(read_u16(last, 19), 0x7000 + 41, 'Unload restores Sub')
end

print('Crystal Socket Soul appearance tests passed.')
