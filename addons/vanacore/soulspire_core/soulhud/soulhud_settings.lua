local M = {}

local defaults = {
    x              = 320,
    y              = 180,
    scale          = 1.0,
    opacity        = 0.94,
    layout         = 'standard', -- 'minimal' | 'standard' | 'expanded' ('compact' aliases to 'standard')
    mode           = 'auto',     -- 'auto' | 'show' | 'hide'
    locked         = false,
    hiddenElements = {},        -- [soulKey] = { [resId] = true }
    showShared     = true,      -- show shared party buffs in the status sub-strip
    autoHideOnMenu = true,      -- hide while any FFXI menu / map / cutscene is open
    pill           = true,      -- compact Soul header pill for Souls without a custom gauge (Lv10+)
}

local function cloneDefaults()
    return {
        x              = defaults.x,
        y              = defaults.y,
        scale          = defaults.scale,
        opacity        = defaults.opacity,
        layout         = defaults.layout,
        mode           = defaults.mode,
        locked         = defaults.locked,
        showShared     = defaults.showShared,
        autoHideOnMenu = defaults.autoHideOnMenu,
        pill           = defaults.pill,
        hiddenElements = {},
    }
end

local function clamp(val, lo, hi)
    if val < lo then return lo end
    if val > hi then return hi end
    return val
end

local function serialize(val, indent)
    indent = indent or ''
    local t = type(val)
    if t == 'number' or t == 'boolean' then
        return tostring(val)
    elseif t == 'string' then
        return string.format('%q', val)
    elseif t == 'table' then
        local keys = {}
        for k, _ in pairs(val) do
            keys[#keys + 1] = k
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = { '{\n' }
        local nextIndent = indent .. '    '
        for _, k in ipairs(keys) do
            local keyExpr = type(k) == 'string' and k:match('^[%a_][%w_]*$') and k or ('[' .. serialize(k) .. ']')
            parts[#parts + 1] = nextIndent .. keyExpr .. ' = ' .. serialize(val[k], nextIndent) .. ',\n'
        end
        parts[#parts + 1] = indent .. '}'
        return table.concat(parts)
    end
    return 'nil'
end

local function getSettingsFolder()
    if type(vana) == 'table' and vana.settings and type(vana.settings.folder) == 'function' then
        local folder = vana.settings.folder('global')
        if type(folder) == 'string' and folder ~= '' then
            return folder:gsub('[/\\]+$', '')
        end
    end
    if type(vana) == 'table' and vana.paths and type(vana.paths.install) == 'string' and vana.paths.install ~= '' then
        return vana.paths.install:gsub('[/\\]+$', '') .. '\\config\\addons\\soulspire_core'
    end
    return nil
end

local function getSettingsPath()
    local folder = getSettingsFolder()
    if not folder then return nil end
    return folder .. '\\soulhud_settings.lua'
end

function M.new()
    return cloneDefaults()
end

function M.reset(cfg)
    local d = cloneDefaults()
    for k, v in pairs(d) do
        cfg[k] = v
    end
end

function M.clampSettings(cfg)
    cfg.x = math.floor((tonumber(cfg.x) or defaults.x) + 0.5)
    cfg.y = math.floor((tonumber(cfg.y) or defaults.y) + 0.5)
    cfg.scale = clamp(tonumber(cfg.scale) or defaults.scale, 0.75, 2.0)
    cfg.opacity = clamp(tonumber(cfg.opacity) or defaults.opacity, 0.25, 1.0)
    if cfg.layout == 'compact' then
        cfg.layout = 'standard'
    end
    if cfg.layout ~= 'minimal' and cfg.layout ~= 'standard' and cfg.layout ~= 'expanded' then
        cfg.layout = defaults.layout
    end
    if cfg.mode ~= 'auto' and cfg.mode ~= 'show' and cfg.mode ~= 'hide' then
        cfg.mode = defaults.mode
    end
    cfg.locked = cfg.locked == true
    cfg.showShared = cfg.showShared ~= false
    cfg.autoHideOnMenu = cfg.autoHideOnMenu ~= false
    cfg.pill = cfg.pill ~= false
    if type(cfg.hiddenElements) ~= 'table' then
        cfg.hiddenElements = {}
    end
end

function M.isElementVisible(cfg, soulKey, resId)
    if not soulKey or not resId then return true end
    local bySoul = cfg.hiddenElements and cfg.hiddenElements[soulKey]
    return not (bySoul and bySoul[resId] == true)
end

function M.setElementVisible(cfg, soulKey, resId, visible)
    if not soulKey or not resId then return end
    cfg.hiddenElements = cfg.hiddenElements or {}
    cfg.hiddenElements[soulKey] = cfg.hiddenElements[soulKey] or {}
    if visible then
        cfg.hiddenElements[soulKey][resId] = nil
    else
        cfg.hiddenElements[soulKey][resId] = true
    end
end

function M.save(cfg)
    M.clampSettings(cfg)
    pcall(function()
        local folder = getSettingsFolder()
        local path = getSettingsPath()
        if not folder or not path then return end
        if type(vana) == 'table' and vana.fs and type(vana.fs.exists) == 'function' and type(vana.fs.create_dir) == 'function' then
            if not vana.fs.exists(folder) then
                vana.fs.create_dir(folder)
            end
        end
        local f = io.open(path, 'w')
        if f then
            f:write('-- SoulspireXI Universal Soul HUD settings\nreturn ' .. serialize(cfg) .. '\n')
            f:close()
        end
    end)
end

function M.load(cfg)
    pcall(function()
        local path = getSettingsPath()
        if not path then return end
        local f = io.open(path, 'r')
        if not f then
            M.save(cfg)
            return
        end
        f:close()

        local loader = loadfile(path)
        if not loader then return end
        if setfenv then setfenv(loader, {}) end
        local ok, data = pcall(loader)
        if ok and type(data) == 'table' then
            for k, v in pairs(data) do
                if k == 'hiddenElements' and type(v) == 'table' then
                    cfg.hiddenElements = {}
                    for sk, tbl in pairs(v) do
                        if type(tbl) == 'table' then
                            cfg.hiddenElements[sk] = {}
                            for rk, flag in pairs(tbl) do
                                if flag == true then
                                    cfg.hiddenElements[sk][rk] = true
                                end
                            end
                        end
                    end
                elseif defaults[k] ~= nil then
                    cfg[k] = v
                end
            end
            M.clampSettings(cfg)
        end
    end)
end

return M
