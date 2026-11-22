-- SoulspireXI Core: ImGui presentation layer.
-- Renders:
--   1. Native-styled docked "Soulspire" entry anchored to the FFXI Main Menu
--      (explicitly identified as a native-styled fallback, not binary FFXiMain.dll insertion).
--   2. Minimal SoulspireXI Core Hub window with the 7 modular placeholder sections.

local bit = require('bit')
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

local function text_unformatted(imgui, text, rgba)
    if rgba and imgui.PushStyleColor then
        imgui.PushStyleColor(ImGuiCol_Text or 0, rgba)
    end
    local s = tostring(text or '')
    if imgui.TextUnformatted then
        imgui.TextUnformatted(s)
    elseif imgui.Text then
        imgui.Text((s:gsub('%%', '%%%%')))
    end
    if rgba and imgui.PopStyleColor then
        imgui.PopStyleColor()
    end
end

local function draw_crest(dl, x, y, size, tex_id)
    if tex_id and dl and dl.AddImage then
        dl:AddImage(tex_id, { x, y }, { x + size, y + size })
        return
    end
    if not dl or not dl.AddQuadFilled then return end
    local cx, cy = x + size * 0.5, y + size * 0.5
    local r = size * 0.42
    dl:AddQuadFilled(
        { cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy },
        Theme.u32.gold
    )
    if dl.AddQuad then
        dl:AddQuad(
            { cx, cy - r }, { cx + r, cy }, { cx, cy + r }, { cx - r, cy },
            Theme.u32.cyan, 1.2
        )
    end
end

function UI.new(imgui, registry, focus, assets)
    return setmetatable({
        imgui = imgui,
        registry = registry,
        focus = focus,
        assets = assets,
        crest_tex = nil,
        last_dock = { visible = false, hovered = false, clicks = 0 },
    }, UI)
end

function UI:ensure_assets()
    if self.crest_tex == nil and self.assets then
        self.crest_tex = self.assets:load_texture('soulspire_crest') or false
    end
    return self.crest_tex ~= false and self.crest_tex or nil
end

-- Draw the native-styled docked "Soulspire" entry anchored below the FFXI Main Menu.
function UI:draw_main_menu_dock(native)
    self.last_dock.visible = false
    self.last_dock.hovered = false
    if not native or not native.dock or self.focus.hub_open then return end

    local imgui = self.imgui
    local L = Theme.layout
    local w = math.max(L.dock_min_width, math.floor(native.dock.w or L.dock_min_width))
    local h = L.dock_height
    local x = math.floor(native.dock.x or 0)
    local y = math.floor(native.dock.y or 0)

    local win_flags = flag_or(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoMove,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoSavedSettings,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground
    )

    if imgui.SetNextWindowPos then imgui.SetNextWindowPos({ x, y }, ImGuiCond_Always or 1) end
    if imgui.SetNextWindowSize then imgui.SetNextWindowSize({ w, h }, ImGuiCond_Always or 1) end
    if imgui.PushStyleVar then imgui.PushStyleVar(ImGuiStyleVar_WindowPadding or 2, { 0, 0 }) end

    local opened = imgui.Begin('##soulspire_main_menu_dock', true, win_flags)
    if opened then
        self.last_dock.visible = true
        local dl = imgui.GetWindowDrawList and imgui.GetWindowDrawList() or nil

        imgui.SetCursorScreenPos({ x, y })
        if imgui.InvisibleButton('##soulspire_dock_btn', { w, h }) then
            self.last_dock.clicks = self.last_dock.clicks + 1
            self.focus:open_hub(self.focus.selected_index, true)
        end
        local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false
        self.last_dock.hovered = hovered
        local focused = self.focus.dock_focused

        if dl then
            local bg = (focused or hovered) and Theme.u32.ffxi_selection or Theme.u32.ffxi_navy
            local border = focused and Theme.u32.gold or (hovered and Theme.u32.gold_hover or Theme.u32.ffxi_silver)
            dl:AddRectFilled({ x + 2, y + 2 }, { x + w + 2, y + h + 2 }, Theme.u32.shadow, 4)
            dl:AddRectFilled({ x, y }, { x + w, y + h }, bg, 4)
            dl:AddRect({ x, y }, { x + w, y + h }, border, 4, 0, focused and 2.0 or 1.2)
            if focused then
                dl:AddRectFilled({ x + 2, y + 4 }, { x + 5, y + h - 4 }, Theme.u32.gold, 1)
            end
            draw_crest(dl, x + 10, y + 6, 20, self:ensure_assets())
        end

        imgui.SetCursorScreenPos({ x + 36, y + 8 })
        text_unformatted(imgui, focused and '> Soulspire' or 'Soulspire',
            (focused or hovered) and Theme.rgba.gold_hover or Theme.rgba.text_primary)

        local hint = focused and '[Enter]' or '[Tab]'
        if w >= 150 then
            imgui.SetCursorScreenPos({ x + w - 52, y + 8 })
            text_unformatted(imgui, hint, focused and Theme.rgba.cyan or Theme.rgba.text_secondary)
        end
    end
    imgui.End()
    if imgui.PopStyleVar then imgui.PopStyleVar() end
end

-- Draw the minimal SoulspireXI Core Hub window.
function UI:draw_hub(native, bridge_available)
    if not self.focus.hub_open then return end

    local imgui = self.imgui
    local L = Theme.layout
    local w, h = L.hub_width, L.hub_height

    local win_flags = flag_or(
        ImGuiWindowFlags_NoTitleBar,
        ImGuiWindowFlags_NoResize,
        ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_NoScrollWithMouse,
        ImGuiWindowFlags_NoCollapse,
        ImGuiWindowFlags_NoNav,
        ImGuiWindowFlags_NoBackground
    )

    if imgui.SetNextWindowSize then imgui.SetNextWindowSize({ w, h }, ImGuiCond_Always or 1) end
    if imgui.SetNextWindowPos then
        local io_obj = imgui.GetIO and imgui.GetIO() or nil
        local cx = io_obj and io_obj.DisplaySize and (io_obj.DisplaySize.x * 0.5) or 640
        local cy = io_obj and io_obj.DisplaySize and (io_obj.DisplaySize.y * 0.5) or 360
        imgui.SetNextWindowPos({ cx - w * 0.5, cy - h * 0.5 }, ImGuiCond_FirstUseEver or 4)
    end
    if imgui.PushStyleVar then imgui.PushStyleVar(ImGuiStyleVar_WindowPadding or 2, { 0, 0 }) end

    local opened = imgui.Begin('##soulspire_core_hub', true, win_flags)
    if opened then
        local wx, wy = 0, 0
        if imgui.GetWindowPos then
            local pos = { imgui.GetWindowPos() }
            if type(pos[1]) == 'table' then
                wx, wy = pos[1][1] or pos[1].x or 0, pos[1][2] or pos[1].y or 0
            else
                wx, wy = pos[1] or 0, pos[2] or 0
            end
        end

        local dl = imgui.GetWindowDrawList and imgui.GetWindowDrawList() or nil
        if dl then
            -- Outer shadow + primary frame
            dl:AddRectFilled({ wx + 4, wy + 5 }, { wx + w + 4, wy + h + 5 }, Theme.u32.shadow, L.corner_radius)
            dl:AddRectFilled({ wx, wy }, { wx + w, wy + h }, Theme.u32.bg_primary, L.corner_radius)
            dl:AddRect({ wx, wy }, { wx + w, wy + h }, Theme.u32.gold, L.corner_radius, 0, 1.4)

            -- Header surface
            dl:AddRectFilled({ wx + 1, wy + 1 }, { wx + w - 1, wy + L.header_height }, Theme.u32.bg_card, L.corner_radius)
            dl:AddLine({ wx + 1, wy + L.header_height }, { wx + w - 1, wy + L.header_height }, Theme.u32.border_subtle, 1.0)

            -- Sidebar surface
            local body_top = wy + L.header_height + 1
            local body_bot = wy + h - L.footer_height - 1
            dl:AddRectFilled({ wx + 1, body_top }, { wx + L.sidebar_width, body_bot }, Theme.u32.bg_card, 0)
            dl:AddLine({ wx + L.sidebar_width, body_top }, { wx + L.sidebar_width, body_bot }, Theme.u32.border_subtle, 1.0)

            -- Footer surface
            dl:AddRectFilled({ wx + 1, body_bot + 1 }, { wx + w - 1, wy + h - 1 }, Theme.u32.bg_card, L.corner_radius)
            dl:AddLine({ wx + 1, body_bot }, { wx + w - 1, body_bot }, Theme.u32.border_subtle, 1.0)

            draw_crest(dl, wx + 16, wy + 13, 32, self:ensure_assets())
        end

        -- Header text & Close button
        imgui.SetCursorScreenPos({ wx + 58, wy + 11 })
        text_unformatted(imgui, 'SOULSPIREXI CORE', Theme.rgba.gold)
        imgui.SetCursorScreenPos({ wx + 58, wy + 31 })
        text_unformatted(imgui, 'Phase 1A  |  Modular UI Shell (Native-Styled Main Menu Fallback)', Theme.rgba.text_secondary)

        local close_x, close_y, close_w, close_h = wx + w - 84, wy + 15, 68, 26
        imgui.SetCursorScreenPos({ close_x, close_y })
        if imgui.InvisibleButton('##soulspire_hub_close', { close_w, close_h }) then
            self.focus:close_hub(native)
        end
        local close_hover = imgui.IsItemHovered and imgui.IsItemHovered() or false
        if dl then
            dl:AddRectFilled({ close_x, close_y }, { close_x + close_w, close_y + close_h },
                close_hover and Theme.u32.bg_selected or Theme.u32.bg_card_alt, 4)
            dl:AddRect({ close_x, close_y }, { close_x + close_w, close_y + close_h },
                close_hover and Theme.u32.gold or Theme.u32.border_subtle, 4, 0, 1.0)
        end
        imgui.SetCursorScreenPos({ close_x + 14, close_y + 5 })
        text_unformatted(imgui, 'Close', close_hover and Theme.rgba.gold_hover or Theme.rgba.text_primary)

        -- Left sidebar: 7 registered modular sections
        local sections = self.registry:sections()
        local row_y = wy + L.header_height + 10
        local row_w = L.sidebar_width - 16
        local row_h = L.row_height

        for idx, sec in ipairs(sections) do
            local rx = wx + 8
            local ry = row_y + (idx - 1) * (row_h + 4)
            local is_selected = (idx == self.focus.selected_index)

            imgui.SetCursorScreenPos({ rx, ry })
            if imgui.InvisibleButton('##soulspire_nav_' .. sec.id, { row_w, row_h }) then
                self.focus:select_index(idx)
            end
            local hovered = imgui.IsItemHovered and imgui.IsItemHovered() or false

            if dl then
                local fill = is_selected and Theme.u32.bg_selected or (hovered and Theme.u32.bg_card_alt or Theme.u32.bg_primary)
                local border = is_selected and Theme.u32.gold or (hovered and Theme.u32.cyan or Theme.u32.border_subtle)
                dl:AddRectFilled({ rx, ry }, { rx + row_w, ry + row_h }, fill, 5)
                dl:AddRect({ rx, ry }, { rx + row_w, ry + row_h }, border, 5, 0, is_selected and 1.4 or 1.0)
                if is_selected then
                    dl:AddRectFilled({ rx + 2, ry + 5 }, { rx + 5, ry + row_h - 5 }, Theme.u32.gold, 1)
                end
            end

            imgui.SetCursorScreenPos({ rx + 12, ry + 11 })
            local label = (is_selected and '> ' or '  ') .. sec.label
            text_unformatted(imgui, label, is_selected and Theme.rgba.gold_hover or Theme.rgba.text_primary)
        end

        -- Right content panel: selected section detail
        local active = self.registry:get(self.focus.active_index) or sections[1]
        if active then
            local px = wx + L.sidebar_width + 20
            local py = wy + L.header_height + 18
            local pw = w - L.sidebar_width - 40
            local ph = h - L.header_height - L.footer_height - 36

            if dl then
                dl:AddRectFilled({ px, py }, { px + pw, py + ph }, Theme.u32.bg_card, 6)
                dl:AddRect({ px, py }, { px + pw, py + ph }, Theme.u32.border_subtle, 6, 0, 1.0)
                -- Placeholder badge pill
                local bx, by, bw, bh = px + pw - 116, py + 14, 100, 22
                dl:AddRectFilled({ bx, by }, { bx + bw, by + bh }, Theme.u32.bg_card_alt, 10)
                dl:AddRect({ bx, by }, { bx + bw, by + bh }, Theme.u32.cyan, 10, 0, 1.0)
            end

            imgui.SetCursorScreenPos({ px + 18, py + 16 })
            text_unformatted(imgui, active.label, Theme.rgba.gold)

            imgui.SetCursorScreenPos({ px + pw - 106, py + 17 })
            text_unformatted(imgui, active.badge or 'PLACEHOLDER', Theme.rgba.cyan)

            if dl then
                dl:AddLine({ px + 18, py + 46 }, { px + pw - 18, py + 46 }, Theme.u32.border_subtle, 1.0)
            end

            imgui.SetCursorScreenPos({ px + 18, py + 58 })
            if imgui.PushTextWrapPos then imgui.PushTextWrapPos(px + pw - 18) end
            text_unformatted(imgui, active.summary, Theme.rgba.text_primary)

            imgui.SetCursorScreenPos({ px + 18, py + 104 })
            text_unformatted(imgui, active.details, Theme.rgba.text_secondary)

            -- Module / integration metadata card
            local mx, my, mw, mh = px + 18, py + 186, pw - 36, 98
            if dl then
                dl:AddRectFilled({ mx, my }, { mx + mw, my + mh }, Theme.u32.bg_primary, 5)
                dl:AddRect({ mx, my }, { mx + mw, my + mh }, Theme.u32.border_subtle, 5, 0, 1.0)
            end

            imgui.SetCursorScreenPos({ mx + 12, my + 10 })
            text_unformatted(imgui, 'MODULE STATUS', Theme.rgba.cyan)

            imgui.SetCursorScreenPos({ mx + 12, my + 32 })
            text_unformatted(imgui, 'Section ID: ' .. active.id, Theme.rgba.text_primary)

            imgui.SetCursorScreenPos({ mx + 12, my + 52 })
            local companion = active.existing_addon and (active.existing_addon .. ' (active, untouched)') or 'None (new Core module slot)'
            text_unformatted(imgui, 'Companion Addon: ' .. companion, Theme.rgba.text_secondary)

            imgui.SetCursorScreenPos({ mx + 12, my + 72 })
            local mode_str = bridge_available
                and 'Integration: Native-Styled Main Menu Fallback (MenuManager read-only)'
                or 'Integration: Standalone Fallback (/soulspire)'
            text_unformatted(imgui, mode_str, Theme.rgba.text_secondary)

            if imgui.PopTextWrapPos then imgui.PopTextWrapPos() end
        end

        -- Footer controls legend
        imgui.SetCursorScreenPos({ wx + 16, wy + h - L.footer_height + 8 })
        text_unformatted(imgui,
            'Up/Down or D-Pad: Navigate   |   Enter/A: Select   |   Esc/B: Close   |   Tab/L1/R1 (on Main Menu): Focus Soulspire',
            Theme.rgba.text_secondary)
    end
    imgui.End()
    if imgui.PopStyleVar then imgui.PopStyleVar() end
end

function UI:draw(native, bridge_available)
    self:draw_main_menu_dock(native)
    self:draw_hub(native, bridge_available)
end

return UI
