-- SoulspireXI Core: official color palette and layout tokens.
-- Matches SoulspireLauncher/App.xaml and soulspire_talents/premium_ui.lua,
-- with native-styled FFXI menu frame accents for the docked Main Menu entry.

local bit = require('bit')

local Theme = {}

-- Float4 RGBA palette (ImGui style/text colors)
Theme.rgba = {
    bg_primary      = { 0.043, 0.059, 0.090, 0.97 }, -- #0B0F17
    bg_card         = { 0.075, 0.102, 0.149, 0.96 }, -- #131A26
    bg_card_alt     = { 0.098, 0.133, 0.200, 0.96 }, -- #192233
    bg_selected     = { 0.149, 0.184, 0.255, 0.98 }, -- warm navy selection
    border_subtle   = { 0.149, 0.196, 0.282, 1.00 }, -- #263248
    border_active   = { 0.898, 0.725, 0.298, 1.00 }, -- #E5B94C
    text_primary    = { 0.945, 0.961, 0.976, 1.00 }, -- #F1F5F9
    text_secondary  = { 0.580, 0.639, 0.722, 1.00 }, -- #94A3B8
    text_muted      = { 0.420, 0.475, 0.560, 1.00 },
    gold            = { 0.898, 0.725, 0.298, 1.00 }, -- #E5B94C
    gold_hover      = { 0.953, 0.804, 0.412, 1.00 }, -- #F3CD69
    cyan            = { 0.176, 0.831, 0.749, 1.00 }, -- #2DD4BF
    shadow          = { 0.000, 0.000, 0.000, 0.55 },
    -- Native FFXI main-menu-inspired surface for the docked fallback entry
    ffxi_navy       = { 0.063, 0.106, 0.212, 0.95 }, -- matches crystalsocket FFXI navy
    ffxi_selection  = { 0.133, 0.224, 0.345, 0.97 },
    ffxi_silver     = { 0.537, 0.592, 0.678, 1.00 },
    ffxi_edge       = { 0.161, 0.224, 0.322, 1.00 },
}

local function clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Convert RGBA float4 {r, g, b, a} to packed ABGR uint32 for ImGui DrawList.
function Theme.abgr(c)
    local r = math.floor(clamp01(c[1] or 0) * 255 + 0.5)
    local g = math.floor(clamp01(c[2] or 0) * 255 + 0.5)
    local b = math.floor(clamp01(c[3] or 0) * 255 + 0.5)
    local a = math.floor(clamp01(c[4] or 1) * 255 + 0.5)
    return bit.bor(bit.lshift(a, 24), bit.lshift(b, 16), bit.lshift(g, 8), r)
end

Theme.u32 = {}
for k, v in pairs(Theme.rgba) do
    Theme.u32[k] = Theme.abgr(v)
end

Theme.layout = {
    hub_width        = 660,
    hub_height       = 430,
    sidebar_width    = 216,
    header_height    = 58,
    footer_height    = 32,
    row_height       = 40,
    dock_height      = 32,
    dock_min_width   = 156,
    dock_gap         = 4,
    corner_radius    = 6,
}

return Theme
