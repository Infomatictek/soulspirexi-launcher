-- Unit tests for SoulspireXI Core UI Foundations (palette, responsive layout, drawing primitives)
-- Run from addons/ashita4/soulspire_core: luajit tests/foundations_test.lua

package.path = './?.lua;./?/init.lua;' .. package.path

local F = require('core.foundations')

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format('%s: expected %s, got %s', msg or 'assert_eq', tostring(expected), tostring(actual)), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then
        error(msg or 'assert_true failed', 2)
    end
end

-- 1. Official palette verification (Abyss #0B1019, Midnight #151928, Soul Gold #E8BD70, Aether Cyan #39CFE5, Crystal Violet #8063BC)
local function check_hex_close(rgba, hexStr, label)
    local expected = F.hex(hexStr, rgba[4])
    for i = 1, 3 do
        assert_true(math.abs(rgba[i] - expected[i]) < 0.005, label .. ' channel ' .. i .. ' mismatch')
    end
end
check_hex_close(F.rgba.abyss, '#0B1019', 'Abyss')
check_hex_close(F.rgba.midnight, '#151928', 'Midnight')
check_hex_close(F.rgba.soul_gold, '#E8BD70', 'Soul Gold')
check_hex_close(F.rgba.aether_cyan, '#39CFE5', 'Aether Cyan')
check_hex_close(F.rgba.crystal_violet, '#8063BC', 'Crystal Violet')

-- 2. All 7 non-hover node visual states exist and have non-color symbols + tags
for _, key in ipairs({ 'locked', 'prereq_blocked', 'available', 'learned', 'maxed', 'pending', 'rejected' }) do
    local st = F.NODE_STATES[key]
    assert_true(type(st) == 'table', 'missing node state: ' .. key)
    assert_true(type(st.tag) == 'string' and #st.tag > 0, 'missing tag: ' .. key)
    assert_true(type(st.symbol) == 'string' and #st.symbol > 0, 'missing symbol: ' .. key)
end

-- 3. Resolution-independent responsive layout matrix
local cases = {
    { name = '1280x720@1.0',  w = 1280, h = 720,  s = 1.00, expectMode = 'focused' },
    { name = '1280x720@1.25', w = 1280, h = 720,  s = 1.25, expectMode = 'focused' },
    { name = '1024x768@1.0',  w = 1024, h = 768,  s = 1.00, expectMode = 'focused' },
    { name = '1600x900@1.0',  w = 1600, h = 900,  s = 1.00, expectMode = 'balanced' },
    { name = '1920x1080@1.0', w = 1920, h = 1080, s = 1.00, expectMode = 'balanced' },
    { name = '1920x1080@1.25',w = 1920, h = 1080, s = 1.25, expectMode = 'balanced' },
    { name = '1920x1080@1.5', w = 1920, h = 1080, s = 1.50, expectMode = 'focused' },
    { name = '2560x1440@1.0', w = 2560, h = 1440, s = 1.00, expectMode = 'expanded' },
    { name = '2560x1440@1.25',w = 2560, h = 1440, s = 1.25, expectMode = 'expanded' },
    { name = '3440x1440@1.0', w = 3440, h = 1440, s = 1.00, expectMode = 'expanded' },
    { name = '3840x2160@1.5', w = 3840, h = 2160, s = 1.50, expectMode = 'expanded' },
    { name = '5120x1440@1.0', w = 5120, h = 1440, s = 1.00, expectMode = 'expanded' },
}

for _, c in ipairs(cases) do
    local L = F.computeViewportLayout(c.w, c.h, c.s)
    assert_eq(L.mode, c.expectMode, c.name .. ' mode')
    assert_true(L.winW <= c.w, c.name .. ' winW fits viewport')
    assert_true(L.winH <= c.h, c.name .. ' winH fits viewport')
    assert_true(L.posX >= 0 and L.posY >= 0, c.name .. ' window origin inside viewport')
    assert_true(L.posX + L.winW <= c.w, c.name .. ' right edge inside viewport')
    assert_true(L.posY + L.winH <= c.h, c.name .. ' bottom edge inside viewport')
    assert_true(L.forgeW >= 320, c.name .. ' forge has usable width')
    assert_true(L.bodyH >= 220, c.name .. ' body has usable height')
end

-- Ultrawide cap check: 3440x1440 and 5120x1440 must not stretch across full monitor
local L_uw = F.computeViewportLayout(3440, 1440, 1.0)
assert_true(L_uw.winW <= 1920, '3440x1440 max width capped')
local L_suw = F.computeViewportLayout(5120, 1440, 1.0)
assert_true(L_suw.winW <= 1920, '5120x1440 max width capped')

-- 4. Mock DrawList smoke test for all reusable primitives
local drawCalls = 0
local mockDl = {
    AddRectFilled = function() drawCalls = drawCalls + 1 end,
    AddRect = function() drawCalls = drawCalls + 1 end,
    AddRectFilledMultiColor = function() drawCalls = drawCalls + 1 end,
    AddLine = function() drawCalls = drawCalls + 1 end,
    AddQuadFilled = function() drawCalls = drawCalls + 1 end,
    AddQuad = function() drawCalls = drawCalls + 1 end,
    AddCircleFilled = function() drawCalls = drawCalls + 1 end,
    AddCircle = function() drawCalls = drawCalls + 1 end,
    AddTriangleFilled = function() drawCalls = drawCalls + 1 end,
    AddText = function() drawCalls = drawCalls + 1 end,
}
local mockImgui = {
    SetCursorScreenPos = function() end,
    InvisibleButton = function() return false end,
    IsItemHovered = function() return false end,
    CalcTextSize = function(s) return #tostring(s or '') * 7, 14 end,
}

F.drawPanelFrame(mockDl, 10, 10, 400, 300)
F.drawDivider(mockDl, 20, 40, 360)
F.drawCrystalMedallion(mockDl, 100, 100, 28)
F.drawBadgePill(mockImgui, mockDl, 20, 60, 'MASTERED')
F.drawConnectionPath(mockDl, 100, 100, 200, 180, 'active')
F.drawConnectionPath(mockDl, 100, 100, 200, 180, 'available')
F.drawConnectionPath(mockDl, 100, 100, 200, 180, 'locked')
F.drawSegmentedGauge(mockImgui, mockDl, 20, 200, 200, 18, 3, 5, { notches = 5, label = 'Zeal', valueText = '3/5' })
F.drawPipRow(mockDl, 20, 230, 3, 5, { glow = true })
F.drawActionButton(mockImgui, mockDl, '##btn', 20, 260, 120, 28, 'FORGE', 'gold')

assert_true(drawCalls >= 40, 'expected draw primitives to emit DrawList calls, got ' .. drawCalls)

-- 5. Viewport clamping for floating HUD
local cx, cy = F.clampToViewport(2400, 1300, 320, 120, 1920, 1080, 4)
assert_true(cx <= 1920 - 320 - 4, 'clampToViewport x')
assert_true(cy <= 1080 - 120 - 4, 'clampToViewport y')

print('SoulspireXI Core UI Foundations tests passed.')
