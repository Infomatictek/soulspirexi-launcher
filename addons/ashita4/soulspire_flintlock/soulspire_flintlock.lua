addon.name = 'soulspire_flintlock'
addon.author = 'SoulspireXI'
addon.version = '0.1.0'
addon.desc = 'COR Flintlock Phase 1 dual-pistol companion: Flintlock-gated ranged auto-facing and safe XIPivot overlay toggle.'

require('common')
local chat = require('chat')
local State = require('flintlock_state')
local PivotConfig = require('pivot_config')

local state = State.new()
if type(addon.path) == 'string' and addon.path ~= '' then
    State.load_registry_default(addon.path)
end

-- Reuse existing crystaljobs.dll status export via LuaJIT FFI (same ABI as soulspire_soul_actions/soul_bridge.lua).
local ok_ffi, ffi = pcall(require, 'ffi')
local status_t, get_status_type, cached_module, cached_address, cached_function
if ok_ffi and ffi then
    pcall(ffi.cdef, 'void* __stdcall GetModuleHandleA(const char*);')
    pcall(ffi.cdef, 'void* __stdcall GetProcAddress(void*, const char*);')
    local ok_s, tp = pcall(ffi.typeof, [=[struct {
        uint32_t size, version, enabled, hooks, character_id, job, known, branch;
        uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
        uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
    }[1]]=])
    if ok_s then status_t = tp end
    local ok_f, fn_t = pcall(ffi.typeof, 'uint32_t (__stdcall *)(void*, uint32_t)')
    if ok_f then get_status_type = fn_t end
end

local function read_crystaljobs_status()
    if not (ffi and status_t and get_status_type) then return nil end
    local ok, result = pcall(function()
        local handle = ffi.C.GetModuleHandleA('soulspire_native.dll')
        local export_name = 'SoulspireNativeGetStatus'
        if handle == nil then
            handle = ffi.C.GetModuleHandleA('crystaljobs.dll')
            export_name = 'CrystalJobsGetStatus'
        end
        if handle == nil then
            cached_module, cached_address, cached_function = nil, nil, nil
            return nil
        end
        local addr = ffi.C.GetProcAddress(handle, export_name)
        if addr == nil and export_name == 'SoulspireNativeGetStatus' then
            addr = ffi.C.GetProcAddress(handle, 'CrystalJobsGetStatus')
        end
        if addr == nil then return nil end
        if cached_module ~= handle or cached_address ~= addr then
            cached_module, cached_address = handle, addr
            cached_function = ffi.cast(get_status_type, addr)
        end
        local buf = ffi.new(status_t)
        if cached_function(buf, ffi.sizeof(buf)) ~= 0 or buf[0].size ~= 68 or buf[0].version ~= 1 then
            return nil
        end
        return {
            enabled = tonumber(buf[0].enabled),
            known = tonumber(buf[0].known),
            job = tonumber(buf[0].job),
            branch = tonumber(buf[0].branch),
            character_id = tonumber(buf[0].character_id),
        }
    end)
    return ok and result or nil
end

local function ashita_root()
    if AshitaCore and AshitaCore.GetInstallPath then
        local p = AshitaCore:GetInstallPath()
        if type(p) == 'string' and p ~= '' then
            return p:gsub('[/\\]+$', '')
        end
    end
    return nil
end

local function is_vanacore_host()
    if not (ok_ffi and ffi) then return false end
    local ok, hit = pcall(function()
        return ffi.C.GetModuleHandleA('VanaCore.Core.dll') ~= nil
            or ffi.C.GetModuleHandleA('SoulspireClient.Core.dll') ~= nil
    end)
    return ok and hit == true
end

local function pivot_ini_path()
    local root = ashita_root()
    if not root then return nil end
    if is_vanacore_host() then
        return root .. '\\vanacore.ini'
    end
    return root .. '\\config\\pivot\\soulspirexi.ini'
end

local function overlay_installed()
    local root = ashita_root()
    if not root then return false end
    -- Check one of the 7 required player skeleton DATs (HumeM base).
    local base_dir = is_vanacore_host() and (root .. '\\pivot\\') or (root .. '\\polplugins\\DATs\\')
    local f = io.open(base_dir .. PivotConfig.FLINTLOCK_OVERLAY .. '\\ROM\\27\\82.DAT', 'rb')
    if f then
        f:close()
        return true
    end
    return false
end

local function read_pivot_ini()
    local path = pivot_ini_path()
    if not path then return nil end
    local f = io.open(path, 'rb')
    if not f then return nil end
    local content = f:read('*a')
    f:close()
    return content
end

local session_overlay_enabled = PivotConfig.is_flintlock_enabled(read_pivot_ini() or '')

local function print_msg(text)
    print(chat.header(addon.name):append(chat.message(text)))
end

local function get_local_player_context()
    local mm = AshitaCore:GetMemoryManager()
    local party = mm:GetParty()
    local player = mm:GetPlayer()
    if not party or not player then return 0, 0, 0 end
    local server_id = party:GetMemberServerId(0) or 0
    local target_idx = party:GetMemberTargetIndex(0) or 0
    if server_id <= 0 or target_idx <= 0 then
        return 0, 0, 0
    end
    local main_job = player:GetMainJob() or 0
    return server_id, main_job, target_idx
end

local function is_firearm_equipped()
    local ok, result = pcall(function()
        local inv = AshitaCore:GetMemoryManager():GetInventory()
        local res = AshitaCore:GetResourceManager()
        if not inv or not res then return false end
        -- Equipment slot 2 = Range
        local eq = inv:GetEquippedItem(2)
        if not eq or eq.Index == 0 then return false end
        local bag = math.floor(eq.Index / 256)
        local slot = eq.Index % 256
        if slot == 0 then return false end
        local item = inv:GetContainerItem(bag, slot)
        if not item or item.Id == 0 then return false end
        local item_res = res:GetItemById(item.Id)
        if not item_res then return false end
        return State.is_firearm_item({
            skill = item_res.Skill,
            name = item_res.Name and item_res.Name[1] or '',
        })
    end)
    return ok and result or false
end

local function find_entity_index_by_server_id(server_id)
    local ent = AshitaCore:GetMemoryManager():GetEntity()
    if not ent then return nil end
    for idx = 0, 2303 do
        if ent:GetServerId(idx) == server_id then
            return idx
        end
    end
    return nil
end

local function face_target(my_idx, target_server_id)
    local ent = AshitaCore:GetMemoryManager():GetEntity()
    if not ent or my_idx <= 0 then return end
    local target_idx = find_entity_index_by_server_id(target_server_id)
    if not target_idx then return end
    local yaw = State.compute_facing_yaw(
        ent:GetLocalPositionX(my_idx),
        ent:GetLocalPositionZ(my_idx),
        ent:GetLocalPositionX(target_idx),
        ent:GetLocalPositionZ(target_idx)
    )
    if yaw and ent.SetLocalPositionYaw then
        ent:SetLocalPositionYaw(my_idx, yaw)
    end
end

local last_sync_tick = 0
local function sync_soul_context(force)
    local now_tick = ashita.time.get_tick64 and ashita.time.get_tick64() or 0
    if not force and (now_tick - last_sync_tick) < 500 then
        return
    end
    last_sync_tick = now_tick

    local char_id, main_job = get_local_player_context()
    local cj = read_crystaljobs_status()
    local changed = state:update_context(char_id, main_job, cj)
    if changed then
        local advisory = state:check_overlay_advisory(overlay_installed(), session_overlay_enabled)
        if advisory then
            print_msg(advisory)
        end
    end
end

ashita.events.register('packet_out', 'soulspire_flintlock_packet_out', function(e)
    if e.id ~= 0x001A or e.blocked then return end
    sync_soul_context(true)
    local data = e.data_modified or e.data
    state:record_outgoing_ra(data)
end)

ashita.events.register('packet_in', 'soulspire_flintlock_packet_in', function(e)
    if e.id == 0x000A or e.id == 0x000B then
        state:reset('zone')
        return
    end

    if e.id == 0x01FC then
        local _, main_job = get_local_player_context()
        state:on_soul_packet(e.data_modified or e.data, main_job > 0 and main_job or nil)
        sync_soul_context(true)
        return
    end

    if e.id == 0x0028 then
        sync_soul_context(false)
        if not state.flintlock_active or not state.aim_enabled then
            return
        end
        local action = State.parse_action_packet(e.data_modified or e.data)
        local target_id = state:resolve_auto_face_target(action, is_firearm_equipped())
        if target_id then
            local _, _, my_idx = get_local_player_context()
            face_target(my_idx, target_id)
        end
    end
end)

ashita.events.register('d3d_present', 'soulspire_flintlock_present', function()
    sync_soul_context(false)
end)

ashita.events.register('command', 'soulspire_flintlock_command', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/flintlock' then
        return
    end
    e.blocked = true
    sync_soul_context(true)

    local sub = (args[2] or 'status'):lower()
    if sub == 'status' then
        local installed = overlay_installed()
        local config_enabled = PivotConfig.is_flintlock_enabled(read_pivot_ini() or '')
        print_msg(string.format(
            'Soul=%s | FlintlockActive=%s | AutoAim=%s | OverlayInstalled=%s | OverlaySession=%s | OverlayNextBoot=%s',
            state.flintlock_active and 'COR Flintlock' or ('job=' .. tostring(state.job) .. ',branch=' .. tostring(state.branch)),
            tostring(state.flintlock_active),
            state.aim_enabled and 'on' or 'off',
            installed and 'yes' or 'no',
            session_overlay_enabled and 'on' or 'off',
            config_enabled and 'on' or 'off'
        ))
        return
    end

    if sub == 'aim' then
        local mode = (args[3] or ''):lower()
        if mode == 'on' then
            state.aim_enabled = true
            print_msg('Flintlock ranged auto-facing enabled (active only while COR Flintlock is equipped).')
        elseif mode == 'off' then
            state.aim_enabled = false
            print_msg('Flintlock ranged auto-facing disabled.')
        else
            print_msg('Usage: /flintlock aim on|off')
        end
        return
    end

    if sub == 'overlay' then
        local mode = (args[3] or ''):lower()
        if mode ~= 'on' and mode ~= 'off' then
            print_msg('Usage: /flintlock overlay on|off')
            return
        end
        local enable = (mode == 'on')
        if enable and not overlay_installed() then
            print_msg('Cannot enable overlay: flintlock-akimbo-compact DATs are not installed. Enable the overlay in SoulspireXI Launcher and sync first.')
            return
        end
        local path = pivot_ini_path()
        local current = read_pivot_ini()
        if not path or not current then
            print_msg('Could not locate Ashita config/pivot/soulspirexi.ini.')
            return
        end
        local updated, err = PivotConfig.set_flintlock_enabled(current, enable)
        if not updated then
            print_msg('Failed to update pivot config: ' .. tostring(err))
            return
        end
        local f = io.open(path, 'wb')
        if not f then
            print_msg('Could not write ' .. path)
            return
        end
        f:write(updated)
        f:close()
        print_msg(enable
            and 'Flintlock dual-pistol overlay enabled for NEXT client launch. Restart FFXI to apply.'
            or 'Flintlock dual-pistol overlay disabled for NEXT client launch. Restart FFXI to return to vanilla single-gun visuals.')
        return
    end

    print_msg('Usage: /flintlock status | /flintlock aim on|off | /flintlock overlay on|off')
end)
