-- SoulspireXI Core (VanaCore-Native): 66-Soul Universal HUD Driver
-- Drives the full polished 66-Soul HUD (`soulhud_layout`, `soulhud_gauge`, `soulhud_buffstrip`,
-- `soulhud_roster`, `souls/*.lua`) natively from `vana.soulspire.hud()`, `vana.soulspire.identity()`,
-- `vana.game.*`, and `vana.imgui` with zero Ashita dependencies.

local M = {}
M.__index = M

local function safe_require(name)
    local ok, mod = pcall(require, name)
    return ok and mod or nil
end

function M.new(addon_path, install_dir, identity_mod)
    local ox_icons = safe_require('ox_icons')
    if ox_icons and ox_icons.setRoot then
        ox_icons.setRoot(addon_path, install_dir)
    end
    local settings_mod = safe_require('soulhud_settings')
    local roster_mod   = safe_require('soulhud_roster')
    local gauge_mod    = safe_require('soulhud_gauge')
    local layout_mod   = safe_require('soulhud_layout')
    local renderer_mod = safe_require('soulhud_renderer')

    local cfg = (settings_mod and settings_mod.new) and settings_mod.new() or {
        x = 560, y = 40, scale = 1.0, opacity = 0.92,
        layout = 'standard', mode = 'auto', locked = false,
        showShared = true, autoHideOnMenu = true, pill = true,
        hiddenElements = {},
    }
    if settings_mod and settings_mod.load then
        settings_mod.load(cfg)
    end

    return setmetatable({
        identity     = identity_mod,
        settings_mod = settings_mod,
        roster_mod   = roster_mod,
        gauge_mod    = gauge_mod,
        layout_mod   = layout_mod,
        renderer_mod = renderer_mod,
        cfg          = cfg,
        visible      = true,
        last_soul    = '',
        state        = {
            soul_key = '',
            kv       = {},
            buffs    = {},
            hp       = 0, hp_max = 0, hpp = 0,
            mp       = 0, mp_max = 0, mpp = 0,
            tp       = 0,
            job      = 0, level = 0,
            updated  = 0,
        },
        frame_count  = 0,
    }, M)
end

function M:toggle()
    self.visible = not self.visible
    return self.visible
end

function M:set_locked(locked)
    self.cfg.locked = locked == true
    if self.settings_mod and self.settings_mod.save then
        self.settings_mod.save(self.cfg)
    end
end

function M:save()
    if self.settings_mod and self.settings_mod.save then
        self.settings_mod.save(self.cfg)
    end
end

function M:refresh()
    local st = self.state
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.hud) == 'function' then
        local snap = vana.soulspire.hud()
        if type(snap) == 'table' then
            if type(snap.soul_key) == 'string' and snap.soul_key ~= '' then
                st.soul_key = snap.soul_key
            end
            if type(snap.kv) == 'table' then
                st.kv = snap.kv
            end
            st.updated = tonumber(snap.updated_ms) or st.updated
        end
    end
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.identity) == 'function' then
        local id = vana.soulspire.identity()
        if type(id) == 'table' and id.known then
            if type(id.soul_key) == 'string' and id.soul_key ~= '' then
                st.soul_key = id.soul_key
            end
            st.job = tonumber(id.job) or st.job
            st.level = tonumber(id.effective_level) or st.level
            st.full_name = id.full_name
            st.short_name = id.short_name
        end
    end
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
    if st.soul_key ~= '' then
        self.last_soul = st.soul_key
    end
end

function M:render(imgui, hub_open)
    if not self.visible or not imgui then return end
    if self.cfg.mode == 'hide' then return end
    if hub_open and self.cfg.autoHideOnMenu then return end
    if type(vana) == 'table' and vana.ui and type(vana.ui.interface_hidden) == 'function' and vana.ui.interface_hidden() then
        return
    end

    self:refresh()
    local st = self.state
    local soul_key = st.soul_key or ''
    if soul_key == '' and self.cfg.mode ~= 'show' then
        return
    end

    self.frame_count = self.frame_count + 1

    -- Resolve authoritative 66-Soul HUD definition from soulhud_roster
    local spec = nil
    if self.roster_mod and type(self.roster_mod.get) == 'function' and soul_key ~= '' then
        spec = self.roster_mod.get(soul_key)
    end

    local scale = tonumber(self.cfg.scale) or 1.0
    local opacity = tonumber(self.cfg.opacity) or 0.92
    local flags = 1 + 4 + 32 + 64 -- NoTitleBar | NoSavedSettings | NoCollapse | AlwaysAutoResize
    if self.cfg.locked then
        flags = flags + 2 -- NoMove
    end

    if imgui.SetNextWindowPos then
        imgui.SetNextWindowPos({ self.cfg.x or 560, self.cfg.y or 40 }, 4) -- FirstUseEver
    end
    if imgui.SetNextWindowBgAlpha then
        imgui.SetNextWindowBgAlpha(opacity)
    end

    local open = imgui.Begin('Soulspire Soul HUD###soulspire_native_soulhud', true, flags)
    if open then
        local title = (spec and spec.displayName) or st.full_name or (soul_key ~= '' and soul_key or 'No Active Soul')
        local accent = (spec and spec.accent) or { 0.85, 0.70, 0.25, 1.0 }
        if imgui.TextColored then
            imgui.TextColored(accent, string.format('%s  (Lv.%d)', tostring(title), tonumber(st.level) or 0))
        else
            imgui.Text(string.format('%s  (Lv.%d)', tostring(title), tonumber(st.level) or 0))
        end

        -- Render configured Soul-specific dynamic elements (pips, gauges, timers, stances)
        local rendered_any = false
        if spec and type(spec.resources) == 'table' then
            for _, res in ipairs(spec.resources) do
                if not self.settings_mod or self.settings_mod.isElementVisible(self.cfg, soul_key, res.id) then
                    local raw_val = st.kv[res.key or res.id]
                    if raw_val ~= nil then
                        rendered_any = true
                        local max_key = res.maxKey or (res.key and (res.key .. 'max'))
                        local max_val = max_key and tonumber(st.kv[max_key]) or tonumber(res.max)
                        local num_val = tonumber(raw_val)
                        if res.kind == 'pips' and num_val and max_val and max_val > 0 then
                            local pips = {}
                            for i = 1, max_val do
                                pips[i] = (i <= num_val) and '[*]' or '[ ]'
                            end
                            imgui.Text(string.format('%s: %s (%d/%d)', tostring(res.label or res.id), table.concat(pips, ' '), num_val, max_val))
                        elseif max_val and max_val > 0 and num_val then
                            imgui.Text(string.format('%s: %d / %d', tostring(res.label or res.id), num_val, max_val))
                        else
                            imgui.Text(string.format('%s: %s', tostring(res.label or res.id), tostring(raw_val)))
                        end
                    end
                end
            end
        end

        -- Fallback: render all live [OXHUD] key/value telemetry so no Soul telemetry is ever hidden
        if not rendered_any then
            local keys = {}
            for k in pairs(st.kv) do keys[#keys + 1] = k end
            table.sort(keys)
            if #keys == 0 then
                if st.kv.sh then
                    local sh = tonumber(st.kv.sh) or 0
                    local shmax = tonumber(st.kv.shmax) or 3
                    imgui.Text(string.format('Shadows: %d / %d', sh, shmax))
                else
                    imgui.Text('Awaiting Soul telemetry...')
                end
            else
                for _, k in ipairs(keys) do
                    imgui.Text(string.format('%s: %s', tostring(k), tostring(st.kv[k])))
                end
            end
        end

        if imgui.GetWindowPos then
            local wx, wy = imgui.GetWindowPos()
            if type(wx) == 'number' and type(wy) == 'number' then
                self.cfg.x, self.cfg.y = math.floor(wx + 0.5), math.floor(wy + 0.5)
            end
        end
    end
    imgui.End()
end

return M
