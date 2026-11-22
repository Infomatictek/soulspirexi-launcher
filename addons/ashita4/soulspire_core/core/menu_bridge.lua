-- SoulspireXI Core: read-only FFXI native MenuManager inspector.
-- Reuses the verified read-only native MenuManager layout from crystalsocket/menu.lua
-- (AshitaCore:GetPointerManager():Get('menu') -> storage - 0x54) without writing to
-- FFXiMain.dll memory or interfering with any crystaljobs.dll hooks.
--
-- IMPORTANT: This bridge powers a clearly identified native-styled fallback entry
-- docked to the FFXI Main Menu. It does NOT perform binary insertion into FFXiMain.dll.

local MenuBridge = {}
MenuBridge.__index = MenuBridge

-- Recognized FFXI top-level Main Menu form names.
MenuBridge.MAIN_MENU_FORMS = {
    ['menu    mnu1']     = true,
    ['menu    mnu2']     = true,
    ['menu    mainmenu'] = true,
    ['menu    submain']  = true,
}

local function address(value, span)
    return type(value) == 'number' and value >= 0x10000
        and value <= 0xFFFFFFFF - span + 1 and value % 1 == 0
end

local function pointer(value, span)
    return address(value, span) and value % 4 == 0
end

function MenuBridge.new(memory, scaling, operand, main_menu_forms)
    local self = setmetatable({
        memory = memory,
        scaling = scaling,
        forms = main_menu_forms or MenuBridge.MAIN_MENU_FORMS,
        manager = nil,
    }, MenuBridge)

    local ok, manager = pcall(function()
        if not memory or not address(operand, 4) then return nil end
        local storage = memory.read_uint32(operand)
        return pointer(storage, 4) and pointer(storage - 0x54, 4) and (storage - 0x54) or nil
    end)
    self.manager = ok and manager or nil
    return self
end

function MenuBridge:is_available()
    return self.manager ~= nil and self.scaling ~= nil
end

-- Walk all visible native FFXI menu windows (read-only).
function MenuBridge:inspect_all()
    if not self:is_available() then return nil end
    local ok, result = pcall(function()
        local memory = self.memory
        local current = memory.read_uint32(self.manager + 0x54)
        if not pointer(current, 0x71) then return nil end
        if memory.read_uint32(current + 0x10) == 0xE or memory.read_uint8(current + 0x70) ~= 0 then
            return { current = nil, current_name = nil, cursor = nil, windows = {} }
        end

        local node = memory.read_uint32(self.manager)
        local seen, windows = {}, {}
        local current_name = nil

        for _ = 1, 128 do
            if node == 0 then break end
            if not pointer(node, 0x15) or seen[node] then return nil end
            seen[node] = true

            if memory.read_uint8(node + 0x14) == 0 then
                local window = memory.read_uint32(node + 0x10)
                if not pointer(window, 0x6F) then return nil end
                if memory.read_uint8(window + 0x69) ~= 0
                    and memory.read_uint8(window + 0x6E) == 0 then
                    local form = memory.read_uint32(window + 4)
                    if not pointer(form, 86) then return nil end
                    local name = memory.read_string(form + 70, 16):gsub('%z.*$', ''):gsub('%s+$', '')
                    local left = memory.read_int16(window + 0x3A)
                    local top = memory.read_int16(window + 0x3C)
                    local right = memory.read_int16(window + 0x3E)
                    local bottom = memory.read_int16(window + 0x40)
                    local entry = {
                        window = window,
                        name = name,
                        left = left,
                        top = top,
                        right = right,
                        bottom = bottom,
                        is_current = (window == current),
                    }
                    windows[#windows + 1] = entry
                    if window == current then
                        current_name = name
                    end
                end
            end

            node = memory.read_uint32(node)
            if node ~= 0 and seen[node] then return nil end
        end

        if node ~= 0 then return nil end
        local cursor = memory.read_int16(current + 0x4C)
        return {
            current = current,
            current_name = current_name,
            cursor = cursor,
            windows = windows,
        }
    end)
    return ok and result or nil
end

-- Returns a main-menu dock context when an FFXI top-level Main Menu is open and active,
-- or nil when no Main Menu is active (e.g., Equipment, Magic, Gameplay, Cutscene).
function MenuBridge:main_menu_context()
    local state = self:inspect_all()
    if not state or not state.current or not state.current_name then return nil end
    if not self.forms[state.current_name] then return nil end

    local main_win = nil
    for _, win in ipairs(state.windows) do
        if win.window == state.current then
            main_win = win
            break
        end
    end
    if not main_win then return nil end

    local scaling = self.scaling
    local left, top, right, bottom = main_win.left, main_win.top, main_win.right, main_win.bottom
    if left < 0 or top < 0 or right <= left or bottom <= top then return nil end
    if scaling.menu and (right > scaling.menu.w or bottom > scaling.menu.h) then return nil end

    local dock_x = scaling.scale_w(left)
    local dock_y = scaling.scale_h(bottom + 4)
    local dock_w = scaling.scale_w(right - left)
    -- Clamp dock inside screen if main menu sits near bottom edge
    if scaling.scaled and scaling.scaled.h and (dock_y + 36) > scaling.scaled.h then
        dock_y = math.max(8, scaling.scale_h(top) - 38)
    end

    return {
        window = state.current,
        name = state.current_name,
        cursor = state.cursor,
        bounds = {
            left = left,
            top = top,
            right = right,
            bottom = bottom,
        },
        dock = {
            x = dock_x,
            y = dock_y,
            w = dock_w,
        },
    }
end

return MenuBridge
