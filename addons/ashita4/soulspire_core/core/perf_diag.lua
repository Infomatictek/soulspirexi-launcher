-- SoulspireXI Core: Opt-in Client Performance Diagnostics & Bounded Telemetry Export.
--
-- Disabled by default (`enabled = false`): when disabled, every hot-path hook
-- exits on a single boolean guard with zero allocations and zero extra packets.
-- When enabled on Testing environments, captures monotonic flow latencies,
-- explicit outcomes (`complete` | `failed` | `cancelled` | `incomplete`),
-- Cold vs Warm segmentation, attribution_scope, frame pacing, and existing
-- DataService / CharacterState packet & retry counters into a bounded (< 256 KB),
-- PII-redacted JSON bundle (`logs/soulspire_perf/core-perf-latest.json`).

local json = require('core.json')

local PerfDiag = {}
PerfDiag.__index = PerfDiag

PerfDiag.SCHEMA_VERSION   = 'soulspire-core-perf-1.0.0'
PerfDiag.MAX_FLOW_SAMPLES = 256
PerfDiag.MAX_FRAME_SAMPLES = 1024
PerfDiag.MAX_EXPORT_BYTES = 262144 -- 256 KB ceiling
PerfDiag.FLUSH_INTERVAL_SEC = 15.0

local ALLOWED_OUTCOMES = {
    complete   = true,
    failed     = true,
    cancelled  = true,
    incomplete = true,
}

local FORBIDDEN_KEYS = {
    password = true, secret = true, token = true, private_key = true, dsn = true,
    character_name = true, char_name = true, player_name = true,
    account_name = true, account_id = true, accid = true, charid = true,
    client_ip = true, remote_ip = true, ip_address = true, email = true, username = true,
}

local function default_clock()
    if type(ashita) == 'table' and type(ashita.time) == 'table' and type(ashita.time.get_tick64) == 'function' then
        local ok, ms = pcall(ashita.time.get_tick64)
        if ok and tonumber(ms) then
            return tonumber(ms) / 1000.0
        end
    end
    return os.clock()
end

local function normalize_sep(p)
    return tostring(p or ''):gsub('\\', '/')
end

local function dirname_of(path)
    local norm = normalize_sep(path):gsub('/+$', '')
    return norm:match('^(.+)/[^/]+$')
end

local function ensure_parent_dir(path)
    local dir = dirname_of(path)
    if not dir or dir == '' then return end
    if type(ashita) == 'table' and type(ashita.fs) == 'table' and type(ashita.fs.create_directory) == 'function' then
        pcall(ashita.fs.create_directory, dir)
    end
    if package.config:sub(1, 1) == '\\' then
        os.execute('if not exist "' .. dir:gsub('/', '\\') .. '" mkdir "' .. dir:gsub('/', '\\') .. '" >nul 2>&1')
    else
        os.execute('mkdir -p "' .. dir .. '" >/dev/null 2>&1')
    end
end

local function redact_str(val)
    local s = tostring(val or '')
    s = s:gsub('[A-Za-z]:\\[^%s"\',;]+', '<win-path-redacted>')
    s = s:gsub('/(?:mnt|root|home)/[%w%._/%-]+', '<host-path-redacted>')
    s = s:gsub('/root/[%w%._/%-]+', '<host-path-redacted>')
    s = s:gsub('/home/[%w%._/%-]+', '<host-path-redacted>')
    s = s:gsub('/mnt/[%w%._/%-]+', '<host-path-redacted>')
    if not s:match('^%d+%.%d+%.%d+$') then
        s = s:gsub('(%d+%.%d+%.%d+%.%d+)', '<ip-redacted>')
    end
    return s
end

PerfDiag.redact_string = redact_str

local function escape_json_str(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\')
         :gsub('"', '\\"')
         :gsub('\b', '\\b')
         :gsub('\f', '\\f')
         :gsub('\n', '\\n')
         :gsub('\r', '\\r')
         :gsub('\t', '\\t')
    s = s:gsub('[%z\1-\31]', function(c)
        return string.format('\\u%04x', string.byte(c))
    end)
    return '"' .. s .. '"'
end

local function is_array(t)
    local n = #t
    local count = 0
    for _ in pairs(t) do
        count = count + 1
    end
    return count == n and n > 0
end

local encode_val
encode_val = function(v, key_hint)
    if key_hint then
        local kl = tostring(key_hint):lower()
        for fk in pairs(FORBIDDEN_KEYS) do
            if kl:find(fk, 1, true) then
                return '"<redacted>"'
            end
        end
    end
    local tv = type(v)
    if tv == 'nil' then
        return 'null'
    elseif tv == 'boolean' then
        return v and 'true' or 'false'
    elseif tv == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then
            return '0'
        end
        if v == math.floor(v) and math.abs(v) < 1e15 then
            return string.format('%d', v)
        end
        return string.format('%.4f', v)
    elseif tv == 'string' then
        return escape_json_str(redact_str(v))
    elseif tv == 'table' then
        if is_array(v) then
            local parts = {}
            for i = 1, #v do
                parts[i] = encode_val(v[i], nil)
            end
            return '[' .. table.concat(parts, ',') .. ']'
        end
        local keys = {}
        for k in pairs(v) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        local parts = {}
        for i = 1, #keys do
            local k = keys[i]
            parts[i] = escape_json_str(k) .. ':' .. encode_val(v[k], k)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    return escape_json_str(tostring(v))
end

PerfDiag.json_encode = function(tbl)
    return encode_val(tbl, nil)
end

local function percentile(sorted, p)
    local n = #sorted
    if n == 0 then return 0 end
    local idx = math.max(1, math.min(n, math.ceil(n * p)))
    return math.floor(sorted[idx] * 10000 + 0.5) / 10000
end

local function round4(v)
    return math.floor((tonumber(v) or 0) * 10000 + 0.5) / 10000
end

local function empty_mode_bucket()
    return {
        durations     = {},
        total_seen    = 0,
        outcomes      = { complete = 0, failed = 0, cancelled = 0, incomplete = 0 },
        retries       = 0,
        timeouts      = 0,
        packets_in    = 0,
        bytes_in      = 0,
        scope         = 'client_only',
    }
end

function PerfDiag.resolve_ashita_paths(addon_path)
    if type(addon_path) ~= 'string' or addon_path == '' then
        return nil, nil
    end
    local root = normalize_sep(addon_path):gsub('/+$', '')
    -- <ashita>/addons/soulspire_core or <ashita>/addons/ashita4/soulspire_core
    local addons_dir = dirname_of(root)
    local base_dir = addons_dir
    if addons_dir and addons_dir:match('/ashita4$') then
        base_dir = dirname_of(addons_dir)
    end
    local ashita_root = dirname_of(base_dir or root) or '.'
    local cfg = ashita_root .. '/addons/ashita4/config/soulspire_perf_diag.json'
    local exp = ashita_root .. '/logs/soulspire_perf/core-perf-latest.json'
    return cfg, exp
end

function PerfDiag.new(opts)
    opts = opts or {}
    local def_cfg, def_exp = PerfDiag.resolve_ashita_paths(opts.addon_path)
    local self = setmetatable({
        enabled             = opts.enabled == true,
        clock               = type(opts.clock) == 'function' and opts.clock or default_clock,
        config_path         = opts.config_path or def_cfg,
        export_path         = opts.export_path or def_exp,
        source_channel      = tostring(opts.source_channel or 'testing'),
        server_target_class = tostring(opts.server_target_class or 'unknown'),
        data_service        = opts.data_service,
        character_state     = opts.character_state,
        active_spans        = {},
        flows               = {},
        recent_samples      = {},
        frame_ms_ring       = {},
        frame_total_count   = 0,
        hitches_gt_33ms     = 0,
        hitches_gt_100ms    = 0,
        legacy_fallback_count = 0,
        op_cache_sync_count   = 0,
        dropped_samples     = 0,
        cold_seen           = {},
        diag_cpu_ms_total   = 0,
        diag_cb_samples_ms  = {},
        mem_baseline_kb     = collectgarbage('count'),
        last_flush_at       = 0,
        dirty               = false,
        listeners_attached  = false,
        last_menu_form      = '',
        equip_proxy_active  = false,
        started_at          = 0,
    }, PerfDiag)
    self.started_at = self.clock()
    if self.enabled then
        self:_attach_listeners()
    end
    return self
end

function PerfDiag:_track_overhead(t0)
    local dt = math.max(0, (self.clock() - t0) * 1000.0)
    self.diag_cpu_ms_total = self.diag_cpu_ms_total + dt
    local list = self.diag_cb_samples_ms
    if #list >= 512 then
        table.remove(list, 1)
    end
    list[#list + 1] = dt
end

function PerfDiag:_attach_listeners()
    if self.listeners_attached then return end
    local ds = self.data_service
    if ds and type(ds.subscribe) == 'function' then
        ds:subscribe('sync_attempt', function(rec)
            if self.enabled then
                self:observe_sync_attempt(rec)
            end
        end)
        ds:subscribe('perf_flow', function(ev)
            if self.enabled then
                self:observe_perf_flow_event(ev)
            end
        end)
        ds:subscribe('diag_event', function(ev)
            if self.enabled and type(ev) == 'table' and ev.kind == 'legacy_fallback' then
                self.legacy_fallback_count = self.legacy_fallback_count + 1
                self.dirty = true
            end
        end)
    end
    local cs = self.character_state
    if cs and type(cs.subscribe) == 'function' then
        cs:subscribe(function(ev)
            if self.enabled then
                self:observe_character_event(ev)
            end
        end)
    end
    self.listeners_attached = true
end

function PerfDiag:load_config()
    if not self.config_path then return false end
    local f = io.open(self.config_path, 'r')
    if not f then
        self.enabled = false
        return false
    end
    local raw = f:read('*a')
    f:close()
    local ok, decoded = pcall(json.decode, raw or '')
    if not ok or type(decoded) ~= 'table' then
        self.enabled = false
        return false
    end
    self.enabled = (decoded.enabled == true)
    if type(decoded.source_channel) == 'string' and decoded.source_channel ~= '' then
        self.source_channel = decoded.source_channel
    end
    if type(decoded.server_target_class) == 'string' and decoded.server_target_class ~= '' then
        self.server_target_class = decoded.server_target_class
    end
    if self.enabled then
        self:_attach_listeners()
    end
    return self.enabled
end

function PerfDiag:save_config()
    if not self.config_path then return false, 'no_config_path' end
    local ok, err = pcall(function()
        ensure_parent_dir(self.config_path)
        local payload = encode_val({
            schema_version      = 'soulspire-perf-diag-config-1.0.0',
            enabled             = self.enabled == true,
            source_channel      = self.source_channel,
            server_target_class = self.server_target_class,
        }, nil)
        local f = assert(io.open(self.config_path, 'w'))
        f:write(payload .. '\n')
        f:close()
    end)
    return ok, err
end

function PerfDiag:set_enabled(flag, persist)
    self.enabled = (flag == true)
    if self.enabled then
        self.mem_baseline_kb = collectgarbage('count')
        self:_attach_listeners()
    end
    if persist ~= false and self.config_path then
        self:save_config()
    end
    return self.enabled
end

function PerfDiag:_record_completed_sample(flow_name, mode, dur_ms, outcome, scope, extra)
    local out = ALLOWED_OUTCOMES[outcome] and outcome or 'incomplete'
    local m = (mode == 'cold' or mode == 'warm') and mode or (self.cold_seen[flow_name] and 'warm' or 'cold')
    self.cold_seen[flow_name] = true

    local fg = self.flows[flow_name]
    if not fg then
        fg = { cold = empty_mode_bucket(), warm = empty_mode_bucket() }
        self.flows[flow_name] = fg
    end
    local b = fg[m]
    b.total_seen = b.total_seen + 1
    b.outcomes[out] = (b.outcomes[out] or 0) + 1
    b.scope = scope or b.scope or 'client_only'
    if extra then
        b.retries    = b.retries + (tonumber(extra.retries) or 0)
        b.timeouts   = b.timeouts + (tonumber(extra.timeouts) or 0)
        b.packets_in = b.packets_in + (tonumber(extra.packets_in) or 0)
        b.bytes_in   = b.bytes_in + (tonumber(extra.bytes_in) or 0)
    end
    if out == 'complete' and dur_ms ~= nil then
        local ms = math.max(0, tonumber(dur_ms) or 0)
        if #b.durations >= PerfDiag.MAX_FLOW_SAMPLES then
            table.remove(b.durations, 1)
            self.dropped_samples = self.dropped_samples + 1
        end
        b.durations[#b.durations + 1] = ms
    end

    if #self.recent_samples >= PerfDiag.MAX_FLOW_SAMPLES then
        table.remove(self.recent_samples, 1)
        self.dropped_samples = self.dropped_samples + 1
    end
    self.recent_samples[#self.recent_samples + 1] = {
        flow      = flow_name,
        mode      = m,
        ms        = dur_ms ~= nil and round4(math.max(0, dur_ms)) or 0,
        outcome   = out,
        scope     = b.scope,
    }
    self.dirty = true
end

function PerfDiag:begin_flow(flow_name, opts)
    if not self.enabled then return end
    local t0 = self.clock()
    opts = opts or {}
    local key = tostring(flow_name)
    local prev = self.active_spans[key]
    if prev and prev.started_at then
        -- Previous in-flight span superseded/interrupted before completing -> explicit incomplete
        self:_record_completed_sample(key, prev.mode, (t0 - prev.started_at) * 1000.0, 'incomplete', prev.scope)
    end
    local mode = opts.mode
    if mode ~= 'cold' and mode ~= 'warm' then
        mode = self.cold_seen[key] and 'warm' or 'cold'
    end
    self.active_spans[key] = {
        started_at = opts.started_at or t0,
        mode       = mode,
        scope      = opts.scope or 'client_only',
        meta       = opts.meta,
    }
    self:_track_overhead(t0)
end

function PerfDiag:end_flow(flow_name, outcome, opts)
    if not self.enabled then return end
    local t0 = self.clock()
    opts = opts or {}
    local key = tostring(flow_name)
    local span = self.active_spans[key]
    if not span then
        self:_track_overhead(t0)
        return
    end
    self.active_spans[key] = nil
    local dur_ms = opts.duration_ms
    if dur_ms == nil then
        dur_ms = math.max(0, (t0 - (span.started_at or t0)) * 1000.0)
    end
    self:_record_completed_sample(
        key,
        opts.mode or span.mode,
        dur_ms,
        outcome or 'complete',
        opts.scope or span.scope,
        opts
    )
    self:_track_overhead(t0)
end

function PerfDiag:record_flow(flow_name, dur_ms, outcome, opts)
    if not self.enabled then return end
    local t0 = self.clock()
    opts = opts or {}
    self:_record_completed_sample(
        tostring(flow_name),
        opts.mode,
        dur_ms,
        outcome or 'complete',
        opts.scope or 'client_only',
        opts
    )
    self:_track_overhead(t0)
end

function PerfDiag:interrupt_inflight(reason)
    if not self.enabled then return end
    local t0 = self.clock()
    local keys = {}
    for k in pairs(self.active_spans) do
        keys[#keys + 1] = k
    end
    for i = 1, #keys do
        local k = keys[i]
        -- zone_transition survives 0x00B
        if not (reason == 'zone_change' and (k == 'zone_transition' or k == 'login')) then
            local span = self.active_spans[k]
            self.active_spans[k] = nil
            local out = (reason == 'cancelled' or reason == 'user_cancel') and 'cancelled' or 'incomplete'
            self:_record_completed_sample(k, span.mode, (t0 - (span.started_at or t0)) * 1000.0, out, span.scope)
        end
    end
    self:_track_overhead(t0)
end

function PerfDiag:record_frame(frame_ms, ui_draw_ms, parse_ms)
    if not self.enabled then return end
    local t0 = self.clock()
    local ms = math.max(0, tonumber(frame_ms) or 0)
    self.frame_total_count = self.frame_total_count + 1
    if ms > 33.3 then self.hitches_gt_33ms = self.hitches_gt_33ms + 1 end
    if ms > 100.0 then self.hitches_gt_100ms = self.hitches_gt_100ms + 1 end
    local ring = self.frame_ms_ring
    if #ring >= PerfDiag.MAX_FRAME_SAMPLES then
        table.remove(ring, 1)
    end
    ring[#ring + 1] = ms
    if ui_draw_ms ~= nil and tonumber(ui_draw_ms) and tonumber(ui_draw_ms) > 0 then
        self.last_ui_draw_ms = tonumber(ui_draw_ms)
    end
    if parse_ms ~= nil and tonumber(parse_ms) and tonumber(parse_ms) > 0 then
        self.last_parse_ms = tonumber(parse_ms)
    end
    self.dirty = true
    self:_track_overhead(t0)
end

function PerfDiag:observe_sync_attempt(rec)
    if not self.enabled or type(rec) ~= 'table' then return end
    local t0 = self.clock()
    local op = tostring(rec.op or '')
    local out = 'failed'
    if rec.outcome == 'ok' then
        out = 'complete'
    elseif rec.outcome == 'cancelled' then
        out = 'cancelled'
    elseif rec.outcome == 'incomplete' then
        out = 'incomplete'
    end
    local extra = {
        retries    = tonumber(rec.retries) or 0,
        timeouts   = (rec.outcome == 'timeout') and 1 or 0,
        packets_in = tonumber(rec.packetsIn) or 0,
        bytes_in   = tonumber(rec.bytesIn) or 0,
    }
    if op == 'OP_WS' or op == 'ws_detail' then
        self:_record_completed_sample('wm_ws_select', nil, tonumber(rec.latencyMs) or 0, out, 'client_plus_server_rtt', extra)
    else
        if op == 'cache_sync' then
            self.op_cache_sync_count = self.op_cache_sync_count + 1
        elseif op == 'legacy_full' or op == 'legacy_state' then
            self.legacy_fallback_count = self.legacy_fallback_count + 1
        end
        self:_record_completed_sample('wm_sync', nil, tonumber(rec.latencyMs) or 0, out, 'client_plus_server_rtt', extra)
    end
    self:_track_overhead(t0)
end

function PerfDiag:observe_perf_flow_event(ev)
    if not self.enabled or type(ev) ~= 'table' then return end
    local t0 = self.clock()
    local flow = tostring(ev.flow or '')
    if flow ~= '' then
        if ev.phase == 'begin' then
            self:begin_flow(flow, { scope = ev.scope or 'client_plus_server_rtt', mode = ev.mode })
        elseif ev.phase == 'end' then
            self:end_flow(flow, ev.outcome or 'complete', {
                duration_ms = ev.duration_ms,
                scope       = ev.scope or 'client_plus_server_rtt',
                retries     = ev.retries,
                timeouts    = ev.timeouts,
            })
        else
            self:_record_completed_sample(
                flow,
                ev.mode,
                ev.duration_ms,
                ev.outcome or 'complete',
                ev.scope or 'client_plus_server_rtt',
                ev
            )
        end
    end
    self:_track_overhead(t0)
end

function PerfDiag:observe_character_event(ev)
    if not self.enabled or type(ev) ~= 'table' then return end
    if ev.source == 'crys_state' or ev.source == 'oxsi_hud' then
        if self.active_spans['soul_switch'] then
            self:end_flow('soul_switch', 'complete', { scope = 'client_plus_server_rtt' })
        end
    end
end

function PerfDiag:observe_menu_form(form_name)
    if not self.enabled then return end
    local name = tostring(form_name or ''):lower()
    if name == self.last_menu_form then return end
    local was_equip = self.last_menu_form:find('equip', 1, true) ~= nil
    local is_equip  = name:find('equip', 1, true) ~= nil
    self.last_menu_form = name
    if not was_equip and is_equip then
        self.equip_proxy_active = true
        self:begin_flow('equip_menu', { scope = 'observed_proxy' })
    elseif was_equip and not is_equip and self.equip_proxy_active then
        self.equip_proxy_active = false
        self:end_flow('equip_menu', 'complete', { scope = 'observed_proxy' })
    end
end

function PerfDiag:flush_due(now)
    if not self.enabled or not self.dirty or not self.export_path then return false end
    local t = now or self.clock()
    if (t - self.last_flush_at) < PerfDiag.FLUSH_INTERVAL_SEC then
        return false
    end
    return self:export_bundle()
end

function PerfDiag:shutdown(now)
    if not self.enabled then return false end
    self:interrupt_inflight('unload')
    return self:export_bundle(now)
end

local function summarize_bucket(b)
    if b.total_seen == 0 and #b.durations == 0 then
        return nil
    end
    local sorted = {}
    for i = 1, #b.durations do sorted[i] = b.durations[i] end
    table.sort(sorted)
    local out = {
        n                 = b.total_seen,
        failures          = (b.outcomes.failed or 0) + (b.outcomes.incomplete or 0),
        retries           = b.retries,
        timeouts          = b.timeouts,
        cancelled         = b.outcomes.cancelled or 0,
        incomplete        = b.outcomes.incomplete or 0,
        packets_in        = b.packets_in,
        bytes_in          = b.bytes_in,
        outcomes          = b.outcomes,
        attribution_scope = b.scope,
    }
    if #sorted > 0 then
        out.p50_ms = percentile(sorted, 0.50)
        out.p95_ms = percentile(sorted, 0.95)
        out.p99_ms = percentile(sorted, 0.99)
        out.max_ms = round4(sorted[#sorted])
    else
        out.p50_ms = 0
        out.max_ms = 0
    end
    return out
end

function PerfDiag:build_bundle()
    local client_flows = {}
    for fname, fg in pairs(self.flows) do
        local entry = {}
        local c = summarize_bucket(fg.cold)
        local w = summarize_bucket(fg.warm)
        if c then entry.cold = c end
        if w then entry.warm = w end
        if fname == 'wm_sync' then
            entry.legacy_fallback_count = self.legacy_fallback_count
            entry.op_cache_sync_count   = self.op_cache_sync_count
        end
        if c or w or fname == 'wm_sync' then
            client_flows[fname] = entry
        end
    end

    local fsorted = {}
    for i = 1, #self.frame_ms_ring do fsorted[i] = self.frame_ms_ring[i] end
    table.sort(fsorted)

    local csorted = {}
    for i = 1, #self.diag_cb_samples_ms do csorted[i] = self.diag_cb_samples_ms[i] end
    table.sort(csorted)

    local ds = self.data_service
    local diag_ds = ds and ds.get_diagnostics and ds:get_diagnostics() or nil
    local metrics = diag_ds and diag_ds.metrics or {}
    local cache_info = diag_ds and diag_ds.cache or {}
    local warmup = diag_ds and diag_ds.warmupStats or {}

    local mem_delta = math.max(0, collectgarbage('count') - (self.mem_baseline_kb or 0))
    return {
        schema_version      = PerfDiag.SCHEMA_VERSION,
        enabled             = self.enabled == true,
        source_channel      = self.source_channel,
        server_target_class = self.server_target_class,
        overhead = {
            diag_cpu_ms_total    = round4(self.diag_cpu_ms_total),
            diag_p99_callback_ms = percentile(csorted, 0.99),
            lua_mem_kb_delta     = round4(mem_delta),
            dropped_samples      = self.dropped_samples,
        },
        client_flows = client_flows,
        runtime_health = {
            frame_ms = {
                n                = self.frame_total_count,
                p50              = percentile(fsorted, 0.50),
                p95              = percentile(fsorted, 0.95),
                p99              = percentile(fsorted, 0.99),
                max              = #fsorted > 0 and round4(fsorted[#fsorted]) or 0,
                hitches_gt_33ms  = self.hitches_gt_33ms,
                hitches_gt_100ms = self.hitches_gt_100ms,
            },
            packet_counters = {
                packets_in_oxtl  = tonumber(metrics.packets_in_oxtl) or 0,
                packets_out_oxtl = tonumber(metrics.packets_out_oxtl) or 0,
                bytes_in_oxtl    = tonumber(metrics.bytes_in_oxtl) or 0,
                packets_in_crys  = tonumber(metrics.packets_in_crys) or 0,
                packets_out_crys = tonumber(metrics.packets_out_crys) or 0,
                bytes_in_crys    = tonumber(metrics.bytes_in_crys) or 0,
                sync_retries     = tonumber(metrics.sync_retries) or 0,
                timeouts         = tonumber(metrics.timeouts) or 0,
                stale_dropped    = tonumber(metrics.stale_dropped) or 0,
                deduped_requests = tonumber(metrics.deduped_requests) or 0,
            },
            cache_stats = {
                load_ms         = tonumber(cache_info.loadMs) or 0,
                warmup_max_ms   = tonumber(warmup.maxFrameMs) or 0,
                warmup_frames   = tonumber(warmup.frames) or 0,
                cache_hits_ws   = tonumber(metrics.cache_hits_ws) or 0,
            },
        },
        recent_samples = self.recent_samples,
    }
end

function PerfDiag:export_bundle(now)
    if not self.export_path then return false, 'no_export_path' end
    local bundle = self:build_bundle()
    local raw = encode_val(bundle, nil)
    -- Enforce strict < 256 KB Core export ceiling by trimming recent_samples first if needed.
    if #raw >= PerfDiag.MAX_EXPORT_BYTES then
        local trimmed = {}
        local keep = math.min(#bundle.recent_samples, 32)
        for i = #bundle.recent_samples - keep + 1, #bundle.recent_samples do
            if i >= 1 then trimmed[#trimmed + 1] = bundle.recent_samples[i] end
        end
        bundle.recent_samples = trimmed
        raw = encode_val(bundle, nil)
        if #raw >= PerfDiag.MAX_EXPORT_BYTES then
            bundle.recent_samples = {}
            raw = encode_val(bundle, nil)
        end
    end
    local ok, err = pcall(function()
        ensure_parent_dir(self.export_path)
        local tmp = self.export_path .. '.tmp'
        local f = assert(io.open(tmp, 'w'))
        f:write(raw .. '\n')
        f:close()
        os.remove(self.export_path)
        local ren_ok = os.rename(tmp, self.export_path)
        if not ren_ok then
            local f2 = assert(io.open(self.export_path, 'w'))
            f2:write(raw .. '\n')
            f2:close()
            os.remove(tmp)
        end
    end)
    if ok then
        self.last_flush_at = now or self.clock()
        self.dirty = false
        return true, self.export_path, #raw
    end
    return false, err
end

function PerfDiag:format_status_line()
    local flow_count = 0
    for _ in pairs(self.flows) do flow_count = flow_count + 1 end
    return ('perfdiag enabled=%s flows=%d frames=%d hitches33=%d cpu=%.3fms dropped=%d cfg=%s'):format(
        tostring(self.enabled),
        flow_count,
        self.frame_total_count,
        self.hitches_gt_33ms,
        self.diag_cpu_ms_total,
        self.dropped_samples,
        tostring(self.config_path ~= nil)
    )
end

return PerfDiag
