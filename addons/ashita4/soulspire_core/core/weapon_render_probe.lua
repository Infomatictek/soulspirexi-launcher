-- SoulspireXI — Narrowly Scoped Developer Weapon-Attachment Research Probe (Ashita v4)
--
-- Strictly developer-only and DISABLED BY DEFAULT:
--   * Refuses to execute unless `/soulspire weapondiag on` has been explicitly enabled.
--   * Uses ONLY supported Ashita v4 read-only module inspection (no loader bypass,
--     no memory writes, no full process dumps).
--   * Reads ONLY strictly bounded `.text` executable code windows inside the loaded
--     FFXiMain.dll module (normalized to ImageBase 0x10000000 so live ASLR bases
--     are never written) plus non-PII numeric actor model IDs.
--   * Excludes credentials, account IDs, character names, chat, inventory, heap,
--     stack, .data, and unrelated process memory.
--   * Output (`plugins/data/soul-weapon-render-probe.local.json`) is strictly private,
--     gitignored, and outside manifest distribution.

local M = {}

M.SCHEMA_VERSION        = 3
M.PROBE_VERSION         = 'v19'
M.PROBE_SOURCE_COMMIT   = '2.2.3-testing.5'
M.EXPECTED_TIMESTAMP    = 0x6AE818B4
M.EXPECTED_IMAGE_SIZE   = 0x00C17000
M.NORMALIZED_IMAGE_BASE = 0x10000000
M.WINDOW_BEFORE         = 64
M.WINDOW_AFTER          = 192
M.MAX_MATCHES_PER_RULE  = 24
M.MAX_SNAPSHOTS         = 12

local function resolve_loaded_lua_path()
    if type(debug) == 'table' and type(debug.getinfo) == 'function' then
        local info = debug.getinfo(1, 'S')
        if info and type(info.source) == 'string' and info.source ~= '' then
            local src = info.source
            if src:sub(1, 1) == '@' then
                src = src:sub(2)
            end
            return src
        end
    end
    return 'unknown'
end

M.LOADED_LUA_PATH = resolve_loaded_lua_path()

-- Accumulated in-memory comparative snapshots and monotonic capture sequence for the active developer session.
local comparative_snapshots = {}
local capture_seq = 0
local last_utc_stamp = ''
local same_second_seq = 0

function M.clear_snapshots()
    local prev = #comparative_snapshots
    comparative_snapshots = {}
    return {
        cleared_count   = prev,
        probe_version   = M.PROBE_VERSION,
        loaded_lua_path = M.LOADED_LUA_PATH,
    }
end

function M.snapshot_count()
    return #comparative_snapshots
end

-- Read-only lookup of <AshitaPath>/.soulspire-state.json written by SoulspireLauncher.
function M.read_launcher_state(ashita_root_dir)
    if type(ashita_root_dir) ~= 'string' or ashita_root_dir == '' then
        return { manifest_version = 'unavailable', channel = 'unavailable', state_path = '' }
    end
    local sep = ashita_root_dir:find('\\', 1, true) and '\\' or '/'
    local clean_root = ashita_root_dir:gsub('[/\\]+$', '')
    local state_path = clean_root .. sep .. '.soulspire-state.json'
    local f = io.open(state_path, 'rb')
    if not f then
        return { manifest_version = 'unavailable', channel = 'unavailable', state_path = state_path }
    end
    local body = f:read('*a') or ''
    f:close()
    local mver = body:match('"[Mm]anifestVersion"%s*:%s*"([^"]*)"')
    local chan = body:match('"[Cc]hannel"%s*:%s*"([^"]*)"')
    return {
        manifest_version = (mver and mver ~= '') and mver or 'unavailable',
        channel          = (chan and chan ~= '') and chan or 'unavailable',
        state_path       = state_path,
    }
end

-- Read-only query of active Soulspire Native DLL version/hook/capability summary.
function M.query_native_dll_version()
    local ok_nb, NativeBridge = pcall(require, 'core.native_bridge')
    if not (ok_nb and type(NativeBridge) == 'table') then
        return 'unavailable'
    end
    if type(NativeBridge.get_interface_info) == 'function' then
        local ok_ii, ii = pcall(NativeBridge.get_interface_info)
        if ok_ii and type(ii) == 'table' and ii.abi_version then
            return string.format('abi=v%d hooks=%d/%d caps=0x%X',
                tonumber(ii.abi_version) or 0,
                tonumber(ii.installed_hooks) or 0,
                tonumber(ii.expected_hooks) or 0,
                tonumber(ii.capabilities) or 0)
        end
    end
    return 'unavailable'
end

-- Build a uniquely named report path in output_dir:
--   soul-weapon-render-probe-<probeVersion>-<YYYYMMDD-HHMMSS>[-NN].json
function M.build_unique_output_path(output_dir, probe_version, utc_file_stamp, same_sec_idx)
    local sep = output_dir:find('\\', 1, true) and '\\' or '/'
    local clean_dir = output_dir:gsub('[/\\]+$', '')
    local ver = tostring(probe_version or M.PROBE_VERSION):gsub('[^%w_%-]', '')
    local stamp = tostring(utc_file_stamp or os.date('!%Y%m%d-%H%M%S'))
    local suffix = (same_sec_idx and same_sec_idx > 1) and string.format('-%02d', same_sec_idx) or ''
    return string.format('%s%ssoul-weapon-render-probe-%s-%s%s.json', clean_dir, sep, ver, stamp, suffix)
end

-- Subset of already-verified layout.h RVAs (TS=0x6AE818B4) used strictly as
-- read-only alignment anchors on the live loaded FFXiMain.dll `.text` section.
M.ANCHOR_SIGNATURES = {
    { name = 'equip_sub_dw_gate',    rva = 0x133D56, hex = '688b000000e86075ffff' },
    { name = 'equip_sub_menu_list',  rva = 0x21DF85, hex = '8546f4745f8b420c33db' },
    { name = 'equip_sub_2h_main',    rva = 0x133DD3, hex = '6899000000e8e374ffff' },
    { name = 'equip_can_in_slot',    rva = 0x133E33, hex = 'e848f7ffff84c07524fe' },
    { name = 'get_item_resource',    rva = 0x15D210, hex = 'b8ac150000e876651b00' },
}

-- Narrowly targeted `.text` code patterns for 3D weapon bone-attachment discovery.
-- Pattern syntax: pairs of hex chars or '??' wildcard.
M.PROBE_PATTERNS = {
    {
        id = 'd3d8_set_transform_world_eax94',
        desc = 'push 0x100 (D3DTS_WORLD) followed by call [eax+0x94] (IDirect3DDevice8::SetTransform)',
        pattern = '6800010000????????????????ff9094000000',
    },
    {
        id = 'd3d8_set_transform_world_ecx94',
        desc = 'push 0x100 (D3DTS_WORLD) followed by call [ecx+0x94]',
        pattern = '6800010000????????????????ff9194000000',
    },
    {
        id = 'd3d8_set_transform_world_edx94',
        desc = 'push 0x100 (D3DTS_WORLD) followed by call [edx+0x94]',
        pattern = '6800010000????????????????ff9294000000',
    },
    {
        id = 'd3d8_set_transform_world_push_only',
        desc = 'push 0x100 (D3DTS_WORLD) immediate in .text (filtered by nearby 0x94 vtable call)',
        pattern = '6800010000',
        require_nearby_hex = '94000000',
        nearby_range = 40,
    },
    {
        id = 'wep0_fourcc_le',
        desc = 'ASCII FourCC wep0 (main weapon mesh tag) referenced in .text',
        pattern = '77657030',
    },
    {
        id = 'wep1_fourcc_le',
        desc = 'ASCII FourCC wep1 (sub weapon mesh tag) referenced in .text',
        pattern = '77657031',
    },
    {
        id = 'wep2_fourcc_le',
        desc = 'ASCII FourCC wep2 (in-hand weapon mesh tag) referenced in .text',
        pattern = '77657032',
    },
    {
        id = 'grap_empty_main_6000',
        desc = '16-bit comparison against 0x6000 (empty Main GrapIDTbl[6] sentinel)',
        pattern = '663d0060',
    },
    {
        id = 'grap_empty_sub_7000',
        desc = '16-bit comparison against 0x7000 (empty Sub GrapIDTbl[7] sentinel)',
        pattern = '663d0070',
    },
    {
        id = 'grap_sub_7000_reg16',
        desc = '16-bit reg op with 0x7000 (Sub GrapIDTbl[7] mask/compare on non-AX reg)',
        pattern = '6681??0070',
    },
    {
        id = 'grap_sub_7000_or_eax',
        desc = '32-bit OR EAX, 0x7000 (Sub weapon model slot tag builder)',
        pattern = '0d00700000',
    },
}

local function bytes_to_hex(bytes)
    local t = {}
    for i = 1, #bytes do
        t[i] = string.format('%02x', bytes[i] or 0)
    end
    return table.concat(t)
end

local function hex_to_pattern(hex)
    local pat = {}
    for i = 1, #hex, 2 do
        local pair = hex:sub(i, i + 1)
        if pair == '??' then
            pat[#pat + 1] = false
        else
            pat[#pat + 1] = tonumber(pair, 16)
        end
    end
    return pat
end

local function read_u16_le(buf, off0)
    local b1 = buf[off0 + 1]
    local b2 = buf[off0 + 2]
    if not b1 or not b2 then return nil end
    return b1 + b2 * 256
end

local function read_u32_le(buf, off0)
    local b1 = buf[off0 + 1]
    local b2 = buf[off0 + 2]
    local b3 = buf[off0 + 3]
    local b4 = buf[off0 + 4]
    if not b4 then return nil end
    return b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
end

local function json_escape(s)
    return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
end

-- Parse PE32 header from a 4096-byte header array (1-based Lua table of uint8).
function M.parse_pe_header(hdr)
    if type(hdr) ~= 'table' or #hdr < 0x100 then
        return nil, 'header too short'
    end
    if hdr[1] ~= 0x4D or hdr[2] ~= 0x5A then
        return nil, 'missing MZ header'
    end
    local pe_off = read_u32_le(hdr, 0x3C)
    if not pe_off or pe_off + 0x80 > #hdr then
        return nil, 'invalid e_lfanew'
    end
    if hdr[pe_off + 1] ~= 0x50 or hdr[pe_off + 2] ~= 0x45 or hdr[pe_off + 3] ~= 0 or hdr[pe_off + 4] ~= 0 then
        return nil, 'missing PE signature'
    end
    local machine  = read_u16_le(hdr, pe_off + 4)
    local num_sec  = read_u16_le(hdr, pe_off + 6)
    local ts       = read_u32_le(hdr, pe_off + 8)
    local opt_sz   = read_u16_le(hdr, pe_off + 20)
    local opt_off  = pe_off + 24
    local img_base = read_u32_le(hdr, opt_off + 28)
    local img_size = read_u32_le(hdr, opt_off + 56)

    local text_va, text_vsz = nil, nil
    local rdata_va, rdata_vsz = nil, nil
    local sec_off = opt_off + opt_sz
    for i = 0, (num_sec or 0) - 1 do
        local s = sec_off + i * 40
        if s + 40 > #hdr then break end
        local name_chars = {}
        for j = 0, 7 do
            local c = hdr[s + j + 1]
            if c == 0 then break end
            name_chars[#name_chars + 1] = string.char(c)
        end
        local name = table.concat(name_chars)
        if name == '.text' then
            text_vsz = read_u32_le(hdr, s + 8)
            text_va  = read_u32_le(hdr, s + 12)
        elseif name == '.rdata' then
            rdata_vsz = read_u32_le(hdr, s + 8)
            rdata_va  = read_u32_le(hdr, s + 12)
        end
    end

    return {
        machine            = machine,
        time_date_stamp    = ts,
        size_of_image      = img_size,
        preferred_base     = img_base,
        text_rva           = text_va,
        text_virtual_size  = text_vsz,
        rdata_rva          = rdata_va,
        rdata_virtual_size = rdata_vsz,
        fingerprint_match  = (ts == M.EXPECTED_TIMESTAMP and img_size == M.EXPECTED_IMAGE_SIZE),
    }, nil
end

-- Scan a bounded `.text` byte buffer (1-based array of uint8 starting at text_rva)
-- strictly for the narrowly scoped weapon-attachment probe rules.
function M.scan_text_buffer(text_bytes, text_rva, pe_info, actor_summary, extra_opts)
    extra_opts = extra_opts or {}
    if type(text_bytes) ~= 'table' or #text_bytes == 0 then
        return nil, 'empty .text buffer'
    end
    local text_len = #text_bytes
    local text_end_rva = text_rva + text_len

    -- 1. Verify anchor signatures strictly within .text
    local anchors = {}
    local anchor_matched = 0
    for _, anc in ipairs(M.ANCHOR_SIGNATURES) do
        local exp = hex_to_pattern(anc.hex)
        local rel0 = anc.rva - text_rva
        local ok = false
        if rel0 >= 0 and (rel0 + #exp) <= text_len then
            ok = true
            for k = 1, #exp do
                if text_bytes[rel0 + k] ~= exp[k] then
                    ok = false
                    break
                end
            end
        end
        if ok then anchor_matched = anchor_matched + 1 end
        anchors[#anchors + 1] = {
            name = anc.name,
            rva = string.format('0x%X', anc.rva),
            matched = ok,
        }
    end

    -- 2. Scan narrowly scoped patterns strictly within .text
    local findings = {}
    for _, rule in ipairs(M.PROBE_PATTERNS) do
        local pat = hex_to_pattern(rule.pattern)
        local pat_len = #pat
        local nearby = rule.require_nearby_hex and hex_to_pattern(rule.require_nearby_hex) or nil
        local nearby_range = rule.nearby_range or 0
        local matches = {}

        local max_i = text_len - pat_len + 1
        local i = 1
        while i <= max_i and #matches < M.MAX_MATCHES_PER_RULE do
            local hit = true
            for k = 1, pat_len do
                local want = pat[k]
                if want ~= false and text_bytes[i + k - 1] ~= want then
                    hit = false
                    break
                end
            end
            if hit and nearby then
                local found_near = false
                local nlen = #nearby
                local stop_j = math.min(text_len - nlen + 1, i + pat_len + nearby_range)
                for j = i + pat_len, stop_j do
                    local nok = true
                    for nk = 1, nlen do
                        if nearby[nk] ~= false and text_bytes[j + nk - 1] ~= nearby[nk] then
                            nok = false
                            break
                        end
                    end
                    if nok then
                        found_near = true
                        break
                    end
                end
                if not found_near then hit = false end
            end

            if hit then
                local match_rva = text_rva + (i - 1)
                local win_start_rva = math.max(text_rva, match_rva - M.WINDOW_BEFORE)
                local win_end_rva   = math.min(text_end_rva, match_rva + M.WINDOW_AFTER)
                local win_bytes = {}
                local start_idx = (win_start_rva - text_rva) + 1
                local end_idx   = (win_end_rva - text_rva)
                for p = start_idx, end_idx do
                    win_bytes[#win_bytes + 1] = text_bytes[p]
                end
                matches[#matches + 1] = {
                    rva              = string.format('0x%X', match_rva),
                    va_normalized    = string.format('0x%08X', M.NORMALIZED_IMAGE_BASE + match_rva),
                    window_start_rva = string.format('0x%X', win_start_rva),
                    window_len       = #win_bytes,
                    code_hex         = bytes_to_hex(win_bytes),
                }
                i = i + pat_len
            else
                i = i + 1
            end
        end

        findings[#findings + 1] = {
            id          = rule.id,
            description = rule.desc,
            match_count = #matches,
            matches     = matches,
        }
    end

    local function capture_window(match_rva)
        local win_start_rva = math.max(text_rva, match_rva - M.WINDOW_BEFORE)
        local win_end_rva   = math.min(text_end_rva, match_rva + M.WINDOW_AFTER)
        local win_bytes = {}
        local start_idx = (win_start_rva - text_rva) + 1
        local end_idx   = (win_end_rva - text_rva)
        for p = start_idx, end_idx do
            win_bytes[#win_bytes + 1] = text_bytes[p]
        end
        return {
            rva              = string.format('0x%X', match_rva),
            va_normalized    = string.format('0x%08X', M.NORMALIZED_IMAGE_BASE + match_rva),
            window_start_rva = string.format('0x%X', win_start_rva),
            window_len       = #win_bytes,
            code_hex         = bytes_to_hex(win_bytes),
        }
    end

    -- 2b. Callers of CDx::SetTransform (RVA 0xBD50) preceded by push 0x100 (D3DTS_WORLD).
    do
        local target_rva = 0xBD50
        local matches = {}
        for i = 1, text_len - 5 do
            if #matches >= M.MAX_MATCHES_PER_RULE then break end
            if text_bytes[i] == 0xE8 then
                local rel = read_u32_le(text_bytes, i)
                if rel then
                    if rel >= 0x80000000 then rel = rel - 0x100000000 end
                    local call_rva = text_rva + (i - 1)
                    if (call_rva + 5 + rel) == target_rva then
                        local has_world = false
                        local back = math.max(1, i - 24)
                        for j = back, i - 5 do
                            if text_bytes[j] == 0x68 and text_bytes[j + 1] == 0x00
                                and text_bytes[j + 2] == 0x01 and text_bytes[j + 3] == 0x00
                                and text_bytes[j + 4] == 0x00 then
                                has_world = true
                                break
                            end
                        end
                        if has_world then
                            matches[#matches + 1] = capture_window(call_rva)
                        end
                    end
                end
            end
        end
        findings[#findings + 1] = {
            id          = 'cdx_set_transform_world_callers',
            description = 'Direct callers of CDx::SetTransform (0xBD50) with push 0x100 (D3DTS_WORLD)',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2c. .rdata string cross-references for weapon tags (wep0, wep1, wep2).
    if type(extra_opts.rdata_bytes) == 'table' and extra_opts.rdata_rva and extra_opts.module_base then
        local rbytes = extra_opts.rdata_bytes
        local rlen = #rbytes
        local rrva = extra_opts.rdata_rva
        local mbase = extra_opts.module_base
        local tags = {
            { id = 'rdata_xref_wep0', bytes = { 0x77, 0x65, 0x70, 0x30 } },
            { id = 'rdata_xref_wep1', bytes = { 0x77, 0x65, 0x70, 0x31 } },
            { id = 'rdata_xref_wep2', bytes = { 0x77, 0x65, 0x70, 0x32 } },
        }
        for _, tg in ipairs(tags) do
            local va_targets = {}
            for ri = 1, rlen - 3 do
                if rbytes[ri] == tg.bytes[1] and rbytes[ri + 1] == tg.bytes[2]
                    and rbytes[ri + 2] == tg.bytes[3] and rbytes[ri + 3] == tg.bytes[4] then
                    local live_va = mbase + rrva + (ri - 1)
                    va_targets[#va_targets + 1] = {
                        b1 = live_va % 256,
                        b2 = math.floor(live_va / 256) % 256,
                        b3 = math.floor(live_va / 65536) % 256,
                        b4 = math.floor(live_va / 16777216) % 256,
                    }
                    if #va_targets >= 8 then break end
                end
            end
            local matches = {}
            for _, vt in ipairs(va_targets) do
                for ti = 1, text_len - 3 do
                    if #matches >= M.MAX_MATCHES_PER_RULE then break end
                    if text_bytes[ti] == vt.b1 and text_bytes[ti + 1] == vt.b2
                        and text_bytes[ti + 2] == vt.b3 and text_bytes[ti + 3] == vt.b4 then
                        matches[#matches + 1] = capture_window(text_rva + (ti - 1))
                    end
                end
            end
            findings[#findings + 1] = {
                id          = tg.id,
                description = '.text cross-references to .rdata tag ' .. tg.id:sub(-4),
                match_count = #matches,
                matches     = matches,
            }
        end
    end

    -- 2d. GrapIDTbl 0x051 decoder pattern: shr reg, 12 (c1 e8..ef 0c) with nearby 0x0FFF mask.
    do
        local matches = {}
        for i = 1, text_len - 3 do
            if #matches >= M.MAX_MATCHES_PER_RULE then break end
            if text_bytes[i] == 0xC1 and text_bytes[i + 1] >= 0xE8 and text_bytes[i + 1] <= 0xEF
                and text_bytes[i + 2] == 0x0C then
                local has_fff = false
                local s_lo = math.max(1, i - 24)
                local s_hi = math.min(text_len - 1, i + 24)
                for j = s_lo, s_hi do
                    if text_bytes[j] == 0xFF and text_bytes[j + 1] == 0x0F then
                        has_fff = true
                        break
                    end
                end
                if has_fff then
                    matches[#matches + 1] = capture_window(text_rva + (i - 1))
                end
            end
        end
        findings[#findings + 1] = {
            id          = 'grap_slot_shift12_mask0fff',
            description = 'shr reg, 12 with nearby 0x0FFF mask (0x051 GrapIDTbl slot/model decoder)',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2e. Callers of SetWorldMatrix (RVA 0x6A480) — character/skeleton 3D matrix stack users.
    do
        local target_rva = 0x6A480
        local matches = {}
        for i = 1, text_len - 5 do
            if #matches >= M.MAX_MATCHES_PER_RULE then break end
            if text_bytes[i] == 0xE8 then
                local rel = read_u32_le(text_bytes, i)
                if rel then
                    if rel >= 0x80000000 then rel = rel - 0x100000000 end
                    local call_rva = text_rva + (i - 1)
                    if (call_rva + 5 + rel) == target_rva then
                        matches[#matches + 1] = capture_window(call_rva)
                    end
                end
            end
        end
        findings[#findings + 1] = {
            id          = 'matrix_stack_set_world_callers',
            description = 'Direct callers of SetWorldMatrix (0x6A480)',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2f. Normalized CXiActor / model vtable method RVAs (code-only, zero heap/PII).
    if type(extra_opts.vtable_method_rvas) == 'table' and #extra_opts.vtable_method_rvas > 0 then
        local matches = {}
        for _, mrva in ipairs(extra_opts.vtable_method_rvas) do
            if #matches >= M.MAX_MATCHES_PER_RULE then break end
            if mrva >= text_rva and mrva < text_end_rva then
                matches[#matches + 1] = capture_window(mrva)
            end
        end
        findings[#findings + 1] = {
            id          = 'actor_vtable_methods',
            description = 'Normalized .text code windows for local actor render vtable methods',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2g. Targeted FTABLE model DAT resolver slice (0xC51C0..0xC5540) + direct callers.
    do
        local slice_start = 0xC51C0
        local slice_len   = 0x380
        local matches = {}
        if slice_start >= text_rva and (slice_start + slice_len) <= text_end_rva then
            local sbytes = {}
            local s0 = (slice_start - text_rva) + 1
            for p = s0, s0 + slice_len - 1 do
                sbytes[#sbytes + 1] = text_bytes[p]
            end
            matches[#matches + 1] = {
                rva              = string.format('0x%X', slice_start),
                va_normalized    = string.format('0x%08X', M.NORMALIZED_IMAGE_BASE + slice_start),
                window_start_rva = string.format('0x%X', slice_start),
                window_len       = #sbytes,
                code_hex         = bytes_to_hex(sbytes),
            }
        end
        findings[#findings + 1] = {
            id          = 'ftable_model_resolver_slice',
            description = 'Full .text slice for FTABLE model DAT resolver 0xC51C0..0xC5540 (incl. 0xC5260..0xC5290)',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2h. Direct callers of FTABLE model DAT resolver 0xC51C0 and its sub-tables 0xC5260..0xC5290.
    do
        local targets = {
            [0xC51C0] = true,
            [0xC5260] = true,
            [0xC5270] = true,
            [0xC5280] = true,
            [0xC5290] = true,
        }
        local matches = {}
        for i = 1, text_len - 5 do
            if #matches >= M.MAX_MATCHES_PER_RULE then break end
            if text_bytes[i] == 0xE8 then
                local rel = read_u32_le(text_bytes, i)
                if rel then
                    if rel >= 0x80000000 then rel = rel - 0x100000000 end
                    local call_rva = text_rva + (i - 1)
                    local dst = call_rva + 5 + rel
                    if targets[dst] and (call_rva < 0xC51C0 or call_rva > 0xC5250) then
                        matches[#matches + 1] = capture_window(call_rva)
                    end
                end
            end
        end
        findings[#findings + 1] = {
            id          = 'ftable_model_resolver_callers',
            description = 'Direct callers of FTABLE model DAT resolver (0xC51C0 / 0xC5260..0xC5290)',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2i. CXiSkeletonActor weapon-mesh slot references (offsets 0x764 & 0x814) inside 0xC0000..0xE0000.
    do
        local matches = {}
        local lo = math.max(1, (0xC0000 - text_rva) + 1)
        local hi = math.min(text_len - 4, (0xE0000 - text_rva))
        for i = lo, hi do
            if #matches >= M.MAX_MATCHES_PER_RULE then break end
            local b0, b1, b2, b3 = text_bytes[i], text_bytes[i + 1], text_bytes[i + 2], text_bytes[i + 3]
            if (b0 == 0x64 and b1 == 0x07 and b2 == 0x00 and b3 == 0x00) or
               (b0 == 0x14 and b1 == 0x08 and b2 == 0x00 and b3 == 0x00) then
                matches[#matches + 1] = capture_window(text_rva + (i - 1))
            end
        end
        findings[#findings + 1] = {
            id          = 'actor_weapon_slot_764_814_refs',
            description = 'CXiSkeletonActor .text references to sub-model offsets 0x764 / 0x814 (0xC0000..0xE0000)',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2j. Full PC equipment model loader slice (0xD385C..0xD3EE8, Cases 0/1 of 0xD3774 switch).
    do
        local slice_start = 0xD385C
        local slice_len   = 0x68C
        local matches = {}
        local callee_matches = {}
        if slice_start >= text_rva and (slice_start + slice_len) <= text_end_rva then
            local sbytes = {}
            local s0 = (slice_start - text_rva) + 1
            for p = s0, s0 + slice_len - 1 do
                sbytes[#sbytes + 1] = text_bytes[p]
            end
            matches[#matches + 1] = {
                rva              = string.format('0x%X', slice_start),
                va_normalized    = string.format('0x%08X', M.NORMALIZED_IMAGE_BASE + slice_start),
                window_start_rva = string.format('0x%X', slice_start),
                window_len       = #sbytes,
                code_hex         = bytes_to_hex(sbytes),
            }
            -- Follow direct E8 callees inside 0xD385C..0xD3EE8 to capture PC FTABLE DAT resolver in one pass.
            local seen_callees = {}
            for p = s0, s0 + slice_len - 5 do
                if #callee_matches >= 20 then break end
                if text_bytes[p] == 0xE8 then
                    local rel = read_u32_le(text_bytes, p)
                    if rel then
                        if rel >= 0x80000000 then rel = rel - 0x100000000 end
                        local call_rva = text_rva + (p - 1)
                        local dst = call_rva + 5 + rel
                        if dst >= text_rva and dst < text_end_rva and not seen_callees[dst] then
                            seen_callees[dst] = true
                            callee_matches[#callee_matches + 1] = capture_window(dst)
                        end
                    end
                end
            end
        end
        findings[#findings + 1] = {
            id          = 'pc_equip_model_loader_slice',
            description = 'Full .text slice for PC equipment model loader 0xD385C..0xD3EE8 (0xD3774 cases 0/1)',
            match_count = #matches,
            matches     = matches,
        }
        findings[#findings + 1] = {
            id          = 'pc_equip_loader_callees',
            description = 'Direct callee windows invoked by PC equipment model loader 0xD385C..0xD3EE8 (PC FTABLE lookup)',
            match_count = #callee_matches,
            matches     = callee_matches,
        }
    end

    -- 2k. CXiSkeletonActor references to dual-wield stance/animation/visibility offsets 0x87C, 0x888, 0x8B4.
    do
        local matches = {}
        local lo = math.max(1, (0xC0000 - text_rva) + 1)
        local hi = math.min(text_len - 4, (0xE0000 - text_rva))
        for i = lo, hi do
            if #matches >= M.MAX_MATCHES_PER_RULE then break end
            local b0, b1, b2, b3 = text_bytes[i], text_bytes[i + 1], text_bytes[i + 2], text_bytes[i + 3]
            if b2 == 0x00 and b3 == 0x00 and b1 == 0x08 and (b0 == 0x7C or b0 == 0x88 or b0 == 0xB4) then
                matches[#matches + 1] = capture_window(text_rva + (i - 1))
            end
        end
        findings[#findings + 1] = {
            id          = 'actor_dw_stance_vis_87c_888_8b4_refs',
            description = 'CXiSkeletonActor .text references to 0x87C (stance), 0x888 (DW anim), 0x8B4 (weapon vis)',
            match_count = #matches,
            matches     = matches,
        }
    end

    -- 2l. Full AttachResourceToModelPart (0xCFA50) and CXiModelPart (0x29D30..0x2A900) slices.
    do
        local attach_matches = {}
        local targets = {
            { rva = 0xCFA50, len = 0x300 },
            { rva = 0x29D30, len = 0xC00 },
        }
        for _, t in ipairs(targets) do
            local idx = (t.rva - text_rva) + 1
            if idx >= 1 and idx + 16 <= text_len then
                local cap_len = math.min(t.len, text_len - idx + 1)
                local slice = {}
                for k = 0, cap_len - 1 do slice[k + 1] = text_bytes[idx + k] end
                attach_matches[#attach_matches + 1] = {
                    rva              = string.format('0x%X', t.rva),
                    va_normalized    = string.format('0x%08X', M.NORMALIZED_IMAGE_BASE + t.rva),
                    window_start_rva = string.format('0x%X', t.rva),
                    window_len       = cap_len,
                    code_hex         = bytes_to_hex(slice),
                }
            end
        end
        findings[#findings + 1] = {
            id          = 'attach_equip_model_downstream_slices',
            description = 'Full AttachEquipModel (0xD0B50..0xD0D50), CXiModelPart (0x2B5C0), and part attach (0x85030) slices',
            match_count = #attach_matches,
            matches     = attach_matches,
        }
    end

    -- 3. Strictly non-PII numeric actor model summary (optional)
    local safe_actor = nil
    if type(actor_summary) == 'table' then
        safe_actor = {
            race_id        = tonumber(actor_summary.race_id) or 0,
            look_face      = tonumber(actor_summary.look_face) or 0,
            look_head      = tonumber(actor_summary.look_head) or 0,
            look_body      = tonumber(actor_summary.look_body) or 0,
            look_hands     = tonumber(actor_summary.look_hands) or 0,
            look_legs      = tonumber(actor_summary.look_legs) or 0,
            look_feet      = tonumber(actor_summary.look_feet) or 0,
            look_main      = tonumber(actor_summary.look_main) or 0,
            look_sub       = tonumber(actor_summary.look_sub) or 0,
            look_ranged    = tonumber(actor_summary.look_ranged) or 0,
            status_id      = tonumber(actor_summary.status_id) or 0,
            main_item_id   = tonumber(actor_summary.main_item_id) or 0,
            main_skill     = tonumber(actor_summary.main_skill) or 0,
            sub_item_id    = tonumber(actor_summary.sub_item_id) or 0,
            sub_skill      = tonumber(actor_summary.sub_skill) or 0,
            active_job     = tonumber(actor_summary.active_job) or 0,
            active_branch  = tonumber(actor_summary.active_branch) or 0,
            soul_known     = actor_summary.soul_known == true,
            effective_level = tonumber(actor_summary.effective_level) or 0,
            has_render_ptr = actor_summary.has_render_ptr == true,
        }
    end

    return {
        schema_version        = M.SCHEMA_VERSION,
        provenance            = extra_opts.provenance,
        scope                 = 'narrow_text_code_windows_and_non_pii_actor_comparative_diff',
        normalized_image_base = string.format('0x%08X', M.NORMALIZED_IMAGE_BASE),
        pe                    = pe_info,
        anchor_matched        = anchor_matched,
        anchor_total          = #anchors,
        anchors               = anchors,
        actor_model_summary   = safe_actor,
        vtable_slot_rvas      = extra_opts.vtable_slot_rvas or {},
        comparative_snapshots = extra_opts.comparative_snapshots or {},
        comparative_diff      = extra_opts.comparative_diff or {},
        findings              = findings,
    }, nil
end

function M.serialize_report_json(report)
    local lines = {}
    lines[#lines + 1] = '{'
    lines[#lines + 1] = ('  "schemaVersion": %d,'):format(report.schema_version)
    local prov = report.provenance or {}
    lines[#lines + 1] = '  "provenance": {'
    lines[#lines + 1] = ('    "captureId": "%s",'):format(json_escape(prov.capture_id or ''))
    lines[#lines + 1] = ('    "generatedAtUtc": "%s",'):format(json_escape(prov.generated_at_utc or ''))
    lines[#lines + 1] = ('    "probeVersion": "%s",'):format(json_escape(prov.probe_version or M.PROBE_VERSION))
    lines[#lines + 1] = ('    "probeSourceCommit": "%s",'):format(json_escape(prov.probe_source_commit or M.PROBE_SOURCE_COMMIT))
    lines[#lines + 1] = ('    "loadedLuaPath": "%s",'):format(json_escape(prov.loaded_lua_path or M.LOADED_LUA_PATH))
    lines[#lines + 1] = ('    "activeLauncherManifestVersion": "%s",'):format(json_escape(prov.active_launcher_manifest_version or 'unavailable'))
    lines[#lines + 1] = ('    "activeLauncherChannel": "%s",'):format(json_escape(prov.active_launcher_channel or 'unavailable'))
    lines[#lines + 1] = ('    "nativeDllVersion": "%s",'):format(json_escape(prov.native_dll_version or 'unavailable'))
    local labels_out = {}
    for _, lbl in ipairs(prov.capture_labels or {}) do
        labels_out[#labels_out + 1] = '"' .. json_escape(lbl) .. '"'
    end
    lines[#lines + 1] = ('    "captureLabels": [%s],'):format(table.concat(labels_out, ', '))
    local req_sec = prov.required_diagnostic_sections or {}
    local sec_out = {}
    for _, sec in ipairs(req_sec) do
        sec_out[#sec_out + 1] = ('{"id": "%s", "present": %s, "count": %d}'):format(
            json_escape(sec.id or ''), sec.present and 'true' or 'false', tonumber(sec.count) or 0)
    end
    lines[#lines + 1] = ('    "requiredDiagnosticSections": [%s],'):format(table.concat(sec_out, ', '))
    lines[#lines + 1] = ('    "outputPath": "%s"'):format(json_escape(prov.output_path or ''))
    lines[#lines + 1] = '  },'
    lines[#lines + 1] = ('  "scope": "%s",'):format(json_escape(report.scope))
    lines[#lines + 1] = ('  "normalizedImageBase": "%s",'):format(json_escape(report.normalized_image_base))
    local pe = report.pe or {}
    lines[#lines + 1] = '  "pe": {'
    lines[#lines + 1] = ('    "machine": "0x%04X",'):format(pe.machine or 0)
    lines[#lines + 1] = ('    "timeDateStamp": "0x%08X",'):format(pe.time_date_stamp or 0)
    lines[#lines + 1] = ('    "sizeOfImage": "0x%08X",'):format(pe.size_of_image or 0)
    lines[#lines + 1] = ('    "textRva": "0x%X",'):format(pe.text_rva or 0)
    lines[#lines + 1] = ('    "textVirtualSize": "0x%X",'):format(pe.text_virtual_size or 0)
    lines[#lines + 1] = ('    "fingerprintMatch": %s'):format(pe.fingerprint_match and 'true' or 'false')
    lines[#lines + 1] = '  },'
    lines[#lines + 1] = ('  "anchorMatched": %d,'):format(report.anchor_matched or 0)
    lines[#lines + 1] = ('  "anchorTotal": %d,'):format(report.anchor_total or 0)

    lines[#lines + 1] = '  "anchors": ['
    for idx, a in ipairs(report.anchors or {}) do
        local comma = (idx < #(report.anchors or {})) and ',' or ''
        lines[#lines + 1] = ('    { "name": "%s", "rva": "%s", "matched": %s }%s'):format(
            json_escape(a.name), json_escape(a.rva), a.matched and 'true' or 'false', comma)
    end
    lines[#lines + 1] = '  ],'

    if report.actor_model_summary then
        local ac = report.actor_model_summary
        lines[#lines + 1] = '  "actorModelSummary": {'
        lines[#lines + 1] = ('    "raceId": %d,'):format(ac.race_id)
        lines[#lines + 1] = ('    "lookFace": %d,'):format(ac.look_face or 0)
        lines[#lines + 1] = ('    "lookHead": %d,'):format(ac.look_head or 0)
        lines[#lines + 1] = ('    "lookBody": %d,'):format(ac.look_body or 0)
        lines[#lines + 1] = ('    "lookHands": %d,'):format(ac.look_hands or 0)
        lines[#lines + 1] = ('    "lookLegs": %d,'):format(ac.look_legs or 0)
        lines[#lines + 1] = ('    "lookFeet": %d,'):format(ac.look_feet or 0)
        lines[#lines + 1] = ('    "lookMain": %d,'):format(ac.look_main)
        lines[#lines + 1] = ('    "lookSub": %d,'):format(ac.look_sub)
        lines[#lines + 1] = ('    "lookRanged": %d,'):format(ac.look_ranged or 0)
        lines[#lines + 1] = ('    "statusId": %d,'):format(ac.status_id)
        lines[#lines + 1] = ('    "mainItemId": %d,'):format(ac.main_item_id or 0)
        lines[#lines + 1] = ('    "mainSkill": %d,'):format(ac.main_skill or 0)
        lines[#lines + 1] = ('    "subItemId": %d,'):format(ac.sub_item_id or 0)
        lines[#lines + 1] = ('    "subSkill": %d,'):format(ac.sub_skill or 0)
        lines[#lines + 1] = ('    "activeJob": %d,'):format(ac.active_job or 0)
        lines[#lines + 1] = ('    "activeBranch": %d,'):format(ac.active_branch or 0)
        lines[#lines + 1] = ('    "soulKnown": %s,'):format(ac.soul_known and 'true' or 'false')
        lines[#lines + 1] = ('    "effectiveLevel": %d,'):format(ac.effective_level or 0)
        lines[#lines + 1] = ('    "hasRenderPtr": %s'):format(ac.has_render_ptr and 'true' or 'false')
        lines[#lines + 1] = '  },'
    else
        lines[#lines + 1] = '  "actorModelSummary": null,'
    end

    -- Compact normalized vtable slot map (slots 0..95, code RVAs only)
    local vslots = report.vtable_slot_rvas or {}
    lines[#lines + 1] = '  "vtableSlotRvas": ['
    for vi, vs in ipairs(vslots) do
        local vcomma = (vi < #vslots) and ',' or ''
        lines[#lines + 1] = ('    { "slot": %d, "offset": "0x%X", "rva": "%s" }%s'):format(
            vs.slot, vs.slot * 4, json_escape(vs.rva), vcomma)
    end
    lines[#lines + 1] = '  ],'

    -- Comparative labeled snapshots (zero PII, zero raw heap/ASLR pointers)
    local snaps = report.comparative_snapshots or {}
    lines[#lines + 1] = '  "comparativeSnapshots": ['
    for si, sn in ipairs(snaps) do
        lines[#lines + 1] = '    {'
        lines[#lines + 1] = ('      "label": "%s",'):format(json_escape(sn.label))
        local a = sn.actor or {}
        lines[#lines + 1] = ('      "raceId": %d, "statusId": %d, "lookMain": %d, "lookSub": %d, "lookRanged": %d,'):format(
            a.race_id or 0, a.status_id or 0, a.look_main or 0, a.look_sub or 0, a.look_ranged or 0)
        lines[#lines + 1] = ('      "mainItemId": %d, "mainSkill": %d, "subItemId": %d, "subSkill": %d,'):format(
            a.main_item_id or 0, a.main_skill or 0, a.sub_item_id or 0, a.sub_skill or 0)
        lines[#lines + 1] = ('      "activeJob": %d, "activeBranch": %d, "soulKnown": %s, "effectiveLevel": %d,'):format(
            a.active_job or 0, a.active_branch or 0, a.soul_known and 'true' or 'false', a.effective_level or 0)
        local slots = sn.sub_model_slots or {}
        lines[#lines + 1] = '      "subModelSlots": ['
        for k, sm in ipairs(slots) do
            local scomma = (k < #slots) and ',' or ''
            local words_str = table.concat(sm.inner_u16 or {}, ',')
            lines[#lines + 1] = ('        { "offset": "%s", "present": %s, "innerPresent": %s, "innerVtableRva": "%s", "innerU16": [%s] }%s'):format(
                json_escape(sm.offset), sm.present and 'true' or 'false',
                sm.inner_present and 'true' or 'false', json_escape(sm.inner_vtable_rva or ''),
                words_str, scomma)
        end
        lines[#lines + 1] = '      ]'
        local sncomma = (si < #snaps) and ',' or ''
        lines[#lines + 1] = '    }' .. sncomma
    end
    lines[#lines + 1] = '  ],'

    -- Automatic side-by-side diff of CXiSkeletonActor offsets (0x500..0xA00) across snapshots
    local diffs = report.comparative_diff or {}
    lines[#lines + 1] = '  "comparativeDiff": ['
    for di, df in ipairs(diffs) do
        local pairs_out = {}
        for _, pair in ipairs(df.values or {}) do
            pairs_out[#pairs_out + 1] = ('"%s": "%s"'):format(json_escape(pair.label), json_escape(pair.value))
        end
        local dcomma = (di < #diffs) and ',' or ''
        lines[#lines + 1] = ('    { "offset": "%s", "values": { %s } }%s'):format(
            json_escape(df.offset), table.concat(pairs_out, ', '), dcomma)
    end
    lines[#lines + 1] = '  ],'

    lines[#lines + 1] = '  "findings": ['
    local findings = report.findings or {}
    for fi, f in ipairs(findings) do
        lines[#lines + 1] = '    {'
        lines[#lines + 1] = ('      "id": "%s",'):format(json_escape(f.id))
        lines[#lines + 1] = ('      "description": "%s",'):format(json_escape(f.description))
        lines[#lines + 1] = ('      "matchCount": %d,'):format(f.match_count or 0)
        lines[#lines + 1] = '      "matches": ['
        local ms = f.matches or {}
        for mi, m in ipairs(ms) do
            local mcomma = (mi < #ms) and ',' or ''
            lines[#lines + 1] = ('        { "rva": "%s", "vaNormalized": "%s", "windowStartRva": "%s", "windowLen": %d, "codeHex": "%s" }%s'):format(
                json_escape(m.rva), json_escape(m.va_normalized), json_escape(m.window_start_rva),
                m.window_len or 0, json_escape(m.code_hex), mcomma)
        end
        lines[#lines + 1] = '      ]'
        local fcomma = (fi < #findings) and ',' or ''
        lines[#lines + 1] = '    }' .. fcomma
    end
    lines[#lines + 1] = '  ]'
    lines[#lines + 1] = '}'
    lines[#lines + 1] = ''
    return table.concat(lines, '\n')
end

-- Sanitize a bounded numeric slice of CXiSkeletonActor (offsets 0x500..0xA00)
-- with STRICT zero-PII and zero-raw-pointer guarantees.
function M.sanitize_actor_struct(actor_ptr, mem, module_base, image_size)
    if not actor_ptr or actor_ptr == 0 or not mem or type(mem.read_uint32) ~= 'function' then
        return {}, {}
    end
    local mod_lo = module_base or 0
    local mod_hi = mod_lo + (image_size or 0)
    local words = {}
    for off = 0x500, 0x9FC, 4 do
        local ok_r, val = pcall(mem.read_uint32, actor_ptr + off)
        if ok_r and type(val) == 'number' then
            if val == 0 then
                words[off] = '0'
            elseif val >= mod_lo and val < mod_hi then
                words[off] = string.format('rva:0x%X', val - mod_lo)
            elseif val <= 0xFFFF then
                words[off] = string.format('u16:0x%04X', val)
            elseif (val >= 0x38000000 and val <= 0x48000000) or (val >= 0xB8000000 and val <= 0xC8000000) then
                words[off] = string.format('f32:0x%08X', val)
            elseif val >= 0x01000000 and val < 0x7FFF0000 then
                local tag = 'ptr:nonnull'
                local ok_vt, vt = pcall(mem.read_uint32, val)
                if ok_vt and type(vt) == 'number' and vt >= mod_lo and vt < mod_hi then
                    tag = string.format('obj:vt=0x%X', vt - mod_lo)
                end
                words[off] = tag
            else
                words[off] = string.format('u32:0x%08X', val)
            end
        end
    end

    -- Inspect known sub-model handle slots (0x764, 0x814 from CXiSkeletonActor::0xD6370)
    local sub_slots = {}
    for _, slot_off in ipairs({ 0x764, 0x814 }) do
        local rec = {
            offset = string.format('0x%X', slot_off),
            present = false,
            inner_present = false,
            inner_vtable_rva = '',
            inner_u16 = {},
        }
        local ok_p, ptr = pcall(mem.read_uint32, actor_ptr + slot_off)
        if ok_p and type(ptr) == 'number' and ptr >= 0x01000000 and ptr < 0x7FFF0000 then
            rec.present = true
            local ok_in, inner = pcall(mem.read_uint32, ptr)
            if ok_in and type(inner) == 'number' and inner >= 0x01000000 and inner < 0x7FFF0000 then
                rec.inner_present = true
                local ok_vt, ivt = pcall(mem.read_uint32, inner)
                if ok_vt and type(ivt) == 'number' and ivt >= mod_lo and ivt < mod_hi then
                    rec.inner_vtable_rva = string.format('0x%X', ivt - mod_lo)
                end
                if type(mem.read_array) == 'function' then
                    local ok_arr, raw = pcall(mem.read_array, inner, 64)
                    if ok_arr and type(raw) == 'table' and #raw >= 32 then
                        for w = 0, 15 do
                            local u16 = (raw[w * 2 + 1] or 0) + (raw[w * 2 + 2] or 0) * 256
                            rec.inner_u16[#rec.inner_u16 + 1] = u16
                        end
                    end
                end
            end
        end
        sub_slots[#sub_slots + 1] = rec
    end

    -- Inspect CXiModelBase::firstPart (actor + 0x674 + 0x44 = actor + 0x6B8 -> CXiModelPart*)
    do
        local rec = {
            offset = '0x6B8_modelPart0',
            present = false,
            inner_present = false,
            inner_vtable_rva = '',
            inner_u16 = {},
        }
        local ok_p, part_ptr = pcall(mem.read_uint32, actor_ptr + 0x6B8)
        if ok_p and type(part_ptr) == 'number' and part_ptr >= 0x01000000 and part_ptr < 0x7FFF0000 then
            rec.present = true
            rec.inner_present = true
            local ok_vt, vt = pcall(mem.read_uint32, part_ptr)
            if ok_vt and type(vt) == 'number' and vt >= mod_lo and vt < mod_hi then
                rec.inner_vtable_rva = string.format('0x%X', vt - mod_lo)
            end
            if type(mem.read_array) == 'function' then
                local ok_arr, raw = pcall(mem.read_array, part_ptr, 0xC8)
                if ok_arr and type(raw) == 'table' and #raw >= 64 then
                    for w = 0, 31 do
                        local u16 = (raw[w * 2 + 1] or 0) + (raw[w * 2 + 2] or 0) * 256
                        rec.inner_u16[#rec.inner_u16 + 1] = u16
                    end
                end
            end
        end
        sub_slots[#sub_slots + 1] = rec
    end
    return words, sub_slots
end

-- Compute side-by-side diff of all sanitized CXiSkeletonActor offsets that differ across snapshots.
function M.compute_comparative_diff(snapshots)
    if type(snapshots) ~= 'table' or #snapshots < 2 then
        return {}
    end
    local diffs = {}
    for off = 0x500, 0x9FC, 4 do
        local first = nil
        local differs = false
        local vals = {}
        for _, sn in ipairs(snapshots) do
            local v = (sn.words and sn.words[off]) or '0'
            if first == nil then
                first = v
            elseif v ~= first then
                differs = true
            end
            vals[#vals + 1] = { label = sn.label, value = v }
        end
        if differs then
            diffs[#diffs + 1] = {
                offset = string.format('0x%X', off),
                values = vals,
            }
        end
    end
    return diffs
end

-- Run the live read-only probe inside Ashita v4.
-- Strictly gated on `diagnostics_enabled == true`.
function M.run_live_probe(opts)
    opts = opts or {}
    if opts.diagnostics_enabled ~= true then
        return false, 'developer diagnostics disabled (run /soulspire weapondiag on first)'
    end
    local mem = opts.memory or (ashita and ashita.memory)
    if not mem or type(mem.read_array) ~= 'function' then
        return false, 'ashita.memory API unavailable'
    end

    local base = opts.module_base
    if not base then
        if type(mem.get_base) == 'function' then
            local ok, b = pcall(mem.get_base, 'FFXiMain.dll')
            if ok and type(b) == 'number' and b > 0 then base = b end
        end
        if not base then
            local ok_ffi, ffi = pcall(require, 'ffi')
            if ok_ffi and ffi then
                pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char* lpModuleName);')
                local h = ffi.C.GetModuleHandleA('FFXiMain.dll')
                if h ~= nil then
                    base = tonumber(ffi.cast('uintptr_t', h))
                end
            end
        end
    end
    if not base or base == 0 then
        return false, 'FFXiMain.dll module base not found'
    end

    local hdr = mem.read_array(base, 4096)
    local pe_info, perr = M.parse_pe_header(hdr)
    if not pe_info then
        return false, 'PE header parse failed: ' .. tostring(perr)
    end
    if not pe_info.text_rva or not pe_info.text_virtual_size or pe_info.text_virtual_size <= 0 then
        return false, '.text section not found in loaded FFXiMain.dll'
    end
    -- Safety cap: never read outside .text or beyond 4 MiB.
    local read_len = math.min(pe_info.text_virtual_size, 0x400000)
    local text_bytes = mem.read_array(base + pe_info.text_rva, read_len)
    if not text_bytes or #text_bytes == 0 then
        return false, 'failed to read loaded .text section'
    end

    local rdata_bytes = nil
    if pe_info.rdata_rva and pe_info.rdata_virtual_size and pe_info.rdata_virtual_size > 0 then
        local rlen = math.min(pe_info.rdata_virtual_size, 0x200000)
        local ok_rd, rb = pcall(mem.read_array, base + pe_info.rdata_rva, rlen)
        if ok_rd and type(rb) == 'table' and #rb > 0 then
            rdata_bytes = rb
        end
    end

    local vtable_method_rvas = {}
    local vtable_slot_rvas = {}
    local actor_words = {}
    local sub_model_slots = {}
    local actor_summary = opts.actor_summary
    if not actor_summary and AshitaCore and AshitaCore.GetMemoryManager then
        local ok_ent, summary = pcall(function()
            local mm = AshitaCore:GetMemoryManager()
            local party = mm:GetParty()
            local ent = mm:GetEntity()
            local inv = mm:GetInventory()
            local res = AshitaCore:GetResourceManager()
            local idx = party and party:GetMemberTargetIndex(0) or 0
            if not ent or not idx or idx == 0 then return nil end
            local function safe_get(fn_name)
                if type(ent[fn_name]) ~= 'function' then return nil end
                local ok_v, v = pcall(ent[fn_name], ent, idx)
                return ok_v and tonumber(v) or nil
            end
            local actor_ptr = safe_get('GetActorPointer') or safe_get('GetRenderPointer') or 0
            if actor_ptr ~= 0 and type(mem.read_uint32) == 'function' then
                local ok_vt, vtbl = pcall(mem.read_uint32, actor_ptr)
                if ok_vt and type(vtbl) == 'number' and vtbl > base and vtbl < (base + pe_info.size_of_image) then
                    local seen = {}
                    for slot = 0, 95 do
                        local ok_fn, fn_va = pcall(mem.read_uint32, vtbl + slot * 4)
                        if ok_fn and type(fn_va) == 'number' and fn_va > base and fn_va < (base + pe_info.size_of_image) then
                            local rva = fn_va - base
                            vtable_slot_rvas[#vtable_slot_rvas + 1] = {
                                slot = slot,
                                rva = string.format('0x%X', rva),
                            }
                            if not seen[rva] and #vtable_method_rvas < 24 then
                                seen[rva] = true
                                vtable_method_rvas[#vtable_method_rvas + 1] = rva
                            end
                        end
                    end
                end
                actor_words, sub_model_slots = M.sanitize_actor_struct(actor_ptr, mem, base, pe_info.size_of_image)
            end

            -- Strictly numeric equipped Main (slot 0) and Sub (slot 1) item ID & skill
            local function read_equip_item(slot_idx)
                if not inv or not res then return 0, 0 end
                local ok_eq, eq = pcall(inv.GetEquippedItem, inv, slot_idx)
                if not ok_eq or not eq or not eq.Index or eq.Index == 0 then return 0, 0 end
                local cont = math.floor(eq.Index / 256)
                local iidx = eq.Index % 256
                if iidx == 0 then return 0, 0 end
                local ok_ci, ci = pcall(inv.GetContainerItem, inv, cont, iidx)
                if not ok_ci or not ci or not ci.Id or ci.Id == 0 then return 0, 0 end
                local ok_ri, ri = pcall(res.GetItemById, res, ci.Id)
                local sk = (ok_ri and ri and tonumber(ri.Skill)) or 0
                return tonumber(ci.Id) or 0, sk
            end
            local main_id, main_sk = read_equip_item(0)
            local sub_id, sub_sk = read_equip_item(1)

            local active_job, active_branch, soul_known, eff_lvl = 0, 0, false, 0
            local ok_nb, NativeBridge = pcall(require, 'core.native_bridge')
            if ok_nb and NativeBridge and type(NativeBridge.query_equipment_runtime) == 'function' then
                local ok_rt, rt = pcall(NativeBridge.query_equipment_runtime)
                if ok_rt and type(rt) == 'table' then
                    active_job = tonumber(rt.activeJob) or 0
                    active_branch = tonumber(rt.activeBranch) or 0
                    soul_known = rt.soulKnown == true
                    eff_lvl = tonumber(rt.effectiveLevel) or 0
                end
            end

            return {
                race_id        = safe_get('GetRace') or 0,
                look_face      = safe_get('GetLookFace') or 0,
                look_head      = safe_get('GetLookHead') or 0,
                look_body      = safe_get('GetLookBody') or 0,
                look_hands     = safe_get('GetLookHands') or 0,
                look_legs      = safe_get('GetLookLegs') or 0,
                look_feet      = safe_get('GetLookFeet') or 0,
                look_main      = safe_get('GetLookMain') or safe_get('GetLookWeaponMain') or 0,
                look_sub       = safe_get('GetLookSub') or safe_get('GetLookWeaponSub') or 0,
                look_ranged    = safe_get('GetLookRanged') or 0,
                status_id      = safe_get('GetStatus') or 0,
                main_item_id   = main_id,
                main_skill     = main_sk,
                sub_item_id    = sub_id,
                sub_skill      = sub_sk,
                active_job     = active_job,
                active_branch  = active_branch,
                soul_known     = soul_known,
                effective_level = eff_lvl,
                has_render_ptr = actor_ptr ~= 0,
            }
        end)
        if ok_ent then actor_summary = summary end
    end

    -- Record comparative snapshot (replace existing entry if same label is re-captured)
    if type(opts.actor_words_override) == 'table' then
        actor_words = opts.actor_words_override
    end
    local snap_label = (type(opts.label) == 'string' and opts.label ~= '')
        and opts.label or ('snap_' .. tostring(#comparative_snapshots + 1))
    local snap_entry = {
        label = snap_label,
        actor = actor_summary or {},
        words = actor_words,
        sub_model_slots = sub_model_slots,
    }
    local replaced = false
    for i, existing in ipairs(comparative_snapshots) do
        if existing.label == snap_label then
            comparative_snapshots[i] = snap_entry
            replaced = true
            break
        end
    end
    if not replaced then
        if #comparative_snapshots >= M.MAX_SNAPSHOTS then
            table.remove(comparative_snapshots, 1)
        end
        comparative_snapshots[#comparative_snapshots + 1] = snap_entry
    end
    local comp_diff = M.compute_comparative_diff(comparative_snapshots)

    -- Compute unique capture ID, UTC timestamps, and uniquely named output path.
    capture_seq = capture_seq + 1
    local utc_iso = (type(opts.utc_iso_override) == 'string' and opts.utc_iso_override ~= '')
        and opts.utc_iso_override or os.date('!%Y-%m-%dT%H:%M:%SZ')
    local utc_file_stamp = (type(opts.utc_file_stamp_override) == 'string' and opts.utc_file_stamp_override ~= '')
        and opts.utc_file_stamp_override or os.date('!%Y%m%d-%H%M%S')
    if utc_file_stamp == last_utc_stamp then
        same_second_seq = same_second_seq + 1
    else
        last_utc_stamp = utc_file_stamp
        same_second_seq = 1
    end
    local capture_id = string.format('wpr-%s-%s-%03d', M.PROBE_VERSION, utc_file_stamp, capture_seq)

    local final_output_path = ''
    if type(opts.output_dir) == 'string' and opts.output_dir ~= '' then
        final_output_path = M.build_unique_output_path(opts.output_dir, M.PROBE_VERSION, utc_file_stamp, same_second_seq)
    elseif type(opts.output_path) == 'string' and opts.output_path ~= '' then
        final_output_path = opts.output_path
    end

    local launcher_state = (type(opts.launcher_state_override) == 'table')
        and opts.launcher_state_override
        or M.read_launcher_state(opts.ashita_root_dir)
    local native_dll_ver = (type(opts.native_dll_version_override) == 'string' and opts.native_dll_version_override ~= '')
        and opts.native_dll_version_override
        or M.query_native_dll_version()

    local capture_labels = {}
    for _, sn in ipairs(comparative_snapshots) do
        capture_labels[#capture_labels + 1] = sn.label
    end

    local report, serr = M.scan_text_buffer(text_bytes, pe_info.text_rva, pe_info, actor_summary, {
        rdata_bytes           = rdata_bytes,
        rdata_rva             = pe_info.rdata_rva,
        module_base           = base,
        vtable_method_rvas    = vtable_method_rvas,
        vtable_slot_rvas      = vtable_slot_rvas,
        comparative_snapshots = comparative_snapshots,
        comparative_diff      = comp_diff,
    })
    if not report then
        return false, serr
    end

    local findings_by_id = {}
    for _, f in ipairs(report.findings or {}) do
        findings_by_id[f.id] = f
    end
    local has_model_part0 = false
    for _, sn in ipairs(comparative_snapshots) do
        for _, sm in ipairs(sn.sub_model_slots or {}) do
            if sm.offset == '0x6B8_modelPart0' then
                has_model_part0 = true
                break
            end
        end
    end
    local required_sections = {
        {
            id      = 'attach_equip_model_downstream_slices',
            present = findings_by_id.attach_equip_model_downstream_slices ~= nil,
            count   = (findings_by_id.attach_equip_model_downstream_slices and findings_by_id.attach_equip_model_downstream_slices.match_count) or 0,
        },
        {
            id      = 'pc_equip_model_loader_slice',
            present = findings_by_id.pc_equip_model_loader_slice ~= nil,
            count   = (findings_by_id.pc_equip_model_loader_slice and findings_by_id.pc_equip_model_loader_slice.match_count) or 0,
        },
        {
            id      = 'actor_vtable_methods',
            present = findings_by_id.actor_vtable_methods ~= nil,
            count   = (findings_by_id.actor_vtable_methods and findings_by_id.actor_vtable_methods.match_count) or 0,
        },
        {
            id      = 'comparativeSnapshots',
            present = #comparative_snapshots > 0,
            count   = #comparative_snapshots,
        },
        {
            id      = 'modelPart0Inspection',
            present = has_model_part0,
            count   = has_model_part0 and 1 or 0,
        },
    }

    report.provenance = {
        capture_id                       = capture_id,
        generated_at_utc                 = utc_iso,
        probe_version                    = M.PROBE_VERSION,
        probe_source_commit              = M.PROBE_SOURCE_COMMIT,
        loaded_lua_path                  = M.LOADED_LUA_PATH,
        active_launcher_manifest_version = launcher_state.manifest_version or 'unavailable',
        active_launcher_channel          = launcher_state.channel or 'unavailable',
        native_dll_version               = native_dll_ver,
        capture_labels                   = capture_labels,
        required_diagnostic_sections     = required_sections,
        output_path                      = final_output_path,
    }

    local json_text = M.serialize_report_json(report)
    if final_output_path ~= '' then
        local f, ferr = io.open(final_output_path, 'wb')
        if not f then
            return false, 'failed to write probe report: ' .. tostring(ferr)
        end
        local wok, werr = f:write(json_text)
        f:flush()
        f:close()
        if not wok then
            return false, 'failed to write probe report bytes: ' .. tostring(werr)
        end
    end
    return true, report, final_output_path
end

return M
