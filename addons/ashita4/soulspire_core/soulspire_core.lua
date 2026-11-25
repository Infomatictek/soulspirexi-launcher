-- SoulspireXI Core: Unified Native-Feeling In-Game UI & Full Gamepad Integration.
--
-- Integrates existing SoulspireXI systems behind one cohesive dark-fantasy interface
-- accessible directly from FFXI's native Commands Menu (or via /soulspire / /ss):
--   - Character / Soul Identity (reuses crystalsocket protocol, state & assets)
--   - Weapon Mastery / The Soulforge (reuses soulspire_talents state, UI & assets)
--   - Soul Talents (live Soul spec loadout, invested nodes & Soul HUD telemetry)
--   - Extensible Dynamic Header driven strictly by core/registry.lua
--
-- Native Menu Integration:
--   Connects directly to soulspire_native.dll (ABI v2) native Commands Menu entry
--   (inserted between Status and Equipment inside FFXI's native menu    menuwind).

addon.name    = 'soulspire_core'
addon.author  = 'SoulspireXI'
addon.version = '1.0.0'
addon.desc    = 'SoulspireXI Core: Unified RPG interface with FFXI Main Menu entry and full gamepad navigation.'
addon.link    = 'https://github.com/Infomatictek/soulspirexi-launcher'

require('common')
local ffi             = require('ffi')
local imgui           = require('imgui')
local Registry        = require('core.registry')
local DataService     = require('core.data_service')
local CharacterState  = require('core.character_state')
local CoreIPC         = require('core.ipc')
local MenuBridge      = require('core.menu_bridge')
local NativeBridge    = require('core.native_bridge')
local Focus           = require('core.focus')
local Input           = require('core.input')
local MouseLifecycle  = require('core.mouse_lifecycle')
local PerfDiag        = require('core.perf_diag')
local Assets          = require('core.assets')
local UI              = require('core.ui')
local WeaponPres      = require('core.weapon_presentation')
local WeaponProbe     = require('core.weapon_render_probe')
local WeaponEquipDiag = require('core.weapon_equip_diag')
local WeaponMastery   = require('modules.weapon_mastery')
local SoulTalents     = require('modules.soul_talents')
local CharacterMod    = require('modules.character')

local registry = Registry.new()
local focus    = Focus.new(registry)
local input    = Input.new()
local weapon_pres = WeaponPres.new()
local data_service = nil
local character_state = nil
local perf_diag = nil
local last_present_clock = nil
local login_span_open = false
local core_open_span_pending = false
local oxtl_ipc_token, oxhud_ipc_token = nil, nil
local menu, assets, ui
local last_synced_equip = { main_id = -1, main_sk = -1, sub_id = -1, sub_sk = -1 }
local sync_local_equipped_weapons_to_native
local sync_native_capabilities_to_server
local mouse_lifecycle = MouseLifecycle.new({
    on_mouse_activity = function(now)
        input:on_mouse_activity(now)
    end,
    on_focus_regain = function()
        if ui and ui.request_window_focus then
            ui:request_window_focus()
        end
    end,
    on_focus_lost = function()
        input:reset()
    end,
})
focus:set_lifecycle_hooks({
    on_hub_open = function(_f, reason)
        if perf_diag and perf_diag.enabled then
            core_open_span_pending = true
            perf_diag:begin_flow('core_ui_open', { scope = 'client_only' })
        end
        mouse_lifecycle:acquire(imgui, reason, os.clock())
    end,
    on_hub_close = function(_f, reason, clear_buttons)
        if perf_diag and perf_diag.enabled then
            if core_open_span_pending then
                core_open_span_pending = false
                perf_diag:end_flow('core_ui_open', 'cancelled', { scope = 'client_only' })
            end
            perf_diag:flush_due(os.clock())
        end
        mouse_lifecycle:release(imgui, reason, os.clock(), clear_buttons == true)
    end,
})
local sf_state, sf_actions, sf_ui, sf_art
local weapon_mastery_mod, soul_talents_mod, character_mod, cs_soul_identity
local ui_font = nil
local last_session_active = false
local watch_menus = false
local last_watched_form = nil
local last_native_probe_at = 0

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

local function sibling_root()
    if type(addon) == 'table' and type(addon.path) == 'string' and addon.path ~= '' then
        return addon.path:gsub('[/\\]+$', ''):gsub('[/\\][^/\\]+$', '')
    end
    return '..'
end

local function load_sibling_lua(sibling_addon, filename)
    local root = sibling_root()
    local dir  = root .. '/' .. sibling_addon
    local full = dir .. '/' .. filename
    local prev_path = package.path
    package.path = dir .. '/?.lua;' .. dir .. '/?/init.lua;' .. prev_path
    local loader, err = loadfile(full)
    if not loader then
        package.path = prev_path
        return nil, err
    end
    local ok, mod = pcall(loader)
    package.path = prev_path
    if not ok then return nil, mod end
    return mod, nil
end

-- Read-only soulspire_native.dll (with legacy crystaljobs.dll fallback) status helper
local crystal_status_t = nil
pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char* name);')
pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void* module, const char* name);')
do
    local okT, stT = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, enabled, hooks, character_id, job, known, branch;
        uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
        uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
    }[1]]=])
    if okT then crystal_status_t = stT end
end
local get_status_sig = nil
pcall(function()
    get_status_sig = ffi.typeof('uint32_t (__stdcall *)(void*, uint32_t)')
end)

local function read_crystaljobs_status()
    if not crystal_status_t or not get_status_sig then return nil end
    local ok, info = pcall(function()
        local mod = ffi.C.GetModuleHandleA('soulspire_native.dll')
        local addr = (mod ~= nil) and ffi.C.GetProcAddress(mod, 'SoulspireNativeGetStatus') or nil
        if addr == nil then
            mod = ffi.C.GetModuleHandleA('crystaljobs.dll')
            addr = (mod ~= nil) and ffi.C.GetProcAddress(mod, 'CrystalJobsGetStatus') or nil
        end
        if addr == nil then return nil end
        local fn = ffi.cast(get_status_sig, addr)
        local st = ffi.new(crystal_status_t)
        if fn(st, ffi.sizeof(st)) ~= 0 or st[0].size ~= 68 or st[0].version ~= 1 then
            return nil
        end
        return {
            enabled = tonumber(st[0].enabled),
            hooks   = tonumber(st[0].hooks),
            job     = tonumber(st[0].job),
            known   = tonumber(st[0].known),
            branch  = tonumber(st[0].branch),
        }
    end)
    return ok and info or nil
end

-- Local preferences (UI scale & configurable input bindings; never touches gameplay)
local function get_settings_path()
    if AshitaCore == nil or not AshitaCore.GetInstallPath then return nil, nil end
    local ok, installPath = pcall(function() return AshitaCore:GetInstallPath() end)
    if not ok or type(installPath) ~= 'string' or installPath == '' then return nil, nil end
    local folder = installPath:gsub('[/\\]+$', '') .. '\\config\\addons\\soulspire_core'
    return folder, folder .. '\\settings.lua'
end

local function serialize_map(tbl)
    local parts = {}
    for k, v in pairs(tbl or {}) do
        if type(k) == 'number' and type(v) == 'string' then
            parts[#parts + 1] = string.format('[%d] = %q', k, v)
        end
    end
    table.sort(parts)
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

local function save_settings()
    pcall(function()
        local folder, path = get_settings_path()
        if not folder or not path then return end
        if ashita and ashita.fs and ashita.fs.exists and ashita.fs.create_directory then
            if not ashita.fs.exists(folder) then
                ashita.fs.create_directory(folder)
            end
        end
        local b = input:get_bindings()
        local f = io.open(path, 'w')
        if f then
            f:write(string.format(
                '-- SoulspireXI Core preferences\nreturn {\n  ui_scale = %.2f,\n  bindings = {\n    keyboard = %s,\n    xinput = %s,\n    dinput = %s,\n  },\n}\n',
                (ui and ui.ui_scale) or 1.0,
                serialize_map(b.keyboard),
                serialize_map(b.xinput),
                serialize_map(b.dinput)
            ))
            f:close()
        end
    end)
end

local function load_settings()
    local loaded_scale = 1.0
    pcall(function()
        local _, path = get_settings_path()
        if not path then return end
        local f = io.open(path, 'r')
        if not f then return end
        f:close()
        local loader = loadfile(path)
        if not loader then return end
        if setfenv then setfenv(loader, {}) end
        local ok, data = pcall(loader)
        if ok and type(data) == 'table' then
            if tonumber(data.ui_scale) then
                loaded_scale = tonumber(data.ui_scale)
            end
            if type(data.bindings) == 'table' then
                input:apply_bindings(data.bindings)
            end
        end
    end)
    return loaded_scale
end

local function is_chat_open()
    local ok, open = pcall(function()
        return AshitaCore:GetChatManager():IsInputOpen() ~= 0
    end)
    return ok and open == true
end

local function is_imgui_text_active()
    local ok, want = pcall(function()
        local io_obj = imgui.GetIO and imgui.GetIO()
        return io_obj ~= nil and io_obj.WantTextInput == true
    end)
    return ok and want == true
end

local function is_player_in_session()
    local ok, active = pcall(function()
        local mem    = AshitaCore:GetMemoryManager()
        local party  = mem and mem:GetParty()
        local player = mem and mem:GetPlayer()
        if not party or not player then return false end
        local sid  = party:GetMemberServerId(0) or 0
        local tidx = party:GetMemberTargetIndex(0) or 0
        local name = party:GetMemberName(0)
        return sid >= 1 and tidx ~= 0 and type(name) == 'string' and name ~= '' and (player:GetMainJob() or 0) > 0
    end)
    return ok and active == true
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

local function push_core_imgui_style()
    local pushed = 0
    if not (imgui.PushStyleColor and imgui.PopStyleColor) then return 0 end
    local function pc(id, col)
        if id ~= nil and col ~= nil then
            imgui.PushStyleColor(id, col)
            pushed = pushed + 1
        end
    end
    pc(ImGuiCol_PopupBg,        { 0.043, 0.063, 0.098, 0.98 })
    pc(ImGuiCol_Border,         { 0.910, 0.741, 0.439, 0.75 })
    pc(ImGuiCol_FrameBg,        { 0.082, 0.098, 0.157, 0.98 })
    pc(ImGuiCol_FrameBgHovered, { 0.125, 0.157, 0.247, 1.00 })
    pc(ImGuiCol_FrameBgActive,  { 0.157, 0.196, 0.302, 1.00 })
    pc(ImGuiCol_Header,         { 0.141, 0.173, 0.267, 0.95 })
    pc(ImGuiCol_HeaderHovered,  { 0.224, 0.812, 0.898, 0.28 })
    pc(ImGuiCol_HeaderActive,   { 0.910, 0.741, 0.439, 0.35 })
    pc(ImGuiCol_CheckMark,      { 0.910, 0.741, 0.439, 1.00 })
    pc(ImGuiCol_Text,           { 0.945, 0.961, 0.976, 1.00 })
    return pushed
end

local function init_modules()
    -- 0. Shared Core Data Service (verified local static JSON cache + diagnostics)
    data_service = DataService.new({
        addon_path = addon.path,
        auto_load  = true,
    })
    if not data_service:is_cache_ready() then
        log('Client cache warning: ' .. tostring(data_service.error_message))
    else
        local info = data_service:get_cache_info()
        log(string.format('Verified client cache %s (schema=v%d hash=%s load=%.1fms)',
            tostring(info.contentVersion), info.schemaVersion, tostring(info.registryHash), info.loadMs))
    end

    -- 0b. Centralized Reactive Character State Service (shared across all Core modules)
    character_state = CharacterState.new({
        data_service  = data_service,
        soul_registry = Registry.souls,
    })

    -- Register process-local packet coexistence tokens so standalone addons never prematurely
    -- block 0x1FD OXTL or 0x017 [OXHUD]| packets before Core receives them.
    oxtl_ipc_token  = CoreIPC.register_listener('OXTL', 'soulspire_core')
    oxhud_ipc_token = CoreIPC.register_listener('OXHUD', 'soulspire_core')

    -- 1. Character / Soul Identity (reuses crystalsocket protocol & state + cached 66-Soul metadata)
    local cs_proto = load_sibling_lua('crystalsocket', 'protocol.lua')
    local cs_state_mod = load_sibling_lua('crystalsocket', 'state.lua')
    cs_soul_identity = load_sibling_lua('crystalsocket', 'soul_identity.lua')
    local cs_state = (cs_state_mod and cs_state_mod.new) and cs_state_mod.new() or nil
    if cs_proto and cs_state then
        character_mod = CharacterMod.new({
            protocol        = cs_proto,
            crystal_state   = cs_state,
            character_state = character_state,
            soul_registry   = Registry.souls,
            data_service    = data_service,
            assets          = assets,
            dll_status_fn   = read_crystaljobs_status,
        })
        registry:attach_controller('character', character_mod, true)
    else
        registry:set_available('character', false, 'CrystalSocket sibling modules unavailable.')
    end

    -- 2. Weapon Mastery (The Soulforge) & 3. Soul Talents (shared soulforge_state + DataService)
    local sf_state_mod = load_sibling_lua('soulspire_talents', 'soulforge_state.lua')
    local ws_reg       = load_sibling_lua('soulspire_talents', 'ws_registry_generated.lua')
    sf_art             = load_sibling_lua('soulspire_talents', 'art.lua')
    if sf_art then
        if sf_art.setRoot then
            sf_art.setRoot(sibling_root() .. '/soulspire_talents')
        end
        -- Ensure soulforge_ui.lua's require('art') reuses this rooted instance
        package.loaded['art'] = sf_art
    end
    sf_ui = load_sibling_lua('soulspire_talents', 'soulforge_ui.lua')

    if sf_state_mod and sf_ui then
        sf_state, sf_actions = sf_state_mod.new({
            soulRegistry = Registry.souls,
            wsRegistry   = ws_reg,
            dataService  = data_service,
            savePrefs    = save_settings,
            onMeta       = function(st)
                if character_state then
                    character_state:observe_oxtl_meta(st)
                end
            end,
        })
        weapon_mastery_mod = WeaponMastery.new(sf_state, sf_actions, sf_ui)
        registry:attach_controller('weapon_mastery', weapon_mastery_mod, true)

        soul_talents_mod = SoulTalents.new(sf_state, sf_actions, sf_ui, {
            soul_registry = Registry.souls,
            data_service  = data_service,
            assets        = assets,
            on_jump_to_ws = function(ws_id, node_key)
                focus:select_module('weapon_mastery')
                weapon_mastery_mod:focus_ws_and_node(ws_id, node_key)
            end,
        })
        registry:attach_controller('soul_talents', soul_talents_mod, true)
    else
        registry:set_available('weapon_mastery', false, 'Soulforge sibling modules unavailable.')
        registry:set_available('soul_talents', false, 'Soulforge sibling modules unavailable.')
    end

    -- Subscribe all Core modules to reactive CharacterState transitions (0ms UI updates + forced sync)
    character_state:subscribe(function(ev)
        if sf_actions and sf_actions.applyCharacterState then
            sf_actions.applyCharacterState(ev.cur, ev)
        end
        if ev.affects_crystals and ev.source ~= 'crys_state' and character_mod then
            character_mod:refresh_player_context()
            if character_mod.crystal_state then
                character_mod.crystal_state.needs_refresh = true
            end
            local active_mod = focus:active_module()
            if focus:is_hub_open() and active_mod and active_mod.id == 'character' then
                character_mod:sync(false)
            end
        end
    end)
end

ashita.events.register('load', 'soulspire_core_load', function()
    local saved_scale = load_settings()
    assets = Assets.new(addon.path)
    perf_diag = PerfDiag.new({ addon_path = addon.path })
    perf_diag:load_config()
    if perf_diag.enabled then
        perf_diag:begin_flow('character_init', { scope = 'client_only' })
    end
    if type(addon.path) == 'string' and addon.path ~= '' then
        local sep = addon.path:find('\\', 1, true) and '\\' or '/'
        local base_dir = addon.path:gsub('[/\\]+$', '')
        local ashita_root = base_dir .. sep .. '..' .. sep .. '..'
        local data_dir = ashita_root .. sep .. 'plugins' .. sep .. 'data' .. sep
        weapon_pres.ashita_root_dir = ashita_root
        weapon_pres.config_path = data_dir .. 'soul-weapon-config.json'
        weapon_pres.calibration_path = data_dir .. 'soul-weapon-calibration.local.json'
        weapon_pres.probe_output_dir = data_dir
        weapon_pres.probe_output_path = data_dir .. 'soul-weapon-render-probe.local.json'
        weapon_pres.equip_diag_output_path = data_dir .. 'soul-weapon-equip-diag.local.json'
        safe_call('weapon_pres.load_file', function() weapon_pres:load_file() end)
    end
    init_modules()
    perf_diag.data_service = data_service
    perf_diag.character_state = character_state
    if perf_diag.enabled then
        perf_diag:_attach_listeners()
        perf_diag:end_flow('character_init', 'complete', { scope = 'client_only' })
        login_span_open = true
        perf_diag:begin_flow('login', { scope = 'client_plus_server_rtt' })
    end

    if imgui.AddFontFromFileTTF then
        for _, fontPath in ipairs({ 'C:\\Windows\\Fonts\\segoeui.ttf', 'C:\\Windows\\Fonts\\arial.ttf' }) do
            local okF, f = pcall(imgui.AddFontFromFileTTF, fontPath, 20)
            if okF and f ~= nil then
                ui_font = f
                break
            end
        end
    end

    local ok, scaling = pcall(require, 'scaling')
    local ptr_ok, operand = pcall(function()
        return AshitaCore:GetPointerManager():Get('menu')
    end)
    if ok and scaling and scaling.scaled and scaling.scaled.w > 0 and scaling.scaled.h > 0 and ptr_ok and operand then
        menu = MenuBridge.new(ashita.memory, scaling, operand)
    else
        menu = MenuBridge.new(nil, nil, nil)
    end

    ui = UI.new(imgui, registry, focus, assets, {
        ui_scale        = saved_scale,
        on_scale_change = function() save_settings() end,
        get_last_device = function() return input and input.last_device or 'gamepad' end,
        get_identity    = function()
            if character_state then
                local id = character_state:get_header_identity()
                if id and id.job_key and id.job_key ~= '---' then
                    return id
                end
            end
            if character_mod then
                return character_mod:get_header_identity()
            end
            return nil
        end,
    })

    last_session_active = is_player_in_session()
    if not menu or not menu.native_hook_supported then
        local detail = menu and menu.native_hook_reason or 'unavailable'
        log('Waiting for soulspire_native.dll native Commands menu hook (' .. tostring(detail) .. '); /soulspire remains available.')
    end
end)

ashita.events.register('unload', 'soulspire_core_unload', function()
    if perf_diag then
        perf_diag:shutdown(os.clock())
    end
    if oxtl_ipc_token then
        CoreIPC.unregister_listener(oxtl_ipc_token)
        oxtl_ipc_token = nil
    end
    if oxhud_ipc_token then
        CoreIPC.unregister_listener(oxhud_ipc_token)
        oxhud_ipc_token = nil
    end
    save_settings()
    focus:blur_all('unload')
    mouse_lifecycle:release(imgui, 'unload', os.clock(), true)
    input:reset()
    if sf_art and sf_art.clear then pcall(sf_art.clear) end
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
        local idx = (rest ~= '') and registry:find_index(rest) or focus.active_index
        focus:open_hub(idx or 1, false)
    elseif sub == 'close' then
        focus:close_hub(current_native_menu())
    elseif sub == 'scale' then
        local n = tonumber(rest)
        if n and ui then
            ui:set_scale(n)
            log(string.format('Core UI scale set to %d%%.', math.floor(ui.ui_scale * 100 + 0.5)))
        else
            log('Usage: /soulspire scale <0.75-1.50>')
        end
    elseif sub == 'bind' then
        if rest == 'reset' then
            input:reset_bindings()
            save_settings()
            log('Input bindings reset to defaults.')
        else
            local dev, act, code = rest:match('^(%S+)%s+(%S+)%s+(%S+)$')
            if dev and act and code and input:set_binding(dev, act, tonumber(code)) then
                save_settings()
                log(('Bound %s code %s -> %s'):format(dev, code, act))
            else
                log('Usage: /soulspire bind <keyboard|xinput|dinput> <action> <code>  |  /soulspire bind reset')
            end
        end
    elseif sub == 'bindings' then
        local b = input:get_bindings()
        log('Keyboard bindings: ' .. serialize_map(b.keyboard))
        log('XInput bindings:   ' .. serialize_map(b.xinput))
        log('DInput bindings:   ' .. serialize_map(b.dinput))
    elseif sub == 'status' then
        if menu then menu:refresh_native_status() end
        local native = current_native_menu()
        local active = focus:active_module()
        local diag = menu and menu:diagnostics() or { mode = 'standalone', bridge_available = false, native_hook_supported = false, native_hook_reason = 'menu_bridge_nil' }
        local sn, sn_err = NativeBridge.query()
        local mm, mm_err = NativeBridge.main_menu_status()
        local line1 = ('version=%s mode=%s native_hook=%s bridge=%s modules=%d(%d live) hub_open=%s active=%s native_form=%s'):format(
            addon.version,
            tostring(diag.mode),
            tostring(diag.native_hook_supported),
            tostring(diag.bridge_available),
            registry:count(),
            #registry:available_modules(),
            tostring(focus.hub_open),
            tostring(active and active.id or 'none'),
            tostring(native and native.name or 'none')
        )
        local line2 = ('native_hook_reason=%s last_action=%s last_device=%s ui_scale=%.2f sf_synced=%s sf_cat=%d sf_eq=%d/%d sf_filt=%d'):format(
            tostring(diag.native_hook_reason),
            tostring(focus.last_action),
            tostring(input.last_device),
            tonumber(ui and ui.ui_scale or 1.0),
            tostring(sf_state ~= nil and sf_state.synced == true),
            sf_state and #(sf_state.catalog or {}) or 0,
            sf_state and (tonumber(sf_state.mainSkill) or 0) or 0,
            sf_state and (tonumber(sf_state.rangedSkill) or 0) or 0,
            sf_state and (tonumber(sf_state.selectedSkill) or -1) or -1
        )
        log(line1)
        log(line2)
        local line3 = ''
        if sn then
            line3 = ('soulspire_native abi=v%d hooks=%d/%d caps=0x%05X modules=0x%02X/0x%02X banks=%d/%d hash=%s'):format(
                sn.abi_version, sn.installed_hooks, sn.expected_hooks, sn.capabilities,
                sn.active_modules_mask, sn.enabled_modules_mask,
                sn.menu2fon_banks_used, sn.menu2fon_banks_max, sn.registry_hash)
            log(line3)
        else
            line3 = 'soulspire_native unavailable: ' .. tostring(sn_err)
            log(line3)
        end
        local line4 = ''
        if mm then
            line4 = ('commands_menu hooks=%s injected=%s btn=%d count=%d frame_h=%d sprite=%s open_inj=%d nav=%d act=%d pending=%d'):format(
                tostring(mm.hooks_installed), tostring(mm.injected), mm.button_id, mm.button_count,
                mm.frame_height, tostring(mm.sprite_synthesized), mm.open_injections,
                mm.nav_overrides, mm.activations, mm.pending_open_requests)
            log(line4)
        else
            line4 = 'commands_menu unavailable: ' .. tostring(mm_err)
            log(line4)
        end
        local line5 = ''
        if data_service then
            local diag_ds = data_service:get_diagnostics()
            local c = diag_ds.cache
            local m = diag_ds.metrics
            local st_sync = diag_ds.syncStats or {}
            line5 = ('cache status=%s compat=%s schema=v%d proto=v%d ver=%s reg=%s load=%.1fms wait=%s oxtl_rx=%d(%dB) crys_rx=%d(%dB) retries=%d timeouts=%d stale=%d dedup=%d avg=%.1fms p95=%.1fms'):format(
                tostring(c.status), tostring(c.compatState), c.schemaVersion or 0,
                sf_state and (sf_state.protocolVersion or 1) or 1,
                tostring(c.contentVersion), tostring(c.registryHash), tonumber(c.loadMs) or 0,
                tostring(sf_state and sf_state.waitingOn or 'idle'),
                m.packets_in_oxtl or 0, m.bytes_in_oxtl or 0,
                m.packets_in_crys or 0, m.bytes_in_crys or 0,
                m.sync_retries or 0, m.timeouts or 0,
                m.stale_dropped or 0, m.deduped_requests or 0,
                tonumber(st_sync.avgLatencyMs) or 0, tonumber(st_sync.p95LatencyMs) or 0
            )
            log(line5)
        end
        local line6 = mouse_lifecycle:format_status_line()
        log(line6)
        if type(addon.path) == 'string' and addon.path ~= '' then
            pcall(function()
                local f = io.open(addon.path:gsub('[/\\]+$', '') .. '/soulspire_core-status.log', 'w')
                if f then
                    f:write('[soulspire_core] ' .. line1 .. '\n[soulspire_core] ' .. line2 .. '\n[soulspire_core] ' .. line3 .. '\n[soulspire_core] ' .. line4 .. '\n[soulspire_core] ' .. line5 .. '\n[soulspire_core] ' .. line6 .. '\n')
                    f:close()
                end
            end)
        end
    elseif sub == 'inputdiag' then
        local d = mouse_lifecycle:diagnostics()
        log(mouse_lifecycle:format_status_line())
        log(('input_counters last_device=%s fallback_activations=%d blocked_mouse=%d absorbed_releases=%d held_core_buttons=%s'):format(
            tostring(input.last_device),
            d.fallback_activations or 0,
            d.blocked_mouse_events,
            d.absorbed_release_events,
            tostring(mouse_lifecycle:has_held_core_buttons())
        ))
        for _, tr in ipairs(d.transitions or {}) do
            log(('  [%.2fs] %s -> %s (%s)'):format(tr.at or 0, tr.from_owner, tr.to_owner, tr.reason))
        end
    elseif sub == 'cache' then
        if not data_service then
            log('DataService not initialized.')
            return
        end
        if rest == 'verify' then
            local okV, errV = data_service:verify_all()
            log(okV and 'Cache SHA-256 verification PASSED for all packages.' or ('Cache verification FAILED: ' .. tostring(errV)))
        end
        local diag_ds = data_service:get_diagnostics()
        local c = diag_ds.cache
        log(('cache status=%s compat=%s schema=v%d ver=%s reg=%s load=%.1fms err=%s'):format(
            tostring(c.status), tostring(c.compatState), c.schemaVersion or 0,
            tostring(c.contentVersion), tostring(c.registryHash), tonumber(c.loadMs) or 0,
            tostring(c.error or 'none')))
        for _, ev in ipairs(diag_ds.recentEvents or {}) do
            log(('  [%.2fs] %s/%s: %s'):format(ev.at or 0, ev.domain, ev.kind, ev.detail))
        end
    elseif sub == 'syncdiag' then
        if not data_service then
            log('DataService not initialized.')
            return
        end
        local diag_ds = data_service:get_diagnostics()
        local c = diag_ds.cache
        local m = diag_ds.metrics
        local ss = diag_ds.syncStats or {}
        local ws_st = diag_ds.warmupStats or {}
        local cs_snap = character_state and character_state:get_snapshot() or nil
        log(('syncdiag proto=v%d v2Confirmed=%s cache=%s/%s talentsWarm=%s(frames=%d max=%.2fms) char=%s/%s(%s) wait=%s avg=%.1fms p95=%.1fms max=%.1fms ok=%d fail=%d retries=%d timeouts=%d stale=%d dedup=%d oxtl_in=%d(%dB) oxtl_out=%d'):format(
            sf_state and (sf_state.protocolVersion or 1) or 1,
            tostring(sf_state and sf_state.v2Confirmed == true),
            tostring(c.status), tostring(c.compatState),
            tostring(data_service:is_talents_warm()),
            tonumber(ws_st.frames) or 0, tonumber(ws_st.maxFrameMs) or 0,
            tostring(cs_snap and cs_snap.main_job_key or '---'),
            tostring(cs_snap and cs_snap.level_label or 'Lv.0'),
            tostring(cs_snap and cs_snap.soul_name or 'Base'),
            tostring(sf_state and sf_state.waitingOn or 'idle'),
            tonumber(ss.avgLatencyMs) or 0, tonumber(ss.p95LatencyMs) or 0, tonumber(ss.maxLatencyMs) or 0,
            tonumber(ss.completedCount) or 0, tonumber(ss.failureCount) or 0,
            m.sync_retries or 0, m.timeouts or 0, m.stale_dropped or 0, m.deduped_requests or 0,
            m.packets_in_oxtl or 0, m.bytes_in_oxtl or 0, m.packets_out_oxtl or 0
        ))
        local logList = diag_ds.syncLog or {}
        local firstIdx = math.max(1, #logList - 7)
        for i = firstIdx, #logList do
            local r = logList[i]
            log(('  [%.2fs] req=%d op=%s ws=%d out=%s lat=%.1fms pkts=%d bytes=%d ret=%d cache=%s proto=v%d reason=%s'):format(
                r.completedAt or 0, r.reqId or 0, tostring(r.op), r.wsId or 0, tostring(r.outcome),
                r.latencyMs or 0, r.packetsIn or 0, r.bytesIn or 0, r.retries or 0,
                tostring(r.cacheHit), r.protocolVersion or 1, tostring(r.timeoutReason or 'none')
            ))
        end
    elseif sub == 'debug' then
        if not menu or not menu:is_available() then
            log('MenuBridge unavailable.')
            return
        end
        local diag = menu:diagnostics()
        log(('mode=%s native_hook=%s reason=%s'):format(
            tostring(diag.mode), tostring(diag.native_hook_supported), tostring(diag.native_hook_reason)))
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
                local clr = WeaponProbe.clear_snapshots()
                log(('Weapon render probe comparative snapshots CLEARED (removed=%d probe=%s loaded=%s).'):format(
                    (type(clr) == 'table' and clr.cleared_count) or 0,
                    tostring(WeaponProbe.PROBE_VERSION or 'unknown'),
                    tostring(WeaponProbe.LOADED_LUA_PATH or 'unknown')))
            else
                local ok, res, out_path = WeaponProbe.run_live_probe({
                    diagnostics_enabled = weapon_pres:is_diagnostics_enabled(),
                    output_dir = weapon_pres.probe_output_dir,
                    ashita_root_dir = weapon_pres.ashita_root_dir,
                    label = (label ~= '') and label or nil,
                })
                if ok and type(res) == 'table' then
                    local total = 0
                    for _, f in ipairs(res.findings or {}) do total = total + (f.match_count or 0) end
                    local snaps = #(res.comparative_snapshots or {})
                    local diffs = #(res.comparative_diff or {})
                    local prov = res.provenance or {}
                    log(('Weapon render probe COMPLETE [%s]: id=%s utc=%s probe=%s manifest=%s findings=%d snapshots=%d diffs=%d'):format(
                        (label ~= '' and label or ('snap_' .. snaps)),
                        tostring(prov.capture_id or 'none'),
                        tostring(prov.generated_at_utc or 'unknown'),
                        tostring(prov.probe_version or 'unknown'),
                        tostring(prov.active_launcher_manifest_version or 'unavailable'),
                        total, snaps, diffs))
                    log(('Probe output=%s | loaded=%s | dll=%s'):format(
                        tostring(out_path),
                        tostring(prov.loaded_lua_path or 'unknown'),
                        tostring(prov.native_dll_version or 'unavailable')))
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
            local wod, wod_err = NativeBridge.query_weapon_offhand_diag()
            if wod then
                log(('Offhand bone diag: hooks=%d/3(mask=0x%X) cap=%s authSub=%d(slot7=%d) regMesh=%d(tot=%d,add=%d) matchDraw=%d(tot=%d) swaps=%d failLookup=%d restores=%d bones(7E=%d,7F=%d,distinct=%s)'):format(
                    wod.hooks_installed_count, wod.hooks_installed_mask, tostring(wod.cap_active),
                    wod.authorized_sub_attaches, wod.attach_calls_slot7,
                    wod.registered_sub_meshes, wod.registered_sub_total, wod.add_mesh_calls_total,
                    wod.matching_mesh_draws, wod.draw_calls_total,
                    wod.bone_swaps_succeeded, wod.bone_lookups_failed, wod.bone_restores_count,
                    wod.last_idx_main, wod.last_idx_sub, tostring(wod.last_matrices_distinct)))
            else
                log('Offhand bone diag unavailable: ' .. tostring(wod_err))
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
    elseif sub == 'perfdiag' then
        if not perf_diag then
            perf_diag = PerfDiag.new({ addon_path = addon.path, data_service = data_service, character_state = character_state })
        end
        local act = (rest or ''):gsub('^%s+', ''):gsub('%s+$', ''):lower()
        if act == 'on' then
            perf_diag:set_enabled(true, true)
            log('Performance diagnostics ENABLED (' .. perf_diag:format_status_line() .. ')')
        elseif act == 'off' then
            perf_diag:interrupt_inflight('cancelled')
            perf_diag:export_bundle(os.clock())
            perf_diag:set_enabled(false, true)
            log('Performance diagnostics DISABLED (config saved; last snapshot flushed).')
        elseif act == 'export' then
            local ok_e, exp_or_err, nbytes = perf_diag:export_bundle(os.clock())
            if ok_e then
                log(('Exported Core performance bundle (%d bytes): %s'):format(tonumber(nbytes) or 0, tostring(exp_or_err)))
            else
                log('PerfDiag export failed: ' .. tostring(exp_or_err))
            end
        else
            log(perf_diag:format_status_line() .. ' (usage: /soulspire perfdiag on|off|status|export)')
        end
    elseif sub == 'watch' then
        watch_menus = not watch_menus
        last_watched_form = nil
        log('Menu form watch ' .. (watch_menus and 'ENABLED (open FFXI Main Menu to log its exact form name)' or 'DISABLED'))
    else
        log('Commands: /soulspire [open [module] | close | scale <n> | bind | bindings | status | inputdiag | syncdiag | perfdiag | cache | debug | watch | weapondiag] (alias: /ss)')
    end
end)

-- Mouse events: balanced input ownership so clicks/drags/wheel never leak into
-- FFXI behind Core, trailing close-button releases are absorbed cleanly, and
-- gamepad -> mouse transitions immediately restore mouse responsiveness.
ashita.events.register('mouse', 'soulspire_core_mouse', function(e)
    if mouse_lifecycle:on_mouse_event(e, focus:is_hub_open(), imgui, os.clock()) then
        e.blocked = true
    end
end)

-- Keyboard events: block both key_data and writable key_state buffer.
ashita.events.register('key_data', 'soulspire_core_key_data', function(e)
    local hub_open = focus:is_hub_open()
    if input:on_key(e.key, e.down, is_chat_open(), dispatch_action, hub_open, is_imgui_text_active()) then
        e.blocked = true
    end
end)

ashita.events.register('key_state', 'soulspire_core_key_state', function(e)
    if not e.data_raw or e.size < 212 then return end
    local data = ffi.cast('uint8_t*', e.data_raw)
    local chat_open = is_chat_open()
    local hub_open  = focus:is_hub_open()
    local text_open = is_imgui_text_active()
    for scan in pairs(input:watched_keys()) do
        if data[scan] == 0 then
            input:release_key(scan)
        elseif input:on_key(scan, true, chat_open, dispatch_action, hub_open, text_open) then
            data[scan] = 0
        end
    end
end)

-- XInput controller button, axis, and raw state capture.
ashita.events.register('xinput_button', 'soulspire_core_xinput_button', function(e)
    local hub_open = focus:is_hub_open()
    if e.button == Input.XINPUT_AXIS_LX or e.button == Input.XINPUT_AXIS_LY then
        if input:on_xinput_axis(e.button, e.state, dispatch_action, hub_open) then
            e.blocked = true
        end
        return
    end
    local down = (e.state ~= nil and e.state ~= 0)
    if input:on_pad('xinput', e.button, down, dispatch_action, hub_open) then
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

ashita.events.register('xinput_state', 'soulspire_core_xinput_state', function(e)
    local hub_open = focus:is_hub_open()
    if input:filter_xinput_state(e.state, e.state_modified, dispatch_action, hub_open) then
        if e.blocked ~= nil then e.blocked = true end
    end
end)

-- DirectInput controller button, POV hat, and raw state capture.
ashita.events.register('dinput_button', 'soulspire_core_dinput_button', function(e)
    local hub_open = focus:is_hub_open()
    if e.button == 32 or e.button == 33 or e.button == 34 or e.button == 35 then
        if input:on_dinput_pov(e.state, dispatch_action, hub_open) then
            e.blocked = true
        end
        return
    end
    local down = (e.state ~= nil and e.state ~= 0)
    if input:on_pad('dinput', e.button, down, dispatch_action, hub_open) then
        e.blocked = true
    end
end)

ashita.events.register('dinput_state', 'soulspire_core_dinput_state', function(e)
    local hub_open = focus:is_hub_open()
    if input:filter_dinput_state(e.state or e.data_raw, e.state_modified or e.data_modified, dispatch_action, hub_open) then
        if e.blocked ~= nil then e.blocked = true end
    end
end)

-- Packet synchronization, native weapon sync, & safe zone/logout lifecycle handling.
ashita.events.register('packet_in', 'soulspire_core_packet_in', function(e)
    if type(e) ~= 'table' then return end
    local buf = e.data_modified or e.data
    local diag_on = perf_diag ~= nil and perf_diag.enabled
    if e.id == 0x00A or e.id == 0x00B then
        focus:blur_all('zone_change')
        input:reset()
        safe_call('weapon_pres.reset_peers', function() weapon_pres:reset_peers() end)
        caps_sent_this_zone = false
        if e.id == 0x00A then
            caps_pending_zone = true
            safe_call('native.sync_equipped', function() sync_local_equipped_weapons_to_native(true) end)
            if diag_on then
                perf_diag:end_flow('zone_transition', 'complete', { scope = 'client_plus_server_rtt' })
            end
        elseif diag_on then
            perf_diag:interrupt_inflight('zone_change')
            perf_diag:begin_flow('zone_transition', { scope = 'client_plus_server_rtt' })
            perf_diag:export_bundle(os.clock())
        end
        if sf_actions and sf_actions.invalidate then
            sf_actions.invalidate('zone_change')
        elseif sf_state then
            sf_state.needsRefresh = true
        end
        if character_state then
            character_state:observe_packet_in(e.id, buf, e.size, os.clock())
        end
        return
    end

    if e.id == 0x01D or e.id == 0x00D then
        safe_call('native.sync_equipped', function() sync_local_equipped_weapons_to_native(false) end)
        if caps_pending_zone and not caps_sent_this_zone then
            safe_call('native.sync_caps', sync_native_capabilities_to_server)
        end
    end

    if e.id == 0x050 then
        safe_call('native.sync_equipped_0x050', function()
            if not sync_local_equipped_from_packet_0x050(buf) then
                sync_local_equipped_weapons_to_native(false)
            end
        end)
        if weapon_pres:is_diagnostics_enabled() then
            local now_sec = now_seconds()
            safe_call('weapon_equip_diag.packet_in', function()
                local rec = WeaponEquipDiag.observe_equip_packet('in', buf, now_sec)
                if rec then
                    log(('[weapondiag] S2C 0x050 equip_slot=%d inv_idx=%d container=%d'):format(
                        rec.equipSlot, rec.invIndex, rec.container))
                end
            end)
        end
    end

    if character_state and (e.id == 0x061 or e.id == 0x01B or e.id == 0x0DF or e.id == 0x0DD or e.id == 0x063) then
        character_state:observe_packet_in(e.id, buf, e.size, os.clock())
        return
    end

    if sf_actions and sf_actions.handlePacketIn(e.id, buf, e.size) then
        if CoreIPC.should_block(oxtl_ipc_token) then
            e.blocked = true
        end
        return
    end

    if character_mod and e.id == 0x1FF and type(buf) == 'string' then
        if character_mod:handle_packet_in(e.id, buf, nil, e.size) then
            e.blocked = true
        end
        return
    end

    if e.id == 0x1FC then
        local t_hud0 = diag_on and perf_diag.clock() or 0
        local now_sec = now_seconds()
        safe_call('weapon_pres.observe_oxsi_packet', function()
            local peer = weapon_pres:observe_oxsi_packet(buf, now_sec)
            if type(peer) == 'table' and tonumber(peer.actor_id) then
                NativeBridge.upsert_peer_soul(peer.actor_id, peer.job or 0, peer.branch or 0, peer.effective_level or 0)
            end
        end)
        if character_mod and cs_soul_identity and cs_soul_identity.decode and type(buf) == 'string' then
            character_mod:refresh_player_context()
            local info = character_mod.player_info
            local job_id = info and info.main_job or (character_state and character_state.main_job) or 0
            local decoded = cs_soul_identity.decode(buf, job_id)
            if decoded then
                character_mod:observe_hud_identity(decoded.branch, job_id)
            end
        end
        if diag_on then
            perf_diag:record_flow('soul_hud', (perf_diag.clock() - t_hud0) * 1000.0, 'complete', { scope = 'client_plus_server_rtt', packets_in = 1, bytes_in = tonumber(e.size) or (type(buf) == 'string' and #buf or 0) })
        end
        return
    end

    if e.id == 0x017 and type(buf) == 'string' and #buf >= 25 then
        local msg = string.sub(buf, 24):match('^([^%z]*)')
        if msg then
            if string.sub(msg, 1, 8) == '[OXHUD]|' then
                local t_oxh0 = diag_on and perf_diag.clock() or 0
                if soul_talents_mod then
                    soul_talents_mod:observe_hud_line(string.sub(msg, 9))
                end
                if CoreIPC.should_block(oxhud_ipc_token) then
                    e.blocked = true
                end
                if diag_on then
                    perf_diag:record_flow('soul_hud', (perf_diag.clock() - t_oxh0) * 1000.0, 'complete', { scope = 'client_plus_server_rtt', packets_in = 1, bytes_in = #msg })
                end
            elseif string.sub(msg, 1, 8) == '[OXMOB]|' then
                -- Suppress internal Soulspire mob-status transport frames so they never leak into
                -- normal player chat when kazenoeye is not loaded (kazenoeye loads before core when enabled).
                e.blocked = true
            end
        end
    end
end)

ashita.events.register('packet_out', 'soulspire_core_packet_out', function(e)
    if type(e) ~= 'table' then return end
    if e.id == 0x00D then
        if perf_diag and perf_diag.enabled then
            perf_diag:interrupt_inflight('logout')
            perf_diag:export_bundle(os.clock())
        end
        focus:blur_all('logout')
        input:reset()
        if sf_actions and sf_actions.invalidate then
            sf_actions.invalidate('logout')
        end
        if character_state then
            character_state:invalidate('logout', os.clock())
        end
    elseif e.id == 0x050 and weapon_pres:is_diagnostics_enabled() then
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

    local now = os.clock()
    local in_session = is_player_in_session()
    local diag_on = perf_diag ~= nil and perf_diag.enabled
    local frame_ms = nil
    if diag_on then
        if last_present_clock ~= nil then
            frame_ms = math.max(0, (now - last_present_clock) * 1000.0)
        end
        last_present_clock = now
        if login_span_open and in_session then
            login_span_open = false
            perf_diag:end_flow('login', 'complete', { scope = 'client_plus_server_rtt' })
        end
    end
    safe_call('native.sync_equipped_tick', function()
        sync_local_equipped_weapons_to_native(false)
        if not caps_sent_this_zone and is_local_player_in_game() then
            sync_native_capabilities_to_server()
        end
    end)

    if last_session_active and not in_session then
        focus:blur_all('disconnect')
        input:reset()
        if sf_actions and sf_actions.invalidate then
            sf_actions.invalidate('disconnect')
        end
        if character_state then
            character_state:invalidate('disconnect', now)
        end
    end
    last_session_active = in_session

    -- Continuously synchronize centralized CharacterState (actual level, Level Sync, job,
    -- subjob, equipped weapon, zone, reconnect) EVEN while Core is closed or on another tab!
    if character_state then
        character_state:poll_memory(now)
    end

    -- Re-probe soulspire_native.dll if it finished Direct3D initialization after addon load.
    if menu and not menu.native_hook_supported and (now - last_native_probe_at) >= 0.5 then
        last_native_probe_at = now
        menu:refresh_native_status()
    end

    -- Dispatch native FFXI Commands menu "Soulspire" (Btn 16) confirm requests into Core.
    local open_requests = menu and menu:consume_native_open_request() or NativeBridge.consume_core_open_request()
    if open_requests > 0 then
        if menu and not menu.native_hook_supported then
            menu:refresh_native_status()
        end
        focus:open_from_native_menu(focus.active_index)
        input:arm_open_guard(0.20)
    end

    -- Reconcile mouse/cursor ownership and Windows focus (Alt+Tab suspend/resume)
    -- on every frame without ever calling Win32 ShowCursor per-frame.
    mouse_lifecycle:tick_present(imgui, focus:is_hub_open(), now)

    -- Cooperative background warmup for talents.json (<=4ms/frame across read, SHA-256, and JSON parse)
    -- so opening Weapon Mastery displays cached trees instantaneously with zero main-thread stutter.
    if data_service and data_service.step_warmup and data_service:is_cache_usable() and not data_service:is_talents_warm() then
        data_service:step_warmup(4.0)
    end

    -- Keep shared Soulforge & Character state lifecycles in sync with bounded retry/timeout ticking
    if character_mod and character_mod.tick then
        character_mod:tick(now)
    end
    if sf_state and sf_actions then
        if sf_actions.tick then
            sf_actions.tick(now)
        end
        local active_mod = focus:active_module()
        local sf_active = focus:is_hub_open() and active_mod ~= nil
            and (active_mod.id == 'weapon_mastery' or active_mod.id == 'soul_talents')
        sf_state.open[1] = sf_active

        if in_session and sf_active then
            if (not sf_state.synced and sf_state.syncPending == nil and sf_state.lastSyncError == nil)
                and (now - (sf_state.syncRequestedAt or 0)) >= 4.0 then
                sf_actions.sync()
            elseif sf_state.needsRefresh and sf_state.syncPending == nil then
                sf_actions.refreshState(true)
            end
        end
    end

    -- Pump hold-to-repeat for D-Pad / Left Stick / Arrow keys while Core Hub is open and focused
    input:tick(now, dispatch_action, focus:is_hub_open() and mouse_lifecycle.window_focused)

    local native = current_native_menu()
    if watch_menus and menu and menu:is_available() then
        local snap = menu:inspect_all()
        local cur_name = snap and snap.current_name or 'none'
        if cur_name ~= last_watched_form then
            last_watched_form = cur_name
            local cur_rect = ''
            if snap and snap.windows then
                for _, win in ipairs(snap.windows) do
                    if win.is_current then
                        cur_rect = (' rect=(%d,%d,%d,%d)'):format(win.left, win.top, win.right, win.bottom)
                        break
                    end
                end
            end
            log(('watch: current="%s"%s matched_main=%s'):format(tostring(cur_name), cur_rect, tostring(native ~= nil)))
        end
    end
    local mode = menu and menu:get_mode() or 'standalone'

    local pushed = push_core_imgui_style()
    local font_pushed = false
    if ui_font ~= nil and imgui.PushFont then
        font_pushed = pcall(imgui.PushFont, ui_font, math.floor(19 * (ui.ui_scale or 1.0) + 0.5))
    end

    local ui_draw_t0 = diag_on and perf_diag.clock() or 0
    local okDraw, errDraw = xpcall(function()
        ui:draw(native, mode)
    end, debug.traceback)
    if not okDraw then
        log('Render error: ' .. tostring(errDraw))
    end
    if diag_on then
        local draw_ms = math.max(0, (perf_diag.clock() - ui_draw_t0) * 1000.0)
        if core_open_span_pending and focus:is_hub_open() then
            core_open_span_pending = false
            perf_diag:end_flow('core_ui_open', 'complete', { scope = 'client_only' })
        end
        perf_diag:observe_menu_form(native and native.name or '')
        if frame_ms ~= nil then
            perf_diag:record_frame(frame_ms, draw_ms)
        end
        perf_diag:flush_due(now)
    end

    if font_pushed and imgui.PopFont then
        imgui.PopFont()
    end
    if pushed > 0 then
        imgui.PopStyleColor(pushed)
    end
    if weapon_pres:is_diagnostics_enabled() then
        safe_call('weapon_pres.draw_diagnostics_panel', function()
            weapon_pres:draw_diagnostics_panel(imgui)
        end)
    end
end)
