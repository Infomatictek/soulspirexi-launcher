-- SoulspireXI Status & HUD Icon Loader (VanaCore-Native)
-- Uses `vana.soulspire.load_texture(path)` with zero d3d8/FFI/Ashita dependencies.

local M = {}

local fileCache = {}
local baseRoot = nil
local installDir = nil

function M.setRoot(addon_path, install_dir)
    baseRoot = type(addon_path) == 'string' and addon_path:gsub('[/\\]+$', '') or nil
    installDir = type(install_dir) == 'string' and install_dir:gsub('[/\\]+$', '') or nil
end

local function resolveBase()
    local base = baseRoot or (type(addon) == 'table' and type(addon.path) == 'string' and addon.path:gsub('[/\\]+$', '')) or '.'
    local inst = installDir or base:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')
    return base, inst
end

local function loadCandidates(key, candidates)
    local cached = fileCache[key]
    if cached ~= nil then return cached ~= false and cached or nil end
    if not (type(vana) == 'table' and vana.soulspire and type(vana.soulspire.load_texture) == 'function') then
        fileCache[key] = false
        return nil
    end
    for _, path in ipairs(candidates) do
        local id = vana.soulspire.load_texture(path)
        if type(id) == 'number' and id ~= 0 then
            fileCache[key] = id
            return id
        end
    end
    fileCache[key] = false
    return nil
end

local function iconCandidates(subdir, filename)
    local base, inst = resolveBase()
    return {
        base .. '/assets/' .. subdir .. '/' .. filename,
        inst .. '/addons/vanacore/soulspire_core/assets/' .. subdir .. '/' .. filename,
        inst .. '/addons/ashita4/soulspire_soulhud/assets/' .. subdir .. '/' .. filename,
        inst .. '/addons/ashita/soulspire_soulhud/assets/' .. subdir .. '/' .. filename,
    }
end

function M.custom(iconId)
    return loadCandidates('custom:' .. tostring(iconId), iconCandidates('status_icons', tostring(iconId) .. '.png'))
end

function M.hud(name)
    return loadCandidates('hud:' .. tostring(name), iconCandidates('status_icons', 'hud_' .. tostring(name) .. '.png'))
end

function M.ui(name)
    return loadCandidates('ui:' .. tostring(name), iconCandidates('ui', tostring(name) .. '.png'))
end

function M.crystal(soulKey)
    local key = tostring(soulKey or '')
    if key == '' then return nil end
    local base, inst = resolveBase()
    local candidates = iconCandidates('crystals', key .. '.png')
    candidates[#candidates + 1] = base .. '/assets/' .. key .. '.png'
    candidates[#candidates + 1] = inst .. '/addons/ashita4/crystalsocket/assets/' .. key .. '.png'
    return loadCandidates('crystal:' .. key, candidates)
end

function M.file(path)
    if type(path) ~= 'string' or path == '' then return nil end
    return loadCandidates('file:' .. path, { path })
end

function M.vanilla(statusId)
    return M.custom(statusId)
end

function M.get(iconId)
    return M.custom(iconId)
end

function M.forEffect(catalog, effectId, iconId)
    local entry = catalog and catalog.byEffectId and catalog.byEffectId[effectId] or nil
    if entry == nil and catalog and catalog.byIconId and iconId then
        local byIcon = catalog.byIconId[iconId]
        if byIcon ~= nil and byIcon.effectId == effectId then entry = byIcon end
    end
    if entry ~= nil then
        return M.custom(entry.iconId), entry
    end
    return M.custom(iconId and iconId > 0 and iconId or effectId), nil
end

function M.release()
    fileCache = {}
end

function M.clear()
    fileCache = {}
end

return M
