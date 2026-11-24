-- SoulspireXI Core: Unified Dark-Fantasy Shell (opened from native FFXI Commands Menu).
--
-- No floating ImGui Main Menu dock or overlay is rendered; "Soulspire" is
-- injected directly into FFXI's native Commands menu ("menu    menuwind") by
-- soulspire_native.dll between Status and Equipment.
--
-- Aligned to the approved SoulspireXI Core visual direction:
--   - Left: Sundered Crag crest + "SOULSPIREXI / — CORE —" brand lockup
--   - Center: Floating beveled navigation ribbon built strictly from Core Registry,
--     with luminous cyan beveled active tab and [LB] / [RB] shoulder cues
--   - Right: Circular gilded utility buttons (? Help, Scale, X Close)
--   - Center Body: Active module viewport (or honest Unavailable card)
--   - Footer: Centered keycap/gamepad prompt pills + integration status

local bit   = require('bit')
local F     = require('core.foundations')
local Theme = require('core.theme')

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
            dl:AddQuad({ cx, cy - r }, { cx + r * 0.72, cy }, { cx, cy + r }, { cx - r * 0.72, cy }, accentU32, 1.2)
        end
    elseif icon_name == 'weapon_mastery' then
        if dl.AddLine then
            dl:AddLine({ cx - r * 0.75, cy + r * 0.75 }, { cx + r * 0.75, cy - r * 0.75 }, colU32, 1.8)
            dl:AddLine({ cx + r * 0.75, cy + r * 0.75 }, { cx - r * 0.75, cy - r * 0.75 }, colU32, 1.8)
            dl:AddLine({ cx - r * 0.55, cy + r * 0.15 }, { cx - r * 0.15, cy + r * 0.55 }, accentU32, 1.5)
            dl:AddLine({ cx + r * 0.55, cy + r * 0.15 }, { cx + r * 0.15, cy + r * 0.55 }, accentU32, 1.5)
        end
    elseif icon_name == 'soul_talents' then
        if dl.AddLine then
            dl:AddLine({ cx, cy + r * 0.65 }, { cx, cy - r * 0.65 }, accentU32, 1.3)
            dl:AddLine({ cx, cy }, { cx - r * 0.65, cy - r * 0.50 }, accentU32, 1.3)
            dl:AddLine({ cx, cy }, { cx + r * 0.65, cy - r * 0.50 }, accentU32, 1.3)
        end
        if dl.AddCircleFilled then
            dl:AddCircleFilled({ cx, cy + r * 0.65 }, r * 0.25, colU32, 10)
            dl:AddCircleFilled({ cx, cy - r * 0.65 }, r * 0.25, colU32, 10)
            dl:AddCircleFilled({ cx - r * 0.65, cy - r * 0.50 }, r * 0.22, colU32, 10)
            dl:AddCircleFilled({ cx + r * 0.65, cy - r * 0.50 }, r * 0.22, colU32, 10)
        end
    elseif icon_name == 'abilities' then
        if dl.AddLine then
            dl:AddLine({ cx, cy - r * 0.85 }, { cx, cy + r * 0.85 }, colU32, 1.5)
            dl:AddLine({ cx - r * 0.85, cy }, { cx + r * 0.85, cy }, colU32, 1.5)
            dl:AddLine({ cx - r * 0.55, cy - r * 0.55 }, { cx + r * 0.55, cy + r * 0.55 }, accentU32, 1.1)
            dl:AddLine({ cx + r * 0.55, cy - r * 0.55 }, { cx - r * 0.55, cy + r * 0.55 }, accentU32, 1.1)
        end
    elseif icon_name == 'equipment' then
        if dl.AddQuad then
            dl:AddQuad({ cx - r * 0.65, cy - r * 0.70 }, { cx + r * 0.65, cy - r * 0.70 },
                { cx + r * 0.50, cy + r * 0.30 }, { cx - r * 0.50, cy + r * 0.30 }, colU32, 1.4)
        end
        if dl.AddLine then
            dl:AddLine({ cx - r * 0.50, cy + r * 0.30 }, { cx, cy + r * 0.85 }, colU32, 1.4)
            dl:AddLine({ cx + r * 0.50, cy + r * 0.30 }, { cx, cy + r * 0.85 }, colU32, 1.4)
        end
    else
        if dl.AddRect then
            dl:AddRect({ cx - r * 0.65, cy - r * 0.75 }, { cx + r * 0.65, cy + r * 0.75 }, colU32, 2, 0, 1.4)
        end
        if dl.AddLine then
            dl:AddLine({ cx, cy - r * 0.75 }, { cx, cy + r * 0.75 }, accentU32, 1.2)
        end
    end
end

local function draw_crest(dl, x, y, size, tex_id)
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
        imgui           = imgui,
        registry        = registry,
        focus           = focus,
        assets          = assets,
        crest_tex       = nil,
        ui_scale        = F.clamp(tonumber(opts.ui_scale) or 1.0, 0.75, 1.50),
        on_scale_change = opts.on_scale_change,
        get_identity    = opts.get_identity,
        character_state = opts.character_state,
        scale_panel_open = false,
        last_viewport_w = 0,
        last_viewport_h = 0,
        last_dock       = { visible = false, hovered = false, clicks = 0 },
        last_layout     = nil,
    }, UI)
end

function UI:set_scale(scale)
    self.ui_scale = F.clamp(tonumber(scale) or 1.0, 0.75, 1.50)
    if type(self.on_scale_change) == 'function' then
        self.on_scale_change(self.ui_scale)
    end
end

function UI:ensure_assets()
    if self.crest_tex == nil and self.assets then
        self.crest_tex = self.assets:load_texture('soulspire_crest') or false
    end
    return self.crest_tex ~= false and self.crest_tex or nil
end

function UI:compute_layout(viewW, viewH)
    return F.computeViewportLayout(viewW, viewH, self.ui_scale or 1.0, {
        maxLogicalW = 1920,
        maxLogicalH = 1120,
    })
end

-- Main Menu integration is handled natively inside FFXI's Commands menu by
-- soulspire_native.dll; no floating ImGui Main Menu button is rendered.
function UI:draw_main_menu_dock(_native)
    self.last_dock.visible = false
    self.last_dock.hovered = false
end

-- Render an honest unavailable module panel (zero fake interactive controls).
function UI:_draw_unavailable_module(dl, L, x, y, w, h, mod, mode_label)
    local imgui = self.imgui
    local s = L.uiScale or 1.0

    F.drawPanelFrame(dl, x, y, w, h, {
        fillTop  = F.u32.midnight,
        fillBot  = F.u32.abyss,
        border   = F.u32.border_subtle,
        accent   = F.u32.soul_gold_dim,
        corners  = (L.ornamentLevel >= 1),
        shadow   = false,
    })

    local cardW = math.min(w - math.floor(40 * s), math.floor(560 * s))
    local cardH = math.min(h - math.floor(40 * s), math.floor(250 * s))
    local cx = x + math.floor((w - cardW) * 0.5)
    local cy = y + math.floor((h - cardH) * 0.5)

    F.drawPanelFrame(dl, cx, cy, cardW, cardH, {
        fillTop  = F.u32.midnight_alt,
        fillBot  = F.u32.midnight_deep,
        border   = F.u32.border_strong,
        accent   = F.u32.crystal_violet,
        rounding = 6,
        corners  = true,
        shadow   = false,
    })

    local pad = math.floor(20 * s)
    draw_module_icon(dl, mod.icon, cx + pad + 14 * s, cy + pad + 14 * s, 12 * s, F.u32.text_muted, F.u32.border_strong)
    F.drawShadowText(imgui, dl, cx + pad + 36 * s, cy + pad + 4 * s,
        string.upper(mod.label), F.u32.soul_gold, 1.06 * s, 'l')

    F.drawBadgePill(imgui, dl, cx + cardW - pad - math.floor(114 * s), cy + pad + 2 * s, '[x] UNAVAILABLE', {
        width     = math.floor(114 * s),
        height    = math.floor(22 * s),
        fill      = F.u32.abyss_solid,
        border    = F.u32.border_strong,
        textCol   = F.u32.text_muted,
        fontScale = 0.72 * s,
    })

    F.drawDivider(dl, cx + pad, cy + pad + 38 * s, cardW - pad * 2, F.u32.border_strong)

    local ty = cy + pad + 54 * s
    local chars = math.max(28, math.floor((cardW - pad * 2) / (7.6 * s)))
    for _, line in ipairs(F.wrapLines(mod.summary or 'This module is not yet integrated.', chars, 3)) do
        F.drawShadowText(imgui, dl, cx + pad, ty, line, F.u32.text_primary, 0.86 * s, 'l')
        ty = ty + math.floor(18 * s)
    end
    ty = ty + 8 * s

    local detail_msg = mod.unavailable_reason or mod.details or 'Module integration pending in a future milestone.'
    for _, line in ipairs(F.wrapLines(detail_msg, chars, 4)) do
        F.drawShadowText(imgui, dl, cx + pad, ty, line, F.u32.text_secondary, 0.78 * s, 'l')
        ty = ty + math.floor(17 * s)
    end

    local companion = mod.existing_addon and (mod.existing_addon .. ' (remains active untouched)') or 'Scheduled for upcoming Core module release'
    F.drawShadowText(imgui, dl, cx + pad, cy + cardH - pad - 34 * s,
        'Companion System: ' .. companion, F.u32.text_muted, 0.74 * s, 'l')
    F.drawShadowText(imgui, dl, cx + pad, cy + cardH - pad - 16 * s,
        'Menu Integration: ' .. tostring(mode_label) .. '  |  Use LB/RB to switch to live modules.',
        F.u32.aether_cyan, 0.74 * s, 'l')
end

-- Render the [Y] Details & Controls Help Overlay modal.
function UI:_draw_help_overlay(dl, L, wx, wy, ww, wh, active)
    local imgui = self.imgui
    local s = L.uiScale or 1.0

    dl:AddRectFilled({ wx, wy }, { wx + ww, wy + wh }, F.abgr(F.rgba.black, 0.66), 8)

    local mw = math.min(ww - math.floor(40 * s), math.floor(560 * s))
    local mh = math.min(wh - math.floor(40 * s), math.floor(340 * s))
    local mx = wx + math.floor((ww - mw) * 0.5)
    local my = wy + math.floor((wh - mh) * 0.5)

    F.drawPanelFrame(dl, mx, my, mw, mh, {
        fillTop  = F.u32.midnight_alt,
        fillBot  = F.u32.abyss_solid,
        border   = F.u32.soul_gold,
        accent   = F.u32.aether_cyan,
        rounding = 7,
        corners  = true,
        shadow   = true,
    })

    local pad = math.floor(18 * s)
    F.drawShadowText(imgui, dl, mx + pad, my + 14 * s, 'SOULSPIREXI CORE — CONTROLS & DETAILS', F.u32.soul_gold_bright, 0.96 * s, 'l')
    F.drawDivider(dl, mx + pad, my + 38 * s, mw - pad * 2, F.u32.soul_gold_dim)

    local rows = {
        { 'LB / RB  (Q / E)',            'Switch Core modules (or focus Soulspire on FFXI Main Menu)' },
        { 'D-Pad / Left Stick / Arrows', 'Navigate menus, weapons, skillchain slots & talent nodes' },
        { 'A  (Enter / Space)',          'Confirm / Select / Open Upgrade Confirmation' },
        { 'B  (Escape / Backspace)',     'Back one level / Cancel modal / Close SoulspireXI Core' },
        { 'X  (X / F / Delete)',         'Context action (Filter Weapon / Refund / Sync / Reset)' },
        { 'Y  (Y / H / F1)',             'Toggle this Details & Controls overlay' },
        { 'Tab',                         'Cycle focus regions inside active module' },
    }
    local cy = my + 50 * s
    for _, r in ipairs(rows) do
        F.drawShadowText(imgui, dl, mx + pad, cy, r[1], F.u32.aether_cyan, 0.78 * s, 'l')
        F.drawShadowText(imgui, dl, mx + pad + math.floor(190 * s), cy,
            F.fitText(imgui, r[2], mw - pad * 2 - math.floor(192 * s), 0.76 * s),
            F.u32.text_primary, 0.76 * s, 'l')
        cy = cy + math.floor(22 * s)
    end

    cy = cy + 6 * s
    F.drawDivider(dl, mx + pad, cy, mw - pad * 2, F.u32.border_strong)
    cy = cy + 10 * s
    if active then
        F.drawShadowText(imgui, dl, mx + pad, cy, 'ACTIVE MODULE: ' .. string.upper(active.label), F.u32.soul_gold, 0.80 * s, 'l')
        cy = cy + 18 * s
        local chars = math.max(30, math.floor((mw - pad * 2) / (7.4 * s)))
        for _, line in ipairs(F.wrapLines(active.details or active.summary or '', chars, 3)) do
            F.drawShadowText(imgui, dl, mx + pad, cy, line, F.u32.text_secondary, 0.74 * s, 'l')
            cy = cy + math.floor(16 * s)
        end
    end

    local btnW, btnH = math.floor(116 * s), math.floor(28 * s)
    if F.drawActionButton(imgui, dl, '##core_help_close', mx + mw - pad - btnW, my + mh - pad - btnH, btnW, btnH,
        'CLOSE [B / Y]', 'gold', { fontScale = 0.76 * s }) then
        self.focus.help_open = false
    end
end

-- 2. Unified SoulspireXI Core Shell Window.
function UI:draw_hub(native, bridge_mode)
    if not self.focus.hub_open then return end

    local imgui = self.imgui
    local vw, vh = F.getViewportSize(imgui)
    local L = self:compute_layout(vw, vh)
    self.last_layout = L
    local s = L.uiScale

    local resized = (self.last_viewport_w ~= vw or self.last_viewport_h ~= vh)
    if resized then
        self.last_viewport_w = vw
        self.last_viewport_h = vh
    end

    local win_flags = flag_or(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground,
        ImGuiWindowFlags_NoSavedSettings
    )

    if imgui.SetNextWindowSize then imgui.SetNextWindowSize({ L.winW, L.winH }, ImGuiCond_Always or 1) end
    if imgui.SetNextWindowPos then
        imgui.SetNextWindowPos({ L.posX, L.posY }, resized and (ImGuiCond_Always or 1) or (ImGuiCond_FirstUseEver or 4))
    end
    if imgui.PushStyleVar then imgui.PushStyleVar(ImGuiStyleVar_WindowPadding or 2, { 0, 0 }) end

    local opened = imgui.Begin('SoulspireXI Core###soulspire_core_hub', true, win_flags)
    if opened then
        local wx, wy = 0, 0
        if imgui.GetWindowPos then
            wx, wy = F.toXY(imgui.GetWindowPos())
        end
        local dl = imgui.GetWindowDrawList and imgui.GetWindowDrawList() or nil

        -- Outer dark-fantasy SoulspireXI chamber frame
        F.drawPanelFrame(dl, wx, wy, L.winW, L.winH, {
            fillTop  = F.u32.midnight_deep,
            fillBot  = F.u32.abyss_solid,
            border   = F.u32.soul_gold_dim,
            accent   = F.u32.soul_gold,
            rounding = 8,
            corners  = true,
            shadow   = true,
        })

        local innerX  = wx + L.pad
        local headerY = wy + math.floor(L.pad * 0.6)
        local headerH = math.floor(((L.mode == 'focused' and 48) or 52) * s)
        local footerH = math.floor(((L.mode == 'focused' and 32) or 36) * s)
        local bodyY   = headerY + headerH + math.floor(L.gap * 0.8)
        local bodyH   = math.max(200, (wy + L.winH - L.pad) - bodyY - footerH - L.gap)
        local footerY = bodyY + bodyH + L.gap

        -- A. Top Navigation Header (Approved Visual Direction)
        if dl then
            F.drawGradRect(dl, wx + 2, wy + 2, wx + L.winW - 2, headerY + headerH + 2,
                F.abgr(F.rgba.midnight_alt, 0.92), F.abgr(F.rgba.abyss_solid, 0.96))
            dl:AddLine({ wx + 10, headerY + headerH + 2 }, { wx + L.winW - 10, headerY + headerH + 2 },
                F.abgr(F.rgba.soul_gold_dim, 0.45), 1.0)
        end

        -- Far Left: Faceted Crystal Crest + "SOULSPIREXI / — CORE —"
        local crestSz = math.floor(math.min(40 * s, headerH - 4))
        draw_crest(dl, innerX + 4 * s, headerY + math.floor((headerH - crestSz) * 0.5), crestSz, self:ensure_assets())
        local brandX = innerX + 12 * s + crestSz
        F.drawShadowText(imgui, dl, brandX, headerY + 6 * s, 'SOULSPIREXI', F.u32.text_primary, 1.04 * s, 'l')
        if L.mode ~= 'focused' then
            local coreSubY = headerY + 28 * s
            local coreMidX = brandX + 44 * s
            if dl and dl.AddLine then
                dl:AddLine({ brandX, coreSubY + 5 * s }, { brandX + 20 * s, coreSubY + 5 * s }, F.u32.soul_gold_dim, 1.0)
                dl:AddLine({ coreMidX + 24 * s, coreSubY + 5 * s }, { coreMidX + 44 * s, coreSubY + 5 * s }, F.u32.soul_gold_dim, 1.0)
            end
            F.drawShadowText(imgui, dl, coreMidX, coreSubY - 1, 'CORE', F.u32.soul_gold, 0.70 * s, 'c')
        end
        local brandEnd = brandX + math.floor((L.mode == 'focused' and 100 or 126) * s)

        -- Far Right: Circular gilded utility buttons (? Help, Scale, X Close)
        local circR = math.floor(13 * s)
        local circY = headerY + headerH * 0.5
        local rightX = innerX + L.innerW - 8 * s

        -- Close (X)
        local closeCx = rightX - circR
        if F.drawCircleIconBtn(imgui, dl, '##core_close', closeCx, circY, circR, 'X', { fontScale = 0.78 * s }) then
            self.focus:close_hub(native)
        end

        -- Scale / Settings (*)
        local setCx = closeCx - circR * 2 - math.floor(8 * s)
        if F.drawCircleIconBtn(imgui, dl, '##core_scale_btn', setCx, circY, circR, '*', {
            active = self.scale_panel_open, fontScale = 0.90 * s,
        }) then
            self.scale_panel_open = not self.scale_panel_open
        end

        -- Help (?)
        local helpCx = setCx - circR * 2 - math.floor(8 * s)
        if F.drawCircleIconBtn(imgui, dl, '##core_help', helpCx, circY, circR, '?', {
            active = self.focus.help_open, fontScale = 0.82 * s,
        }) then
            self.focus.help_open = not self.focus.help_open
        end

        -- Optional inline compact scale adjuster when Settings circle is toggled
        local navRightLimit = helpCx - circR - math.floor(12 * s)
        if self.scale_panel_open and L.mode ~= 'focused' then
            local stepW = math.floor(20 * s)
            local btnH  = math.floor(22 * s)
            local btnY  = headerY + math.floor((headerH - btnH) * 0.5)
            local sx = navRightLimit - stepW
            if F.drawActionButton(imgui, dl, '##core_sc_up', sx, btnY, stepW, btnH, '+', 'neutral', { fontScale = 0.76 * s }) then
                self:set_scale(math.floor((self.ui_scale + 0.10) * 100 + 0.5) / 100)
            end
            local pctW = math.floor(38 * s)
            sx = sx - pctW - 2 * s
            F.drawShadowText(imgui, dl, sx + pctW * 0.5, btnY + 4 * s,
                string.format('%d%%', math.floor(self.ui_scale * 100 + 0.5)), F.u32.soul_gold_bright, 0.72 * s, 'c')
            sx = sx - stepW - 2 * s
            if F.drawActionButton(imgui, dl, '##core_sc_dn', sx, btnY, stepW, btnH, '-', 'neutral', { fontScale = 0.76 * s }) then
                self:set_scale(math.floor((self.ui_scale - 0.10) * 100 + 0.5) / 100)
            end
            navRightLimit = sx - math.floor(10 * s)
        end

        -- Center: Floating Beveled Dark Ribbon housing Dynamic Registry Tabs
        local modules = self.registry:sections()
        local count = math.max(1, #modules)
        local availNavW = math.max(200, navRightLimit - brandEnd - math.floor(12 * s))
        local idealRibW = math.min(availNavW, math.floor(count * 136 * s + 80 * s))
        local ribX = brandEnd + math.floor((availNavW - idealRibW) * 0.5) + math.floor(6 * s)
        local ribH = math.floor(34 * s)
        local ribY = headerY + math.floor((headerH - ribH) * 0.5)

        if dl then
            F.drawBeveledPill(dl, ribX, ribY, idealRibW, ribH, {
                bevel     = math.floor(14 * s),
                fillTop   = F.abgr(F.rgba.midnight, 0.92),
                fillBot   = F.abgr(F.rgba.abyss_solid, 0.95),
                border    = F.abgr(F.rgba.border_strong, 0.90),
                thickness = 1.1,
            })
        end

        -- LB / RB shoulder buttons flanking the dynamic tab strip
        local bmpW = math.floor(28 * s)
        local bmpH = math.floor(20 * s)
        local bmpY = ribY + math.floor((ribH - bmpH) * 0.5)
        if F.drawActionButton(imgui, dl, '##core_lb', ribX + math.floor(14 * s), bmpY, bmpW, bmpH, 'LB', 'neutral', { fontScale = 0.66 * s }) then
            self.focus:switch_module(-1)
        end
        if F.drawActionButton(imgui, dl, '##core_rb', ribX + idealRibW - math.floor(14 * s) - bmpW, bmpY, bmpW, bmpH, 'RB', 'neutral', { fontScale = 0.66 * s }) then
            self.focus:switch_module(1)
        end

        local tabsX = ribX + math.floor(18 * s) + bmpW
        local tabsW = math.max(100, idealRibW - (math.floor(18 * s) + bmpW) * 2)
        local tabGap = math.floor(4 * s)
        local tabW = math.floor((tabsW - tabGap * (count - 1)) / count)
        local tabH = ribH - math.floor(2 * s)
        local tabY = ribY + math.floor(1 * s)

        for idx, mod in ipairs(modules) do
            local tx = tabsX + (idx - 1) * (tabW + tabGap)
            local isActive = (idx == self.focus.active_index)
            local isAvail  = (mod.available == true)

            imgui.SetCursorScreenPos({ tx, tabY })
            if imgui.InvisibleButton('##core_tab_' .. mod.id, { tabW, tabH }) then
                self.focus:select_index(idx)
            end
            local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false

            if dl then
                if isActive then
                    -- Approved visual direction: luminous Aether Cyan beveled-hex active tab!
                    F.drawBeveledPill(dl, tx - 2, tabY - 1, tabW + 4, tabH + 2, {
                        bevel     = math.floor(11 * s),
                        fillTop   = F.abgr(F.hex('#1D647D', 0.96)),
                        fillBot   = F.abgr(F.hex('#0D2B3D', 0.98)),
                        border    = F.u32.aether_cyan,
                        glow      = F.abgr(F.rgba.aether_cyan, 0.22),
                        highlight = F.abgr(F.rgba.white, 0.45),
                        thickness = 1.6,
                    })
                elseif hovered then
                    F.drawBeveledPill(dl, tx, tabY + 1, tabW, tabH - 2, {
                        bevel     = math.floor(9 * s),
                        fillTop   = F.u32.midnight_alt,
                        fillBot   = F.u32.midnight_deep,
                        border    = F.u32.soul_gold_dim,
                        thickness = 1.0,
                    })
                end

                local showIcon = (tabW >= 104 * s)
                local iconCol = isActive and F.u32.white
                    or (isAvail and F.u32.aether_cyan or F.u32.text_disabled)
                local iconAcc = isActive and F.u32.soul_gold_bright or F.u32.border_strong
                if showIcon then
                    draw_module_icon(dl, mod.icon, tx + 16 * s, tabY + tabH * 0.5, 6.2 * s, iconCol, iconAcc)
                end

                local labelX = showIcon and (tx + 28 * s) or (tx + tabW * 0.5)
                local maxLabelW = showIcon and math.max(24, tabW - 36 * s) or math.max(24, tabW - 14 * s)
                local txtCol = isActive and F.u32.white
                    or (hovered and F.u32.soul_gold_bright
                    or (isAvail and F.u32.text_secondary or F.u32.text_disabled))
                local labelStr = F.fitText(imgui, mod.label, maxLabelW, 0.80 * s)
                F.drawShadowText(imgui, dl, labelX, tabY + math.floor((tabH - 14 * s) * 0.5),
                    labelStr, txtCol, 0.80 * s, showIcon and 'l' or 'c')
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
                    focus           = self.focus,
                    mode            = bridge_mode,
                    identity        = ident,
                    character_state = self.character_state,
                })
            end, debug.traceback)
            if not okDraw then
                F.drawPanelFrame(dl, innerX, bodyY, L.innerW, bodyH, {
                    fillTop = F.u32.midnight, fillBot = F.u32.abyss, border = F.u32.danger, shadow = false,
                })
                F.drawShadowText(imgui, dl, innerX + 16 * s, bodyY + 16 * s,
                    'Module render error (' .. tostring(active.id) .. '): ' .. tostring(errDraw), F.u32.danger, 0.80 * s, 'l')
            end
        elseif active then
            self:_draw_unavailable_module(dl, L, innerX, bodyY, L.innerW, bodyH, active, mode_str)
        end

        -- C. Consistent Bottom Controls Bar (Keycap / Gamepad Prompt Pills)
        F.drawPanelFrame(dl, innerX, footerY, L.innerW, footerH, {
            fillTop  = F.u32.midnight_deep,
            fillBot  = F.u32.abyss_solid,
            border   = F.u32.border_subtle,
            corners  = false,
            shadow   = false,
        })

        local prompts = {
            { 'LB/RB', 'Modules' },
            { 'D-Pad', 'Navigate' },
            { 'A',     'Select' },
            { 'X',     'Action' },
            { 'Y',     'Help' },
            { 'B',     'Back / Close' },
        }
        local py = footerY + math.floor((footerH - 20 * 0.74 * s) * 0.5)
        local px = innerX + math.floor(14 * s)
        local rightMetaW = (L.mode ~= 'focused') and math.floor(290 * s) or 0
        local maxPx = innerX + L.innerW - rightMetaW - math.floor(16 * s)
        for _, pr in ipairs(prompts) do
            if px < maxPx - math.floor(70 * s) then
                px = px + F.drawPromptPill(imgui, dl, px, py, pr[1], pr[2], { fontScale = 0.74 * s })
            end
        end

        if L.mode ~= 'focused' then
            local meta_str = string.format('%s  |  %s (%dx%d)', mode_str, string.upper(L.mode), L.viewW, L.viewH)
            F.drawShadowText(imgui, dl, innerX + L.innerW - 12 * s, footerY + math.floor((footerH - 13 * s) * 0.5),
                F.fitText(imgui, meta_str, rightMetaW, 0.70 * s), F.u32.text_muted, 0.70 * s, 'r')
        end

        -- D. Optional Help / Controls Modal Overlay
        if self.focus.help_open and dl then
            self:_draw_help_overlay(dl, L, wx, wy, L.winW, L.winH, active)
        end
    end
    imgui.End()
    if imgui.PopStyleVar then imgui.PopStyleVar() end
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
