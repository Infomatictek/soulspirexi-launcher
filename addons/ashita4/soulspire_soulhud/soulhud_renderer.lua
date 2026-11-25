--[[
* SoulspireXI Universal Soul HUD — Settings Window
* Styled with SoulspireXI Core UI Foundations (Abyss #0B1019, Midnight #151928,
* Soul Gold #E8BD70, Aether Cyan #39CFE5, Crystal Violet #8063BC).
--]]

local M = {}

function M.renderConfig(imgui, soulDef, cfg, settingsMod, callbacks)
    if not imgui or not callbacks.isConfigOpen() then
        return
    end

    local pushed = 0
    local function pc(idx, v)
        if idx ~= nil then imgui.PushStyleColor(idx, v); pushed = pushed + 1 end
    end
    pc(ImGuiCol_WindowBg,       { 0.043, 0.063, 0.098, 0.97 }) -- Abyss #0B1019
    pc(ImGuiCol_ChildBg,        { 0.082, 0.098, 0.157, 0.96 }) -- Midnight #151928
    pc(ImGuiCol_Border,         { 0.910, 0.741, 0.439, 0.90 }) -- Soul Gold #E8BD70
    pc(ImGuiCol_TitleBg,        { 0.063, 0.078, 0.133, 1.00 })
    pc(ImGuiCol_TitleBgActive,  { 0.094, 0.118, 0.200, 1.00 })
    pc(ImGuiCol_FrameBg,        { 0.082, 0.098, 0.157, 1.00 })
    pc(ImGuiCol_FrameBgHovered, { 0.125, 0.157, 0.247, 1.00 })
    pc(ImGuiCol_CheckMark,      { 0.910, 0.741, 0.439, 1.00 })
    pc(ImGuiCol_SliderGrab,     { 0.224, 0.812, 0.898, 1.00 }) -- Aether Cyan #39CFE5
    pc(ImGuiCol_HeaderHovered,  { 0.224, 0.812, 0.898, 0.30 })
    pc(ImGuiCol_HeaderActive,   { 0.910, 0.741, 0.439, 0.38 })
    pc(ImGuiCol_Text,           { 0.945, 0.961, 0.976, 1.00 })

    imgui.SetNextWindowSize({ 340, 420 }, ImGuiCond_FirstUseEver or 4)
    local open = { true }
    if imgui.Begin('SoulspireXI — Universal Soul HUD Config', open, 0) then
        imgui.TextColored({ 0.910, 0.741, 0.439, 1.0 }, 'DISPLAY MODE & LAYOUT')
        imgui.Separator()

        local layouts = { 'minimal', 'standard', 'expanded' }
        local curLayout = (cfg.layout == 'compact') and 'standard' or (cfg.layout or 'standard')
        if imgui.BeginCombo('Display Mode', curLayout) then
            for _, l in ipairs(layouts) do
                if imgui.Selectable(l, curLayout == l) then
                    cfg.layout = l
                    settingsMod.save(cfg)
                end
            end
            imgui.EndCombo()
        end

        local modes = { 'auto', 'show', 'hide' }
        if imgui.BeginCombo('Visibility Mode', cfg.mode) then
            for _, m in ipairs(modes) do
                if imgui.Selectable(m, cfg.mode == m) then
                    cfg.mode = m
                    settingsMod.save(cfg)
                end
            end
            imgui.EndCombo()
        end

        local scaleArr = { cfg.scale }
        if imgui.SliderFloat('HUD Scale', scaleArr, 0.75, 2.0, '%.2f') then
            cfg.scale = scaleArr[1]
            settingsMod.save(cfg)
        end

        local opArr = { cfg.opacity }
        if imgui.SliderFloat('Opacity', opArr, 0.25, 1.0, '%.2f') then
            cfg.opacity = opArr[1]
            settingsMod.save(cfg)
        end

        if imgui.Checkbox('Lock Position', { cfg.locked }) then
            cfg.locked = not cfg.locked
            settingsMod.save(cfg)
        end
        if imgui.Checkbox('Auto-Hide in FFXI Menus / Cutscenes', { cfg.autoHideOnMenu ~= false }) then
            cfg.autoHideOnMenu = not (cfg.autoHideOnMenu ~= false)
            settingsMod.save(cfg)
        end
        if imgui.Checkbox('Show Shared Party Buffs', { cfg.showShared ~= false }) then
            cfg.showShared = not (cfg.showShared ~= false)
            settingsMod.save(cfg)
        end
        if imgui.Checkbox('Show Soul Identity Pill (Inactive Providers)', { cfg.pill ~= false }) then
            cfg.pill = not (cfg.pill ~= false)
            settingsMod.save(cfg)
        end

        imgui.Separator()
        imgui.TextColored({ 0.224, 0.812, 0.898, 1.0 }, 'PREVIEW WITHOUT COMBAT')
        imgui.Text('/soulhud demo <soulKey|cycle|off>')

        if soulDef and #(soulDef.resources or {}) > 0 then
            imgui.Separator()
            imgui.TextColored({ 0.655, 0.549, 0.878, 1.0 }, ('TRACKERS (%s):'):format(soulDef.name))
            for _, res in ipairs(soulDef.resources or {}) do
                local vis = settingsMod.isElementVisible(cfg, soulDef.key, res.id)
                if imgui.Checkbox(res.label .. '##' .. res.id, { vis }) then
                    settingsMod.setElementVisible(cfg, soulDef.key, res.id, not vis)
                    settingsMod.save(cfg)
                end
            end
        end
    end
    imgui.End()
    if pushed > 0 then imgui.PopStyleColor(pushed) end
    if not open[1] then
        callbacks.setConfigOpen(false)
    end
end

return M
