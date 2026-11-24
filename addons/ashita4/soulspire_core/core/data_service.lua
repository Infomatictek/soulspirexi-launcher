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
        sync_diag_log    = {},
        warmup           = nil, -- cooperative incremental talents.json loader state
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
            stale_dropped      = 0,
            deduped_requests   = 0,
            cache_hits_catalog = 0,
            cache_hits_ws      = 0,
            cache_hits_souls   = 0,
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
end

function DataService:record_metric(key, delta)
    if self.metrics[key] ~= nil then
        self.metrics[key] = self.metrics[key] + (tonumber(delta) or 1)
    end
end

function DataService:record_sync_diag(entry)
    if type(entry) ~= 'table' then return end
    local rec = {
        completedAt     = tonumber(entry.completedAt) or self.clock(),
        reqId           = tonumber(entry.reqId) or 0,
        domain          = tostring(entry.domain or 'oxtl'),
        op              = tostring(entry.op or 'sync'),
        wsId            = tonumber(entry.wsId) or 0,
        outcome         = tostring(entry.outcome or 'ok'),
        latencyMs       = tonumber(entry.latencyMs) or 0,
        packetsIn       = tonumber(entry.packetsIn) or 0,
        bytesIn         = tonumber(entry.bytesIn) or 0,
        retries         = tonumber(entry.retries) or 0,
        cacheHit        = entry.cacheHit == true,
        protocolVersion = tonumber(entry.protocolVersion) or 2,
        timeoutReason   = entry.timeoutReason and tostring(entry.timeoutReason) or nil,
    }
    local list = self.sync_diag_log
    if #list >= DataService.MAX_DIAG_EVENTS then
        table.remove(list, 1)
    end
    list[#list + 1] = rec
end

function DataService:get_sync_diag_log()
    return self.sync_diag_log
end

function DataService:is_talents_warm()
    return self.talent_trees ~= nil
end

function DataService:get_warmup_state()
    if self.talent_trees ~= nil then
        return { stage = 'ready', progress = 1.0, done = true, error = nil }
    end
    local w = self.warmup
    if not w then
        return { stage = 'idle', progress = 0.0, done = false, error = nil }
    end
    return {
        stage    = w.stage,
        progress = w.progress or 0.0,
        done     = (w.stage == 'ready' or w.stage == 'error'),
        error    = w.error,
        msSpent  = w.ms_spent or 0,
    }
end

-- Cooperatively read, SHA-256 verify, and parse talents.json within budget_ms per frame
-- so Ashita v4's d3d_present never stalls while preparing the 6.8MB static talent cache.
function DataService:step_warmup(budget_ms)
    if self.talent_trees ~= nil then
        return true
    end
    if not self:is_cache_usable() or not self.manifest or type(self.manifest.packages) ~= 'table' then
        return false
    end
    local info = self.manifest.packages.talents
    if type(info) ~= 'table' or type(info.file) ~= 'string' then
        return false
    end

    local budget_sec = math.max(0.001, (tonumber(budget_ms) or 4.0) / 1000.0)
    local t0 = self.clock()

    local w = self.warmup
    if not w then
        if info.file:find('..', 1, true) or info.file:find('/', 1, true) or info.file:find('\\', 1, true) then
            self:_fail_cache('corrupt', 'Unsafe package filename in manifest: ' .. tostring(info.file))
            self.warmup = { stage = 'error', progress = 0, error = self.error_message, ms_spent = 0 }
            return false
        end
        local full_path = self.cache_dir .. '/' .. info.file
        local raw, read_err = read_file_bytes(full_path)
        if not raw then
            self.package_status.talents = { verified = false, error = 'missing: ' .. tostring(read_err) }
            self:_fail_cache('missing', string.format('Missing cache package %s (%s). Run SoulspireLauncher to update.', info.file, tostring(read_err)))
            self.warmup = { stage = 'error', progress = 0, error = self.error_message, ms_spent = (self.clock() - t0) * 1000 }
            return false
        end
        if type(info.size) == 'number' and #raw ~= info.size then
            self.package_status.talents = { verified = false, size = #raw, error = 'size mismatch' }
            self:_fail_cache('corrupt', string.format('Cache integrity failed for %s (size %d != %d). Run SoulspireLauncher to repair.', info.file, #raw, info.size))
            self.warmup = { stage = 'error', progress = 0, error = self.error_message, ms_spent = (self.clock() - t0) * 1000 }
            return false
        end
        w = {
            stage    = 'hashing',
            raw      = raw,
            size     = #raw,
            offset   = 1,
            hasher   = sha256.new(),
            progress = 0.05,
            ms_spent = (self.clock() - t0) * 1000,
            error    = nil,
        }
        self.warmup = w
        if (self.clock() - t0) >= budget_sec then
            return false
        end
    end

    if w.stage == 'error' then
        return false
    end

    if w.stage == 'hashing' then
        local CHUNK = 65536
        while w.offset <= w.size do
            local stop = math.min(w.size, w.offset + CHUNK - 1)
            w.hasher:update(string.sub(w.raw, w.offset, stop))
            w.offset = stop + 1
            w.progress = 0.05 + 0.70 * math.min(1.0, (w.offset - 1) / math.max(1, w.size))
            if (self.clock() - t0) >= budget_sec then
                w.ms_spent = w.ms_spent + (self.clock() - t0) * 1000
                return false
            end
        end
        local actual_sha = w.hasher:digest()
        if type(info.sha256) ~= 'string' or actual_sha ~= string.lower(info.sha256) then
            self.package_status.talents = { verified = false, size = w.size, sha256 = actual_sha, error = 'sha256 mismatch' }
            self:_fail_cache('corrupt', string.format('Cache SHA-256 mismatch for %s. Run SoulspireLauncher to repair.', info.file))
            w.stage = 'error'
            w.raw = nil
            w.error = self.error_message
            return false
        end
        w.sha256 = actual_sha
        w.stage = 'parsing'
        w.progress = 0.80
        w.ms_spent = w.ms_spent + (self.clock() - t0) * 1000
        return false
    end

    if w.stage == 'parsing' then
        local parsed, dec_err = json.decode(w.raw)
        local raw_size = w.size
        local sha_val = w.sha256
        w.raw = nil
        if not parsed or type(parsed) ~= 'table' then
            self.package_status.talents = { verified = false, size = raw_size, sha256 = sha_val, error = 'json parse error' }
            self:_fail_cache('corrupt', string.format('Malformed JSON in %s: %s', info.file, tostring(dec_err)))
            w.stage = 'error'
            w.error = self.error_message
            return false
        end
        if tonumber(parsed.schemaVersion) ~= tonumber(self.manifest.schemaVersion) then
            self.package_status.talents = { verified = false, error = 'schema mismatch' }
            self:_fail_cache('incompatible', string.format('Schema mismatch in %s.', info.file))
            w.stage = 'error'
            w.error = self.error_message
            return false
        end
        local ok_idx, idx_err = self:_index_talents(parsed)
        if not ok_idx then
            self.package_status.talents = { verified = false, error = idx_err }
            self:_fail_cache('corrupt', string.format('Invalid cache structure in %s: %s', info.file, tostring(idx_err)))
            w.stage = 'error'
            w.error = self.error_message
            return false
        end
        local step_ms = (self.clock() - t0) * 1000
        w.ms_spent = w.ms_spent + step_ms
        self.load_ms_total = self.load_ms_total + w.ms_spent
        self.packages.talents = parsed
        self.package_status.talents = {
            verified = true,
            size     = raw_size,
            sha256   = sha_val,
            loadMs   = w.ms_spent,
        }
        w.stage = 'ready'
        w.progress = 1.0
        self:record_event('cache', 'talents_warm', string.format('size=%dB ms=%.1f', raw_size, w.ms_spent))
        self:emit('talents_warm', { size = raw_size, loadMs = w.ms_spent })
        return true
    end

    return self.talent_trees ~= nil
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
    local pkg = self:load_package('talents')
    return pkg ~= nil
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
        recentEvents = self.diag_events,
    }
end

return DataService
