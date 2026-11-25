-- SoulspireXI Talent Art Loader (VanaCore-Native)
-- Uses `vana.soulspire.load_texture(path)` with zero d3d8/FFI/Ashita dependencies.
-- Missing or invalid assets degrade cleanly to procedural DrawList visuals.

local A = { textures = {}, status = {}, root = nil, install_dir = nil }

local function validName(name)
    return type(name) == 'string' and name:match('^[%w_%-]+$') ~= nil
end

function A.setRoot(path, install_dir)
    if type(path) == 'string' and path ~= '' then
        A.root = path:gsub('[/\\]+$', '')
    else
        A.root = nil
    end
    if type(install_dir) == 'string' and install_dir ~= '' then
        A.install_dir = install_dir:gsub('[/\\]+$', '')
    elseif A.root then
        A.install_dir = A.root:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')
    end
end

local function resolveBase()
    local base = A.root
    if type(base) ~= 'string' or base == '' then
        if type(addon) == 'table' and type(addon.path) == 'string' then
            base = addon.path:gsub('[/\\]+$', '')
        end
    end
    return base
end

local function loadCandidates(cacheKey, candidates)
    local cached = A.textures[cacheKey]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    if A.status[cacheKey] ~= nil then return nil end

    if not (type(vana) == 'table' and vana.soulspire and type(vana.soulspire.load_texture) == 'function') then
        A.status[cacheKey] = 'vana.soulspire.load_texture unavailable'
        return nil
    end

    local last_err = 'missing'
    for _, filename in ipairs(candidates) do
        local id, why = vana.soulspire.load_texture(filename)
        if type(id) == 'number' and id ~= 0 then
            A.textures[cacheKey] = id
            A.status[cacheKey] = 'ready'
            return id
        elseif type(why) == 'string' then
            last_err = why
        end
    end

    A.textures[cacheKey] = false
    A.status[cacheKey] = last_err
    return nil
end

function A.get(name)
    if not validName(name) then return nil end
    local base = resolveBase()
    if type(base) ~= 'string' or base == '' then return nil end
    local inst = A.install_dir or base:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')
    return loadCandidates(name, {
        base .. '/assets/' .. name .. '.png',
        base .. '/assets/soulspire_talents/' .. name .. '.png',
        inst .. '/addons/ashita4/soulspire_talents/assets/' .. name .. '.png',
        inst .. '/addons/ashita/soulspire_talents/assets/' .. name .. '.png',
        inst .. '/addons/ashita4/soulspire_core/assets/' .. name .. '.png',
        inst .. '/addons/ashita/soulspire_core/assets/' .. name .. '.png',
    })
end

function A.getFromAddon(siblingAddon, name)
    if not validName(siblingAddon) or not validName(name) then return nil end
    local base = resolveBase()
    if type(base) ~= 'string' or base == '' then return nil end
    local inst = A.install_dir or base:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')
    return loadCandidates(siblingAddon .. ':' .. name, {
        base .. '/assets/' .. siblingAddon .. '/' .. name .. '.png',
        base .. '/assets/' .. name .. '.png',
        inst .. '/addons/ashita4/' .. siblingAddon .. '/assets/' .. name .. '.png',
        inst .. '/addons/ashita/' .. siblingAddon .. '/assets/' .. name .. '.png',
    })
end

function A.draw(dl, name, x, y, w, h, tint)
    if dl == nil or w <= 0 or h <= 0 then return false end
    local id = A.get(name)
    if id == nil then return false end
    dl:AddImage(id, { x, y }, { x + w, y + h }, { 0, 0 }, { 1, 1 }, tint or 0xFFFFFFFF)
    return true
end

function A.clear()
    A.textures = {}
    A.status = {}
end

return A
