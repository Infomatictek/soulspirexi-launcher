-- SoulspireXI Core: official color palette and layout tokens.
-- Backed by SoulspireXI Core UI Foundations (core/foundations.lua) so Core,
-- The Soulforge (WS Talents), and the Universal Soul HUD share one visual system.

local F = require('core.foundations')

local Theme = {}

Theme.foundations = F

-- Float4 RGBA palette (ImGui style/text colors), aligned to the official palette:
-- Abyss #0B1019 | Midnight #151928 | Soul Gold #E8BD70 | Aether Cyan #39CFE5 | Crystal Violet #8063BC
Theme.rgba = {
    bg_primary      = F.rgba.abyss,
    bg_card         = F.rgba.midnight,
    bg_card_alt     = F.rgba.midnight_alt,
    bg_selected     = F.rgba.midnight_selected,
    border_subtle   = F.rgba.border_subtle,
    border_active   = F.rgba.soul_gold,
    text_primary    = F.rgba.text_primary,
    text_secondary  = F.rgba.text_secondary,
    text_muted      = F.rgba.text_muted,
    gold            = F.rgba.soul_gold,
    gold_hover      = F.rgba.soul_gold_bright,
    cyan            = F.rgba.aether_cyan,
    violet          = F.rgba.crystal_violet,
    violet_bright   = F.rgba.crystal_violet_bright,
    shadow          = F.rgba.shadow,
    -- Native FFXI main-menu-inspired surface for the docked fallback entry
    ffxi_navy       = F.rgba.ffxi_navy,
    ffxi_selection  = F.rgba.ffxi_selection,
    ffxi_silver     = F.rgba.ffxi_silver,
    ffxi_edge       = F.rgba.ffxi_edge,
}

Theme.abgr = F.abgr

Theme.u32 = {}
for k, v in pairs(Theme.rgba) do
    Theme.u32[k] = F.abgr(v)
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
