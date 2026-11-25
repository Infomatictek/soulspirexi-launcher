local M = {
    REQUEST_ID       = 0x11f,
    RESPONSE_ID      = 0x1ff,
    OP_QUERY         = 0,
    OP_SELECT        = 1,
    OP_SYNC_CATALOG  = 2,
    CATALOG_BEGIN    = 0,
    CATALOG_ENTRY    = 1,
    CATALOG_HIGHLIGHT = 2,
    CATALOG_END      = 3,
    MAX_BRANCHES     = 7,
}

local function integer(value, low, high)
    return type(value) == 'number' and value >= low and value <= high and value % 1 == 0
end

function M.owns(mask, branch)
    return integer(mask, 0, 254) and mask % 2 == 0 and integer(branch, 1, M.MAX_BRANCHES)
        and math.floor(mask / 2 ^ branch) % 2 == 1
end

function M.encode_request(operation, request_id, job, branch)
    if not integer(operation, 0, 2) or not integer(request_id, 1, 65535)
        or not integer(job, 0, 23) or not integer(branch, 0, M.MAX_BRANCHES) then
        return nil, 'Invalid crystal request.'
    end
    if operation == M.OP_SELECT and job < 1 then
        return nil, 'Invalid crystal selection job.'
    end
    if operation ~= M.OP_SELECT and branch ~= 0 then
        return nil, 'Invalid crystal query branch.'
    end
    return string.char(0x1f, 0x09, 0, 0) .. 'CRYS'
        .. string.char(1, operation, request_id % 256, math.floor(request_id / 256), job, branch, 0, 0)
end

function M.decode_reply(packet)
    if type(packet) ~= 'string' or #packet ~= 64 then
        return nil, 'Invalid crystal reply length.'
    end
    local b = { packet:byte(1, 64) }
    if b[1] ~= 0xff or b[2] ~= 0x21 or packet:sub(5, 8) ~= 'CRYS'
        or b[9] ~= 1 or b[10] > 4 or b[13] > 23 or b[14] ~= 24 or b[16] ~= 0 then
        return nil, 'Invalid crystal reply header.'
    end
    local entries = {}
    for index = 1, 24 do
        local owned, active = b[15 + index * 2], b[16 + index * 2]
        if owned > 254 or owned % 2 ~= 0 or active > M.MAX_BRANCHES then
            return nil, 'Invalid crystal collection entry.'
        end
        entries[index] = { owned_mask = owned, active = active }
    end
    return {
        kind       = 'state',
        result     = b[10],
        request_id = b[11] + b[12] * 256,
        job        = b[13],
        level      = b[15],
        entries    = entries,
    }
end

function M.decode_catalog(packet)
    if type(packet) ~= 'string' or #packet < 20 or #packet > 256 then
        return nil, 'Invalid crystal catalog length.'
    end
    local b = { packet:byte(1, 20) }
    if b[1] ~= 0xff or b[2] % 2 ~= 1 or packet:sub(5, 8) ~= 'CRYC'
        or b[9] ~= 1 or b[10] > 3 or b[13] < 1 or b[13] > 23 or b[18] > 1 then
        return nil, 'Invalid crystal catalog header.'
    end
    local text_len = b[19] + b[20] * 256
    if text_len > 220 or #packet < 20 + text_len then
        return nil, 'Invalid crystal catalog payload length.'
    end
    return {
        kind         = 'catalog',
        catalog_kind = b[10],
        request_id   = b[11] + b[12] * 256,
        job_id       = b[13],
        branch_id    = b[14],
        index        = b[15],
        req_level    = b[16],
        chunk_idx    = b[17],
        chunk_flag   = b[18],
        text         = packet:sub(21, 20 + text_len),
    }
end

function M.decode_packet(packet)
    if type(packet) ~= 'string' or #packet < 8 then
        return nil, 'Invalid crystal packet.'
    end
    local magic = packet:sub(5, 8)
    if magic == 'CRYS' then
        return M.decode_reply(packet)
    elseif magic == 'CRYC' then
        return M.decode_catalog(packet)
    end
    return nil, 'Unknown crystal packet signature.'
end

return M
