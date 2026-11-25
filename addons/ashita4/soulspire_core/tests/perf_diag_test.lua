-- SoulspireXI Core: PerfDiag unit, overhead benchmark, redaction, ring-bound,
-- config-load, and export ceiling tests.

local PerfDiag    = require('core.perf_diag')
local DataService = require('core.data_service')
local json        = require('core.json')

local function assert_eq(a, b, msg)
    if a ~= b then
        error((msg or 'assert_eq failed') .. ': expected ' .. tostring(b) .. ', got ' .. tostring(a), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or 'assert_true failed', 2)
    end
end

local tmp_root = '/tmp/soulspire_perf_diag_test'
os.execute('rm -rf ' .. tmp_root)
os.execute('mkdir -p ' .. tmp_root .. '/addons/ashita4/config ' .. tmp_root .. '/logs/soulspire_perf')

-- 1. Disabled by default: zero side effects, zero export, zero listener attachment
do
    local t = 10.0
    local ds = DataService.new({ clock = function() return t end, auto_load = false })
    local pd = PerfDiag.new({
        clock        = function() return t end,
        data_service = ds,
        config_path  = tmp_root .. '/addons/ashita4/config/soulspire_perf_diag.json',
        export_path  = tmp_root .. '/logs/soulspire_perf/core-perf-latest.json',
    })
    assert_eq(pd:load_config(), false, 'Missing config file keeps perfdiag disabled')
    assert_eq(pd.enabled, false, 'Disabled by default')
    pd:begin_flow('core_ui_open')
    t = t + 0.015
    pd:end_flow('core_ui_open', 'complete')
    pd:record_frame(16.6, 0.4, 0.1)
    assert_eq(pd.frame_total_count, 0, 'Disabled record_frame must be zero-op')
    assert_eq(next(pd.flows), nil, 'Disabled must not allocate flow entries')
    assert_eq(pd:flush_due(t + 60.0), false, 'Disabled flush_due does nothing')
end

-- 2. Config sync load (`enabled = true`) + DataService + CharacterState + explicit outcomes + redaction
do
    local t = 100.0
    local sent_packets = 0
    local cfg_file = tmp_root .. '/addons/ashita4/config/soulspire_perf_diag.json'
    local exp_file = tmp_root .. '/logs/soulspire_perf/core-perf-latest.json'
    local f = assert(io.open(cfg_file, 'w'))
    f:write('{"enabled":true,"source_channel":"testing","server_target_class":"staging"}\n')
    f:close()

    local ds = DataService.new({ clock = function() return t end, auto_load = false })
    local pd = PerfDiag.new({
        clock        = function() return t end,
        data_service = ds,
        config_path  = cfg_file,
        export_path  = exp_file,
    })
    assert_eq(pd:load_config(), true, 'Config enables perfdiag cleanly')
    assert_eq(pd.source_channel, 'testing')
    assert_eq(pd.server_target_class, 'staging')

    -- Cold vs Warm segmentation + incomplete interruption
    pd:begin_flow('core_ui_open', { scope = 'client_only' })
    t = t + 0.012
    pd:end_flow('core_ui_open', 'complete')
    pd:begin_flow('core_ui_open', { scope = 'client_only' })
    t = t + 0.004
    pd:end_flow('core_ui_open', 'complete')

    pd:begin_flow('zone_transition', { scope = 'client_plus_server_rtt' })
    pd:begin_flow('crystal_sync', { scope = 'client_plus_server_rtt' })
    t = t + 0.500
    pd:interrupt_inflight('zone_change') -- zone_transition survives, crystal_sync marked incomplete!
    t = t + 0.200
    pd:end_flow('zone_transition', 'complete')

    -- DataService sync attempt hooks feed wm_sync & wm_ws_select without extra packets
    ds:record_sync_attempt({ op = 'cache_sync', latencyMs = 45.0, outcome = 'ok', packetsIn = 3, bytesIn = 420 })
    ds:record_sync_attempt({ op = 'OP_WS', wsId = 42, latencyMs = 18.0, outcome = 'ok', packetsIn = 2, bytesIn = 310 })
    ds:record_sync_attempt({ op = 'cache_sync', latencyMs = 5000.0, outcome = 'timeout', retries = 2 })
    pd:record_flow('talent_mutation', 32.5, 'complete', { scope = 'client_plus_server_rtt' })
    pd:record_flow('equip_menu', 9.2, 'cancelled', { scope = 'observed_proxy' })
    pd:record_frame(16.6, 0.3, 0.1)
    pd:record_frame(42.0, 0.5, 0.2)
    assert_eq(sent_packets, 0, 'PerfDiag must never generate network traffic')

    -- Redaction check: paths & IPs scrubbed inside recent_samples / flow fields
    local redacted = PerfDiag.redact_string('C:\\Users\\RinPlayer\\AppData\\Local\\test from 192.168.86.117 /root/secret/db')
    assert_true(redacted:find('RinPlayer', 1, true) == nil, 'Windows user path redacted')
    assert_true(redacted:find('192.168.86.117', 1, true) == nil, 'IP redacted')
    assert_true(redacted:find('/root/secret', 1, true) == nil, 'Host path redacted')

    local ok_exp, path_out, nbytes = pd:export_bundle(t)
    assert_true(ok_exp == true and path_out == exp_file, 'Atomic export succeeds')
    assert_true(nbytes > 0 and nbytes < PerfDiag.MAX_EXPORT_BYTES, 'Export under 256 KB ceiling')

    local rf = assert(io.open(exp_file, 'r'))
    local raw = rf:read('*a')
    rf:close()
    local parsed = assert(json.decode(raw), 'Exported JSON decodes cleanly')
    assert_eq(parsed.schema_version, 'soulspire-core-perf-1.0.0')
    assert_eq(parsed.client_flows.core_ui_open.cold.outcomes.complete, 1)
    assert_eq(parsed.client_flows.core_ui_open.warm.outcomes.complete, 1)
    assert_eq(parsed.client_flows.crystal_sync.cold.outcomes.incomplete, 1)
    assert_eq(parsed.client_flows.wm_sync.op_cache_sync_count, 2)
    assert_eq(parsed.client_flows.wm_sync.cold.outcomes.complete, 1)
    assert_eq(parsed.client_flows.wm_sync.warm.outcomes.failed, 1)
    assert_eq(parsed.client_flows.equip_menu.cold.outcomes.cancelled, 1)
    assert_eq(parsed.client_flows.equip_menu.cold.attribution_scope, 'observed_proxy')
    assert_eq(parsed.runtime_health.frame_ms.n, 2)
    assert_eq(parsed.runtime_health.frame_ms.hitches_gt_33ms, 1)
end

-- 3. Bounded buffer & < 256 KB ceiling check under heavy flow spam
do
    local t = 200.0
    local exp_file = tmp_root .. '/logs/soulspire_perf/core-perf-heavy.json'
    local pd = PerfDiag.new({
        enabled     = true,
        clock       = function() return t end,
        export_path = exp_file,
    })
    for i = 1, 600 do
        t = t + 0.001
        pd:record_flow('wm_ws_select', 10 + (i % 20), 'complete', { scope = 'client_plus_server_rtt' })
        pd:record_frame(16.0)
    end
    assert_true(#pd.recent_samples <= PerfDiag.MAX_FLOW_SAMPLES, 'recent_samples bounded at <= 256')
    assert_true(pd.dropped_samples > 0, 'dropped_samples tracked when ring wraps')
    local ok_exp, _, bytes = pd:export_bundle(t)
    assert_true(ok_exp and bytes < PerfDiag.MAX_EXPORT_BYTES, 'Heavy spam bundle strictly < 256 KB')
end

-- 4. Real LuaJIT instrumentation overhead microbenchmark (disabled vs enabled)
do
    local pd_off = PerfDiag.new({ enabled = false })
    local pd_on  = PerfDiag.new({ enabled = true })
    local N = 50000

    collectgarbage('collect')
    local t0_off = os.clock()
    for _ = 1, N do
        pd_off:record_frame(16.6)
    end
    local dt_off_us = ((os.clock() - t0_off) * 1e6) / N

    collectgarbage('collect')
    local mem0 = collectgarbage('count')
    local t0_on = os.clock()
    for _ = 1, N do
        pd_on:record_frame(16.6)
    end
    local dt_on_us = ((os.clock() - t0_on) * 1e6) / N
    local mem_kb = math.max(0, collectgarbage('count') - mem0)

    print(string.format('BENCHMARK N=%d disabled=%.4f us/op enabled=%.4f us/op mem_delta=%.2f KB',
        N, dt_off_us, dt_on_us, mem_kb))
    assert_true(dt_off_us < 1.0, 'Disabled guard must be < 1 us/op, got ' .. tostring(dt_off_us))
    assert_true(dt_on_us < 50.0, 'Enabled record_frame must be < 50 us/op (0.05ms), got ' .. tostring(dt_on_us))
end

os.execute('rm -rf ' .. tmp_root)
print('PerfDiag LuaJIT tests + overhead benchmark passed.')
