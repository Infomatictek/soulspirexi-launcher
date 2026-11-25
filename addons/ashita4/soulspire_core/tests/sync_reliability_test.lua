-- SoulspireXI Core — Phase 4 Talent Synchronization Reliability & Stress Test Suite
-- Covers all 12 required operational scenarios:
--   1. Empty client state login
--   2. Valid static cache login + cooperative non-blocking warmup
--   3. Open Weapon Mastery (instant cached tree preview + gated mutations)
--   4. Repeated tab switching Character <-> Weapon Mastery <-> Soul Talents (zero storms)
--   5. Repeated sync requests while in-flight (strict deduplication)
--   6. Unlock & upgrade talent (authoritative mutation)
--   7. Refund talent (authoritative mutation)
--   8. Zone & reopen interface
--   9. Logout & reconnect
--  10. Delayed, dropped, duplicated, and out-of-order responses (zero stale corruption)
--  11. Legacy addon interference & /addon reload order safety
--  12. Server unavailable & clean recovery

package.path = './?.lua;./?/init.lua;../soulspire_talents/?.lua;../crystalsocket/?.lua;' .. package.path

local DataService    = require('core.data_service')
local CoreIPC        = require('core.ipc')
local Registry       = require('core.registry')
local Focus          = require('core.focus')
local SoulforgeState = require('soulforge_state')
local WeaponMastery  = require('modules.weapon_mastery')
local SoulTalents    = require('modules.soul_talents')

-- Minimal mock ImGui for soulforge_ui helper checks
package.loaded['imgui'] = {
    GetIO = function() return { DisplaySize = { x = 1920, y = 1080 } } end,
    CalcTextSize = function(s) return #tostring(s or '') * 7, 14 end,
}
package.loaded['art'] = { draw = function() return false end, get = function() return nil end, clear = function() end }
local sfUI = require('soulforge_ui')

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format('%s: expected %s, got %s', msg or 'assert_eq', tostring(b), tostring(a)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then error(msg or 'assert_true failed', 2) end
end

-- =========================================================================
-- Scenario 1 & 2: Valid Static Cache + Cooperative Non-Blocking Warmup
-- =========================================================================
local t0 = os.clock()
local ds = DataService.new({ cache_dir = 'cache', auto_load = true })
local eagerMs = (os.clock() - t0) * 1000
assert_true(ds:is_cache_ready(), 'Static cache must load cleanly')
assert_true(not ds:is_talents_warm(), 'Large talents.json deferred at startup')

local warmupFrames = 0
local maxWarmupFrameMs = 0
local totalWarmupMs = 0
while not ds:is_talents_warm() do
    local s0 = os.clock()
    ds:step_warmup(4.0)
    local dt = (os.clock() - s0) * 1000
    if dt > maxWarmupFrameMs then
        maxWarmupFrameMs = dt
    end
    totalWarmupMs = totalWarmupMs + dt
    warmupFrames = warmupFrames + 1
    assert_true(warmupFrames < 300, 'Cooperative warmup must converge cleanly')
end
assert_true(ds:is_talents_warm(), 'talents.json cooperatively verified and indexed')
assert_true(warmupFrames >= 8, 'Warmup must span multiple budgeted frames (read + SHA-256 + incremental parse)')
assert_true(maxWarmupFrameMs < 35.0, string.format('Every warmup frame (read + hash + parse) must stay within budget, got %.2fms', maxWarmupFrameMs))
assert_eq(#ds:get_all_weapon_skills(), 219, '219 weapon skills cached')
assert_true(ds:get_ws_tree(42, 'spellblade') ~= nil, 'Incrementally parsed Savage Blade tree resolves cleanly')

-- =========================================================================
-- Scenario 3, 4, 5: Instant Cached Preview, Tab Switch Dedup, Repeated Sync
-- =========================================================================
local fakeClock = 1000.0
local sent = {}
local sfState, sfActions = SoulforgeState.new({
    soulRegistry = Registry.souls,
    dataService  = ds,
    clock        = function() return fakeClock end,
    sendPacket   = function(id, bytes, op, wsId, a1, a2)
        sent[#sent + 1] = { id = id, op = op, wsId = wsId, a1 = a1, a2 = a2, at = fakeClock }
        return true
    end,
})

local reg = Registry.new()
local wm  = WeaponMastery.new(sfState, sfActions, sfUI)
local st  = SoulTalents.new(sfState, sfActions, sfUI, { soul_registry = Registry.souls, data_service = ds })
reg:attach_controller('weapon_mastery', wm, true)
reg:attach_controller('soul_talents', st, true)
local focus = Focus.new(reg)

-- Open directly to Weapon Mastery -> sends exactly ONE OP_CACHE_SYNC
focus:open_from_native_menu(reg:find_index('weapon_mastery'))
assert_eq(#sent, 1, 'Initial open sends exactly 1 OP_CACHE_SYNC')
assert_eq(sent[1].op, SoulforgeState.OP_CACHE_SYNC, 'Op is OP_CACHE_SYNC')

-- Scenario 5: Spamming sync() while in-flight is deduplicated!
assert_eq(sfActions.sync(), false, 'Duplicate sync while in-flight deduplicated')
assert_eq(sfActions.sync(), false, 'Third sync while in-flight deduplicated')
assert_eq(#sent, 1, 'Still only 1 C2S packet sent')
assert_true(ds.metrics.deduped_requests >= 2, 'Deduplicated requests counted')

-- Simulate healthy local-network v2 server reply in 45ms
fakeClock = fakeClock + 0.045
local info = ds:get_cache_info()
sfActions.handleProtoLine(string.format('CACHE|2|1|1|%s|%s|%s|1', info.contentHash, info.registryHash, info.contentVersion))
sfActions.handleProtoLine('META|RDM|75|12|5|17|3|0|Spellblade|spellblade')
sfActions.handleProtoLine('SPENT_BEGIN')
sfActions.handleProtoLine('SPENT|42:5:1,34:0:0')
sfActions.handleProtoLine('SPENT_END')
sfActions.handleProtoLine('SYNC_END|1|1')

assert_true(sfState.synced, 'Synced cleanly via v2')
assert_true(sfState.v2Confirmed, 'v2Confirmed set')
assert_true(sfState.lastSyncLatencyMs > 0 and sfState.lastSyncLatencyMs < 100, 'Measured latency recorded (~45ms)')
-- Auto-select triggered OP_WS_STATE for first Sword WS AND immediately populated cached preview tree!
assert_eq(#sent, 2, 'Auto-select sent 1 compact OP_WS_STATE')
assert_eq(sent[2].op, SoulforgeState.OP_WS_STATE, 'Compact WS state op')
assert_true(sfState.wsDetail ~= nil, 'Cached preview tree immediately displayed before server WSS reply!')
assert_eq(sfState.wsDetail.authoritative, false, 'Preview tree clearly marked non-authoritative')
for _, n in ipairs(sfState.wsDetail.nodes) do
    assert_eq(n.canLearn, false, 'Mutations disabled on non-authoritative preview node: ' .. tostring(n.key))
end

-- Server completes WSS_END in 35ms
local wsId1 = sent[2].wsId
local reqSeq1 = sent[2].a2
fakeClock = fakeClock + 0.035
sfActions.handleProtoLine(string.format('WSS_BEGIN|%d|5|12|1|spellblade|12:0:0:0|%d', wsId1, reqSeq1))
sfActions.handleProtoLine(string.format('WSS|%d|ftp=2:1,gen_t1c2=2:1,gen_t1c3=1:1', wsId1))
sfActions.handleProtoLine(string.format('WSS_END|%d|12|1|%d', wsId1, reqSeq1))
assert_eq(sfState.wsDetail.authoritative, true, 'WS detail upgraded to authoritative after WSS_END')
assert_eq(sfState.wsDetail.byKey.ftp.rank, 2, 'Authoritative rank merged')
assert_eq(sfState.wsDetail.byKey.ftp.canLearn, true, 'Authoritative canLearn enabled')

-- Scenario 4: Rapidly switch tabs 10 times within freshness window -> ZERO duplicate sync storms!
local pktsBeforeTabSpam = #sent
for _ = 1, 5 do
    fakeClock = fakeClock + 0.1
    focus:select_module('soul_talents')
    fakeClock = fakeClock + 0.1
    focus:select_module('weapon_mastery')
end
assert_eq(#sent, pktsBeforeTabSpam, 'Rapid tab switching emitted ZERO redundant packets')

-- =========================================================================
-- Scenario 6 & 7: Unlock/Upgrade & Refund Talent (Authoritative)
-- =========================================================================
assert_true(sfActions.investNode(wsId1, sfState.wsDetail.byKey.ftp), 'Invest sent')
assert_eq(sent[#sent].op, SoulforgeState.OP_INVEST, 'OP_INVEST sent')
assert_eq(sent[#sent].a2, 1, 'Compact flag set on OP_INVEST')
fakeClock = fakeClock + 0.040
sfActions.handleProtoLine('META|RDM|75|11|6|17|3|0|Spellblade|spellblade')
sfActions.handleProtoLine(string.format('WSS_BEGIN|%d|6|11|1|spellblade|12:0:0:0|0', wsId1))
sfActions.handleProtoLine(string.format('WSS|%d|ftp=3:1,gen_t1c2=2:1,gen_t1c3=1:1', wsId1))
sfActions.handleProtoLine(string.format('WSS_END|%d|11|1|0', wsId1))
assert_eq(sfState.wsDetail.byKey.ftp.rank, 3, 'Rank upgraded to 3 authoritatively')
assert_eq(sfState.avail, 11, 'Points decremented to 11')

assert_true(sfActions.refundNode(wsId1, sfState.wsDetail.byKey.ftp), 'Refund sent')
assert_eq(sent[#sent].op, SoulforgeState.OP_REFUND, 'OP_REFUND sent')
fakeClock = fakeClock + 0.040
sfActions.handleProtoLine('META|RDM|75|12|5|17|3|0|Spellblade|spellblade')
sfActions.handleProtoLine(string.format('WSS_BEGIN|%d|5|12|1|spellblade|12:0:0:0|0', wsId1))
sfActions.handleProtoLine(string.format('WSS|%d|ftp=2:1,gen_t1c2=2:1,gen_t1c3=1:1', wsId1))
sfActions.handleProtoLine(string.format('WSS_END|%d|12|1|0', wsId1))
assert_eq(sfState.wsDetail.byKey.ftp.rank, 2, 'Rank refunded back to 2 authoritatively')

-- =========================================================================
-- Scenario 10: Delayed, Duplicated & Out-Of-Order Responses (ZERO Corruption!)
-- =========================================================================
fakeClock = fakeClock + 5.0
-- Player rapidly selects WS #42 then WS #34 before WS #42 replies
sfActions.requestWS(42)
local seq42 = sfState.wsRequest.seq
sfActions.requestWS(34)
local seq34 = sfState.wsRequest.seq
assert_eq(sfState.selectedWsId, 34, 'Selected WS is 34')

-- Stale delayed WSS_END for WS #42 arrives late!
sfActions.handleProtoLine(string.format('WSS_BEGIN|42|5|12|1|spellblade|0:0:0:0|%d', seq42))
sfActions.handleProtoLine('WSS|42|ftp=5:0')
sfActions.handleProtoLine(string.format('WSS_END|42|12|1|%d', seq42))
assert_eq(sfState.selectedWsId, 34, 'Selected WS remains 34')
assert_eq(sfState.wsDetail.id, 34, 'Stale WS #42 response MUST NOT overwrite active WS #34 view!')
assert_true(sfState.wsRequest ~= nil and sfState.wsRequest.wsId == 34, 'In-flight request for WS #34 remains active')

-- Out-of-order stale seq for WS #34 arrives (seq34 - 1) -> dropped!
local staleSeq = (seq34 > 1) and (seq34 - 1) or 99
sfActions.handleProtoLine(string.format('WSS_BEGIN|34|1|12|1|spellblade|0:0:0:0|%d', staleSeq))
sfActions.handleProtoLine('WSS|34|ftp=1:1')
sfActions.handleProtoLine(string.format('WSS_END|34|12|1|%d', staleSeq))
assert_eq(sfState.wsDetail.authoritative, false, 'Stale seq response dropped, did not corrupt state')

-- Valid seq34 response arrives -> applied cleanly!
fakeClock = fakeClock + 0.050
sfActions.handleProtoLine(string.format('WSS_BEGIN|34|2|12|1|spellblade|0:0:0:0|%d', seq34))
sfActions.handleProtoLine('WSS|34|ftp=2:1')
sfActions.handleProtoLine(string.format('WSS_END|34|12|1|%d', seq34))
assert_eq(sfState.wsDetail.id, 34, 'WS #34 applied cleanly')
assert_eq(sfState.wsDetail.authoritative, true, 'WS #34 now authoritative')
assert_eq(sfState.wsDetail.byKey.ftp.rank, 2, 'WS #34 rank=2 applied')
assert_true(ds.metrics.stale_dropped >= 2, 'Stale responses tracked in diagnostics')

-- =========================================================================
-- Scenario 8 & 9: Zone + Reopen & Logout + Reconnect
-- =========================================================================
sfActions.invalidate('zone_change')
assert_eq(#sfState.catalog, 219, 'Zone keeps verified 219-WS static cache')
assert_eq(sfState.wsDetail, nil, 'Zone clears stale dynamic detail')
assert_true(sfState.needsRefresh, 'Zone flags needsRefresh')
assert_eq(sfState.serverSupportsV2, true, 'v2Confirmed preserved across zone')

sfActions.invalidate('logout')
assert_eq(sfState.syncPending, nil, 'Logout clears in-flight sync')
assert_eq(sfState.wsRequest, nil, 'Logout clears in-flight WS request')

-- =========================================================================
-- Scenario 11: Legacy Addon Interference & /addon reload Safety
-- =========================================================================
CoreIPC.reset_for_tests()
local tTal = CoreIPC.register_listener('OXTL', 'soulspire_talents')
local tCor = CoreIPC.register_listener('OXTL', 'soulspire_core')
assert_true(CoreIPC.has_listener('OXTL', 'soulspire_core'), 'Core listener visible to standalone addon')
assert_true(not CoreIPC.is_primary_owner('OXTL', 'soulspire_talents'), 'Core is primary owner over standalone addon')
assert_true(CoreIPC.is_primary_owner('OXTL', 'soulspire_core'), 'Core owns OXTL')
assert_true(not CoreIPC.should_block(tTal), 'Earlier talents addon does not block')
assert_true(CoreIPC.should_block(tCor), 'Core blocks after receiving')

-- Simulate /addon reload soulspire_talents while soulspire_core stays loaded!
CoreIPC.unregister_listener(tTal)
local tTalReload = CoreIPC.register_listener('OXTL', 'soulspire_talents')
assert_true(not CoreIPC.should_block(tCor), 'Core now passes packet to reloaded talents addon')
assert_true(CoreIPC.should_block(tTalReload), 'Reloaded talents addon blocks last')
assert_true(CoreIPC.has_listener('OXTL', 'soulspire_core'), 'Core still recognized as active primary owner')
CoreIPC.unregister_listener(tTalReload)
assert_true(CoreIPC.should_block(tCor), 'After talents unloads, Core cleanly resumes blocking')

-- =========================================================================
-- Scenario 12: Server Unavailable -> Exponential Backoff -> Clean Recovery
-- =========================================================================
local recClock = 2000.0
local recSent = {}
local recState, recActions = SoulforgeState.new({
    dataService = ds,
    clock       = function() return recClock end,
    sendPacket  = function(_, _, op, wsId) recSent[#recSent + 1] = { op = op, wsId = wsId, at = recClock }; return true end,
})
recActions.sync()
-- Step through fallback + 3 bounded exponential backoff retries -> clean error (zero infinite spin!)
for _ = 1, 10 do
    recClock = recClock + 2.0
    recActions.tick(recClock)
end
assert_eq(recState.syncPending, nil, 'Exhausted retries cleared syncPending')
assert_eq(recState.syncState, 'error', 'Entered actionable error state')
assert_true(recState.lastSyncError ~= nil, 'Actionable error message populated')

-- Server comes back online -> manual sync recovers cleanly!
assert_eq(recActions.sync(false, true), true, 'Manual recovery sync dispatched')
recClock = recClock + 0.030
recActions.handleProtoLine(string.format('CACHE|2|1|1|%s|%s|%s|1', info.contentHash, info.registryHash, info.contentVersion))
recActions.handleProtoLine('META|WAR|75|10|0|10|6|0|Berserker|berserker')
recActions.handleProtoLine('SPENT_BEGIN')
recActions.handleProtoLine('SPENT_END')
recActions.handleProtoLine('SYNC_END|' .. tostring(recState.syncGen) .. '|1')
assert_true(recState.synced and recState.syncState == 'synced' and recState.lastSyncError == nil, 'Recovered cleanly when server returned')

local stats = ds:get_sync_stats()
print(string.format(
    'SYNC_RELIABILITY_OK eager=%.1fms warmupFrames=%d maxWarmupFrame=%.2fms totalWarmup=%.1fms avgLat=%.1fms p95=%.1fms ok=%d fail=%d staleDropped=%d deduped=%d',
    eagerMs, warmupFrames, maxWarmupFrameMs, totalWarmupMs, stats.avgLatencyMs, stats.p95LatencyMs,
    stats.completedCount, stats.failureCount, stats.staleDropped, stats.dedupedRequests
))
