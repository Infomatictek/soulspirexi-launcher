-- SoulspireXI Core (Phase 1A): Modular UI foundation & Native-Styled Main Menu integration.
-- Preserves all existing addons and crystaljobs.dll hooks untouched.
--
-- Integration Mode:
--   Native-Styled Fallback docked to FFXI's Main Menu via read-only MenuManager
--   inspection (same verified memory layout as crystalsocket/menu.lua).
--   Does NOT modify FFXiMain.dll binaries or existing crystaljobs.dll hooks.

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
local Assets     = require('core.assets')
local UI         = require('core.ui')

local registry = Registry.new()
local focus    = Focus.new(registry)
local input    = Input.new()
local menu, assets, ui

local function log(msg)
    print('[soulspire_core] ' .. tostring(msg))
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
        log(('version=%s mode=native-styled-fallback bridge=%s sections=%d hub_open=%s dock_focused=%s active=%s native_form=%s'):format(
            addon.version,
            tostring(menu ~= nil and menu:is_available()),
            registry:count(),
            tostring(focus.hub_open),
            tostring(focus.dock_focused),
            tostring(active and active.id or 'none'),
            tostring(native and native.name or 'none')
        ))
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
    else
        log('Commands: /soulspire [open [section] | close | status | debug] (alias: /ss)')
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

-- Cleanly blur/close on zone transitions and logout.
ashita.events.register('packet_in', 'soulspire_core_packet_in', function(e)
    if e.id == 0x00A or e.id == 0x00B then
        focus:blur_all('zone_change')
        input:reset()
    end
end)

ashita.events.register('d3d_present', 'soulspire_core_present', function()
    if not ui then return end
    local native = current_native_menu()
    ui:draw(native, menu ~= nil and menu:is_available())
end)
