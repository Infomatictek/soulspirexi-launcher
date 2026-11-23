-- Unit & headless render tests for SoulspireXI Universal Soul HUD (soulhud_gauge.lua)
-- Run from addons/ashita4/soulspire_soulhud: luajit tests/soulhud_gauge_test.lua

package.path = './?.lua;../soulspire_core/?.lua;' .. package.path

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

local drawCount = 0
local lastWindowSize = { 0, 0 }
local mockDisplay = { x = 1920, y = 1080 }
local mockDl = {
    AddRectFilled = function() drawCount = drawCount + 1 end,
    AddRect = function() drawCount = drawCount + 1 end,
    AddRectFilledMultiColor = function() drawCount = drawCount + 1 end,
    AddLine = function() drawCount = drawCount + 1 end,
    AddQuadFilled = function() drawCount = drawCount + 1 end,
    AddQuad = function() drawCount = drawCount + 1 end,
    AddCircleFilled = function() drawCount = drawCount + 1 end,
    AddCircle = function() drawCount = drawCount + 1 end,
    AddTriangleFilled = function() drawCount = drawCount + 1 end,
    AddText = function() drawCount = drawCount + 1 end,
    AddImage = function() drawCount = drawCount + 1 end,
}

local mockImgui = {
    GetIO = function() return { DisplaySize = mockDisplay } end,
    SetNextWindowPos = function() end,
    PushStyleVar = function() end,
    PopStyleVar = function() end,
    PushStyleColor = function() end,
    PopStyleColor = function() end,
    Begin = function() return true end,
    End = function() end,
    BeginPopup = function() return false end,
    EndPopup = function() end,
    GetWindowPos = function() return 200, 200 end,
    GetWindowDrawList = function() return mockDl end,
    SetCursorScreenPos = function() end,
    Dummy = function(sz)
        if type(sz) == 'table' and (sz[1] or 0) > 10 and (sz[2] or 0) > 10 then
            lastWindowSize = { sz[1], sz[2] }
        end
    end,
    IsItemHovered = function() return false end,
    SetWindowFontScale = function() end,
    CalcTextSize = function(s) return #tostring(s or '') * 7, 14 end,
    TextUnformatted = function() end,
}

package.loaded['ox_icons'] = { ui = function() return nil end, crystal = function() return nil end, custom = function() return nil end }

local settingsMod = require('soulhud_settings')
local registry    = require('soulhud_registry')
local loadSouls   = require('souls.init')
local gauge       = require('soulhud_gauge')
local roster      = require('soulhud_roster')

loadSouls(registry)

-- 1. Settings normalization: legacy 'compact' maps to 'standard'
local cfg = settingsMod.new()
assert_eq(cfg.layout, 'standard', 'default layout is standard')
cfg.layout = 'compact'
settingsMod.clampSettings(cfg)
assert_eq(cfg.layout, 'standard', 'legacy compact maps to standard')
cfg.layout = 'minimal'
settingsMod.clampSettings(cfg)
assert_eq(cfg.layout, 'minimal', 'minimal preserved')
cfg.layout = 'expanded'
settingsMod.clampSettings(cfg)
assert_eq(cfg.layout, 'expanded', 'expanded preserved')

-- 2. Render COR Flintlock across minimal, standard, and expanded modes
local flintDef = registry.getSoul('flintlock')
assert_true(flintDef ~= nil, 'flintlock registered')
local flintRt = registry.newRuntimeState(flintDef)
registry.applyServerData(flintDef, flintRt, { powder = '2', load_cd = '12', mark_rem = '18', hair_cd = '0' }, 100)
registry.updateNativeRecasts(flintDef, flintRt, { [195] = 45 }, 100)

local sampleBuffs = {
    { iconId = 9001, power = 3, expiresAt = 125, entry = { name = 'Test Buff', tooltip = 'Active', isDebuff = false } },
    { iconId = 9002, power = 0, expiresAt = 104, entry = { name = 'Test Debuff', tooltip = 'Danger', isDebuff = true } },
}

local modeDraws = {}
for _, mode in ipairs({ 'minimal', 'standard', 'expanded' }) do
    cfg.layout = mode
    drawCount = 0
    gauge.render(mockImgui, {
        soulKey = 'flintlock',
        kv      = { powder = '2', load_cd = '12', mark_rem = '18' },
        def     = flintDef,
        rt      = flintRt,
        buffs   = sampleBuffs,
        now     = 100,
        syncAt  = 100,
        cfg     = cfg,
        level   = 75,
    })
    modeDraws[mode] = drawCount
    assert_true(drawCount > 20, mode .. ' emitted draw calls')
end
assert_true(modeDraws.minimal < modeDraws.standard, 'minimal draws fewer elements than standard')
assert_true(modeDraws.expanded > modeDraws.standard, 'expanded draws secondary mechanics deck')

-- 3. Representative Souls across all roles + Soul switch
local testSouls = {
    { key = 'aegistemplar', kv = { zeal = '4', consec_rem = '9' } },
    { key = 'chiweaver',    kv = { chi_stacks = '85', harmony_rem = '12' } },
    { key = 'kurogane',     kv = { clones = '4', phase = '3', phase_rem = '14', last_cmd = 'Feint' } },
    { key = 'necromancer',  kv = { thrall_mode = 'dullahan', thrall_role = 'tank', thrall_hpp = '18', dark_pact = '1' } },
}
cfg.layout = 'expanded'
for _, ts in ipairs(testSouls) do
    local def = registry.getSoul(ts.key)
    local rt  = def and registry.newRuntimeState(def) or nil
    if def and rt then registry.applyServerData(def, rt, ts.kv, 100) end
    drawCount = 0
    gauge.render(mockImgui, {
        soulKey = ts.key, kv = ts.kv, def = def, rt = rt,
        buffs = sampleBuffs, now = 100, syncAt = 100, cfg = cfg, level = 75,
    })
    assert_true(drawCount > 25, ts.key .. ' rendered cleanly')
end

-- 4. Full 66-Soul canonical roster compatibility pass (all 3 display modes)
local demoMod = require('soulhud_demo')
assert_eq(#(roster.list or {}), 66, 'canonical 66-Soul roster count')
for _, e in ipairs(roster.list) do
    local def = registry.getSoul(e.key)
    local rt  = def and registry.newRuntimeState(def) or nil
    local kv  = demoMod.kv(e.key, 100) or {}
    if def and rt then registry.applyServerData(def, rt, kv, 100) end
    for _, mode in ipairs({ 'minimal', 'standard', 'expanded' }) do
        cfg.layout = mode
        gauge.render(mockImgui, {
            soulKey = e.key, kv = kv, def = def, rt = rt,
            buffs = {}, now = 100, syncAt = 100, cfg = cfg, level = 75,
        })
    end
end
cfg.layout = 'expanded'

-- 5. Viewport clamping when positioned off-screen
cfg.x, cfg.y = 5000, 5000
mockDisplay.x, mockDisplay.y = 1280, 720
gauge.render(mockImgui, {
    soulKey = 'flintlock', kv = { powder = '3' }, def = flintDef, rt = flintRt,
    buffs = {}, now = 100, syncAt = 100, cfg = cfg, level = 75,
})
assert_true(cfg.x < 1280 and cfg.y < 720, 'HUD clamped inside 1280x720 viewport')

-- 6. Micro-benchmark: 500 headless frames in Expanded mode
local t0 = os.clock()
for i = 1, 500 do
    gauge.render(mockImgui, {
        soulKey = 'flintlock', kv = { powder = '2', load_cd = '12', mark_rem = '18' },
        def = flintDef, rt = flintRt, buffs = sampleBuffs, now = 100 + i * 0.016, syncAt = 100, cfg = cfg, level = 75,
    })
end
local avgMs = ((os.clock() - t0) * 1000) / 500
print(string.format('Soul HUD headless render (Expanded): %.3f ms/frame avg over 500 frames.', avgMs))
assert_true(avgMs < 2.0, 'expected <2ms/frame headless LuaJIT render for combat HUD')

print('SoulspireXI Universal Soul HUD tests passed.')
