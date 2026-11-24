-- SoulspireXI Core — Opt-In Runtime Weapon Equipment Diagnostic (WS3-WEAP-002).
--
-- Strictly disabled by default; requires `/soulspire weapondiag on` before
-- `/soulspire weapondiag equip` will execute.
--
-- Generic & registry-driven:
--   * Zero hardcoded Soul IDs or Berserker exceptions.
--   * Reads authoritative `soul-weapon-config.json` rules & queries live
--     `soulspire_native.dll` exports (ABI v2, GetStatus, GetWeaponStatus,
--     GetHookDiagnostics, GetIdentityDiagnostics).
--   * Evaluates equipped Main weapon and accessible Inventory/Wardrobe Sub
--     candidates through every native filtering stage (DLL/Hooks -> Soul Sync
--     -> Weapon Config Rule -> Min Level -> Hook #26 Sub Menu -> Hook #27 2H
--     Main+Sub -> Hook #22/#25 Equip Gate) and reports exact rejection reasons.
--   * Writes a private local diagnostic report (never committed; zero PII).

local bit = require('bit')
local ok_ffi, ffi = pcall(require, 'ffi')
local NativeBridge = require('core.native_bridge')

local D = {}

local packet_trace = {}
local MAX_PACKET_TRACE = 32

function D.clear_packet_trace()
    packet_trace = {}
end

function D.observe_equip_packet(direction, data, ts)
    if type(data) ~= 'string' or #data < 8 then return nil end
    local rec = {
        dir = tostring(direction),
        invIndex = data:byte(5) or 0,
        equipSlot = data:byte(6) or 0,
        container = data:byte(7) or 0,
        ts = tonumber(ts) or 0,
    }
    packet_trace[#packet_trace + 1] = rec
    if #packet_trace > MAX_PACKET_TRACE then
        table.remove(packet_trace, 1)
    end
    return rec
end

function D.get_packet_trace()
    local copy = {}
    for i = 1, #packet_trace do
        copy[i] = packet_trace[i]
    end
    return copy
end

-- Narrowly scoped, read-only .text slice capture for EquipMenu::TryEquipItem (0x133BD0..0x133ED0)
-- and CanEquipItemInSlot (0x133580..0x133680) to verify exact register/branch layout on retail FFXiMain.dll.
-- Never dumps heap, stack, credentials, or unrelated memory.
function D.capture_try_equip_slices()
    if not (ok_ffi and ffi) then return {} end
    local ok, slices = pcall(function()
        local h = ffi.C.GetModuleHandleA('FFXiMain.dll')
        if h == nil then return {} end
        local base = tonumber(ffi.cast('uintptr_t', h))
        if not base or base == 0 then return {} end
        local specs = {
            { name = 'TryEquipItem', rva = 0x133BD0, size = 0x300 },
            { name = 'CanEquipItemInSlot', rva = 0x133580, size = 0x100 },
        }
        local out = {}
        for _, sp in ipairs(specs) do
            local ptr = ffi.cast('const uint8_t*', base + sp.rva)
            local hex = {}
            for i = 0, sp.size - 1 do
                hex[#hex + 1] = ('%02x'):format(tonumber(ptr[i]))
            end
            out[#out + 1] = {
                name = sp.name,
                rva = ('0x%X'):format(sp.rva),
                size = sp.size,
                bytesHex = table.concat(hex),
            }
        end
        return out
    end)
    return (ok and type(slices) == 'table') and slices or {}
end

D.MODE_NAMES = {
    [0] = 'vanilla',
    [1] = 'dual_1h',
    [2] = 'dual_2h',
    [3] = 'twohand_shield',
}

D.SKILL_NAMES = {
    [1] = 'hand_to_hand',
    [2] = 'dagger',
    [3] = 'sword',
    [4] = 'great_sword',
    [5] = 'axe',
    [6] = 'great_axe',
    [7] = 'scythe',
    [8] = 'polearm',
    [9] = 'katana',
    [10] = 'great_katana',
    [11] = 'club',
    [12] = 'staff',
}

-- Bit indices in SoulspireNativeHookDiagnostics.installed_mask (0-based).
-- 31-hook layout adds 3 CALL patches (bits 22..24) before PrologueDetours, shifting detours +3.
function D.equip_hook_specs(expected_hooks)
    local is_31 = (tonumber(expected_hooks) or 31) >= 31
    return {
        { bit = 21, number = 22, rva = '0x133E33', name = 'soul_can_equip_in_slot' },
        { bit = is_31 and 27 or 24, number = 25, rva = '0x133D56', name = 'soul_sub_weapon_detour' },
        { bit = is_31 and 28 or 25, number = 26, rva = '0x21DF85', name = 'dual_2h_menu_detour' },
        { bit = is_31 and 29 or 26, number = 27, rva = '0x133DD3', name = 'dual_2h_equip_detour' },
    }
end

function D.query_native_runtime()
    return NativeBridge.query_equipment_runtime()
end

function D.inspect_equipment_hooks(installed_mask, expected_hooks)
    local mask = tonumber(installed_mask) or 0
    local out = {}
    local all_ok = true
    for _, spec in ipairs(D.equip_hook_specs(expected_hooks)) do
        local installed = bit.band(mask, bit.lshift(1, spec.bit)) ~= 0
        if not installed then all_ok = false end
        out[#out + 1] = {
            hook = spec.number,
            bit = spec.bit,
            rva = spec.rva,
            name = spec.name,
            installed = installed,
        }
    end
    if expected_hooks and tonumber(expected_hooks) < 27 then
        all_ok = false
    end
    return all_ok, out
end

-- Find all matching native weapon rules for (job, branch) from centralized config rules.
function D.resolve_rules_for_soul(rules, job, branch)
    local matched = {}
    if type(rules) ~= 'table' or not job or job <= 0 or not branch or branch <= 0 then
        return matched
    end
    for _, r in ipairs(rules) do
        if r.job == job and r.branch == branch then
            matched[#matched + 1] = r
        end
    end
    return matched
end

-- Evaluate a single candidate Sub-slot item through every native filtering stage.
function D.evaluate_candidate(ctx, item)
    local stages = {}
    local function rec(name, pass, reason)
        stages[#stages + 1] = { stage = name, pass = pass, reason = reason }
        return pass
    end

    local native = ctx.native or {}
    local slots = tonumber(item.slots) or 0
    local skill = tonumber(item.skill) or 0
    local item_id = tonumber(item.item_id) or 0
    local main_skill = tonumber(ctx.main_weapon and ctx.main_weapon.skill) or 0
    local main_slots = tonumber(ctx.main_weapon and ctx.main_weapon.slots) or 0
    local main_is_2h = (bit.band(main_slots, 1) ~= 0) and (bit.band(main_slots, 2) == 0)

    -- Stage 0: Vanilla Sub-slot bit (grips, straps, shields, 1H sub-capable weapons).
    local has_sub_bit = bit.band(slots, 2) ~= 0
    local has_main_bit = bit.band(slots, 1) ~= 0
    if has_sub_bit then
        rec('vanilla_sub_slot', true, 'item has vanilla Sub slot bit (slots & 2 != 0)')
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'ALLOW_VANILLA_SUB',
            rejection_reason = nil,
            stages = stages,
        }
    end

    -- Non-vanilla Sub candidate (e.g. 2H weapon with slots == 1).
    if not has_main_bit then
        rec('hook26_slot_gate', false, 'item lacks both Sub (bit 1) and Main (bit 0) equipment slot bits')
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'REJECT',
            rejection_reason = 'NOT_EQUIPPABLE_IN_MAIN_OR_SUB',
            stages = stages,
        }
    end

    -- Stage 1: Native DLL loaded, enabled, and all 4 Equipment hooks installed.
    local hooks_ok = native.dll_loaded == true and native.enabled == true and ctx.equip_hooks_ok == true
    if not hooks_ok then
        local why = not native.dll_loaded and 'DLL_NOT_LOADED'
            or (not native.enabled and 'NATIVE_DISABLED_OR_HOOK_ERROR')
            or 'EQUIPMENT_HOOKS_MISSING'
        rec('native_dll_and_hooks', false, why)
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'REJECT',
            rejection_reason = why,
            stages = stages,
        }
    end
    rec('native_dll_and_hooks', true, 'soulspire_native enabled with hooks #22/#25/#26/#27 active')

    -- Stage 2: Authoritative Soul identity synced to native.
    local job = tonumber(native.job) or 0
    local branch = tonumber(native.branch) or 0
    if not native.known or job < 1 or job > 22 or branch < 1 or branch > 3 then
        rec('native_soul_identity', false, ('NATIVE_SOUL_UNKNOWN(known=%s,job=%d,branch=%d)'):format(
            tostring(native.known), job, branch))
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'REJECT',
            rejection_reason = 'NATIVE_SOUL_NOT_SYNCED',
            stages = stages,
        }
    end
    rec('native_soul_identity', true, ('job=%d branch=%d known=true'):format(job, branch))

    -- Stage 3: Native weapon rule catalog populated & matching Soul rule present.
    local native_rules_count = tonumber(native.weapon_rules_count) or 0
    if native_rules_count <= 0 then
        rec('native_weapon_rules', false, 'NATIVE_WEAPON_RULE_CATALOG_EMPTY(rules_count=0)')
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'REJECT',
            rejection_reason = 'NATIVE_WEAPON_RULE_CATALOG_EMPTY',
            stages = stages,
        }
    end
    local soul_rules = ctx.soul_rules or {}
    if #soul_rules == 0 then
        rec('soul_weapon_config', false, ('NO_WEAPON_RULE_FOR_SOUL(job=%d,branch=%d)'):format(job, branch))
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'REJECT',
            rejection_reason = 'SOUL_HAS_NO_DUAL_WEAPON_RULE',
            stages = stages,
        }
    end
    rec('native_weapon_rules', true, ('native_rules=%d soul_rules=%d'):format(native_rules_count, #soul_rules))

    -- Stage 4 & 5: Hook #26 (0x21DF85) — effective level, mode == DUAL_2H, sub_skill_mask.
    local eff_lvl = tonumber(ctx.effective_level) or 0
    local sub_bit = (skill > 0 and skill < 32) and bit.lshift(1, skill) or 0
    local matched_rule = nil
    local fail_reason = 'SUB_SKILL_NOT_WHITELISTED'
    for _, r in ipairs(soul_rules) do
        if r.mode ~= 2 then
            fail_reason = 'RULE_MODE_NOT_DUAL_2H'
        elseif eff_lvl < (r.min_effective_level or 10) then
            fail_reason = ('LEVEL_BELOW_MIN(%d<%d)'):format(eff_lvl, r.min_effective_level or 10)
        elseif sub_bit == 0 or bit.band(r.sub_skill_mask or 0, sub_bit) == 0 then
            fail_reason = ('SUB_SKILL_MASK_MISMATCH(skill=%d,mask=%d)'):format(skill, r.sub_skill_mask or 0)
        elseif (r.sub_item_id or 0) ~= 0 and r.sub_item_id ~= item_id then
            fail_reason = 'SUB_ITEM_ID_MISMATCH'
        else
            matched_rule = r
            break
        end
    end
    if not matched_rule then
        rec('hook26_sub_menu_filter', false, fail_reason)
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'REJECT',
            rejection_reason = fail_reason,
            stages = stages,
        }
    end
    rec('hook26_sub_menu_filter', true, ('soul=%s mode=dual_2h lvl=%d>=%d skill=%d'):format(
        tostring(matched_rule.soul_id), eff_lvl, matched_rule.min_effective_level or 10, skill))

    -- Stage 6: Hook #27 (0x133DD3) — 2H Main weapon compatibility when Main is equipped.
    if main_is_2h then
        local main_bit = (main_skill > 0 and main_skill < 32) and bit.lshift(1, main_skill) or 0
        if main_bit == 0 or bit.band(matched_rule.main_skill_mask or 0, main_bit) == 0 then
            local why = ('MAIN_SKILL_MASK_MISMATCH(main_skill=%d,mask=%d)'):format(
                main_skill, matched_rule.main_skill_mask or 0)
            rec('hook27_2h_main_compat', false, why)
            return {
                item_id = item_id,
                name = item.name or ('item#' .. tostring(item_id)),
                skill = skill,
                skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
                slots = slots,
                decision = 'REJECT',
                rejection_reason = why,
                stages = stages,
            }
        end
        rec('hook27_2h_main_compat', true, ('main_skill=%d compatible with sub_skill=%d'):format(main_skill, skill))
    else
        rec('hook27_2h_main_compat', true, 'main weapon is not 2H (hook #27 not triggered)')
    end

    -- Stage 7: Hook #22 (0x133E33 -> CanEquipItemInSlot) & Hook #25 (0x133D56).
    if item.already_equipped_in_main == true then
        rec('equip_slot_exclusivity', false, 'SAME_INVENTORY_SLOT_ALREADY_EQUIPPED_IN_MAIN')
        return {
            item_id = item_id,
            name = item.name or ('item#' .. tostring(item_id)),
            skill = skill,
            skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
            slots = slots,
            decision = 'REJECT',
            rejection_reason = 'SAME_INVENTORY_SLOT_ALREADY_EQUIPPED_IN_MAIN',
            stages = stages,
        }
    end
    rec('hook22_hook25_equip_gate', true, 'eligible for Sub slot under authoritative DUAL_2H rule')

    return {
        item_id = item_id,
        name = item.name or ('item#' .. tostring(item_id)),
        skill = skill,
        skill_name = D.SKILL_NAMES[skill] or ('skill_' .. tostring(skill)),
        slots = slots,
        decision = 'ALLOW_DUAL_2H',
        rejection_reason = nil,
        stages = stages,
    }
end

local function json_escape(s)
    return tostring(s):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r')
end

local function encode_json(v, indent)
    indent = indent or 0
    local tv = type(v)
    if tv == 'nil' then return 'null'
    elseif tv == 'boolean' then return v and 'true' or 'false'
    elseif tv == 'number' then return tostring(v)
    elseif tv == 'string' then return '"' .. json_escape(v) .. '"'
    elseif tv == 'table' then
        local is_arr = (#v > 0)
        if not is_arr then
            for k in pairs(v) do
                if type(k) ~= 'number' then is_arr = false; break end
            end
        end
        local pad = string.rep('  ', indent)
        local pad_in = string.rep('  ', indent + 1)
        if is_arr then
            if #v == 0 then return '[]' end
            local parts = {}
            for i = 1, #v do
                parts[#parts + 1] = pad_in .. encode_json(v[i], indent + 1)
            end
            return '[\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. ']'
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            if #keys == 0 then return '{}' end
            local parts = {}
            for _, k in ipairs(keys) do
                parts[#parts + 1] = pad_in .. '"' .. json_escape(k) .. '": ' .. encode_json(v[k], indent + 1)
            end
            return '{\n' .. table.concat(parts, ',\n') .. '\n' .. pad .. '}'
        end
    end
    return 'null'
end

local function collect_live_ashita_inventory()
    local main_weapon = nil
    local candidates = {}
    local eff_level = 0
    if not AshitaCore then return eff_level, main_weapon, candidates end

    pcall(function()
        local mem = AshitaCore:GetMemoryManager()
        local res = AshitaCore:GetResourceManager()
        local player = mem and mem:GetPlayer()
        local inv = mem and mem:GetInventory()
        if player then
            eff_level = tonumber(player:GetMainJobLevel()) or 0
        end
        if not (inv and res) then return end

        local main_eq = inv:GetEquippedItem(0)
        local main_bag, main_idx = -1, -1
        if main_eq and main_eq.Index and main_eq.Index ~= 0 then
            main_bag = bit.band(main_eq.Index, 0xFF00) / 256
            main_idx = bit.band(main_eq.Index, 0x00FF)
            local mi = inv:GetContainerItem(main_bag, main_idx)
            if mi and mi.Id and mi.Id > 0 then
                local ir = res:GetItemById(mi.Id)
                if ir then
                    main_weapon = {
                        item_id = mi.Id,
                        name = ir.Name and ir.Name[1] or ('item#' .. tostring(mi.Id)),
                        skill = tonumber(ir.Skill) or 0,
                        slots = tonumber(ir.Slots) or 0,
                        bag = main_bag,
                        index = main_idx,
                    }
                end
            end
        end

        -- Accessible equippable containers: Inventory (0) + Wardrobes 1..8 (8,10,11,12,13,14,15,16).
        local bags = { 0, 8, 10, 11, 12, 13, 14, 15, 16 }
        for _, bag in ipairs(bags) do
            local max_slots = tonumber(inv:GetContainerCountMax(bag)) or 0
            for idx = 1, max_slots do
                local ci = inv:GetContainerItem(bag, idx)
                if ci and ci.Id and ci.Id > 0 then
                    local ir = res:GetItemById(ci.Id)
                    if ir then
                        local slots = tonumber(ir.Slots) or 0
                        if bit.band(slots, 3) ~= 0 then
                            candidates[#candidates + 1] = {
                                item_id = ci.Id,
                                name = ir.Name and ir.Name[1] or ('item#' .. tostring(ci.Id)),
                                skill = tonumber(ir.Skill) or 0,
                                slots = slots,
                                bag = bag,
                                index = idx,
                                already_equipped_in_main = (bag == main_bag and idx == main_idx),
                            }
                        end
                    end
                end
            end
        end
    end)

    return eff_level, main_weapon, candidates
end

function D.run_diagnostic(opts)
    opts = opts or {}
    if opts.diagnostics_enabled ~= true then
        return false, 'Developer weapon diagnostics are disabled by default. Run `/soulspire weapondiag on` first.'
    end

    local native = opts.native_override or D.query_native_runtime()
    local equip_hooks_ok, hook_details = D.inspect_equipment_hooks(native.installed_mask, native.expected_hooks)

    local rules = opts.rules_override or {}
    local soul_rules = D.resolve_rules_for_soul(rules, native.job, native.branch)

    local eff_level = opts.effective_level
    local main_weapon = opts.main_weapon
    local candidates = opts.candidates
    if eff_level == nil or candidates == nil then
        local live_lvl, live_main, live_cands = collect_live_ashita_inventory()
        if eff_level == nil then eff_level = live_lvl end
        if main_weapon == nil then main_weapon = live_main end
        if candidates == nil then candidates = live_cands end
    end

    local ctx = {
        native = native,
        equip_hooks_ok = equip_hooks_ok,
        soul_rules = soul_rules,
        effective_level = eff_level or 0,
        main_weapon = main_weapon,
    }

    local evaluations = {}
    local allowed_dual_2h = 0
    local allowed_vanilla_sub = 0
    local rejected = 0
    for _, item in ipairs(candidates or {}) do
        local ev = D.evaluate_candidate(ctx, item)
        evaluations[#evaluations + 1] = ev
        if ev.decision == 'ALLOW_DUAL_2H' then
            allowed_dual_2h = allowed_dual_2h + 1
        elseif ev.decision == 'ALLOW_VANILLA_SUB' then
            allowed_vanilla_sub = allowed_vanilla_sub + 1
        else
            rejected = rejected + 1
        end
    end

    local trace = opts.packet_trace_override or D.get_packet_trace()
    local slices = opts.slices_override or D.capture_try_equip_slices()
    local resolved_soul_id = soul_rules[1] and soul_rules[1].soul_id or nil
    local report = {
        schemaVersion = 1,
        diagnosticType = 'soulspire_weapon_equip_diag',
        native = {
            dllLoaded = native.dll_loaded == true,
            enabled = native.enabled == true,
            abiVersion = native.abi_version or 0,
            installedHooks = native.installed_hooks or native.hooks or 0,
            expectedHooks = native.expected_hooks or 0,
            equipHooksOk = equip_hooks_ok,
            equipHooks = hook_details,
            activeJob = native.job or 0,
            activeBranch = native.branch or 0,
            soulKnown = native.known == true,
            effectiveLevel = eff_level or 0,
            resolvedSoulId = resolved_soul_id,
            weaponRulesCount = native.weapon_rules_count or 0,
            weaponAllowHits = native.weapon_allow_hits or 0,
            weaponDenyHits = native.weapon_deny_hits or 0,
            lastError = native.last_error or 0,
            queryErrors = native.query_errors or {},
        },
        sync = {
            compiledRegistryHash = native.compiled_registry_hash or '',
            activeRegistryHash = native.active_registry_hash or native.registry_hash or '',
            configRegistryHash = opts.config_registry_hash or '',
            weaponConfigHash = opts.weapon_config_hash or '',
            registryHashesMatch = (native.compiled_registry_hash or '') ~= ''
                and (opts.config_registry_hash or '') ~= ''
                and native.compiled_registry_hash == opts.config_registry_hash,
        },
        mainWeapon = main_weapon,
        packetTrace0x050 = trace,
        tryEquipCodeSlices = slices,
        summary = {
            candidateCount = #evaluations,
            allowedDual2h = allowed_dual_2h,
            allowedVanillaSub = allowed_vanilla_sub,
            rejected = rejected,
            packets0x050Count = #trace,
            codeSlicesCount = #slices,
        },
        candidates = evaluations,
    }

    local written_path = nil
    local write_error = nil
    if type(opts.output_path) == 'string' and opts.output_path ~= '' then
        local f, io_err = io.open(opts.output_path, 'wb')
        if f then
            local ok_w, w_err = f:write(encode_json(report, 0), '\n')
            f:close()
            if ok_w then
                written_path = opts.output_path
            else
                write_error = 'Failed writing ' .. tostring(opts.output_path) .. ': ' .. tostring(w_err)
            end
        else
            write_error = 'Failed opening ' .. tostring(opts.output_path) .. ' for write: ' .. tostring(io_err)
        end
    end

    return true, report, written_path, write_error
end

return D
