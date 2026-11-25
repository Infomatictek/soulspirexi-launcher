-- SoulspireXI Phase C — Unified VanaCore-Native Soulspire Core Addon
-- Consolidates Soul HUD, Soulforge, Soul Actions, Soul Identity, Weapon Mastery,
-- CrystalSocket, Flintlock State, and Mob Status using native `vana.soulspire`,
-- `vana.gameui`, `vana.imgui`, `vana.events`, `vana.packets`, and `vana.gamepad`.

addon.name    = 'soulspire_core'
addon.author  = 'SoulspireXI'
addon.version = '3.0.0-vanacore'
addon.desc    = 'Unified VanaCore-native Soulspire Core (Phase C)'

local addon_dir = (type(addon) == 'table' and type(addon.path) == 'string')
    and addon.path:gsub('[/\\]+$', '')
    or '.'

local function load_mod(rel)
    local fn, err = loadfile(addon_dir .. '/' .. rel)
    if not fn then
        if type(vana) == 'table' and vana.log then
            vana.log('soulspire_core: failed loading ' .. rel .. ': ' .. tostring(err))
        end
        return nil
    end
    return fn()
end

local IdentityMod      = load_mod('core/identity.lua')
local ActionsMod       = load_mod('core/actions.lua')
local HudMod           = load_mod('core/hud.lua')
local SoulforgeMod     = load_mod('core/soulforge.lua')
local WeaponMasteryMod = load_mod('core/weapon_mastery.lua')
local CrystalSocketMod = load_mod('core/crystalsocket.lua')
local FlintlockMod     = load_mod('core/flintlock.lua')
local MobStatusMod     = load_mod('core/mob_status.lua')

local install_dir = addon_dir:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')
local identity, actions, hud, soulforge, weapon_mastery, crystalsocket, flintlock, mob_status
local hub_open = false
local active_tab = 'soulforge' -- 'soulforge' | 'souls' | 'actions' | 'flintlock' | 'mobs' | 'diag'

local function log_msg(msg)
    if type(vana) == 'table' and type(vana.log) == 'function' then
        vana.log('[soulspire_core] ' .. tostring(msg))
    else
        print('[soulspire_core] ' .. tostring(msg))
    end
end

local function toggle_hub(tab)
    if tab then
        active_tab = tab
        hub_open = true
    else
        hub_open = not hub_open
    end
    if hub_open and soulforge and not soulforge.synced then
        soulforge:request_sync()
    end
end

local function render_actions_tab(imgui)
    local diag = (vana.soulspire and vana.soulspire.diagnostics) and vana.soulspire.diagnostics() or {}
    imgui.TextColored({ 0.85, 0.70, 0.25, 1.0 }, 'SOUL ACTIONS & VISIBILITY INSPECTOR')
    imgui.Text(string.format('Catalog: %d actions | Visibility rules: %d | Row limit: %d chars',
        tonumber(diag.action_count) or 0, tonumber(diag.visibility_count) or 0, tonumber(diag.action_row_limit) or 16))
    if imgui.SmallButton('Reload Actions & Visibility') and actions then
        local a, v = actions:sync_to_native()
        log_msg(string.format('Synced %d actions and %d visibility rules to vana.soulspire.', a, v))
    end
    imgui.Separator()
    local rows = actions and actions:search(actions.search_query or '', 64) or {}
    if #rows == 0 then
        imgui.Text('No custom Soul actions active for current Soul.')
    else
        for _, r in ipairs(rows) do
            local vis = actions:check_visibility(r.kind, r.id, 0)
            imgui.Text(string.format('[%s #%d] %s  (vis=%s)',
                r.kind == 1 and 'Spell' or (r.kind == 3 and 'WS' or 'JA'),
                r.id, tostring(r.name), tostring(vis)))
            if r.description and r.description ~= '' then
                imgui.TextColored({ 0.72, 0.78, 0.88, 1.0 }, '   ' .. tostring(r.description))
            end
        end
    end
end

local function render_diag_tab(imgui)
    local d = (vana.soulspire and vana.soulspire.diagnostics) and vana.soulspire.diagnostics() or {}
    imgui.TextColored({ 0.85, 0.70, 0.25, 1.0 }, 'VANACORE-NATIVE DIAGNOSTICS (DEC-028)')
    imgui.Text(string.format('Enabled: %s | API v%d | Caps: 0x%X | Hooks: %d/%d',
        tostring(d.enabled), tonumber(d.api_version) or 0, tonumber(d.capabilities) or 0,
        tonumber(d.hooks_installed) or 0, tonumber(d.hooks_total) or 0))
    imgui.Text(string.format('Registry: %d Souls (hash=%s) | Weapon Rules: %d (hash=%s)',
        tonumber(d.registry_soul_count) or 0, tostring(d.registry_hash or ''),
        tonumber(d.weapon_rule_count) or 0, tostring(d.weapon_config_hash or '')))
    imgui.Text(string.format('Packets: 1FF=%d 1FC=%d 1FD=%d 1FE=%d | OXHUD=%d OXMOB=%d OXTAL=%d | Suppressed=%d',
        tonumber(d.packets_1ff) or 0, tonumber(d.packets_1fc) or 0,
        tonumber(d.packets_1fd) or 0, tonumber(d.packets_1fe) or 0,
        tonumber(d.packets_oxhud) or 0, tonumber(d.packets_oxmob) or 0,
        tonumber(d.packets_oxtal) or 0, tonumber(d.suppressed_chat_frames) or 0))
    imgui.Separator()
    for _, h in ipairs(d.hooks or {}) do
        imgui.Text(string.format('[%s] %-22s (%s / %s) +0x%X hits=%d — %s',
            h.installed and 'OK' or 'FAIL', tostring(h.id), tostring(h.owner),
            tostring(h.disposition or ''), tonumber(h.rva) or 0,
            tonumber(h.hit_count) or 0, tostring(h.detail or '')))
    end
end

local function render_hub(imgui)
    if not hub_open or not imgui then return end

    -- Hand gamepad navigation to ImGui while Core Hub is open so controller works cleanly.
    if vana.gamepad and type(vana.gamepad.nav) == 'function' then
        vana.gamepad.nav(true)
    end

    imgui.SetNextWindowSize({ 780, 500 }, 2) -- ImGuiCond_FirstUseEver
    local open = imgui.Begin('Soulspire Core (VanaCore Native)###soulspire_core_hub', true)
    if not open then
        hub_open = false
        imgui.End()
        return
    end

    local tabs = {
        { id = 'soulforge', label = 'Soulforge' },
        { id = 'souls',     label = 'CrystalSocket' },
        { id = 'actions',   label = 'Soul Actions' },
        { id = 'flintlock', label = 'Flintlock' },
        { id = 'mobs',      label = 'Mob Status' },
        { id = 'diag',      label = 'Diagnostics' },
    }
    for i, t in ipairs(tabs) do
        if i > 1 then imgui.SameLine() end
        local lbl = (active_tab == t.id) and ('[' .. t.label .. ']') or t.label
        if imgui.Button(lbl .. '##tab_' .. t.id) then
            active_tab = t.id
            if t.id == 'soulforge' and soulforge and not soulforge.synced then
                soulforge:request_sync()
            end
        end
    end
    imgui.SameLine()
    if imgui.SmallButton('Close##hub_close') then
        hub_open = false
    end
    imgui.Separator()

    if active_tab == 'soulforge' and weapon_mastery then
        weapon_mastery:render(imgui)
    elseif active_tab == 'souls' and crystalsocket then
        crystalsocket:render(imgui)
    elseif active_tab == 'actions' then
        render_actions_tab(imgui)
    elseif active_tab == 'flintlock' and flintlock then
        flintlock:render(imgui)
    elseif active_tab == 'mobs' and mob_status then
        mob_status:render(imgui)
    elseif active_tab == 'diag' then
        render_diag_tab(imgui)
    end

    imgui.End()
end

if type(vana) == 'table' and vana.events then
    vana.events.on('load', function()
        identity       = IdentityMod and IdentityMod.new(install_dir) or nil
        actions        = ActionsMod and ActionsMod.new(install_dir, identity) or nil
        hud            = HudMod and HudMod.new(identity) or nil
        soulforge      = SoulforgeMod and SoulforgeMod.new() or nil
        weapon_mastery = WeaponMasteryMod and WeaponMasteryMod.new(soulforge) or nil
        crystalsocket  = CrystalSocketMod and CrystalSocketMod.new(identity) or nil
        flintlock      = FlintlockMod and FlintlockMod.new(identity) or nil
        mob_status     = MobStatusMod and MobStatusMod.new() or nil

        local a_cnt, v_cnt = 0, 0
        if actions then
            a_cnt, v_cnt = actions:sync_to_native()
        end

        -- Native VanaCore menu integration (replaces legacy menuwind hooks #28-#31 cleanly).
        if vana.gameui and type(vana.gameui.add) == 'function' then
            pcall(vana.gameui.add, 'config_menu', 'Soulspire', function()
                toggle_hub()
            end)
        end

        log_msg(string.format('Loaded VanaCore-native Soulspire Core v%s (souls=%d, actions=%d, visibility=%d). Use /soulspire or Config menu.',
            addon.version, identity and #(identity.souls or {}) or 0, a_cnt, v_cnt))
    end)

    vana.events.on('frame', function()
        local now = os.clock()
        if soulforge then
            soulforge:tick(now)
        end
        if vana.soulspire and type(vana.soulspire.consume_open_core) == 'function' then
            if vana.soulspire.consume_open_core() > 0 then
                toggle_hub()
            end
        end
        if vana.imgui then
            if hud then hud:render(vana.imgui) end
            if hub_open then render_hub(vana.imgui) end
        end
    end)

    vana.events.on('packet_in', function(e)
        if type(e) ~= 'table' then return end
        local data = e.data
        if soulforge and soulforge:handle_packet_in(e.id, data) then
            return
        end
        if e.id == 0x00A or e.id == 0x00B then
            if soulforge then
                soulforge.pending_op = nil
                soulforge.synced = false
            end
        end
    end)

    vana.events.on('command', function(e)
        if type(e) ~= 'table' or type(e.command) ~= 'string' then return end
        local cmd = e.command:match('^%s*(.-)%s*$')
        local low = string.lower(cmd)
        if low == '/soulspire' or low == '/ss' or low == '/talents' or low == '/soulforge' then
            toggle_hub(low == '/talents' or low == '/soulforge' and 'soulforge' or nil)
            return true
        end
        local sub = low:match('^/soulspire%s+(%S+)')
        if sub then
            if sub == 'hud' and hud then
                hud.visible = not hud.visible
                log_msg('Soul HUD ' .. (hud.visible and 'shown' or 'hidden'))
            elseif sub == 'forge' or sub == 'talents' then
                toggle_hub('soulforge')
            elseif sub == 'souls' or sub == 'crystal' then
                toggle_hub('souls')
            elseif sub == 'actions' then
                toggle_hub('actions')
            elseif sub == 'flintlock' then
                toggle_hub('flintlock')
            elseif sub == 'mobs' then
                toggle_hub('mobs')
            elseif sub == 'diag' or sub == 'status' then
                toggle_hub('diag')
            else
                toggle_hub()
            end
            return true
        end
    end)

    vana.events.on('unload', function()
        hub_open = false
    end)
end
