-- SoulspireXI Core (VanaCore-Native): Authoritative Dear ImGui 1.92.3 Enum Constants
-- Matches VanaCore's compiled `third_party/imgui/imgui.h` directly with zero Ashita globals.

local C = {
    WindowFlags = {
        None                 = 0,
        NoTitleBar           = 1,       -- 1 << 0
        NoResize             = 2,       -- 1 << 1
        NoMove               = 4,       -- 1 << 2
        NoScrollbar          = 8,       -- 1 << 3
        NoScrollWithMouse    = 16,      -- 1 << 4
        NoCollapse           = 32,      -- 1 << 5
        AlwaysAutoResize     = 64,      -- 1 << 6
        NoBackground         = 128,     -- 1 << 7
        NoSavedSettings      = 256,     -- 1 << 8
        NoMouseInputs        = 512,     -- 1 << 9
        MenuBar              = 1024,    -- 1 << 10
        HorizontalScrollbar  = 2048,    -- 1 << 11
        NoFocusOnAppearing   = 4096,    -- 1 << 12
        NoBringToFrontOnFocus = 8192,   -- 1 << 13
        NoNavInputs          = 65536,   -- 1 << 16
        NoNavFocus           = 131072,  -- 1 << 17
        NoNav                = 196608,  -- NoNavInputs | NoNavFocus
        NoDecoration         = 43,      -- NoTitleBar | NoResize | NoScrollbar | NoCollapse
    },
    ChildFlags = {
        None    = 0,
        Borders = 1,
    },
    Cond = {
        Always       = 1,
        Once         = 2,
        FirstUseEver = 4,
        Appearing    = 8,
    },
    StyleVar = {
        Alpha              = 0,
        DisabledAlpha      = 1,
        WindowPadding      = 2,
        WindowRounding     = 3,
        WindowBorderSize   = 4,
        WindowMinSize      = 5,
        WindowTitleAlign   = 6,
        ChildRounding      = 7,
        ChildBorderSize    = 8,
        PopupRounding      = 9,
        PopupBorderSize    = 10,
        FramePadding       = 11,
        FrameRounding      = 12,
        FrameBorderSize    = 13,
        ItemSpacing        = 14,
        ItemInnerSpacing   = 15,
    },
    Col = {
        Text                = 0,
        TextDisabled        = 1,
        WindowBg            = 2,
        ChildBg             = 3,
        PopupBg             = 4,
        Border              = 5,
        BorderShadow        = 6,
        FrameBg             = 7,
        FrameBgHovered      = 8,
        FrameBgActive       = 9,
        TitleBg             = 10,
        TitleBgActive       = 11,
        TitleBgCollapsed    = 12,
        MenuBarBg           = 13,
        ScrollbarBg         = 14,
        ScrollbarGrab       = 15,
        ScrollbarGrabHovered = 16,
        ScrollbarGrabActive = 17,
        CheckMark           = 18,
        SliderGrab          = 19,
        SliderGrabActive    = 20,
        Button              = 21,
        ButtonHovered       = 22,
        ButtonActive        = 23,
        Header              = 24,
        HeaderHovered       = 25,
        HeaderActive        = 26,
    },
}

return C
