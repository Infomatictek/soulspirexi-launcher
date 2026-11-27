-- SoulspireXI — Full VanaCore-Native Soulspire Core (CLIENT-MODERN-001 / DEC-028)
--
-- Single unified VanaCore-native addon (`addons/vanacore/soulspire_core/`) with ZERO Ashita
-- dependencies (`AshitaCore`, `ashita.*`, `d3d8`, `soulspire_native.dll`, `crystaljobs.dll`).
-- Preserves 100% of the polished Soulspire Core UI shell, Soul Sanctum, Soulforge Constellation
-- talent trees (with live-verified WS allocation/refund), Soul Talents, 66-Soul Universal HUD,
-- Soul Actions, CrystalSocket, Flintlock state, Mob Status, and authoritative VanaCore-managed
-- input & cursor ownership (`vana.soulspire.acquire_ui_input` / `release_ui_input`).

addon.name    = 'soulspire_core'
addon.author  = 'SoulspireXI'
addon.version = '4.0.0-vanacore'
addon.desc    = 'Unified VanaCore-native Soulspire Core (Shell, Soul Sanctum, Soulforge, 66-Soul HUD, Actions, Diagnostics)'

local addon_dir = (type(addon) == 'table' and type(addon.path) == 'string' and addon.path ~= '')
    and addon.path:gsub('[/\\]+$', '')
    or '.'
local install_dir = (type(vana) == 'table' and vana.paths and type(vana.paths.install) == 'string' and vana.paths.install ~= '')
    and vana.paths.install:gsub('[/\\]+$', '')
    or addon_dir:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')

-- Configure module search paths strictly inside addons/vanacore/soulspire_core/
package.path = table.concat({
    addon_dir .. '/?.lua',
    addon_dir .. '/?/init.lua',
    addon_dir .. '/soulforge/?.lua',
    addon_dir .. '/soulhud/?.lua',
    addon_dir .. '/crystalsocket/?.lua',
    package.path,
}, ';')

-- Expose VanaCore's native ImGui table to ported UI modules via standard require('imgui')
if type(vana) == 'table' and type(vana.imgui) == 'table' then
    package.loaded['imgui'] = vana.imgui
end

local startup_report = {
    ok      = true,
    version = addon.version,
    modules = {},
    errors  = {},
}

local function log_msg(msg)
    local line = '[soulspire_core] ' .. tostring(msg)
    if type(vana) == 'table' and type(vana.log) == 'function' then
        vana.log(line)
    end
    print(line)
end

local function load_mod(name, mod_name)
    local ok, mod = pcall(require, mod_name)
    if not ok or mod == nil then
        startup_report.ok = false
        startup_report.modules[name] = 'FAIL: ' .. tostring(mod)
        startup_report.errors[#startup_report.errors + 1] = name .. ': ' .. tostring(mod)
        log_msg('ERROR loading module ' .. name .. ' (' .. mod_name .. '): ' .. tostring(mod))
        return nil
    end
    startup_report.modules[name] = 'OK'
    return mod
end

local RegistryMod    = load_mod('registry',       'core.registry')
local FocusMod       = load_mod('focus',          'core.focus')
local InputMod       = load_mod('input',          'core.input')
local AssetsMod      = load_mod('assets',         'core.assets')
local DataServiceMod = load_mod('data_service',   'core.data_service')
local UiMod          = load_mod('ui',             'core.ui')
local IdentityMod    = load_mod('identity',       'core.identity')
local ActionsMod     = load_mod('actions',        'core.actions')
local FlintlockMod   = load_mod('flintlock',      'core.flintlock')
local MobStatusMod   = load_mod('mob_status',     'core.mob_status')
local SoulHudBridge  = load_mod('soulhud_bridge', 'core.soulhud_bridge')

local CharacterMod   = load_mod('character',      'modules.character')
local WeaponMod      = load_mod('weapon_mastery', 'modules.weapon_mastery')
local SoulTalentsMod = load_mod('soul_talents',   'modules.soul_talents')
local AbilitiesMod   = load_mod('abilities',      'modules.abilities')
local StatusDiagMod  = load_mod('status_diag',    'modules.status_and_diag')

local CsProto        = load_mod('cs_protocol',    'crystalsocket.protocol')
local CsStateMod     = load_mod('cs_state',       'crystalsocket.state')
local SfArt          = load_mod('sf_art',         'soulforge.art')
local SfStateMod     = load_mod('sf_state',       'soulforge.soulforge_state')
local WsReg          = load_mod('ws_registry',    'soulforge.ws_registry_generated')
local SfUi           = load_mod('sf_ui',          'soulforge.soulforge_ui')

-- Runtime instances
local settings_store = nil
local registry       = nil
local focus          = nil
local input          = nil
local assets         = nil
local data_service   = nil
local ui             = nil
local identity       = nil
local actions        = nil
local flintlock      = nil
local mob_status     = nil
local soulhud        = nil
local character_mod  = nil
local weapon_mod     = nil
local soul_talents   = nil
local abilities_mod  = nil
local status_diag    = nil
local sf_state       = nil
local sf_actions     = nil

local ui_input_held         = false
local last_lease_refresh    = 0
local last_known_job        = 0
local LEASE_REFRESH_INTERVAL = 0.50

local runtime_diag = {
    crys_req_sent       = 0,
    crys_rx             = 0,
    oxhd_rx             = 0,
    xinput_events       = 0,
    dinput_events       = 0,
    xinput_state_events = 0,
    dinput_state_events = 0,
    actions_dispatched  = 0,
    last_action         = 'none',
    last_action_reached = false,
    last_device         = 'gamepad',
    input_diag_fn       = nil,
}

local function native_clock()
    if type(vana) == 'table' and vana.time and type(vana.time.clock) == 'function' then
        local ok, t = pcall(vana.time.clock)
        if ok and type(t) == 'number' and t >= 0 then return t end
    end
    return os.clock()
end

local function acquire_native_ui_input(now)
    local ts = now or native_clock()
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.acquire_ui_input) == 'function' then
        vana.soulspire.acquire_ui_input('soulspire_core', {
            block_mouse     = true,
            capture_gamepad = true,
            show_cursor     = true,
            lease_ms        = 2000,
        })
        ui_input_held = true
        last_lease_refresh = ts
    elseif type(vana) == 'table' and vana.gamepad and type(vana.gamepad.nav) == 'function' then
        vana.gamepad.nav(true)
        ui_input_held = true
        last_lease_refresh = ts
    end
end

-- Refresh lease while foreground & active without causing 60 Hz acquire/release churn on focus_loss.
local function refresh_native_ui_input_if_active(now)
    local ts = now or native_clock()
    if not ui_input_held then return end
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.ui_input_state) == 'function' then
        local ok, st = pcall(vana.soulspire.ui_input_state)
        if ok and type(st) == 'table' then
            if st.active ~= true then
                -- C++ released ownership (e.g. focus_loss); do NOT re-acquire until user interacts again.
                ui_input_held = false
                return
            end
        end
    end
    if (ts - last_lease_refresh) >= LEASE_REFRESH_INTERVAL then
        acquire_native_ui_input(ts)
    end
end

local function release_native_ui_input(reason)
    if not ui_input_held then return end
    ui_input_held = false
    last_lease_refresh = 0
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.release_ui_input) == 'function' then
        vana.soulspire.release_ui_input('soulspire_core', reason or 'closed')
    elseif type(vana) == 'table' and vana.gamepad and type(vana.gamepad.nav) == 'function' then
        vana.gamepad.nav(false)
    end
end

local function dispatch_ui_action(act, source)
    if not focus or not focus:is_hub_open() or type(act) ~= 'string' or act == '' then
        return false
    end
    if not ui_input_held then
        acquire_native_ui_input()
    end
    runtime_diag.actions_dispatched = runtime_diag.actions_dispatched + 1
    runtime_diag.last_action = act
    runtime_diag.last_device = (input and input.last_device) or source or 'gamepad'
    local handled = focus:handle_action(act, nil) == true
    runtime_diag.last_action_reached = handled
    if not focus:is_hub_open() then
        release_native_ui_input((source or 'ui') .. '_close')
    end
    return handled
end

local function save_core_settings()
    if settings_store and type(settings_store.save) == 'function' then
        if ui then settings_store.data.ui_scale = ui.ui_scale end
        if input then settings_store.data.bindings = input:get_bindings() end
        pcall(function() settings_store:save() end)
    end
end

local function open_hub(module_id, from_native_menu)
    if not focus then return end
    if type(module_id) == 'string' and module_id ~= '' and registry then
        local idx = registry:find_index(module_id)
        local m = idx and registry:get(idx) or nil
        if m then
            focus:select_module(m.id)
        end
    end
    if from_native_menu and type(focus.open_from_native_menu) == 'function' then
        focus:open_from_native_menu(nil)
    else
        focus:open_hub()
    end
    if ui then ui:request_window_focus() end
    acquire_native_ui_input()
    if input and type(input.arm_open_guard) == 'function' then
        input:arm_open_guard(0.22)
    end
    if sf_actions and sf_state and (not sf_state.synced or #(sf_state.catalog or {}) == 0) then
        sf_actions.sync()
    end
end

local function close_hub(reason)
    if focus and focus:is_hub_open() then
        focus:close_hub()
    end
    if input and type(input.reset) == 'function' then
        input:reset()
    end
    release_native_ui_input(reason or 'closed')
end

local function toggle_hub(module_id)
    if not focus then return end
    if type(module_id) == 'string' and module_id ~= '' then
        open_hub(module_id)
    elseif focus:is_hub_open() then
        close_hub('toggle_off')
    else
        open_hub(nil)
    end
end

local function is_chat_or_text_active()
    if type(vana) == 'table' and vana.game and type(vana.game.world) == 'function' then
        local w = vana.game.world()
        if type(w) == 'table' and w.chat_open == true then
            return true
        end
    end
    local imgui = type(vana) == 'table' and vana.imgui or nil
    if imgui and type(imgui.GetIO) == 'function' then
        local ok, io_obj = pcall(imgui.GetIO)
        if ok and io_obj and io_obj.WantTextInput == true then
            return true
        end
    end
    return false
end

local function print_status()
    local d = (type(vana) == 'table' and vana.soulspire and vana.soulspire.diagnostics)
        and vana.soulspire.diagnostics() or {}
    local caps = tonumber(d.capabilities) or 0
    local has_cmd_menu = (math.floor(caps / 65536) % 2) == 1
    local has_tex = (math.floor(caps / 1048576) % 2) == 1
    local has_input = (math.floor(caps / 2097152) % 2) == 1
    log_msg(string.format(
        'Status: v%s enabled=%s api=v%d hooks=%d/%d caps=0x%X cmd_menu=%s tex=%s input=%s ashita_compat=%s actions=%d vis=%d startup_ok=%s',
        addon.version, tostring(d.enabled), tonumber(d.api_version) or 0,
        tonumber(d.hooks_installed) or 0, tonumber(d.hooks_total) or 0,
        caps, tostring(has_cmd_menu), tostring(has_tex), tostring(has_input),
        tostring(d.ashita_compat_enabled),
        tonumber(d.action_count) or 0, tonumber(d.visibility_count) or 0,
        tostring(startup_report.ok)))
    for _, err in ipairs(startup_report.errors) do
        log_msg('  STARTUP ERROR: ' .. tostring(err))
    end
end

local function print_soulactions_status(show_caps)
    local d = (type(vana) == 'table' and vana.soulspire and vana.soulspire.diagnostics)
        and vana.soulspire.diagnostics() or {}
    local id = identity and identity:active() or {}
    if show_caps then
        log_msg(string.format('[soulactions] capabilities=0x%X hooks=%d/%d row_limit=%d',
            tonumber(d.capabilities) or 0, tonumber(d.hooks_installed) or 0,
            tonumber(d.hooks_total) or 0, tonumber(d.action_row_limit) or 16))
        for _, h in ipairs(d.hooks or {}) do
            log_msg(string.format('  [%s] %s (%s/%s) +0x%X hits=%d',
                h.installed and 'OK' or 'FAIL', tostring(h.id), tostring(h.owner),
                tostring(h.disposition or ''), tonumber(h.rva) or 0, tonumber(h.hit_count) or 0))
        end
    else
        log_msg(string.format('[soulactions] soul=%s (job=%d branch=%d lv=%d) actions=%d visibility=%d hooks=%d/%d',
            tostring(id.full_name or id.soul_key or 'none'),
            tonumber(id.job) or 0, tonumber(id.branch) or 0, tonumber(id.effective_level) or 0,
            tonumber(d.action_count) or 0, tonumber(d.visibility_count) or 0,
            tonumber(d.hooks_installed) or 0, tonumber(d.hooks_total) or 0))
    end
end

local function init_all()
    if type(vana) == 'table' and vana.settings and type(vana.settings.register) == 'function' then
        local ok, store = pcall(vana.settings.register, {
            name     = 'soulspire_core',
            scope    = 'global',
            defaults = { ui_scale = 1.0, bindings = {} },
        })
        if ok and store then settings_store = store end
    end

    local saved_scale = (settings_store and settings_store.data and tonumber(settings_store.data.ui_scale)) or 1.0
    local saved_binds = (settings_store and settings_store.data and type(settings_store.data.bindings) == 'table')
        and settings_store.data.bindings or nil

    assets   = AssetsMod and AssetsMod.new(addon_dir, install_dir) or nil
    registry = RegistryMod and RegistryMod.new() or nil
    focus    = (FocusMod and registry) and FocusMod.new(registry) or nil
    input    = InputMod and InputMod.new({
        bindings = saved_binds,
        clock    = native_clock,
    }) or nil
    runtime_diag.input_diag_fn = function()
        return (input and type(input.get_diagnostics) == 'function') and input:get_diagnostics() or nil
    end

    if SfArt and SfArt.setRoot then
        SfArt.setRoot(addon_dir, install_dir)
        package.loaded['art'] = SfArt
    end

    data_service = DataServiceMod and DataServiceMod.new({
        addon_path = addon_dir,
        auto_load  = true,
    }) or nil

    identity   = IdentityMod and IdentityMod.new(install_dir, addon_dir) or nil
    actions    = ActionsMod and ActionsMod.new(install_dir, identity, addon_dir) or nil
    flintlock  = FlintlockMod and FlintlockMod.new(identity) or nil
    mob_status = MobStatusMod and MobStatusMod.new() or nil
    soulhud    = SoulHudBridge and SoulHudBridge.new(addon_dir, install_dir, identity) or nil

    -- 1. Soul Sanctum / Character Identity (CrystalSocket)
    if CharacterMod and CsProto and CsStateMod and registry then
        local cs_state = CsStateMod.new()
        character_mod = CharacterMod.new({
            protocol      = CsProto,
            crystal_state = cs_state,
            soul_registry = RegistryMod and RegistryMod.souls or nil,
            data_service  = data_service,
            assets        = assets,
            clock         = native_clock,
            send_packet   = function(pkt)
                if type(pkt) ~= 'string' or #pkt ~= 16 then
                    return nil, 'Invalid crystal packet.'
                end
                if type(vana) == 'table' and vana.packets and type(vana.packets.inject) == 'function' then
                    runtime_diag.crys_req_sent = runtime_diag.crys_req_sent + 1
                    vana.packets.inject(false, CsProto.REQUEST_ID, pkt)
                    return true
                end
                return nil, 'VanaCore packet transport unavailable.'
            end,
            dll_status_fn = function()
                local d = (type(vana) == 'table' and vana.soulspire and vana.soulspire.diagnostics)
                    and vana.soulspire.diagnostics() or {}
                local hooks_installed = tonumber(d.hooks_installed) or 0
                local hooks_total     = tonumber(d.hooks_total) or 0
                return {
                    loaded                = d.enabled == true,
                    hooks                 = hooks_installed,
                    hooks_installed       = hooks_installed,
                    hooks_total           = hooks_total,
                    api_version           = tonumber(d.api_version) or 0,
                    capabilities          = tonumber(d.capabilities) or 0,
                    ashita_compat_enabled = d.ashita_compat_enabled == true,
                    mode                  = 'VanaCore Native',
                }
            end,
        })
        registry:attach_controller('character', character_mod, true)
        if soulhud and type(soulhud.set_character_mod) == 'function' then
            soulhud:set_character_mod(character_mod)
        end
    end

    -- 2. Weapon Mastery (Soulforge Constellation) & 3. Soul Talents
    if SfStateMod and SfUi and WeaponMod and registry then
        sf_state, sf_actions = SfStateMod.new({
            soulRegistry = RegistryMod and RegistryMod.souls or nil,
            wsRegistry   = WsReg,
            dataService  = data_service,
            savePrefs    = save_core_settings,
            clock        = (type(vana) == 'table' and vana.time and vana.time.clock) or os.clock,
        })
        weapon_mod = WeaponMod.new(sf_state, sf_actions, SfUi)
        registry:attach_controller('weapon_mastery', weapon_mod, true)

        if SoulTalentsMod then
            soul_talents = SoulTalentsMod.new(sf_state, sf_actions, SfUi, {
                soul_registry = RegistryMod and RegistryMod.souls or nil,
                data_service  = data_service,
                assets        = assets,
                on_jump_to_ws = function(ws_id, node_key)
                    if focus then focus:select_module('weapon_mastery') end
                    if weapon_mod then weapon_mod:focus_ws_and_node(ws_id, node_key) end
                end,
            })
            registry:attach_controller('soul_talents', soul_talents, true)
        end
    end

    -- 4. Soul Actions
    if AbilitiesMod and registry then
        abilities_mod = AbilitiesMod.new(actions, identity)
        registry:attach_controller('abilities', abilities_mod, true)
    end

    -- 5. Diagnostics, Mob Status & Flintlock
    if StatusDiagMod and registry then
        status_diag = StatusDiagMod.new(flintlock, mob_status, startup_report, identity, actions, runtime_diag)
        registry:attach_controller('journal', status_diag, true)
    end

    -- 6. Full-Screen Dark-Fantasy RPG Shell
    local imgui = type(vana) == 'table' and vana.imgui or nil
    if UiMod and imgui and registry and focus then
        ui = UiMod.new(imgui, registry, focus, assets, {
            ui_scale        = saved_scale,
            on_scale_change = function() save_core_settings() end,
            get_identity    = function() return identity and identity:active() or nil end,
            get_last_device = function() return input and input.last_device or 'gamepad' end,
        })
    end

    local a_cnt, v_cnt = 0, 0
    if actions then
        a_cnt, v_cnt = actions:sync_to_native()
    end

    -- Fail-loud startup validation (never report startup_ok=true when required data is missing)
    local soul_cnt = identity and #(identity.souls or {}) or 0
    local expected_souls = (IdentityMod and IdentityMod.EXPECTED_SOUL_COUNT) or 66
    local min_actions    = (ActionsMod and ActionsMod.MIN_EXPECTED_ACTIONS) or 100
    local min_visibility = (ActionsMod and ActionsMod.MIN_EXPECTED_VISIBILITY) or 100

    if soul_cnt ~= expected_souls then
        startup_report.ok = false
        startup_report.errors[#startup_report.errors + 1] = string.format(
            'Soul registry invalid: expected %d Souls, loaded %d (source=%s, error=%s, tried=%s)',
            expected_souls, soul_cnt,
            tostring(identity and identity.registry_source or 'none'),
            tostring(identity and identity.last_error or 'unknown'),
            table.concat((identity and identity.tried_paths) or {}, ', '))
    elseif not identity or type(identity.registry_hash) ~= 'string' or identity.registry_hash == '' then
        startup_report.ok = false
        startup_report.errors[#startup_report.errors + 1] = string.format(
            'Soul registry hash missing (source=%s)',
            tostring(identity and identity.registry_source or 'none'))
    end

    if a_cnt < min_actions then
        startup_report.ok = false
        startup_report.errors[#startup_report.errors + 1] = string.format(
            'Soul actions catalog incomplete: expected >=%d, loaded %d (source=%s)',
            min_actions, a_cnt, tostring(actions and actions.actions_source or 'none'))
    end
    if v_cnt < min_visibility then
        startup_report.ok = false
        startup_report.errors[#startup_report.errors + 1] = string.format(
            'Soul visibility catalog incomplete: expected >=%d, loaded %d (source=%s)',
            min_visibility, v_cnt, tostring(actions and actions.visibility_source or 'none'))
    end
    if actions and type(actions.errors) == 'table' then
        for _, aerr in ipairs(actions.errors) do
            startup_report.ok = false
            startup_report.errors[#startup_report.errors + 1] = 'actions: ' .. tostring(aerr)
        end
    end

    if not (type(vana) == 'table' and vana.soulspire and type(vana.soulspire.enabled) == 'function' and vana.soulspire.enabled()) then
        startup_report.ok = false
        startup_report.errors[#startup_report.errors + 1] = 'vana.soulspire native subsystem disabled or unavailable'
    end
    if not imgui then
        startup_report.ok = false
        startup_report.errors[#startup_report.errors + 1] = 'vana.imgui unavailable'
    end

    -- Trigger initial authoritative Soul sync if already logged in (VanaCore delay.login=1 loads addon after login)
    if character_mod and type(character_mod.sync) == 'function'
        and type(vana) == 'table' and vana.game and type(vana.game.self) == 'function' then
        local sid = vana.game.self()
        if tonumber(sid) and tonumber(sid) > 0 then
            character_mod:sync(false)
        end
    end

    log_msg(string.format(
        'Initialized VanaCore-Native Core v%s (startup_ok=%s, souls=%d, actions=%d, visibility=%d, reg_src=%s). Commands: /soulspire, /talents, /soulhud, /soulactions.',
        addon.version, tostring(startup_report.ok), soul_cnt, a_cnt, v_cnt,
        tostring(identity and identity.registry_source or 'none')))
    if not startup_report.ok then
        print_status()
    end
end

-- Event registration (strictly verified VanaCore native events)
if type(vana) == 'table' and vana.events then
    vana.events.on('load', function()
        init_all()
    end)

    vana.events.on('present', function()
        local now = native_clock()

        -- Native main Commands menu activation (Hooks #28-#31: Status -> Soulspire -> Equipment)
        if vana.soulspire and type(vana.soulspire.consume_open_core) == 'function' then
            if vana.soulspire.consume_open_core() > 0 then
                if focus and focus:is_hub_open() then
                    close_hub('native_menu_toggle')
                else
                    open_hub(nil, true)
                end
            end
        end

        -- Tick Soulforge & CrystalSocket pending-op timeout / sync recovery
        if sf_actions and type(sf_actions.tick) == 'function' then
            sf_actions.tick(now)
        end
        if character_mod and type(character_mod.tick) == 'function' then
            character_mod:tick(now)
        end

        -- Tick directional hold-to-repeat & throttle lease refresh when hub is open
        local hub_open = focus ~= nil and focus:is_hub_open()
        if hub_open then
            refresh_native_ui_input_if_active(now)
            if input and type(input.tick) == 'function' then
                input:tick(now, function(act)
                    dispatch_ui_action(act, 'repeat')
                end, true)
            end
        elseif ui_input_held then
            release_native_ui_input('hub_closed')
        end

        local imgui = vana.imgui
        if imgui then
            if hub_open and input and type(input.on_mouse_activity) == 'function' and type(imgui.GetIO) == 'function' then
                local ok_io, io_obj = pcall(imgui.GetIO)
                if ok_io and io_obj then
                    local dx = (io_obj.MouseDelta and tonumber(io_obj.MouseDelta.x)) or 0
                    local dy = (io_obj.MouseDelta and tonumber(io_obj.MouseDelta.y)) or 0
                    local clicked = (type(imgui.IsMouseClicked) == 'function')
                        and (imgui.IsMouseClicked(0) or imgui.IsMouseClicked(1)) or false
                    if clicked or math.abs(dx) > 1.5 or math.abs(dy) > 1.5 then
                        input:on_mouse_activity(now)
                        runtime_diag.last_device = 'mouse'
                        if not ui_input_held then
                            acquire_native_ui_input(now)
                        end
                    end
                end
            end
            if soulhud then
                soulhud:render(imgui, hub_open)
            end
            if hub_open and ui then
                ui:draw_hub()
                if not focus:is_hub_open() then
                    release_native_ui_input('ui_closed')
                end
            end
        end
    end)

    vana.events.on('packet_in', function(e)
        if type(e) ~= 'table' then return end
        local id, data, size = e.id, e.data, e.size
        local now = native_clock()
        if sf_actions then
            if type(sf_actions.handlePacketIn) == 'function' then
                sf_actions.handlePacketIn(id, data, size)
            elseif type(sf_actions.handlePacket) == 'function' then
                sf_actions.handlePacket(id, data, size)
            end
        end
        if id == 0x1FF and character_mod and type(character_mod.handle_packet_in) == 'function' then
            if character_mod:handle_packet_in(id, data, now, size) then
                runtime_diag.crys_rx = runtime_diag.crys_rx + 1
            end
        end
        -- Decode binary 0x1FC OXHD authoritatively in Lua so Soul identity is always accurate
        -- even on VanaCore builds where C++ 0x1FC byte offsets differed.
        if id == 0x1FC and type(data) == 'string' then
            local len = (type(size) == 'number' and size > 0 and size <= #data) and size or #data
            if len >= 16 and data:sub(5, 8) == 'OXHD' and data:byte(9) == 1 then
                runtime_diag.oxhd_rx = runtime_diag.oxhd_rx + 1
                local unlocked = (data:byte(10) or 0) == 1
                local job_id   = data:byte(11) or 0
                local key_len  = data:byte(12) or 0
                if key_len > 0 and 16 + key_len <= len and identity and type(identity.resolve_key) == 'function' then
                    local soul_key = data:sub(17, 16 + key_len)
                    local rec = identity:resolve_key(soul_key)
                    if rec and rec.job_id == job_id and unlocked then
                        if character_mod and type(character_mod.observe_hud_identity) == 'function' then
                            character_mod:observe_hud_identity(rec.branch_id, rec.job_id)
                        end
                        if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.set_identity) == 'function' then
                            pcall(vana.soulspire.set_identity, rec.job_id, rec.branch_id, 0, 0)
                        end
                    end
                end
            end
        end
        if soulhud and type(soulhud.handle_packet_in) == 'function' then
            soulhud:handle_packet_in(id, data, now, size)
        end
        -- Job / Level change (0x061 Char Stats): refresh Soul collection & invalidate stale Soulforge state
        if id == 0x061 and type(data) == 'string' and #data >= 14 then
            local new_job = data:byte(13) or 0
            if new_job >= 1 and new_job <= 22 and new_job ~= last_known_job then
                local prev_job = last_known_job
                last_known_job = new_job
                if prev_job > 0 then
                    if sf_actions and type(sf_actions.invalidate) == 'function' then
                        sf_actions.invalidate('job_change')
                    end
                    if character_mod and type(character_mod.sync) == 'function' then
                        character_mod:sync(false)
                    end
                end
            end
        end
        if id == 0x00A or id == 0x00B then
            close_hub(id == 0x00A and 'zone_in' or 'zone_out')
            if sf_actions then
                if type(sf_actions.invalidate) == 'function' then
                    sf_actions.invalidate(id == 0x00A and 'zone_in' or 'zone_out')
                elseif type(sf_actions.onZone) == 'function' then
                    sf_actions.onZone()
                end
            end
            if id == 0x00A and character_mod and type(character_mod.sync) == 'function' then
                character_mod:sync(false)
            end
        end
    end)

    -- Authoritative native XInput controller routing (LB=8 / RB=9 module switching, D-Pad, A/B/X/Y, L-Stick)
    vana.events.on('xinput_button', function(e)
        if type(e) ~= 'table' or not focus or not focus:is_hub_open() then return false end
        runtime_diag.xinput_events = runtime_diag.xinput_events + 1
        if input and type(input.on_xinput_button) == 'function' then
            input:on_xinput_button(e, function(act)
                return dispatch_ui_action(act, 'xinput')
            end, true, native_clock())
        end
        -- While Core Hub is active, consume ALL gamepad events so nothing leaks to FFXI gameplay
        e.blocked = true
        return true
    end)

    -- Authoritative native XInput state filtering (Left Stick + digital wButtons edge detection + zeroing game state)
    vana.events.on('xinput_state', function(e)
        if type(e) ~= 'table' or not focus or not focus:is_hub_open() then return false end
        runtime_diag.xinput_state_events = runtime_diag.xinput_state_events + 1
        if input and type(input.filter_xinput_state) == 'function' then
            input:filter_xinput_state(e.state, e.state_modified, function(act)
                return dispatch_ui_action(act, 'xinput_state')
            end, true, native_clock(), e.user)
        end
        return true
    end)

    -- Authoritative native DirectInput controller routing (DIJOYSTATE offsets: 32=POV, 48+n=buttons, 0/4=LX/LY)
    vana.events.on('dinput_button', function(e)
        if type(e) ~= 'table' or not focus or not focus:is_hub_open() then return false end
        runtime_diag.dinput_events = runtime_diag.dinput_events + 1
        if input and type(input.on_dinput_button) == 'function' then
            input:on_dinput_button(e, function(act)
                return dispatch_ui_action(act, 'dinput')
            end, true, native_clock())
        end
        e.blocked = true
        return true
    end)

    -- Authoritative native DirectInput state filtering (Left Stick + POV + rgbButtons edge detection + neutralizing game state)
    vana.events.on('dinput_state', function(e)
        if type(e) ~= 'table' or not focus or not focus:is_hub_open() then return false end
        runtime_diag.dinput_state_events = runtime_diag.dinput_state_events + 1
        if input and type(input.filter_dinput_state) == 'function' then
            input:filter_dinput_state(e.state, e.state_modified, function(act)
                return dispatch_ui_action(act, 'dinput_state')
            end, true, native_clock())
        end
        return true
    end)

    -- Keyboard navigation while Core Hub is open (respects chat & ImGui text inputs)
    vana.events.on('key', function(e)
        if type(e) ~= 'table' or not focus or not focus:is_hub_open() then return false end
        if is_chat_or_text_active() then return false end
        local vk = tonumber(e.wparam) or 0
        local is_down = (e.down == true) or ((tonumber(e.lparam) or 0) >= 0)
        if not is_down then return false end
        local vk_to_action = {
            [0x1B] = 'cancel',      -- VK_ESCAPE
            [0x08] = 'cancel',      -- VK_BACK
            [0x09] = 'focus_dock',  -- VK_TAB
            [0x51] = 'module_prev', -- Q
            [0x45] = 'module_next', -- E
            [0xDB] = 'module_prev', -- [
            [0xDD] = 'module_next', -- ]
            [0x26] = 'up',          -- VK_UP
            [0x28] = 'down',        -- VK_DOWN
            [0x25] = 'left',        -- VK_LEFT
            [0x27] = 'right',       -- VK_RIGHT
            [0x0D] = 'confirm',     -- VK_RETURN
            [0x20] = 'confirm',     -- VK_SPACE
            [0x58] = 'context',     -- X
            [0x59] = 'details',     -- Y
            [0x52] = 'respec_ws',   -- R
            [0x54] = 'toggle_paths',-- T
        }
        local act = vk_to_action[vk]
        if act then
            if input then input.last_device = 'keyboard' end
            dispatch_ui_action(act, 'keyboard')
            e.blocked = true
            return true
        end
        return false
    end)

    vana.events.on('command', function(e)
        if type(e) ~= 'table' or type(e.command) ~= 'string' then return false end
        local cmd = e.command:match('^%s*(.-)%s*$')
        local low = string.lower(cmd)

        if low == '/soulspire' or low == '/ss' then
            toggle_hub(nil)
            return true
        end
        if low == '/talents' or low == '/soulforge' or low == '/soulspire talents' or low == '/soulspire soulforge' then
            toggle_hub('weapon_mastery')
            return true
        end
        if low == '/crystals' or low == '/soulspire character' or low == '/soulspire souls' then
            toggle_hub('character')
            return true
        end
        if low == '/soulspire soultalents' then
            toggle_hub('soul_talents')
            return true
        end
        if low == '/flintlock' or low == '/mobstatus' or low == '/soulspire diag' or low == '/soulspire diagnostics' then
            if status_diag then
                status_diag.subtab = (low == '/flintlock' and 'flintlock') or (low == '/mobstatus' and 'mobs') or 'diag'
            end
            toggle_hub('journal')
            return true
        end
        if low == '/soulhud' or low == '/soulspire hud' or low:sub(1, 9) == '/soulhud ' then
            if soulhud and type(soulhud.handle_command) == 'function' then
                local args = (low:sub(1, 9) == '/soulhud ') and cmd:sub(10) or ''
                log_msg(soulhud:handle_command(args))
            end
            return true
        end
        if low == '/soulactions status' or low == '/soulactions' then
            print_soulactions_status(false)
            return true
        end
        if low == '/soulactions capabilities' or low == '/soulactions caps' then
            print_soulactions_status(true)
            return true
        end
        if low == '/soulactions reload' then
            if actions then
                local a, v = actions:sync_to_native()
                log_msg(string.format('[soulactions] Reloaded %d actions and %d visibility rules.', a, v))
            end
            return true
        end
        if low == '/soulspire status' or low == '/ss status' then
            print_status()
            return true
        end
        if low == '/soulspire reload' or low == '/ss reload' then
            if vana.soulspire and vana.soulspire.reload then vana.soulspire.reload() end
            local a, v = actions and actions:sync_to_native() or 0, 0
            log_msg(string.format('Reloaded native registries + %d actions + %d visibility rules.', a, v))
            return true
        end
        return false
    end)

    vana.events.on('zone_change', function()
        close_hub('zone_change')
    end)

    vana.events.on('logout', function()
        close_hub('logout')
    end)

    vana.events.on('unload', function()
        close_hub('addon_unload')
        save_core_settings()
        if soulhud then soulhud:save() end
        if assets then assets:release_all() end
    end)
end

return {
    startup_report = startup_report,
    runtime_diag   = runtime_diag,
    open_hub       = open_hub,
    close_hub      = close_hub,
    toggle_hub     = toggle_hub,
    get_state      = function()
        return {
            focus         = focus,
            input         = input,
            character_mod = character_mod,
            weapon_mod    = weapon_mod,
            soul_talents  = soul_talents,
            abilities_mod = abilities_mod,
            status_diag   = status_diag,
            assets        = assets,
            sf_state      = sf_state,
            runtime_diag  = runtime_diag,
        }
    end,
}
