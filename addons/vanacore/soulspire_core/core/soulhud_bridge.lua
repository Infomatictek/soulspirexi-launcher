-- SoulspireXI Core (VanaCore-Native): 66-Soul Universal HUD Driver
-- Drives the full polished 66-Soul HUD (`soulhud_gauge`, `soulhud_layout`, `soulhud_registry`,
-- `souls/init.lua`, `soulhud_buffstrip`, `soulhud_roster`, `soulhud_renderer`, `ox_icons`)
-- natively from `0x1FC` (OXHD), `0x017` ([OXHUD]|[OXBST]), `vana.soulspire.hud()`,
-- `vana.soulspire.identity()`, `vana.game.*`, and `vana.imgui` with zero Ashita dependencies.

local M = {}
M.__index = M

local function safe_require(name)
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

local function trim(s)
    return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

local function split_char(str, sep)
    local out, start = {}, 1
    while true do
        local pos = string.find(str, sep, start, true)
        if not pos then
            out[#out + 1] = string.sub(str, start)
            break
        end
        out[#out + 1] = string.sub(str, start, pos - 1)
        start = pos + 1
    end
    return out
end

local function parse_kv(raw)
    local kv = {}
    if type(raw) ~= 'string' or raw == '' then
        return kv
    end
    for _, pair in ipairs(split_char(raw, ';')) do
        local eq = string.find(pair, '=', 1, true)
        if eq then
            local k = trim(string.sub(pair, 1, eq - 1))
            local v = trim(string.sub(pair, eq + 1))
            if k ~= '' then
                kv[k] = v
            end
        end
    end
    return kv
end

local function decode_oxhd_0x1fc(data, size)
    if type(data) ~= 'string' then return nil end
    local len = (type(size) == 'number' and size > 0 and size <= #data) and size or #data
    local magic = len >= 8 and data:sub(5, 8) or ''
    if len < 16 or (magic ~= 'SSHD' and magic ~= 'OXHD') then return nil end
    local ver      = data:byte(9) or 0
    local unlocked = (data:byte(10) or 0) == 1
    local job_id   = data:byte(11) or 0
    local key_len  = data:byte(12) or 0
    local kv_len   = (data:byte(13) or 0) + (data:byte(14) or 0) * 256
    if ver ~= 1 or 16 + key_len + kv_len > len then return nil end
    local soul_key = key_len > 0 and data:sub(17, 16 + key_len) or ''
    local kv_raw   = kv_len > 0 and data:sub(17 + key_len, 16 + key_len + kv_len) or ''
    return {
        unlocked = unlocked,
        job_id   = job_id,
        soul_key = soul_key,
        kv       = parse_kv(kv_raw),
    }
end

local function extract_0x017_message(data, size)
    if type(data) ~= 'string' then return nil end
    local len = (type(size) == 'number' and size > 0 and size <= #data) and size or #data
    if len <= 24 then return nil end
    local raw = data:sub(25, len)
    local nul = raw:find('\0', 1, true)
    if nul then raw = raw:sub(1, nul - 1) end
    return raw
end

function M.new(addon_path, install_dir, identity_mod)
    local ox_icons = safe_require('ox_icons')
    if ox_icons and ox_icons.setRoot then
        ox_icons.setRoot(addon_path, install_dir)
    end
    local settings_mod  = safe_require('soulhud_settings')
    local roster_mod    = safe_require('soulhud_roster')
    local gauge_mod     = safe_require('soulhud_gauge')
    local layout_mod    = safe_require('soulhud_layout')
    local renderer_mod  = safe_require('soulhud_renderer')
    local registry_mod  = safe_require('soulhud_registry')
    local buffstrip_mod = safe_require('soulhud_buffstrip')
    local souls_init    = safe_require('souls.init')

    if registry_mod and type(souls_init) == 'function' then
        pcall(souls_init, registry_mod)
    end

    local cfg = (settings_mod and settings_mod.new) and settings_mod.new() or {
        x = 560, y = 40, scale = 1.0, opacity = 0.94,
        layout = 'standard', mode = 'auto', locked = false,
        showShared = true, autoHideOnMenu = true, pill = true,
        hiddenElements = {},
    }
    if settings_mod and settings_mod.load then
        settings_mod.load(cfg)
    end

    local self = setmetatable({
        identity      = identity_mod,
        character_mod = nil,
        settings_mod  = settings_mod,
        roster_mod    = roster_mod,
        gauge_mod     = gauge_mod,
        layout_mod    = layout_mod,
        renderer_mod  = renderer_mod,
        registry_mod  = registry_mod,
        buffstrip_mod = buffstrip_mod,
        cfg           = cfg,
        visible       = true,
        config_open   = false,
        reset_pos     = false,
        demo_key      = nil,
        last_soul     = '',
        active_def    = nil,
        active_rt     = nil,
        sync_at       = 0,
        last_packet_at = 0,
        packet_count  = 0,
        boost         = nil,
        state         = {
            soul_key   = '',
            unlocked   = false,
            kv         = {},
            hp         = 0, hp_max = 0, hpp = 0,
            mp         = 0, mp_max = 0, mpp = 0,
            tp         = 0,
            job        = 0, branch = 0, level = 0,
            updated    = 0,
            full_name  = nil,
            short_name = nil,
        },
        frame_count   = 0,
    }, M)

    return self
end

function M:set_character_mod(character_mod)
    self.character_mod = character_mod
end

function M:toggle()
    self.visible = not self.visible
    return self.visible
end

function M:set_locked(locked)
    self.cfg.locked = locked == true
    self:save()
end

function M:save()
    if self.settings_mod and self.settings_mod.save then
        pcall(self.settings_mod.save, self.cfg)
    end
end

function M:resolve_soul_key(soul_key, job_id, branch_id)
    if type(soul_key) == 'string' and soul_key ~= '' then
        if not self.roster_mod or self.roster_mod.get(soul_key) then
            return soul_key
        end
    end
    if self.identity and type(self.identity.by_job_branch) == 'function'
        and tonumber(job_id) and tonumber(job_id) > 0
        and tonumber(branch_id) and tonumber(branch_id) > 0 then
        local entry = self.identity:by_job_branch(tonumber(job_id), tonumber(branch_id))
        if entry and type(entry.key) == 'string' and entry.key ~= '' then
            return entry.key
        end
    end
    if self.roster_mod and type(self.roster_mod.list) == 'function'
        and tonumber(job_id) and tonumber(job_id) > 0
        and tonumber(branch_id) and tonumber(branch_id) > 0 then
        for _, entry in ipairs(self.roster_mod.list()) do
            if tonumber(entry.jobId) == tonumber(job_id) and tonumber(entry.branch) == tonumber(branch_id) then
                return entry.key
            end
        end
    end
    return soul_key or ''
end

function M:ensure_runtime(soul_key)
    if not self.registry_mod or type(soul_key) ~= 'string' or soul_key == '' then
        self.active_def = nil
        self.active_rt  = nil
        return
    end
    if self.active_def and self.active_def.key == soul_key and self.active_rt then
        return
    end
    local def = self.registry_mod.getSoul(soul_key)
    if def then
        self.active_def = def
        self.active_rt  = self.registry_mod.newRuntimeState(def)
    else
        self.active_def = nil
        self.active_rt  = nil
    end
end

function M:_apply_hud_payload(soul_key, job_id, unlocked, kv, now)
    local st = self.state
    local ts = now or ((type(vana) == 'table' and vana.time and vana.time.clock and vana.time.clock()) or os.clock())
    if tonumber(job_id) and tonumber(job_id) > 0 then
        st.job = tonumber(job_id)
    end
    st.unlocked = unlocked == true
    if type(soul_key) == 'string' and soul_key ~= '' then
        if st.soul_key ~= soul_key and self.gauge_mod and self.gauge_mod.reset then
            self.gauge_mod.reset()
        end
        st.soul_key = soul_key
        self.last_soul = soul_key
        local entry = self.identity and self.identity.by_key and self.identity.by_key[soul_key] or nil
        if entry and tonumber(entry.branch_id) then
            st.branch = tonumber(entry.branch_id)
        end
    end
    if type(kv) == 'table' then
        st.kv = kv
    end
    self.sync_at = ts
    self.last_packet_at = ts
    self.packet_count = self.packet_count + 1

    self:ensure_runtime(st.soul_key)
    if self.registry_mod and self.active_def and self.active_rt then
        self.registry_mod.applyServerData(self.active_def, self.active_rt, st.kv, ts)
    end
    if self.buffstrip_mod and self.buffstrip_mod.applyKv then
        self.buffstrip_mod.applyKv(st.kv, ts)
    end

    if self.character_mod and type(self.character_mod.observe_hud_identity) == 'function'
        and tonumber(st.branch) and tonumber(st.branch) > 0
        and tonumber(st.job) and tonumber(st.job) > 0 then
        self.character_mod:observe_hud_identity(st.branch, st.job)
    end
    return true
end

function M:handle_packet_in(id, data, now, size)
    local ts = now or ((type(vana) == 'table' and vana.time and vana.time.clock and vana.time.clock()) or os.clock())
    if id == 0x1FC then
        local pkt = decode_oxhd_0x1fc(data, size)
        if pkt then
            return self:_apply_hud_payload(pkt.soul_key, pkt.job_id, pkt.unlocked, pkt.kv, ts)
        end
        return false
    end
    if id == 0x017 then
        local msg = extract_0x017_message(data, size)
        if type(msg) ~= 'string' or msg == '' then return false end
        if msg:sub(1, 8) == '[SSHUD]|' or msg:sub(1, 8) == '[OXHUD]|' then
            local parts = split_char(msg, '|')
            local job_id   = tonumber(parts[2]) or 0
            local soul_key = trim(parts[3] or '')
            local unlocked = (trim(parts[4] or '') == '1')
            local kv_raw   = parts[5] or ''
            return self:_apply_hud_payload(soul_key, job_id, unlocked, parse_kv(kv_raw), ts)
        elseif msg:sub(1, 8) == '[SSBST]|' or msg:sub(1, 8) == '[OXBST]|' then
            local parts = split_char(msg, '|')
            local active = (trim(parts[2] or '') == '1')
            local stacks = tonumber(parts[3]) or 0
            local max_s  = tonumber(parts[4]) or 0
            local rem    = tonumber(parts[5]) or 0
            self.boost = active and { active = true, stacks = stacks, max = max_s, rem = rem, at = ts } or nil
            return true
        end
        return false
    end
    if id == 0x029 and self.buffstrip_mod and self.buffstrip_mod.notePacket029 then
        local pkt = (type(size) == 'number' and size > 0 and size <= #(data or '')) and data:sub(1, size) or data
        pcall(self.buffstrip_mod.notePacket029, pkt)
    end
    return false
end

function M:refresh(now)
    local st = self.state
    local ts = now or ((type(vana) == 'table' and vana.time and vana.time.clock and vana.time.clock()) or os.clock())

    -- 1. Merge native C++ HUD snapshot (0x1FC / [OXHUD])
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.hud) == 'function' then
        local snap = vana.soulspire.hud()
        if type(snap) == 'table' then
            local snap_ms = tonumber(snap.updated_ms) or 0
            if type(snap.soul_key) == 'string' and snap.soul_key ~= '' then
                st.soul_key = snap.soul_key
                st.unlocked = true
            end
            if type(snap.kv) == 'table' and next(snap.kv) ~= nil then
                if snap_ms ~= st.updated or next(st.kv) == nil then
                    st.kv = snap.kv
                    self.sync_at = ts
                    if self.buffstrip_mod and self.buffstrip_mod.applyKv then
                        self.buffstrip_mod.applyKv(st.kv, ts)
                    end
                end
            end
            st.updated = snap_ms
        end
    end

    -- 2. Merge authoritative native Soul identity (0x1FF / OXID)
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.identity) == 'function' then
        local id = vana.soulspire.identity()
        if type(id) == 'table' and id.known then
            st.job = tonumber(id.job) or st.job
            st.branch = tonumber(id.branch) or st.branch
            st.level = tonumber(id.effective_level) or st.level
            st.full_name = id.full_name
            st.short_name = id.short_name
            if (st.soul_key == '' or st.soul_key == nil) then
                local resolved = self:resolve_soul_key(id.soul_key, st.job, st.branch)
                if resolved ~= '' then
                    st.soul_key = resolved
                    st.unlocked = (st.branch > 0)
                end
            end
        end
    end

    -- 3. Merge live Character / CrystalSocket authoritative Soul state (instant display on login/zone)
    if self.character_mod and type(self.character_mod.get_header_identity) == 'function' then
        local okH, hdr = pcall(self.character_mod.get_header_identity, self.character_mod)
        if okH and type(hdr) == 'table' then
            local hJob = tonumber(hdr.job_id) or 0
            local hBr  = tonumber(hdr.branch) or 0
            if hJob > 0 then st.job = hJob end
            if hBr > 0 then
                st.branch = hBr
                st.unlocked = true
                local resolved = self:resolve_soul_key(hdr.soul_key or st.soul_key, hJob, hBr)
                if resolved ~= '' and (st.soul_key == '' or st.soul_key == nil) then
                    st.soul_key = resolved
                end
            end
        end
    end

    -- 4. Merge native player vitals & level
    if type(vana) == 'table' and vana.game and type(vana.game.self) == 'function' then
        local sid, _, job, lvl, _, _, _, _, hp, mp, tp, hpp, mpp = vana.game.self()
        if sid and sid > 0 then
            st.job   = tonumber(job) or st.job
            st.level = tonumber(lvl) or st.level
            st.hp    = tonumber(hp) or 0
            st.mp    = tonumber(mp) or 0
            st.tp    = tonumber(tp) or 0
            st.hpp   = tonumber(hpp) or 0
            st.mpp   = tonumber(mpp) or 0
        end
    end

    local effective_key = self.demo_key or st.soul_key or ''
    if effective_key ~= '' then
        self.last_soul = effective_key
        self:ensure_runtime(effective_key)
        if self.registry_mod and self.active_def and self.active_rt then
            self.registry_mod.applyServerData(self.active_def, self.active_rt, st.kv, ts)
            if type(vana) == 'table' and vana.game and type(vana.game.recasts) == 'function' then
                local okR, recasts = pcall(vana.game.recasts)
                if okR and type(recasts) == 'table' then
                    local lookup = {}
                    for k, v in pairs(recasts) do
                        local rid = tonumber(k)
                        local rem = tonumber(v)
                        if rid and rem then
                            lookup[rid] = rem
                        elseif type(v) == 'table' and tonumber(v.id) then
                            lookup[tonumber(v.id)] = tonumber(v.remaining or v.recast or 0) or 0
                        end
                    end
                    self.registry_mod.updateNativeRecasts(self.active_def, self.active_rt, lookup, ts)
                end
            end
            self.registry_mod.tickTimers(self.active_def, self.active_rt, ts)
        end
    end
end

function M:handle_command(args)
    local a = trim(args or '')
    local low = string.lower(a)
    if low == '' or low == 'toggle' then
        local vis = self:toggle()
        return 'Soul HUD ' .. (vis and 'shown' or 'hidden')
    elseif low == 'config' or low == 'settings' then
        self.config_open = not self.config_open
        return 'Soul HUD config ' .. (self.config_open and 'opened' or 'closed')
    elseif low == 'lock' then
        self:set_locked(true)
        return 'Soul HUD position locked.'
    elseif low == 'unlock' then
        self:set_locked(false)
        return 'Soul HUD position unlocked.'
    elseif low == 'minimal' or low == 'standard' or low == 'expanded' then
        self.cfg.layout = low
        self:save()
        return 'Soul HUD display mode set to ' .. low .. '.'
    elseif low == 'auto' or low == 'show' or low == 'hide' then
        self.cfg.mode = low
        self.visible = (low ~= 'hide')
        self:save()
        return 'Soul HUD visibility mode set to ' .. low .. '.'
    elseif low == 'reset' then
        self.cfg.x, self.cfg.y = 560, 40
        self.cfg.scale = 1.0
        self.cfg.opacity = 0.94
        self.reset_pos = true
        self:save()
        return 'Soul HUD position and scale reset.'
    elseif low == 'status' then
        local kv_n = 0
        for _ in pairs(self.state.kv or {}) do kv_n = kv_n + 1 end
        return string.format('Soul HUD: visible=%s mode=%s layout=%s soul=%s job=%d br=%d kv=%d pkts=%d frames=%d pos=(%d,%d)',
            tostring(self.visible), tostring(self.cfg.mode), tostring(self.cfg.layout),
            tostring(self.demo_key or self.state.soul_key or 'none'),
            tonumber(self.state.job) or 0, tonumber(self.state.branch) or 0,
            kv_n, self.packet_count, self.frame_count,
            tonumber(self.cfg.x) or 0, tonumber(self.cfg.y) or 0)
    elseif low:sub(1, 5) == 'scale' then
        local v = tonumber(trim(a:sub(6)))
        if v and v >= 0.5 and v <= 2.5 then
            self.cfg.scale = v
            self:save()
            return string.format('Soul HUD scale set to %.2f.', v)
        end
        return 'Usage: /soulhud scale <0.5..2.5>'
    elseif low:sub(1, 7) == 'opacity' then
        local v = tonumber(trim(a:sub(8)))
        if v and v >= 0.2 and v <= 1.0 then
            self.cfg.opacity = v
            self:save()
            return string.format('Soul HUD opacity set to %.2f.', v)
        end
        return 'Usage: /soulhud opacity <0.2..1.0>'
    elseif low:sub(1, 4) == 'demo' then
        local target = trim(a:sub(5))
        if target == '' or string.lower(target) == 'off' then
            self.demo_key = nil
            return 'Soul HUD demo preview cleared.'
        end
        self.demo_key = target
        return 'Soul HUD demo preview set to ' .. target .. '.'
    end
    return 'Soul HUD commands: /soulhud [config|status|lock|unlock|minimal|standard|expanded|scale <n>|opacity <n>|reset|demo <key|off>]'
end

function M:render(imgui, hub_open)
    if not imgui then return end

    -- Render Soul HUD Config modal when opened via right-click medallion or /soulhud config
    if self.config_open and self.renderer_mod and self.renderer_mod.renderConfig then
        self.renderer_mod.renderConfig(imgui, self.active_def, self.cfg, self.settings_mod, {
            isConfigOpen  = function() return self.config_open end,
            setConfigOpen = function(v) self.config_open = v == true end,
        })
    end

    if not self.visible then return end
    if self.cfg.mode == 'hide' then return end
    if hub_open and self.cfg.autoHideOnMenu ~= false then return end
    if type(vana) == 'table' and vana.ui and type(vana.ui.interface_hidden) == 'function' and vana.ui.interface_hidden() then
        return
    end

    local now = (type(vana) == 'table' and vana.time and vana.time.clock and vana.time.clock()) or os.clock()
    self:refresh(now)

    local st = self.state
    local soul_key = self.demo_key or st.soul_key or ''
    if soul_key == '' then
        return
    end

    self.frame_count = self.frame_count + 1

    -- Drive the FULL polished 66-Soul Combat Instrument (`soulhud_gauge.lua`)
    if self.gauge_mod and type(self.gauge_mod.render) == 'function' then
        local buffs = (self.buffstrip_mod and self.buffstrip_mod.buffs) or {}
        local ctx = {
            soulKey           = soul_key,
            kv                = st.kv or {},
            def               = self.active_def,
            rt                = self.active_rt,
            buffs             = buffs,
            boost             = self.boost,
            level             = st.level or 0,
            cfg               = self.cfg,
            now               = now,
            syncAt            = self.sync_at or now,
            demo              = self.demo_key ~= nil,
            resetPos          = self.reset_pos,
            onResetPosApplied = function() self.reset_pos = false end,
            callbacks         = {
                onSave         = function() self:save() end,
                onMove         = function() self:save() end,
                onToggleConfig = function() self.config_open = not self.config_open end,
            },
        }
        self.gauge_mod.render(imgui, ctx)
    end
end

return M
