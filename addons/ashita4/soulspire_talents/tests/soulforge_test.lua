-- Unit & headless render tests for SoulspireXI The Soulforge (soulforge_ui.lua)
-- Run from addons/ashita4/soulspire_talents: luajit tests/soulforge_test.lua

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

-- Mock ImGui & DrawList for headless rendering & layout verification
local mockDisplay = { x = 1920, y = 1080 }
local drawCount = 0
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

local cursorX, cursorY = 0, 0
local mockImgui = {
    GetIO = function() return { DisplaySize = mockDisplay } end,
    SetNextWindowSize = function() end,
    SetNextWindowPos = function() end,
    PushStyleVar = function() end,
    PopStyleVar = function() end,
    PushStyleColor = function() end,
    PopStyleColor = function() end,
    Begin = function() return true end,
    End = function() end,
    BeginChild = function() return true end,
    EndChild = function() end,
    GetWindowPos = function() return 40, 40 end,
    GetWindowDrawList = function() return mockDl end,
    SetCursorScreenPos = function(p) cursorX, cursorY = p[1], p[2] end,
    GetCursorScreenPos = function() return cursorX, cursorY end,
    InvisibleButton = function() return false end,
    IsItemHovered = function() return false end,
    IsItemClicked = function() return false end,
    IsWindowHovered = function() return false end,
    IsMouseDragging = function() return false end,
    PushItemWidth = function() end,
    PopItemWidth = function() end,
    BeginCombo = function() return false end,
    EndCombo = function() end,
    InputText = function() return false end,
    Checkbox = function() return false end,
    Dummy = function() end,
    SetWindowFontScale = function() end,
    CalcTextSize = function(s) return #tostring(s or '') * 7, 14 end,
    TextUnformatted = function() end,
}

package.loaded['imgui'] = mockImgui
package.loaded['art']   = { draw = function() return false end, get = function() return nil end, clear = function() end }

local UI = require('soulforge_ui')

-- Build realistic Evolution WS detail (Combo id=1 with 5 stages + 4 mastery skillchain slots)
local function makeSampleState()
    local nodes = {
        { idx = 1,  key = 'e_co_open',   tier = 1, col = 1, rank = 1, maxRank = 1, canLearn = false, reqWsPoints = 0, reqKey = nil,         reqRank = 0, name = 'Opening Palm',    desc = 'Unlocks Combo and grants +15% TP return on hit.', reqLevel = 1,  cost = 1 },
        { idx = 2,  key = 'e_co_force',  tier = 1, col = 2, rank = 0, maxRank = 1, canLearn = false, reqWsPoints = 0, reqKey = nil,         reqRank = 0, name = 'Crushing Force',  desc = 'Unlocks Combo with +20% fTP on first strike.',    reqLevel = 1,  cost = 1 },
        { idx = 3,  key = 'e_co_flow',   tier = 2, col = 1, rank = 1, maxRank = 3, canLearn = true,  reqWsPoints = 1, reqKey = 'e_co_open', reqRank = 1, name = 'Flowing Strikes', desc = 'Adds +8% multi-hit rate per rank.',               reqLevel = 15, cost = 1 },
        { idx = 4,  key = 'e_co_edge',   tier = 2, col = 2, rank = 0, maxRank = 1, canLearn = true,  reqWsPoints = 1, reqKey = 'e_co_open', reqRank = 1, name = 'Keen Edge',       desc = 'Increases critical hit rate by +12%.',            reqLevel = 15, cost = 1 },
        { idx = 5,  key = 'e_co_storm',  tier = 3, col = 1, rank = 0, maxRank = 1, canLearn = false, reqWsPoints = 3, reqKey = 'e_co_flow', reqRank = 2, name = 'Tempest Chain',   desc = 'Extends skillchain window by 3s.',                reqLevel = 35, cost = 1 },
        { idx = 6,  key = 'evsc_t1',     tier = 1, col = 3, rank = 0, maxRank = 0, canLearn = false, reqWsPoints = 0, reqKey = nil,         reqRank = 0, name = 'SC Slot 1',       desc = 'Optional skillchain', reqLevel = 1, scTier = 1, scId = 1, scName = 'Impaction', cost = 0 },
        { idx = 7,  key = 'evsc_t2',     tier = 2, col = 3, rank = 0, maxRank = 0, canLearn = false, reqWsPoints = 0, reqKey = nil,         reqRank = 0, name = 'SC Slot 2',       desc = 'Optional skillchain', reqLevel = 1, scTier = 2, scId = 0, scName = '',          cost = 0 },
        { idx = 8,  key = 'evsc_t3',     tier = 3, col = 3, rank = 0, maxRank = 0, canLearn = false, reqWsPoints = 0, reqKey = nil,         reqRank = 0, name = 'SC Slot 3',       desc = 'Optional skillchain', reqLevel = 1, scTier = 3, scId = 9, scName = 'Fusion',    cost = 0 },
        { idx = 9,  key = 'evsc_t4',     tier = 4, col = 3, rank = 0, maxRank = 0, canLearn = false, reqWsPoints = 0, reqKey = nil,         reqRank = 0, name = 'SC Slot 4',       desc = 'Optional skillchain', reqLevel = 1, scTier = 4, scId = 0, scName = '',          cost = 0 },
    }
    local byKey = {}
    for _, n in ipairs(nodes) do byKey[n.key] = n end

    return {
        open = { true },
        synced = true,
        jobKey = 'MNK',
        specName = 'Chi Weaver',
        jobLevel = 40,
        avail = 3,
        spent = 2,
        earned = 5,
        mainSkill = 1,
        rangedSkill = 0,
        selectedSkill = -1,
        selectedWsId = 1,
        inspectedNodeKey = 'e_co_flow',
        searchBuf = { '' },
        investedOnly = { false },
        spentByWs = { [1] = 2 },
        unlockedByWs = { [1] = true },
        catalog = {
            { id = 1, skill = 1, name = 'Combo', wsType = 'physical' },
            { id = 2, skill = 1, name = 'Shoulder Tackle', wsType = 'physical' },
        },
        wsDetail = {
            id = 1,
            name = 'Combo',
            skillName = 'Hand-to-Hand',
            wsType = 'physical',
            spent = 2,
            orig = 'Impaction',
            nodes = nodes,
            byKey = byKey,
        },
    }
end

local st = makeSampleState()
local d  = st.wsDetail

-- 1. Verify Evolution detection, 4 Skillchain Forging slots (with unlock rules), and 4 Spec WS Slots
assert_true(UI.isEvolutionTree(d), 'Combo detected as Evolution tree')
assert_true(UI.isWsUnlocked(st), 'Combo detected as unlocked')
local slots = UI.getSkillchainSlots(d)
assert_eq(#slots, 4, '4 skillchain forging slots extracted')
assert_eq(slots[1].scName, 'Impaction', 'slot 1 SC name')
assert_eq(slots[1].unlocked, true, 'slot 1 unlocked at 2 spent')
assert_eq(slots[1].active, true, 'slot 1 active when unlocked and scId>0')
assert_eq(slots[2].scName, 'OFF', 'slot 2 OFF')
assert_eq(slots[2].unlocked, true, 'slot 2 unlocked at 2 spent')
assert_eq(slots[3].scName, 'Fusion', 'slot 3 SC name')
assert_eq(slots[3].unlocked, false, 'slot 3 locked at 2 spent (requires 3 stages)')
assert_eq(slots[3].active, false, 'slot 3 inactive while locked')
assert_eq(slots[4].unlocked, false, 'slot 4 locked at 2 spent (requires 4 stages)')

local invested = UI.getInvestedWeaponskills(st)
assert_eq(#invested, 1, '1 invested WS in spec mastery slots')
assert_eq(invested[1].id, 1, 'invested WS id matches Combo')
assert_eq(invested[1].mastered, false, 'Combo at 2/5 not yet mastered')

st.ui = { confirmAction = { kind = 'invest' }, confirmResetWs = true, drawerOpen = 'arsenal' }
st.confirmResetAll = true
UI.resetTransientState(st)
assert_eq(st.ui.confirmAction, nil, 'resetTransientState clears confirmAction')
assert_eq(st.ui.confirmResetWs, false, 'resetTransientState clears confirmResetWs')
assert_eq(st.confirmResetAll, false, 'resetTransientState clears confirmResetAll')
assert_eq(st.ui.drawerOpen, nil, 'resetTransientState clears drawerOpen')

-- 2. Verify all node evaluation states
local evMax = UI.evaluateNode(st, d, d.byKey.e_co_open, false, 10)
assert_eq(evMax.stateKey, 'maxed', 'rank==maxRank is maxed')
assert_eq(evMax.canUpgrade, false, 'maxed node cannot upgrade')

local evLearned = UI.evaluateNode(st, d, d.byKey.e_co_flow, false, 10)
assert_eq(evLearned.stateKey, 'learned', 'partial rank is learned')
assert_eq(evLearned.canUpgrade, true, 'learned node with canLearn can upgrade')
assert_eq(evLearned.canRefund, true, 'learned node can refund')

local evAvail = UI.evaluateNode(st, d, d.byKey.e_co_edge, false, 10)
assert_eq(evAvail.stateKey, 'available', 'unlearned canLearn node is available')
assert_eq(evAvail.canUpgrade, true, 'available node can upgrade')

local evPrereq = UI.evaluateNode(st, d, d.byKey.e_co_storm, false, 10)
assert_eq(evPrereq.stateKey, 'prereq_blocked', 'unmet parent/wsPoints is prereq_blocked')
assert_true(evPrereq.reason and evPrereq.reason:find('Flowing Strikes', 1, true) ~= nil, 'prereq reason names parent node')

local evOther = UI.evaluateNode(st, d, d.byKey.e_co_force, true, 10)
assert_eq(evOther.stateKey, 'locked', 'other path chosen is locked')
assert_eq(evOther.canUpgrade, false, 'other path cannot upgrade')

-- Pending state
st.pendingOp = { kind = 'invest', wsId = 1, nodeKey = 'e_co_edge', sentAt = 9.5 }
local evPending = UI.evaluateNode(st, d, d.byKey.e_co_edge, false, 10)
assert_eq(evPending.stateKey, 'pending', 'pending op sets pending state')
assert_eq(evPending.canUpgrade, false, 'pending op blocks duplicate submissions')
st.pendingOp = nil

-- Server rejection state (authoritative rank stays 0)
st.rejectedNodeKey = 'e_co_edge'
st.rejectedMsg = 'Insufficient points on server.'
st.rejectedAt = 9.8
local evRej = UI.evaluateNode(st, d, d.byKey.e_co_edge, false, 10)
assert_eq(evRej.stateKey, 'rejected', 'server rejection sets rejected state')
assert_eq(d.byKey.e_co_edge.rank, 0, 'authoritative rank untouched on rejection')
st.rejectedNodeKey = nil

-- 3. Headless render & responsive layout pass across QA resolutions + timing
local mockActions = {
    send = function() end,
    requestWS = function() end,
    sync = function() end,
    filtered = function() return st.catalog end,
    skills = { { id = -1, name = 'Equipped' } },
    investNode = function() end,
    refundNode = function() end,
    cycleSkillchain = function() end,
    resetWS = function() end,
    resetAll = function() end,
    savePrefs = function() end,
}

local resolutions = {
    { w = 1280, h = 720,  expectMode = 'focused' },
    { w = 1920, h = 1080, expectMode = 'balanced' },
    { w = 2560, h = 1440, expectMode = 'expanded' },
    { w = 3440, h = 1440, expectMode = 'expanded' },
}

for _, res in ipairs(resolutions) do
    mockDisplay.x, mockDisplay.y = res.w, res.h
    drawCount = 0
    local L = UI.computeLayout(st, res.w, res.h)
    assert_eq(L.mode, res.expectMode, string.format('%dx%d mode', res.w, res.h))
    UI.draw(st, mockActions)
    assert_true(drawCount > 80, string.format('%dx%d emitted draw calls (%d)', res.w, res.h, drawCount))
end

-- Micro-benchmark: 200 headless frames at 2560x1440
mockDisplay.x, mockDisplay.y = 2560, 1440
local t0 = os.clock()
for _ = 1, 200 do
    UI.draw(st, mockActions)
end
local elapsedMs = (os.clock() - t0) * 1000
local avgMs = elapsedMs / 200
print(string.format('Soulforge headless render: %.3f ms/frame avg over 200 frames at 2560x1440.', avgMs))
assert_true(avgMs < 5.0, 'expected <5ms/frame headless LuaJIT render')

print('SoulspireXI The Soulforge tests passed.')
