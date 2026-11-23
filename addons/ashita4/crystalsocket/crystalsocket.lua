addon.name = 'crystalsocket'
addon.author = 'SoulspireXI / Crystal Socket'
addon.version = '0.3.9'
addon.desc = 'SoulspireXI Soul Job crystal socket integrated with the Equipment menu and native job labels.'

require('common')
local ffi = require('ffi')
local d3d8 = require('d3d8')
local imgui = require('imgui')
local protocol = require('protocol')
local state = require('state').new()
local UI = require('ui')
local Menu = require('menu')
local labels = require('job_labels').new()
local WeaponConfig = require('weapon_config')
local native_weapon_rules = WeaponConfig.native_rules()
local appearance = require('soul_appearance').new()

local character_id = 0
local ui, menu
local textures, asset_status = {}, {}
local preload_names = { 'commander', 'berserker', 'gladiator', 'spartan', 'sensei', 'blackbelt', 'chiweaver', 'medic', 'sage', 'ronin', 'imperialarcher', 'warlord', 'bladewheel', 'miragesentinel', 'necromancer', 'inquisitor', 'spellblade', 'lifebinder', 'aegistemplar', 'alphawarden', 'kurogane', 'kagemusha', 'azurebastion', 'crimsonduelist', 'vanguard', 'pugilist', 'bishop', 'templar', 'magus', 'vampire', 'celestial', 'animist', 'verdant', 'wyvernheart', 'flintlock', 'gambler', 'buccaneer', 'huntsman' }
local epoch, transitioning = 0, false
local key_owner = {} -- nil: new press; false: native/chat; true: addon, until physical release.
local last_mouse
local was_anchored, last_anchor_refresh = false, 0
local equipment_probe = { open = false, opens = 0, last = 'not observed' }
local transport = { queued = 0, outgoing = 0, incoming = 0 }
local keys = { [1] = 'back', [200] = 'up', [208] = 'down', [203] = 'left', [205] = 'right',
    [28] = 'enter', [156] = 'enter' }

local function now()
    return ashita.time.get_tick64() / 1000
end

local function inject_grap_list(packet)
    if type(packet) ~= 'string' or #packet ~= 24 then return end
    local pm = AshitaCore and AshitaCore:GetPacketManager()
    if not pm or not pm.AddIncomingPacket then return end
    local bytes = { packet:byte(1, #packet) }
    pm:AddIncomingPacket(0x0051, bytes)
end

local function sync_appearance()
    appearance:set_active_soul(state.current_job or 0, labels.branch or 0, inject_grap_list)
end

local function reset(reason)
    labels:clear_hud_hint()
    appearance:reset()
    epoch = epoch + 1
    state:reset(reason, false)
    character_id = 0
    labels:sync(state:snapshot(), character_id, now())
    if ui then ui:blur() end
end

local function load_icon_texture(name)
    if type(name) ~= 'string' or name == '' then return nil end
    if textures[name] ~= nil then return tonumber(ffi.cast('uint32_t', textures[name])) end

    local ok, result, tex = pcall(function()
        if type(addon.path) ~= 'string' then return 'addon path unavailable', nil end
        local safe = name:gsub('[^%w_%-]', '')
        if safe == '' then return 'invalid asset name', nil end
        local file = io.open(addon.path:gsub('[/\\]+$', '') .. '/assets/' .. safe .. '.png', 'rb')
        if not file then return 'file unavailable', nil end
        local data = file:read('*a')
        file:close()
        if not data or #data == 0 then return 'file unreadable', nil end
        local out = ffi.new('IDirect3DTexture8*[1]')
        local hr = ffi.C.D3DXCreateTextureFromFileInMemoryEx(d3d8.get_device(), data,
            #data, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0, ffi.C.D3DFMT_A8R8G8B8,
            ffi.C.D3DPOOL_MANAGED, ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0, nil, nil, out)
        if hr ~= ffi.C.S_OK or out[0] == nil then
            if out[0] ~= nil then out[0]:Release() end
            return 'texture failed (' .. tostring(hr) .. ')', nil
        end
        return 'ready', out[0]
    end)

    if ok and tex then
        textures[name] = tex
        asset_status[name] = 'ready'
        return tonumber(ffi.cast('uint32_t', tex))
    end

    asset_status[name] = ok and result or 'texture API unavailable'
    return nil
end

local function context()
    local memory = AshitaCore:GetMemoryManager()
    local party = memory:GetParty()
    local player = memory:GetPlayer()
    local id, name = party:GetMemberServerId(0), party:GetMemberName(0)
    if transitioning or type(id) ~= 'number' or id < 1 or id > 4294967295 or id % 1 ~= 0
        or name == nil or name == '' or party:GetMemberTargetIndex(0) == 0 then
        state:set_context(nil, nil, nil, nil)
        character_id = 0
        labels:sync(state:snapshot(), character_id, now())
        if ui then ui:blur() end
        return
    end
    local lvl = player.GetMainJobLevel and player:GetMainJobLevel() or nil
    local changed = state:set_context(tostring(id) .. ':' .. name .. ':' .. epoch,
        player:GetMainJob(), party:GetMemberZone(0), lvl)
    character_id = id
    if changed and ui then ui:blur(); ui.feedback = nil end
    labels:sync(state:snapshot(), character_id, now())
    sync_appearance()
end

local function send(packet)
    if type(packet) ~= 'string' or #packet ~= 16 then return nil, 'Invalid crystal packet.' end
    local bytes = { packet:byte(1, #packet) }
    AshitaCore:GetPacketManager():AddOutgoingPacket(protocol.REQUEST_ID, bytes)
    transport.queued = transport.queued + 1
    transport.request_id = bytes[11] + bytes[12] * 256
    return true
end

local function hex16(packet)
    if type(packet) ~= 'string' then return '?' end
    return (packet:sub(1, 16):gsub('.', function(byte) return ('%02X'):format(byte:byte()) end))
end

local function event_packet(e)
    local buffer, size = e.data_modified or e.data, e.size
    if type(buffer) ~= 'string' or type(size) ~= 'number' or size % 1 ~= 0
        or size < 0 or size > 512 or size > #buffer then
        return nil, 'Invalid custom packet event size.'
    end
    return buffer:sub(1, size)
end

local function view()
    context()
    local snapshot = state:snapshot()
    local can_show = snapshot.session_key ~= nil and ui ~= nil and ui:has_socket(snapshot)
    local native = menu and can_show and menu:context() or nil
    if ui and (not native or (ui.focus_window and ui.focus_window ~= native.window)
        or (ui.focus_cursor ~= nil and ui.focus_cursor ~= native.cursor)) then
        ui:blur()
    end
    return native
end

local function input(scan, key, down)
    local native = view() -- Read current native ownership for every input, not the last rendered frame.
    if key_owner[scan] ~= nil then return key_owner[scan] end
    if not down then return false end
    key_owner[scan] = false
    if not native or AshitaCore:GetChatManager():IsInputOpen() ~= 0 then return false end
    local navigation = native.window == native.equipment and native.selected and native or nil
    if ui:key(key, now(), navigation) then
        key_owner[scan] = true
        return true
    end
    return false
end

ashita.events.register('command', 'crystalsocket_command', function(e)
    local cmd = e.command:lower()
    if cmd:match('^/crystalsocket%s+sync%s*$') then
        e.blocked = true
        context()
        local ok, why = state:sync_current(now(), send, true)
        if not ok then
            print('[crystalsocket] Sync failed: ' .. tostring(why))
        else
            print('[crystalsocket] Syncing soul crystals for current job...')
        end
        return
    end
    if cmd:match('^/crystalsocket%s+debug%s*$') then
        e.blocked = true
        print(('[crystalsocket] Equipment native label hook activity: %s (opens=%d open=%s)'):format(
            equipment_probe.last, equipment_probe.opens, tostring(equipment_probe.open)))
        local dll_st = labels:status()
        if dll_st then
            print(('[crystalsocket] Native label counters: item=%d full=%d search=%d rows=%d hooks=%d enabled=%d err=%d'):format(
                dll_st.item_labels, dll_st.full_labels, dll_st.search_labels,
                dll_st.search_rows, dll_st.hooks, dll_st.enabled, dll_st.last_error))
        else
            print('[crystalsocket] Native status unavailable: ' .. tostring(labels.last_status_error))
        end
        local wpn_st = labels:weapon_status()
        if wpn_st then
            print(('[crystalsocket] Native weapon rules: count=%d gen=%d lvl=%d allow=%d deny=%d hooks=%d/%d'):format(
                wpn_st.rule_count, wpn_st.rule_generation, wpn_st.effective_level,
                wpn_st.allow_hits, wpn_st.deny_hits, wpn_st.total_hooks, wpn_st.expected_hooks))
        else
            print('[crystalsocket] Native weapon rules unavailable: ' .. tostring(labels.weapon_rules_error))
        end
        local diag = labels:hook_diagnostics()
        if diag then
            for _, line in ipairs(labels.format_hook_diagnostics(diag)) do
                print('[crystalsocket] ' .. line)
            end
        else
            print('[crystalsocket] hooks_diag unavailable (older native DLL without SoulspireNativeGetHookDiagnostics)')
        end
        return
    end
    if not cmd:match('^/crystalsocket%s+status%s*$') then return end
    e.blocked = true
    local lines = {}
    local function report(line)
        lines[#lines + 1] = line
        print(line)
    end
    local snapshot = state:snapshot()
    local loaded_assets = {}
    for k, st in pairs(asset_status) do
        loaded_assets[#loaded_assets + 1] = k .. ':' .. st
    end
    table.sort(loaded_assets)
    report(('[crystalsocket] version=%s assets=[%s]'):format(addon.version, table.concat(loaded_assets, ', ')))
    report(('[crystalsocket] model=%s session=%s job=%s lvl=%s loaded=%s pending=%s open=%s active=%s owned=%s'):format(
        tostring(snapshot.status), tostring(snapshot.session_key), tostring(snapshot.current_job),
        tostring(snapshot.current_lvl), tostring(snapshot.loaded), tostring(snapshot.pending),
        tostring(snapshot.open), tostring(snapshot.active), tostring(snapshot.owned_mask)))
    report(('[crystalsocket] catalog_entries=%d'):format(snapshot.catalog and #(snapshot.catalog.entries or {}) or -1))
    report('[crystalsocket] ' .. tostring(snapshot.message))
    local dll_st = labels:status()
    report(('[crystalsocket] labels dll=%s known=%s branch=%s error=%s'):format(
        tostring(labels.native), tostring(labels.known), tostring(labels.branch), tostring(labels.error)))
    report('[crystalsocket] label_source=' .. tostring(labels.source or 'none'))
    report(('[crystalsocket] dll_status successes=%s failures=%s last_error=%s'):format(
        tostring(labels.status_successes), tostring(labels.status_failures),
        tostring(labels.last_status_error)))
    report(('[crystalsocket] equipment_probe opens=%d open=%s last=%s'):format(equipment_probe.opens, tostring(equipment_probe.open), equipment_probe.last))
    report(('[crystalsocket] hud packets=%d decoded=%d rejected=%d context_job=%s bytes=%s reason=%s hint_job=%s hint_character=%s hint_branch=%s'):format(
        labels.hud_packets, labels.hud_decoded, labels.hud_rejected,
        tostring(labels.last_hud_job), tostring(labels.last_hud_length),
        tostring(labels.last_hud_error), tostring(labels.hud_hint and labels.hud_hint.job),
        tostring(labels.hud_hint and labels.hud_hint.character_id),
        tostring(labels.hud_hint and labels.hud_hint.branch)))
    report(('[crystalsocket] native_sync sends=%d result=%s source=%s'):format(
        labels.send_count, tostring(labels.last_send_result), tostring(labels.source)))
    if dll_st then
        report(('[crystalsocket] native enabled=%d hooks=%d job=%d known=%d branch=%d items=%d search=%d full=%d rows=%d err=%d'):format(
            dll_st.enabled, dll_st.hooks, dll_st.job, dll_st.known, dll_st.branch,
            dll_st.item_labels, dll_st.search_labels, dll_st.full_labels, dll_st.search_rows, dll_st.last_error))
    end
    local wpn_st = labels:weapon_status()
    if wpn_st then
        report(('[crystalsocket] weapon_rules synced=%s count=%d gen=%d lvl=%d allow=%d deny=%d hooks=%d/%d'):format(
            tostring(labels.weapon_rules_synced), wpn_st.rule_count, wpn_st.rule_generation,
            wpn_st.effective_level, wpn_st.allow_hits, wpn_st.deny_hits, wpn_st.total_hooks, wpn_st.expected_hooks))
    else
        report(('[crystalsocket] weapon_rules synced=%s error=%s'):format(
            tostring(labels.weapon_rules_synced), tostring(labels.weapon_rules_error)))
    end
    local diag = labels:hook_diagnostics()
    if diag then
        for _, line in ipairs(labels.format_hook_diagnostics(diag)) do
            report('[crystalsocket] ' .. line)
        end
    else
        report('[crystalsocket] hooks_diag unavailable (older native DLL without SoulspireNativeGetHookDiagnostics)')
    end
    report(('[crystalsocket] tx queued=%d request=%s observed=%d size=%s buffer=%s injected=%s blocked=%s'):format(
        transport.queued, tostring(transport.request_id), transport.outgoing, tostring(transport.out_size),
        tostring(transport.out_buffer), tostring(transport.out_injected), tostring(transport.out_blocked)))
    report('[crystalsocket] tx16=' .. tostring(transport.out_hex))
    report(('[crystalsocket] rx=%d size=%s buffer=%s request=%s expected=%s matched=%s result=%s error=%s'):format(
        transport.incoming, tostring(transport.in_size), tostring(transport.in_buffer), tostring(transport.in_request),
        tostring(transport.in_expected), tostring(transport.in_matched), tostring(transport.in_result),
        tostring(transport.in_error)))
    if ui then
        local native = menu and menu:context()
        report(('[crystalsocket] focus=%s origin=%s current=%s form=%s selected=%s cursor=%s/%s'):format(
            tostring(ui.focused), tostring(ui.focus_window), tostring(native and native.window),
            tostring(native and native.name), tostring(native and native.selected),
            tostring(ui.focus_cursor), tostring(native and native.cursor)))
        local slot = ui.lastslot
        local function n(value) return value and ('%.1f'):format(value) or '?' end
        report(('[crystalsocket] slot=%s hover=%s clicks=%d scale=%s,%s anchor=%s,%s'):format(
            tostring(slot.visible), tostring(slot.hovered), slot.clicks, n(ui.sx), n(ui.sy),
            n(slot.anchor_x), n(slot.anchor_y)))
    end
    if last_mouse then
        report(('[crystalsocket] mouse event=%s xy=%s,%s blocked=%s'):format(
            tostring(last_mouse.message), tostring(last_mouse.x), tostring(last_mouse.y), tostring(last_mouse.blocked)))
    end
    if type(addon.path) == 'string' then
        local file = io.open(addon.path:gsub('[/\\]+$', '') .. '/crystalsocket-status.log', 'w')
        if file then file:write(table.concat(lines, '\n'), '\n'); file:close() end
    end
end)

ashita.events.register('mouse', 'crystalsocket_mouse_diagnostic', function(e)
    last_mouse = last_mouse or {}
    last_mouse.message, last_mouse.x, last_mouse.y, last_mouse.blocked = e.message, e.x, e.y, e.blocked
end)

ashita.events.register('load', 'crystalsocket_load', function()
    if type(addon.path) == 'string' and addon.path ~= '' then
        labels:set_dll_path(addon.path:gsub('[/\\]+$', '') .. '\\..\\..\\plugins\\soulspire_native.dll')
        labels:ensure_loaded()
        labels:sync_weapon_rules(native_weapon_rules)
    end
    local ok, scaling = pcall(require, 'scaling')
    if not ok or scaling.scaled.w <= 0 or scaling.scaled.h <= 0 then
        print('[crystalsocket] Menu scaling is unavailable; socket hidden.')
        return
    end
    menu = Menu.new(ashita.memory, scaling, AshitaCore:GetPointerManager():Get('menu'))
    ui = UI.new(imgui, state, send, scaling, load_icon_texture)
    local font_ok, font = pcall(imgui.AddFontFromFileTTF, 'C:\\Windows\\Fonts\\arial.ttf', 14)
    if font_ok then ui.font = font end
    for _, name in ipairs(preload_names) do
        local tex = load_icon_texture(name)
        if tex then ui.icons[name] = tex end
    end
    if not menu.manager then print('[crystalsocket] Menu layout unavailable; socket hidden.') end
end)

ashita.events.register('packet_in', 'crystalsocket_packet_in', function(e)
    if e.id == 0x051 and not e.injected then
        local mod = appearance:on_grap_list(e.data_modified or e.data)
        if mod then e.data_modified = mod end
        return
    end
    if e.id == 0x00D and not e.injected then
        local mod = appearance:on_char_update(e.data_modified or e.data, character_id)
        if mod then e.data_modified = mod end
        return
    end
    if e.id == 0x1FC then
        -- Reuse the already-authoritative HUD identity for native labels when the
        -- Crystal Socket catalog query has not finished; don't alter gameplay.
        context()
        if labels:observe_hud(e.data, state.current_job, character_id) then
            labels:sync(state:snapshot(), character_id, now())
            sync_appearance()
        end
        return
    end
    if e.id == protocol.RESPONSE_ID then
        local packet, boundary_error = event_packet(e)
        local decoded = packet and protocol.decode_packet(packet) or nil
        -- The active DLL consumes its high-ID CRYS replies after host filters and before stock dispatch.
        if decoded and decoded.kind == 'state' and decoded.request_id >= 0x8000 and labels:native_decoder_ready() then
            return
        end
        -- Reserved replies must never reach the stock packet dispatcher, including malformed replies.
        e.blocked = true
        context()
        transport.incoming = transport.incoming + 1
        local buffer = e.data_modified or e.data
        transport.in_size, transport.in_buffer = e.size, type(buffer) == 'string' and #buffer or nil
        transport.in_request = decoded and decoded.request_id
        transport.in_result = decoded and decoded.result
        transport.in_expected = state:snapshot().pending_request
        transport.in_matched = decoded ~= nil and transport.in_expected == decoded.request_id
        if packet then
            local ok, received, why = pcall(state.receive, state, packet, now())
            transport.in_error = ok and (received and nil or why) or tostring(received)
        else
            transport.in_error = boundary_error
        end
        labels:sync(state:snapshot(), character_id, now())
        sync_appearance()
        return
    end
    if e.id == 0x00A then
        transitioning = false
        reset('Zone changed; syncing soul crystals...')
        if not e.injected then
            local mod = appearance:on_zone_in(e.data_modified or e.data)
            if mod then e.data_modified = mod end
        end
    elseif e.id == 0x00B then
        transitioning = true
        reset('Changing zones...')
        state:set_context(nil, nil, nil, nil)
    end
end)

ashita.events.register('packet_out', 'crystalsocket_packet_out', function(e)
    if e.id == protocol.REQUEST_ID then
        local packet = event_packet(e)
        transport.outgoing = transport.outgoing + 1
        local buffer = e.data_modified or e.data
        transport.out_size, transport.out_buffer = e.size, type(buffer) == 'string' and #buffer or nil
        transport.out_hex = hex16(packet)
        transport.out_injected, transport.out_blocked = e.injected, e.blocked
        return
    end
    if e.id == 0x00D then
        transitioning = true
        reset('Leaving this session...')
        state:set_context(nil, nil, nil, nil)
    end
end)

ashita.events.register('key_data', 'crystalsocket_key_data', function(e)
    local key = keys[e.key]
    if not ui or not key then return end
    if input(e.key, key, e.down) then e.blocked = true end
end)

ashita.events.register('key_state', 'crystalsocket_key_state', function(e)
    if not ui or not e.data_raw or e.size < 209 then return end
    -- Ashita's supported event buffer is writable; no game code or native callback is patched.
    local data = ffi.cast('uint8_t*', e.data_raw)
    for scan, key in pairs(keys) do
        if data[scan] == 0 then
            key_owner[scan] = nil
        elseif input(scan, key, true) then
            data[scan] = 0 -- Consume the complete press, including repeats after Back closes the panel.
        end
    end
end)

ashita.events.register('d3d_present', 'crystalsocket_present', function()
    context()
    local ts = now()
    state:tick(ts)
    state:ensure_loaded(ts, send)
    local native = view()
    local anchor = native and native.anchor or nil
    local snap = state:snapshot()
    if anchor and not was_anchored and snap.loaded and not snap.pending and (ts - last_anchor_refresh) >= 2 then
        last_anchor_refresh = ts
        state:sync_current(ts, send, false)
    end
    -- Read-only observation of the existing native label hooks while Equipment
    -- is visible. No game memory writes or new native hook offsets.
    local equip_visible = native ~= nil and native.name == 'menu    equip'
    if equip_visible and not equipment_probe.open then
        equipment_probe.open = true
        equipment_probe.opens = equipment_probe.opens + 1
        equipment_probe.start = labels:status()
    elseif not equip_visible and equipment_probe.open then
        equipment_probe.open = false
        local before, after = equipment_probe.start, labels:status()
        if before ~= nil and after ~= nil then
            equipment_probe.last = ('item=%d full=%d search=%d'):format(
                after.item_labels - before.item_labels,
                after.full_labels - before.full_labels,
                after.search_labels - before.search_labels)
        else
            equipment_probe.last = 'native status unavailable: ' .. tostring(labels.last_status_error)
        end
    end
    was_anchored = anchor ~= nil
    if ui then
        ui:draw(anchor, ts, native and native.window or nil, native and native.cursor or nil)
    end
    labels:sync(state:snapshot(), character_id, ts)
    sync_appearance()
    if not labels.weapon_rules_synced and not labels.weapon_rules_missing and labels.native then
        labels:sync_weapon_rules(native_weapon_rules)
    end
end)

ashita.events.register('unload', 'crystalsocket_unload', function()
    appearance:restore(inject_grap_list)
    state:set_context(nil, nil, nil, nil)
    character_id = 0
    labels:sync(state:snapshot(), character_id, now())
    if ui then ui:blur(); ui.icons = {} end
    ui, menu = nil, nil
    for name, texture in pairs(textures) do
        texture:Release()
        textures[name] = nil
    end
    asset_status = {}
end)
