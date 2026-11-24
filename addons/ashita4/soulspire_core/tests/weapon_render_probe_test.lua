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
end

print('weapon_render_probe_test: ALL PASSED')
