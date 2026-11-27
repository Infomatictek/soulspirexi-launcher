-- SoulspireXI Core: Shared Data Service (Static Verified Cache + Compatibility + Diagnostics)
--
-- Single reusable data-access layer for SoulspireXI Core modules (Weapon Mastery,
-- Character, Soul Talents, and future Abilities / Equipment / Journal) and
-- standalone soulspire_talents.
--
-- Security & Architecture Guarantees:
--   1. Never executes Lua from cached files — parses strictly pure JSON via core/json.lua.
--   2. Verifies SHA-256 and exact byte size of every cache package against cache/manifest.json
--      ONCE per session at load time (zero per-frame file I/O or hashing).
--   3. Cache data is strictly static presentation/structural metadata. The server remains
--      100% authoritative over ownership, eligibility, talent points, ranks, costs, and combat.
--   4. Corrupted, missing, or schema-incompatible caches fail safely with an explicit
--      launcher update/repair prompt and allow clean fallback to legacy server sync.

local json   = require('core.json')
local sha256 = require('core.sha256')

local DataService = {}
DataService.__index = DataService

DataService.SUPPORTED_SCHEMA_VERSION = 1
DataService.PROTOCOL_VERSION         = 2
DataService.MAX_DIAG_EVENTS          = 40

local EAGER_PACKAGES = { 'souls', 'weapon_skills', 'ui_metadata' }
local ALL_PACKAGES   = { 'souls', 'weapon_skills', 'talents', 'abilities', 'equipment', 'ui_metadata' }

local function read_file_bytes(path)
    local f, err = io.open(path, 'rb')
    if not f then
        return nil, err or 'file not found'
    end
    local data = f:read('*a')
    f:close()
    if type(data) ~= 'string' then
        return nil, 'unreadable file'
    end
    return data, nil
end

local function normalize_dir(path)
    if type(path) ~= 'string' or path == '' then return '.' end
    return path:gsub('\\', '/'):gsub('/+$', '')
end

local function shallow_copy_node(n)
    local out = {}
    for k, v in pairs(n) do
        out[k] = v
    end
    return out
end

function DataService.new(opts)
    opts = opts or {}
    local clock_fn = opts.clock or os.clock
    local cache_dir = opts.cache_dir
    if not cache_dir and type(opts.addon_path) == 'string' and opts.addon_path ~= '' then
        cache_dir = normalize_dir(opts.addon_path) .. '/cache'
    end
    cache_dir = normalize_dir(cache_dir or 'cache')

    local self = setmetatable({
        cache_dir        = cache_dir,
        clock            = clock_fn,
        manifest         = nil,
        packages         = {},
        package_status   = {}, -- pkgName -> { verified, size, sha256, loadMs, error }
        status           = 'unloaded', -- 'unloaded' | 'ready' | 'missing' | 'corrupt' | 'incompatible'
        error_message    = nil,
        compat_state     = 'unverified', -- 'unverified' | 'compatible' | 'outdated_content' | 'incompatible_schema' | 'corrupt_local' | 'legacy_server'
        server_compat    = nil,
        load_ms_total    = 0,
        loaded_once      = false,

        -- Indexed lookup tables built once per package load
        souls_ordered    = {},
        souls_by_id      = {},
        souls_by_key     = {},
        souls_by_jb      = {}, -- [jobId][branchId] -> soul
        souls_by_job     = {}, -- [jobId] -> { soul1, soul2, soul3 }

        ws_ordered       = {},
        ws_by_id         = {}, -- numeric wsId -> ws
        ws_by_stable_id  = {}, -- string stable id -> ws
        skill_families   = {},

        talent_rules     = nil,
        talent_trees     = nil, -- raw parsed trees map keyed by tostring(wsId)
        resolved_trees   = {},  -- memoized resolved tree cache keyed by "wsId:variant"

        abilities_by_soul = nil,
        equipment_data    = nil,
        ui_metadata       = nil,

        listeners        = {},
        diag_events      = {},
        sync_log         = {}, -- timestamped per-request sync telemetry (max 32 entries)
        warmup_state     = nil, -- cooperative background warmup for large talents.json
        warmup_stats     = {
            frames      = 0,
            maxFrameMs  = 0,
            totalMs     = 0,
            treesParsed = 0,
            phase       = 'idle',
        },
        metrics          = {
            packets_in_oxtl    = 0,
            packets_out_oxtl   = 0,
            bytes_in_oxtl      = 0,
            packets_in_crys    = 0,
            packets_out_crys   = 0,
            bytes_in_crys      = 0,
            sync_retries       = 0,
            timeouts           = 0,
            invalidations      = 0,
            cache_hits_catalog = 0,
            cache_hits_ws      = 0,
            cache_hits_souls   = 0,
            stale_dropped      = 0,
            deduped_requests   = 0,
        },
    }, DataService)

    if opts.auto_load ~= false then
        self:load()
    end

    return self
end

function DataService:subscribe(event_name, fn)
    if type(event_name) ~= 'string' or type(fn) ~= 'function' then return end
    self.listeners[event_name] = self.listeners[event_name] or {}
    self.listeners[event_name][#self.listeners[event_name] + 1] = fn
end

function DataService:emit(event_name, payload)
    local list = self.listeners[event_name]
    if not list then return end
    for _, fn in ipairs(list) do
        pcall(fn, payload, self)
    end
end

function DataService:record_event(domain, kind, detail)
    local ev = {
        at     = self.clock(),
        domain = tostring(domain or 'core'),
        kind   = tostring(kind or 'info'),
        detail = tostring(detail or ''),
    }
    local list = self.diag_events
    if #list >= DataService.MAX_DIAG_EVENTS then
        table.remove(list, 1)
    end
    list[#list + 1] = ev
    if self.listeners and self.listeners.diag_event then
        self:emit('diag_event', ev)
    end
end

function DataService:record_metric(key, delta)
    if self.metrics[key] ~= nil then
        self.metrics[key] = self.metrics[key] + (tonumber(delta) or 1)
    end
end

function DataService:record_sync_attempt(entry)
    if type(entry) ~= 'table' then return end
    local rec = {
        reqId           = entry.reqId or 0,
        op              = tostring(entry.op or 'unknown'),
        wsId            = tonumber(entry.wsId) or 0,
        startedAt       = tonumber(entry.startedAt) or 0,
        completedAt     = tonumber(entry.completedAt) or self.clock(),
        latencyMs       = tonumber(entry.latencyMs) or 0,
        packetsIn       = tonumber(entry.packetsIn) or 0,
        bytesIn         = tonumber(entry.bytesIn) or 0,
        retries         = tonumber(entry.retries) or 0,
        outcome         = tostring(entry.outcome or 'ok'),
        timeoutReason   = entry.timeoutReason,
        cacheHit        = entry.cacheHit == true,
        protocolVersion = tonumber(entry.protocolVersion) or DataService.PROTOCOL_VERSION,
        waitingOn       = tostring(entry.waitingOn or 'idle'),
    }
    local list = self.sync_log
    if #list >= 32 then
        table.remove(list, 1)
    end
    list[#list + 1] = rec
    if self.listeners and self.listeners.sync_attempt then
        self:emit('sync_attempt', rec)
    end
end

function DataService:get_sync_stats()
    local latencies = {}
    local total_ms, max_ms, ok_count, fail_count = 0, 0, 0, 0
    for _, rec in ipairs(self.sync_log or {}) do
        if rec.outcome == 'ok' then
            ok_count = ok_count + 1
            local ms = tonumber(rec.latencyMs) or 0
            latencies[#latencies + 1] = ms
            total_ms = total_ms + ms
            if ms > max_ms then max_ms = ms end
        elseif rec.outcome == 'timeout' or rec.outcome == 'error' then
            fail_count = fail_count + 1
        end
    end
    table.sort(latencies)
    local p95 = 0
    if #latencies > 0 then
        local idx = math.max(1, math.min(#latencies, math.ceil(#latencies * 0.95)))
        p95 = latencies[idx]
    end
    return {
        completedCount    = ok_count,
        failureCount      = fail_count,
        avgLatencyMs      = ok_count > 0 and (total_ms / ok_count) or 0,
        p95LatencyMs      = p95,
        maxLatencyMs      = max_ms,
        retries           = self.metrics.sync_retries or 0,
        timeouts          = self.metrics.timeouts or 0,
        staleDropped      = self.metrics.stale_dropped or 0,
        dedupedRequests   = self.metrics.deduped_requests or 0,
    }
end

function DataService:_fail_cache(status_kind, reason)
    self.status = status_kind
    self.error_message = tostring(reason or 'Cache verification failed.')
    if status_kind == 'corrupt' or status_kind == 'missing' then
        self.compat_state = 'corrupt_local'
    elseif status_kind == 'incompatible' then
        self.compat_state = 'incompatible_schema'
    end
    self:record_event('cache', status_kind, self.error_message)
    self:emit('cache_error', { status = status_kind, message = self.error_message })
    return false, self.error_message
end

function DataService:_index_souls(pkg)
    self.souls_ordered = {}
    self.souls_by_id   = {}
    self.souls_by_key  = {}
    self.souls_by_jb   = {}
    self.souls_by_job  = {}

    local list = type(pkg) == 'table' and pkg.souls or nil
    if type(list) ~= 'table' then return false, 'souls.json missing souls array' end

    for _, s in ipairs(list) do
        if type(s) == 'table' and type(s.id) == 'string' and s.id ~= '' then
            self.souls_ordered[#self.souls_ordered + 1] = s
            self.souls_by_id[s.id] = s
            if type(s.internalKey) == 'string' and s.internalKey ~= '' then
                self.souls_by_key[string.lower(s.internalKey)] = s
            end
            if type(s.canonicalKey) == 'string' and s.canonicalKey ~= '' then
                self.souls_by_key[string.lower(s.canonicalKey)] = s
            end
            if type(s.displayName) == 'string' and s.displayName ~= '' then
                self.souls_by_key[string.lower(s.displayName)] = s
            end
            if type(s.legacyAliases) == 'table' then
                for _, alias in ipairs(s.legacyAliases) do
                    if type(alias) == 'string' and alias ~= '' then
                        self.souls_by_key[string.lower(alias)] = s
                    end
                end
            end
            local jid = tonumber(s.jobId)
            local bid = tonumber(s.branchId)
            if jid and bid then
                self.souls_by_jb[jid] = self.souls_by_jb[jid] or {}
                self.souls_by_jb[jid][bid] = s
                self.souls_by_job[jid] = self.souls_by_job[jid] or {}
                self.souls_by_job[jid][#self.souls_by_job[jid] + 1] = s
            end
        end
    end

    for _, arr in pairs(self.souls_by_job) do
        table.sort(arr, function(a, b) return (a.branchId or 0) < (b.branchId or 0) end)
    end
    return true, nil
end

function DataService:_index_weapon_skills(pkg)
    self.ws_ordered      = {}
    self.ws_by_id        = {}
    self.ws_by_stable_id = {}
    self.skill_families  = (type(pkg) == 'table' and type(pkg.skillFamilies) == 'table') and pkg.skillFamilies or {}

    local list = type(pkg) == 'table' and pkg.weaponSkills or nil
    if type(list) ~= 'table' then return false, 'weapon_skills.json missing weaponSkills array' end

    for _, ws in ipairs(list) do
        if type(ws) == 'table' and type(ws.wsId) == 'number' then
            -- Provide convenient alias fields matching Soulforge catalog entries (id=wsId, skill=skillId)
            local rec = {
                stableId           = ws.id,
                id                 = ws.wsId,
                wsId               = ws.wsId,
                key                = ws.key or '',
                name               = ws.name or ('WS #' .. tostring(ws.wsId)),
                skill              = tonumber(ws.skillId) or 0,
                skillId            = tonumber(ws.skillId) or 0,
                skillName          = ws.skillName or '',
                wsType             = ws.wsType or 'physical',
                elementName        = ws.elementName,
                archetype          = ws.archetype or ws.wsType or 'heavy',
                evolution          = ws.evolution == true,
                maxPoints          = tonumber(ws.maxPoints) or 56,
                isCustomThrowing   = ws.isCustomThrowing == true,
                isSpecAdaptive     = ws.isSpecAdaptive == true,
                aftermath          = ws.aftermath,
                debuff             = ws.debuff,
                defaultSkillchains = ws.defaultSkillchains or {},
                iconPath           = ws.iconPath,
                description        = ws.description or '',
            }
            self.ws_ordered[#self.ws_ordered + 1] = rec
            self.ws_by_id[rec.wsId] = rec
            if type(rec.stableId) == 'string' then
                self.ws_by_stable_id[rec.stableId] = rec
            end
        end
    end
    return true, nil
end

function DataService:_index_talents(pkg)
    if type(pkg) ~= 'table' or type(pkg.trees) ~= 'table' then
        return false, 'talents.json missing trees map'
    end
    self.talent_rules   = pkg.rules or {}
    self.talent_trees   = pkg.trees
    self.resolved_trees = {}
    return true, nil
end

function DataService:_index_abilities(pkg)
    if type(pkg) ~= 'table' or type(pkg.entries) ~= 'table' then
        return false, 'abilities.json missing entries array'
    end
    local by_soul = {}
    for _, entry in ipairs(pkg.entries) do
        if type(entry) == 'table' and type(entry.soulId) == 'string' and entry.soulId ~= '' then
            by_soul[entry.soulId] = by_soul[entry.soulId] or {}
            by_soul[entry.soulId][#by_soul[entry.soulId] + 1] = entry
        end
    end
    self.abilities_by_soul = by_soul
    return true, nil
end

function DataService:_index_equipment(pkg)
    if type(pkg) ~= 'table' then
        return false, 'equipment.json root must be an object'
    end
    local by_soul = {}
    for _, wm in ipairs(pkg.soulWeaponModes or {}) do
        if type(wm) == 'table' and type(wm.soulId) == 'string' then
            by_soul[wm.soulId] = wm
        end
    end
    self.equipment_data = {
        items           = pkg.items or {},
        weaponFamilies  = pkg.weaponFamilies or {},
        soulWeaponModes = by_soul,
    }
    return true, nil
end

function DataService:_index_ui_metadata(pkg)
    if type(pkg) ~= 'table' then
        return false, 'ui_metadata.json root must be an object'
    end
    self.ui_metadata = pkg
    return true, nil
end

function DataService:load_package(pkg_name)
    if self.packages[pkg_name] ~= nil then
        return self.packages[pkg_name], nil
    end
    if not self.manifest or type(self.manifest.packages) ~= 'table' then
        return nil, self.error_message or 'Cache manifest not loaded.'
    end
    local info = self.manifest.packages[pkg_name]
    if type(info) ~= 'table' or type(info.file) ~= 'string' then
        return nil, 'Manifest missing package entry: ' .. tostring(pkg_name)
    end
    -- Guard against path traversal in manifest file name
    if info.file:find('..', 1, true) or info.file:find('/', 1, true) or info.file:find('\\', 1, true) then
        self:_fail_cache('corrupt', 'Unsafe package filename in manifest: ' .. tostring(info.file))
        return nil, self.error_message
    end

    local t0 = self.clock()
    local full_path = self.cache_dir .. '/' .. info.file
    local raw, read_err = read_file_bytes(full_path)
    if not raw then
        self.package_status[pkg_name] = { verified = false, error = 'missing: ' .. tostring(read_err) }
        self:_fail_cache('missing', string.format('Missing cache package %s (%s). Run SoulspireLauncher to update.', info.file, tostring(read_err)))
        return nil, self.error_message
    end

    if type(info.size) == 'number' and #raw ~= info.size then
        self.package_status[pkg_name] = { verified = false, size = #raw, error = 'size mismatch' }
        self:_fail_cache('corrupt', string.format('Cache integrity failed for %s (size %d != %d). Run SoulspireLauncher to repair.', info.file, #raw, info.size))
        return nil, self.error_message
    end

    local actual_sha = sha256.digest(raw)
    if type(info.sha256) ~= 'string' or actual_sha ~= string.lower(info.sha256) then
        self.package_status[pkg_name] = { verified = false, size = #raw, sha256 = actual_sha, error = 'sha256 mismatch' }
        self:_fail_cache('corrupt', string.format('Cache SHA-256 mismatch for %s. Run SoulspireLauncher to repair.', info.file))
        return nil, self.error_message
    end

    local parsed, dec_err = json.decode(raw)
    if not parsed or type(parsed) ~= 'table' then
        self.package_status[pkg_name] = { verified = false, size = #raw, sha256 = actual_sha, error = 'json parse error' }
        self:_fail_cache('corrupt', string.format('Malformed JSON in %s: %s', info.file, tostring(dec_err)))
        return nil, self.error_message
    end

    if tonumber(parsed.schemaVersion) ~= tonumber(self.manifest.schemaVersion) then
        self.package_status[pkg_name] = { verified = false, error = 'schema mismatch' }
        self:_fail_cache('incompatible', string.format('Schema mismatch in %s.', info.file))
        return nil, self.error_message
    end

    local ok_idx, idx_err = true, nil
    if pkg_name == 'souls' then
        ok_idx, idx_err = self:_index_souls(parsed)
    elseif pkg_name == 'weapon_skills' then
        ok_idx, idx_err = self:_index_weapon_skills(parsed)
    elseif pkg_name == 'talents' then
        ok_idx, idx_err = self:_index_talents(parsed)
    elseif pkg_name == 'abilities' then
        ok_idx, idx_err = self:_index_abilities(parsed)
    elseif pkg_name == 'equipment' then
        ok_idx, idx_err = self:_index_equipment(parsed)
    elseif pkg_name == 'ui_metadata' then
        ok_idx, idx_err = self:_index_ui_metadata(parsed)
    end
    if not ok_idx then
        self.package_status[pkg_name] = { verified = false, error = idx_err }
        self:_fail_cache('corrupt', string.format('Invalid cache structure in %s: %s', info.file, tostring(idx_err)))
        return nil, self.error_message
    end

    local elapsed_ms = (self.clock() - t0) * 1000
    self.load_ms_total = self.load_ms_total + elapsed_ms
    self.packages[pkg_name] = parsed
    self.package_status[pkg_name] = {
        verified = true,
        size     = #raw,
        sha256   = actual_sha,
        loadMs   = elapsed_ms,
    }
    return parsed, nil
end

function DataService:load()
    if self.loaded_once and self.status == 'ready' then
        return true, nil
    end

    self.loaded_once = true
    local manifest_path = self.cache_dir .. '/manifest.json'
    local raw, read_err = read_file_bytes(manifest_path)
    if not raw then
        return self:_fail_cache('missing', 'Client cache manifest missing (' .. tostring(read_err) .. '). Run SoulspireLauncher to update.')
    end

    local parsed, dec_err = json.decode(raw)
    if not parsed or type(parsed) ~= 'table' then
        return self:_fail_cache('corrupt', 'Client cache manifest is malformed: ' .. tostring(dec_err))
    end

    local schema_ver = tonumber(parsed.schemaVersion) or 0
    local min_schema = tonumber(parsed.minCompatibleSchemaVersion) or schema_ver
    if schema_ver < 1 or DataService.SUPPORTED_SCHEMA_VERSION < min_schema or schema_ver > DataService.SUPPORTED_SCHEMA_VERSION then
        return self:_fail_cache('incompatible', string.format(
            'Client cache schema v%d is incompatible with Core v%d. Update via SoulspireLauncher.',
            schema_ver, DataService.SUPPORTED_SCHEMA_VERSION
        ))
    end

    if type(parsed.packages) ~= 'table' or type(parsed.contentVersion) ~= 'string' or parsed.contentVersion == '' then
        return self:_fail_cache('corrupt', 'Client cache manifest missing required metadata.')
    end

    self.manifest = parsed

    -- Verify and load eager lightweight packages ONCE at session startup (~7ms)
    for _, pkg_name in ipairs(EAGER_PACKAGES) do
        local ok, err = self:load_package(pkg_name)
        if not ok then
            return false, err
        end
    end

    self.status = 'ready'
    self.error_message = nil
    self:record_event('cache', 'loaded', string.format(
        'v=%s hash=%s souls=%d ws=%d load=%.1fms',
        tostring(self.manifest.contentVersion),
        tostring(self.manifest.registryHash),
        #self.souls_ordered,
        #self.ws_ordered,
        self.load_ms_total
    ))
    self:emit('cache_loaded', self:get_cache_info())
    return true, nil
end

function DataService:verify_all()
    if self.status ~= 'ready' then
        local ok, err = self:load()
        if not ok then return false, err end
    end
    for _, pkg_name in ipairs(ALL_PACKAGES) do
        local pkg, err = self:load_package(pkg_name)
        if not pkg then
            return false, err
        end
    end
    return true, nil
end

function DataService:is_cache_ready()
    return self.status == 'ready' and self.manifest ~= nil
end

function DataService:is_cache_usable()
    if not self:is_cache_ready() then return false end
    return self.compat_state ~= 'incompatible_schema' and self.compat_state ~= 'corrupt_local'
end

function DataService:get_cache_info()
    local m = self.manifest
    return {
        status          = self.status,
        error           = self.error_message,
        compatState     = self.compat_state,
        schemaVersion   = m and tonumber(m.schemaVersion) or 0,
        protocolVersion = m and tonumber(m.protocolVersion) or DataService.PROTOCOL_VERSION,
        contentVersion  = m and tostring(m.contentVersion or '') or '',
        contentHash     = m and tostring(m.contentHash or '') or '',
        registryVersion = m and tostring(m.registryVersion or '') or '',
        registryHash    = m and tostring(m.registryHash or '') or '',
        loadMs          = self.load_ms_total,
    }
end

-- Compare local verified cache metadata against server-advertised requirements.
-- IMPORTANT: This is compatibility metadata ONLY — never gameplay authorization.
function DataService:apply_server_compat(server_info)
    if type(server_info) ~= 'table' then return self.compat_state end
    self.server_compat = {
        protocolVersion = tonumber(server_info.protocolVersion) or 1,
        schemaVersion   = tonumber(server_info.schemaVersion) or 1,
        minSchema       = tonumber(server_info.minSchema) or 1,
        contentVersion  = tostring(server_info.contentVersion or ''),
        contentHash     = tostring(server_info.contentHash or ''),
        registryHash    = tostring(server_info.registryHash or ''),
    }

    if not self:is_cache_ready() then
        self.compat_state = (self.status == 'incompatible') and 'incompatible_schema' or 'corrupt_local'
        self:emit('compat_changed', { state = self.compat_state, server = self.server_compat })
        return self.compat_state
    end

    local local_schema = tonumber(self.manifest.schemaVersion) or 0
    local local_hash   = tostring(self.manifest.contentHash or '')
    local local_reg    = tostring(self.manifest.registryHash or '')

    if local_schema < self.server_compat.minSchema or local_schema > self.server_compat.schemaVersion then
        self.compat_state = 'incompatible_schema'
        self.error_message = string.format(
            'Cache schema v%d incompatible with server (requires v%d..v%d). Update via SoulspireLauncher.',
            local_schema, self.server_compat.minSchema, self.server_compat.schemaVersion
        )
    elseif (self.server_compat.registryHash ~= '' and local_reg ~= self.server_compat.registryHash)
        or (self.server_compat.contentHash ~= '' and local_hash ~= self.server_compat.contentHash) then
        self.compat_state = 'outdated_content'
        self.error_message = string.format(
            'Client cache (%s) differs from server (%s). Update via SoulspireLauncher for latest descriptions.',
            local_hash ~= '' and local_hash or local_reg,
            self.server_compat.contentHash ~= '' and self.server_compat.contentHash or self.server_compat.registryHash
        )
    else
        self.compat_state = 'compatible'
        self.error_message = nil
    end

    self:record_event('compat', self.compat_state, string.format(
        'local=%s/%s server=%s/%s',
        local_reg, local_hash, self.server_compat.registryHash, self.server_compat.contentHash
    ))
    self:emit('compat_changed', { state = self.compat_state, server = self.server_compat })
    return self.compat_state
end

function DataService:mark_legacy_server()
    if self.server_compat == nil then
        self.compat_state = 'legacy_server'
        self:record_event('compat', 'legacy_server', 'Server responded using legacy OXTL v1 protocol.')
    end
end

function DataService:invalidate_dynamic_state(reason)
    self:record_metric('invalidations', 1)
    self:record_event('lifecycle', 'invalidate', tostring(reason or 'context_change'))
    self:emit('state_invalidated', { reason = reason })
end

-- ---------------------------------------------------------------------------
-- Static Metadata Lookups (Souls, Weapon Skills, Talents, Abilities, Equipment)
-- ---------------------------------------------------------------------------
function DataService:get_all_souls()
    if not self:is_cache_usable() then return {} end
    return self.souls_ordered
end

function DataService:get_soul_by_id(permanent_id)
    if not self:is_cache_usable() or type(permanent_id) ~= 'string' then return nil end
    return self.souls_by_id[permanent_id]
end

function DataService:get_soul_by_key(key_or_name)
    if not self:is_cache_usable() or type(key_or_name) ~= 'string' or key_or_name == '' then return nil end
    return self.souls_by_id[key_or_name] or self.souls_by_key[string.lower(key_or_name)]
end

function DataService:get_soul_by_job_branch(job_id, branch_id)
    if not self:is_cache_usable() then return nil end
    local j = self.souls_by_jb[tonumber(job_id) or 0]
    return j and j[tonumber(branch_id) or 0] or nil
end

function DataService:get_souls_for_job(job_id)
    if not self:is_cache_usable() then return {} end
    self:record_metric('cache_hits_souls', 1)
    return self.souls_by_job[tonumber(job_id) or 0] or {}
end

function DataService:get_all_weapon_skills()
    if not self:is_cache_usable() then return {} end
    self:record_metric('cache_hits_catalog', 1)
    return self.ws_ordered
end

function DataService:get_weapon_skill(ws_id)
    if not self:is_cache_usable() then return nil end
    return self.ws_by_id[tonumber(ws_id) or 0]
end

function DataService:get_weapon_skill_by_id(stable_id)
    if not self:is_cache_usable() then return nil end
    return self.ws_by_stable_id[tostring(stable_id or '')]
end

function DataService:get_skill_families()
    if not self:is_cache_usable() then return {} end
    return self.skill_families
end

function DataService:_ensure_talents_loaded()
    if not self:is_cache_usable() then return false end
    if self.talent_trees ~= nil then return true end
    -- If cooperative warmup already read & partially hashed talents.json, finish cleanly
    if self.warmup_state and self.warmup_state.pkg_name == 'talents' then
        while self.warmup_state and not self.warmup_state.done do
            self:step_warmup(1000.0)
        end
        if self.talent_trees ~= nil then return true end
    end
    local pkg = self:load_package('talents')
    return pkg ~= nil
end

-- Cooperative background warmup for talents.json (6.8MB) so file read, SHA-256 verification,
-- AND JSON parsing ALL run in small time-budgeted slices across d3d_present frames
-- (eliminating single-frame parse stalls on 32-bit Windows clients).
function DataService:step_warmup(budget_ms)
    if not self:is_cache_usable() or self.talent_trees ~= nil then
        return true
    end
    local info = self.manifest and self.manifest.packages and self.manifest.packages.talents
    if type(info) ~= 'table' or type(info.file) ~= 'string' then
        return true
    end
    local budget = math.max(1.0, tonumber(budget_ms) or 4.0) / 1000.0
    local start_t = self.clock()

    local function record_frame(phase_name)
        local dt_ms = math.max(0, (self.clock() - start_t) * 1000)
        self.warmup_stats.frames = (self.warmup_stats.frames or 0) + 1
        self.warmup_stats.totalMs = (self.warmup_stats.totalMs or 0) + dt_ms
        if dt_ms > (self.warmup_stats.maxFrameMs or 0) then
            self.warmup_stats.maxFrameMs = dt_ms
        end
        self.warmup_stats.phase = phase_name or self.warmup_stats.phase
        return dt_ms
    end

    local ws = self.warmup_state
    if not ws then
        if info.file:find('..', 1, true) or info.file:find('/', 1, true) or info.file:find('\\', 1, true) then
            self:_fail_cache('corrupt', 'Unsafe package filename in manifest: ' .. tostring(info.file))
            record_frame('error')
            return true
        end
        local full_path = self.cache_dir .. '/' .. info.file
        local raw, read_err = read_file_bytes(full_path)
        if not raw then
            self.package_status.talents = { verified = false, error = 'missing: ' .. tostring(read_err) }
            self:_fail_cache('missing', string.format('Missing cache package %s (%s). Run SoulspireLauncher to update.', info.file, tostring(read_err)))
            record_frame('error')
            return true
        end
        if type(info.size) == 'number' and #raw ~= info.size then
            self.package_status.talents = { verified = false, size = #raw, error = 'size mismatch' }
            self:_fail_cache('corrupt', string.format('Cache integrity failed for %s (size %d != %d). Run SoulspireLauncher to repair.', info.file, #raw, info.size))
            record_frame('error')
            return true
        end
        local dt_ms = record_frame('read')
        self.warmup_state = {
            pkg_name   = 'talents',
            file       = info.file,
            expected   = string.lower(tostring(info.sha256 or '')),
            raw        = raw,
            total      = #raw,
            pos        = 1,
            hasher     = sha256.new(),
            phase      = 'hash',
            elapsed_ms = dt_ms,
            done       = false,
        }
        return false
    end

    if ws.phase == 'hash' then
        local chunk = 262144 -- 256 KB per slice (~1.5-2.0ms in LuaJIT)
        while ws.pos <= ws.total do
            local e = math.min(ws.total, ws.pos + chunk - 1)
            ws.hasher:update(ws.raw, ws.pos, e)
            ws.pos = e + 1
            if (self.clock() - start_t) >= budget and ws.pos <= ws.total then
                ws.elapsed_ms = ws.elapsed_ms + record_frame('hash')
                return false
            end
        end
        local actual_sha = ws.hasher:final()
        if actual_sha ~= ws.expected then
            self.warmup_state = nil
            self.package_status.talents = { verified = false, size = ws.total, sha256 = actual_sha, error = 'sha256 mismatch' }
            self:_fail_cache('corrupt', string.format('Cache SHA-256 mismatch for %s. Run SoulspireLauncher to repair.', ws.file))
            record_frame('error')
            return true
        end
        ws.sha256 = actual_sha
        ws.hasher = nil
        -- Prepare incremental streaming JSON parser state (strip optional UTF-8 BOM)
        local p = 1
        if string.sub(ws.raw, 1, 3) == '\239\187\191' then
            p = 4
        end
        ws.json_pos = p
        ws.parsed   = {}
        ws.phase    = 'parse_header'
        ws.elapsed_ms = ws.elapsed_ms + record_frame('hash')
        return false
    end

    local function fail_parse(err_msg)
        ws.raw = nil
        self.warmup_state = nil
        self.package_status.talents = { verified = false, size = ws.total, sha256 = ws.sha256, error = 'json parse error' }
        self:_fail_cache('corrupt', string.format('Malformed JSON in %s: %s', ws.file, tostring(err_msg)))
        record_frame('error')
        return true
    end

    if ws.phase == 'parse_header' then
        local raw = ws.raw
        local pos = json.skip_ws(raw, ws.json_pos)
        if string.byte(raw, pos) ~= 123 then -- '{'
            return fail_parse('expected root object')
        end
        pos = json.skip_ws(raw, pos + 1)
        if string.byte(raw, pos) == 125 then -- '{}'
            ws.json_pos = pos + 1
            ws.phase = 'finalize'
        else
            while true do
                if string.byte(raw, pos) ~= 34 then
                    return fail_parse('expected root string key at byte ' .. tostring(pos))
                end
                local key, npos, kerr = json.decode_string_at(raw, pos)
                if kerr then return fail_parse(kerr) end
                pos = json.skip_ws(raw, npos)
                if string.byte(raw, pos) ~= 58 then -- ':'
                    return fail_parse('expected ":" after root key at byte ' .. tostring(pos))
                end
                pos = json.skip_ws(raw, pos + 1)
                if key == 'trees' and string.byte(raw, pos) == 123 then
                    -- Enter incremental per-tree parsing phase!
                    ws.parsed.trees = {}
                    ws.trees_pos = json.skip_ws(raw, pos + 1)
                    ws.phase = 'parse_trees'
                    break
                else
                    local val, vpos, verr = json.decode_value_at(raw, pos)
                    if verr then return fail_parse(verr) end
                    ws.parsed[key] = val
                    pos = json.skip_ws(raw, vpos)
                    local sep = string.byte(raw, pos)
                    if sep == 44 then -- ','
                        pos = json.skip_ws(raw, pos + 1)
                    elseif sep == 125 then -- '}'
                        ws.json_pos = pos + 1
                        ws.phase = 'finalize'
                        break
                    else
                        return fail_parse('expected "," or "}" in root object at byte ' .. tostring(pos))
                    end
                end
            end
        end
        ws.elapsed_ms = ws.elapsed_ms + record_frame('parse_header')
        if (self.clock() - start_t) >= budget and ws.phase ~= 'finalize' then
            return false
        end
    end

    if ws.phase == 'parse_trees' then
        local raw = ws.raw
        local pos = ws.trees_pos
        local trees = ws.parsed.trees
        while true do
            pos = json.skip_ws(raw, pos)
            local ch = string.byte(raw, pos)
            if ch == 125 then -- '}' end of trees object
                pos = json.skip_ws(raw, pos + 1)
                local sep = string.byte(raw, pos)
                if sep == 44 then -- ',' more root keys follow
                    ws.json_pos = json.skip_ws(raw, pos + 1)
                    ws.phase = 'parse_tail'
                elseif sep == 125 then -- '}' end of root object
                    ws.json_pos = pos + 1
                    ws.phase = 'finalize'
                else
                    return fail_parse('expected "," or "}" after trees at byte ' .. tostring(pos))
                end
                break
            end
            if ch ~= 34 then
                return fail_parse('expected string wsId key in trees at byte ' .. tostring(pos))
            end
            local wsKey, npos, kerr = json.decode_string_at(raw, pos)
            if kerr then return fail_parse(kerr) end
            pos = json.skip_ws(raw, npos)
            if string.byte(raw, pos) ~= 58 then
                return fail_parse('expected ":" after wsId key at byte ' .. tostring(pos))
            end
            pos = json.skip_ws(raw, pos + 1)
            local treeVal, vpos, verr = json.decode_value_at(raw, pos)
            if verr then return fail_parse(verr) end
            trees[wsKey] = treeVal
            self.warmup_stats.treesParsed = (self.warmup_stats.treesParsed or 0) + 1

            pos = json.skip_ws(raw, vpos)
            local sep = string.byte(raw, pos)
            if sep == 44 then -- ','
                pos = json.skip_ws(raw, pos + 1)
            elseif sep ~= 125 then
                return fail_parse('expected "," or "}" in trees at byte ' .. tostring(pos))
            end

            if (self.clock() - start_t) >= budget and string.byte(raw, pos) ~= 125 then
                ws.trees_pos = pos
                ws.elapsed_ms = ws.elapsed_ms + record_frame('parse_trees')
                return false
            end
        end
        if ws.phase ~= 'finalize' and (self.clock() - start_t) >= budget then
            ws.elapsed_ms = ws.elapsed_ms + record_frame('parse_trees')
            return false
        end
    end

    if ws.phase == 'parse_tail' then
        local raw = ws.raw
        local pos = ws.json_pos
        while true do
            pos = json.skip_ws(raw, pos)
            if string.byte(raw, pos) == 125 then
                ws.json_pos = pos + 1
                ws.phase = 'finalize'
                break
            end
            if string.byte(raw, pos) ~= 34 then
                return fail_parse('expected trailing root string key at byte ' .. tostring(pos))
            end
            local key, npos, kerr = json.decode_string_at(raw, pos)
            if kerr then return fail_parse(kerr) end
            pos = json.skip_ws(raw, npos)
            if string.byte(raw, pos) ~= 58 then
                return fail_parse('expected ":" after trailing root key at byte ' .. tostring(pos))
            end
            pos = json.skip_ws(raw, pos + 1)
            local val, vpos, verr = json.decode_value_at(raw, pos)
            if verr then return fail_parse(verr) end
            ws.parsed[key] = val
            pos = json.skip_ws(raw, vpos)
            local sep = string.byte(raw, pos)
            if sep == 44 then
                pos = json.skip_ws(raw, pos + 1)
            elseif sep == 125 then
                ws.json_pos = pos + 1
                ws.phase = 'finalize'
                break
            else
                return fail_parse('expected "," or "}" in root tail at byte ' .. tostring(pos))
            end
        end
    end

    if ws.phase == 'finalize' then
        local raw = ws.raw
        local trailing = json.skip_ws(raw, ws.json_pos)
        if trailing <= #raw then
            return fail_parse('trailing data after JSON root at byte ' .. tostring(trailing))
        end
        local parsed = ws.parsed
        ws.raw = nil -- release raw 6.8MB buffer immediately
        if tonumber(parsed.schemaVersion) ~= tonumber(self.manifest.schemaVersion) then
            self.warmup_state = nil
            self.package_status.talents = { verified = false, error = 'schema mismatch' }
            self:_fail_cache('incompatible', string.format('Schema mismatch in %s.', ws.file))
            record_frame('error')
            return true
        end
        local ok_idx, idx_err = self:_index_talents(parsed)
        if not ok_idx then
            self.warmup_state = nil
            self.package_status.talents = { verified = false, error = idx_err }
            self:_fail_cache('corrupt', string.format('Invalid cache structure in %s: %s', ws.file, tostring(idx_err)))
            record_frame('error')
            return true
        end
        local dt_ms = record_frame('ready')
        local total_ms = ws.elapsed_ms + dt_ms
        self.load_ms_total = self.load_ms_total + total_ms
        self.packages.talents = parsed
        self.package_status.talents = {
            verified = true,
            size     = ws.total,
            sha256   = ws.sha256,
            loadMs   = total_ms,
        }
        ws.done = true
        self.warmup_state = nil
        self:record_event('cache', 'talents_warmed', string.format('size=%dB total=%.1fms frames=%d maxFrame=%.2fms',
            ws.total, total_ms, self.warmup_stats.frames or 0, self.warmup_stats.maxFrameMs or 0))
        return true
    end
    return true
end

function DataService:is_talents_warm()
    return self.talent_trees ~= nil
end

-- Build an immediate non-authoritative static preview tree from verified local cache
-- so the UI displays the full circular Soulforge tree instantaneously without freezing
-- while live character ranks/eligibility sync from the server (all mutations gated).
function DataService:build_static_ws_preview(ws_id, spec_key)
    if not self:is_cache_usable() then return nil end
    local wsMeta = self:get_weapon_skill(ws_id)
    local tree   = self:get_ws_tree(ws_id, spec_key)
    if not wsMeta or not tree then return nil end

    local nodes = {}
    local byKey = {}
    for i, staticNode in ipairs(tree.nodes or {}) do
        local node = {
            idx         = tonumber(staticNode.idx) or i,
            slot        = tonumber(staticNode.slot) or i,
            key         = staticNode.key,
            tier        = tonumber(staticNode.tier) or 1,
            col         = tonumber(staticNode.col) or 1,
            rank        = 0,
            maxRank     = tonumber(staticNode.maxRank) or 1,
            canLearn    = false, -- Strictly disabled until server confirms live state!
            reqWsPoints = tonumber(staticNode.reqWsPoints) or 0,
            reqKey      = staticNode.reqKey,
            reqRank     = tonumber(staticNode.reqRank) or 0,
            name        = staticNode.name or staticNode.key,
            desc        = DataService.get_node_desc(staticNode, 0),
            nextDesc    = DataService.get_node_desc(staticNode, 1),
            reqLevel    = DataService.get_node_next_req_level(staticNode, 0),
            scTier      = tonumber(staticNode.scTier) or 0,
            scId        = 0,
            scName      = '',
            cost        = tonumber(staticNode.cost) or 1,
        }
        nodes[i] = node
        byKey[node.key] = node
    end

    return {
        id            = wsMeta.wsId or wsMeta.id,
        name          = wsMeta.name,
        skillName     = wsMeta.skillName or '',
        wsType        = wsMeta.wsType or 'physical',
        spent         = 0,
        orig          = 'Syncing live mastery state...',
        nodes         = nodes,
        byKey         = byKey,
        source        = 'cache_preview',
        syncStatus    = 'preview_cached',
        authoritative = false,
    }
end

function DataService:get_talent_rules()
    if not self:_ensure_talents_loaded() then return nil end
    return self.talent_rules
end

-- Resolve static talent tree for (wsId, specKey) with sparse specVariant overlay.
function DataService:get_ws_tree(ws_id, spec_key)
    if not self:_ensure_talents_loaded() then return nil end
    local wid = tonumber(ws_id)
    if not wid then return nil end
    local raw = self.talent_trees[tostring(wid)]
    if not raw then return nil end

    local norm_spec = type(spec_key) == 'string' and string.lower(spec_key) or ''
    local variant = (norm_spec ~= '' and raw.specVariants and raw.specVariants[norm_spec]) or nil
    local cache_key = tostring(wid) .. ':' .. (variant and norm_spec or (raw.defaultVariant or 'generic'))
    if self.resolved_trees[cache_key] then
        self:record_metric('cache_hits_ws', 1)
        return self.resolved_trees[cache_key]
    end

    local nodes = {}
    if variant and variant.mode == 'full' and type(variant.nodes) == 'table' then
        for i, n in ipairs(variant.nodes) do
            nodes[i] = shallow_copy_node(n)
        end
    else
        local patch = (variant and variant.mode == 'patch' and type(variant.nodes) == 'table') and variant.nodes or nil
        for i, base_n in ipairs(raw.nodes or {}) do
            local override = patch and patch[tostring(i)] or nil
            nodes[i] = shallow_copy_node(override or base_n)
        end
    end

    local by_key = {}
    for i, n in ipairs(nodes) do
        n.idx  = tonumber(n.idx) or i
        n.cost = tonumber(n.cost) or 1
        n.reqWsPoints = tonumber(n.reqWsPoints) or 0
        n.reqRank = tonumber(n.reqRank) or 0
        n.scTier = tonumber(n.scTier) or 0
        by_key[n.key] = n
    end

    local resolved = {
        wsId       = wid,
        wsStableId = raw.wsStableId,
        evolution  = raw.evolution == true,
        archetype  = raw.archetype or 'heavy',
        maxPoints  = tonumber(raw.maxPoints) or 56,
        variant    = variant and norm_spec or (raw.defaultVariant or 'generic'),
        nodes      = nodes,
        byKey      = by_key,
    }
    self.resolved_trees[cache_key] = resolved
    self:record_metric('cache_hits_ws', 1)
    return resolved
end

function DataService.get_node_desc(node, rank)
    if type(node) ~= 'table' then return '' end
    local descs = node.rankDescs
    if type(descs) ~= 'table' or #descs == 0 then
        return tostring(node.desc or '')
    end
    local r = math.max(0, math.floor(tonumber(rank) or 0))
    local idx = r + 1
    if idx > #descs then idx = #descs end
    return tostring(descs[idx] or descs[1] or '')
end

function DataService.get_node_next_req_level(node, current_rank)
    if type(node) ~= 'table' then return 1 end
    local lvls = node.rankReqLevels
    if type(lvls) ~= 'table' or #lvls == 0 then
        return tonumber(node.reqLevel) or 1
    end
    local next_r = math.max(1, math.floor(tonumber(current_rank) or 0) + 1)
    if next_r > #lvls then next_r = #lvls end
    return tonumber(lvls[next_r]) or 1
end

function DataService:get_skillchain_name(sc_id)
    local id = tonumber(sc_id) or 0
    if id <= 0 then return '' end
    local rules = self:get_talent_rules()
    local props = rules and rules.skillchainMeta and rules.skillchainMeta.properties or nil
    if type(props) == 'table' then
        for _, p in ipairs(props) do
            if tonumber(p.id) == id then
                return tostring(p.short or p.name or '')
            end
        end
    end
    return tostring(id)
end

-- Future module extension points (Abilities, Equipment, Journal)
function DataService:get_abilities_for_soul(permanent_soul_id)
    if not self:is_cache_usable() then return {} end
    if self.abilities_by_soul == nil then
        if not self:load_package('abilities') then return {} end
    end
    return self.abilities_by_soul[tostring(permanent_soul_id or '')] or {}
end

function DataService:get_equipment_items()
    if not self:is_cache_usable() then return {} end
    if self.equipment_data == nil then
        if not self:load_package('equipment') then return {} end
    end
    return self.equipment_data.items or {}
end

function DataService:get_soul_weapon_mode(permanent_soul_id)
    if not self:is_cache_usable() then return nil end
    if self.equipment_data == nil then
        if not self:load_package('equipment') then return nil end
    end
    return self.equipment_data.soulWeaponModes[tostring(permanent_soul_id or '')]
end

function DataService:get_ui_metadata()
    if not self:is_cache_usable() then return nil end
    return self.ui_metadata
end

-- Authoritative 66-Soul weapon family eligibility (aligned with server soulspire_ws_spec_profiles.lua
-- P.ALLOWED_SKILLS_BY_SPEC + soulspire_ws_talents.lua SPEC_KEY_TO_CATEGORY + soul-weapon-config.json).
-- Single shared source of truth for BOTH Weapon Mastery and Soulforge.
-- Skill IDs: 1=H2H, 2=Dagger, 3=Sword, 4=GSword, 5=Axe, 6=GAxe, 7=Scythe,
--            8=Polearm, 9=Katana, 10=GKatana, 11=Club, 12=Staff, 25=Archery, 26=Marksmanship, 27=Throwing
DataService.BASE_JOB_WEAPON_SKILLS = {
    WAR = { 6, 5, 4, 3, 7, 8, 11, 2, 1, 12, 25, 26, 27 },
    MNK = { 1, 12, 11, 27 },
    WHM = { 11, 12 },
    BLM = { 12, 11 },
    RDM = { 3, 2, 11, 12, 25 },
    THF = { 2, 3, 1, 11, 25, 26, 27 },
    PLD = { 3, 11, 4, 8, 12, 2 },
    DRK = { 7, 4, 3, 6, 5, 11, 2, 26 },
    BST = { 5, 7, 3, 2, 11 },
    BRD = { 2, 3, 11, 12 },
    RNG = { 25, 26, 5, 2, 3, 11, 27 },
    SAM = { 10, 8, 3, 11, 25, 27 },
    NIN = { 9, 2, 3, 10, 1, 11, 27, 25 },
    DRG = { 8, 12, 3, 11, 2 },
    SMN = { 12, 11 },
    BLU = { 3, 11 },
    COR = { 2, 3, 26, 27 },
    PUP = { 1, 2, 11, 27 },
    DNC = { 2, 3, 1, 27 },
    SCH = { 12, 11 },
    GEO = { 11, 12, 2 },
    RUN = { 4, 3, 6, 5, 11 },
}

DataService.SOUL_ELIGIBLE_SKILLS = {
    -- WAR
    commander      = { 6 },
    berserker      = { 6 },
    spartan        = { 8 },
    gladiator      = { 8 },
    -- MNK
    blackbelt      = { 1 },
    chiweaver      = { 1 },
    sensei         = { 12 },
    -- WHM
    bishop         = { 11, 12 },
    zealot         = { 12 },
    valkyrie       = { 8 },
    -- BLM
    astromancer    = { 12 },
    channeler      = { 12 },
    necromancer    = { 7 },
    -- RDM
    crimsonduelist = { 3 },
    royaltactician = { 3 },
    scarletweaver  = { 3 },
    -- THF
    bandit         = { 2, 3 },
    trickster      = { 2, 3 },
    phantom        = { 2, 9 },
    -- PLD
    defender       = { 3, 11 },
    templar        = { 11 },
    lightkeeper    = { 11 },
    aegistemplar   = { 11 },
    oathbreaker    = { 4 },
    -- DRK
    reaper         = { 7 },
    scourge        = { 7 },
    dreadnought    = { 7 },
    -- BST
    alphawarden    = { 5 },
    untamed        = { 5, 6 },
    beastspeaker   = { 5 },
    -- BRD
    adventurer     = { 2, 3 },
    musician       = { 2, 3, 11, 12 },
    minstrel       = { 2, 11, 12 },
    -- RNG
    sniper         = { 26 },
    arcanearcher   = { 25 },
    huntsman       = { 25, 26 },
    -- SAM
    ronin          = { 10 },
    warlord        = { 10 },
    imperialarcher = { 10, 25 },
    -- NIN
    shinobi        = { 9 },
    kagemusha      = { 9 },
    kurogane       = { 9 },
    nightblade     = { 9 },
    fuin           = { 9 },
    -- DRG
    lancer         = { 8 },
    skyborn        = { 8 },
    wyvernheart    = { 8 },
    -- SMN
    celestial      = { 12, 11 },
    caller         = { 12, 11 },
    primalist      = { 11, 12 },
    herald         = { 11, 12 },
    -- BLU
    warmage        = { 3, 11 },
    magus          = { 3, 11 },
    azurebastion   = { 3, 11 },
    -- COR
    flintlock      = { 26 },
    buccaneer      = { 3 },
    gambler        = { 26, 2 },
    -- PUP
    pugilist       = { 1 },
    vanguard       = { 1 },
    marionettist   = { 1 },
    animist        = { 1 },
    -- DNC
    bladewheel     = { 27, 2, 3 },
    vampire        = { 2, 27 },
    miragesentinel = { 2 },
    -- SCH
    medic          = { 2, 11, 12 },
    archivist      = { 11, 12 },
    sage           = { 2, 3, 11, 12 },
    -- GEO
    verdant        = { 11, 12 },
    terramancer    = { 11, 12 },
    diviner        = { 11, 12 },
    -- RUN
    spellblade     = { 4 },
    inquisitor     = { 4, 3, 5, 6, 11 },
    lifebinder     = { 4, 3, 5, 6, 11 },
}

local function add_mask_skills(set, mask)
    local m = tonumber(mask) or 0
    if m <= 0 then return end
    for _, sid in ipairs({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 25, 26, 27 }) do
        if math.floor(m / (2 ^ sid)) % 2 == 1 then
            set[sid] = true
        end
    end
end

local function normalize_spec_token(raw)
    return string.lower(tostring(raw or '')):gsub('[^a-z0-9]', '')
end

function DataService:get_weapon_config()
    if self._weapon_config_loaded then
        return self._weapon_config
    end
    self._weapon_config_loaded = true
    local candidates = {}
    if type(self.cache_dir) == 'string' and self.cache_dir ~= '' then
        local root = self.cache_dir:gsub('/cache$', '')
        candidates[#candidates + 1] = root .. '/data/soul-weapon-config.json'
    end
    if type(vana) == 'table' and vana.paths and type(vana.paths.addon) == 'function' then
        candidates[#candidates + 1] = normalize_dir(vana.paths.addon()) .. '/data/soul-weapon-config.json'
    end
    candidates[#candidates + 1] = 'addons/vanacore/soulspire_core/data/soul-weapon-config.json'
    for _, path in ipairs(candidates) do
        local raw = read_file_bytes(path)
        if type(raw) == 'string' and raw ~= '' then
            local ok, decoded = pcall(json.decode, raw)
            if ok and type(decoded) == 'table' then
                self._weapon_config = decoded
                return decoded
            end
        end
    end
    return nil
end

-- Single authoritative 66-Soul weapon family eligibility resolver for BOTH Weapon Mastery & Soulforge.
-- Returns a set `{ [skillId] = true }` or `nil` when Soul/Job identity is unavailable (fail-closed).
function DataService.resolve_eligible_weapon_skills(job_key, spec_key, opts)
    opts = opts or {}
    local ds = opts.data_service
    local wc = opts.weapon_config or (ds and ds.get_weapon_config and ds:get_weapon_config()) or nil

    local raw_spec = tostring(spec_key or '')
    local norm_spec = normalize_spec_token(raw_spec)
    local job_u = string.upper(tostring(job_key or ''))
    if job_u == '---' then job_u = '' end

    -- Resolve canonical Soul key via DataService's 66-Soul registry if available
    if ds and norm_spec ~= '' and norm_spec ~= 'base' and norm_spec ~= 'unspecced' and norm_spec ~= 'none' then
        local soul = ds.get_soul_by_key and ds:get_soul_by_key(raw_spec) or nil
        if type(soul) == 'table' then
            if type(soul.canonicalKey) == 'string' and soul.canonicalKey ~= '' then
                norm_spec = normalize_spec_token(soul.canonicalKey)
            elseif type(soul.internalKey) == 'string' and soul.internalKey ~= '' then
                norm_spec = normalize_spec_token(soul.internalKey)
            end
            if job_u == '' and type(soul.jobKey) == 'string' then
                job_u = string.upper(soul.jobKey)
            end
        end
    end

    local is_base = (norm_spec == '' or norm_spec == 'base' or norm_spec == 'unspecced' or norm_spec == 'none')
    if is_base then
        -- Base-job state: allow base job weapons ONLY when job is genuinely known & unspecced.
        -- Unavailable job identity returns nil (fail-closed: never expose all 15 weapon families!).
        local base_list = DataService.BASE_JOB_WEAPON_SKILLS[job_u]
        if not base_list then return nil end
        local set = {}
        for _, sid in ipairs(base_list) do set[sid] = true end
        return set
    end

    local set = {}
    -- 1. Authoritative soul-weapon-config.json rangedOnly restrictions (e.g. Flintlock firearm-only)
    if type(wc) == 'table' and type(wc.rangedOnly) == 'table' then
        for _, ro in ipairs(wc.rangedOnly) do
            if type(ro) == 'table' and normalize_spec_token(ro.soulKey) == norm_spec and ro.firearmOnly == true then
                set[26] = true
                return set
            end
        end
    end

    -- 2. Authoritative per-Soul weapon family list (all 66 canonical Souls, no broad vanilla job fallback)
    local soul_list = DataService.SOUL_ELIGIBLE_SKILLS[norm_spec]
    if type(soul_list) == 'table' then
        for _, sid in ipairs(soul_list) do
            set[sid] = true
        end
        -- Merge any explicit weapon_config rule masks for this Soul (e.g. Berserker dual_2h GAxe, Adventurer dual_1h Dagger/Sword)
        if type(wc) == 'table' and type(wc.rules) == 'table' then
            for _, rule in ipairs(wc.rules) do
                if type(rule) == 'table' and normalize_spec_token(rule.soulKey) == norm_spec then
                    add_mask_skills(set, rule.mainSkillMask)
                    add_mask_skills(set, rule.subSkillMask)
                end
            end
        end
        return set
    end

    -- Unknown / unrecognized Soul key: fail-closed (never dump all 15 weapon families!)
    return nil
end

function DataService:get_eligible_weapon_skills(job_key, spec_key)
    return DataService.resolve_eligible_weapon_skills(job_key, spec_key, {
        data_service  = self,
        weapon_config = self:get_weapon_config(),
    })
end

function DataService:get_diagnostics()
    local info = self:get_cache_info()
    local loaded_pkgs = {}
    for k, st in pairs(self.package_status) do
        loaded_pkgs[k] = {
            verified = st.verified == true,
            size     = st.size or 0,
            loadMs   = st.loadMs or 0,
            error    = st.error,
        }
    end
    return {
        cache        = info,
        serverCompat = self.server_compat,
        packages     = loaded_pkgs,
        metrics      = self.metrics,
        syncStats    = self:get_sync_stats(),
        warmupStats  = self.warmup_stats,
        syncLog      = self.sync_log,
        recentEvents = self.diag_events,
    }
end

return DataService
