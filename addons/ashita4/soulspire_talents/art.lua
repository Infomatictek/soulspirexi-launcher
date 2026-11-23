-- SoulspireXI Talent Art Loader (Ashita v4 / Direct3D8)
-- Optional PNG assets. All missing or invalid assets render as graceful fallbacks.
local ffi = require('ffi')
local d3d8 = require('d3d8')
local A = { textures = {}, status = {}, root = nil }

local function validName(name)
    return type(name) == 'string' and name:match('^[%w_%-]+$') ~= nil
end

function A.setRoot(path)
    if type(path) == 'string' and path ~= '' then
        A.root = path:gsub('[/\\]+$', '')
    else
        A.root = nil
    end
end

function A.get(name)
    if not validName(name) then return nil end
    local cached = A.textures[name]
    if cached ~= nil then
        return tonumber(ffi.cast('uint32_t', cached))
    end
    if A.status[name] ~= nil then return nil end
    local ok, why, texture = pcall(function()
        local base = A.root
        if type(base) ~= 'string' or base == '' then
            if type(addon) == 'table' and type(addon.path) == 'string' then
                base = addon.path:gsub('[/\\]+$', '')
            end
        end
        if type(base) ~= 'string' or base == '' then return 'no addon path', nil end
        local filename = base .. '/assets/' .. name .. '.png'
        local f = io.open(filename, 'rb')
        if not f then return 'missing', nil end
        local bytes = f:read('*a')
        f:close()
        if not bytes or #bytes == 0 then return 'empty file', nil end
        local out = ffi.new('IDirect3DTexture8*[1]')
        local hr = ffi.C.D3DXCreateTextureFromFileInMemoryEx(
            d3d8.get_device(), bytes, #bytes,
            0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
            ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED,
            ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT,
            0, nil, nil, out)
        if hr ~= ffi.C.S_OK or out[0] == nil then
            if out[0] ~= nil then out[0]:Release() end
            return 'Direct3D loading failed: ' .. tostring(hr), nil
        end
        return 'ready', out[0]
    end)
    if ok and texture then
        A.textures[name] = texture
        A.status[name] = 'ready'
        return tonumber(ffi.cast('uint32_t', texture))
    end
    A.status[name] = ok and why or 'D3D API unavailable'
    return nil
end

function A.draw(dl, name, x, y, w, h, tint)
    if dl == nil or w <= 0 or h <= 0 then return false end
    local id = A.get(name)
    if id == nil then return false end
    dl:AddImage(id, { x, y }, { x + w, y + h },
        { 0, 0 }, { 1, 1 }, tint or 0xFFFFFFFF)
    return true
end

function A.clear()
    for name, texture in pairs(A.textures) do
        pcall(function() texture:Release() end)
        A.textures[name] = nil
    end
    A.status = {}
end

return A
