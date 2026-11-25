-- SoulspireXI Core: Client Cache, SHA-256 Integrity, Coexistence IPC & Sync Protocol Test Suite
-- Run from addons/ashita4/soulspire_core: luajit tests/cache_and_sync_test.lua

package.path = './?.lua;./?/init.lua;../soulspire_talents/?.lua;../crystalsocket/?.lua;' .. package.path

local json           = require('core.json')
local sha256         = require('core.sha256')
local DataService    = require('core.data_service')
local CoreIPC        = require('core.ipc')
local SoulforgeState = require('soulforge_state')
local CharacterMod   = require('modules.character')
local csProtocol     = require('protocol')
local csStateMod     = require('state')

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format('%s: expected %s, got %s', msg or 'assert_eq', tostring(b), tostring(a)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then error(msg or 'assert_true failed', 2) end
end

local function copy_file(src, dst)
    local f = assert(io.open(src, 'rb'))
    local data = f:read('*a')
    f:close()
    local o = assert(io.open(dst, 'wb'))
    o:write(data)
    o:close()
end

-- ---------------------------------------------------------------------------
-- 1. Pure-Lua SHA-256 FIPS 180-4 & JSON Decoder Tests (Zero loadstring)
-- ---------------------------------------------------------------------------
assert_eq(sha256.digest(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'SHA-256 empty')
assert_eq(sha256.digest('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'SHA-256 abc')
assert_eq(sha256.digest('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1', 'SHA-256 448-bit vector')

local decObj, decErr = json.decode('{"a":1,"b":[true,false,null,"hi\\n\\u0041"]}')
assert_true(decErr == nil and decObj.a == 1 and decObj.b[1] == true and decObj.b[2] == false and decObj.b[4] == 'hi\nA', 'JSON decode')
local badObj, badErr = json.decode('{"a":1} trailing')
assert_true(badObj == nil and badErr ~= nil, 'JSON rejects trailing garbage')

-- ---------------------------------------------------------------------------
-- 2. DataService Loads & Verifies All 66 Souls, 219 WSs, 219 Talent Trees
-- ---------------------------------------------------------------------------
local memBefore = collectgarbage('count')
local tStart = os.clock()
local ds = DataService.new({ cache_dir = 'cache', auto_load = true })
local eagerMs = (os.clock() - tStart) * 1000
assert_true(ds:is_cache_ready(), 'DataService must load verified cache: ' .. tostring(ds.error_message))
assert_eq(#ds:get_all_souls(), 66, 'All 66 canonical Souls loaded from cache')
assert_eq(#ds:get_all_weapon_skills(), 219, 'All 219 Weapon Skills loaded from cache')

-- Verify permanent ID, job/branch, legacy alias, and display name resolution
local spartan = ds:get_soul_by_id('war_tank')
assert_true(spartan ~= nil and spartan.displayName == 'Spartan' and spartan.abbreviation == 'SPT', 'war_tank -> Spartan')
assert_eq(ds:get_soul_by_key('gladiator').id, 'war_tank', 'legacy alias gladiator resolves to war_tank')
assert_eq(ds:get_soul_by_job_branch(1, 3).id, 'war_tank', 'job=1,branch=3 resolves to war_tank')
local opp = ds:get_soul_by_key('bandit')
assert_true(opp ~= nil and opp.id == 'thf_dps' and opp.displayName == 'Opportunist', 'Renamed Soul propagates displayName while preserving internalKey')

-- Verify lazy talent tree loading (WS #16 Wasp Sting + Evolution WS #1 Combo)
local tTal0 = os.clock()
local ws16Tree = ds:get_ws_tree(16, 'berserker')
local lazyTalMs = (os.clock() - tTal0) * 1000
assert_true(ws16Tree ~= nil and #ws16Tree.nodes >= 12, 'WS #16 berserker tree resolved from cache')
local ws16Gen = ds:get_ws_tree(16, 'generic')
assert_true(ws16Gen ~= nil and ws16Gen.nodes[1].name ~= ws16Tree.nodes[1].name, 'Spec variant overrides node presentation cleanly')
assert_true(DataService.get_node_desc(ws16Tree.nodes[1], 0) ~= '', 'Node rank 0 description present')
assert_true(DataService.get_node_desc(ws16Tree.nodes[1], 1) ~= '', 'Node rank 1 description present')

local comboTree = ds:get_ws_tree(1, 'generic')
assert_true(comboTree ~= nil and comboTree.evolution == true, 'Evolution WS #1 Combo tree loaded')

local okAll, errAll = ds:verify_all()
assert_true(okAll, 'verify_all must pass across all 6 packages: ' .. tostring(errAll))
local memAfter = collectgarbage('count')

-- ---------------------------------------------------------------------------
-- 3. Hash Corruption, Missing Cache, Malformed Cache & Version Mismatch Detection
-- ---------------------------------------------------------------------------
local tmpDir = '/tmp/soulspire_cache_test_' .. tostring(math.floor(os.clock() * 100000))
os.execute('rm -rf ' .. tmpDir .. ' && mkdir -p ' .. tmpDir)
for _, fname in ipairs({ 'manifest.json', 'souls.json', 'weapon_skills.json', 'talents.json', 'abilities.json', 'equipment.json', 'ui_metadata.json' }) do
    copy_file('cache/' .. fname, tmpDir .. '/' .. fname)
end

-- Corrupt 1 byte of weapon_skills.json
local fws = assert(io.open(tmpDir .. '/weapon_skills.json', 'rb'))
local wsBytes = fws:read('*a')
fws:close()
local fwsW = assert(io.open(tmpDir .. '/weapon_skills.json', 'wb'))
fwsW:write(wsBytes:sub(1, 20) .. 'X' .. wsBytes:sub(22))
fwsW:close()

local dsCorrupt = DataService.new({ cache_dir = tmpDir, auto_load = true })
assert_true(not dsCorrupt:is_cache_ready(), 'Corrupted weapon_skills.json must fail SHA-256 verification')
assert_eq(dsCorrupt.status, 'corrupt', 'Status must be corrupt')
assert_eq(dsCorrupt.compat_state, 'corrupt_local', 'compat_state must be corrupt_local')
assert_true(dsCorrupt.error_message:find('SoulspireLauncher', 1, true) ~= nil, 'Error message guides user to SoulspireLauncher')

-- Missing cache directory
local dsMissing = DataService.new({ cache_dir = tmpDir .. '/does_not_exist', auto_load = true })
assert_true(not dsMissing:is_cache_ready() and dsMissing.status == 'missing', 'Missing cache fails safely')

-- Server incompatible schema version
local dsCompat = DataService.new({ cache_dir = 'cache', auto_load = true })
local cState = dsCompat:apply_server_compat({
    protocolVersion = 2, schemaVersion = 3, minSchema = 2,
    contentHash = 'abc', registryHash = 'deadbeef', contentVersion = 'v3',
})
assert_eq(cState, 'incompatible_schema', 'Schema mismatch detected cleanly')
assert_true(not dsCompat:is_cache_usable(), 'Incompatible schema prevents stale cache use')

os.execute('rm -rf ' .. tmpDir)

-- ---------------------------------------------------------------------------
-- 4. Weapon Mastery Vertical Slice: Cached Sync, WS #16 Compact State,
--    Legacy Fallback, Timeout Recovery, and Zero Double-OP_SYNC Bug
-- ---------------------------------------------------------------------------
local fakeClock = 100.0
local sentPkts = {}
local sfState, sfActions = SoulforgeState.new({
    dataService = ds,
    clock       = function() return fakeClock end,
    sendPacket  = function(id, bytes, op, wsId, a1, a2)
        sentPkts[#sentPkts + 1] = { id = id, op = op, wsId = wsId, a1 = a1, a2 = a2 }
        return true
    end,
})
sfState.open[1] = true

-- Immediate local catalog availability BEFORE any server packets arrive!
assert_eq(#sfState.catalog, 219, 'Weapon Mastery has 219 WSs immediately from verified cache')
assert_eq(sfState.catalogSource, 'cache', 'Catalog source is cache')
assert_eq(sfState.catalogById[16].name, 'Wasp Sting', 'WS #16 resolved immediately as Wasp Sting (never Weapon Skill #16)')

-- Sync sends lightweight OP_CACHE_SYNC (op=9), NOT legacy 42-packet OP_SYNC (op=1)
sfActions.sync()
assert_eq(#sentPkts, 1, 'Initial sync sends exactly 1 packet')
assert_eq(sentPkts[1].op, SoulforgeState.OP_CACHE_SYNC, 'Uses OP_CACHE_SYNC (9)')

-- Simulate server CACHE + META + SPENT + SYNC_END reply (only 4 packets total!)
local info = ds:get_cache_info()
sfActions.handleProtoLine(string.format('CACHE|2|1|1|%s|%s|%s|1', info.contentHash, info.registryHash, info.contentVersion))
sfActions.handleProtoLine('META|THF|75|220|5|225|2|0|Opportunist|bandit')
-- Verify initial META did NOT trigger the old double-OP_SYNC bug!
assert_eq(#sentPkts, 1, 'Initial META must NOT trigger duplicate OP_SYNC')
sfActions.handleProtoLine('SPENT_BEGIN')
sfActions.handleProtoLine('SPENT|16:5:1')
sfActions.handleProtoLine('SPENT_END')
sfActions.handleProtoLine('SYNC_END|1|1')
assert_true(sfState.synced, 'Synced cleanly via lightweight v2 flow')
assert_eq(ds.compat_state, 'compatible', 'Cache marked compatible with server')
-- Auto-select requested WS #16 (first Dagger WS) via compact OP_WS_STATE (op=10)!
assert_eq(sfState.selectedWsId, 16, 'Auto-selected WS #16 Wasp Sting for equipped Dagger')
assert_eq(sentPkts[2].op, SoulforgeState.OP_WS_STATE, 'WS inspect uses compact OP_WS_STATE (10)')
assert_eq(sentPkts[2].wsId, 16, 'Requested WS #16')

-- Simulate server compact WSS_BEGIN + WSS + WSS_END for WS #16
sfActions.handleProtoLine('WSS_BEGIN|16|5|220|1|bandit|4:0:0:0|1')
sfActions.handleProtoLine('WSS|16|ftp=3:1,sc_t1=1:1')
sfActions.handleProtoLine('WSS_END|16|220|1|1')
assert_true(sfState.wsDetail ~= nil and sfState.wsDetail.id == 16, 'WS #16 detail assembled from cache+WSS')
assert_eq(sfState.wsDetail.source, 'cache+wss', 'Detail assembled via cache+wss')
assert_eq(sfState.wsDetail.byKey['ftp'].rank, 3, 'Authoritative rank merged onto cached tree')
assert_eq(sfState.wsDetail.byKey['sc_t1'].scId, 4, 'Authoritative skillchain ID merged')
assert_true(sfState.wsDetail.byKey['ftp'].desc ~= '', 'Rank-specific description resolved locally')

-- Test WS #16 timeout recovery (prevents infinite "LOADING WEAPON SKILL #16..." bug!)
sfState.wsDetail = nil
sfState.wsDetailsById = {}
sfActions.requestWS(16)
assert_true(sfState.wsRequest ~= nil and sfState.wsRequest.mode == 'compact', 'Compact request armed')
-- Advance 2.0s with no server reply -> auto-fallback to legacy OP_WS (op=3)
fakeClock = fakeClock + 2.0
sfActions.tick(fakeClock)
assert_eq(sfState.wsRequest.mode, 'legacy', 'Auto-fallback to legacy OP_WS after 1.8s')
assert_eq(sentPkts[#sentPkts].op, SoulforgeState.OP_WS, 'Sent legacy OP_WS fallback')
-- Advance through bounded retries -> cleanly enters error state instead of spinning forever
for _ = 1, 3 do
    fakeClock = fakeClock + 5.5
    sfActions.tick(fakeClock)
end
assert_true(sfState.wsRequest == nil and sfState.wsError ~= nil, 'Bounded timeout sets actionable wsError instead of infinite loading')

-- Test zoning invalidation does NOT wipe verified local static catalog
sfActions.invalidate('zone_change')
assert_eq(#sfState.catalog, 219, 'Zone invalidation keeps verified static 219-WS catalog intact')
assert_true(sfState.wsDetail == nil and sfState.needsRefresh == true, 'Zone invalidation clears stale dynamic WS state')

-- ---------------------------------------------------------------------------
-- 5. Legacy Server Auto-Fallback (unmodified server without OP_CACHE_SYNC)
-- ---------------------------------------------------------------------------
local legClock = 200.0
local legSent = {}
local legState, legActions = SoulforgeState.new({
    dataService = ds,
    clock       = function() return legClock end,
    sendPacket  = function(_, _, op, wsId) legSent[#legSent + 1] = { op = op, wsId = wsId }; return true end,
})
legActions.sync()
assert_eq(legSent[1].op, SoulforgeState.OP_CACHE_SYNC, 'Starts with OP_CACHE_SYNC')
legClock = legClock + 2.0
legActions.tick(legClock)
assert_eq(legSent[2].op, SoulforgeState.OP_STATE, 'Falls back to OP_STATE (still avoids 36-pkt CAT flood!)')
legActions.handleProtoLine('META|WAR|75|200|25|225|6|0|Berserker')
legActions.handleProtoLine('SPENT_BEGIN')
legActions.handleProtoLine('SPENT|80:5:1')
legActions.handleProtoLine('SPENT_END')
assert_true(legState.synced and #legState.catalog == 219, 'Legacy server completes sync cleanly with cached catalog')

-- ---------------------------------------------------------------------------
-- 6. Character Module: Cached 66-Soul Metadata + Lightweight OP_QUERY + Coexistence
-- ---------------------------------------------------------------------------
local csClock = 300.0
local csSent = {}
local csState = csStateMod.new()
local charMod = CharacterMod.new({
    protocol      = csProtocol,
    crystal_state = csState,
    data_service  = ds,
    clock         = function() return csClock end,
    player_ctx_fn = function()
        return { name = 'Hero', server_id = 12345, zone = 230, main_job = 1, main_lvl = 75, sub_job = 13, sub_lvl = 37 }
    end,
    send_packet   = function(pkt)
        csSent[#csSent + 1] = pkt
        return true
    end,
})

charMod:on_open()
-- Must send OP_QUERY (0), NOT OP_SYNC_CATALOG (2) -> avoids 15-25 CRYC packets AND Busy race!
assert_eq(#csSent, 1, 'Character on_open sends 1 lightweight crystal packet')
assert_eq(csSent[1]:byte(10), csProtocol.OP_QUERY, 'Uses lightweight OP_QUERY instead of OP_SYNC_CATALOG')
local reqId = csSent[1]:byte(11) + csSent[1]:byte(12) * 256
assert_true(reqId >= 0x4000 and reqId < 0x8000, 'Uses Core reserved request ID range')

-- Static Soul metadata (names, roles, descriptions, highlights) is ALREADY populated from cache!
local preEntries = charMod:get_entries()
assert_eq(#preEntries, 4, 'Base + 3 canonical WAR Souls available instantly before server reply')
assert_eq(preEntries[4].name, 'Spartan', 'Spartan displayName from verified cache')
assert_true(#preEntries[4].highlights > 0, 'Spartan highlights populated locally from cache')
assert_true(not preEntries[4].owned, 'Ownership remains FALSE until server confirms via CRYS')

-- Build authoritative 64-byte CRYS reply confirming WAR branches 1..3 owned, branch 3 active
local function make_crys(req, job, level, result, active_branch, owned_mask)
    local hdr = string.char(0xFF, 0x21, 0, 0) .. 'CRYS' .. string.char(1, result, req % 256, math.floor(req / 256), job, 24, level, 0)
    local body = {}
    for i = 0, 23 do
        if i == job then
            body[#body + 1] = string.char(owned_mask, active_branch)
        else
            body[#body + 1] = string.char(0, 0)
        end
    end
    return hdr .. table.concat(body)
end

-- First test Busy (result=3) triggers bounded retry instead of staying broken
local busyPkt = make_crys(reqId, 1, 75, 3, 0, 0)
assert_true(charMod:handle_packet_in(0x1FF, busyPkt, csClock, 64), 'Core handles its own CRYS Busy reply')
assert_true(charMod.retry_after ~= nil, 'Busy schedules bounded retry')
csClock = csClock + 2.0
charMod:tick(csClock)
assert_eq(#csSent, 2, 'Bounded retry sent second OP_QUERY')
local reqId2 = csSent[2]:byte(11) + csSent[2]:byte(12) * 256

-- Now deliver authoritative Success reply (even with trailing padded bytes, sliced via size=64!)
local okPkt = make_crys(reqId2, 1, 75, 0, 3, 14) -- bits 1,2,3 set (2+4+8=14), active=3 (Spartan)
assert_true(charMod:handle_packet_in(0x1FF, okPkt .. '\0\0\0\0', csClock, 64), 'Core slices padded packet and accepts CRYS reply')
local postEntries, postSnap = charMod:get_entries()
assert_true(postSnap.loaded and postSnap.status == 'ready', 'Character status is ready')
assert_true(postEntries[4].owned and postEntries[4].active, 'Spartan confirmed owned & active by server')
assert_true(charMod:_can_socket(postSnap), 'Can socket owned Crystals without waiting for CRYC catalog packets')

-- ---------------------------------------------------------------------------
-- 7. Multi-Addon Coexistence IPC (Both Load Orders!)
-- ---------------------------------------------------------------------------
CoreIPC.reset_for_tests()
local tTal = CoreIPC.register_listener('OXTL', 'soulspire_talents')
local tCor = CoreIPC.register_listener('OXTL', 'soulspire_core')
assert_true(not CoreIPC.should_block(tTal), 'Earlier-loaded soulspire_talents must NOT block before soulspire_core')
assert_true(CoreIPC.should_block(tCor), 'Later-loaded soulspire_core blocks 0x1FD from reaching FFXI')
CoreIPC.unregister_listener(tCor)
assert_true(CoreIPC.should_block(tTal), 'After soulspire_core unloads, standalone soulspire_talents resumes blocking')

CoreIPC.reset_for_tests()
local tCor2 = CoreIPC.register_listener('OXTL', 'soulspire_core')
local tTal2 = CoreIPC.register_listener('OXTL', 'soulspire_talents')
assert_true(not CoreIPC.should_block(tCor2), 'Reverse load order: earlier-loaded soulspire_core passes to soulspire_talents')
assert_true(CoreIPC.should_block(tTal2), 'Reverse load order: later-loaded soulspire_talents blocks')

print(string.format(
    'CACHE_SYNC_TEST_OK eagerLoadMs=%.2f lazyTalentsMs=%.2f memDeltaKB=%.1f',
    eagerMs, lazyTalMs, memAfter - memBefore
))
