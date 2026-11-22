-- SoulspireXI Core: verified project asset loader (D3D8 texture helper).
-- Loads addons/ashita4/soulspire_core/assets/soulspire_crest.png (copied from
-- SoulspireLauncher/Assets/app.png) with graceful fallback when D3D8 is absent.

local Assets = {}
Assets.__index = Assets

function Assets.new(addon_path)
    return setmetatable({
        addon_path = addon_path,
        textures = {},
        status = {},
    }, Assets)
end

function Assets:load_texture(name)
    if type(name) ~= 'string' or name == '' then return nil end
    if self.textures[name] ~= nil then
        return self.textures[name] ~= false and self.textures[name].id or nil
    end

    local ok, status, tex, id = pcall(function()
        local ffi = require('ffi')
        local d3d8 = require('d3d8')
        if type(self.addon_path) ~= 'string' or self.addon_path == '' then
            return 'addon path unavailable', nil, nil
        end
        local safe = name:gsub('[^%w_%-]', '')
        if safe == '' then return 'invalid asset name', nil, nil end
        local full_path = self.addon_path:gsub('[/\\]+$', '') .. '/assets/' .. safe .. '.png'
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
        self.textures[name] = { ptr = tex, id = id }
        self.status[name] = 'ready'
        return id
    end

    self.textures[name] = false
    self.status[name] = ok and status or 'd3d8 unavailable'
    return nil
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
