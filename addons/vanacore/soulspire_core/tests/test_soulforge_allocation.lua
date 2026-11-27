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

-- 5. Real soulforge/soulforge_state.lua packet_in (0x1FD OXTL), investNode, refundNode, and Job+Soul weapon filtering
local sf_state_mod = dofile('addons/vanacore/soulspire_core/soulforge/soulforge_state.lua')
local sent2 = {}
local now2 = 20.0
local st, act = sf_state_mod.new({
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

-- Feed binary 0x1FD OXTL packets for NIN Shinobi
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|NIN|75|5|0|5|9|0|Shinobi')))
assert(st.jobKey == 'NIN' and st.avail == 5 and st.specKey == 'shinobi')
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('CAT_BEGIN')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('CAT|135:9:Blade: Ten:physical,80:6:Upheaval:physical,96:7:Cross Reaper:physical,212:26:Leaden Salute:magical')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('CAT_END')))

-- Shinobi (NIN) All Weapons (selectedSkill=0) must include Katana (9) and exclude Great Axe (6), Scythe (7), Marksmanship (26)
st.selectedSkill = 0
local nin_rows = act.filtered()
assert(#nin_rows == 1 and nin_rows[1].id == 135, 'Shinobi All Weapons should only include NIN-eligible skills, got ' .. tostring(#nin_rows))
local nin_skills = act.getAvailableSkills()
local has_gaxe, has_katana = false, false
for _, s in ipairs(nin_skills) do
    if s.id == 6 then has_gaxe = true end
    if s.id == 9 then has_katana = true end
end
assert(has_katana and not has_gaxe, 'Shinobi skill list must include Katana and exclude Great Axe')

-- COR Flintlock (ranged-only) must restrict All Weapons strictly to Marksmanship (26)
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|COR|75|5|0|5|0|26|Flintlock')))
local cor_rows = act.filtered()
assert(#cor_rows == 1 and cor_rows[1].id == 212, 'COR Flintlock should restrict to Marksmanship WS only')

-- BLM Necromancer must add Scythe (7) to BLM weapons
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|BLM|75|5|0|5|7|0|Necromancer')))
local blm_rows = act.filtered()
assert(#blm_rows == 1 and blm_rows[1].id == 96, 'BLM Necromancer must include Scythe WS')

-- Back to NIN Shinobi -> load WS detail via 0x1FD and verify investNode + refundNode
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|NIN|75|5|0|5|9|0|Shinobi')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS|135|Blade: Ten|Katana|physical|0|LOCKED')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('NODE|135|t1_dmg|1|1|0|5|1|0||0|Edge Mastery|+5% dmg|1|0|0||1')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS_END|135|5|0')))
assert(st.wsDetail and st.wsDetail.authoritative == true and st.wsDetail.id == 135)

local ok_inv = act.investNode(135, st.wsDetail.byKey['t1_dmg'])
assert(ok_inv == true, 'investNode must succeed on authoritative WS detail')
assert(sent2[#sent2].id == 0x11F and sent2[#sent2].op == sf_state_mod.OP_INVEST and sent2[#sent2].wsId == 135 and sent2[#sent2].a1 == 1)

assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('META|NIN|75|4|1|5|9|0|Shinobi')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS|135|Blade: Ten|Katana|physical|1|UNLOCKED')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('NODE|135|t1_dmg|1|1|1|5|1|0||0|Edge Mastery|+5% dmg|1|0|0||1')))
assert(act.handlePacketIn(0x1FD, make_oxtl_1fd('WS_END|135|4|1')))
assert(st.pendingOp == nil and st.avail == 4 and st.wsDetail.byKey['t1_dmg'].rank == 1)

local ok_ref = act.refundNode(135, st.wsDetail.byKey['t1_dmg'])
assert(ok_ref == true, 'refundNode must succeed')
assert(sent2[#sent2].op == sf_state_mod.OP_REFUND and sent2[#sent2].wsId == 135 and sent2[#sent2].a1 == 1)
print('PASS: real soulforge_state 0x1FD packet_in, invest/refund, and Job+Soul weapon filtering verified')
