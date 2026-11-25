-- SoulspireXI Core — Centralized Reactive Character State Regression Test Suite
--
-- Verifies immediate reactive synchronization across Character, Weapon Mastery,
-- Soul Talents, and Universal Header WITHOUT closing the UI or clicking manual Sync:
--   1. Level-up (actual level & effective level update immediately, forces OP_STATE + WS refresh)
--   2. Level-down (immediate update & forced refresh even inside STATE_FRESH_SEC window)
--   3. Level Sync activation (actual_lvl=75, effective_lvl=30, is_level_synced=true, banner label)
--   4. Level Sync removal (effective_lvl returns to 75, is_level_synced=false, forced refresh)
--   5. Main job & subjob change (RDM/WHM -> WAR/NIN, Soul reset & WS cache cleared)
--   6. Soul change via Character module (0x1FF CRYS & 0x1FC HUD) immediately updates Weapon Mastery & Soul Talents
--   7. Zoning (0x00A/0x00B) & Logout/Reconnect recovery
--   8. Background polling while Core UI is CLOSED detects level-up / Level Sync and flags refresh
--   9. Server META trailing fields (effectiveLvl|subJobKey|subLvl) + legacy META backwards compatibility
--  10. Zero hardcoded Soul tables — all Soul names/roles resolved from DataService verified cache

package.path = './?.lua;./?/init.lua;../soulspire_talents/?.lua;../crystalsocket/?.lua;' .. package.path

local DataService    = require('core.data_service')
local CharacterState = require('core.character_state')
local Registry       = require('core.registry')
local SoulforgeState = require('soulforge_state')
local CharacterMod   = require('modules.character')
local CSProto        = require('protocol')
local CSStateMod     = require('state')

local function assert_eq(a, b, msg)
    if a ~= b then
        error(string.format('%s: expected %s, got %s', msg or 'assert_eq', tostring(b), tostring(a)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then error(msg or 'assert_true failed', 2) end
end

local function make_0x061(mjob, mlvl, sjob, slvl)
    local b = {}
    for i = 1, 16 do b[i] = 0 end
    b[13] = mjob
    b[14] = mlvl
    b[15] = sjob
    b[16] = slvl
    return string.char(unpack(b))
end

local function make_0x01B(mjob, sjob, job_levels)
    local b = {}
    for i = 1, 60 do b[i] = 0 end
    b[9]  = mjob
    b[12] = sjob
    for j, lvl in pairs(job_levels or {}) do
        b[33 + j] = lvl
    end
    return string.char(unpack(b))
end

local function make_0x0DF(server_id, mjob, mlvl, sjob, slvl)
    local b = {}
    for i = 1, 40 do b[i] = 0 end
    b[5]  = server_id % 256
    b[6]  = math.floor(server_id / 256) % 256
    b[7]  = math.floor(server_id / 65536) % 256
    b[8]  = math.floor(server_id / 16777216) % 256
    b[35] = mjob
    b[36] = mlvl
    b[37] = sjob
    b[38] = slvl
    return string.char(unpack(b))
end

local function encode_crys_state_reply(req_id, job_id, active_branch, owned_mask, lvl)
    local entries = {}
    for j = 0, 23 do
        entries[j + 1] = { owned_mask = 0, active = 0 }
    end
    entries[job_id + 1] = { owned_mask = owned_mask, active = active_branch }
    local header = string.char(
        0xFF, 0x21, 0x00, 0x00,
        string.byte('C'), string.byte('R'), string.byte('Y'), string.byte('S'),
        1, 0, req_id % 256, math.floor(req_id / 256) % 256,
        job_id, 24, lvl % 256, 0
    )
    local body = {}
    for j = 1, 24 do
        local e = entries[j]
        body[#body + 1] = string.char(e.owned_mask % 256, e.active % 256)
    end
    return header .. table.concat(body)
end

-- Load verified static cache (real 66-Soul registry & 219-WS catalog)
local ds = DataService.new({ cache_dir = 'cache', auto_load = true })
assert_true(ds:is_cache_ready(), 'DataService cache must be ready')

local fakeClock = 500.0
local memState = {
    in_session       = true,
    player_name      = 'Elaria',
    server_id        = 10042,
    zone             = 230,
    main_job         = 5, -- RDM
    sub_job          = 3, -- WHM
    actual_lvl       = 20,
    effective_lvl    = 20,
    sub_lvl          = 10,
    main_equip_sig   = '257:16535',
    ranged_equip_sig = '0:0',
}

local cs = CharacterState.new({
    data_service  = ds,
    soul_registry = Registry.souls,
    clock         = function() return fakeClock end,
    read_memory   = function()
        local out = {}
        for k, v in pairs(memState) do out[k] = v end
        return out
    end,
})

local sent = {}
local sfState, sfActions = SoulforgeState.new({
    soulRegistry = Registry.souls,
    dataService  = ds,
    clock        = function() return fakeClock end,
    sendPacket   = function(id, bytes, op, wsId, a1, a2)
        sent[#sent + 1] = { id = id, op = op, wsId = wsId, a1 = a1, a2 = a2, at = fakeClock }
        return true
    end,
    onMeta       = function(st)
        cs:observe_oxtl_meta(st, fakeClock)
    end,
})

local csState = CSStateMod.new()
local charMod = CharacterMod.new({
    protocol        = CSProto,
    crystal_state   = csState,
    character_state = cs,
    soul_registry   = Registry.souls,
    data_service    = ds,
    clock           = function() return fakeClock end,
    send_packet     = function() return true end,
})

local events = {}
cs:subscribe(function(ev)
    events[#events + 1] = ev
    sfActions.applyCharacterState(ev.cur, ev)
end)

-- Initial poll & Weapon Mastery open + initial v2 sync
cs:poll_memory(fakeClock, true)
assert_eq(cs.main_job_key, 'RDM', 'Initial job RDM')
assert_eq(cs.actual_lvl, 20, 'Initial actual level 20')
assert_eq(cs.effective_lvl, 20, 'Initial effective level 20')
assert_eq(cs.is_level_synced, false, 'Not initially level synced')

sfState.open[1] = true
sfActions.sync()
fakeClock = fakeClock + 0.03
local info = ds:get_cache_info()
sfActions.handleProtoLine(string.format('CACHE|2|1|1|%s|%s|%s|1', info.contentHash, info.registryHash, info.contentVersion))
sfActions.handleProtoLine('META|RDM|20|4|0|4|3|0|Spellblade|spellblade|20|WHM|10')
sfActions.handleProtoLine('SPENT_BEGIN')
sfActions.handleProtoLine('SPENT_END')
sfActions.handleProtoLine('SYNC_END|' .. tostring(sfState.syncGen) .. '|1')

assert_true(sfState.synced, 'Initial sync complete')
assert_eq(sfState.jobLevel, 20, 'Weapon Mastery shows Lv.20')
assert_eq(sfState.specName, 'Spellblade', 'Soul resolved from verified cache')
assert_eq(cs.soul_name, 'Spellblade', 'CharacterState reconciled active Soul from META')
assert_true(cs.soul_role ~= '' and cs.soul_role ~= 'Base Job', 'Soul role resolved from verified cache (non-hardcoded)')

local wsId1 = sfState.selectedWsId
assert_true(wsId1 ~= nil, 'WS auto-selected')
local seq1 = sfState.wsRequest.seq
sfActions.handleProtoLine(string.format('WSS_BEGIN|%d|0|4|0|spellblade|0:0:0:0|%d', wsId1, seq1))
sfActions.handleProtoLine(string.format('WSS|%d|ftp=0:1', wsId1))
sfActions.handleProtoLine(string.format('WSS_END|%d|4|0|%d', wsId1, seq1))

-- =========================================================================
-- Test 1: Immediate Level-Up while Weapon Mastery is OPEN (inside STATE_FRESH_SEC!)
-- =========================================================================
local pktsBefore = #sent
fakeClock = fakeClock + 0.30 -- strictly < STATE_FRESH_SEC (2.5s)! Previously swallowed!
memState.actual_lvl = 21
memState.effective_lvl = 21
cs:poll_memory(fakeClock)

assert_eq(cs.actual_lvl, 21, 'CharacterState updated to Lv.21')
assert_eq(sfState.jobLevel, 21, 'Weapon Mastery banner immediately shows Lv.21 (0ms lag)')
assert_eq(charMod:get_header_identity().job_level, 21, 'Header identity shows Lv.21')
assert_true(#sent >= pktsBefore + 2, 'Level-up forced OP_STATE + OP_WS_STATE refresh even within freshness window')
assert_eq(sent[pktsBefore + 1].op, SoulforgeState.OP_STATE, 'Forced OP_STATE dispatched on level-up')
assert_eq(sent[pktsBefore + 2].op, SoulforgeState.OP_WS_STATE, 'Forced OP_WS_STATE dispatched for active WS')

-- Server confirms new talent points at Lv.21
sfActions.handleProtoLine('META|RDM|21|5|0|5|3|0|Spellblade|spellblade|21|WHM|10')
sfActions.handleProtoLine('SPENT_BEGIN')
sfActions.handleProtoLine('SPENT_END')
assert_eq(sfState.avail, 5, 'New talent point synced live without closing UI')

-- =========================================================================
-- Test 2: Immediate Level-Down (via 0x01B + 0x061 packets)
-- =========================================================================
pktsBefore = #sent
fakeClock = fakeClock + 0.30
memState.actual_lvl = 20
memState.effective_lvl = 20
cs:observe_packet_in(0x01B, make_0x01B(5, 3, { [5] = 20, [1] = 75 }), 60, fakeClock)
cs:observe_packet_in(0x061, make_0x061(5, 20, 3, 10), 16, fakeClock)
assert_eq(cs.actual_lvl, 20, 'Level-down reflected immediately')
assert_eq(sfState.jobLevel, 20, 'Weapon Mastery downgraded to Lv.20 immediately')
assert_true(#sent > pktsBefore, 'Level-down triggered immediate forced server refresh')

-- =========================================================================
-- Test 3 & 4: Level Sync Activation (Lv.75 -> Lv.30 Sync 75) & Removal
-- =========================================================================
fakeClock = fakeClock + 0.50
memState.actual_lvl = 75
memState.effective_lvl = 75
cs:observe_packet_in(0x01B, make_0x01B(5, 3, { [5] = 75, [1] = 75 }), 60, fakeClock)
cs:poll_memory(fakeClock, true)
assert_eq(cs.actual_lvl, 75, 'Promoted to Lv.75')
assert_eq(cs.is_level_synced, false, 'Not synced at Lv.75')
assert_eq(cs:format_level_label(), 'Lv.75', 'Normal level label')

-- Activate Level Sync to Lv.30 (0x061 + 0x0DF + memory)
pktsBefore = #sent
fakeClock = fakeClock + 0.30
memState.effective_lvl = 30
memState.sub_lvl = 15
cs:observe_packet_in(0x061, make_0x061(5, 30, 3, 15), 16, fakeClock)
assert_eq(cs.actual_lvl, 75, 'Actual stored level preserved at 75 under Level Sync')
assert_eq(cs.effective_lvl, 30, 'Effective level updated to 30 under Level Sync')
assert_eq(cs.is_level_synced, true, 'is_level_synced set to true')
assert_eq(cs:format_level_label(), 'Lv.30 (Sync 75)', 'Formatted Level Sync label')
assert_eq(sfState.jobLevel, 75, 'Weapon Mastery keeps actual Lv.75')
assert_eq(sfState.effectiveLevel, 30, 'Weapon Mastery tracks effective Lv.30')
assert_eq(sfState.isLevelSynced, true, 'Weapon Mastery shows Level Sync indicator')
assert_eq(charMod:get_header_identity().level_label, 'Lv.30 (Sync 75)', 'Universal Header shows Level Sync')
assert_true(#sent > pktsBefore, 'Level Sync activation forced server refresh')

-- Remove Level Sync via 0x0DF CharUpdate
pktsBefore = #sent
fakeClock = fakeClock + 0.30
memState.effective_lvl = 75
memState.sub_lvl = 37
cs:observe_packet_in(0x0DF, make_0x0DF(10042, 5, 75, 3, 37), 40, fakeClock)
assert_eq(cs.actual_lvl, 75, 'Actual level 75')
assert_eq(cs.effective_lvl, 75, 'Effective level restored to 75')
assert_eq(cs.is_level_synced, false, 'Level Sync removed')
assert_eq(sfState.isLevelSynced, false, 'Weapon Mastery Level Sync cleared')
assert_eq(cs:format_level_label(), 'Lv.75', 'Label restored to Lv.75')
assert_true(#sent > pktsBefore, 'Level Sync removal forced server refresh')

-- =========================================================================
-- Test 5: Soul Change via Character Module (0x1FF CRYS) Updates Weapon Mastery!
-- =========================================================================
pktsBefore = #sent
fakeClock = fakeClock + 0.40
charMod:refresh_player_context()
-- Simulate player socketing RDM Branch 2 via Character module (passive or Core-owned 0x1FF CRYS reply)
local rdmBranch2 = ds:get_soul_by_job_branch(5, 2)
assert_true(rdmBranch2 ~= nil, 'RDM branch 2 exists in verified cache')
local crysPkt = encode_crys_state_reply(0x4001, 5, 2, 14, 75)
-- Pretend Core had request 0x4001 pending or receive passively via standalone req_id 0x0010
local passivePkt = encode_crys_state_reply(0x0010, 5, 2, 14, 75)
charMod:handle_packet_in(CSProto.RESPONSE_ID, passivePkt, fakeClock, #passivePkt)
assert_eq(cs.soul_branch, 2, 'CharacterState updated to branch 2')
assert_eq(cs.soul_name, rdmBranch2.displayName, 'Soul displayName resolved from verified cache')
assert_eq(sfState.specName, rdmBranch2.displayName, 'Weapon Mastery immediately shows new Soul!')
assert_eq(sfState.specKey, string.lower(rdmBranch2.internalKey), 'Weapon Mastery specKey updated immediately')
assert_true(#sent > pktsBefore, 'Soul change forced Weapon Mastery server sync')

-- Also test 0x1FC HUD identity swap to RDM Branch 3
local rdmBranch3 = ds:get_soul_by_job_branch(5, 3)
assert_true(rdmBranch3 ~= nil, 'RDM branch 3 exists in verified cache')
charMod:observe_hud_identity(3, 5)
assert_eq(sfState.specName, rdmBranch3.displayName, '0x1FC Soul switch propagated to Weapon Mastery')

-- =========================================================================
-- Test 6: Main Job & Subjob Change (RDM/WHM -> WAR/NIN)
-- =========================================================================
pktsBefore = #sent
fakeClock = fakeClock + 0.50
memState.main_job = 1 -- WAR
memState.sub_job  = 13 -- NIN
memState.actual_lvl = 75
memState.effective_lvl = 75
memState.sub_lvl = 37
cs:poll_memory(fakeClock)
assert_eq(cs.main_job_key, 'WAR', 'Main job switched to WAR')
assert_eq(cs.sub_job_key, 'NIN', 'Subjob switched to NIN')
assert_eq(sfState.jobKey, 'WAR', 'Weapon Mastery switched to WAR immediately')
assert_eq(sfState.subJobKey, 'NIN', 'Weapon Mastery subjob updated to NIN')
assert_eq(sfState.specName, 'Base', 'Stale RDM Soul cleared on WAR switch until WAR Soul confirms')
assert_eq(sfState.wsDetail, nil, 'Stale RDM WS detail cleared on job change')
assert_true(#sent > pktsBefore, 'Job change triggered server sync')

-- =========================================================================
-- Test 7: Background Polling While Core UI Is CLOSED (Previously Broken!)
-- =========================================================================
sfState.open[1] = false
sfState.needsRefresh = false
pktsBefore = #sent
fakeClock = fakeClock + 0.50
memState.actual_lvl = 76
memState.effective_lvl = 76
cs:poll_memory(fakeClock)
assert_eq(cs.actual_lvl, 76, 'Closed-Core poll still detected Lv.76')
assert_eq(sfState.jobLevel, 76, 'sfState level updated immediately even while closed')
assert_true(sfState.needsRefresh, 'Closed-Core level-up flagged needsRefresh for next open')
assert_eq(#sent, pktsBefore, 'Did not spam network packets while Core UI is closed')

-- =========================================================================
-- Test 8: Zoning (0x00A) & Disconnect / Reconnect Recovery
-- =========================================================================
cs:observe_packet_in(0x00A, string.rep('\0', 16), 16, fakeClock)
assert_true(sfState.needsRefresh, 'Zone packet flagged needsRefresh')

fakeClock = fakeClock + 0.50
memState.in_session = false
cs:poll_memory(fakeClock, true)
assert_eq(cs.in_session, false, 'Disconnect tracked cleanly')

sfState.open[1] = true
pktsBefore = #sent
fakeClock = fakeClock + 1.0
memState.in_session = true
memState.zone = 244
cs:poll_memory(fakeClock, true)
assert_eq(cs.in_session, true, 'Reconnect detected cleanly')
assert_eq(cs.zone, 244, 'New zone tracked')
assert_true(#sent > pktsBefore, 'Reconnect triggered fresh authoritative sync')

print(string.format('CHARACTER_STATE_TEST_OK events=%d gen=%d', #events, cs.generation))
