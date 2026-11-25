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

local function iconCandidates(filename)
    local base = baseRoot or (type(addon) == 'table' and type(addon.path) == 'string' and addon.path:gsub('[/\\]+$', '')) or '.'
    local inst = installDir or base:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')
    return {
        base .. '/assets/status_icons/' .. filename,
        inst .. '/addons/ashita4/soulspire_soulhud/assets/status_icons/' .. filename,
        inst .. '/addons/ashita/soulspire_soulhud/assets/status_icons/' .. filename,
    }
end

function M.custom(iconId)
    return loadCandidates('custom:' .. tostring(iconId), iconCandidates(tostring(iconId) .. '.png'))
end

function M.hud(name)
    return loadCandidates('hud:' .. tostring(name), iconCandidates('hud_' .. tostring(name) .. '.png'))
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

function M.clear()
    fileCache = {}
end

return M
