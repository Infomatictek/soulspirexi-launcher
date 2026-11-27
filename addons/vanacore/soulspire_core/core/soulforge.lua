-- SoulspireXI Phase C — Native VanaCore Soulforge Protocol & State Controller
-- Uses native `vana.packets.inject(false, 0x11F, ...)` for C2S OXTL and decodes S2C 0x1FD / 0x017 `[OXTAL]|`.
-- Fixes the Weapon Skill talent point allocation defect:
--   1. Validates 1-based server `tree.nodes` index (`node.idx` with `nodes` array fallback, never sending 0).
--   2. Expires stuck `pendingOp` in `tick()` after 5.0s and triggers an authoritative `OP_WS` resync.
--   3. Sends clean v1 `OP_STATE`/`OP_WS` directly when server is v1 (zero 1.8s stall).

local M = {}

M.PROTO_TAG        = '[SSTAL]|'
M.LEGACY_PROTO_TAG = '[OXTAL]|'
M.PACKET_C2S_ID    = 0x11F
M.PACKET_S2C_ID    = 0x1FD
M.OP_SYNC       = 1
M.OP_STATE      = 2
M.OP_WS         = 3
M.OP_INVEST     = 4
M.OP_REFUND     = 5
M.OP_CYCLE_SC   = 6
M.OP_RESET_WS   = 7
M.OP_RESET_ALL  = 8

M.PENDING_TIMEOUT_SEC = 5.0

M.SKILL_LIST = {
    { id = -1, name = 'Equipped' },
    { id = 0,  name = 'All Weapons' },
    { id = 1,  name = 'Hand-to-Hand' },
    { id = 2,  name = 'Dagger' },
    { id = 3,  name = 'Sword' },
    { id = 4,  name = 'Great Sword' },
    { id = 5,  name = 'Axe' },
    { id = 6,  name = 'Great Axe' },
    { id = 7,  name = 'Scythe' },
    { id = 8,  name = 'Polearm' },
    { id = 9,  name = 'Katana' },
    { id = 10, name = 'Great Katana' },
    { id = 11, name = 'Club' },
    { id = 12, name = 'Staff' },
    { id = 25, name = 'Archery' },
    { id = 26, name = 'Marksmanship' },
    { id = 27, name = 'Throwing' },
}

local function split_pipe(str)
    local out = {}
    local start = 1
    while true do
        local pos = string.find(str, '|', start, true)
        if not pos then
            out[#out + 1] = string.sub(str, start)
            break
        end
        out[#out + 1] = string.sub(str, start, pos - 1)
        start = pos + 1
    end
    return out
end

function M.encode_packet(op, ws_id, arg1, arg2)
    local w  = tonumber(ws_id) or 0
    local a1 = (tonumber(arg1) or 0) % 256
    local a2 = (tonumber(arg2) or 0) % 256
    return string.char(0x1F, 0x09, 0x00, 0x00)
        .. 'OXTL'
        .. string.char(1, (tonumber(op) or 0) % 256, w % 256, math.floor(w / 256) % 256, a1, a2, 0, 0)
end

function M.new(opts)
    opts = opts or {}
    local clock_fn = opts.clock or os.clock
    local send_fn  = opts.send_packet

    local self = {
        synced         = false,
        job_key        = '',
        job_level      = 1,
        avail          = 0,
        spent          = 0,
        earned         = 0,
        main_skill     = 0,
        ranged_skill   = 0,
        spec_name      = 'Base',
        selected_skill = 0, -- default to All Weapons so Arsenal is never empty on open
        search_query   = '',
        invested_only  = false,
        catalog        = {},
        catalog_by_id  = {},
        spent_by_ws    = {},
        unlocked_by_ws = {},
        selected_ws_id = nil,
        ws_detail      = nil,
        ws_by_id       = {},
        temp_catalog   = nil,
        temp_ws        = nil,
        pending_op     = nil,
        last_error     = nil,
        status_text    = 'Ready',
        packets_in     = 0,
        packets_out    = 0,
    }

    local function send_oxtl(op, ws_id, arg1, arg2)
        local raw = M.encode_packet(op, ws_id, arg1, arg2)
        self.packets_out = self.packets_out + 1
        if type(send_fn) == 'function' then
            return send_fn(M.PACKET_C2S_ID, raw, op, ws_id, arg1, arg2) ~= false
        end
        if type(vana) == 'table' and vana.packets and type(vana.packets.inject) == 'function' then
            vana.packets.inject(false, M.PACKET_C2S_ID, raw)
            return true
        end
        return false
    end

    function self:resolve_node_idx(ws_id, node)
        if type(node) ~= 'table' then return 0 end
        local idx = tonumber(node.idx) or 0
        if idx >= 1 then return idx end
        local detail = (self.ws_detail and self.ws_detail.id == ws_id) and self.ws_detail or self.ws_by_id[ws_id]
        if detail and type(detail.nodes) == 'table' then
            for i, n in ipairs(detail.nodes) do
                if n == node or (node.key ~= nil and n.key == node.key) then
                    return tonumber(n.idx) or i
                end
            end
        end
        return tonumber(node.slot) or 0
    end

    function self:request_sync()
        self.last_error = nil
        self.status_text = 'Syncing Soulforge catalog & points...'
        return send_oxtl(M.OP_SYNC, 0, 0, 0)
    end

    function self:request_state()
        self.last_error = nil
        return send_oxtl(M.OP_STATE, 0, 0, 0)
    end

    function self:request_ws(ws_id)
        local wid = tonumber(ws_id) or 0
        if wid <= 0 then return false end
        self.selected_ws_id = wid
        self.ws_detail = self.ws_by_id[wid]
        self.status_text = 'Loading Weapon Skill #' .. tostring(wid) .. '...'
        return send_oxtl(M.OP_WS, wid, 0, 0)
    end

    function self:invest(ws_id, node)
        if self.pending_op ~= nil then return false, 'pending' end
        local wid = tonumber(ws_id) or 0
        local idx = self:resolve_node_idx(wid, node)
        if wid <= 0 or idx < 1 then
            self.last_error = 'Invalid talent node index; resyncing...'
            self.status_text = self.last_error
            if wid > 0 then self:request_ws(wid) end
            return false, 'invalid_node_idx'
        end
        self.last_error = nil
        self.pending_op = {
            kind = 'invest',
            ws_id = wid,
            node_key = node.key,
            node_idx = idx,
            sent_at = clock_fn(),
        }
        self.status_text = 'Allocating point into ' .. tostring(node.name or node.key) .. '...'
        if not send_oxtl(M.OP_INVEST, wid, idx, 0) then
            self.pending_op = nil
            self.last_error = 'Packet transport unavailable.'
            self.status_text = self.last_error
            return false, 'transport_unavailable'
        end
        return true
    end

    function self:refund(ws_id, node)
        if self.pending_op ~= nil then return false, 'pending' end
        local wid = tonumber(ws_id) or 0
        local idx = self:resolve_node_idx(wid, node)
        if wid <= 0 or idx < 1 then
            self.last_error = 'Invalid talent node index; resyncing...'
            self.status_text = self.last_error
            return false, 'invalid_node_idx'
        end
        self.last_error = nil
        self.pending_op = {
            kind = 'refund',
            ws_id = wid,
            node_key = node.key,
            node_idx = idx,
            sent_at = clock_fn(),
        }
        self.status_text = 'Refunding ' .. tostring(node.name or node.key) .. '...'
        if not send_oxtl(M.OP_REFUND, wid, idx, 0) then
            self.pending_op = nil
            self.last_error = 'Packet transport unavailable.'
            return false, 'transport_unavailable'
        end
        return true
    end

    function self:cycle_skillchain(ws_id, tier, dir)
        if self.pending_op ~= nil then return false end
        local wid = tonumber(ws_id) or 0
        local t = tonumber(tier) or 0
        if wid <= 0 or t < 1 or t > 4 then return false end
        self.pending_op = { kind = 'sc', ws_id = wid, sent_at = clock_fn() }
        local d = (dir == -1 or dir == 2) and 2 or 1
        return send_oxtl(M.OP_CYCLE_SC, wid, t, d)
    end

    function self:reset_ws(ws_id)
        if self.pending_op ~= nil then return false end
        local wid = tonumber(ws_id) or 0
        if wid <= 0 then return false end
        self.pending_op = { kind = 'reset_ws', ws_id = wid, sent_at = clock_fn() }
        self.status_text = 'Resetting Weapon Skill talents...'
        return send_oxtl(M.OP_RESET_WS, wid, 0, 0)
    end

    function self:reset_all()
        if self.pending_op ~= nil then return false end
        self.pending_op = { kind = 'reset_all', ws_id = 0, sent_at = clock_fn() }
        self.status_text = 'Resetting all Weapon Skill talents...'
        return send_oxtl(M.OP_RESET_ALL, self.selected_ws_id or 0, 0, 0)
    end

    function self:tick(now)
        local t = now or clock_fn()
        if self.pending_op and (t - (self.pending_op.sent_at or 0)) >= M.PENDING_TIMEOUT_SEC then
            local timed_out = self.pending_op
            self.pending_op = nil
            self.last_error = 'Server response timed out; resyncing...'
            self.status_text = self.last_error
            if timed_out.ws_id and timed_out.ws_id > 0 then
                self:request_ws(timed_out.ws_id)
            else
                self:request_state()
            end
        end
    end

    function self:filtered_catalog()
        local out = {}
        local q = string.lower(tostring(self.search_query or ''))
        local sk = tonumber(self.selected_skill) or 0
        for _, ws in ipairs(self.catalog) do
            local ok_skill = (sk == 0)
                or (sk == -1 and ((self.main_skill > 0 and ws.skill == self.main_skill)
                    or (self.ranged_skill > 0 and ws.skill == self.ranged_skill)))
                or (ws.skill == sk)
            if ok_skill then
                local pts = self.spent_by_ws[ws.id] or 0
                local ok_inv = (not self.invested_only) or (pts > 0)
                local ok_q = (q == '') or (string.find(string.lower(ws.name), q, 1, true) ~= nil)
                if ok_inv and ok_q then
                    out[#out + 1] = ws
                end
            end
        end
        return out
    end

    function self:handle_proto_line(line)
        if type(line) ~= 'string' or line == '' then return false end
        local parts = split_pipe(line)
        local kind = parts[1]

        if kind == 'META' then
            self.job_key      = parts[2] or self.job_key
            self.job_level    = tonumber(parts[3]) or self.job_level
            self.avail        = tonumber(parts[4]) or self.avail
            self.spent        = tonumber(parts[5]) or self.spent
            self.earned       = tonumber(parts[6]) or self.earned
            self.main_skill   = tonumber(parts[7]) or self.main_skill
            self.ranged_skill = tonumber(parts[8]) or self.ranged_skill
            self.spec_name    = parts[9] or self.spec_name
            self.synced       = true
            return true
        elseif kind == 'SPENT' then
            if parts[2] and parts[2] ~= '' then
                for entry in string.gmatch(parts[2], '([^,]+)') do
                    local wid, pts = entry:match('^(%d+)=(%d+)$')
                    if wid and pts then
                        self.spent_by_ws[tonumber(wid)] = tonumber(pts)
                    end
                end
            end
            return true
        elseif kind == 'CAT_BEGIN' then
            self.temp_catalog = {}
            return true
        elseif kind == 'CAT' then
            if self.temp_catalog and parts[2] and parts[2] ~= '' then
                for entry in string.gmatch(parts[2], '([^;]+)') do
                    local wid, sk, name, wtype = entry:match('^(%d+),(%d+),([^,]+),?(.*)$')
                    if wid and name then
                        self.temp_catalog[#self.temp_catalog + 1] = {
                            id = tonumber(wid),
                            skill = tonumber(sk) or 0,
                            name = name,
                            ws_type = (wtype ~= '' and wtype) or 'physical',
                        }
                    end
                end
            end
            return true
        elseif kind == 'CAT_END' then
            if self.temp_catalog then
                self.catalog = self.temp_catalog
                self.catalog_by_id = {}
                for _, ws in ipairs(self.catalog) do
                    self.catalog_by_id[ws.id] = ws
                end
                self.temp_catalog = nil
                self.synced = true
                self.status_text = string.format('Synced %d weapon skills (%d pts available).', #self.catalog, self.avail)
            end
            return true
        elseif kind == 'WS' then
            local wid = tonumber(parts[2])
            self.temp_ws = {
                id = wid,
                name = parts[3] or ('WS #' .. tostring(wid)),
                skill_name = parts[4] or '',
                ws_type = parts[5] or 'physical',
                spent = tonumber(parts[6]) or 0,
                summary = parts[7] or '',
                nodes = {},
                by_key = {},
            }
            return true
        elseif kind == 'NODE' then
            if self.temp_ws and tonumber(parts[2]) == self.temp_ws.id then
                local idx = #self.temp_ws.nodes + 1
                local node = {
                    idx           = idx,
                    slot          = tonumber(parts[18]) or idx,
                    key           = parts[3],
                    tier          = tonumber(parts[4]) or 1,
                    col           = tonumber(parts[5]) or 1,
                    rank          = tonumber(parts[6]) or 0,
                    max_rank      = tonumber(parts[7]) or 1,
                    can_learn     = (tonumber(parts[8]) or 0) == 1,
                    req_ws_points = tonumber(parts[9]) or 0,
                    req_key       = (parts[10] ~= '' and parts[10]) or nil,
                    req_rank      = tonumber(parts[11]) or 0,
                    name          = parts[12] or parts[3],
                    desc          = parts[13] or '',
                    req_level     = tonumber(parts[14]) or 1,
                    sc_tier       = tonumber(parts[15]) or 0,
                    sc_id         = tonumber(parts[16]) or 0,
                    sc_name       = parts[17] or '',
                }
                self.temp_ws.nodes[idx] = node
                self.temp_ws.by_key[node.key] = node
            end
            return true
        elseif kind == 'WS_END' then
            if self.temp_ws and tonumber(parts[2]) == self.temp_ws.id then
                local wid = self.temp_ws.id
                self.avail = tonumber(parts[3]) or self.avail
                self.spent_by_ws[wid] = self.temp_ws.spent or 0
                self.unlocked_by_ws[wid] = (tonumber(parts[4]) or 0) == 1 or (self.temp_ws.spent or 0) > 0
                self.ws_by_id[wid] = self.temp_ws
                if self.selected_ws_id == nil or self.selected_ws_id == wid then
                    self.ws_detail = self.temp_ws
                end
                self.temp_ws = nil
                if self.pending_op and (self.pending_op.ws_id == 0 or self.pending_op.ws_id == wid) then
                    self.pending_op = nil
                    self.status_text = 'Soulforge updated.'
                end
            end
            return true
        elseif kind == 'ERR' then
            self.pending_op = nil
            self.last_error = parts[2] or 'Soulforge action rejected by server.'
            self.status_text = self.last_error
            return true
        end
        return false
    end

    function self:handle_packet_in(id, data)
        if type(data) ~= 'string' then return false end
        local magic = (#data >= 8) and data:sub(5, 8) or ''
        if id == M.PACKET_S2C_ID and #data >= 12 and (magic == 'SSTL' or magic == 'OXTL') then
            self.packets_in = self.packets_in + 1
            local b11, b12 = data:byte(11, 12)
            local pay_len = (b11 or 0) + (b12 or 0) * 256
            if pay_len > 0 and #data >= 12 + pay_len then
                local line = data:sub(13, 12 + pay_len)
                if line:sub(1, #M.PROTO_TAG) == M.PROTO_TAG then
                    line = line:sub(#M.PROTO_TAG + 1)
                elseif line:sub(1, #M.LEGACY_PROTO_TAG) == M.LEGACY_PROTO_TAG then
                    line = line:sub(#M.LEGACY_PROTO_TAG + 1)
                end
                return self:handle_proto_line(line)
            end
            return true
        elseif id == 0x017 and #data >= 25 then
            local msg = string.sub(data, 24):match('^([^%z]*)')
            if msg and string.sub(msg, 1, #M.PROTO_TAG) == M.PROTO_TAG then
                self.packets_in = self.packets_in + 1
                return self:handle_proto_line(string.sub(msg, #M.PROTO_TAG + 1))
            elseif msg and string.sub(msg, 1, #M.LEGACY_PROTO_TAG) == M.LEGACY_PROTO_TAG then
                self.packets_in = self.packets_in + 1
                return self:handle_proto_line(string.sub(msg, #M.LEGACY_PROTO_TAG + 1))
            end
        end
        return false
    end

    return self
end

return M
