-- SoulspireXI Core: verified project asset loader (D3D8 texture helper).
-- Loads addons/ashita4/soulspire_core/assets/soulspire_crest.png and sibling addon
-- assets (e.g., crystalsocket/assets/*.png, soulspire_talents/assets/*.png) with
-- graceful fallback when D3D8 is absent or an icon file is missing.

local Assets = {}
Assets.__index = Assets

function Assets.new(addon_path)
    return setmetatable({
        addon_path = addon_path,
        textures = {},
        status = {},
    }, Assets)
end

local function load_texture_from_path(self, cache_key, full_path)
    if self.textures[cache_key] ~= nil then
        return self.textures[cache_key] ~= false and self.textures[cache_key].id or nil
    end

    local ok, status, tex, id = pcall(function()
        local ffi = require('ffi')
        local d3d8 = require('d3d8')
        local file = io.open(full_path, 'rb')
        if not file then return 'file unavailable', nil, nil end
        local data = file:read('*a')
        file:close()
        if not data or #data == 0 then return 'file unreadable', nil, nil end

        local out = ffi.new('IDirect3DTexture8*[1]')
        local hr = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
            d3d8.get_device(), data, #data,
            0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
            ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED,
            ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0,
            nil, nil, out
        )
        if hr ~= ffi.C.S_OK or out[0] == nil then
            if out[0] ~= nil then out[0]:Release() end
            return 'texture failed (' .. tostring(hr) .. ')', nil, nil
        end
        return 'ready', out[0], tonumber(ffi.cast('uint32_t', out[0]))
    end)

    if ok and tex and id then
        self.textures[cache_key] = { ptr = tex, id = id }
        self.status[cache_key] = 'ready'
        return id
    end

    self.textures[cache_key] = false
    self.status[cache_key] = ok and status or 'd3d8 unavailable'
    return nil
end

function Assets:load_texture(name)
    if type(name) ~= 'string' or name == '' then return nil end
    if type(self.addon_path) ~= 'string' or self.addon_path == '' then
        self.status[name] = 'addon path unavailable'
        return nil
    end
    local safe = name:gsub('[^%w_%-]', '')
    if safe == '' then return nil end
    local full_path = self.addon_path:gsub('[/\\]+$', '') .. '/assets/' .. safe .. '.png'
    return load_texture_from_path(self, name, full_path)
end

-- Load a PNG asset from a sibling Ashita v4 addon without duplicating asset files.
function Assets:load_from_addon(sibling_addon, name)
    if type(sibling_addon) ~= 'string' or sibling_addon == '' or type(name) ~= 'string' or name == '' then
        return nil
    end
    if type(self.addon_path) ~= 'string' or self.addon_path == '' then return nil end
    local safe_addon = sibling_addon:gsub('[^%w_%-]', '')
    local safe_name  = name:gsub('[^%w_%-]', '')
    if safe_addon == '' or safe_name == '' then return nil end
    local root = self.addon_path:gsub('[/\\]+$', ''):gsub('[/\\][^/\\]+$', '')
    local full_path = root .. '/' .. safe_addon .. '/assets/' .. safe_name .. '.png'
    return load_texture_from_path(self, safe_addon .. ':' .. safe_name, full_path)
end

function Assets:release_all()
    for name, entry in pairs(self.textures) do
        if type(entry) == 'table' and entry.ptr then
            pcall(function() entry.ptr:Release() end)
        end
        self.textures[name] = nil
    end
    self.status = {}
end

return Assets
