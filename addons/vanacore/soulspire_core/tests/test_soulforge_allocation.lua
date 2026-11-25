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
