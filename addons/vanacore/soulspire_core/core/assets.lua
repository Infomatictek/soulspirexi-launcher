-- SoulspireXI Core (VanaCore-Native): WIC -> D3D8 Texture Loader
-- Uses VanaCore's native `vana.soulspire.load_texture(path)` API with zero d3d8/FFI/Ashita dependencies.
-- Searches addon-local `assets/` first, then sibling Soulspire asset directories if present.

local Assets = {}
Assets.__index = Assets

function Assets.new(addon_path, install_dir)
    local clean_addon = type(addon_path) == 'string' and addon_path:gsub('[/\\]+$', '') or '.'
    local clean_install = type(install_dir) == 'string' and install_dir:gsub('[/\\]+$', '') or clean_addon:gsub('[/\\]addons[/\\]vanacore[/\\]soulspire_core$', '')
    return setmetatable({
        addon_path  = clean_addon,
        install_dir = clean_install,
        textures    = {},
        dims        = {},
        status      = {},
    }, Assets)
end

local function load_candidates(self, cache_key, candidates)
    if self.textures[cache_key] ~= nil then
        return self.textures[cache_key] ~= false and self.textures[cache_key] or nil
    end

    if not (type(vana) == 'table' and vana.soulspire and type(vana.soulspire.load_texture) == 'function') then
        self.textures[cache_key] = false
        self.status[cache_key] = 'vana.soulspire.load_texture unavailable'
        return nil
    end

    local last_err = 'not found'
    for _, full_path in ipairs(candidates) do
        local id, w, h = vana.soulspire.load_texture(full_path)
        if type(id) == 'number' and id ~= 0 then
            self.textures[cache_key] = id
            self.dims[cache_key] = { width = tonumber(w) or 0, height = tonumber(h) or 0 }
            self.status[cache_key] = 'ready'
            return id
        elseif type(w) == 'string' then
            last_err = w
        end
    end

    self.textures[cache_key] = false
    self.status[cache_key] = last_err
    return nil
end

function Assets:load_texture(name)
    if type(name) ~= 'string' or name == '' then return nil end
    local safe = name:gsub('[^%w_%-]', '')
    if safe == '' then return nil end
    return load_candidates(self, name, {
        self.addon_path .. '/assets/' .. safe .. '.png',
        self.install_dir .. '/addons/vanacore/soulspire_core/assets/' .. safe .. '.png',
        self.install_dir .. '/addons/ashita4/soulspire_core/assets/' .. safe .. '.png',
        self.install_dir .. '/addons/ashita/soulspire_core/assets/' .. safe .. '.png',
    })
end

function Assets:load_from_addon(sibling_addon, name)
    if type(sibling_addon) ~= 'string' or sibling_addon == '' or type(name) ~= 'string' or name == '' then
        return nil
    end
    local safe_addon = sibling_addon:gsub('[^%w_%-]', '')
    local safe_name  = name:gsub('[^%w_%-]', '')
    if safe_addon == '' or safe_name == '' then return nil end
    return load_candidates(self, safe_addon .. ':' .. safe_name, {
        self.addon_path .. '/assets/' .. safe_addon .. '/' .. safe_name .. '.png',
        self.addon_path .. '/assets/' .. safe_name .. '.png',
        self.install_dir .. '/addons/ashita4/' .. safe_addon .. '/assets/' .. safe_name .. '.png',
        self.install_dir .. '/addons/ashita/' .. safe_addon .. '/assets/' .. safe_name .. '.png',
    })
end

function Assets:load_path(full_path)
    if type(full_path) ~= 'string' or full_path == '' then return nil end
    return load_candidates(self, 'path:' .. full_path, { full_path })
end

function Assets:release_all()
    if type(vana) == 'table' and vana.soulspire and type(vana.soulspire.release_textures) == 'function' then
        pcall(vana.soulspire.release_textures)
    end
    self.textures = {}
    self.dims = {}
    self.status = {}
end

return Assets
