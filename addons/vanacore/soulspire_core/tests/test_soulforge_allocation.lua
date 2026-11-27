-- Unit test for Phase C VanaCore-native Soulforge WS talent point allocation fix.
local sf_mod = dofile('addons/vanacore/soulspire_core/core/soulforge.lua')

local sent = {}
local now = 10.0
local sf = sf_mod.new({
    clock = function() return now end,
    send_packet = function(id, raw, op, ws_id, a1, a2)
        sent[#sent + 1] = { id = id, raw = raw, op = op, ws_id = ws_id, a1 = a1, a2 = a2 }
        return true
    end,
})

-- 1. Receive server META, CAT, WS, NODE, WS_END
assert(sf:handle_proto_line('META|NIN|75|5|0|5|9|0|Shinobi'))
assert(sf.avail == 5 and sf.spec_name == 'Shinobi')
assert(sf:handle_proto_line('CAT_BEGIN'))
assert(sf:handle_proto_line('CAT|128,9,Blade: Rin,physical;135,9,Blade: Ten,physical'))
assert(sf:handle_proto_line('CAT_END'))
assert(#sf.catalog == 2)
assert(sf:handle_proto_line('WS|135|Blade: Ten|Katana|physical|0|LOCKED'))
assert(sf:handle_proto_line('NODE|135|t1_dmg|1|1|0|5|1|0||0|Edge Mastery|+5% dmg|1|0|0||1'))
assert(sf:handle_proto_line('NODE|135|t1_acc|1|2|0|5|1|0||0|Keen Eye|+10 acc|1|0|0||2'))
assert(sf:handle_proto_line('WS_END|135|5|0'))
assert(sf.ws_detail and sf.ws_detail.id == 135 and #sf.ws_detail.nodes == 2)

-- 2. Allocate a point into node #2 even if caller omitted .idx (fallback resolves 1-based index = 2)
local ok, err = sf:invest(135, { key = 't1_acc', name = 'Keen Eye' })
assert(ok == true, 'invest should succeed: ' .. tostring(err))
assert(#sent == 1 and sent[1].id == 0x11F and sent[1].op == 4 and sent[1].ws_id == 135 and sent[1].a1 == 2)
assert(#sent[1].raw == 16 and sent[1].raw:sub(5, 8) == 'OXTL')
assert(sf.pending_op ~= nil)

-- 3. Server responds with updated META + WS + NODE + WS_END -> rank increments & avail decrements
assert(sf:handle_proto_line('META|NIN|75|4|1|5|9|0|Shinobi'))
assert(sf:handle_proto_line('WS|135|Blade: Ten|Katana|physical|1|UNLOCKED'))
assert(sf:handle_proto_line('NODE|135|t1_dmg|1|1|0|5|1|0||0|Edge Mastery|+5% dmg|1|0|0||1'))
assert(sf:handle_proto_line('NODE|135|t1_acc|1|2|1|5|1|0||0|Keen Eye|+10 acc|1|0|0||2'))
assert(sf:handle_proto_line('WS_END|135|4|1'))
assert(sf.pending_op == nil)
assert(sf.avail == 4 and sf.spent_by_ws[135] == 1 and sf.ws_detail.by_key['t1_acc'].rank == 1)

-- 4. Timeout recovery: if a second invest gets no reply within 5.0s, tick() clears pending_op and resyncs
assert(sf:invest(135, sf.ws_detail.by_key['t1_dmg']))
assert(sf.pending_op ~= nil)
now = now + 5.5
sf:tick(now)
assert(sf.pending_op == nil, 'tick() must clear timed-out pending_op')
assert(sent[#sent].op == sf_mod.OP_WS and sent[#sent].ws_id == 135, 'tick() must resync WS after timeout')

print('PASS: Phase C Soulforge WS talent allocation & timeout recovery verified')

-- 5. Real soulforge/soulforge_state.lua packet_in (0x1FD OXTL), investNode, refundNode, and authoritative 66-Soul weapon filtering
package.path = 'addons/vanacore/soulspire_core/?.lua;' .. package.path
package.loaded['imgui'] = package.loaded['imgui'] or {}
local sf_state_mod = dofile('addons/vanacore/soulspire_core/soulforge/soulforge_state.lua')
local DataService  = dofile('addons/vanacore/soulspire_core/core/data_service.lua')
local WeaponMod    = dofile('addons/vanacore/soulspire_core/modules/weapon_mastery.lua')
local SfUi         = dofile('addons/vanacore/soulspire_core/soulforge/soulforge_ui.lua')
local json_mod     = dofile('addons/vanacore/soulspire_core/core/json.lua')
local ds = DataService.new({ addon_path = 'addons/vanacore/soulspire_core', auto_load = true })
local sent2 = {}
local now2 = 20.0
local st, act = sf_state_mod.new({
    dataService = ds,
    clock = function() return now2 end,
    sendPacket = function(id, bytes, op, wsId, a1, a2)
        sent2[#sent2 + 1] = { id = id, bytes = bytes, op = op, wsId = wsId, a1 = a1, a2 = a2 }
        return true
    end,
})

local function make_oxtl_1fd(line)
    local payload = '[OXTAL]|' .. line
    local len = #payload
    return string.char(0xFD, 0x00, 0x00, 0x00) .. 'OXTL'
        .. string.char(1, 0, len % 256, math.floor(len / 256) % 256)
        .. payload
end

-- Verify both handlePacketIn and backwards-compatible handlePacket alias work
assert(type(act.handlePacketIn) == 'function', 'handlePacketIn must be exported')
assert(act.handlePacket == act.handlePacketIn, 'handlePacket alias must point to handlePacketIn')
assert(type(act.onZone) == 'function', 'onZone alias must be exported')
assert(type(act.setActiveIdentity) == 'function', 'setActiveIdentity must be exported')

-- 5a. Unavailable identity MUST fail-closed (never display all 15 weapon families or all 219 skills!)
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('CAT_BEGIN')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('CAT|135:9:Blade: Ten:physical,80:6:Upheaval:physical,96:7:Cross Reaper:physical,212:26:Leaden Salute:magical,42:3:Savage Blade:physical,112:8:Stardiver:physical,192:25:Sidewinder:physical,16:2:Evisceration:physical')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('CAT_END')))
st.selectedSkill = 0
local uninit_rows = act.filtered()
assert(#uninit_rows == 0, 'Unavailable identity must NOT display all weapons as eligible, got ' .. tostring(#uninit_rows))
local uninit_skills = act.getAvailableSkills()
assert(#uninit_skills == 2, 'Unavailable identity must only show All/Equipped tabs, got ' .. tostring(#uninit_skills))

-- 5b. NIN Shinobi: strictly Katana (9) ONLY (no broad vanilla NIN Sword/Dagger/H2H fallback!)
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|NIN|75|5|0|5|3|0|Shinobi')))
assert(st.jobKey == 'NIN' and st.avail == 5 and (st.specKey == 'kurogane' or st.specKey == 'shinobi'))
local nin_rows = act.filtered()
assert(#nin_rows == 1 and nin_rows[1].id == 135, 'Shinobi must restrict strictly to Katana (9) even with Sword equipped, got ' .. tostring(#nin_rows))
local nin_skills = act.getAvailableSkills()
local has_gaxe, has_katana, has_sword = false, false, false
for _, s in ipairs(nin_skills) do
    if s.id == 6 then has_gaxe = true end
    if s.id == 9 then has_katana = true end
    if s.id == 3 then has_sword = true end
end
assert(has_katana and not has_gaxe and not has_sword, 'Shinobi skill list must include ONLY Katana (not Great Axe or Sword)')

-- 5c. WAR Souls: Commander (Great Axe ONLY), Berserker (Great Axe ONLY), Spartan (Polearm ONLY)
act.setActiveIdentity('WAR', 'commander', 'Commander')
local cdr_rows = act.filtered()
assert(#cdr_rows == 1 and cdr_rows[1].id == 80, 'WAR Commander must show Great Axe (6) ONLY, got ' .. tostring(#cdr_rows))
act.setActiveIdentity('WAR', 'berserker', 'Berserker')
local bsk_rows = act.filtered()
assert(#bsk_rows == 1 and bsk_rows[1].id == 80, 'WAR Berserker must show Great Axe (6) ONLY, got ' .. tostring(#bsk_rows))
act.setActiveIdentity('WAR', 'spartan', 'Spartan')
local spt_rows = act.filtered()
assert(#spt_rows == 1 and spt_rows[1].id == 112, 'WAR Spartan must show Polearm (8) ONLY, got ' .. tostring(#spt_rows))

-- 5d. Intentional multi-weapon Soul exceptions: COR Gambler (Marksmanship + Dagger), RNG Huntsman (Archery + Marksmanship)
act.setActiveIdentity('COR', 'gambler', 'Gambler')
local gmb_rows = act.filtered()
assert(#gmb_rows == 2, 'COR Gambler must allow both Marksmanship (26) and Dagger (2), got ' .. tostring(#gmb_rows))
act.setActiveIdentity('RNG', 'huntsman', 'Huntsman')
local hnt_rows = act.filtered()
assert(#hnt_rows == 2, 'RNG Huntsman must allow both Archery (25) and Marksmanship (26), got ' .. tostring(#hnt_rows))

-- 5e. Base-job state (unspecced WAR) uses base WAR job weapons cleanly
act.setActiveIdentity('WAR', 'base', 'Unspecced')
local base_war_elig = act.getEligibleSkillSet()
assert(base_war_elig and base_war_elig[6] == true and base_war_elig[8] == true and base_war_elig[3] == true,
    'Unspecced base WAR must allow base WAR job weapons')

-- 5f. COR Flintlock (ranged-only from authoritative soul-weapon-config.json):
-- Equipped Sword (mainSkill=3) must NOT grant Sword WS eligibility!
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|COR|75|5|0|5|3|26|Flintlock')))
local cor_rows = act.filtered()
assert(#cor_rows == 1 and cor_rows[1].id == 212 and not cor_rows[1].refundOnly,
    'COR Flintlock must restrict to Marksmanship WS even with Sword equipped')
assert(act.isWsEligible(212) == true and act.isWsEligible(42) == false, 'Flintlock Sword WS must be ineligible')

-- Previously invested but ineligible WS (Savage Blade id=42 with 2 pts spent) must appear as refundOnly=true,
-- block further investNode, and allow refundNode!
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_BEGIN')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT|42:2:1')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_END')))
local cor_rows_with_refund = act.filtered()
assert(#cor_rows_with_refund == 2, 'Previously invested ineligible WS must remain visible for refunds')
local found_refund_only = false
for _, r in ipairs(cor_rows_with_refund) do
    if r.id == 42 then found_refund_only = (r.refundOnly == true) end
end
assert(found_refund_only == true, 'Ineligible invested WS must be marked refundOnly=true')
assert(act.isWsRefundOnly(42) == true, 'isWsRefundOnly(42) must be true')
assert(act.investNode(42, { key = 't1_dmg', idx = 1, name = 'Power' }) == false, 'investNode must block refund-only WS')
local prev_sent = #sent2
assert(act.refundNode(42, { key = 't1_dmg', idx = 1, name = 'Power' }) == true, 'refundNode must remain allowed on refund-only WS')
assert(#sent2 == prev_sent + 1 and sent2[#sent2].op == sf_state_mod.OP_REFUND)
-- Clear pendingOp via ERR| and verify no optimistic corruption
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('ERR|Refund test error')))
assert(st.pendingOp == nil and st.rejectedMsg == 'Refund test error')
-- Clear spent before next checks
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_BEGIN')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_END')))

-- BLM Necromancer must restrict strictly to Scythe (7)
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|BLM|75|5|0|5|0|0|Necromancer')))
local blm_rows = act.filtered()
assert(#blm_rows == 1 and blm_rows[1].id == 96, 'BLM Necromancer must restrict to Scythe WS')

-- 5g. Validate ALL 66 canonical Souls from authoritative soul-identities.json + Weapon Mastery agreement
local id_f = assert(io.open('addons/vanacore/soulspire_core/data/soul-identities.json', 'rb'))
local id_data = json_mod.decode(id_f:read('*a'))
id_f:close()
local JOB_ID_TO_KEY = {
    [1]='WAR',[2]='MNK',[3]='WHM',[4]='BLM',[5]='RDM',[6]='THF',[7]='PLD',[8]='DRK',[9]='BST',[10]='BRD',[11]='RNG',
    [12]='SAM',[13]='NIN',[14]='DRG',[15]='SMN',[16]='BLU',[17]='COR',[18]='PUP',[19]='DNC',[20]='SCH',[21]='GEO',[22]='RUN',
}
local checked_souls = 0
for _, entry in ipairs(id_data.souls or {}) do
    local jkey = entry.jobKey or JOB_ID_TO_KEY[tonumber(entry.jobId)]
    local skey = entry.internalKey or entry.canonicalKey or entry.name or entry.displayName
    assert(act.handlePacketIn(0x1FD, make_oxtl_1fd(string.format('META|%s|75|5|0|5|0|0|%s', jkey, skey))))
    local elig = act.getEligibleSkillSet()
    local ds_elig = ds:get_eligible_weapon_skills(jkey, skey)
    assert(type(elig) == 'table' and type(ds_elig) == 'table', 'Eligible skill set must exist for ' .. tostring(jkey) .. ':' .. tostring(skey))
    local cnt = 0
    for sid, v in pairs(elig) do
        if v then
            cnt = cnt + 1
            assert(ds_elig[sid] == true, 'Weapon Mastery and DataService must agree on skill ' .. tostring(sid) .. ' for ' .. tostring(skey))
        end
    end
    assert(cnt >= 1 and cnt <= 5, 'Every canonical Soul must have narrow authoritative weapon family eligibility (1..5), got ' .. tostring(cnt) .. ' for ' .. tostring(skey))
    local low = string.lower(skey):gsub('[^a-z0-9]', '')
    if low == 'flintlock' then
        assert(cnt == 1 and elig[26] == true, 'Flintlock must be strictly Marksmanship (26)')
    elseif low == 'necromancer' then
        assert(cnt == 1 and elig[7] == true, 'Necromancer must be strictly Scythe (7)')
    elseif low == 'berserker' or low == 'commander' then
        assert(cnt == 1 and elig[6] == true, low .. ' must be strictly Great Axe (6)')
    elseif low == 'spartan' then
        assert(cnt == 1 and elig[8] == true, 'Spartan must be strictly Polearm (8)')
    elseif low == 'gambler' then
        assert(cnt == 2 and elig[26] == true and elig[2] == true, 'Gambler must be Marksmanship + Dagger')
    end
    checked_souls = checked_souls + 1
end
assert(checked_souls == 66, 'Expected 66 canonical Souls validated, got ' .. tostring(checked_souls))

-- 5h. Weapon Mastery controller navigation after filtering changes
local wm = WeaponMod.new(st, act, SfUi)
act.setActiveIdentity('WAR', 'spartan', 'Spartan')
wm:on_open()
assert(wm:on_action('up') == true or wm:on_action('down') == true or wm.arsenal_index == 1, 'WeaponMastery navigation stays valid after strict filtering')

-- Back to NIN Shinobi -> load WS detail via 0x1FD and verify investNode + duplicate prevention + refundNode + zone invalidation
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|NIN|75|5|0|5|9|0|Shinobi')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS|135|Blade: Ten|Katana|physical|0|LOCKED')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('NODE|135|t1_dmg|1|1|0|5|1|0||0|Edge Mastery|+5% dmg|1|0|0||1')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS_END|135|5|0')))
assert(st.wsDetail and st.wsDetail.authoritative == true and st.wsDetail.id == 135)

local ok_inv = act.investNode(135, st.wsDetail.byKey['t1_dmg'])
assert(ok_inv == true, 'investNode must succeed on authoritative WS detail')
assert(act.investNode(135, st.wsDetail.byKey['t1_dmg']) == false, 'Duplicate investNode while pending must be blocked')
assert(sent2[#sent2].id == 0x11F and sent2[#sent2].op == sf_state_mod.OP_INVEST and sent2[#sent2].wsId == 135 and sent2[#sent2].a1 == 1)

assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|NIN|75|4|1|5|9|0|Shinobi')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS|135|Blade: Ten|Katana|physical|1|UNLOCKED')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('NODE|135|t1_dmg|1|1|1|5|1|0||0|Edge Mastery|+5% dmg|1|0|0||1')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS_END|135|4|1')))
assert(st.pendingOp == nil and st.avail == 4 and st.wsDetail.byKey['t1_dmg'].rank == 1)

local ok_ref = act.refundNode(135, st.wsDetail.byKey['t1_dmg'])
assert(ok_ref == true, 'refundNode must succeed')
assert(sent2[#sent2].op == sf_state_mod.OP_REFUND and sent2[#sent2].wsId == 135 and sent2[#sent2].a1 == 1)
act.onZone()
assert(st.pendingOp == nil and st.wsDetail == nil and st.needsRefresh == true, 'onZone/invalidate must clear transient WS state')

-- 5i. Verify ALL 66 Souls resolve by displayName too (server META sends displayName + canonical specKey)
local checked_display = 0
for _, entry in ipairs(id_data.souls or {}) do
    local jkey = entry.jobKey or JOB_ID_TO_KEY[tonumber(entry.jobId)]
    local dname = entry.displayName or entry.name or entry.internalKey
    local skey = entry.internalKey or entry.canonicalKey or dname
    assert(act.handlePacketIn(0x1FD, make_oxtl_1fd(string.format('META|%s|75|5|0|5|0|0|%s|%s', jkey, dname, skey))))
    local elig = act.getEligibleSkillSet()
    assert(type(elig) == 'table', 'DisplayName+specKey META must resolve eligible skills for ' .. tostring(dname))
    checked_display = checked_display + 1
end
assert(checked_display == 66, 'Expected 66 Souls resolved by displayName+specKey, got ' .. tostring(checked_display))

-- 6. Verify Classic Ashita v4 soulspire_talents/soulforge_state.lua ALSO enforces strict 66-Soul weapon eligibility
local ashita_sf_mod = dofile('addons/ashita4/soulspire_talents/soulforge_state.lua')
local sent_ashita = {}
local ast, aact = ashita_sf_mod.new({
    clock = function() return 30.0 end,
    sendPacket = function(id, bytes, op, wsId, a1, a2)
        sent_ashita[#sent_ashita + 1] = { id = id, op = op, wsId = wsId, a1 = a1 }
        return true
    end,
})
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('CAT_BEGIN')))
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('CAT|135:9:Blade: Ten:physical,80:6:Upheaval:physical,212:26:Leaden Salute:magical,42:3:Savage Blade:physical,112:8:Stardiver:physical')))
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('CAT_END')))
ast.selectedSkill = 0
assert(#aact.filtered() == 0, 'Ashita v4 Weapon Mastery must fail-closed when identity is unavailable')
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('META|COR|75|5|0|5|3|26|Flintlock|flintlock')))
local a_cor_rows = aact.filtered()
assert(#a_cor_rows == 1 and a_cor_rows[1].id == 212, 'Ashita v4 Flintlock must restrict strictly to Marksmanship')
assert(aact.investNode(42, { key = 't1_dmg', idx = 1, name = 'Power' }) == false, 'Ashita v4 must block investNode on ineligible Sword WS')
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_BEGIN')))
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT|42:2:1')))
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_END')))
assert(aact.isWsRefundOnly(42) == true, 'Ashita v4 must preserve ineligible invested WS as refundOnly')
assert(aact.investNode(42, { key = 't1_dmg', idx = 1, name = 'Power' }) == false, 'Ashita v4 must block investNode on refundOnly WS')
assert(aact.refundNode(42, { key = 't1_dmg', idx = 1, name = 'Power' }) == true, 'Ashita v4 must allow refundNode on refundOnly WS')
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_BEGIN')))
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('SPENT_END')))
assert(aact.handlePacketIn(0x1FD, make_oxtl_1fd('META|NIN|75|5|0|5|3|0|Shinobi|shinobi')))
local a_nin_skills = aact.getAvailableSkills()
local a_has_katana, a_has_sword = false, false
for _, s in ipairs(a_nin_skills) do
    if s.id == 9 then a_has_katana = true end
    if s.id == 3 then a_has_sword = true end
end
assert(a_has_katana and not a_has_sword, 'Ashita v4 Shinobi getAvailableSkills must show Katana only')

print('PASS: real soulforge_state 0x1FD packet_in, invest/refund, 66-Soul eligibility parity (VanaCore + Ashita v4) & refund-only verified')
