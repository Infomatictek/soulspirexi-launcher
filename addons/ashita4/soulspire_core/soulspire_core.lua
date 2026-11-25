-- SoulspireXI Core (Phase 1A): Modular UI foundation & Native-Styled Main Menu integration.
-- Preserves all existing addons and soulspire_native.dll hooks untouched.
--
-- Integration Mode:
--   Native-Styled Fallback docked to FFXI's Main Menu via read-only MenuManager
--   inspection (same verified memory layout as crystalsocket/menu.lua).
--   Consumes Soulspire Native's versioned ABI (core.native_bridge) read-only.

addon.name    = 'soulspire_core'
addon.author  = 'SoulspireXI'
addon.version = '0.1.0'
addon.desc    = 'SoulspireXI Core Phase 1A: Modular UI shell with native-styled FFXI Main Menu entry.'
addon.link    = 'https://github.com/Infomatictek/soulspirexi-launcher'

require('common')
local ffi        = require('ffi')
local imgui      = require('imgui')
local Registry   = require('core.registry')
local MenuBridge = require('core.menu_bridge')
local Focus      = require('core.focus')
local Input      = require('core.input')
local Assets       = require('core.assets')
local UI           = require('core.ui')
local NativeBridge = require('core.native_bridge')
local WeaponPres   = require('core.weapon_presentation')
local WeaponProbe  = require('core.weapon_render_probe')
local WeaponEquipDiag = require('core.weapon_equip_diag')

local registry = Registry.new()
local focus    = Focus.new(registry)
local input    = Input.new()
local weapon_pres = WeaponPres.new()
local menu, assets, ui
local last_synced_equip = { main_id = -1, main_sk = -1, sub_id = -1, sub_sk = -1 }
local sync_local_equipped_weapons_to_native
local sync_native_capabilities_to_server

local function log(msg)
    print('[soulspire_core] ' .. tostring(msg))
end

local MODULE_ERR_RATE_SEC = 10
local module_err_state = {}

local function now_seconds()
    if ashita and ashita.time and ashita.time.get_tick64 then
        return ashita.time.get_tick64() / 1000
    end
    return os.time()
end

-- Isolate non-critical module calls so a single module error cannot unload soulspire_core,
-- while surfacing actionable rate-limited diagnostics to chat.
local function safe_call(module_key, fn, ...)
    local ok, res = pcall(fn, ...)
    if ok then return true, res end
    local ts = now_seconds()
    local st = module_err_state[module_key]
    if not st then
        st = { last_log = -1e9, suppressed = 0 }
        module_err_state[module_key] = st
    end
    if (ts - st.last_log) >= MODULE_ERR_RATE_SEC then
        local suffix = st.suppressed > 0 and (' (+' .. tostring(st.suppressed) .. ' suppressed)') or ''
        log(('Module error [%s]: %s%s'):format(tostring(module_key), tostring(res), suffix))
        st.last_log = ts
        st.suppressed = 0
    else
        st.suppressed = st.suppressed + 1
    end
    return false, res
end

local function is_chat_open()
    local ok, open = pcall(function()
        return AshitaCore:GetChatManager():IsInputOpen() ~= 0
    end)
    return ok and open == true
end

local function current_native_menu()
    if not menu then return nil end
    local ctx = menu:main_menu_context()
    focus:sync_native(ctx)
    return ctx
end

local function dispatch_action(action)
    local native = current_native_menu()
    return focus:handle_action(action, native)
end

ashita.events.register('load', 'soulspire_core_load', function()
    assets = Assets.new(addon.path)
    if type(addon.path) == 'string' and addon.path ~= '' then
        local sep = addon.path:find('\\', 1, true) and '\\' or '/'
        local base_dir = addon.path:gsub('[/\\]+$', '')
        local data_dir = base_dir .. sep .. '..' .. sep .. '..' .. sep .. 'plugins' .. sep .. 'data' .. sep
        weapon_pres.config_path = data_dir .. 'soul-weapon-config.json'
        weapon_pres.calibration_path = data_dir .. 'soul-weapon-calibration.local.json'
        weapon_pres.probe_output_path = data_dir .. 'soul-weapon-render-probe.local.json'
        weapon_pres.equip_diag_output_path = data_dir .. 'soul-weapon-equip-diag.local.json'
        safe_call('weapon_pres.load_file', function() weapon_pres:load_file() end)
    end
    local ok, scaling = pcall(require, 'scaling')
    if ok and scaling and scaling.scaled and scaling.scaled.w > 0 and scaling.scaled.h > 0 then
        local ptr_ok, operand = pcall(function()
            return AshitaCore:GetPointerManager():Get('menu')
        end)
        if ptr_ok and operand then
            menu = MenuBridge.new(ashita.memory, scaling, operand)
        end
    end
    ui = UI.new(imgui, registry, focus, assets)
    if not menu or not menu:is_available() then
        log('MenuManager layout unavailable; running in standalone /soulspire mode.')
    end
end)

ashita.events.register('unload', 'soulspire_core_unload', function()
    focus:blur_all('unload')
    input:reset()
    if assets then
        assets:release_all()
        assets = nil
    end
    menu, ui = nil, nil
end)

ashita.events.register('command', 'soulspire_core_command', function(e)
    local cmd = e.command:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if cmd == '/soulspire' or cmd == '/ss' then
        e.blocked = true
        focus:toggle_hub()
        return
    end

    local sub, rest = cmd:match('^/soulspire%s+(%S+)%s*(.*)$')
    if not sub then
        sub, rest = cmd:match('^/ss%s+(%S+)%s*(.*)$')
    end
    if not sub then return end

    e.blocked = true
    if sub == 'open' then
        local idx = (rest ~= '') and registry:find_index(rest) or focus.selected_index
        focus:open_hub(idx or 1, false)
    elseif sub == 'close' then
        focus:close_hub(current_native_menu())
    elseif sub == 'status' then
        local native = current_native_menu()
        local active = registry:get(focus.active_index)
        local sn, sn_err = NativeBridge.query()
        log(('version=%s mode=native-styled-fallback bridge=%s sections=%d hub_open=%s dock_focused=%s active=%s native_form=%s'):format(
            addon.version,
            tostring(menu ~= nil and menu:is_available()),
            registry:count(),
            tostring(focus.hub_open),
            tostring(focus.dock_focused),
            tostring(active and active.id or 'none'),
            tostring(native and native.name or 'none')
        ))
        if sn then
            log(('soulspire_native abi=v%d hooks=%d/%d caps=0x%04X modules=0x%02X/0x%02X banks=%d/%d hash=%s'):format(
                sn.abi_version, sn.installed_hooks, sn.expected_hooks, sn.capabilities,
                sn.active_modules_mask, sn.enabled_modules_mask,
                sn.menu2fon_banks_used, sn.menu2fon_banks_max, sn.registry_hash))
        else
            log('soulspire_native unavailable: ' .. tostring(sn_err))
        end
    elseif sub == 'debug' then
        if not menu or not menu:is_available() then
            log('MenuBridge unavailable.')
            return
        end
        local snap = menu:inspect_all()
        if not snap then
            log('MenuBridge inspect_all returned nil.')
            return
        end
        log(('current=%s cursor=%s windows=%d'):format(
            tostring(snap.current_name), tostring(snap.cursor), #snap.windows))
        for i, win in ipairs(snap.windows) do
            log(('  [%d] form="%s" rect=(%d,%d,%d,%d) current=%s'):format(
                i, win.name, win.left, win.top, win.right, win.bottom, tostring(win.is_current)))
        end
    elseif sub == 'weapondiag' then
        local trimmed = (rest or ''):gsub('^%s+', ''):gsub('%s+$', '')
        local action, arg = trimmed:match('^(%S+)%s*(.-)$')
        action = (action or ''):lower()
        arg = (arg or ''):gsub('^%s+', ''):gsub('%s+$', '')
        if action == 'on' then
            weapon_pres:set_diagnostics_enabled(true)
            weapon_pres:load_calibration_file()
            local det_ok, det_rk = weapon_pres:detect_local_race()
            log(('Developer weapon alignment diagnostics ENABLED (race=%s; disabled by default; live sync to soulspire_native active).'):format(
                det_ok and tostring(det_rk) or 'manual'))
        elseif action == 'off' then
            weapon_pres:set_diagnostics_enabled(false)
            if weapon_pres.calibration_path then weapon_pres:save_calibration_and_sync_native() end
            log('Developer weapon alignment diagnostics DISABLED.')
        elseif action == 'save' then
            local ok, path, synced = weapon_pres:save_calibration_and_sync_native()
            log(ok and ('Saved developer calibration to ' .. tostring(path) .. ' (native_sync=' .. tostring(synced) .. ')')
                or ('Save failed: ' .. tostring(path)))
        elseif action == 'export' then
            local ok, res = weapon_pres:export_file()
            log(ok and ('Exported calibrated weapon presentation profile to ' .. tostring(res))
                or ('Export failed: ' .. tostring(res)))
        elseif action == 'reset' then
            weapon_pres:reset_transforms()
            if weapon_pres.calibration_path then weapon_pres:save_calibration_and_sync_native() end
            log('Reset weapon presentation transforms to authoritative registry baseline.')
        elseif action == 'equip' then
            local ok_wc, WC = pcall(require, 'weapon_config')
            if not (ok_wc and WC) and type(addon.path) == 'string' and addon.path ~= '' then
                local sep = addon.path:find('\\', 1, true) and '\\' or '/'
                local cs_wc = addon.path:gsub('[/\\]+$', '') .. sep .. '..' .. sep .. 'crystalsocket' .. sep .. 'weapon_config.lua'
                ok_wc, WC = pcall(dofile, cs_wc)
            end
            local wc_rules, wc_reg_hash = {}, ''
            if ok_wc and WC then
                if not WC.status().loaded and type(addon.path) == 'string' then
                    WC.load_default(addon.path)
                end
                wc_rules = WC.native_rules()
                wc_reg_hash = WC.status().registry_hash or ''
            end
            local st = weapon_pres:status()
            local ok, rep, out_path, write_err = WeaponEquipDiag.run_diagnostic({
                diagnostics_enabled = weapon_pres:is_diagnostics_enabled(),
                rules_override = wc_rules,
                config_registry_hash = wc_reg_hash,
                weapon_config_hash = st.weapon_config_hash or '',
                output_path = weapon_pres.equip_diag_output_path,
            })
            if ok and type(rep) == 'table' then
                local n = rep.native
                log(('Equip diag: dll=%s enabled=%s hooks=%d/%d equip_hooks=%s soul=%s(job=%d,br=%d,known=%s,lvl=%d) native_rules=%d hits=+%d/-%d'):format(
                    tostring(n.dllLoaded), tostring(n.enabled), n.installedHooks, n.expectedHooks,
                    tostring(n.equipHooksOk), tostring(n.resolvedSoulId or 'none'),
                    n.activeJob, n.activeBranch, tostring(n.soulKnown), n.effectiveLevel,
                    n.weaponRulesCount, n.weaponAllowHits, n.weaponDenyHits))
                log(('Equip diag candidates: total=%d dual_2h=%d vanilla_sub=%d rejected=%d 0x050_trace=%d slices=%d'):format(
                    rep.summary.candidateCount, rep.summary.allowedDual2h,
                    rep.summary.allowedVanillaSub, rep.summary.rejected,
                    rep.summary.packets0x050Count or 0, rep.summary.codeSlicesCount or 0))
                if out_path then
                    log('Equip diag report written to: ' .. tostring(out_path))
                elseif write_err then
                    log('Equip diag report write ERROR: ' .. tostring(write_err))
                else
                    log('Equip diag report kept in memory (no output_path configured).')
                end
            else
                log('Weapon equip diag refused/failed: ' .. tostring(rep))
            end
        elseif action == 'probe' then
            local label = arg:gsub('[^%w_%-]', '_')
            if label:lower() == 'clear' or label:lower() == 'reset' then
                WeaponProbe.clear_snapshots()
                log('Weapon render probe comparative snapshots CLEARED.')
            else
                local ok, res, out_path = WeaponProbe.run_live_probe({
                    diagnostics_enabled = weapon_pres:is_diagnostics_enabled(),
                    output_path = weapon_pres.probe_output_path,
                    label = (label ~= '') and label or nil,
                })
                if ok and type(res) == 'table' then
                    local total = 0
                    for _, f in ipairs(res.findings or {}) do total = total + (f.match_count or 0) end
                    local snaps = #(res.comparative_snapshots or {})
                    local diffs = #(res.comparative_diff or {})
                    log(('Weapon render probe COMPLETE [%s]: anchors=%d/%d findings=%d snapshots=%d diffs=%d output=%s'):format(
                        (label ~= '' and label or ('snap_' .. snaps)),
                        res.anchor_matched or 0, res.anchor_total or 0, total, snaps, diffs, tostring(out_path)))
                else
                    log('Weapon render probe refused/failed: ' .. tostring(res))
                end
            end
        elseif action == 'caps' then
            local eq_ok = sync_local_equipped_weapons_to_native(true)
            local cap_ok = sync_native_capabilities_to_server()
            log(('Weapon capability sync: equip_pushed=%s cap_sent=%s (main=%d/sk=%d sub=%d/sk=%d)'):format(
                tostring(eq_ok), tostring(cap_ok),
                last_synced_equip.main_id, last_synced_equip.main_sk,
                last_synced_equip.sub_id, last_synced_equip.sub_sk))
            local wmd, wmd_err = NativeBridge.query_weapon_model_diag()
            if wmd then
                log(('Hook32 diag: calls=%d remaps=%d deny(dis=%d,sh=%d,aid=%d,eq=%d,f84=%d,auth=%d) last(aid=%u,lcid=%u,loc=%s,look=0x%04X,sub=%d->slot=%d) soul(known=%s,j=%d,b=%d,lvl=%d) nativeEq(m=%d/sk%d,s=%d/sk%d) pres(ld=%s,b=%d,p=%d)'):format(
                    wmd.hook32_calls, wmd.hook32_remaps,
                    wmd.deny_disabled, wmd.deny_zero_or_shield, wmd.deny_actor_id,
                    wmd.deny_local_equip, wmd.deny_fallback_84, wmd.deny_auth,
                    wmd.last_actor_id, wmd.last_local_char_id, tostring(wmd.last_is_local),
                    wmd.last_look_word, wmd.last_sub_model_id, wmd.last_result_slot,
                    tostring(wmd.last_soul_known), wmd.last_job, wmd.last_branch, wmd.last_effective_level,
                    wmd.local_main_item_id, wmd.local_main_skill, wmd.local_sub_item_id, wmd.local_sub_skill,
                    tostring(wmd.pres_loaded), wmd.pres_bindings, wmd.pres_profiles))
            else
                log('Hook32 diag unavailable: ' .. tostring(wmd_err))
            end
            if AshitaCore and AshitaCore.GetChatManager then
                local function send_status()
                    local chat = AshitaCore:GetChatManager()
                    if chat and type(chat.QueueCommand) == 'function' then
                        chat:QueueCommand(1, '/say !soulhud status')
                    end
                end
                -- Avoid queueing two /say commands in the same frame (which causes FFXI's
                -- "A command error occurred." message).
                if cap_ok and ashita and ashita.tasks and type(ashita.tasks.once) == 'function' then
                    ashita.tasks.once(0.4, send_status)
                else
                    send_status()
                end
            end
        else
            local st = weapon_pres:status()
            log(('weapondiag loaded=%s enabled=%s bindings=%d profiles=%d peers=%d hash=%s (usage: /soulspire weapondiag on|off|save|export|reset|equip|probe|caps)'):format(
                tostring(st.loaded),
                tostring(st.diagnostics_enabled),
                st.binding_count,
                st.profile_count,
                st.peer_count,
                tostring(st.weapon_config_hash)))
        end
    else
        log('Commands: /soulspire [open [section] | close | status | debug | weapondiag] (alias: /ss)')
    end
end)

-- Keyboard events: block both key_data and writable key_state buffer (verified pattern from crystalsocket.lua).
ashita.events.register('key_data', 'soulspire_core_key_data', function(e)
    if not Input.KEY_MAP[e.key] then return end
    if input:on_key(e.key, e.down, is_chat_open(), dispatch_action) then
        e.blocked = true
    end
end)

ashita.events.register('key_state', 'soulspire_core_key_state', function(e)
    if not e.data_raw or e.size < 209 then return end
    local data = ffi.cast('uint8_t*', e.data_raw)
    local chat_open = is_chat_open()
    for scan in pairs(Input.KEY_MAP) do
        if data[scan] == 0 then
            input:release_key(scan)
        elseif input:on_key(scan, true, chat_open, dispatch_action) then
            data[scan] = 0
        end
    end
end)

-- Controller events (XInput & DirectInput).
ashita.events.register('xinput_button', 'soulspire_core_xinput_button', function(e)
    local down = (e.state ~= nil and e.state ~= 0)
    if input:on_pad('xinput', e.button, down, dispatch_action) then
        e.blocked = true
    end
end)

ashita.events.register('dinput_button', 'soulspire_core_dinput_button', function(e)
    if e.button == 32 or e.button == 33 or e.button == 34 or e.button == 35 then
        -- POV hat event in Ashita DirectInput (offset 32..35)
        if input:on_dinput_pov(e.state, dispatch_action) then
            e.blocked = true
        end
        return
    end
    local down = (e.state ~= nil and e.state ~= 0)
    if input:on_pad('dinput', e.button, down, dispatch_action) then
        e.blocked = true
    end
end)

local caps_pending_zone = false
local caps_sent_this_zone = false

-- Sync local Main/Sub equipped item IDs & skills to soulspire_native.dll (Hook #32).
local function push_local_equipped_weapons(main_id, main_sk, sub_id, sub_sk, force)
    main_id = tonumber(main_id) or 0
    main_sk = tonumber(main_sk) or 0
    sub_id  = tonumber(sub_id)  or 0
    sub_sk  = tonumber(sub_sk)  or 0
    if not force and
        last_synced_equip.main_id == main_id and
        last_synced_equip.main_sk == main_sk and
        last_synced_equip.sub_id  == sub_id and
        last_synced_equip.sub_sk  == sub_sk then
        return false
    end
    last_synced_equip.main_id = main_id
    last_synced_equip.main_sk = main_sk
    last_synced_equip.sub_id  = sub_id
    last_synced_equip.sub_sk  = sub_sk
    return NativeBridge.set_local_equipped_weapons(main_id, main_sk, sub_id, sub_sk)
end

local function read_equipped_weapon_slot(inv, res, slot_idx)
    local ok_eq, eq = pcall(inv.GetEquippedItem, inv, slot_idx)
    if not ok_eq or not eq or not eq.Index or eq.Index == 0 then return 0, 0 end
    local cont = math.floor(eq.Index / 256)
    local iidx = eq.Index % 256
    if iidx == 0 then return 0, 0 end
    local ok_ci, ci = pcall(inv.GetContainerItem, inv, cont, iidx)
    if not ok_ci or not ci or not ci.Id or ci.Id == 0 then return 0, 0 end
    local ok_ri, ri = pcall(res.GetItemById, res, ci.Id)
    return tonumber(ci.Id) or 0, (ok_ri and ri and tonumber(ri.Skill)) or 0
end

sync_local_equipped_weapons_to_native = function(force)
    if not (AshitaCore and AshitaCore.GetMemoryManager and AshitaCore.GetResourceManager) then return false end
    local mm = AshitaCore:GetMemoryManager()
    local inv = mm and mm:GetInventory()
    local res = AshitaCore:GetResourceManager()
    if not inv or not res then return false end
    local main_id, main_sk = read_equipped_weapon_slot(inv, res, 0)
    local sub_id, sub_sk = read_equipped_weapon_slot(inv, res, 1)
    return push_local_equipped_weapons(main_id, main_sk, sub_id, sub_sk, force)
end

-- Parse incoming S2C 0x050 BEFORE FFXiMain.dll processes it so soulspire_native.dll
-- already has the new Main/Sub item ID & skill when LoadPcEquipmentModels runs.
local function sync_local_equipped_from_packet_0x050(raw)
    if type(raw) ~= 'string' or #raw < 7 then return false end
    local inv_idx = raw:byte(5) or 0
    local equip_slot = raw:byte(6) or 255
    local container = raw:byte(7) or 0
    if equip_slot ~= 0 and equip_slot ~= 1 then return false end
    if not (AshitaCore and AshitaCore.GetMemoryManager and AshitaCore.GetResourceManager) then return false end
    local mm = AshitaCore:GetMemoryManager()
    local inv = mm and mm:GetInventory()
    local res = AshitaCore:GetResourceManager()
    if not inv or not res then return false end
    local main_id, main_sk = read_equipped_weapon_slot(inv, res, 0)
    local sub_id, sub_sk = read_equipped_weapon_slot(inv, res, 1)
    local new_id, new_sk = 0, 0
    if inv_idx ~= 0 then
        local ok_ci, ci = pcall(inv.GetContainerItem, inv, container, inv_idx)
        if ok_ci and ci and ci.Id and ci.Id ~= 0 then
            local ok_ri, ri = pcall(res.GetItemById, res, ci.Id)
            new_id = tonumber(ci.Id) or 0
            new_sk = (ok_ri and ri and tonumber(ri.Skill)) or 0
        end
    end
    if equip_slot == 0 then
        main_id, main_sk = new_id, new_sk
    else
        sub_id, sub_sk = new_id, new_sk
    end
    return push_local_equipped_weapons(main_id, main_sk, sub_id, sub_sk, true)
end

-- Advertise verified native capabilities (e.g. Hook #32 WMR = 0x20000) to the server
-- via /say !soulhud cap <caps> (matching Ashita v4 server command dispatch) so the
-- server preserves compact_dual_axe for incompatible clients and sends real
-- independent weapon models only to capable clients.
sync_native_capabilities_to_server = function()
    if not (AshitaCore and AshitaCore.GetChatManager) then return false end
    local info = NativeBridge.query()
    if not info or type(info.capabilities) ~= 'number' then return false end
    if not NativeBridge.has_weapon_model_resolve_capability() then return false end
    local chat = AshitaCore:GetChatManager()
    if not chat or type(chat.QueueCommand) ~= 'function' then return false end
    sync_local_equipped_weapons_to_native(true)
    chat:QueueCommand(1, ('/say !soulhud cap %u'):format(info.capabilities))
    caps_pending_zone = false
    caps_sent_this_zone = true
    return true
end

-- Cleanly blur/close on zone transitions and track authoritative OXSI peer Souls.
ashita.events.register('packet_in', 'soulspire_core_packet_in', function(e)
    if type(e) ~= 'table' then return end
    if e.id == 0x00A or e.id == 0x00B then
        safe_call('focus.blur_all', function() focus:blur_all('zone_change') end)
        safe_call('input.reset', function() input:reset() end)
        safe_call('weapon_pres.reset_peers', function() weapon_pres:reset_peers() end)
        caps_sent_this_zone = false
        if e.id == 0x00A then
            caps_pending_zone = true
            safe_call('native.sync_equipped', function() sync_local_equipped_weapons_to_native(true) end)
        end
    elseif e.id == 0x01D or e.id == 0x00D then
        safe_call('native.sync_equipped', function() sync_local_equipped_weapons_to_native(false) end)
        if caps_pending_zone and not caps_sent_this_zone then
            safe_call('native.sync_caps', sync_native_capabilities_to_server)
        end
    elseif e.id == 0x1FC then
        local now_sec = now_seconds()
        safe_call('weapon_pres.observe_oxsi_packet', function()
            local peer = weapon_pres:observe_oxsi_packet(e.data_modified or e.data, now_sec)
            if type(peer) == 'table' and tonumber(peer.actor_id) then
                NativeBridge.upsert_peer_soul(peer.actor_id, peer.job or 0, peer.branch or 0, peer.effective_level or 0)
            end
        end)
    elseif e.id == 0x050 then
        safe_call('native.sync_equipped_0x050', function()
            if not sync_local_equipped_from_packet_0x050(e.data_modified or e.data) then
                sync_local_equipped_weapons_to_native(false)
            end
        end)
        if weapon_pres:is_diagnostics_enabled() then
            local now_sec = now_seconds()
            safe_call('weapon_equip_diag.packet_in', function()
                local rec = WeaponEquipDiag.observe_equip_packet('in', e.data_modified or e.data, now_sec)
                if rec then
                    log(('[weapondiag] S2C 0x050 equip_slot=%d inv_idx=%d container=%d'):format(
                        rec.equipSlot, rec.invIndex, rec.container))
                end
            end)
        end
    end
end)

ashita.events.register('packet_out', 'soulspire_core_packet_out', function(e)
    if type(e) ~= 'table' then return end
    if e.id == 0x050 and weapon_pres:is_diagnostics_enabled() then
        local now_sec = now_seconds()
        safe_call('weapon_equip_diag.packet_out', function()
            local rec = WeaponEquipDiag.observe_equip_packet('out', e.data_modified or e.data, now_sec)
            if rec then
                log(('[weapondiag] C2S 0x050 equip_slot=%d inv_idx=%d container=%d'):format(
                    rec.equipSlot, rec.invIndex, rec.container))
            end
        end)
    end
end)

local function is_local_player_in_game()
    if not (AshitaCore and AshitaCore.GetMemoryManager) then return false end
    local ok, sid = pcall(function()
        local party = AshitaCore:GetMemoryManager():GetParty()
        return party and party:GetMemberServerId(0) or 0
    end)
    return ok and tonumber(sid) ~= nil and tonumber(sid) > 0
end

ashita.events.register('d3d_present', 'soulspire_core_present', function()
    if not ui then return end
    safe_call('native.sync_equipped_tick', function()
        sync_local_equipped_weapons_to_native(false)
        if not caps_sent_this_zone and is_local_player_in_game() then
            sync_native_capabilities_to_server()
        end
    end)
    safe_call('ui.draw', function()
        local native = current_native_menu()
        ui:draw(native, menu ~= nil and menu:is_available())
    end)
    if weapon_pres:is_diagnostics_enabled() then
        safe_call('weapon_pres.draw_diagnostics_panel', function()
            weapon_pres:draw_diagnostics_panel(imgui)
        end)
    end
end)
