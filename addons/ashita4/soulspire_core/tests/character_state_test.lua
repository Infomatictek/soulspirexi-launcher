-- SoulspireXI Core: Universal Character State Service Regression & Performance Suite
-- Covers all 14 Phase-9 regression scenarios + Phase-8 diagnostics & performance checks.

package.path = './?.lua;./?/init.lua;../soulspire_talents/?.lua;../crystalsocket/?.lua;' .. package.path

local DataService    = require('core.data_service')
local CharacterState = require('core.character_state')
local CoreIPC        = require('core.ipc')
local sha256         = require('core.sha256')
local SoulforgeState = require('soulforge_state')
local CharacterMod   = require('modules.character')
local WeaponMastery  = require('modules.weapon_mastery')
local SoulTalents    = require('modules.soul_talents')
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

local function build_crys_state_packet(req_id, job_id, level, result, owned_mask, active_branch)
    local out = {
        0xFF, 0x21, 0x00, 0x00,
        0x43, 0x52, 0x59, 0x53, -- "CRYS"
        1,
        result or 0,
        req_id % 256, math.floor(req_id / 256) % 256,
        job_id or 0,
        24,
        level or 1,
        0,
    }
    for j = 0, 23 do
        if j == job_id then
            out[#out + 1] = owned_mask or 0
            out[#out + 1] = active_branch or 0
        else
            out[#out + 1] = 0
            out[#out + 1] = 0
        end
    end
    local chars = {}
    for i = 1, #out do chars[i] = string.char(out[i]) end
    return table.concat(chars)
end

local function build_0x061_packet(main_job, main_lvl, sub_job, sub_lvl, nation)
    local bytes = {}
    for i = 1, 96 do bytes[i] = '\0' end
    bytes[1]  = string.char(0x61)
    bytes[13] = string.char(main_job)
    bytes[14] = string.char(main_lvl)
    bytes[15] = string.char(sub_job or 0)
    bytes[16] = string.char(sub_lvl or 0)
    bytes[81] = string.char(nation or 0)
    return table.concat(bytes)
end

local function build_0x050_packet(slot_idx, equip_slot, bag)
    local bytes = {}
    for i = 1, 12 do bytes[i] = '\0' end
    bytes[1] = string.char(0x50)
    bytes[5] = string.char(slot_idx or 1)
    bytes[6] = string.char(equip_slot or 0)
    bytes[7] = string.char(bag or 0)
    return table.concat(bytes)
end

local function make_dummy_sf_ui()
    return {
        MAX_SPEC_WS_SLOTS = 4,
        getTreeGrid = function(d)
            if not d or not d.nodes or #d.nodes == 0 then return {} end
            return { { tier = 1, nodes = d.nodes } }
        end,
        isEvolutionTree = function() return false end,
        isSkillchainNode = function(n) return (tonumber(n.scTier) or 0) > 0 end,
        getSkillchainSlots = function() return {} end,
        evaluateNode = function(_st, _d, n)
            return { canUpgrade = n.canLearn == true, canRefund = (n.rank or 0) > 0 }
        end,
        getInvestedWeaponskills = function(st)
            local list = {}
            for wid, pts in pairs(st.spentByWs or {}) do
                if pts > 0 then list[#list + 1] = { id = wid, spent = pts, name = 'WS #' .. tostring(wid) } end
            end
            return list
        end,
        resetTransientState = function() end,
        drawEmbedded = function() end,
    }
end

-- Create a full wired Core test harness with deterministic clock & packet capture
local function make_harness(opts)
    opts = opts or {}
    local now = opts.startTime or 100.0
    local clock = function() return now end
    local advance = function(dt) now = now + dt; return now end

    local ds = opts.dataService or DataService.new({ cache_dir = 'cache', auto_load = true, clock = clock })
    local runtime = opts.runtime or {
        inSession   = true,
        characterId = 1001,
        name        = 'Rin',
        targetIndex = 1,
        mainJob     = 1, -- WAR
        mainLevel   = 1,
        subJob      = 2, -- MNK
        subLevel    = 1,
        nation      = 1,
        zone        = 230,
        isDead      = false,
        equipment   = {
            mainHand = { bag = 0, slot = 1, itemId = 16640, skillId = 5 }, -- Axe
            subHand  = { bag = 0, slot = 0, itemId = 0, skillId = 0 },
            ranged   = { bag = 0, slot = 0, itemId = 0, skillId = 0 },
        },
    }

    local sent_oxtl = {}
    local sent_crys = {}

    local cs = CharacterState.new({
        clock                = clock,
        dataService          = ds,
        ipc                  = CoreIPC,
        runtimeReader        = function() return runtime end,
        reconcileIntervalSec = opts.reconcileIntervalSec or 1.0,
        coalesceWindowSec    = opts.coalesceWindowSec or 0.15,
        requestTimeoutSec    = opts.requestTimeoutSec or 4.5,
        maxRetries           = opts.maxRetries or 2,
    })

    local crys_state = csStateMod.new()
    local char_mod = CharacterMod.new({
        protocol        = csProtocol,
        crystal_state   = crys_state,
        data_service    = ds,
        character_state = cs,
        clock           = clock,
        send_packet     = function(pkt)
            sent_crys[#sent_crys + 1] = { at = now, pkt = pkt, decoded = csProtocol.decode_packet(pkt) }
            return true
        end,
    })

    local sf_state, sf_actions = SoulforgeState.new({
        dataService    = ds,
        characterState = cs,
        clock          = clock,
        sendPacket     = function(pid, bytes, op, wsId, a1, a2)
            sent_oxtl[#sent_oxtl + 1] = { at = now, id = pid, bytes = bytes, op = op, wsId = wsId, a1 = a1, a2 = a2 }
            return true
        end,
    })

    local dummy_ui = make_dummy_sf_ui()
    local wm_mod = WeaponMastery.new(sf_state, sf_actions, dummy_ui, { character_state = cs })
    local st_mod = SoulTalents.new(sf_state, sf_actions, dummy_ui, { data_service = ds, character_state = cs })

    return {
        clock      = clock,
        advance    = advance,
        set_time   = function(t) now = t end,
        ds         = ds,
        cs         = cs,
        runtime    = runtime,
        set_runtime = function(r) runtime = r end,
        char_mod   = char_mod,
        crys_state = crys_state,
        sf_state   = sf_state,
        sf_actions = sf_actions,
        wm_mod     = wm_mod,
        st_mod     = st_mod,
        sent_oxtl  = sent_oxtl,
        sent_crys  = sent_crys,
    }
end

-- ---------------------------------------------------------------------------
-- Pre-check: Streaming SHA-256 parity & Cooperative <=4ms Talents Warmup
-- ---------------------------------------------------------------------------
do
    local sample = string.rep('SoulspireXI-CharacterState-2026!', 500)
    local h = sha256.new()
    for i = 1, #sample, 137 do
        h:update(string.sub(sample, i, i + 136))
    end
    assert_eq(h:digest(), sha256.digest(sample), 'Incremental SHA-256 matches one-shot digest')

    local ds = DataService.new({ cache_dir = 'cache', auto_load = true })
    assert_true(ds:is_cache_ready(), 'Eager cache ready')
    assert_true(not ds:is_talents_warm(), 'Talents not synchronously loaded at startup')
    local steps = 0
    local max_hash_step_ms = 0
    while not ds:is_talents_warm() and steps < 2000 do
        local stage_before = ds:get_warmup_state().stage
        local t0 = os.clock()
        ds:step_warmup(4.0)
        local dt = (os.clock() - t0) * 1000
        if stage_before == 'hashing' and dt > max_hash_step_ms then
            max_hash_step_ms = dt
        end
        steps = steps + 1
    end
    assert_true(ds:is_talents_warm(), 'Cooperative warmup completes talents.json')
    assert_true(steps >= 2, 'Cooperative warmup yields across frames (steps=' .. tostring(steps) .. ')')
    print(string.format('[BENCH] Cooperative talents.json warmup: %d frames, max_hash_step=%.2fms', steps, max_hash_step_ms))
end

-- ---------------------------------------------------------------------------
-- Scenario 1 & 5: WAR Lv.1 -> Lv.10 -> Lv.20 + Character & Weapon Mastery Parity
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.cs:tick(H.clock()) -- initial login observation (Rin, WAR Lv.1)
    H.advance(0.2)
    H.cs:tick(H.clock())

    -- Server confirms WAR Lv.1 for both CRYS and OXTL
    assert_true(#H.sent_crys >= 1, 'Initial CRYS query dispatched')
    local cReq = H.crys_state.pending and H.crys_state.pending.request_id or 0x4000
    H.char_mod:handle_packet_in(0x1FF, build_crys_state_packet(cReq, 1, 1, 0, 0, 0), H.clock())
    H.wm_mod:on_open()
    H.sf_actions.handleProtoLine('CACHE|2|1|1|||')
    H.sf_actions.handleProtoLine('META|WAR|1|1|0|1|5|0|Base|base')
    H.sf_actions.handleProtoLine('SPENT_BEGIN')
    H.sf_actions.handleProtoLine('SPENT_END')
    H.sf_actions.handleProtoLine('SYNC_END|' .. tostring(H.sf_state.syncGen) .. '|1')

    assert_eq(H.char_mod:get_header_identity().job_level, 1, 'Character starts at WAR Lv.1')
    assert_eq(H.sf_state.jobLevel, 1, 'Weapon Mastery starts at WAR Lv.1')

    -- Change Rin WAR Lv.1 -> Lv.10 (via 0x061 Char Stats packet, e.g. GM !setplayerlevel)
    H.runtime.mainLevel = 10
    H.cs:onPacketIn(0x061, build_0x061_packet(1, 10, 2, 5, 1), 96, H.clock())

    -- IMMEDIATELY (before ANY server OXTL/CRYS reply arrives!), both Character & Weapon Mastery show Lv.10!
    local charHdr = H.char_mod:get_header_identity()
    local wmHdr   = CharacterState.Selectors.selectWeaponMasteryHeader(H.cs:getSnapshot())
    assert_eq(charHdr.job_level, 10, 'Character displays WAR Lv.10 immediately')
    assert_eq(H.sf_state.jobLevel, 10, 'Weapon Mastery displays WAR Lv.10 immediately')
    assert_eq(wmHdr.jobLevel, 10, 'WeaponMastery selector displays WAR Lv.10 immediately')
    assert_eq(wmHdr.confirmedLevel, 1, 'Server-confirmed level remains Lv.1 until server confirms')
    assert_true(wmHdr.levelMismatch, 'levelMismatch flagged while awaiting server confirmation')

    -- Coalesce window drains ONE server refresh -> server confirms Lv.10 + 10 talent points
    H.advance(0.2)
    local oxtlBefore = #H.sent_oxtl
    H.cs:tick(H.clock())
    assert_eq(#H.sent_oxtl, oxtlBefore + 1, 'Level change coalesced into single progression sync')
    H.sf_actions.handleProtoLine('META|WAR|10|10|0|10|5|0|Base|base')
    H.sf_actions.handleProtoLine('SPENT_BEGIN')
    H.sf_actions.handleProtoLine('SPENT_END')
    H.sf_actions.handleProtoLine('SYNC_END|' .. tostring(H.sf_state.syncGen) .. '|1')

    wmHdr = CharacterState.Selectors.selectWeaponMasteryHeader(H.cs:getSnapshot())
    assert_eq(wmHdr.confirmedLevel, 10, 'Server-confirmed level updated to Lv.10')
    assert_eq(wmHdr.availPoints, 10, 'Authoritative talent points updated to 10')
    assert_true(not wmHdr.levelMismatch, 'levelMismatch cleared after server confirmation')

    -- Advance WAR Lv.10 -> Lv.20 via bounded runtime reconciliation (even without 0x061!)
    H.runtime.mainLevel = 20
    H.advance(1.1)
    H.cs:tick(H.clock())
    assert_eq(H.char_mod:get_header_identity().job_level, 20, 'Character shows WAR Lv.20')
    assert_eq(H.sf_state.jobLevel, 20, 'Weapon Mastery shows WAR Lv.20 identically')
    print('[PASS] Scenarios 1 & 5: WAR Lv.1 -> Lv.10 -> Lv.20 Character/WeaponMastery parity')
end

-- ---------------------------------------------------------------------------
-- Scenario 2: Job and Subjob Changes
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    -- Confirm initial WAR Soul state so soul domain is fresh before job change
    local cReq = H.crys_state.pending.request_id
    H.char_mod:handle_packet_in(0x1FF, build_crys_state_packet(cReq, 1, 1, 0, 0, 0), H.clock())
    assert_eq(H.cs:getFreshness('soul').state, 'fresh', 'Soul domain fresh before job change')

    -- Change WAR/MNK -> PLD/WAR Lv.35/17
    H.runtime.mainJob   = 7 -- PLD
    H.runtime.mainLevel = 35
    H.runtime.subJob    = 1 -- WAR
    H.runtime.subLevel  = 17
    H.cs:onPacketIn(0x061, build_0x061_packet(7, 35, 1, 17, 0), 96, H.clock())

    local hdr = CharacterState.Selectors.selectHeaderIdentity(H.cs:getSnapshot())
    assert_eq(hdr.job_key, 'PLD', 'Main job switched to PLD')
    assert_eq(hdr.job_level, 35, 'Main level updated to 35')
    assert_eq(hdr.sub_job_key, 'WAR', 'Subjob switched to WAR')
    assert_eq(hdr.sub_level, 17, 'Subjob level updated to 17')
    assert_eq(H.sf_state.jobKey, 'PLD', 'Weapon Mastery jobKey updated immediately to PLD')
    assert_eq(H.sf_state.jobLevel, 35, 'Weapon Mastery jobLevel updated immediately to 35')
    assert_eq(H.cs:getFreshness('soul').state, 'stale', 'Soul domain invalidated on job change')
    print('[PASS] Scenario 2: Job and subjob changes propagate cleanly')
end

-- ---------------------------------------------------------------------------
-- Scenario 3: Soul Selection & Socket Changes Propagate to All Modules
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.runtime.mainLevel = 15
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    local cReq = H.crys_state.pending.request_id
    H.char_mod:handle_packet_in(0x1FF, build_crys_state_packet(cReq, 1, 15, 0, 14, 0), H.clock()) -- owns branches 1,2,3; active=0

    -- Open Weapon Mastery & confirm Base state
    H.wm_mod:on_open()
    H.sf_actions.handleProtoLine('META|WAR|15|15|0|15|5|0|Base|base')
    H.sf_actions.handleProtoLine('SPENT_BEGIN')
    H.sf_actions.handleProtoLine('SPENT_END')
    H.sf_actions.handleProtoLine('SYNC_END|' .. tostring(H.sf_state.syncGen) .. '|1')

    -- Socket WAR Branch 2 (Berserker) via Character module
    local okSel = H.char_mod:select_branch(2)
    assert_true(okSel, 'Soul socket request sent')
    assert_true(H.cs:getPendingTransaction('soul') ~= nil, 'Pending soul_socket transaction tracked')
    assert_eq(H.cs:getSnapshot().effective.soulBranch, 0, 'No optimistic Soul grant before server confirmation')

    local selReq = H.crys_state.pending.request_id
    local oxtlBefore = #H.sent_oxtl
    H.char_mod:handle_packet_in(0x1FF, build_crys_state_packet(selReq, 1, 15, 0, 14, 2), H.clock())

    assert_true(H.cs:getPendingTransaction('soul') == nil, 'Pending soul_socket transaction confirmed')
    assert_eq(H.cs:getSnapshot().effective.soulBranch, 2, 'CharacterState reflects confirmed Berserker')
    assert_eq(H.sf_state.specName, H.cs:getSnapshot().effective.soulName, 'Weapon Mastery receives updated Soul name immediately')
    assert_eq(H.cs:getFreshness('progression').state, 'stale', 'Progression invalidated on Soul change')
    H.advance(0.2); H.cs:tick(H.clock())
    assert_eq(#H.sent_oxtl, oxtlBefore + 1, 'Soul change triggers single coalesced progression sync')
    print('[PASS] Scenario 3: Soul selection & socket propagation')
end

-- ---------------------------------------------------------------------------
-- Scenario 4: Equipment Changes
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    H.wm_mod:on_open()
    H.sf_actions.handleProtoLine('META|WAR|10|10|0|10|5|0|Base|base')
    H.sf_actions.handleProtoLine('SPENT_BEGIN'); H.sf_actions.handleProtoLine('SPENT_END')
    H.sf_actions.handleProtoLine('SYNC_END|' .. tostring(H.sf_state.syncGen) .. '|1')

    -- Swap Axe (skill 5) -> Great Axe (skill 6) via 0x050 Equip List packet
    H.runtime.equipment.mainHand = { bag = 0, slot = 2, itemId = 18200, skillId = 6 }
    local oxtlBefore = #H.sent_oxtl
    H.cs:onPacketIn(0x050, build_0x050_packet(2, 0, 0), 12, H.clock())
    local eqCtx = CharacterState.Selectors.selectEquipmentContext(H.cs:getSnapshot())
    assert_eq(eqCtx.mainHand.itemId, 18200, 'Equipment context reflects new Main Hand itemId')
    assert_eq(eqCtx.mainHand.skillId, 6, 'Equipment context reflects Great Axe skillId')
    H.advance(0.2); H.cs:tick(H.clock())
    assert_eq(#H.sent_oxtl, oxtlBefore + 1, 'Equipment weapon change coalesces single progression refresh')
    print('[PASS] Scenario 4: Equipment changes update WS eligibility context')
end

-- ---------------------------------------------------------------------------
-- Scenario 6: Repeated Tab Switching Sends ZERO Extra Network Requests
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.runtime.mainLevel = 10
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    -- Confirm both Soul and Progression domains
    local cReq = H.crys_state.pending.request_id
    H.char_mod:handle_packet_in(0x1FF, build_crys_state_packet(cReq, 1, 10, 0, 14, 2), H.clock())
    H.wm_mod:on_open()
    H.sf_actions.handleProtoLine('META|WAR|10|10|0|10|5|0|Berserker|berserker')
    H.sf_actions.handleProtoLine('SPENT_BEGIN'); H.sf_actions.handleProtoLine('SPENT_END')
    H.sf_actions.handleProtoLine('SYNC_END|' .. tostring(H.sf_state.syncGen) .. '|1')
    -- Complete initial auto-selected WS detail
    if H.sf_state.wsRequest then
        local wid = H.sf_state.wsRequest.wsId
        local seq = H.sf_state.wsRequest.seq
        H.sf_actions.handleProtoLine(string.format('WSS_BEGIN|%d|0|10|0|berserker|0:0:0:0|%d', wid, seq))
        H.sf_actions.handleProtoLine(string.format('WSS_END|%d|10|0|%d', wid, seq))
    end

    local oxtlBefore = #H.sent_oxtl
    local crysBefore = #H.sent_crys

    -- Switch tabs 20 times rapidly!
    for _ = 1, 20 do
        H.char_mod:on_open()
        H.wm_mod:on_open()
        H.st_mod:on_open()
        H.advance(0.1)
        H.cs:tick(H.clock())
    end

    assert_eq(#H.sent_oxtl, oxtlBefore, '20 tab switches sent ZERO extra OXTL packets')
    assert_eq(#H.sent_crys, crysBefore, '20 tab switches sent ZERO extra CRYS packets')
    print('[PASS] Scenario 6: 20 repeated tab switches produced 0 network requests')
end

-- ---------------------------------------------------------------------------
-- Scenario 7: Talent Invest, Unlock, Refund, Respec & Rejection (No Optimistic Grant)
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    H.wm_mod:on_open()
    H.sf_actions.handleProtoLine('META|WAR|20|20|0|20|2|0|Base|base')
    H.sf_actions.handleProtoLine('SPENT_BEGIN'); H.sf_actions.handleProtoLine('SPENT_END')
    H.sf_actions.handleProtoLine('SYNC_END|' .. tostring(H.sf_state.syncGen) .. '|1')

    -- Load WS #16 (Wasp Sting)
    H.sf_actions.requestWS(16, false, { force = true })
    local seq = H.sf_state.wsRequest.seq
    local tree16 = H.ds:get_ws_tree(16, 'generic')
    local firstNode = tree16.nodes[1]
    H.sf_actions.handleProtoLine(string.format('WSS_BEGIN|16|0|20|0|base|0:0:0:0|%d', seq))
    H.sf_actions.handleProtoLine(string.format('WSS|16|%s=0:1', firstNode.key))
    H.sf_actions.handleProtoLine(string.format('WSS_END|16|20|0|%d', seq))

    local revBefore = H.cs:getSnapshot().confirmed.progression.revision
    local oxtlCountBefore = #H.sent_oxtl
    -- Invest 1 point -> must track pending tx and NOT optimistically bump rank or deduct points
    assert_true(H.sf_actions.investNode(16, firstNode), 'investNode sent')
    assert_true(H.cs:getPendingTransaction('progression') ~= nil, 'Pending invest tx tracked')
    assert_eq(H.sf_state.wsDetail.byKey[firstNode.key].rank, 0, 'Rank NOT optimistically incremented before confirmation')
    assert_eq(H.sf_state.avail, 20, 'Points NOT optimistically spent before confirmation')

    -- Server confirms META + compact WSS delta (NO full OP_CACHE_SYNC triggered!)
    H.sf_actions.handleProtoLine('META|WAR|20|19|1|20|2|0|Base|base')
    H.sf_actions.handleProtoLine('WSS_BEGIN|16|1|19|1|base|0:0:0:0|0')
    H.sf_actions.handleProtoLine(string.format('WSS|16|%s=1:1', firstNode.key))
    H.sf_actions.handleProtoLine('WSS_END|16|19|1|0')

    assert_true(H.cs:getPendingTransaction('progression') == nil, 'Invest tx confirmed')
    assert_eq(H.sf_state.wsDetail.byKey[firstNode.key].rank, 1, 'Rank updated on server confirmation')
    assert_eq(H.sf_state.avail, 19, 'Available points updated to 19')
    assert_true(H.sf_state.unlockedByWs[16], 'WS #16 unlocked confirmed')
    assert_true(H.cs:getSnapshot().confirmed.progression.revision > revBefore, 'Progression revision incremented')
    assert_eq(#H.sent_oxtl, oxtlCountBefore + 1, 'No redundant full resync after invest confirmation')

    -- Refund node
    assert_true(H.sf_actions.refundNode(16, firstNode), 'refundNode sent')
    H.sf_actions.handleProtoLine('META|WAR|20|20|0|20|2|0|Base|base')
    H.sf_actions.handleProtoLine('WSS_BEGIN|16|0|20|0|base|0:0:0:0|0')
    H.sf_actions.handleProtoLine(string.format('WSS|16|%s=0:1', firstNode.key))
    H.sf_actions.handleProtoLine('WSS_END|16|20|0|0')
    assert_eq(H.sf_state.wsDetail.byKey[firstNode.key].rank, 0, 'Refund confirmed')
    assert_eq(H.sf_state.avail, 20, 'Refund restored 20 available points')

    -- Rejection recovery on ERR
    assert_true(H.sf_actions.investNode(16, firstNode), 'investNode for rejection test')
    H.sf_actions.handleProtoLine('ERR|Insufficient job level.')
    assert_true(H.cs:getPendingTransaction('progression') == nil, 'Rejected tx cleared')
    assert_eq(H.cs:getSnapshot().transactions.last.state, 'rejected', 'Last tx recorded as rejected')
    assert_eq(H.sf_state.rejectedMsg, 'Insufficient job level.', 'Actionable error preserved')

    -- Respec (resetAll)
    assert_true(H.sf_actions.resetAll(), 'resetAll sent')
    assert_true(H.cs:getPendingTransaction('progression') ~= nil, 'resetAll tx tracked')
    H.sf_actions.handleProtoLine('META|WAR|20|20|0|20|2|0|Base|base')
    assert_true(H.cs:getPendingTransaction('progression') == nil, 'resetAll confirmed')
    print('[PASS] Scenario 7: Talent invest, unlock, refund, respec, and rejection recovery')
end

-- ---------------------------------------------------------------------------
-- Scenario 8: Delayed, Duplicated, Missing & Out-of-Order Server Responses
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())

    -- Send sync #1 (gen=1), then force sync #2 (gen=2); stale SYNC_END|1 must be dropped!
    H.sf_actions.sync(false, { force = true })
    local gen1 = H.sf_state.syncGen
    H.sf_actions.sync(false, { force = true })
    local gen2 = H.sf_state.syncGen
    assert_true(gen2 ~= gen1, 'Sync generation incremented')
    local staleBefore = H.ds.metrics.stale_dropped
    H.sf_actions.handleProtoLine('SYNC_END|' .. tostring(gen1) .. '|1')
    assert_eq(H.ds.metrics.stale_dropped, staleBefore + 1, 'Stale SYNC_END dropped')
    assert_true(not H.sf_state.synced, 'Stale SYNC_END did not mark state synced')

    -- Out-of-order WSS response with stale seq must be dropped
    H.sf_actions.requestWS(16, false, { force = true })
    local seq1 = H.sf_state.wsRequest.seq
    H.sf_actions.requestWS(16, false, { force = true })
    local seq2 = H.sf_state.wsRequest.seq
    H.sf_actions.handleProtoLine(string.format('WSS_BEGIN|16|9|1|1|base|0:0:0:0|%d', seq1))
    H.sf_actions.handleProtoLine(string.format('WSS_END|16|1|1|%d', seq1))
    assert_true(H.ds.metrics.stale_dropped >= staleBefore + 2, 'Out-of-order WSS seq dropped')
    assert_true(H.sf_state.wsRequest ~= nil and H.sf_state.wsRequest.seq == seq2, 'Current WS request preserved')

    -- Missing server response -> bounded backoff retries -> explicit error state (never stuck loading!)
    for _ = 1, 20 do
        H.advance(2.5)
        H.sf_actions.tick(H.clock())
        H.cs:tick(H.clock())
    end
    assert_eq(H.sf_state.syncState, 'error', 'Missing sync response terminates cleanly in error state')
    assert_true(H.sf_state.lastSyncError ~= nil, 'Actionable sync error message present')
    assert_true(H.sf_state.wsRequest == nil and H.sf_state.wsError ~= nil, 'Missing WS response terminates cleanly')
    print('[PASS] Scenario 8: Stale/out-of-order rejection & bounded timeout recovery')
end

-- ---------------------------------------------------------------------------
-- Scenario 9: Zoning During a Pending Request
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    local zGen1 = H.cs:getSnapshot().session.zoneGeneration
    -- Enter zone out (0x00B) while request is pending
    H.cs:onPacketIn(0x00B, '', 0, H.clock())
    assert_true(H.cs:getSnapshot().session.zoning, 'Zoning state entered on 0x00B')
    -- Late response tagged with old zoneGen must be rejected
    local okLate, whyLate = H.cs:applyProgressionConfirmation({ jobKey = 'WAR', jobLevel = 5, zoneGen = zGen1 })
    assert_true(not okLate and whyLate == 'stale_zone', 'Old-zone response rejected cleanly')
    -- Zone in (0x00A) clears zoning and schedules fresh sync
    H.cs:onPacketIn(0x00A, '', 0, H.clock())
    assert_true(not H.cs:getSnapshot().session.zoning, 'Zoning state cleared on 0x00A')
    assert_true(H.cs:getSnapshot().session.zoneGeneration > zGen1, 'zoneGeneration incremented across zone')
    print('[PASS] Scenario 9: Zoning during pending request drops stale reply & resyncs')
end

-- ---------------------------------------------------------------------------
-- Scenario 10: Logout & Login With a Different Character (Zero Cross-Session Leakage)
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.runtime.mainLevel = 42
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    local cReq = H.crys_state.pending.request_id
    H.char_mod:handle_packet_in(0x1FF, build_crys_state_packet(cReq, 1, 42, 0, 14, 2), H.clock())
    H.st_mod:observe_hud_line('berserker|rage=80', H.clock())
    local genRin = H.cs:getSnapshot().session.generation

    -- Logout (0x00D) and login as Kael (characterId 2002, WHM Lv.12)
    H.cs:onPacketOut(0x00D, '', 0, H.clock())
    assert_true(H.cs:getSnapshot().session.generation > genRin, 'Session generation incremented on logout')
    assert_eq(H.st_mod.hud_soul_key, '', 'HUD telemetry cleared on logout')
    assert_eq(H.cs:getSnapshot().confirmed.soul.activeBranch, 0, 'Confirmed Soul cleared on logout')

    H.set_runtime({
        inSession   = true,
        characterId = 2002,
        name        = 'Kael',
        targetIndex = 2,
        mainJob     = 3, -- WHM
        mainLevel   = 12,
        subJob      = 20, -- SCH
        subLevel    = 6,
        zone        = 235,
    })
    H.advance(1.1); H.cs:tick(H.clock())
    local snapKael = H.cs:getSnapshot()
    assert_eq(snapKael.effective.name, 'Kael', 'New character name loaded')
    assert_eq(snapKael.effective.mainJobKey, 'WHM', 'New character job WHM loaded')
    assert_eq(snapKael.effective.mainLevel, 12, 'New character level 12 loaded')
    assert_eq(snapKael.confirmed.soul.activeBranch, 0, 'No stale Berserker branch leaked to Kael')
    assert_eq(H.sf_state.jobKey, 'WHM', 'Weapon Mastery reflects Kael WHM')
    assert_eq(H.sf_state.jobLevel, 12, 'Weapon Mastery reflects Kael Lv.12')
    print('[PASS] Scenario 10: Logout & character switch isolates all session state')
end

-- ---------------------------------------------------------------------------
-- Scenario 11 & 13: Addon Reload, Reconnect & Legacy Addon Packet Interception
-- ---------------------------------------------------------------------------
do
    CoreIPC.reset_for_tests()
    -- Load standalone addons BEFORE soulspire_core (worst-case legacy load order!)
    local tokTal  = CoreIPC.register_listener('OXTL', 'soulspire_talents')
    local tokCrys = CoreIPC.register_listener('CRYS', 'crystalsocket')
    local tokHud  = CoreIPC.register_listener('OXHUD', 'soulspire_soulhud')
    local tokCoreOxtl = CoreIPC.register_listener('OXTL', 'soulspire_core')
    local tokCoreCrys = CoreIPC.register_listener('CRYS', 'soulspire_core')
    local tokCoreHud  = CoreIPC.register_listener('OXHUD', 'soulspire_core')

    assert_true(not CoreIPC.should_block(tokTal), 'Earlier soulspire_talents MUST NOT block OXTL before Core')
    assert_true(CoreIPC.should_block(tokCoreOxtl), 'Final soulspire_core blocks OXTL before stock FFXI')
    assert_true(not CoreIPC.should_block(tokCrys), 'Earlier crystalsocket MUST NOT block CRYS before Core')
    assert_true(CoreIPC.should_block(tokCoreCrys), 'Final soulspire_core blocks CRYS before stock FFXI')
    assert_true(not CoreIPC.should_block(tokHud), 'Earlier soulspire_soulhud MUST NOT block OXHUD before Core')
    assert_true(CoreIPC.should_block(tokCoreHud), 'Final soulspire_core blocks OXHUD before stock FFXI')
    assert_true(CoreIPC.is_primary_owner('OXTL', 'soulspire_core'), 'soulspire_core is primary OXTL owner')
    assert_true(not CoreIPC.is_primary_owner('OXTL', 'soulspire_talents'), 'standalone soulspire_talents stays passive')

    -- Simulate /addon reload soulspire_talents, then unload soulspire_talents
    local tokTalReloaded = CoreIPC.register_listener('OXTL', 'soulspire_talents')
    assert_true(not CoreIPC.should_block(tokCoreOxtl), 'After reload, earlier Core passes packet to reloaded talents')
    assert_true(CoreIPC.should_block(tokTalReloaded), 'Reloaded talents is now final blocker')
    CoreIPC.unregister_listener(tokTalReloaded)
    assert_true(CoreIPC.should_block(tokCoreOxtl), 'After talents unloads, Core resumes final blocker cleanly')

    -- Reconnect: session drops to offline then returns
    local H = make_harness()
    H.cs:tick(H.clock())
    local gen1 = H.cs:getSnapshot().session.generation
    H.set_runtime({ inSession = false })
    H.advance(1.1); H.cs:tick(H.clock())
    assert_eq(H.cs:getFreshness('identity').state, 'offline', 'Disconnect marks identity offline')
    H.set_runtime({ inSession = true, characterId = 1001, name = 'Rin', mainJob = 1, mainLevel = 15, zone = 230 })
    H.advance(1.1); H.cs:tick(H.clock())
    assert_true(H.cs:getSnapshot().session.generation > gen1, 'Reconnect starts fresh session generation')
    assert_eq(H.cs:getSnapshot().effective.mainLevel, 15, 'Reconnect restores runtime state')
    print('[PASS] Scenarios 11 & 13: Addon reload, reconnect & multi-addon IPC coexistence')
end

-- ---------------------------------------------------------------------------
-- Scenario 12: Partial Static-Cache Availability (Missing/Corrupt Fallback)
-- ---------------------------------------------------------------------------
do
    local brokenDs = DataService.new({ cache_dir = '/tmp/nonexistent_soulspire_cache_dir_xyz', auto_load = true })
    assert_true(not brokenDs:is_cache_usable(), 'Missing cache cleanly marked unusable')
    local H = make_harness({ dataService = brokenDs })
    H.cs:tick(H.clock())
    H.advance(0.2); H.cs:tick(H.clock())
    H.wm_mod:on_open()
    assert_true(#H.sent_oxtl >= 1, 'Falls back to legacy OP_SYNC when cache unavailable')
    assert_eq(H.sent_oxtl[#H.sent_oxtl].op, SoulforgeState.OP_SYNC, 'Uses legacy OP_SYNC on missing cache')
    assert_eq(H.cs:getSnapshot().cache.usable, false, 'CharacterState surfaces cache usability honestly')
    print('[PASS] Scenario 12: Partial/missing static cache fails safely & falls back')
end

-- ---------------------------------------------------------------------------
-- Scenario 14: Immutable Snapshots, Subscription Cleanup & Loop Prevention
-- ---------------------------------------------------------------------------
do
    local H = make_harness()
    H.cs:tick(H.clock())
    local snap = H.cs:getSnapshot()
    -- LuaJIT 2.1 native pairs() compatibility check
    local keyCount = 0
    for _ in pairs(snap) do keyCount = keyCount + 1 end
    assert_true(keyCount >= 6, 'Snapshot supports native LuaJIT pairs()')

    -- Cross-module mutation protection
    local okMut = pcall(function() snap.effective.injected_field = 999 end)
    assert_true(not okMut, 'Read-only snapshot blocks accidental new-key mutation')

    -- Selector only fires when selected value ACTUALLY changes
    local fireCount = 0
    local subId = H.cs:subscribe(
        function(s) return s.effective.mainLevel end,
        function() fireCount = fireCount + 1 end,
        { owner = 'test_mod' }
    )
    H.cs:observeHudTelemetry('berserker', { rage = '50' }, H.clock()) -- unrelated domain!
    assert_eq(fireCount, 0, 'Unrelated HUD update does NOT fire mainLevel subscriber')
    H.runtime.mainLevel = 11
    H.advance(1.1); H.cs:tick(H.clock())
    assert_eq(fireCount, 1, 'Actual mainLevel change fires subscriber once')

    -- Recursive notification loop guard
    local loopSubId = H.cs:subscribe(
        function(s) return s.domains.soul.invalidatedAt end,
        function()
            -- Malicious/buggy listener trying to create an infinite invalidation loop!
            H.cs:invalidate('soul', 'recursive_loop_test', H.advance(0.001))
        end,
        { owner = 'loop_tester' }
    )
    H.cs:invalidate('soul', 'trigger_loop', H.advance(0.001))
    local diag = H.cs:getDiagnostics()
    assert_true(diag.notificationLoopsBlocked >= 1, 'Recursive notification loop blocked safely')
    H.cs:unsubscribe(loopSubId)

    -- Cleanup on module unload
    H.cs:unsubscribe(subId)
    H.char_mod:destroy()
    H.wm_mod:destroy()
    H.st_mod:destroy()
    H.sf_actions.destroy()
    assert_eq(H.cs:getDiagnostics().subscriptionCount, 0, 'All module subscriptions cleaned up on unload')

    -- Micro-benchmark: snapshot creation latency
    local t0 = os.clock()
    for _ = 1, 1000 do
        local _ = H.cs:getSnapshot()
    end
    local snapUs = ((os.clock() - t0) * 1e6) / 1000
    print(string.format('[BENCH] getSnapshot() read-only clone latency: %.2f us/call', snapUs))
    print('[PASS] Scenario 14: Immutable snapshots, cleanup, and recursive loop prevention')
end

print('CHARACTER_STATE_TEST_OK')
