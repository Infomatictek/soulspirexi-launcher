--[[
* SoulspireXI Universal Soul HUD — Unified Combat Instrument Renderer
*
* Shares the official SoulspireXI Core UI Foundations design language with
* The Soulforge (Abyss #0B1019, Midnight #151928, Soul Gold #E8BD70,
* Aether Cyan #39CFE5, Crystal Violet #8063BC), tuned for real-time combat
* readability with restrained effects.
*
* Display Modes:
*   - minimal  : Essential combat instrument only (Medallion + primary pips/bar).
*   - standard : Framed combat chassis + Medallion + pips/bar + wrapped status strip.
*   - expanded : Standard + modular secondary mechanics deck (charges, cooldowns,
*                timers, builder/spender cues, threshold warnings) driven directly
*                by existing soulhud_registry provider contracts.
--]]

local okIcons, icons = pcall(require, 'ox_icons')
if not okIcons then icons = nil end
local roster    = require('soulhud_roster')
local layoutMod = require('soulhud_layout')
local settingsMod = require('soulhud_settings')
local okTips, tips = pcall(require, 'soulhud_tips')
if not okTips then tips = nil end
local okBit, bit = pcall(require, 'bit')
local IG = require('core.imgui_constants')

-- Load shared SoulspireXI Core UI Foundations from sibling soulspire_core addon.
local function loadFoundations()
    local okReq, mod = pcall(require, 'core.foundations')
    if okReq and type(mod) == 'table' then return mod end
    if type(addon) == 'table' and type(addon.path) == 'string' and addon.path ~= '' then
        local root = addon.path:gsub('[/\\]+$', ''):gsub('[/\\][^/\\]+$', '')
        local loader = loadfile(root .. '/soulspire_core/core/foundations.lua')
        if loader then
            local ok, res = pcall(loader)
            if ok and type(res) == 'table' then return res end
        end
    end
    local loader = loadfile('../soulspire_core/core/foundations.lua')
    if loader then
        local ok, res = pcall(loader)
        if ok and type(res) == 'table' then return res end
    end
    return nil
end

local F = loadFoundations()

local M = {}

-- ---------------------------------------------------------------------------
-- Base Geometry (unscaled px; multiplied by cfg.scale)
-- ---------------------------------------------------------------------------
local PAD        = 8
local MED        = 54
local SPINE_X    = 66
local PIP        = 20
local PIP_PITCH  = 22
local PIP_Y      = 9
local BAR_W      = 228
local BAR_H      = 22
local BAR_Y      = 34
local DECK_GAP   = 6
local DECK_ROW_H = 22
local DECK_MAX   = 4
local STRIP_GAP  = 6
local RING       = 34
local ICON       = 26
local RING_PITCH = 38
local TIMER_H    = 12
local ROW_GAP    = 3
local ROW_H      = RING + TIMER_H + ROW_GAP
local MAX_ROWS   = 4
local PILL_H     = 22

-- ---------------------------------------------------------------------------
-- Unified SoulspireXI Palette Helpers (backed by Core Foundations)
-- ---------------------------------------------------------------------------
local clamp = F and F.clamp or function(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function rgba(name, fallback)
    return (F and F.rgba and F.rgba[name]) or fallback
end

local function abgr(c, alpha)
    if F and F.abgr then return F.abgr(c, alpha) end
    local r = math.floor(clamp(c[1] or 0, 0, 1) * 255 + 0.5)
    local g = math.floor(clamp(c[2] or 0, 0, 1) * 255 + 0.5)
    local b = math.floor(clamp(c[3] or 0, 0, 1) * 255 + 0.5)
    local a = math.floor(clamp(alpha ~= nil and alpha or (c[4] or 1), 0, 1) * 255 + 0.5)
    return a * 16777216 + b * 65536 + g * 256 + r
end

local function mix(a, b, t, alpha)
    if F and F.mix then return F.mix(a, b, t, alpha) end
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, alpha or 1 }
end

local C = {
    abyss         = rgba('abyss',                 { 0.043, 0.063, 0.098, 0.96 }),
    midnight      = rgba('midnight',              { 0.082, 0.098, 0.157, 0.96 }),
    midnight_deep = rgba('midnight_deep',         { 0.063, 0.078, 0.133, 0.96 }),
    gold          = rgba('soul_gold',             { 0.910, 0.741, 0.439, 1.00 }),
    gold_bright   = rgba('soul_gold_bright',      { 0.965, 0.847, 0.588, 1.00 }),
    gold_dim      = rgba('soul_gold_dim',         { 0.620, 0.498, 0.286, 1.00 }),
    cyan          = rgba('aether_cyan',           { 0.224, 0.812, 0.898, 1.00 }),
    violet        = rgba('crystal_violet',        { 0.502, 0.388, 0.737, 1.00 }),
    violet_bright = rgba('crystal_violet_bright', { 0.655, 0.549, 0.878, 1.00 }),
    text          = rgba('text_primary',          { 0.945, 0.961, 0.976, 1.00 }),
    text_dim      = rgba('text_secondary',        { 0.659, 0.710, 0.784, 1.00 }),
    border        = rgba('border_subtle',         { 0.149, 0.188, 0.278, 1.00 }),
    border_strong = rgba('border_strong',         { 0.231, 0.286, 0.412, 1.00 }),
    warn          = rgba('danger',                { 0.937, 0.325, 0.314, 1.00 }),
    success       = rgba('success',               { 0.290, 0.871, 0.502, 1.00 }),
    white         = { 1, 1, 1, 1 },
    black         = { 0, 0, 0, 1 },
}

local ROLES = {
    tank    = { body = C.cyan,                   gold = C.gold, deep = { 0.055, 0.114, 0.184, 0.95 } },
    healer  = { body = C.success,                gold = C.gold, deep = { 0.051, 0.141, 0.118, 0.95 } },
    support = { body = C.violet,                 gold = C.gold, deep = { 0.106, 0.082, 0.188, 0.95 } },
    damage  = { body = { 0.898, 0.361, 0.424, 1 }, gold = C.gold, deep = { 0.153, 0.071, 0.110, 0.95 } },
}

local GEM_COLORS = {
    gold    = C.gold,
    crimson = { 0.898, 0.361, 0.424, 1 },
    azure   = C.cyan,
    emerald = C.success,
    violet  = C.violet_bright,
}

local anim = { disp = {}, peak = {}, lastClock = nil, movedAt = -10 }

function M.reset()
    anim.disp, anim.peak, anim.lastClock = {}, {}, nil
end

-- ---------------------------------------------------------------------------
-- Formatting & Text Helpers
-- ---------------------------------------------------------------------------
local function toXY(a, b)
    if F and F.toXY then return F.toXY(a, b) end
    if type(a) == 'table' then return a[1] or a.x or 0, a[2] or a.y or 0 end
    return a or 0, b or 0
end

local function fmtTime(rem)
    rem = math.max(0, math.ceil(rem))
    if rem >= 3600 then return ('%dh'):format(math.floor(rem / 3600)) end
    if rem >= 60 then return ('%dm'):format(math.floor(rem / 60)) end
    return ('%ds'):format(rem)
end

local function powerBadge(power)
    power = tonumber(power) or 0
    if power <= 0 then return '' end
    if power <= 5 then return ('x%d'):format(power) end
    return ('%d%%'):format(math.min(power, 999))
end

local function barValueText(bar, cur, max)
    if cur <= 0.0001 and bar.idle then return bar.idle end
    if bar.right and bar.right ~= '' then return bar.right end
    local f = bar.fmt
    if f == 'sec' then return fmtTime(cur) end
    if f == 'frac' then return ('%d/%d'):format(math.floor(cur + 0.5), math.floor(max + 0.5)) end
    if f == 'pct' then return ('%d%%'):format(math.floor(cur / math.max(max, 0.0001) * 100 + 0.5)) end
    return tostring(math.floor(cur + 0.5))
end

local function drawText(imgui, dl, x, y, colorU32, str, fs, align, alpha)
    if F and F.drawShadowText then
        return F.drawShadowText(imgui, dl, x, y, str, colorU32, fs, align, alpha)
    end
    dl:AddText({ math.floor(x + 0.5), math.floor(y + 0.5) }, colorU32, tostring(str or ''))
    return #tostring(str or '') * 7 * (fs or 1), 13 * (fs or 1)
end

local function fitText(imgui, str, maxW, fs)
    if F and F.fitText then return F.fitText(imgui, str, maxW, fs) end
    return tostring(str or '')
end

local function image(dl, tex, x0, y0, x1, y1, tint)
    if tex ~= nil and dl and dl.AddImage then
        dl:AddImage(tex, { x0, y0 }, { x1, y1 }, { 0, 0 }, { 1, 1 }, tint or 0xFFFFFFFF)
        return true
    end
    return false
end

local function normalizeLayoutMode(raw)
    if raw == 'minimal' or raw == 'expanded' then return raw end
    return 'standard'
end
M.normalizeLayoutMode = normalizeLayoutMode

-- Collect visible secondary provider resources for Expanded mode
function M.collectExpandedResources(def, rt, cfg)
    local out = {}
    if not def or not rt or not def.resources or not rt.values then return out end
    for _, res in ipairs(def.resources) do
        local vis = settingsMod.isElementVisible(cfg, def.key, res.id)
        local st  = rt.values[res.id]
        if vis and st then
            local show = true
            if type(res.visibleWhen) == 'function' then
                local okV, v = pcall(res.visibleWhen, res, st)
                if okV and v == false then show = false end
            end
            if show then
                out[#out + 1] = { res = res, st = st }
                if #out >= DECK_MAX then break end
            end
        end
    end
    return out
end

local function evaluateResourceWarning(res, st)
    if type(res.warnWhen) == 'function' then
        local ok, w = pcall(res.warnWhen, res, st)
        if ok then return w == true end
    end
    if res.warnThreshold ~= nil then
        local cur = tonumber(st.current) or 0
        if res.warnMode == 'low' then return cur <= res.warnThreshold end
        if res.warnMode == 'high' then return cur >= res.warnThreshold end
        if res.warnMode == 'active' then return st.active == true end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Quick Options Popup (right-click medallion or click while unlocked)
-- ---------------------------------------------------------------------------
local POPUP_ID = '##ox_soulhud_opts'

local function drawOptions(imgui, cfg, callbacks, pal)
    local pushed = 0
    local function pc(idx, v)
        if idx ~= nil and imgui.PushStyleColor then imgui.PushStyleColor(idx, v); pushed = pushed + 1 end
    end
    pc(IG.Col.PopupBg,       C.abyss)
    pc(IG.Col.Border,        C.gold)
    pc(IG.Col.Text,          C.text)
    pc(IG.Col.HeaderHovered, { 0.224, 0.812, 0.898, 0.30 })
    pc(IG.Col.HeaderActive,  { 0.910, 0.741, 0.439, 0.40 })

    if imgui.BeginPopup(POPUP_ID) then
        imgui.TextColored(C.gold, 'SoulspireXI Soul HUD')
        imgui.Separator()

        local curMode = normalizeLayoutMode(cfg.layout)
        for _, m in ipairs({ 'minimal', 'standard', 'expanded' }) do
            local lbl = ('Mode: %s%s'):format(m:sub(1, 1):upper() .. m:sub(2), curMode == m and '  *' or '')
            if imgui.Selectable(lbl) then
                cfg.layout = m
                if callbacks.onSave then callbacks.onSave() end
            end
        end
        imgui.Separator()

        if imgui.Selectable(cfg.locked and 'Unlock Position' or 'Lock Position') then
            cfg.locked = not cfg.locked
            if callbacks.onSave then callbacks.onSave() end
        end
        for _, sv in ipairs({ 0.85, 1.0, 1.25 }) do
            local label = ('Scale %.2gx%s'):format(sv, math.abs((cfg.scale or 1) - sv) < 0.01 and '  *' or '')
            if imgui.Selectable(label) then
                cfg.scale = sv
                if callbacks.onSave then callbacks.onSave() end
            end
        end
        if imgui.Selectable('Shared Party Buffs: ' .. (cfg.showShared ~= false and 'On' or 'Off')) then
            cfg.showShared = not (cfg.showShared ~= false)
            if callbacks.onSave then callbacks.onSave() end
        end
        if imgui.Selectable('Auto-Hide in Menus: ' .. (cfg.autoHideOnMenu ~= false and 'On' or 'Off')) then
            cfg.autoHideOnMenu = not (cfg.autoHideOnMenu ~= false)
            if callbacks.onSave then callbacks.onSave() end
        end
        if imgui.Selectable('More Settings...') then
            if callbacks.onToggleConfig then callbacks.onToggleConfig() end
        end
        imgui.EndPopup()
    end
    if pushed > 0 then imgui.PopStyleColor(pushed) end
end

local function styledTooltip(imgui, accentRgba, title, lines, opts)
    if F and F.drawTooltipCard then
        local mapped = {}
        for _, ln in ipairs(lines or {}) do
            if ln.sep then
                mapped[#mapped + 1] = { sep = true }
            else
                local colRgba = nil
                if type(ln.color) == 'table' then
                    colRgba = (ln.color[1] > 1)
                        and { ln.color[1] / 255, ln.color[2] / 255, ln.color[3] / 255, 1.0 }
                        or ln.color
                end
                mapped[#mapped + 1] = { head = ln.head, text = ln.text, rgba = colRgba }
            end
        end
        F.drawTooltipCard(imgui, title, mapped, {
            accent   = accentRgba,
            subtitle = opts and opts.subtitle or nil,
            weapon   = opts and opts.weapon or nil,
        })
    end
end

-- ---------------------------------------------------------------------------
-- Main Render Entry
-- ---------------------------------------------------------------------------
function M.render(imgui, ctx)
    local entry = roster.get(ctx.soulKey)
    if entry == nil then return end

    local cfg   = ctx.cfg
    local now   = ctx.now or os.clock()
    local s     = cfg.scale or 1.0
    local alpha = cfg.opacity or 0.94
    local mode  = normalizeLayoutMode(cfg.layout)
    local pal   = ROLES[entry.role] or ROLES.support

    local dt = anim.lastClock and clamp(now - anim.lastClock, 0, 0.1) or 0.016
    anim.lastClock = now

    local data = layoutMod.build(entry.key, ctx.kv, ctx.def, ctx.rt, entry.role) or {}
    local tctx = { kv = ctx.kv or {}, lvl = tonumber(ctx.level) or 0, boost = ctx.boost }

    -- Status buffs (hidden in Minimal mode for maximum combat clarity)
    local buffs = {}
    if mode ~= 'minimal' then
        for _, b in ipairs(ctx.buffs or {}) do
            local expired = b.expiresAt and now > b.expiresAt + 0.5
            local hidden  = (cfg.showShared == false) and b.entry and b.entry.isShared
            if not expired and not hidden then buffs[#buffs + 1] = b end
        end
    end

    -- Secondary provider trackers (Expanded mode only)
    local deckItems = (mode == 'expanded') and M.collectExpandedResources(ctx.def, ctx.rt, cfg) or {}
    local deckH = (#deckItems > 0) and (DECK_GAP + #deckItems * DECK_ROW_H + 4) or 0

    local innerW = SPINE_X + BAR_W
    local perRow = math.max(1, math.floor((innerW + (RING_PITCH - RING)) / RING_PITCH))
    local hiddenCount = 0
    if #buffs > perRow * MAX_ROWS then
        hiddenCount = #buffs - perRow * MAX_ROWS
        for i = #buffs, perRow * MAX_ROWS + 1, -1 do buffs[i] = nil end
    end
    local rows = math.ceil(#buffs / perRow)

    local pad = (mode == 'minimal') and 4 or PAD
    local chassisH = pad + MED + pad + deckH
    local stripTop = chassisH + STRIP_GAP
    local totalW   = pad + innerW + pad
    local totalH   = (rows > 0) and (stripTop + rows * ROW_H + 4) or (chassisH + 2)
    local W, H     = math.floor(totalW * s + 0.5), math.floor(totalH * s + 0.5)

    -- Viewport clamp so HUD never leaves the FFXI client screen
    local forcePos = ctx.resetPos == true
    local vw, vh = 0, 0
    if F and F.getViewportSize then
        vw, vh = F.getViewportSize(imgui)
    end
    if vw > 0 and vh > 0 then
        local nx, ny = F.clampToViewport(cfg.x, cfg.y, W, H, vw, vh, 4)
        if nx ~= cfg.x or ny ~= cfg.y then
            cfg.x, cfg.y = nx, ny
            forcePos = true
            if ctx.callbacks and ctx.callbacks.onMove then ctx.callbacks.onMove() end
        end
    end

    local WF = IG.WindowFlags
    local flagList = {
        WF.NoTitleBar,
        WF.NoScrollbar,
        WF.NoCollapse,
        WF.NoBackground,
        WF.AlwaysAutoResize,
        WF.NoSavedSettings,
        WF.NoFocusOnAppearing,
        WF.NoResize,
        WF.NoScrollWithMouse,
        cfg.locked and WF.NoMove or 0,
    }
    local flags = 0
    for _, f in ipairs(flagList) do
        flags = (okBit and bit) and bit.bor(flags, f) or (flags + f)
    end

    if ctx.resetPos and ctx.onResetPosApplied then ctx.onResetPosApplied() end
    imgui.SetNextWindowPos({ cfg.x, cfg.y }, forcePos and IG.Cond.Always or IG.Cond.FirstUseEver)
    imgui.PushStyleVar(IG.StyleVar.WindowPadding, { 0, 0 })

    if imgui.Begin('SoulspireSoulHUD##gauge', nil, flags) then
        local wx, wy = toXY(imgui.GetWindowPos())
        if not cfg.locked and (math.floor(wx + 0.5) ~= cfg.x or math.floor(wy + 0.5) ~= cfg.y) then
            cfg.x, cfg.y = math.floor(wx + 0.5), math.floor(wy + 0.5)
            anim.movedAt = now
            if ctx.callbacks and ctx.callbacks.onMove then ctx.callbacks.onMove() end
        end
        wx, wy = math.floor(wx), math.floor(wy)

        imgui.SetCursorScreenPos({ wx, wy })
        imgui.Dummy({ W, H })

        local dl      = imgui.GetWindowDrawList()
        local tint    = abgr(C.white, alpha)
        local goldU32 = abgr(C.gold, alpha)
        local txtU32  = abgr(C.text, alpha)
        local dimU32  = abgr(C.text_dim, alpha)

        -- ===================================================== Chassis Frame
        if mode ~= 'minimal' and F and F.drawPanelFrame then
            F.drawPanelFrame(dl, wx, wy, W, math.floor(chassisH * s), {
                fillTop         = abgr(C.midnight, 0.90 * alpha),
                fillBot         = abgr(C.abyss, 0.94 * alpha),
                border          = abgr(C.border_strong, alpha),
                accent          = abgr(pal.body, 0.85 * alpha),
                rounding        = 6,
                corners         = true,
                cornerSize      = math.floor(8 * s),
                cornerThickness = 1.3,
                shadow          = true,
            })
        else
            -- Minimal mode: ultra-clean dark pill backdrop behind gauges only
            dl:AddRectFilled({ wx, wy }, { wx + W, wy + math.floor(chassisH * s) },
                abgr(C.abyss, 0.72 * alpha), 6)
            dl:AddRect({ wx, wy }, { wx + W, wy + math.floor(chassisH * s) },
                abgr(C.border, 0.85 * alpha), 6, 0, 1.0)
        end

        -- ===================================================== Soul Medallion
        local mx = wx + pad * s
        local my = wy + pad * s
        local ms = MED * s
        local mCx, mCy = mx + ms * 0.5, my + ms * 0.5
        local crystalTex = icons and icons.crystal(entry.key) or nil

        if F and F.drawCrystalMedallion then
            F.drawCrystalMedallion(dl, mCx, mCy, ms * 0.48, {
                texId        = crystalTex,
                rim          = abgr(C.gold, alpha),
                core         = pal.body,
                deep         = pal.deep,
                alpha        = alpha,
                tint         = tint,
                studs        = (mode ~= 'minimal'),
                rimThickness = 1.6,
            })
        end

        -- 3-letter job badge pill at bottom of medallion
        local abrW = 28 * s
        local abrH = 12 * s
        dl:AddRectFilled({ mCx - abrW * 0.5, my + ms - abrH + 1 }, { mCx + abrW * 0.5, my + ms + 1 },
            abgr(C.abyss, 0.96 * alpha), 4)
        dl:AddRect({ mCx - abrW * 0.5, my + ms - abrH + 1 }, { mCx + abrW * 0.5, my + ms + 1 },
            abgr(C.gold_dim, alpha), 4, 0, 1.0)
        drawText(imgui, dl, mCx, my + ms - abrH + 1.5, goldU32, entry.abr, 0.68 * s, 'c', alpha)

        local function soulTip(withHint)
            local info = tips and tips.soul(entry, tctx) or nil
            local lines = info and info.lines or {}
            if withHint then
                lines[#lines + 1] = { sep = true }
                lines[#lines + 1] = {
                    text = ctx.demo and 'Demo preview' or (cfg.locked and 'Locked: /soulhud lock to unlock' or 'Right-click medallion: display mode & options'),
                    color = C.text_dim,
                }
            end
            styledTooltip(imgui, C.gold, entry.name .. '  (' .. entry.abr .. ')', lines, {
                subtitle = (roster.ROLE_LABEL[entry.role] or 'Soul') .. ' Soul Crystal',
                weapon   = info and info.weapon or nil,
            })
        end

        imgui.SetCursorScreenPos({ mx, my })
        imgui.Dummy({ ms, ms })
        if imgui.IsItemHovered() then
            soulTip(true)
            local released, rclick = false, false
            pcall(function() released = imgui.IsMouseReleased(0) end)
            pcall(function() rclick = imgui.IsMouseClicked(1) end)
            if rclick or (released and not cfg.locked and (now - anim.movedAt) > 0.3) then
                imgui.OpenPopup(POPUP_ID)
            end
        end
        drawOptions(imgui, cfg, ctx.callbacks or {}, pal)

        -- ===================================================== Primary Row: Pips / Stance / Fallback Identity
        local sx   = wx + (pad + SPINE_X) * s
        local rowY = wy + (pad + PIP_Y - 5) * s

        if data.pips then
            local p = data.pips
            local pulse = 0.5 + 0.5 * math.sin(now * 5.0)
            if p.badge then
                local x0, y0, x1, y1 = sx, rowY, sx + BAR_W * s, rowY + PILL_H * s
                local rad = PILL_H * s * 0.5
                dl:AddRectFilled({ x0, y0 }, { x1, y1 }, abgr(pal.deep, 0.94 * alpha), rad)
                dl:AddRect({ x0, y0 }, { x1, y1 }, p.glow and goldU32 or abgr(pal.body, 0.90 * alpha), rad, 0, p.glow and 1.4 or 1.1)
                local innerBarW = (BAR_W - 18) * s
                local rTxt = tostring(p.right or '')
                if rTxt ~= '' then
                    rTxt = fitText(imgui, rTxt, innerBarW * 0.45, 0.72 * s)
                    drawText(imgui, dl, x1 - 9 * s, y0 + 5 * s, p.glow and goldU32 or abgr(C.cyan, alpha), rTxt, 0.72 * s, 'r', alpha)
                end
                local lTxt = fitText(imgui, p.label, innerBarW * 0.55, 0.78 * s)
                drawText(imgui, dl, x0 + 9 * s, y0 + 4 * s, p.glow and goldU32 or txtU32, lTxt, 0.78 * s, 'l', alpha)
            else
                local gemRgba = GEM_COLORS[p.gem] or pal.body
                if F and F.drawPipRow then
                    F.drawPipRow(dl, sx + 2 * s, rowY + 3 * s, p.cur, p.max, {
                        size  = 14 * s,
                        pitch = 19 * s,
                        lit   = gemRgba,
                        alpha = alpha,
                        glow  = p.glow,
                        pulse = pulse,
                    })
                end
                local pipsEndX   = sx + (2 + p.max * 19 + 4) * s
                local rightEdgeX = sx + (BAR_W - 2) * s
                local availW     = math.max(24 * s, rightEdgeX - pipsEndX)
                local lab        = p.right or ('%s %d/%d'):format(string.upper(p.label), p.cur, p.max)
                lab = fitText(imgui, lab, availW, 0.74 * s)
                drawText(imgui, dl, rightEdgeX, rowY + 4 * s,
                    (p.glow or p.cur >= p.max) and goldU32 or dimU32, lab, 0.74 * s, 'r', alpha)
            end
            imgui.SetCursorScreenPos({ sx, rowY })
            imgui.Dummy({ BAR_W * s, PILL_H * s })
            if imgui.IsItemHovered() then
                local lines = tips and tips.element(entry.key, 'pips', tctx) or nil
                local headTitle = p.badge and (p.label .. (p.right and ('  |  ' .. p.right) or ''))
                    or ('%s  %d / %d'):format(p.label, p.cur, p.max)
                styledTooltip(imgui, C.gold, headTitle, lines or { { text = p.right or ('%d / %d'):format(p.cur, p.max) } })
            end
        else
            -- Safe fallback when a Soul has no active bespoke gauge provider
            local roleStr = string.upper(roster.ROLE_LABEL[entry.role] or 'SOUL')
            local x0, y0, x1, y1 = sx, rowY + 4 * s, sx + BAR_W * s, rowY + (4 + PILL_H) * s
            local rad = PILL_H * s * 0.5
            dl:AddRectFilled({ x0, y0 }, { x1, y1 }, abgr(pal.deep, 0.94 * alpha), rad)
            dl:AddRect({ x0, y0 }, { x1, y1 }, abgr(C.gold_dim, alpha), rad, 0, 1.1)
            drawText(imgui, dl, x0 + 10 * s, y0 + 4 * s, goldU32, fitText(imgui, entry.name, (BAR_W - 84) * s, 0.88 * s), 0.88 * s, 'l', alpha)
            drawText(imgui, dl, x1 - 10 * s, y0 + 5 * s, abgr(pal.body, alpha), roleStr, 0.74 * s, 'r', alpha)
            if not data.bar then
                drawText(imgui, dl, sx + 4 * s, wy + (pad + BAR_Y + 2) * s, dimU32,
                    'No bespoke combat gauge active', 0.70 * s, 'l', alpha)
            end
            imgui.SetCursorScreenPos({ x0, y0 })
            imgui.Dummy({ BAR_W * s, PILL_H * s })
            if imgui.IsItemHovered() then soulTip(false) end
        end

        -- ===================================================== Primary Resource / Timer Bar
        if data.bar then
            local b = data.bar
            local bx, by = sx, wy + (pad + BAR_Y - 2) * s
            local key = entry.key .. ':' .. b.key

            local cur = tonumber(b.cur) or 0
            if b.countdown and cur > 0 then
                cur = math.max(0, cur - (now - (ctx.syncAt or now)))
            end
            local mxv = b.max
            if mxv == nil then
                local pk = anim.peak[key] or 0
                if (tonumber(b.cur) or 0) <= 0 then pk = 0 end
                pk = math.max(pk, tonumber(b.cur) or 0)
                anim.peak[key] = pk
                mxv = math.max(1, pk)
            end

            local target = clamp(cur / mxv, 0, 1)
            local disp = anim.disp[key]
            if disp == nil then disp = target end
            disp = disp + (target - disp) * math.min(1, dt * 9)
            if math.abs(target - disp) < 0.0015 then disp = target end
            anim.disp[key] = disp

            local labelStr = (b.warn and '[!] ' or '') .. tostring(b.label or '')
            local valStr   = barValueText(b, cur, mxv)
            if F and F.drawSegmentedGauge then
                F.drawSegmentedGauge(imgui, dl, bx, by, BAR_W * s, BAR_H * s, disp, 1.0, {
                    fill      = pal.body,
                    border    = abgr(C.gold_dim, alpha),
                    notches   = b.notches,
                    warn      = b.warn == true,
                    label     = labelStr,
                    valueText = valStr,
                    fontScale = 0.76 * s,
                    alpha     = alpha,
                    rounding  = 4,
                })
            end

            imgui.SetCursorScreenPos({ bx, by })
            imgui.Dummy({ BAR_W * s, BAR_H * s })
            if imgui.IsItemHovered() then
                local lines = tips and tips.element(entry.key, 'bar', tctx) or nil
                styledTooltip(imgui, b.warn and C.warn or C.gold,
                    ('%s  %s'):format(b.label, valStr),
                    lines or { { text = valStr } })
            end
        end

        -- ===================================================== Expanded Secondary Mechanics Deck
        if mode == 'expanded' and #deckItems > 0 then
            local deckTop = wy + (pad + MED + DECK_GAP) * s
            local dx = wx + pad * s
            local dw = innerW * s

            if dl.AddLine then
                dl:AddLine({ dx, deckTop - 3 * s }, { dx + dw, deckTop - 3 * s }, abgr(C.border, 0.85 * alpha), 1.0)
            end

            for idx, item in ipairs(deckItems) do
                local res, st = item.res, item.st
                local ry = deckTop + (idx - 1) * DECK_ROW_H * s
                local warn = evaluateResourceWarning(res, st)
                local rowFill, curVal, maxVal, valStr, tagStr

                if res.type == 'charges' then
                    curVal  = tonumber(st.charges) or tonumber(st.current) or 0
                    maxVal  = math.max(1, tonumber(st.maxCharges) or tonumber(res.maxCharges) or 1)
                    valStr  = (curVal < maxVal and (st.remaining or 0) > 0)
                        and ('%d/%d (%s)'):format(curVal, maxVal, fmtTime(st.remaining))
                        or ('%d/%d RDY'):format(curVal, maxVal)
                    rowFill = curVal > 0 and C.gold or C.border_strong
                    tagStr  = res.shortLabel or res.label
                elseif res.type == 'cooldown' then
                    local rem = tonumber(st.remaining) or 0
                    local dur = math.max(1, tonumber(res.duration) or 30)
                    curVal  = rem > 0 and math.max(0, dur - rem) or dur
                    maxVal  = dur
                    valStr  = rem > 0 and fmtTime(rem) or 'READY'
                    rowFill = rem > 0 and C.violet or C.cyan
                    tagStr  = res.shortLabel or res.label
                elseif res.type == 'timer' then
                    local rem = tonumber(st.remaining) or 0
                    local dur = math.max(1, tonumber(res.duration) or 15)
                    curVal  = rem
                    maxVal  = dur
                    valStr  = rem > 0 and fmtTime(rem) or 'IDLE'
                    rowFill = C.cyan
                    tagStr  = res.shortLabel or res.label
                elseif res.type == 'toggle' or res.type == 'status' or res.type == 'combo' then
                    local active = st.active == true or (tonumber(st.current) or 0) > 0
                    curVal  = active and 1 or 0
                    maxVal  = 1
                    if type(res.format) == 'function' then
                        local okF, formatted = pcall(res.format, st, res)
                        valStr = (okF and formatted and formatted ~= '') and tostring(formatted) or (active and 'ACTIVE' or 'OFF')
                    elseif st.text and st.text ~= '' then
                        valStr = st.text
                    else
                        valStr = active and 'ACTIVE' or 'OFF'
                    end
                    rowFill = active and C.gold or C.border_strong
                    tagStr  = res.shortLabel or res.label
                else
                    curVal  = tonumber(st.current) or 0
                    maxVal  = math.max(1, tonumber(st.max) or tonumber(res.max) or 1)
                    if type(res.format) == 'function' then
                        local okF, formatted = pcall(res.format, st, res)
                        valStr = (okF and formatted and formatted ~= '') and tostring(formatted) or ('%d/%d'):format(math.floor(curVal + 0.5), math.floor(maxVal + 0.5))
                    elseif st.text and st.text ~= '' then
                        valStr = st.text
                    else
                        valStr = ('%d/%d'):format(math.floor(curVal + 0.5), math.floor(maxVal + 0.5))
                    end
                    rowFill = pal.body
                    tagStr  = res.shortLabel or res.label
                end

                local cue = (res.builder and res.spender) and (tagStr .. '  [' .. res.builder .. '->' .. res.spender .. ']') or tagStr
                if warn then cue = '[!] ' .. cue end

                if F and F.drawSegmentedGauge then
                    F.drawSegmentedGauge(imgui, dl, dx, ry + 2 * s, dw, (DECK_ROW_H - 4) * s, curVal, maxVal, {
                        fill      = rowFill,
                        border    = abgr(warn and C.warn or C.border, alpha),
                        notches   = (res.type == 'charges' or res.type == 'stack') and maxVal or 0,
                        warn      = warn,
                        label     = cue,
                        valueText = valStr,
                        fontScale = 0.70 * s,
                        alpha     = alpha,
                        rounding  = 3,
                    })
                end
            end
        end

        -- ===================================================== Wrapped Status Buff/Debuff Strip
        if #buffs > 0 then
            local ringTex = icons and icons.ui('buff_ring_gold') or nil
            for i, b in ipairs(buffs) do
                local colIdx = (i - 1) % perRow
                local rowIdx = math.floor((i - 1) / perRow)
                local ix = wx + (pad + colIdx * RING_PITCH) * s
                local iy = wy + (stripTop + rowIdx * ROW_H) * s
                local entryB = b.entry
                local isDebuff = entryB and entryB.isDebuff
                local rem = b.expiresAt and math.max(0, b.expiresAt - now) or nil

                local iconTex = icons and icons.custom(b.iconId) or nil
                local o = (RING - ICON) * 0.5 * s
                if not image(dl, iconTex, ix + o, iy + o, ix + o + ICON * s, iy + o + ICON * s, tint) then
                    dl:AddRectFilled({ ix + o, iy + o }, { ix + o + ICON * s, iy + o + ICON * s }, abgr(C.abyss, alpha), 4)
                end
                if not image(dl, ringTex, ix, iy, ix + RING * s, iy + RING * s,
                    isDebuff and abgr(C.warn, alpha) or tint) then
                    dl:AddRect({ ix + 1, iy + 1 }, { ix + RING * s - 1, iy + RING * s - 1 },
                        abgr(isDebuff and C.warn or C.gold, alpha), 5, 0, 1.4)
                end

                local badge = powerBadge(b.power)
                if badge ~= '' then
                    drawText(imgui, dl, ix + (RING - 3) * s, iy + 3 * s, goldU32, badge, 0.70 * s, 'r', alpha)
                end
                if rem then
                    drawText(imgui, dl, ix + RING * s * 0.5, iy + (RING + 0.5) * s,
                        rem < 5 and abgr(C.warn, alpha) or txtU32, fmtTime(rem), 0.68 * s, 'c', alpha)
                end

                imgui.SetCursorScreenPos({ ix, iy })
                imgui.Dummy({ RING * s, (RING + TIMER_H) * s })
                if imgui.IsItemHovered() then
                    local title, lines
                    if tips then
                        title, lines = tips.buff(b, now, fmtTime)
                    else
                        title = entryB and entryB.name or ('Effect #' .. tostring(b.iconId))
                        lines = { { text = entryB and entryB.tooltip or '' } }
                        if rem then lines[#lines + 1] = { text = 'Remaining: ' .. fmtTime(rem), color = C.text_dim } end
                    end
                    if (tonumber(b.power) or 0) > 0 then
                        lines[#lines + 1] = { text = 'Potency: ' .. powerBadge(b.power), color = C.gold }
                    end
                    styledTooltip(imgui, isDebuff and C.warn or C.gold, title, lines)
                end
            end
            if hiddenCount > 0 then
                drawText(imgui, dl, wx + W - pad * s, wy + (stripTop - 11) * s, dimU32, ('+%d more'):format(hiddenCount), 0.64 * s, 'r', alpha)
            end
        end

        imgui.SetCursorScreenPos({ wx, wy + H - 1 })
        imgui.Dummy({ W, 1 })
    end
    imgui.End()
    imgui.PopStyleVar(1)
end

return M
