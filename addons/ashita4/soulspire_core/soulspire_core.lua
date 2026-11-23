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
local ffi           = require('ffi')
local imgui         = require('imgui')
local Registry      = require('core.registry')
local MenuBridge    = require('core.menu_bridge')
local NativeBridge  = require('core.native_bridge')
local Focus         = require('core.focus')
local Input         = require('core.input')
local Assets        = require('core.assets')
local UI            = require('core.ui')
local WeaponMastery = require('modules.weapon_mastery')
local SoulTalents   = require('modules.soul_talents')
local CharacterMod  = require('modules.character')

local registry = Registry.new()
local focus    = Focus.new(registry)
local input    = Input.new()
local menu, assets, ui
local sf_state, sf_actions, sf_ui, sf_art
local weapon_mastery_mod, soul_talents_mod, character_mod, cs_soul_identity
local ui_font = nil
local last_session_active = false
local watch_menus = false
local last_watched_form = nil

local function log(msg)
    print('[soulspire_core] ' .. tostring(msg))
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

-- Read-only crystaljobs.dll status helper (zero memory writes, never interferes with hooks)
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
        local mod = ffi.C.GetModuleHandleA('crystaljobs.dll')
        if mod == nil then return nil end
        local addr = ffi.C.GetProcAddress(mod, 'CrystalJobsGetStatus')
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
    -- 1. Character / Soul Identity (reuses crystalsocket protocol & state)
    local cs_proto = load_sibling_lua('crystalsocket', 'protocol.lua')
    local cs_state_mod = load_sibling_lua('crystalsocket', 'state.lua')
    cs_soul_identity = load_sibling_lua('crystalsocket', 'soul_identity.lua')
    local cs_state = (cs_state_mod and cs_state_mod.new) and cs_state_mod.new() or nil
    if cs_proto and cs_state then
        character_mod = CharacterMod.new({
            protocol      = cs_proto,
            crystal_state = cs_state,
            soul_registry = Registry.souls,
            assets        = assets,
            dll_status_fn = read_crystaljobs_status,
        })
        registry:attach_controller('character', character_mod, true)
    else
        registry:set_available('character', false, 'CrystalSocket sibling modules unavailable.')
    end

    -- 2. Weapon Mastery (The Soulforge) & 3. Soul Talents (shared soulforge_state)
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
            savePrefs    = save_settings,
        })
        weapon_mastery_mod = WeaponMastery.new(sf_state, sf_actions, sf_ui)
        registry:attach_controller('weapon_mastery', weapon_mastery_mod, true)

        soul_talents_mod = SoulTalents.new(sf_state, sf_actions, sf_ui, {
            soul_registry = Registry.souls,
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
end

ashita.events.register('load', 'soulspire_core_load', function()
    local saved_scale = load_settings()
    assets = Assets.new(addon.path)
    init_modules()

    if imgui.AddFontFromFileTTF then
        for _, fontPath in ipairs({ 'C:\\Windows\\Fonts\\segoeui.ttf', 'C:\\Windows\\Fonts\\arial.ttf' }) do
            local okF, f = pcall(imgui.AddFontFromFileTTF, fontPath, 16)
            if okF and f ~= nil then
                ui_font = f
                break
            end
        end
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

    ui = UI.new(imgui, registry, focus, assets, {
        ui_scale        = saved_scale,
        on_scale_change = function() save_settings() end,
        get_identity    = function()
            if character_mod then
                return character_mod:get_header_identity()
            end
            return nil
        end,
    })

    last_session_active = is_player_in_session()
    if not menu or not menu:is_available() then
        log('MenuManager layout unavailable; running in standalone /soulspire mode.')
    end
end)

ashita.events.register('unload', 'soulspire_core_unload', function()
    save_settings()
    focus:blur_all('unload')
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
        local native = current_native_menu()
        local active = focus:active_module()
        local diag = menu and menu:diagnostics() or { mode = 'standalone', bridge_available = false, native_hook_supported = false, native_hook_reason = 'menu_bridge_nil' }
        local sn, sn_err = NativeBridge.query()
        local line1 = ('version=%s mode=%s native_hook=%s bridge=%s modules=%d(%d live) hub_open=%s dock_focused=%s active=%s native_form=%s'):format(
            addon.version,
            tostring(diag.mode),
            tostring(diag.native_hook_supported),
            tostring(diag.bridge_available),
            registry:count(),
            #registry:available_modules(),
            tostring(focus.hub_open),
            tostring(focus.dock_focused),
            tostring(active and active.id or 'none'),
            tostring(native and native.name or 'none')
        )
        local line2 = ('native_hook_reason=%s last_action=%s last_device=%s ui_scale=%.2f sf_synced=%s'):format(
            tostring(diag.native_hook_reason),
            tostring(focus.last_action),
            tostring(input.last_device),
            tonumber(ui and ui.ui_scale or 1.0),
            tostring(sf_state ~= nil and sf_state.synced == true)
        )
        log(line1)
        log(line2)
        local line3 = ''
        if sn then
            line3 = ('soulspire_native abi=v%d hooks=%d/%d caps=0x%04X modules=0x%02X/0x%02X banks=%d/%d hash=%s'):format(
                sn.abi_version, sn.installed_hooks, sn.expected_hooks, sn.capabilities,
                sn.active_modules_mask, sn.enabled_modules_mask,
                sn.menu2fon_banks_used, sn.menu2fon_banks_max, sn.registry_hash)
            log(line3)
        else
            line3 = 'soulspire_native unavailable: ' .. tostring(sn_err)
            log(line3)
        end
        if type(addon.path) == 'string' and addon.path ~= '' then
            pcall(function()
                local f = io.open(addon.path:gsub('[/\\]+$', '') .. '/soulspire_core-status.log', 'w')
                if f then
                    f:write('[soulspire_core] ' .. line1 .. '\n[soulspire_core] ' .. line2 .. '\n[soulspire_core] ' .. line3 .. '\n')
                    f:close()
                end
            end)
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
    elseif sub == 'watch' then
        watch_menus = not watch_menus
        last_watched_form = nil
        log('Menu form watch ' .. (watch_menus and 'ENABLED (open FFXI Main Menu to log its exact form name)' or 'DISABLED'))
    else
        log('Commands: /soulspire [open [module] | close | scale <n> | bind | bindings | status | debug | watch] (alias: /ss)')
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

-- Packet synchronization & safe zone/logout lifecycle handling.
ashita.events.register('packet_in', 'soulspire_core_packet_in', function(e)
    if e.id == 0x00A or e.id == 0x00B then
        focus:blur_all('zone_change')
        input:reset()
        return
    end

    local buf = e.data_modified or e.data
    if sf_actions and sf_actions.handlePacketIn(e.id, buf, e.size) then
        e.blocked = true
        return
    end

    if character_mod and e.id == 0x1FF and type(buf) == 'string' then
        if character_mod:handle_packet_in(e.id, buf) then
            e.blocked = true
        end
        return
    end

    if e.id == 0x1FC and character_mod and cs_soul_identity and cs_soul_identity.decode and type(buf) == 'string' then
        character_mod:refresh_player_context()
        local info = character_mod.player_info
        local decoded = cs_soul_identity.decode(buf, info and info.main_job or 0)
        if decoded then
            character_mod:observe_hud_identity(decoded.branch, info and info.main_job or 0)
        end
        return
    end

    if e.id == 0x017 and soul_talents_mod and type(buf) == 'string' and #buf >= 25 then
        local msg = string.sub(buf, 24):match('^([^%z]*)')
        if msg and string.sub(msg, 1, 8) == '[OXHUD]|' then
            soul_talents_mod:observe_hud_line(string.sub(msg, 9))
        end
    end
end)

ashita.events.register('packet_out', 'soulspire_core_packet_out', function(e)
    if e.id == 0x00D then
        focus:blur_all('logout')
        input:reset()
    end
end)

ashita.events.register('d3d_present', 'soulspire_core_present', function()
    if not ui then return end

    local in_session = is_player_in_session()
    if last_session_active and not in_session then
        focus:blur_all('disconnect')
        input:reset()
    end
    last_session_active = in_session

    -- Pump hold-to-repeat for D-Pad / Left Stick / Arrow keys while Core Hub is open
    input:tick(os.clock(), dispatch_action, focus:is_hub_open())

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
        font_pushed = pcall(imgui.PushFont, ui_font, math.floor(16 * (ui.ui_scale or 1.0) + 0.5))
    end

    local okDraw, errDraw = xpcall(function()
        ui:draw(native, mode)
    end, debug.traceback)
    if not okDraw then
        log('Render error: ' .. tostring(errDraw))
    end

    if font_pushed and imgui.PopFont then
        imgui.PopFont()
    end
    if pushed > 0 then
        imgui.PopStyleColor(pushed)
    end
end)
