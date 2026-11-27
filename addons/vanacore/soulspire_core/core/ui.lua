-- SoulspireXI Core: Full-Screen Dark-Fantasy RPG Shell (opened from native FFXI Commands Menu).
--
-- Aligned to the approved Soulforge visual target:
--   - Full-viewport dark cosmic dim scrim + Soulforge cavern backdrop (zero floating tool-window feel)
--   - Prominent Universal Top Header:
--       Left:   Faceted Soulspire crest + "SOULSPIREXI / — CORE —"
--       Center: Spacious floating beveled navigation ribbon built strictly from Core Registry,
--               with luminous Aether Cyan beveled-hex active tab and [LB] / [RB] shoulder cues
--       Right:  Three circular gilded utility buttons (? Help, * Scale, X Close)
--   - Central Body: Full-bleed module viewport (Weapon Mastery, Character, Soul Talents, etc.)
--   - Bottom Controls Bar: Centered keycap/gamepad prompt pills (zero debug clutter)

local bit   = require('bit')
local F     = require('core.foundations')
local Theme = require('core.theme')
local IG    = require('core.imgui_constants')

local UI = {}
UI.__index = UI

local function flag_or(...)
    local out = 0
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if type(v) == 'number' then
            out = bit.bor(out, v)
        end
    end
    return out
end

-- Crisp vector module icons for Core Registry modules.
local function draw_module_icon(dl, icon_name, cx, cy, r, colU32, accentU32)
    if not dl then return end
    if icon_name == 'character' then
        if dl.AddQuadFilled then
            dl:AddQuadFilled({ cx, cy - r }, { cx + r * 0.72, cy }, { cx, cy + r }, { cx - r * 0.72, cy }, colU32)
        end
        if dl.AddQuad then
            dl:AddQuad({ cx, cy - r }, { cx + r * 0.72, cy }, { cx, cy + r }, { cx - r * 0.72, cy }, accentU32, 1.3)
        end
    elseif icon_name == 'weapon_mastery' then
        if dl.AddLine then
            dl:AddLine({ cx - r * 0.75, cy + r * 0.75 }, { cx + r * 0.75, cy - r * 0.75 }, colU32, 2.0)
            dl:AddLine({ cx + r * 0.75, cy + r * 0.75 }, { cx - r * 0.75, cy - r * 0.75 }, colU32, 2.0)
            dl:AddLine({ cx - r * 0.55, cy + r * 0.15 }, { cx - r * 0.15, cy + r * 0.55 }, accentU32, 1.6)
            dl:AddLine({ cx + r * 0.55, cy + r * 0.15 }, { cx + r * 0.15, cy + r * 0.55 }, accentU32, 1.6)
        end
    elseif icon_name == 'soul_talents' then
        if dl.AddLine then
            dl:AddLine({ cx, cy + r * 0.65 }, { cx, cy - r * 0.65 }, accentU32, 1.4)
            dl:AddLine({ cx, cy }, { cx - r * 0.65, cy - r * 0.50 }, accentU32, 1.4)
            dl:AddLine({ cx, cy }, { cx + r * 0.65, cy - r * 0.50 }, accentU32, 1.4)
        end
        if dl.AddCircleFilled then
            dl:AddCircleFilled({ cx, cy + r * 0.65 }, r * 0.25, colU32, 10)
            dl:AddCircleFilled({ cx, cy - r * 0.65 }, r * 0.25, colU32, 10)
            dl:AddCircleFilled({ cx - r * 0.65, cy - r * 0.50 }, r * 0.22, colU32, 10)
            dl:AddCircleFilled({ cx + r * 0.65, cy - r * 0.50 }, r * 0.22, colU32, 10)
        end
    elseif icon_name == 'abilities' then
        if dl.AddLine then
            dl:AddLine({ cx, cy - r * 0.85 }, { cx, cy + r * 0.85 }, colU32, 1.6)
            dl:AddLine({ cx - r * 0.85, cy }, { cx + r * 0.85, cy }, colU32, 1.6)
            dl:AddLine({ cx - r * 0.55, cy - r * 0.55 }, { cx + r * 0.55, cy + r * 0.55 }, accentU32, 1.2)
            dl:AddLine({ cx + r * 0.55, cy - r * 0.55 }, { cx - r * 0.55, cy + r * 0.55 }, accentU32, 1.2)
        end
    elseif icon_name == 'equipment' then
        if dl.AddQuad then
            dl:AddQuad({ cx - r * 0.65, cy - r * 0.70 }, { cx + r * 0.65, cy - r * 0.70 },
                { cx + r * 0.50, cy + r * 0.30 }, { cx - r * 0.50, cy + r * 0.30 }, colU32, 1.5)
        end
        if dl.AddLine then
            dl:AddLine({ cx - r * 0.50, cy + r * 0.30 }, { cx, cy + r * 0.85 }, colU32, 1.5)
            dl:AddLine({ cx + r * 0.50, cy + r * 0.30 }, { cx, cy + r * 0.85 }, colU32, 1.5)
        end
    else
        if dl.AddRect then
            dl:AddRect({ cx - r * 0.65, cy - r * 0.75 }, { cx + r * 0.65, cy + r * 0.75 }, colU32, 2, 0, 1.5)
        end
        if dl.AddLine then
            dl:AddLine({ cx, cy - r * 0.75 }, { cx, cy + r * 0.75 }, accentU32, 1.3)
        end
    end
end

local function draw_crest(dl, x, y, size, tex_id)
    if dl and dl.AddCircleFilled then
        dl:AddCircleFilled({ x + size * 0.5, y + size * 0.5 }, size * 0.58, F.abgr(F.rgba.aether_cyan, 0.16), 24)
    end
    if tex_id and dl and dl.AddImage then
        dl:AddImage(tex_id, { x, y }, { x + size, y + size })
        return
    end
    F.drawCrystalMedallion(dl, x + size * 0.5, y + size * 0.5, size * 0.46, {
        rim   = F.u32.aether_cyan,
        core  = F.rgba.crystal_violet,
        studs = false,
    })
end

function UI.new(imgui, registry, focus, assets, opts)
    opts = opts or {}
    return setmetatable({
        imgui            = imgui,
        registry         = registry,
        focus            = focus,
        assets           = assets,
        crest_tex        = nil,
        backdrop_tex     = nil,
        chamber_tex      = nil,
        ui_scale         = F.clamp(tonumber(opts.ui_scale) or 1.0, 0.75, 1.50),
        on_scale_change  = opts.on_scale_change,
        get_identity     = opts.get_identity,
        get_last_device  = opts.get_last_device,
        input            = opts.input,
        scale_panel_open = false,
        last_viewport_w   = 0,
        last_viewport_h   = 0,
        last_dock         = { visible = false, hovered = false, clicks = 0 },
        last_layout       = nil,
        focus_window_once = false,
    }, UI)
end

function UI:request_window_focus()
    self.focus_window_once = true
end

function UI:set_scale(scale)
    self.ui_scale = F.clamp(tonumber(scale) or 1.0, 0.75, 1.50)
    if type(self.on_scale_change) == 'function' then
        self.on_scale_change(self.ui_scale)
    end
end

function UI:label_for(action, device)
    if self.input and type(self.input.label_for) == 'function' then
        local ok, lbl = pcall(self.input.label_for, self.input, action, device)
        if ok and type(lbl) == 'string' and lbl ~= '' then
            return lbl
        end
    end
    local fallback = (device == 'keyboard' or device == 'mouse') and {
        confirm = 'Enter', cancel = 'Esc', context = 'X', details = 'Y',
        module_prev = 'Q', module_next = 'E', modules = 'Q/E', nav = 'Arrows',
    } or {
        confirm = 'A', cancel = 'B', context = 'X', details = 'Y',
        module_prev = 'LB', module_next = 'RB', modules = 'LB/RB', nav = 'D-Pad',
    }
    return fallback[action] or tostring(action)
end

function UI:ensure_assets()
    if self.assets then
        if self.crest_tex == nil then
            self.crest_tex = self.assets:load_texture('soulspire_crest') or false
        end
        if self.backdrop_tex == nil then
            self.backdrop_tex = self.assets:load_texture('soulforge_backdrop') or false
        end
        if self.chamber_tex == nil then
            self.chamber_tex = self.assets:load_texture('character_chamber_bg') or false
        end
    end
    return (self.crest_tex ~= false and self.crest_tex or nil),
           (self.backdrop_tex ~= false and self.backdrop_tex or nil),
           (self.chamber_tex ~= false and self.chamber_tex or nil)
end

function UI:compute_layout(viewW, viewH)
    return F.computeViewportLayout(viewW, viewH, self.ui_scale or 1.0, {
        maxLogicalW = 2480,
        maxLogicalH = 1400,
    })
end

-- Main Menu integration is handled natively inside FFXI's Commands menu by
-- soulspire_native.dll; no floating ImGui Main Menu button is rendered.
function UI:draw_main_menu_dock(_native)
    self.last_dock.visible = false
    self.last_dock.hovered = false
end

-- Render an honest unavailable module panel with full Soulforge dark-fantasy framing.
function UI:_draw_unavailable_module(dl, L, x, y, w, h, mod, mode_label)
    local imgui = self.imgui
    local s = L.uiScale or 1.0
    local _, backdropTex, chamberTex = self:ensure_assets()

    F.drawOrnatePanel(dl, x, y, w, h, {
        texId      = chamberTex or backdropTex,
        texTint    = F.abgr(F.rgba.white, 0.45),
        scrimAlpha = 0.62,
        border     = F.u32.soul_gold_dim,
        accent     = F.u32.soul_gold,
        corners    = (L.ornamentLevel >= 1),
        shadow     = false,
    })

    local cardW = math.min(w - math.floor(48 * s), math.floor(660 * s))
    local cardH = math.min(h - math.floor(48 * s), math.floor(310 * s))
    local cx = x + math.floor((w - cardW) * 0.5)
    local cy = y + math.floor((h - cardH) * 0.5)

    F.drawOrnatePanel(dl, cx, cy, cardW, cardH, {
        fillTop  = F.abgr(F.hex('#141A2D', 0.96)),
        fillBot  = F.abgr(F.hex('#080C17', 0.98)),
        border   = F.u32.soul_gold,
        accent   = F.u32.soul_gold_bright,
        rounding = 7,
        corners  = true,
        shadow   = true,
    })

    local pad = math.floor(26 * s)
    F.drawCrystalMedallion(dl, cx + pad + 20 * s, cy + pad + 20 * s, 20 * s, {
        rim   = F.u32.soul_gold_dim,
        core  = F.rgba.crystal_violet,
        studs = false,
    })
    draw_module_icon(dl, mod.icon, cx + pad + 20 * s, cy + pad + 20 * s, 11 * s, F.u32.soul_gold_bright, F.u32.aether_cyan)

    F.drawShadowText(imgui, dl, cx + pad + 52 * s, cy + pad + 6 * s,
        string.upper(mod.label), F.u32.soul_gold_bright, 1.24 * s, 'l')

    F.drawBadgePill(imgui, dl, cx + cardW - pad - math.floor(132 * s), cy + pad + 6 * s, '[x] UNAVAILABLE', {
        width     = math.floor(132 * s),
        height    = math.floor(26 * s),
        fill      = F.u32.abyss_solid,
        border    = F.u32.soul_gold_dim,
        textCol   = F.u32.text_secondary,
        fontScale = 0.80 * s,
    })

    F.drawDivider(dl, cx + pad, cy + pad + 52 * s, cardW - pad * 2, F.u32.soul_gold_dim)

    local ty = cy + pad + 70 * s
    local chars = math.max(30, math.floor((cardW - pad * 2) / (8.4 * s)))
    for _, line in ipairs(F.wrapLines(mod.summary or 'This module is not yet integrated.', chars, 3)) do
        F.drawShadowText(imgui, dl, cx + pad, ty, line, F.u32.text_primary, 0.96 * s, 'l')
        ty = ty + math.floor(22 * s)
    end
    ty = ty + 10 * s

    local detail_msg = mod.unavailable_reason or mod.details or 'Module integration pending in a future milestone.'
    for _, line in ipairs(F.wrapLines(detail_msg, chars, 4)) do
        F.drawShadowText(imgui, dl, cx + pad, ty, line, F.u32.text_secondary, 0.88 * s, 'l')
        ty = ty + math.floor(20 * s)
    end

    local companion = mod.existing_addon and (mod.existing_addon .. ' (remains active untouched)') or 'Scheduled for upcoming Core module release'
    F.drawShadowText(imgui, dl, cx + pad, cy + cardH - pad - 40 * s,
        'Companion System: ' .. companion, F.u32.text_muted, 0.82 * s, 'l')
    F.drawShadowText(imgui, dl, cx + pad, cy + cardH - pad - 18 * s,
        'Integration: ' .. tostring(mode_label) .. '  |  Use ' .. self:label_for('modules', 'gamepad') .. ' to return to live modules.',
        F.u32.aether_cyan, 0.82 * s, 'l')
end

-- Render the compact Settings & Controller Bindings Overlay modal (* utility button).
function UI:_draw_settings_overlay(dl, L, wx, wy, ww, wh)
    local imgui = self.imgui
    local s = L.uiScale or 1.0
    local inp = self.input

    dl:AddRectFilled({ wx, wy }, { wx + ww, wy + wh }, F.abgr(F.rgba.black, 0.72), 8)

    local mw = math.min(ww - math.floor(36 * s), math.floor(720 * s))
    local mh = math.min(wh - math.floor(36 * s), math.floor(520 * s))
    local mx = wx + math.floor((ww - mw) * 0.5)
    local my = wy + math.floor((wh - mh) * 0.5)

    F.drawOrnatePanel(dl, mx, my, mw, mh, {
        fillTop  = F.abgr(F.hex('#151C30', 0.98)),
        fillBot  = F.abgr(F.hex('#080C15', 0.99)),
        border   = F.u32.soul_gold,
        accent   = F.u32.aether_cyan,
        rounding = 7,
        corners  = true,
        shadow   = true,
    })

    local pad = math.floor(20 * s)
    local cy = my + math.floor(14 * s)
    F.drawShadowText(imgui, dl, mx + pad, cy, 'SOULSPIREXI CORE — SETTINGS & CONTROLLER BINDINGS', F.u32.soul_gold_bright, 1.02 * s, 'l')
    cy = cy + math.floor(26 * s)
    F.drawDivider(dl, mx + pad, cy, mw - pad * 2, F.u32.soul_gold_dim)
    cy = cy + math.floor(10 * s)

    -- Row 1: UI Scale
    local btnH = math.floor(24 * s)
    F.drawShadowText(imgui, dl, mx + pad, cy + 4 * s, 'UI Scale:', F.u32.text_primary, 0.86 * s, 'l')
    local sx = mx + pad + math.floor(92 * s)
    if F.drawActionButton(imgui, dl, '##set_sc_dn', sx, cy, math.floor(28 * s), btnH, '-', 'neutral', { fontScale = 0.84 * s }) then
        self:set_scale(math.floor((self.ui_scale - 0.10) * 100 + 0.5) / 100)
    end
    F.drawShadowText(imgui, dl, sx + math.floor(54 * s), cy + 4 * s,
        string.format('%d%%', math.floor(self.ui_scale * 100 + 0.5)), F.u32.soul_gold_bright, 0.84 * s, 'c')
    if F.drawActionButton(imgui, dl, '##set_sc_up', sx + math.floor(80 * s), cy, math.floor(28 * s), btnH, '+', 'neutral', { fontScale = 0.84 * s }) then
        self:set_scale(math.floor((self.ui_scale + 0.10) * 100 + 0.5) / 100)
    end

    if inp then
        local diag = inp:get_diagnostics()
        local backend = diag.active_backend or 'xinput'
        local src_text = string.format('Backend: %s  |  Source: %s',
            string.upper(backend), tostring(diag.config_source or 'defaults'))
        F.drawShadowText(imgui, dl, mx + mw - pad, cy + 4 * s, src_text, F.u32.aether_cyan, 0.80 * s, 'r')
    end

    cy = cy + math.floor(32 * s)
    F.drawDivider(dl, mx + pad, cy, mw - pad * 2, F.u32.border_strong)
    cy = cy + math.floor(10 * s)

    if inp then
        -- Row 2: Use FFXI Bindings toggle + Refresh Existing Bindings
        local use_ffxi = (inp.use_ffxi_bindings == true)
        local toggleLbl = use_ffxi and '[ON] Use FFXI Bindings' or '[OFF] Use FFXI Bindings'
        if F.drawActionButton(imgui, dl, '##set_use_ffxi', mx + pad, cy, math.floor(196 * s), btnH,
            toggleLbl, use_ffxi and 'cyan' or 'neutral', { fontScale = 0.80 * s }) then
            inp:set_use_ffxi_bindings(not use_ffxi)
        end
        if F.drawActionButton(imgui, dl, '##set_refresh_ffxi', mx + pad + math.floor(206 * s), cy, math.floor(196 * s), btnH,
            'Refresh Existing Bindings', 'neutral', { fontScale = 0.80 * s }) then
            inp:import_ffxi_bindings()
        end
        cy = cy + math.floor(30 * s)

        -- Conflict banner if any binding conflict exists
        local conflicts = inp:get_conflicts()
        if #conflicts > 0 then
            local diag = inp:get_diagnostics()
            F.drawShadowText(imgui, dl, mx + pad, cy,
                'Conflict Detected: ' .. tostring(diag.conflict_summary), F.u32.danger, 0.80 * s, 'l')
            cy = cy + math.floor(20 * s)
        end

        -- Per-action binding rows
        local backend = inp.active_backend or inp.detected_backend or 'xinput'
        local actions = inp.CONFIGURABLE_ACTIONS or {}
        local rowH = math.floor(26 * s)
        for _, item in ipairs(actions) do
            local info = inp:get_action_info(item.id, backend)
            F.drawShadowText(imgui, dl, mx + pad, cy + 4 * s, item.label, F.u32.text_primary, 0.82 * s, 'l')

            local provTag = (info.provenance == 'inherited' and '[Inherited]')
                or (info.provenance == 'overridden' and '[Override]')
                or '[Default]'
            local provCol = (info.provenance == 'inherited' and F.u32.aether_cyan)
                or (info.provenance == 'overridden' and F.u32.soul_gold_bright)
                or F.u32.text_muted
            F.drawShadowText(imgui, dl, mx + pad + math.floor(200 * s), cy + 4 * s, provTag, provCol, 0.78 * s, 'l')

            local ctrlX = mx + mw - pad - math.floor(240 * s)
            if F.drawActionButton(imgui, dl, '##bind_prev_' .. item.id, ctrlX, cy, math.floor(26 * s), math.floor(22 * s), '<', 'neutral', { fontScale = 0.78 * s }) then
                inp:cycle_action_override(backend, item.id, -1)
            end
            F.drawShadowText(imgui, dl, ctrlX + math.floor(72 * s), cy + 3 * s, info.label, F.u32.white, 0.82 * s, 'c')
            if F.drawActionButton(imgui, dl, '##bind_next_' .. item.id, ctrlX + math.floor(118 * s), cy, math.floor(26 * s), math.floor(22 * s), '>', 'neutral', { fontScale = 0.78 * s }) then
                inp:cycle_action_override(backend, item.id, 1)
            end
            if info.provenance == 'overridden' then
                if F.drawActionButton(imgui, dl, '##bind_clr_' .. item.id, ctrlX + math.floor(154 * s), cy, math.floor(82 * s), math.floor(22 * s), 'Clear', 'neutral', { fontScale = 0.74 * s }) then
                    inp:clear_action_override(backend, item.id)
                end
            end
            cy = cy + rowH
        end

        -- Bottom utility buttons
        local footY = my + mh - pad - math.floor(32 * s)
        if F.drawActionButton(imgui, dl, '##set_restore_inh', mx + pad, footY, math.floor(210 * s), math.floor(30 * s),
            'Restore Inherited Bindings', 'cyan', { fontScale = 0.78 * s }) then
            inp:restore_inherited_bindings()
        end
        if F.drawActionButton(imgui, dl, '##set_restore_def', mx + pad + math.floor(220 * s), footY, math.floor(196 * s), math.floor(30 * s),
            'Restore Standard Defaults', 'neutral', { fontScale = 0.78 * s }) then
            inp:restore_standard_defaults()
        end
    end

    local closeW, closeH = math.floor(110 * s), math.floor(30 * s)
    if F.drawBeveledCtaButton(imgui, dl, '##set_close', mx + mw - pad - closeW, my + mh - pad - closeH, closeW, closeH,
        'CLOSE', 'gold', { fontScale = 0.82 * s }) then
        self.scale_panel_open = false
    end
end

-- Render the Details & Controls Help Overlay modal with dynamic active button labels.
function UI:_draw_help_overlay(dl, L, wx, wy, ww, wh, active)
    local imgui = self.imgui
    local s = L.uiScale or 1.0

    dl:AddRectFilled({ wx, wy }, { wx + ww, wy + wh }, F.abgr(F.rgba.black, 0.72), 8)

    local mw = math.min(ww - math.floor(40 * s), math.floor(640 * s))
    local mh = math.min(wh - math.floor(40 * s), math.floor(400 * s))
    local mx = wx + math.floor((ww - mw) * 0.5)
    local my = wy + math.floor((wh - mh) * 0.5)

    F.drawOrnatePanel(dl, mx, my, mw, mh, {
        fillTop  = F.abgr(F.hex('#151C30', 0.98)),
        fillBot  = F.abgr(F.hex('#080C15', 0.99)),
        border   = F.u32.soul_gold,
        accent   = F.u32.aether_cyan,
        rounding = 7,
        corners  = true,
        shadow   = true,
    })

    local pad = math.floor(22 * s)
    F.drawShadowText(imgui, dl, mx + pad, my + 16 * s, 'SOULSPIREXI CORE — CONTROLS & DETAILS', F.u32.soul_gold_bright, 1.08 * s, 'l')
    F.drawDivider(dl, mx + pad, my + 44 * s, mw - pad * 2, F.u32.soul_gold_dim)

    local lbl_mod  = self:label_for('modules', 'gamepad')
    local lbl_nav  = self:label_for('nav', 'gamepad')
    local lbl_ok   = self:label_for('confirm', 'gamepad')
    local lbl_back = self:label_for('cancel', 'gamepad')
    local lbl_ctx  = self:label_for('context', 'gamepad')
    local lbl_help = self:label_for('details', 'gamepad')

    local rows = {
        { lbl_mod .. '  (Q / E)',                  'Switch Core modules (Character, Weapon Mastery, Soul Talents...)' },
        { lbl_nav .. ' / Left Stick / Arrows',     'Navigate arsenal, weapon filters, skillchains & orbital talent tree' },
        { lbl_ok .. '  (Enter / Space)',           'Select / Inspect / Open Forge Confirmation' },
        { lbl_back .. '  (Escape / Backspace)',    'Back one level / Cancel modal / Close SoulspireXI Core' },
        { lbl_ctx .. '  (X / F / Delete)',         'Context action (Cycle Weapon / Refund / Sync)' },
        { 'R  /  T',                               'Respec active Weapon Skill  |  Toggle Path Spotlight' },
        { lbl_help .. '  (Y / H / F1)',            'Toggle this Details & Controls overlay' },
    }
    local cy = my + 58 * s
    for _, r in ipairs(rows) do
        F.drawShadowText(imgui, dl, mx + pad, cy, r[1], F.u32.aether_cyan, 0.86 * s, 'l')
        F.drawShadowText(imgui, dl, mx + pad + math.floor(215 * s), cy,
            F.fitText(imgui, r[2], mw - pad * 2 - math.floor(218 * s), 0.84 * s),
            F.u32.text_primary, 0.84 * s, 'l')
        cy = cy + math.floor(25 * s)
    end

    cy = cy + 8 * s
    F.drawDivider(dl, mx + pad, cy, mw - pad * 2, F.u32.border_strong)
    cy = cy + 12 * s
    if active then
        F.drawShadowText(imgui, dl, mx + pad, cy, 'ACTIVE MODULE: ' .. string.upper(active.label), F.u32.soul_gold, 0.88 * s, 'l')
        cy = cy + 20 * s
        local chars = math.max(32, math.floor((mw - pad * 2) / (8.0 * s)))
        for _, line in ipairs(F.wrapLines(active.details or active.summary or '', chars, 3)) do
            F.drawShadowText(imgui, dl, mx + pad, cy, line, F.u32.text_secondary, 0.82 * s, 'l')
            cy = cy + math.floor(18 * s)
        end
    end

    local btnW, btnH = math.floor(164 * s), math.floor(34 * s)
    if F.drawBeveledCtaButton(imgui, dl, '##core_help_close', mx + mw - pad - btnW, my + mh - pad - btnH, btnW, btnH,
        'CLOSE [' .. lbl_back .. ' / ' .. lbl_help .. ']', 'gold', { fontScale = 0.86 * s }) then
        self.focus.help_open = false
    end
end

-- Unified Full-Screen SoulspireXI Core Modal Shell.
function UI:draw_hub(native, bridge_mode)
    if not self.focus.hub_open then return end

    local imgui = self.imgui
    local vw, vh = F.getViewportSize(imgui)
    local L = self:compute_layout(vw, vh)
    self.last_layout = L
    local s = L.uiScale
    local crestTex, backdropTex = self:ensure_assets()

    local resized = (self.last_viewport_w ~= vw or self.last_viewport_h ~= vh)
    if resized then
        self.last_viewport_w = vw
        self.last_viewport_h = vh
    end

    -- Full-viewport dark cosmic dim + backdrop behind modal (eliminates "floating window" look)
    if imgui.GetBackgroundDrawList then
        local bgdl = imgui.GetBackgroundDrawList()
        if bgdl and bgdl.AddRectFilled then
            bgdl:AddRectFilled({ 0, 0 }, { vw, vh }, F.abgr(F.rgba.abyss_solid, 0.84), 0)
            if backdropTex and bgdl.AddImage then
                bgdl:AddImage(backdropTex, { 0, 0 }, { vw, vh }, { 0, 0 }, { 1, 1 }, F.abgr(F.rgba.white, 0.42))
            end
            bgdl:AddRectFilled({ 0, 0 }, { vw, vh }, F.abgr(F.rgba.abyss_solid, 0.46), 0)
        end
    end

    local WF = IG.WindowFlags
    local win_flags = flag_or(
        WF.NoTitleBar,
        WF.NoResize,
        WF.NoMove,
        WF.NoScrollbar,
        WF.NoScrollWithMouse,
        WF.NoCollapse,
        WF.NoNav,
        WF.NoBackground,
        WF.NoSavedSettings
    )

    if imgui.SetNextWindowSize then imgui.SetNextWindowSize({ L.winW, L.winH }, IG.Cond.Always) end
    if imgui.SetNextWindowPos then
        imgui.SetNextWindowPos({ L.posX, L.posY }, IG.Cond.Always)
    end
    if self.focus_window_once then
        self.focus_window_once = false
        if imgui.SetNextWindowFocus then
            pcall(imgui.SetNextWindowFocus)
        end
    end
    local pushed_vars = 0
    if imgui.PushStyleVar then
        imgui.PushStyleVar(IG.StyleVar.WindowPadding, { 0, 0 })
        imgui.PushStyleVar(IG.StyleVar.WindowBorderSize, 0.0)
        imgui.PushStyleVar(IG.StyleVar.WindowRounding, 0.0)
        pushed_vars = 3
    end

    local opened = imgui.Begin('##soulspire_core_hub', nil, win_flags)
    if opened then
        local wx, wy = 0, 0
        if imgui.GetWindowPos then
            wx, wy = F.toXY(imgui.GetWindowPos())
        end
        local dl = imgui.GetWindowDrawList and imgui.GetWindowDrawList() or nil

        -- Full-screen cosmic dark-fantasy chamber canvas
        F.drawOrnatePanel(dl, wx, wy, L.winW, L.winH, {
            texId      = backdropTex,
            texTint    = F.abgr(F.rgba.white, 0.56),
            scrimAlpha = 0.56,
            fillTop    = F.abgr(F.hex('#0D1322', 0.96)),
            fillBot    = F.abgr(F.hex('#050810', 0.99)),
            border     = F.u32.soul_gold_dim,
            accent     = F.u32.soul_gold,
            rounding   = 8,
            corners    = true,
            shadow     = true,
        })

        local innerX  = wx + L.pad
        local headerY = wy + math.floor(L.pad * 0.45)
        local headerH = math.floor(((L.mode == 'focused' and 52) or 62) * s)
        local footerH = math.floor(((L.mode == 'focused' and 34) or 40) * s)
        local bodyY   = headerY + headerH + math.floor(L.gap * 0.75)
        local bodyH   = math.max(200, (wy + L.winH - math.floor(L.pad * 0.65)) - bodyY - footerH - math.floor(L.gap * 0.75))
        local footerY = bodyY + bodyH + math.floor(L.gap * 0.75)

        -- A. Universal Top Navigation Header (Approved Soulforge Mockup Standard)
        if dl then
            F.drawGradRect(dl, wx + 2, wy + 2, wx + L.winW - 2, headerY + headerH + 4,
                F.abgr(F.hex('#0C1324', 0.88)), F.abgr(F.hex('#060A14', 0.94)))
            -- Luminous golden horizon hairline with subtle center accent
            dl:AddLine({ wx + 16, headerY + headerH + 3 }, { wx + L.winW - 16, headerY + headerH + 3 },
                F.abgr(F.rgba.soul_gold_dim, 0.62), 1.2)
            dl:AddLine({ wx + L.winW * 0.25, headerY + headerH + 3 }, { wx + L.winW * 0.75, headerY + headerH + 3 },
                F.abgr(F.rgba.aether_cyan, 0.35), 1.2)
        end

        -- Far Left: Prominent Soulspire Crest + "SOULSPIREXI / — CORE —"
        local crestSz = math.floor(math.min(48 * s, headerH - 4))
        draw_crest(dl, innerX + 4 * s, headerY + math.floor((headerH - crestSz) * 0.5), crestSz, crestTex)
        local brandX = innerX + 14 * s + crestSz
        F.drawShadowText(imgui, dl, brandX, headerY + 8 * s, 'SOULSPIREXI', F.u32.white, 1.24 * s, 'l')
        if L.mode ~= 'focused' then
            local coreSubY = headerY + 34 * s
            local coreMidX = brandX + 62 * s
            if dl and dl.AddLine then
                dl:AddLine({ brandX + 2 * s, coreSubY + 6 * s }, { coreMidX - 28 * s, coreSubY + 6 * s }, F.u32.soul_gold_dim, 1.1)
                dl:AddLine({ coreMidX + 28 * s, coreSubY + 6 * s }, { brandX + 124 * s, coreSubY + 6 * s }, F.u32.soul_gold_dim, 1.1)
            end
            F.drawShadowText(imgui, dl, coreMidX, coreSubY - 1, 'CORE', F.u32.soul_gold_bright, 0.80 * s, 'c')
        end
        local brandEnd = brandX + math.floor((L.mode == 'focused' and 120 or 162) * s)

        -- Far Right: Circular gilded utility buttons (? Help, * Scale, X Close)
        local circR = math.floor(15 * s)
        local circY = headerY + headerH * 0.5
        local rightX = innerX + L.innerW - 6 * s

        local closeCx = rightX - circR
        if F.drawCircleIconBtn(imgui, dl, '##core_close', closeCx, circY, circR, 'X', { fontScale = 0.88 * s }) then
            self.focus:close_hub(native)
        end

        local setCx = closeCx - circR * 2 - math.floor(10 * s)
        if F.drawCircleIconBtn(imgui, dl, '##core_scale_btn', setCx, circY, circR, '*', {
            active = self.scale_panel_open, fontScale = 1.02 * s,
        }) then
            self.scale_panel_open = not self.scale_panel_open
        end

        local helpCx = setCx - circR * 2 - math.floor(10 * s)
        if F.drawCircleIconBtn(imgui, dl, '##core_help', helpCx, circY, circR, '?', {
            active = self.focus.help_open, fontScale = 0.92 * s,
        }) then
            self.focus.help_open = not self.focus.help_open
        end

        -- Optional inline compact scale adjuster when Settings circle is toggled
        local navRightLimit = helpCx - circR - math.floor(14 * s)
        if self.scale_panel_open and L.mode ~= 'focused' then
            local stepW = math.floor(24 * s)
            local btnH  = math.floor(26 * s)
            local btnY  = headerY + math.floor((headerH - btnH) * 0.5)
            local sx = navRightLimit - stepW
            if F.drawActionButton(imgui, dl, '##core_sc_up', sx, btnY, stepW, btnH, '+', 'neutral', { fontScale = 0.84 * s }) then
                self:set_scale(math.floor((self.ui_scale + 0.10) * 100 + 0.5) / 100)
            end
            local pctW = math.floor(44 * s)
            sx = sx - pctW - 2 * s
            F.drawShadowText(imgui, dl, sx + pctW * 0.5, btnY + 5 * s,
                string.format('%d%%', math.floor(self.ui_scale * 100 + 0.5)), F.u32.soul_gold_bright, 0.80 * s, 'c')
            sx = sx - stepW - 2 * s
            if F.drawActionButton(imgui, dl, '##core_sc_dn', sx, btnY, stepW, btnH, '-', 'neutral', { fontScale = 0.84 * s }) then
                self:set_scale(math.floor((self.ui_scale - 0.10) * 100 + 0.5) / 100)
            end
            navRightLimit = sx - math.floor(12 * s)
        end

        -- Center: Floating Beveled Dark Ribbon housing Dynamic Registry Tabs
        local modules = (type(self.registry.visible_sections) == 'function')
            and self.registry:visible_sections(self.dev_mode == true)
            or self.registry:sections()
        local count = math.max(1, #modules)
        local availNavW = math.max(220, navRightLimit - brandEnd - math.floor(14 * s))
        local idealRibW = math.min(availNavW, math.floor(count * 196 * s + 96 * s))
        local ribX = brandEnd + math.floor((availNavW - idealRibW) * 0.5) + math.floor(7 * s)
        local ribH = math.floor(((L.mode == 'focused' and 34) or 42) * s)
        local ribY = headerY + math.floor((headerH - ribH) * 0.5)

        if dl then
            F.drawBeveledPill(dl, ribX, ribY, idealRibW, ribH, {
                bevel     = math.floor(16 * s),
                fillTop   = F.abgr(F.hex('#101728', 0.94)),
                fillBot   = F.abgr(F.hex('#070B14', 0.97)),
                border    = F.abgr(F.rgba.soul_gold_dim, 0.72),
                highlight = F.abgr(F.rgba.soul_gold_bright, 0.22),
                thickness = 1.2,
            })
        end

        -- Dynamic shoulder/module-switch buttons flanking the dynamic tab strip
        local last_device = 'gamepad'
        if type(self.get_last_device) == 'function' then
            local okDev, devRes = pcall(self.get_last_device)
            if okDev and type(devRes) == 'string' then last_device = devRes end
        end
        local label_fn = function(act, dev) return self:label_for(act, dev or last_device) end

        local prevLbl = self:label_for('module_prev', last_device)
        local nextLbl = self:label_for('module_next', last_device)
        local bmpW = math.floor(math.max(32, math.max(#prevLbl, #nextLbl) * 8 + 14) * s)
        local bmpH = math.floor(24 * s)
        local bmpY = ribY + math.floor((ribH - bmpH) * 0.5)
        if F.drawActionButton(imgui, dl, '##core_lb', ribX + math.floor(16 * s), bmpY, bmpW, bmpH, prevLbl, 'neutral', { fontScale = 0.72 * s }) then
            self.focus:switch_module(-1)
        end
        if F.drawActionButton(imgui, dl, '##core_rb', ribX + idealRibW - math.floor(16 * s) - bmpW, bmpY, bmpW, bmpH, nextLbl, 'neutral', { fontScale = 0.72 * s }) then
            self.focus:switch_module(1)
        end

        local tabsX = ribX + math.floor(22 * s) + bmpW
        local tabsW = math.max(100, idealRibW - (math.floor(22 * s) + bmpW) * 2)
        local tabGap = math.floor(4 * s)
        local tabW = math.floor((tabsW - tabGap * (count - 1)) / count)
        local tabH = ribH - math.floor(2 * s)
        local tabY = ribY + math.floor(1 * s)

        for idx, mod in ipairs(modules) do
            local tx = tabsX + (idx - 1) * (tabW + tabGap)
            local real_idx = self.registry:index_of(mod.id) or idx
            local isActive = (real_idx == self.focus.active_index)
            local isAvail  = (mod.available == true)

            imgui.SetCursorScreenPos({ tx, tabY })
            if imgui.InvisibleButton('##core_tab_' .. mod.id, { tabW, tabH }) then
                self.focus:select_index(real_idx)
            end
            local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false

            if dl then
                if isActive then
                    -- Signature Soulforge Luminous Aether Cyan Beveled-Hex Active Tab
                    F.drawBeveledPill(dl, tx - 3, tabY - 2, tabW + 6, tabH + 4, {
                        bevel     = math.floor(14 * s),
                        fillTop   = F.abgr(F.hex('#20728E', 0.98)),
                        fillBot   = F.abgr(F.hex('#0C3147', 0.99)),
                        border    = F.u32.aether_cyan,
                        glow      = F.abgr(F.rgba.aether_cyan, 0.30),
                        highlight = F.abgr(F.rgba.white, 0.62),
                        thickness = 1.9,
                    })
                elseif hovered then
                    F.drawBeveledPill(dl, tx, tabY + 1, tabW, tabH - 2, {
                        bevel     = math.floor(11 * s),
                        fillTop   = F.u32.midnight_alt,
                        fillBot   = F.u32.midnight_deep,
                        border    = F.u32.soul_gold_dim,
                        thickness = 1.1,
                    })
                end

                local labelFs = ((L.mode == 'focused') and 0.84 or 0.96) * s
                local maxLabelW = math.max(30, tabW - 18 * s)
                local txtCol = isActive and F.u32.white
                    or (hovered and F.u32.soul_gold_bright
                    or (isAvail and F.u32.text_primary or F.u32.text_muted))
                local labelStr = F.fitText(imgui, mod.label, maxLabelW, labelFs)
                F.drawShadowText(imgui, dl, tx + tabW * 0.5, tabY + math.floor((tabH - 14 * labelFs) * 0.5),
                    labelStr, txtCol, labelFs, 'c')
            end
        end

        -- B. Central Module Viewport
        local active = self.focus:active_module()
        local mode_str = (bridge_mode == 'native-commands-menu' and 'Native Commands Menu')
            or (bridge_mode == 'native-hook' and 'Native Commands Menu')
            or 'Standalone (/soulspire)'

        local ident = nil
        if type(self.get_identity) == 'function' then
            local okId, idRes = pcall(self.get_identity)
            if okId and type(idRes) == 'table' then ident = idRes end
        end
        if active and active.available and active.controller and type(active.controller.draw) == 'function' then
            local okDraw, errDraw = xpcall(function()
                active.controller:draw(imgui, dl, F, L, innerX, bodyY, L.innerW, bodyH, {
                    focus       = self.focus,
                    mode        = bridge_mode,
                    identity    = ident,
                    assets      = self.assets,
                    last_device = last_device,
                    label_for   = label_fn,
                })
            end, debug.traceback)
            if not okDraw then
                F.drawOrnatePanel(dl, innerX, bodyY, L.innerW, bodyH, {
                    fillTop = F.u32.midnight, fillBot = F.u32.abyss, border = F.u32.danger, shadow = false,
                })
                F.drawShadowText(imgui, dl, innerX + 18 * s, bodyY + 18 * s,
                    'Module render error (' .. tostring(active.id) .. '): ' .. tostring(errDraw), F.u32.danger, 0.88 * s, 'l')
            end
        elseif active then
            self:_draw_unavailable_module(dl, L, innerX, bodyY, L.innerW, bodyH, active, mode_str)
        end

        -- C. Premium Bottom Controls Bar (Centered RPG Keycap / Gamepad Legends — Zero Debug Clutter)
        if dl then
            F.drawGradRect(dl, innerX, footerY, innerX + L.innerW, footerY + footerH,
                F.abgr(F.hex('#0D1322', 0.90)), F.abgr(F.hex('#060912', 0.95)))
            dl:AddRect({ innerX, footerY }, { innerX + L.innerW, footerY + footerH },
                F.abgr(F.rgba.soul_gold_dim, 0.45), 5, 0, 1.0)
            dl:AddLine({ innerX + 24, footerY + 1 }, { innerX + L.innerW - 24, footerY + 1 },
                F.abgr(F.rgba.soul_gold, 0.45), 1.0)
        end

        local prompts = nil
        if active and active.controller and type(active.controller.get_prompt_pills) == 'function' then
            local okP, resP = pcall(active.controller.get_prompt_pills, active.controller, last_device, label_fn)
            if okP and type(resP) == 'table' and #resP > 0 then
                prompts = resP
            end
        end
        if not prompts then
            prompts = {
                { label_fn('modules', last_device), 'Modules' },
                { label_fn('nav',     last_device), 'Navigate' },
                { label_fn('confirm', last_device), 'Select' },
                { label_fn('context', last_device), 'Action' },
                { label_fn('details', last_device), 'Help' },
                { label_fn('cancel',  last_device), 'Close' },
            }
        end

        local pillFs = ((L.mode == 'focused') and 0.76 or 0.86) * s
        -- Pre-measure total width to center prompts cleanly inside the bottom bar
        local totalW = 0
        local widths = {}
        for i, pr in ipairs(prompts) do
            local kw = F.measureText(imgui, pr[1], pillFs)
            local dw = F.measureText(imgui, pr[2], pillFs)
            local pw = math.max(math.floor(28 * pillFs), math.floor(kw + math.floor(10 * pillFs + 0.5) * 2 + 4 * pillFs + 0.5))
            local itemW = pw + math.floor(10 * pillFs) + dw + math.floor(28 * pillFs)
            widths[i] = itemW
            totalW = totalW + itemW
        end
        totalW = math.max(0, totalW - math.floor(28 * pillFs))

        local py = footerY + math.floor((footerH - math.floor(24 * pillFs + 0.5)) * 0.5)
        local px = innerX + math.max(math.floor(14 * s), math.floor((L.innerW - totalW) * 0.5))
        local maxPx = innerX + L.innerW - math.floor(14 * s)
        for i, pr in ipairs(prompts) do
            if px + widths[i] - math.floor(16 * pillFs) <= maxPx then
                px = px + F.drawPromptPill(imgui, dl, px, py, pr[1], pr[2], { fontScale = pillFs })
            end
        end

        -- D. Optional Help / Controls Modal Overlay or Settings & Controller Bindings Overlay
        if self.focus.help_open and dl then
            self:_draw_help_overlay(dl, L, wx, wy, L.winW, L.winH, active)
        elseif self.scale_panel_open and dl then
            self:_draw_settings_overlay(dl, L, wx, wy, L.winW, L.winH)
        end
    end
    imgui.End()
    if imgui.PopStyleVar and pushed_vars > 0 then imgui.PopStyleVar(pushed_vars) end
end

function UI:draw(native, bridge_mode)
    local mode = bridge_mode
    if type(mode) == 'boolean' then
        mode = mode and 'native-commands-menu' or 'standalone'
    end
    self.last_dock.visible = false
    self.last_dock.hovered = false
    self:draw_hub(native, mode or 'standalone')
end

return UI
