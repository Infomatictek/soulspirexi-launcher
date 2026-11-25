-- Unit tests for SoulspireXI Narrowly Scoped Developer Weapon Render Probe.
package.path = './?.lua;./core/?.lua;' .. package.path

local Probe = require('core.weapon_render_probe')

local function write_u16_le(buf, off0, val)
    buf[off0 + 1] = val % 256
    buf[off0 + 2] = math.floor(val / 256) % 256
end

local function write_u32_le(buf, off0, val)
    buf[off0 + 1] = val % 256
    buf[off0 + 2] = math.floor(val / 256) % 256
    buf[off0 + 3] = math.floor(val / 65536) % 256
    buf[off0 + 4] = math.floor(val / 16777216) % 256
end

local function write_hex(buf, off0, hex)
    local p = off0
    for i = 1, #hex, 2 do
        buf[p + 1] = tonumber(hex:sub(i, i + 1), 16)
        p = p + 1
    end
end

-- 1. Strictly fail-closed when developer diagnostics are disabled (default).
do
    local ok, err = Probe.run_live_probe({ diagnostics_enabled = false })
    assert(ok == false, 'probe must refuse when diagnostics_enabled == false')
    assert(tostring(err):find('disabled', 1, true) ~= nil, 'expected disabled error message')

    local ok2 = Probe.run_live_probe({})
    assert(ok2 == false, 'probe must refuse when diagnostics_enabled is omitted')
end

-- 2. Synthetic PE32 header + .text buffer test (narrow code-window capture, ASLR normalization, zero PII).
do
    local hdr = {}
    for i = 1, 4096 do hdr[i] = 0 end
    hdr[1] = 0x4D; hdr[2] = 0x5A -- MZ
    write_u32_le(hdr, 0x3C, 0x80) -- e_lfanew
    hdr[0x80 + 1] = 0x50; hdr[0x80 + 2] = 0x45 -- PE\0\0
    write_u16_le(hdr, 0x80 + 4, 0x014C) -- i386
    write_u16_le(hdr, 0x80 + 6, 1)      -- 1 section (.text)
    write_u32_le(hdr, 0x80 + 8, Probe.EXPECTED_TIMESTAMP)
    write_u16_le(hdr, 0x80 + 20, 0xE0)  -- optional header size
    local opt = 0x80 + 24
    write_u32_le(hdr, opt + 28, 0x10000000)
    write_u32_le(hdr, opt + 56, Probe.EXPECTED_IMAGE_SIZE)

    local sec = opt + 0xE0
    local name = '.text'
    for i = 1, #name do hdr[sec + i] = name:byte(i) end
    write_u32_le(hdr, sec + 8, 0x2000) -- VirtualSize
    write_u32_le(hdr, sec + 12, 0x1000) -- VirtualAddress (.text RVA)

    local pe, perr = Probe.parse_pe_header(hdr)
    assert(pe ~= nil and perr == nil, 'PE header parse must succeed: ' .. tostring(perr))
    assert(pe.fingerprint_match == true, 'expected fingerprint_match == true')
    assert(pe.text_rva == 0x1000 and pe.text_virtual_size == 0x2000)

    -- Synthetic .text bytes containing D3D8 SetTransform(D3DTS_WORLD), wep0, wep1, 0x6000, 0x7000
    local text = {}
    for i = 1, 0x2000 do text[i] = 0x90 end
    -- D3DTS_WORLD + call [eax+0x94] at offset 0x100 (RVA 0x1100)
    write_hex(text, 0x100, '6800010000518b088b018b5004ff9094000000')
    -- wep0 at offset 0x300 (RVA 0x1300)
    write_hex(text, 0x300, '77657030')
    -- wep1 at offset 0x400 (RVA 0x1400)
    write_hex(text, 0x400, '77657031')
    -- cmp ax, 0x6000 at offset 0x500 (RVA 0x1500)
    write_hex(text, 0x500, '663d0060')
    -- cmp ax, 0x7000 at offset 0x600 (RVA 0x1600)
    write_hex(text, 0x600, '663d0070')

    local mock_mem = {
        read_array = function(addr, len)
            if addr == 0x77000000 and len == 4096 then return hdr end
            if addr == 0x77001000 and len == 0x2000 then return text end
            return nil
        end,
    }

    local ok, report = Probe.run_live_probe({
        diagnostics_enabled = true,
        memory = mock_mem,
        module_base = 0x77000000, -- non-default ASLR base to verify normalization!
        actor_summary = {
            race_id = 2,
            look_main = 94,
            look_sub = 93,
            status_id = 1,
            has_render_ptr = true,
            -- Intentionally inject fake PII keys to verify they are stripped:
            character_name = 'SHOULD_NOT_APPEAR',
            account_id = 999999,
            password = 'SECRET_VALUE',
        },
    })
    assert(ok == true and type(report) == 'table', 'live probe must succeed on valid synthetic .text')
    local json = Probe.serialize_report_json(report)

    -- Zero ASLR base leak & zero PII leak
    assert(json:find('77000000', 1, true) == nil, 'live ASLR base address must NEVER appear in probe output')
    assert(json:find('SHOULD_NOT_APPEAR', 1, true) == nil, 'character_name must NEVER appear in probe output')
    assert(json:find('999999', 1, true) == nil, 'account_id must NEVER appear in probe output')
    assert(json:find('SECRET_VALUE', 1, true) == nil, 'credentials must NEVER appear in probe output')

    -- Expected normalized RVAs & findings
    local by_id = {}
    for _, f in ipairs(report.findings) do by_id[f.id] = f end
    assert(by_id.d3d8_set_transform_world_eax94.match_count == 1)
    assert(by_id.d3d8_set_transform_world_eax94.matches[1].rva == '0x1100')
    assert(by_id.d3d8_set_transform_world_eax94.matches[1].va_normalized == '0x10001100')
    assert(by_id.wep0_fourcc_le.match_count == 1 and by_id.wep0_fourcc_le.matches[1].rva == '0x1300')
    assert(by_id.wep1_fourcc_le.match_count == 1 and by_id.wep1_fourcc_le.matches[1].rva == '0x1400')
    assert(by_id.grap_empty_main_6000.match_count == 1 and by_id.grap_empty_main_6000.matches[1].rva == '0x1500')
    assert(by_id.grap_empty_sub_7000.match_count == 1 and by_id.grap_empty_sub_7000.matches[1].rva == '0x1600')
    assert(report.actor_model_summary.race_id == 2 and report.actor_model_summary.look_main == 94 and report.actor_model_summary.look_sub == 93)

    -- 3. Comparative labeled snapshot accumulation & automatic CXiSkeletonActor diff test.
    Probe.clear_snapshots()
    assert(Probe.snapshot_count() == 0)
    local ok_a, rep_a = Probe.run_live_probe({
        diagnostics_enabled = true,
        memory = mock_mem,
        module_base = 0x77000000,
        label = '1h_single',
        actor_summary = { race_id = 2, look_main = 0x6010, look_sub = 0x7000, status_id = 0, has_render_ptr = true },
        actor_words_override = { [0x764] = 'obj:vt=0xC5190', [0x814] = '0' },
    })
    assert(ok_a == true and #rep_a.comparative_snapshots == 1 and #rep_a.comparative_diff == 0)

    local ok_b, rep_b = Probe.run_live_probe({
        diagnostics_enabled = true,
        memory = mock_mem,
        module_base = 0x77000000,
        label = '1h_dual',
        actor_summary = { race_id = 2, look_main = 0x6010, look_sub = 0x7011, status_id = 0, has_render_ptr = true },
        actor_words_override = { [0x764] = 'obj:vt=0xC5190', [0x814] = 'obj:vt=0xC5190' },
    })
    assert(ok_b == true and #rep_b.comparative_snapshots == 2)
    assert(#rep_b.comparative_diff == 1 and rep_b.comparative_diff[1].offset == '0x814',
        'expected exact diff at 0x814 between 1h_single and 1h_dual')
    local json_b = Probe.serialize_report_json(rep_b)
    assert(json_b:find('"1h_single"', 1, true) ~= nil and json_b:find('"1h_dual"', 1, true) ~= nil)
    assert(json_b:find('77000000', 1, true) == nil, 'ASLR base must never leak in comparative JSON')

    -- Verify sanitize_actor_struct never leaks raw heap pointers or ASLR bases.
    local mock_actor_mem = {
        read_uint32 = function(addr)
            if addr == 0x12345600 + 0x764 then return 0x770C5190 end -- inside FFXiMain.dll
            if addr == 0x12345600 + 0x814 then return 0x22334455 end -- raw heap ptr
            if addr == 0x22334455 then return 0xDEADBEEF end         -- non-vtable heap data
            return 0
        end,
    }
    local san_words = Probe.sanitize_actor_struct(0x12345600, mock_actor_mem, 0x77000000, 0x00C17000)
    assert(san_words[0x764] == 'rva:0xC5190', 'module pointer must normalize to RVA')
    assert(san_words[0x814] == 'ptr:nonnull', 'raw heap pointer must never be emitted')
    Probe.clear_snapshots()

    -- 4. Mandatory diagnostic provenance, unique report filenames, .soulspire-state.json parsing, and probe clear isolation.
    local tmp_dir = '/tmp/soulspire_probe_prov_test'
    os.execute('rm -rf ' .. tmp_dir .. ' && mkdir -p ' .. tmp_dir)
    local sf = assert(io.open(tmp_dir .. '/.soulspire-state.json', 'wb'))
    sf:write('{"Channel":"testing","ManifestVersion":"2.2.0-testing.19","LastSyncedUtc":"2026-11-25T05:00:00Z"}')
    sf:close()

    local lst = Probe.read_launcher_state(tmp_dir)
    assert(lst.manifest_version == '2.2.0-testing.19', 'expected parsed ManifestVersion')
    assert(lst.channel == 'testing', 'expected parsed Channel')

    local ok_p1, rep_p1, path_p1 = Probe.run_live_probe({
        diagnostics_enabled = true,
        memory = mock_mem,
        module_base = 0x77000000,
        output_dir = tmp_dir,
        ashita_root_dir = tmp_dir,
        native_dll_version_override = 'abi=v2 hooks=32/32 caps=0x37FFF',
        utc_iso_override = '2026-11-25T05:10:00Z',
        utc_file_stamp_override = '20261125-051000',
        label = 'dual_1h_ref',
        actor_summary = { race_id = 2, look_main = 0x605A, look_sub = 0x704C, status_id = 0, has_render_ptr = true },
    })
    assert(ok_p1 == true and type(rep_p1) == 'table', 'provenance probe 1 must succeed')
    assert(path_p1 == (tmp_dir .. '/soul-weapon-render-probe-' .. Probe.PROBE_VERSION .. '-20261125-051000.json'),
        'expected unique timestamped filename, got: ' .. tostring(path_p1))

    -- Same-second second capture must generate a distinct filename (-02) and distinct captureId.
    local ok_p2, rep_p2, path_p2 = Probe.run_live_probe({
        diagnostics_enabled = true,
        memory = mock_mem,
        module_base = 0x77000000,
        output_dir = tmp_dir,
        ashita_root_dir = tmp_dir,
        native_dll_version_override = 'abi=v2 hooks=32/32 caps=0x37FFF',
        utc_iso_override = '2026-11-25T05:10:00Z',
        utc_file_stamp_override = '20261125-051000',
        label = 'dual_ga_hook32',
        actor_summary = { race_id = 2, look_main = 0x625B, look_sub = 0x705F, status_id = 0, has_render_ptr = true },
    })
    assert(ok_p2 == true and path_p2 ~= path_p1, 'second capture must write a uniquely named file')
    assert(path_p2 == (tmp_dir .. '/soul-weapon-render-probe-' .. Probe.PROBE_VERSION .. '-20261125-051000-02.json'),
        'expected -02 collision suffix, got: ' .. tostring(path_p2))
    assert(rep_p2.provenance.capture_id ~= rep_p1.provenance.capture_id, 'captureId must be unique per run')

    -- Verify file on disk contains all 10 mandatory provenance fields and required sections.
    local rf = assert(io.open(path_p2, 'rb'))
    local disk_json = rf:read('*a')
    rf:close()
    for _, key in ipairs({
        '"provenance"',
        '"captureId"',
        '"generatedAtUtc": "2026-11-25T05:10:00Z"',
        '"probeVersion": "' .. Probe.PROBE_VERSION .. '"',
        '"probeSourceCommit": "' .. Probe.PROBE_SOURCE_COMMIT .. '"',
        '"loadedLuaPath"',
        '"activeLauncherManifestVersion": "2.2.0-testing.19"',
        '"nativeDllVersion": "abi=v2 hooks=32/32 caps=0x37FFF"',
        '"captureLabels": ["dual_1h_ref", "dual_ga_hook32"]',
        '"requiredDiagnosticSections"',
        '"attach_equip_model_downstream_slices"',
        '"outputPath": "' .. path_p2 .. '"',
    }) do
        assert(disk_json:find(key, 1, true) ~= nil, 'missing mandatory provenance key/value on disk: ' .. key)
    end

    -- Verify probe clear removes all previous comparative snapshots completely.
    local clr = Probe.clear_snapshots()
    assert(clr.cleared_count == 2 and Probe.snapshot_count() == 0, 'clear_snapshots must remove all prior snapshots')
    local ok_p3, rep_p3 = Probe.run_live_probe({
        diagnostics_enabled = true,
        memory = mock_mem,
        module_base = 0x77000000,
        output_dir = tmp_dir,
        ashita_root_dir = tmp_dir,
        utc_iso_override = '2026-11-25T05:10:05Z',
        utc_file_stamp_override = '20261125-051005',
        label = 'fresh_only',
        actor_summary = { race_id = 2, look_main = 0x605F, look_sub = 0x705E, status_id = 0, has_render_ptr = true },
    })
    assert(ok_p3 == true and #rep_p3.provenance.capture_labels == 1 and rep_p3.provenance.capture_labels[1] == 'fresh_only',
        'after clear, captureLabels must contain ONLY the new label')
    os.execute('rm -rf ' .. tmp_dir)
    Probe.clear_snapshots()
end

print('weapon_render_probe_test: ALL PASSED')
