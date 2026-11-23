-- SoulspireXI Core UI Foundations
-- Shared visual design system, responsive viewport layout engine, and reusable
-- Ashita v4 ImGui DrawList components for SoulspireXI Core, The Soulforge
-- (WS Talents), and the Universal Soul HUD.
--
-- Pure LuaJIT + Ashita v4 ImGui DrawList (no native hooks, no gameplay logic).

local okBit, bit = pcall(require, 'bit')

local F = {}

-- ---------------------------------------------------------------------------
-- 1. Color Utilities & Official SoulspireXI Palette
-- ---------------------------------------------------------------------------
local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end
F.clamp = clamp

function F.hex(hexStr, alpha)
    local h = tostring(hexStr or ''):gsub('^#', '')
    if #h ~= 6 then
        return { 1, 1, 1, alpha or 1 }
    end
    local r = tonumber(h:sub(1, 2), 16) or 255
    local g = tonumber(h:sub(3, 4), 16) or 255
    local b = tonumber(h:sub(5, 6), 16) or 255
    return { r / 255, g / 255, b / 255, alpha or 1.0 }
end

function F.withAlpha(c, alpha)
    return { c[1], c[2], c[3], clamp(alpha or c[4] or 1.0, 0, 1) }
end

function F.mix(a, b, t, alpha)
    t = clamp(t or 0.5, 0, 1)
    return {
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t,
        alpha ~= nil and alpha or ((a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t),
    }
end

function F.abgr(c, alphaOverride)
    local r = math.floor(clamp(c[1] or 0, 0, 1) * 255 + 0.5)
    local g = math.floor(clamp(c[2] or 0, 0, 1) * 255 + 0.5)
    local b = math.floor(clamp(c[3] or 0, 0, 1) * 255 + 0.5)
    local a = math.floor(clamp(alphaOverride ~= nil and alphaOverride or (c[4] or 1), 0, 1) * 255 + 0.5)
    if okBit and bit then
        local v = bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(g, 8), r)
        if v < 0 then v = v + 4294967296 end
        return v
    end
    return a * 16777216 + b * 65536 + g * 256 + r
end

-- Official SoulspireXI Palette (RGBA float4)
F.rgba = {
    -- Core brand surfaces & accents
    abyss             = F.hex('#0B1019', 0.98), -- Primary deep backdrop / inset wells
    abyss_solid       = F.hex('#0B1019', 1.00),
    abyss_glass       = F.hex('#0B1019', 0.88),
    midnight          = F.hex('#151928', 0.97), -- Primary elevated panel surface
    midnight_alt      = F.hex('#1B2135', 0.97), -- Secondary card / hover surface
    midnight_selected = F.hex('#222A42', 0.98), -- Active / selected container fill
    midnight_deep     = F.hex('#101422', 0.96), -- Recessed rail / header band

    soul_gold         = F.hex('#E8BD70', 1.00), -- Progression, mastery, selected
    soul_gold_bright  = F.hex('#F6D896', 1.00), -- Hover / active highlight
    soul_gold_dim     = F.hex('#9E7F49', 1.00), -- Subtle metallic trim
    soul_gold_wash    = F.hex('#E8BD70', 0.14), -- Soft active surface tint

    aether_cyan       = F.hex('#39CFE5', 1.00), -- Actionable, unlockable, info, focus
    aether_cyan_dim   = F.hex('#247E91', 1.00),
    aether_cyan_wash  = F.hex('#39CFE5', 0.14),

    crystal_violet        = F.hex('#8063BC', 1.00), -- Soul identity, aetheric accents
    crystal_violet_bright = F.hex('#A78CE0', 1.00),
    crystal_violet_dim    = F.hex('#4E3B78', 1.00),
    crystal_violet_wash   = F.hex('#8063BC', 0.16),

    -- Text hierarchy
    text_primary      = F.hex('#F1F5F9', 1.00),
    text_secondary    = F.hex('#A8B5C8', 1.00),
    text_muted        = F.hex('#6B788E', 1.00),
    text_disabled     = F.hex('#4A5568', 1.00),

    -- Borders & elevation
    border_subtle     = F.hex('#263047', 1.00),
    border_strong     = F.hex('#3B4969', 1.00),
    shadow            = { 0.00, 0.00, 0.00, 0.58 },
    scrim             = { 0.03, 0.05, 0.08, 0.72 },
    white             = { 1.00, 1.00, 1.00, 1.00 },
    black             = { 0.00, 0.00, 0.00, 1.00 },

    -- Semantic status colors
    success           = F.hex('#4ADE80', 1.00),
    success_wash      = F.hex('#4ADE80', 0.14),
    warning           = F.hex('#F5A623', 1.00),
    warning_wash      = F.hex('#F5A623', 0.16),
    danger            = F.hex('#EF5350', 1.00),
    danger_dim        = F.hex('#8B2629', 1.00),
    danger_wash       = F.hex('#EF5350', 0.16),

    -- Native FFXI main-menu-inspired surface (Core dock fallback)
    ffxi_navy         = { 0.063, 0.106, 0.212, 0.95 },
    ffxi_selection    = { 0.133, 0.224, 0.345, 0.97 },
    ffxi_silver       = { 0.537, 0.592, 0.678, 1.00 },
    ffxi_edge         = { 0.161, 0.224, 0.322, 1.00 },
}

-- Precomputed packed ABGR u32 colors (zero per-frame conversion for static tokens)
F.u32 = {}
for k, v in pairs(F.rgba) do
    F.u32[k] = F.abgr(v)
end

-- Role palettes harmonized with SoulspireXI brand colors
F.roles = {
    tank    = { accent = F.hex('#39CFE5', 1.0), secondary = F.rgba.soul_gold,      deep = F.hex('#0E1D2F', 0.95), label = 'TANK' },
    healer  = { accent = F.hex('#4ADE80', 1.0), secondary = F.rgba.soul_gold,      deep = F.hex('#0D241E', 0.95), label = 'HEALER' },
    support = { accent = F.rgba.crystal_violet, secondary = F.rgba.aether_cyan,    deep = F.hex('#1B1530', 0.95), label = 'SUPPORT' },
    damage  = { accent = F.hex('#E55C6C', 1.0), secondary = F.rgba.soul_gold,      deep = F.hex('#27121C', 0.95), label = 'DAMAGE' },
}

-- Spacing tokens (base pixels at uiScale = 1.0)
F.space = {
    xs = 4,
    sm = 8,
    md = 12,
    lg = 16,
    xl = 24,
}

-- ---------------------------------------------------------------------------
-- 2. Node Visual State Spec (Color + Non-Color Symbol + Border Style)
-- ---------------------------------------------------------------------------
F.NODE_STATES = {
    locked = {
        tag       = 'LOCKED',
        symbol    = 'x',
        fill      = F.hex('#0E131F', 0.94),
        border    = F.rgba.border_subtle,
        text      = F.rgba.text_muted,
        accent    = F.rgba.text_muted,
        thickness = 1.0,
        doubleRim = false,
    },
    prereq_blocked = {
        tag       = 'REQ',
        symbol    = '!',
        fill      = F.hex('#171422', 0.95),
        border    = F.hex('#7C4752', 0.95),
        text      = F.rgba.text_secondary,
        accent    = F.rgba.warning,
        thickness = 1.2,
        doubleRim = false,
    },
    available = {
        tag       = 'OPEN',
        symbol    = '+',
        fill      = F.hex('#132233', 0.97),
        border    = F.rgba.aether_cyan,
        text      = F.rgba.text_primary,
        accent    = F.rgba.aether_cyan,
        thickness = 1.6,
        doubleRim = false,
    },
    learned = {
        tag       = 'LEARNED',
        symbol    = '*',
        fill      = F.hex('#221E18', 0.98),
        border    = F.rgba.soul_gold,
        text      = F.rgba.soul_gold_bright,
        accent    = F.rgba.soul_gold,
        thickness = 1.8,
        doubleRim = false,
    },
    maxed = {
        tag       = 'MAXED',
        symbol    = '#',
        fill      = F.hex('#272115', 0.99),
        border    = F.rgba.soul_gold_bright,
        text      = F.rgba.soul_gold_bright,
        accent    = F.rgba.soul_gold_bright,
        thickness = 2.0,
        doubleRim = true,
    },
    pending = {
        tag       = 'SYNC...',
        symbol    = '~',
        fill      = F.hex('#152538', 0.98),
        border    = F.rgba.aether_cyan,
        text      = F.rgba.aether_cyan,
        accent    = F.rgba.aether_cyan,
        thickness = 2.0,
        doubleRim = true,
    },
    rejected = {
        tag       = 'REJECTED',
        symbol    = '!',
        fill      = F.hex('#2B141A', 0.98),
        border    = F.rgba.danger,
        text      = F.rgba.danger,
        accent    = F.rgba.danger,
        thickness = 2.0,
        doubleRim = false,
    },
}

-- ---------------------------------------------------------------------------
-- 3. Resolution-Independent Viewport & Responsive Layout Engine
-- ---------------------------------------------------------------------------
function F.toXY(a, b)
    if type(a) == 'table' then
        return a[1] or a.x or 0, a[2] or a.y or 0
    end
    return a or 0, b or 0
end

function F.getViewportSize(imgui)
    if imgui and imgui.GetIO then
        local ok, w, h = pcall(function()
            local io = imgui.GetIO()
            if io and io.DisplaySize then
                return F.toXY(io.DisplaySize)
            end
            return 0, 0
        end)
        if ok and type(w) == 'number' and type(h) == 'number' and w > 0 and h > 0 then
            return math.floor(w + 0.5), math.floor(h + 0.5)
        end
    end
    return 1920, 1080
end

-- Computes resolution-independent layout mode and panel geometry from actual
-- FFXI client viewport dimensions + independent user UI scale.
-- Modes:
--   'expanded' : 3-panel layout with generous Arsenal, Soulforge, and Inspector
--   'balanced' : 3-panel layout with optimized spacing & reduced ornamentation
--   'focused'  : Soulforge priority; Arsenal & Inspector collapse into drawers
function F.computeViewportLayout(viewW, viewH, uiScale, opts)
    opts = opts or {}
    local vw = math.max(640, tonumber(viewW) or 1920)
    local vh = math.max(480, tonumber(viewH) or 1080)
    local scale = clamp(tonumber(uiScale) or 1.0, 0.75, 1.50)

    local marginX = math.max(12, math.floor(math.min(40, vw * 0.025)))
    local marginY = math.max(12, math.floor(math.min(36, vh * 0.028)))
    local maxWinW = math.floor(math.min(vw - marginX * 2, (opts.maxLogicalW or 1920) * scale))
    local maxWinH = math.floor(math.min(vh - marginY * 2, (opts.maxLogicalH or 1160) * scale))

    local winW = math.max(math.min(vw - 8, 620), maxWinW)
    local winH = math.max(math.min(vh - 8, 440), maxWinH)

    -- Effective logical dimensions drive responsive mode (never hardcoded monitor names)
    local effW = winW / scale
    local effH = winH / scale

    local mode
    if effW >= 1720 and effH >= 1040 then
        mode = 'expanded'
    elseif effW >= 1260 and effH >= 740 then
        mode = 'balanced'
    else
        mode = 'focused'
    end

    local pad    = math.floor(((mode == 'expanded' and 14) or (mode == 'balanced' and 10) or 8) * scale + 0.5)
    local gap    = math.floor(((mode == 'expanded' and 12) or (mode == 'balanced' and 8) or 6) * scale + 0.5)
    local headH  = math.floor(((mode == 'focused' and 64) or (mode == 'balanced' and 72) or 78) * scale + 0.5)
    local footH  = math.floor(((mode == 'focused' and 38) or 42) * scale + 0.5)
    local bodyH  = math.max(220, winH - headH - footH - pad * 2 - gap * 2)
    local innerW = math.max(320, winW - pad * 2)

    local arsenalW, inspectorW, forgeW
    local showArsenal, showInspector = true, true
    local drawerMode = (mode == 'focused')

    if mode == 'expanded' then
        arsenalW   = math.floor(clamp(innerW * 0.21, 250 * scale, 340 * scale))
        inspectorW = math.floor(clamp(innerW * 0.26, 310 * scale, 410 * scale))
        forgeW     = math.max(420, innerW - arsenalW - inspectorW - gap * 2)
    elseif mode == 'balanced' then
        arsenalW   = math.floor(clamp(innerW * 0.22, 210 * scale, 275 * scale))
        inspectorW = math.floor(clamp(innerW * 0.27, 255 * scale, 330 * scale))
        forgeW     = math.max(360, innerW - arsenalW - inspectorW - gap * 2)
    else
        -- Focused mode: Forge takes primary space; Arsenal / Inspector open as drawers
        showArsenal   = false
        showInspector = false
        arsenalW      = math.floor(clamp(innerW * 0.42, 220 * scale, 320 * scale))
        inspectorW    = math.floor(clamp(innerW * 0.46, 250 * scale, 360 * scale))
        forgeW        = innerW
    end

    -- Clamp window position inside viewport
    local posX = math.floor((vw - winW) * 0.5)
    local posY = math.floor((vh - winH) * 0.5)

    return {
        viewW         = vw,
        viewH         = vh,
        uiScale       = scale,
        effW          = effW,
        effH          = effH,
        mode          = mode,
        drawerMode    = drawerMode,
        winW          = winW,
        winH          = winH,
        posX          = posX,
        posY          = posY,
        pad           = pad,
        gap           = gap,
        headerH       = headH,
        footerH       = footH,
        bodyH         = bodyH,
        innerW        = innerW,
        arsenalW      = arsenalW,
        forgeW        = forgeW,
        inspectorW    = inspectorW,
        showArsenal   = showArsenal,
        showInspector = showInspector,
        ornamentLevel = (mode == 'expanded' and 2) or (mode == 'balanced' and 1) or 0,
    }
end

-- Clamp any floating window (e.g. Soul HUD) strictly inside the client viewport
function F.clampToViewport(x, y, w, h, viewW, viewH, pad)
    pad = pad or 4
    local maxX = math.max(pad, (viewW or 1920) - (w or 0) - pad)
    local maxY = math.max(pad, (viewH or 1080) - (h or 0) - pad)
    return math.floor(clamp(x or pad, pad, maxX) + 0.5),
           math.floor(clamp(y or pad, pad, maxY) + 0.5)
end

-- ---------------------------------------------------------------------------
-- 4. Text & Typography Helpers
-- ---------------------------------------------------------------------------
function F.utf8Len(str)
    local _, count = tostring(str or ''):gsub('[^\128-\191]', '')
    return count
end

function F.measureText(imgui, str, fontScale)
    local fs = fontScale or 1.0
    local s = tostring(str or '')
    if imgui and imgui.CalcTextSize then
        local scaled = false
        if fs ~= 1.0 and imgui.SetWindowFontScale then
            imgui.SetWindowFontScale(fs)
            scaled = true
        end
        local ok, w, h = pcall(function() return F.toXY(imgui.CalcTextSize(s)) end)
        if scaled and imgui.SetWindowFontScale then
            imgui.SetWindowFontScale(1.0)
        end
        if ok and type(w) == 'number' and w > 0 then
            return w, (type(h) == 'number' and h > 0) and h or math.floor(14 * fs + 0.5)
        end
    end
    return math.floor(F.utf8Len(s) * 7.2 * fs + 0.5), math.floor(14 * fs + 0.5)
end

function F.fitText(imgui, str, maxW, fontScale)
    local s = tostring(str or ''):gsub('[\r\n]+', ' ')
    if maxW <= 4 or s == '' then return '' end
    local w = F.measureText(imgui, s, fontScale)
    if w <= maxW then return s end
    local lo, hi = 1, #s
    local best = ''
    while lo <= hi do
        local mid = math.floor((lo + hi) * 0.5)
        local cand = s:sub(1, mid):gsub('%s+$', '') .. '..'
        if F.measureText(imgui, cand, fontScale) <= maxW then
            best = cand
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return best
end

function F.wrapLines(str, maxChars, maxLines)
    local clean = tostring(str or ''):gsub('[\r\n]+', ' ')
    local limit = math.max(8, math.floor(maxChars or 36))
    local lines = {}
    local cur = ''
    for word in clean:gmatch('%S+') do
        if cur == '' then
            cur = word
        elseif #cur + 1 + #word <= limit then
            cur = cur .. ' ' .. word
        else
            lines[#lines + 1] = cur
            cur = word
            if maxLines and #lines >= maxLines then
                cur = ''
                break
            end
        end
    end
    if cur ~= '' then
        lines[#lines + 1] = cur
    end
    if maxLines and #lines > maxLines then
        lines[maxLines] = lines[maxLines]:sub(1, math.max(1, limit - 2)) .. '..'
        for i = #lines, maxLines + 1, -1 do lines[i] = nil end
    end
    return lines
end

-- Crisp 1px drop-shadowed text via DrawList (supports alignment 'l', 'c', 'r')
function F.drawShadowText(imgui, dl, x, y, text, colorU32, fontScale, align, alpha)
    local s = tostring(text or '')
    if s == '' then return 0, 0 end
    local fs = fontScale or 1.0
    local w, h = F.measureText(imgui, s, fs)
    local tx = x
    if align == 'r' then
        tx = x - w
    elseif align == 'c' then
        tx = x - w * 0.5
    end
    tx = math.floor(tx + 0.5)
    local ty = math.floor(y + 0.5)

    local scaled = false
    if fs ~= 1.0 and imgui and imgui.SetWindowFontScale then
        imgui.SetWindowFontScale(fs)
        scaled = true
    end
    if dl and dl.AddText then
        dl:AddText({ tx + 1, ty + 1 }, F.abgr(F.rgba.black, 0.85 * (alpha or 1.0)), s)
        dl:AddText({ tx, ty }, colorU32 or F.u32.text_primary, s)
    elseif imgui and imgui.SetCursorScreenPos and imgui.TextUnformatted then
        imgui.SetCursorScreenPos({ tx, ty })
        imgui.TextUnformatted(s)
    end
    if scaled and imgui and imgui.SetWindowFontScale then
        imgui.SetWindowFontScale(1.0)
    end
    return w, h
end

function F.textUnformatted(imgui, text, rgba)
    if not imgui then return end
    local s = tostring(text or '')
    if rgba and imgui.PushStyleColor then
        imgui.PushStyleColor(ImGuiCol_Text or 0, rgba)
    end
    if imgui.TextUnformatted then
        imgui.TextUnformatted(s)
    elseif imgui.Text then
        imgui.Text((s:gsub('%%', '%%%%')))
    end
    if rgba and imgui.PopStyleColor then
        imgui.PopStyleColor()
    end
end

-- ---------------------------------------------------------------------------
-- 5. Reusable AAA Vector / DrawList UI Primitives
-- ---------------------------------------------------------------------------
function F.drawGradRect(dl, x0, y0, x1, y1, topU32, botU32)
    if not dl then return end
    if dl.AddRectFilledMultiColor then
        dl:AddRectFilledMultiColor({ x0, y0 }, { x1, y1 }, topU32, topU32, botU32, botU32)
    elseif dl.AddRectFilled then
        dl:AddRectFilled({ x0, y0 }, { x1, y1 }, botU32)
    end
end

-- Layered dark-fantasy panel frame with Abyss/Midnight depth, subtle top edge
-- sheen, optional corner crystal ticks, and outer drop shadow.
function F.drawPanelFrame(dl, x, y, w, h, opts)
    if not dl then return end
    opts = opts or {}
    local r = opts.rounding or 6
    local fillTop = opts.fillTop or F.u32.midnight
    local fillBot = opts.fillBot or F.u32.abyss
    local border  = opts.border or F.u32.border_subtle
    local accent  = opts.accent or F.u32.soul_gold_dim
    local thick   = opts.thickness or 1.1
    local corners = opts.corners ~= false

    if opts.shadow ~= false then
        dl:AddRectFilled({ x + 3, y + 4 }, { x + w + 3, y + h + 4 }, F.u32.shadow, r)
    end
    dl:AddRectFilled({ x, y }, { x + w, y + h }, fillBot, r)
    if dl.AddRectFilledMultiColor and h > 12 then
        dl:AddRectFilledMultiColor({ x + 1, y + 1 }, { x + w - 1, y + math.min(h - 1, 44) },
            fillTop, fillTop, fillBot, fillBot)
    end
    dl:AddRect({ x, y }, { x + w, y + h }, border, r, 0, thick)

    -- Subtle inner top highlight line
    if dl.AddLine and w > 24 then
        dl:AddLine({ x + r + 2, y + 1 }, { x + w - r - 2, y + 1 }, F.abgr(F.rgba.white, 0.08), 1.0)
    end

    -- Corner crystal L-ticks for premium Soulforge framing
    if corners and dl.AddLine and w >= 60 and h >= 40 then
        local tick = opts.cornerSize or 10
        local ct = opts.cornerThickness or 1.4
        -- Top-left
        dl:AddLine({ x + 1, y + tick }, { x + 1, y + 1 }, accent, ct)
        dl:AddLine({ x + 1, y + 1 }, { x + tick, y + 1 }, accent, ct)
        -- Top-right
        dl:AddLine({ x + w - tick, y + 1 }, { x + w - 1, y + 1 }, accent, ct)
        dl:AddLine({ x + w - 1, y + 1 }, { x + w - 1, y + tick }, accent, ct)
        -- Bottom-left
        dl:AddLine({ x + 1, y + h - tick }, { x + 1, y + h - 1 }, accent, ct)
        dl:AddLine({ x + 1, y + h - 1 }, { x + tick, y + h - 1 }, accent, ct)
        -- Bottom-right
        dl:AddLine({ x + w - tick, y + h - 1 }, { x + w - 1, y + h - 1 }, accent, ct)
        dl:AddLine({ x + w - 1, y + h - tick }, { x + w - 1, y + h - 1 }, accent, ct)
    end
end

-- Ornamental divider with center diamond
function F.drawDivider(dl, x, y, w, accentU32)
    if not dl or w < 16 then return end
    local mid = x + w * 0.5
    local col = accentU32 or F.u32.border_strong
    local dim = F.u32.border_subtle
    dl:AddLine({ x, y }, { mid - 8, y }, dim, 1.0)
    dl:AddLine({ mid + 8, y }, { x + w, y }, dim, 1.0)
    if dl.AddQuadFilled then
        dl:AddQuadFilled({ mid, y - 3 }, { mid + 4, y }, { mid, y + 3 }, { mid - 4, y }, col)
    end
end

-- Faceted Soul Crystal / WS Medallion emblem (with optional D3D8 texture)
function F.drawCrystalMedallion(dl, cx, cy, radius, opts)
    if not dl then return end
    opts = opts or {}
    local r = radius or 24
    local rimCol   = opts.rim or F.u32.soul_gold
    local coreCol  = opts.core or F.rgba.crystal_violet
    local deepCol  = opts.deep or F.rgba.abyss_solid
    local alpha    = opts.alpha or 1.0

    -- Outer octagonal / diamond housing
    if dl.AddCircleFilled then
        dl:AddCircleFilled({ cx, cy }, r + 2, F.abgr(F.rgba.black, 0.55 * alpha), 24)
        dl:AddCircleFilled({ cx, cy }, r, F.abgr(deepCol, 0.96 * alpha), 24)
    end
    if opts.texId and dl.AddImage then
        local ir = r * 0.74
        dl:AddImage(opts.texId, { cx - ir, cy - ir }, { cx + ir, cy + ir }, { 0, 0 }, { 1, 1 },
            opts.tint or F.abgr(F.rgba.white, alpha))
    elseif dl.AddTriangleFilled then
        local cr = r * 0.68
        local lite = F.abgr(F.mix(coreCol, F.rgba.white, 0.42), alpha)
        local mid  = F.abgr(coreCol, alpha)
        local dark = F.abgr(F.mix(coreCol, F.rgba.black, 0.48), alpha)
        dl:AddTriangleFilled({ cx, cy - cr }, { cx + cr * 0.68, cy }, { cx, cy + cr * 0.18 }, lite)
        dl:AddTriangleFilled({ cx, cy - cr }, { cx - cr * 0.68, cy }, { cx, cy + cr * 0.18 }, mid)
        dl:AddTriangleFilled({ cx - cr * 0.68, cy }, { cx + cr * 0.68, cy }, { cx, cy + cr }, dark)
        dl:AddTriangleFilled({ cx - cr * 0.68, cy }, { cx, cy + cr * 0.18 }, { cx, cy + cr }, mid)
    end
    if dl.AddCircle then
        dl:AddCircle({ cx, cy }, r, rimCol, 24, opts.rimThickness or 1.8)
        dl:AddCircle({ cx, cy }, r - 3, F.abgr(F.rgba.white, 0.14 * alpha), 24, 1.0)
    end
    -- Cardinal diamond studs
    if opts.studs ~= false and dl.AddQuadFilled then
        local s = math.max(2, r * 0.12)
        for _, pt in ipairs({ { cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy } }) do
            dl:AddQuadFilled(
                { pt[1], pt[2] - s }, { pt[1] + s, pt[2] },
                { pt[1], pt[2] + s }, { pt[1] - s, pt[2] },
                rimCol
            )
        end
    end
end

-- Pill badge with symbol + label (color + shape + text for accessibility)
function F.drawBadgePill(imgui, dl, x, y, text, opts)
    opts = opts or {}
    local fs = opts.fontScale or 0.85
    local padX = opts.padX or 8
    local h = opts.height or math.floor(20 * fs + 0.5)
    local tw = F.measureText(imgui, text, fs)
    local w = opts.width or math.max(36, math.floor(tw + padX * 2 + 0.5))
    local rad = h * 0.5
    local fill = opts.fill or F.u32.abyss_solid
    local border = opts.border or F.u32.border_strong
    local txtCol = opts.textCol or F.u32.text_primary

    if dl then
        dl:AddRectFilled({ x, y }, { x + w, y + h }, fill, rad)
        dl:AddRect({ x, y }, { x + w, y + h }, border, rad, 0, 1.1)
    end
    F.drawShadowText(imgui, dl, x + w * 0.5, y + (h - 13 * fs) * 0.5, text, txtCol, fs, 'c', opts.alpha)
    return w, h
end

-- Connection pathway between parent and child talent nodes
-- stateKey: 'active' (Soul Gold) | 'available' (Aether Cyan) | 'locked' (subtle slate)
function F.drawConnectionPath(dl, x1, y1, x2, y2, stateKey, opts)
    if not dl then return end
    opts = opts or {}
    local col, glowCol, thick
    if stateKey == 'active' then
        col     = F.u32.soul_gold
        glowCol = F.abgr(F.rgba.soul_gold, 0.24)
        thick   = opts.thickness or 2.4
    elseif stateKey == 'available' then
        col     = F.u32.aether_cyan
        glowCol = F.abgr(F.rgba.aether_cyan, 0.20)
        thick   = opts.thickness or 1.9
    else
        col     = F.u32.border_strong
        glowCol = nil
        thick   = opts.thickness or 1.3
    end

    local mx = (x1 + x2) * 0.5
    local my = (y1 + y2) * 0.5
    local stepped = opts.stepped ~= false and math.abs(x1 - x2) > 6 and math.abs(y1 - y2) > 6

    local function stroke(c, t)
        if stepped then
            dl:AddLine({ x1, y1 }, { x1, my }, c, t)
            dl:AddLine({ x1, my }, { x2, my }, c, t)
            dl:AddLine({ x2, my }, { x2, y2 }, c, t)
        else
            dl:AddLine({ x1, y1 }, { x2, y2 }, c, t)
        end
    end

    if glowCol then
        stroke(glowCol, thick + 3.2)
    end
    stroke(col, thick)

    -- Midpoint crystal node marker
    if dl.AddQuadFilled then
        local d = stateKey == 'active' and 4.0 or 3.0
        dl:AddQuadFilled({ mx, my - d }, { mx + d, my }, { mx, my + d }, { mx - d, my }, F.u32.abyss_solid)
        if dl.AddQuad then
            dl:AddQuad({ mx, my - d }, { mx + d, my }, { mx, my + d }, { mx - d, my }, col, 1.3)
        end
    end
end

-- Segmented / smooth resource gauge bar shared between Soul HUD and WS Talents
function F.drawSegmentedGauge(imgui, dl, x, y, w, h, cur, maxVal, opts)
    if not dl then return end
    opts = opts or {}
    local mx = math.max(0.0001, tonumber(maxVal) or 1)
    local ratio = clamp((tonumber(cur) or 0) / mx, 0, 1)
    local alpha = opts.alpha or 1.0
    local r = opts.rounding or 4
    local fillRgba = opts.warn and F.rgba.danger or (opts.fill or F.rgba.soul_gold)
    local borderU32 = opts.warn and F.abgr(F.rgba.danger, alpha) or (opts.border or F.abgr(F.rgba.border_strong, alpha))

    dl:AddRectFilled({ x, y }, { x + w, y + h }, F.abgr(F.rgba.abyss_solid, 0.94 * alpha), r)

    local pad = 1.5
    local innerW = math.max(0, w - pad * 2)
    local fillW = innerW * ratio
    if fillW > 1.0 then
        local x0, y0 = x + pad, y + pad
        local x1, y1 = x0 + fillW, y + h - pad
        local midY = (y0 + y1) * 0.5
        local topC = F.abgr(F.mix(fillRgba, F.rgba.white, 0.30), alpha)
        local midC = F.abgr(fillRgba, alpha)
        local botC = F.abgr(F.mix(fillRgba, F.rgba.black, 0.35), alpha)
        F.drawGradRect(dl, x0, y0, x1, midY, topC, midC)
        F.drawGradRect(dl, x0, midY, x1, y1, midC, botC)
        -- Bright leading edge tick
        dl:AddRectFilled({ math.max(x0, x1 - 1.5), y0 }, { x1, y1 }, F.abgr(F.rgba.white, 0.65 * alpha))
    end

    -- Optional notch dividers
    local notches = tonumber(opts.notches) or 0
    if notches > 1 then
        for i = 1, notches - 1 do
            local nx = math.floor(x + pad + innerW * (i / notches) + 0.5)
            dl:AddRectFilled({ nx, y + pad }, { nx + 1.2, y + h - pad }, F.abgr(F.rgba.abyss_solid, 0.85 * alpha))
        end
    end

    dl:AddRect({ x, y }, { x + w, y + h }, borderU32, r, 0, 1.1)

    if opts.label or opts.valueText then
        local fs = opts.fontScale or 0.80
        local ty = y + (h - 13 * fs) * 0.5
        local txtCol = opts.warn and F.abgr(F.mix(F.rgba.danger, F.rgba.white, 0.35), alpha)
            or F.abgr(F.rgba.text_primary, alpha)
        if opts.label and opts.label ~= '' then
            local maxLW = opts.valueText and (w * 0.58) or (w - 10)
            local lStr = F.fitText(imgui, opts.label, maxLW, fs)
            F.drawShadowText(imgui, dl, x + 6, ty, lStr, txtCol, fs, 'l', alpha)
        end
        if opts.valueText and opts.valueText ~= '' then
            F.drawShadowText(imgui, dl, x + w - 6, ty, opts.valueText, txtCol, fs, 'r', alpha)
        end
    end
end

-- Faceted diamond pip row (stacks, charges, talent ranks)
function F.drawPipRow(dl, x, y, cur, maxPips, opts)
    if not dl or not maxPips or maxPips <= 0 then return 0 end
    opts = opts or {}
    local size   = opts.size or 12
    local pitch  = opts.pitch or (size + 5)
    local litCol = opts.lit or F.rgba.soul_gold
    local alpha  = opts.alpha or 1.0
    local glow   = opts.glow == true
    local pulse  = opts.pulse or 0.5

    local half = size * 0.5
    for i = 1, maxPips do
        local cx = x + (i - 1) * pitch + half
        local cy = y + half
        local isLit = i <= (cur or 0)

        if isLit and glow and dl.AddCircleFilled then
            dl:AddCircleFilled({ cx, cy }, half + 2.5 + pulse * 1.5,
                F.abgr(litCol, (0.16 + 0.14 * pulse) * alpha), 16)
        end
        if dl.AddQuadFilled then
            local fill = isLit and F.abgr(litCol, alpha) or F.abgr(F.rgba.abyss_solid, 0.90 * alpha)
            local rim  = isLit and F.abgr(F.mix(litCol, F.rgba.white, 0.35), alpha) or F.abgr(F.rgba.border_strong, alpha)
            dl:AddQuadFilled({ cx, cy - half }, { cx + half, cy }, { cx, cy + half }, { cx - half, cy }, fill)
            if dl.AddQuad then
                dl:AddQuad({ cx, cy - half }, { cx + half, cy }, { cx, cy + half }, { cx - half, cy }, rim, isLit and 1.3 or 1.0)
            end
        end
    end
    return maxPips * pitch
end

-- Styled interactive button using InvisibleButton + DrawList
-- variant: 'gold' | 'cyan' | 'violet' | 'danger' | 'neutral'
function F.drawActionButton(imgui, dl, id, x, y, w, h, label, variant, opts)
    opts = opts or {}
    local disabled = opts.disabled == true
    local fs = opts.fontScale or 0.92
    local clicked = false
    local hovered = false

    if imgui and imgui.SetCursorScreenPos and imgui.InvisibleButton then
        imgui.SetCursorScreenPos({ x, y })
        if imgui.InvisibleButton(id, { w, h }) and not disabled then
            clicked = true
        end
        hovered = (not disabled) and (imgui.IsItemHovered and imgui.IsItemHovered() or false)
    end

    local fill, border, textCol
    if disabled then
        fill    = F.abgr(F.rgba.abyss, 0.85)
        border  = F.u32.border_subtle
        textCol = F.u32.text_disabled
    elseif variant == 'gold' then
        fill    = F.abgr(hovered and F.hex('#3C2F18', 0.98) or F.hex('#2A2112', 0.96))
        border  = hovered and F.u32.soul_gold_bright or F.u32.soul_gold
        textCol = F.u32.soul_gold_bright
    elseif variant == 'cyan' then
        fill    = F.abgr(hovered and F.hex('#143949', 0.98) or F.hex('#102938', 0.96))
        border  = F.u32.aether_cyan
        textCol = hovered and F.u32.white or F.u32.aether_cyan
    elseif variant == 'violet' then
        fill    = F.abgr(hovered and F.hex('#2F234A', 0.98) or F.hex('#211938', 0.96))
        border  = hovered and F.u32.crystal_violet_bright or F.u32.crystal_violet
        textCol = hovered and F.u32.white or F.u32.crystal_violet_bright
    elseif variant == 'danger' then
        fill    = F.abgr(hovered and F.hex('#521B1E', 0.98) or F.hex('#361417', 0.96))
        border  = F.u32.danger
        textCol = F.u32.white
    else
        fill    = hovered and F.u32.midnight_selected or F.u32.midnight_alt
        border  = hovered and F.u32.soul_gold or F.u32.border_strong
        textCol = hovered and F.u32.soul_gold_bright or F.u32.text_primary
    end

    if dl then
        local r = opts.rounding or 4
        dl:AddRectFilled({ x, y }, { x + w, y + h }, fill, r)
        dl:AddRect({ x, y }, { x + w, y + h }, border, r, 0, hovered and 1.5 or 1.1)
        if not disabled and hovered and dl.AddLine then
            dl:AddLine({ x + r, y + 1 }, { x + w - r, y + 1 }, F.abgr(F.rgba.white, 0.22), 1.0)
        end
    end

    local fit = F.fitText(imgui, label, w - 12, fs)
    F.drawShadowText(imgui, dl, x + w * 0.5, y + (h - 14 * fs) * 0.5, fit, textCol, fs, 'c')
    return clicked, hovered
end

-- Ornate beveled-hex RPG pill (used for active Core navigation tab & Gold CTA button)
function F.drawBeveledPill(dl, x, y, w, h, opts)
    if not dl then return end
    opts = opts or {}
    local bevel   = math.min(opts.bevel or math.floor(h * 0.34), math.floor(w * 0.22))
    local midY    = y + h * 0.5
    local fillTop = opts.fillTop or F.u32.midnight_selected
    local fillBot = opts.fillBot or F.u32.midnight_deep
    local border  = opts.border or F.u32.aether_cyan
    local glow    = opts.glow
    local thick   = opts.thickness or 1.6

    -- Soft outer glow halo
    if glow and dl.AddRectFilled then
        dl:AddRectFilled({ x + bevel * 0.4, y - 2 }, { x + w - bevel * 0.4, y + h + 2 }, glow, 6)
    end

    -- Fill body + beveled left/right end-caps
    F.drawGradRect(dl, x + bevel, y, x + w - bevel, y + h, fillTop, fillBot)
    if dl.AddTriangleFilled and bevel > 0 then
        dl:AddTriangleFilled({ x, midY }, { x + bevel, y }, { x + bevel, y + h }, fillBot)
        dl:AddTriangleFilled({ x + w, midY }, { x + w - bevel, y }, { x + w - bevel, y + h }, fillBot)
    end

    -- Crisp beveled perimeter outline
    if dl.AddLine then
        dl:AddLine({ x + bevel, y }, { x + w - bevel, y }, border, thick)
        dl:AddLine({ x + w - bevel, y }, { x + w, midY }, border, thick)
        dl:AddLine({ x + w, midY }, { x + w - bevel, y + h }, border, thick)
        dl:AddLine({ x + w - bevel, y + h }, { x + bevel, y + h }, border, thick)
        dl:AddLine({ x + bevel, y + h }, { x, midY }, border, thick)
        dl:AddLine({ x, midY }, { x + bevel, y }, border, thick)
        -- Luminous top & bottom highlight lines
        if opts.highlight then
            dl:AddLine({ x + bevel + 4, y + 1 }, { x + w - bevel - 4, y + 1 }, opts.highlight, 1.3)
            dl:AddLine({ x + bevel + 4, y + h - 1 }, { x + w - bevel - 4, y + h - 1 }, opts.highlight, 1.3)
        end
    end
end

-- Rotated 45-degree diamond Mastery Slot socket (lit = active WS, unlit = open/locked slot)
function F.drawDiamondSocket(dl, cx, cy, r, opts)
    if not dl then return end
    opts = opts or {}
    local lit     = opts.lit == true
    local active  = opts.active == true
    local fillCol = opts.fill or (lit and F.abgr(F.rgba.crystal_violet_wash, 0.92) or F.u32.abyss_solid)
    local rimCol  = opts.rim or (active and F.u32.soul_gold_bright or (lit and F.u32.soul_gold or F.u32.border_strong))
    local thick   = active and 2.0 or (lit and 1.5 or 1.1)

    if lit and dl.AddCircleFilled then
        dl:AddCircleFilled({ cx, cy }, r + 3, F.abgr(opts.glowRgba or F.rgba.soul_gold, 0.16), 16)
    end
    if dl.AddQuadFilled then
        dl:AddQuadFilled({ cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy }, fillCol)
    end
    if lit and opts.texId and dl.AddImage then
        local ir = r * 0.56
        dl:AddImage(opts.texId, { cx - ir, cy - ir }, { cx + ir, cy + ir })
    elseif lit and dl.AddQuadFilled then
        local ir = r * 0.44
        dl:AddQuadFilled({ cx, cy - ir }, { cx + ir, cy }, { cx, cy + ir }, { cx - ir, cy },
            opts.coreU32 or F.u32.soul_gold_bright)
    elseif dl.AddRect then
        -- Minimal lock silhouette inside open/locked diamond
        local lw, lh = r * 0.34, r * 0.30
        dl:AddRect({ cx - lw, cy - lh * 0.2 }, { cx + lw, cy + lh }, F.u32.text_muted, 1, 0, 1.1)
        if dl.AddCircle then
            dl:AddCircle({ cx, cy - lh * 0.35 }, lw * 0.65, F.u32.text_muted, 10, 1.0)
        end
    end
    if dl.AddQuad then
        dl:AddQuad({ cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy }, rimCol, thick)
    end
end

-- Glowing 8-point crystal star (used for Talent Points & Point Cost)
function F.drawCrystalStar(dl, cx, cy, r, colU32, coreU32)
    if not dl then return end
    local col  = colU32 or F.u32.crystal_violet_bright
    local core = coreU32 or F.u32.white
    if dl.AddCircleFilled then
        dl:AddCircleFilled({ cx, cy }, r * 1.15, F.abgr(F.rgba.crystal_violet, 0.26), 16)
    end
    if dl.AddQuadFilled then
        local w = r * 0.26
        dl:AddQuadFilled({ cx, cy - r }, { cx + w, cy }, { cx, cy + r }, { cx - w, cy }, col)
        dl:AddQuadFilled({ cx - r, cy }, { cx, cy - w }, { cx + r, cy }, { cx, cy + w }, col)
        local d = r * 0.58
        local dw = r * 0.16
        dl:AddQuadFilled({ cx - d, cy - d }, { cx + dw, cy - dw }, { cx + d, cy + d }, { cx - dw, cy + dw }, col)
        dl:AddQuadFilled({ cx + d, cy - d }, { cx + dw, cy + dw }, { cx - d, cy + d }, { cx - dw, cy - dw }, col)
    end
    if dl.AddCircleFilled then
        dl:AddCircleFilled({ cx, cy }, r * 0.24, core, 10)
    end
end

-- Atmospheric Soulforge Astral Ring backdrop behind the Talent Tree
function F.drawAstralRing(dl, cx, cy, r, opts)
    if not dl or r < 40 then return end
    opts = opts or {}
    local alpha = opts.alpha or 1.0
    if dl.AddCircleFilled then
        dl:AddCircleFilled({ cx, cy }, r * 0.94, F.abgr(F.rgba.crystal_violet, 0.08 * alpha), 48)
        dl:AddCircleFilled({ cx, cy }, r * 0.62, F.abgr(F.rgba.aether_cyan, 0.06 * alpha), 40)
        dl:AddCircleFilled({ cx, cy }, r * 0.36, F.abgr(F.rgba.crystal_violet_bright, 0.10 * alpha), 32)
    end
    if dl.AddCircle then
        dl:AddCircle({ cx, cy }, r, F.abgr(F.rgba.soul_gold_dim, 0.42 * alpha), 56, 2.0)
        dl:AddCircle({ cx, cy }, r * 0.88, F.abgr(F.rgba.soul_gold, 0.26 * alpha), 48, 1.2)
        dl:AddCircle({ cx, cy }, r * 0.66, F.abgr(F.rgba.crystal_violet_bright, 0.30 * alpha), 40, 1.1)
    end
    if dl.AddLine then
        -- Cardinal astral rays
        for _, dir in ipairs({ { 0, -1 }, { 1, 0 }, { 0, 1 }, { -1, 0 } }) do
            dl:AddLine(
                { cx + dir[1] * r * 0.88, cy + dir[2] * r * 0.88 },
                { cx + dir[1] * r * 1.03, cy + dir[2] * r * 1.03 },
                F.abgr(F.rgba.soul_gold, 0.55 * alpha), 1.6
            )
        end
    end
end

-- Circular gilded icon button (? / Settings / X in top-right Core header)
function F.drawCircleIconBtn(imgui, dl, id, cx, cy, r, symbol, opts)
    opts = opts or {}
    local clicked = false
    local hovered = false
    if imgui and imgui.SetCursorScreenPos and imgui.InvisibleButton then
        imgui.SetCursorScreenPos({ cx - r, cy - r })
        if imgui.InvisibleButton(id, { r * 2, r * 2 }) then
            clicked = true
        end
        hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false
    end
    local active = opts.active == true
    local fill   = active and F.u32.midnight_selected or (hovered and F.u32.midnight_alt or F.u32.abyss_solid)
    local rim    = active and F.u32.aether_cyan or (hovered and F.u32.soul_gold_bright or F.u32.soul_gold_dim)
    if dl then
        if dl.AddCircleFilled then dl:AddCircleFilled({ cx, cy }, r, fill, 24) end
        if dl.AddCircle then dl:AddCircle({ cx, cy }, r, rim, 24, (active or hovered) and 1.6 or 1.2) end
    end
    local fs = opts.fontScale or 0.86
    F.drawShadowText(imgui, dl, cx, cy - 7 * fs, symbol,
        (active or hovered) and F.u32.soul_gold_bright or F.u32.text_primary, fs, 'c')
    return clicked, hovered
end

-- Crisp keycap / gamepad badge + label pair for the bottom controls legend bar
function F.drawPromptPill(imgui, dl, x, y, keyLabel, descLabel, opts)
    opts = opts or {}
    local fs = opts.fontScale or 0.74
    local padX = math.floor(6 * fs + 0.5)
    local h = math.floor(20 * fs + 0.5)
    local kw = F.measureText(imgui, keyLabel, fs)
    local pillW = math.max(math.floor(20 * fs), math.floor(kw + padX * 2 + 0.5))
    local dw = F.measureText(imgui, descLabel, fs)

    if dl then
        dl:AddRectFilled({ x, y }, { x + pillW, y + h }, F.u32.abyss_solid, 4)
        dl:AddRect({ x, y }, { x + pillW, y + h }, opts.keyBorder or F.u32.soul_gold_dim, 4, 0, 1.1)
    end
    F.drawShadowText(imgui, dl, x + pillW * 0.5, y + (h - 13 * fs) * 0.5, keyLabel,
        opts.keyCol or F.u32.soul_gold_bright, fs, 'c')
    F.drawShadowText(imgui, dl, x + pillW + math.floor(6 * fs), y + (h - 13 * fs) * 0.5, descLabel,
        opts.descCol or F.u32.text_secondary, fs, 'l')

    return pillW + math.floor(6 * fs) + dw + math.floor(14 * fs)
end

-- Unified SoulspireXI tooltip card (Abyss/Midnight + Gold/Cyan/Violet accents)
function F.drawTooltipCard(imgui, title, lines, opts)
    if not imgui or not imgui.BeginTooltip then return end
    opts = opts or {}
    local accentRgba = opts.accent or F.rgba.soul_gold
    local wrapW = opts.wrapWidth or 340

    local pushed = 0
    local function pc(idx, v)
        if idx ~= nil and imgui.PushStyleColor then
            imgui.PushStyleColor(idx, v)
            pushed = pushed + 1
        end
    end
    pc(ImGuiCol_PopupBg, F.rgba.abyss)
    pc(ImGuiCol_Border, accentRgba)
    pc(ImGuiCol_Text, F.rgba.text_primary)

    imgui.BeginTooltip()
    local wrapped = false
    if imgui.PushTextWrapPos then
        wrapped = pcall(imgui.PushTextWrapPos, wrapW)
    end
    F.textUnformatted(imgui, title, accentRgba)
    if opts.subtitle and opts.subtitle ~= '' then
        F.textUnformatted(imgui, opts.subtitle, F.rgba.crystal_violet_bright)
    end
    if opts.weapon and opts.weapon ~= '' then
        F.textUnformatted(imgui, 'Weapon: ' .. opts.weapon, F.rgba.soul_gold)
    end
    local needSep = (opts.subtitle ~= nil or opts.weapon ~= nil)
    for _, ln in ipairs(lines or {}) do
        if ln.sep then
            if imgui.Separator then imgui.Separator() end
            needSep = false
        else
            if needSep and imgui.Separator then imgui.Separator() end
            needSep = false
            if ln.head then
                F.textUnformatted(imgui, ln.head, accentRgba)
            end
            if ln.text and ln.text ~= '' then
                F.textUnformatted(imgui, ln.text, ln.rgba or F.rgba.text_primary)
            end
        end
    end
    if wrapped and imgui.PopTextWrapPos then
        imgui.PopTextWrapPos()
    end
    imgui.EndTooltip()
    if pushed > 0 and imgui.PopStyleColor then
        imgui.PopStyleColor(pushed)
    end
end

-- Helper for sibling Ashita v4 addons to load this shared foundations module
-- from ../soulspire_core/core/foundations.lua without duplicating code.
function F.resolveSiblingCore(addonPath)
    if type(addonPath) ~= 'string' or addonPath == '' then return nil end
    local root = addonPath:gsub('[/\\]+$', ''):gsub('[/\\][^/\\]+$', '')
    local cand = root .. '/soulspire_core/core/foundations.lua'
    local loader = loadfile(cand)
    if loader then
        local ok, mod = pcall(loader)
        if ok and type(mod) == 'table' then return mod end
    end
    return nil
end

return F
