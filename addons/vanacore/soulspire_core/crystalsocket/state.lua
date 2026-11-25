local protocol = require('protocol')
local okReg, soulRegistry = pcall(require, 'soul_registry_generated')
if not okReg or type(soulRegistry) ~= 'table' then soulRegistry = nil end
local State = {}
State.__index = State

local messages = {
    [0] = 'Collection updated.',
    [1] = 'That soul crystal is locked by level.',
    [2] = 'Your main job changed; refresh to continue.',
    [3] = 'Cannot swap soul crystals right now.',
    [4] = 'The server rejected the crystal request.',
}

local function valid_time(now)
    return type(now) == 'number' and now >= 0 and now < math.huge
end

local function split_sep(str, sep)
    local out = {}
    local start = 1
    while true do
        local pos = string.find(str, sep, start, true)
        if not pos then
            out[#out + 1] = string.sub(str, start)
            break
        end
        out[#out + 1] = string.sub(str, start, pos - 1)
        start = pos + 1
    end
    return out
end

local function copy_catalog(cat)
    if not cat then return nil end
    local entries = {}
    for i, e in ipairs(cat.entries or {}) do
        local hl = {}
        for j, line in ipairs(e.highlights or {}) do hl[j] = line end
        local reg = soulRegistry and soulRegistry.resolve and soulRegistry.resolve(e.key) or nil
        entries[i] = {
            id          = e.id,
            permanent_id = reg and reg.id or nil,
            key         = e.key,
            name        = (reg and reg.displayName) or e.name,
            role        = e.role,
            icon        = (reg and reg.icon) or e.icon,
            req_level   = e.req_level,
            description = e.description,
            highlights  = hl,
        }
    end
    return {
        job_id   = cat.job_id,
        job_name = cat.job_name,
        entries  = entries,
    }
end

function State.new()
    return setmetatable({
        next_request = 0,
        open = false,
        status = 'offline',
        message = 'Log in to load your soul crystals.',
        catalogs = {},
        builders = {},
        auto_attempted = false,
        needs_refresh = false,
    }, State)
end

function State:reset(reason, keep_catalogs)
    self.open = false
    self.pending = nil
    self.accepted = nil
    self.all_entries = nil
    self.last_result = nil
    self.auto_attempted = false
    self.needs_refresh = false
    self.builders = {}
    if not keep_catalogs then
        self.catalogs = {}
    end
    self.status = self.session_key ~= nil and 'unloaded' or 'offline'
    self.message = reason or 'Refresh to load your soul crystals.'
end

function State:set_context(session_key, job, zone, level)
    local base_changed = self.session_key ~= session_key or self.current_job ~= job or self.zone ~= zone
    if not base_changed then
        if level ~= nil and self.current_lvl ~= level then
            self.current_lvl = level
            if self.accepted ~= nil then
                self.needs_refresh = true
            end
        end
        return false
    end

    local same_session = self.session_key == session_key and session_key ~= nil
    self.session_key, self.current_job, self.zone, self.current_lvl = session_key, job, zone, level
    self:reset(session_key == nil and 'Log in to load your soul crystals.'
        or 'Refresh to load your soul crystals.', same_session)
    return true
end

function State:request(operation, branch, now, send, target_job)
    if not valid_time(now) then return nil, 'Invalid request time.' end
    self:tick(now)
    if self.session_key == nil then return nil, 'Log in first.' end
    if type(self.current_job) ~= 'number' or self.current_job % 1 ~= 0
        or self.current_job < 1 or self.current_job > 23 then
        return nil, 'Main job is not available yet.'
    end
    if self.pending then return nil, 'A crystal request is already pending.' end
    if type(send) ~= 'function' then return nil, 'Crystal transport is unavailable.' end
    if self.next_request >= 0x7fff then
        return nil, 'Crystal request IDs exhausted; reload the addon.'
    end

    local job_arg = target_job or self.current_job
    local request_id = self.next_request + 1
    local packet, why = protocol.encode_request(operation, request_id, job_arg, branch)
    if not packet then return nil, why end

    if operation == protocol.OP_SELECT then
        if not self.accepted then return nil, 'Refresh the collection first.' end
        local catalog = self.catalogs[self.current_job]
        if not catalog or #(catalog.entries or {}) == 0 then
            return nil, 'No soul crystals available for this job.'
        end
        if branch ~= 0 and not protocol.owns(self.accepted.owned_mask, branch) then
            return nil, 'That soul crystal is locked.'
        end
    end

    self.next_request = request_id
    self.pending = { request_id = request_id, operation = operation, since = now }
    self.status, self.message = 'loading', 'Waiting for the server...'

    local ok, sent, error_message = pcall(send, packet)
    if not ok or sent ~= true then
        self.pending = nil
        self.accepted, self.last_result = nil, nil
        self.status, self.message = 'error', 'Crystal request could not be sent.'
        return nil, self.message .. (ok and type(error_message) == 'string' and ' ' .. error_message or '')
    end
    return true
end

function State:sync_current(now, send, force_catalog)
    local op = (force_catalog or not self.catalogs[self.current_job])
        and protocol.OP_SYNC_CATALOG
        or protocol.OP_QUERY
    return self:request(op, 0, now, send, self.current_job)
end

function State:ensure_loaded(now, send)
    if self.session_key == nil or self.pending then return false end
    if type(self.current_job) ~= 'number' or self.current_job < 1 or self.current_job > 23 then
        return false
    end
    if self.accepted and self.catalogs[self.current_job] and not self.needs_refresh then
        return false
    end
    if self.auto_attempted and not self.needs_refresh then
        return false
    end
    self.auto_attempted = true
    self.needs_refresh = false
    return self:sync_current(now, send, false)
end

function State:show(now, send)
    self.open = true
    if self.pending then return true end
    return self:sync_current(now, send, false)
end

function State:cancel()
    self.open = false
end

function State:tick(now)
    if not valid_time(now) or not self.pending or now - self.pending.since < 10 then
        return false
    end
    self.builders[self.pending.request_id] = nil
    self.pending = nil
    self.accepted, self.last_result = nil, nil
    self.status, self.message = 'error', 'No crystal reply; refresh to retry.'
    return true
end

function State:receive_catalog_chunk(msg)
    if not self.pending or self.pending.request_id ~= msg.request_id then
        return nil, 'Unsolicited or stale crystal catalog packet.'
    end
    local builder = self.builders[msg.request_id]
    if not builder then
        builder = { job_id = msg.job_id, job_name = '', entries = {}, by_id = {}, chunks = {} }
        self.builders[msg.request_id] = builder
    end

    local chunk_key = ('%d:%d:%d:%d'):format(msg.catalog_kind, msg.job_id, msg.branch_id, msg.index)
    local chunk = builder.chunks[chunk_key]
    if not chunk then
        chunk = { parts = {}, final_count = nil }
        builder.chunks[chunk_key] = chunk
    end
    chunk.parts[msg.chunk_idx + 1] = msg.text

    if msg.chunk_flag == 0 then
        chunk.final_count = msg.chunk_idx + 1
    end

    if not chunk.final_count then
        return true
    end

    for i = 1, chunk.final_count do
        if chunk.parts[i] == nil then
            return true
        end
    end

    local full_text = table.concat(chunk.parts, '', 1, chunk.final_count)
    builder.chunks[chunk_key] = nil

    if msg.catalog_kind == protocol.CATALOG_BEGIN then
        builder.job_id = msg.job_id
        builder.job_name = full_text
        builder.entries = {}
        builder.by_id = {}
    elseif msg.catalog_kind == protocol.CATALOG_ENTRY then
        local fields = split_sep(full_text, '\31')
        local entry = {
            id          = msg.branch_id,
            key         = fields[1] or '',
            name        = fields[2] or '',
            role        = fields[3] or '',
            icon        = fields[4] or '',
            description = fields[5] or '',
            req_level   = msg.req_level,
            highlights  = {},
        }
        builder.entries[#builder.entries + 1] = entry
        builder.by_id[entry.id] = entry
    elseif msg.catalog_kind == protocol.CATALOG_HIGHLIGHT then
        local entry = builder.by_id[msg.branch_id]
        if entry then
            entry.highlights[msg.index] = full_text
        end
    elseif msg.catalog_kind == protocol.CATALOG_END then
        builder.complete = true
        self.catalogs[builder.job_id] = {
            job_id   = builder.job_id,
            job_name = builder.job_name,
            entries  = builder.entries,
        }
    end
    return true
end

function State:receive(packet, now)
    if not valid_time(now) then return nil, 'Invalid reply time.' end
    self:tick(now)
    local msg, why = protocol.decode_packet(packet)
    if not msg then return nil, why end

    if msg.kind == 'catalog' then
        return self:receive_catalog_chunk(msg)
    end

    if not self.pending or self.pending.request_id ~= msg.request_id then
        return nil, 'Unsolicited or stale crystal reply.'
    end
    if msg.job ~= self.current_job then
        self:reset('Main job changed; refresh the collection.', true)
        return nil, 'Crystal reply main job does not match the current session.'
    end

    local mutation = self.pending.operation == protocol.OP_SELECT
    self.builders[msg.request_id] = nil
    self.pending = nil
    self.all_entries = msg.entries
    -- Wire entries use zero-based job IDs; Lua tables start at one.
    self.accepted = msg.entries[self.current_job + 1]
    if msg.level and msg.level > 0 then
        self.current_lvl = msg.level
    end
    self.needs_refresh = false
    self.last_result = msg.result
    self.status = msg.result == 0 and 'ready' or 'error'
    self.message = messages[msg.result] or 'Unknown crystal server status.'
    if mutation and msg.result == 0 then self.open = false end
    return true
end

function State:snapshot()
    local catalog = self.current_job and copy_catalog(self.catalogs[self.current_job]) or nil
    return {
        open            = self.open,
        status          = self.status,
        message         = self.message,
        loaded          = self.accepted ~= nil,
        pending         = self.pending ~= nil,
        pending_request = self.pending and self.pending.request_id or nil,
        owned_mask      = self.accepted and self.accepted.owned_mask or 0,
        active          = self.accepted and self.accepted.active or 0,
        current_job     = self.current_job,
        current_lvl     = self.current_lvl,
        session_key     = self.session_key,
        zone            = self.zone,
        last_result     = self.last_result,
        catalog         = catalog,
    }
end

return State
