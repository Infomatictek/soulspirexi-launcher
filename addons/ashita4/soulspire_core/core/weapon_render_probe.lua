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

M.SCHEMA_VERSION        = 1
M.EXPECTED_TIMESTAMP    = 0x6AE818B4
M.EXPECTED_IMAGE_SIZE   = 0x00C17000
M.NORMALIZED_IMAGE_BASE = 0x10000000
M.WINDOW_BEFORE         = 64
M.WINDOW_AFTER          = 192
M.MAX_MATCHES_PER_RULE  = 24

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
            break
        end
    end

    return {
        machine            = machine,
        time_date_stamp    = ts,
        size_of_image      = img_size,
        preferred_base     = img_base,
        text_rva           = text_va,
        text_virtual_size  = text_vsz,
        fingerprint_match  = (ts == M.EXPECTED_TIMESTAMP and img_size == M.EXPECTED_IMAGE_SIZE),
    }, nil
end

-- Scan a bounded `.text` byte buffer (1-based array of uint8 starting at text_rva)
-- strictly for the narrowly scoped weapon-attachment probe rules.
function M.scan_text_buffer(text_bytes, text_rva, pe_info, actor_summary)
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

    -- 3. Strictly non-PII numeric actor model summary (optional)
    local safe_actor = nil
    if type(actor_summary) == 'table' then
        safe_actor = {
            race_id        = tonumber(actor_summary.race_id) or 0,
            look_main      = tonumber(actor_summary.look_main) or 0,
            look_sub       = tonumber(actor_summary.look_sub) or 0,
            status_id      = tonumber(actor_summary.status_id) or 0,
            has_render_ptr = actor_summary.has_render_ptr == true,
        }
    end

    return {
        schema_version        = M.SCHEMA_VERSION,
        scope                 = 'narrow_text_code_windows_only_zero_pii',
        normalized_image_base = string.format('0x%08X', M.NORMALIZED_IMAGE_BASE),
        pe                    = pe_info,
        anchor_matched        = anchor_matched,
        anchor_total          = #anchors,
        anchors               = anchors,
        actor_model_summary   = safe_actor,
        findings              = findings,
    }, nil
end

function M.serialize_report_json(report)
    local lines = {}
    lines[#lines + 1] = '{'
    lines[#lines + 1] = ('  "schemaVersion": %d,'):format(report.schema_version)
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
        lines[#lines + 1] = ('    "lookMain": %d,'):format(ac.look_main)
        lines[#lines + 1] = ('    "lookSub": %d,'):format(ac.look_sub)
        lines[#lines + 1] = ('    "statusId": %d,'):format(ac.status_id)
        lines[#lines + 1] = ('    "hasRenderPtr": %s'):format(ac.has_render_ptr and 'true' or 'false')
        lines[#lines + 1] = '  },'
    else
        lines[#lines + 1] = '  "actorModelSummary": null,'
    end

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

    local actor_summary = opts.actor_summary
    if not actor_summary and AshitaCore and AshitaCore.GetMemoryManager then
        local ok_ent, summary = pcall(function()
            local mm = AshitaCore:GetMemoryManager()
            local party = mm:GetParty()
            local ent = mm:GetEntity()
            local idx = party and party:GetMemberTargetIndex(0) or 0
            if not ent or not idx or idx == 0 then return nil end
            return {
                race_id        = ent:GetRace(idx) or 0,
                look_main      = ent:GetLookMain(idx) or 0,
                look_sub       = ent:GetLookSub(idx) or 0,
                status_id      = ent:GetStatus(idx) or 0,
                has_render_ptr = (ent:GetRenderPointer(idx) or 0) ~= 0,
            }
        end)
        if ok_ent then actor_summary = summary end
    end

    local report, serr = M.scan_text_buffer(text_bytes, pe_info.text_rva, pe_info, actor_summary)
    if not report then
        return false, serr
    end

    local json_text = M.serialize_report_json(report)
    if type(opts.output_path) == 'string' and opts.output_path ~= '' then
        local f, ferr = io.open(opts.output_path, 'wb')
        if not f then
            return false, 'failed to write probe report: ' .. tostring(ferr)
        end
        f:write(json_text)
        f:close()
    end
    return true, report, opts.output_path
end

return M
