-- SoulspireXI Core: Pure-LuaJIT SHA-256 Digest (FIPS 180-4)
-- Supports both one-shot digest(msg) and incremental streaming hasher (new():update():final())
-- so large static cache packages (e.g. talents.json) can be verified cooperatively across
-- idle frames without stalling the Ashita v4 D3D render thread.

local M = {}

local okBit, bit = pcall(require, 'bit')
if not okBit or type(bit) ~= 'table' then
    bit = _G.bit
end

local band, bor, bxor, bnot, rshift, lshift, ror
if bit then
    band   = bit.band
    bor    = bit.bor
    bxor   = bit.bxor
    bnot   = bit.bnot
    rshift = bit.rshift
    lshift = bit.lshift
    ror    = bit.ror or function(x, n) return bor(rshift(x, n), lshift(x, 32 - n)) end
else
    local MOD32 = 4294967296
    local function u32(x) return x % MOD32 end
    band = function(a, b)
        a, b = u32(a), u32(b)
        local r, p = 0, 1
        while a > 0 and b > 0 do
            if a % 2 == 1 and b % 2 == 1 then r = r + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return r
    end
    bor = function(a, b)
        a, b = u32(a), u32(b)
        local r, p = 0, 1
        while a > 0 or b > 0 do
            if a % 2 == 1 or b % 2 == 1 then r = r + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return r
    end
    bxor = function(a, b)
        a, b = u32(a), u32(b)
        local r, p = 0, 1
        while a > 0 or b > 0 do
            if (a % 2) ~= (b % 2) then r = r + p end
            a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2
        end
        return r
    end
    bnot = function(a) return MOD32 - 1 - u32(a) end
    rshift = function(a, n) return math.floor(u32(a) / (2 ^ n)) end
    lshift = function(a, n) return u32(u32(a) * (2 ^ n)) end
    ror = function(a, n) return bor(rshift(a, n), lshift(a, 32 - n)) end
end

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local byte   = string.byte
local char   = string.char
local format = string.format
local floor  = math.floor
local sub    = string.sub

local function hex32(x)
    if x < 0 then x = x + 4294967296 end
    return format('%08x', x % 4294967296)
end

local function process_blocks(st, data, start_pos, end_pos)
    local h0, h1, h2, h3 = st.h0, st.h1, st.h2, st.h3
    local h4, h5, h6, h7 = st.h4, st.h5, st.h6, st.h7
    local w = st.w

    for offset = start_pos, end_pos, 64 do
        for i = 0, 15 do
            local j = offset + i * 4
            local b1, b2, b3, b4 = byte(data, j, j + 3)
            w[i + 1] = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        end
        for i = 17, 64 do
            local v1 = w[i - 15]
            local s0 = bxor(ror(v1, 7), ror(v1, 18), rshift(v1, 3))
            local v2 = w[i - 2]
            local s1 = bxor(ror(v2, 17), ror(v2, 19), rshift(v2, 10))
            w[i] = band(w[i - 16] + s0 + w[i - 7] + s1, 0xffffffff)
        end

        local a, b, c, d = h0, h1, h2, h3
        local e, f, g, h = h4, h5, h6, h7

        for i = 1, 64 do
            local S1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = band(h + S1 + ch + K[i] + w[i], 0xffffffff)
            local S0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = band(S0 + maj, 0xffffffff)

            h = g; g = f; f = e
            e = band(d + temp1, 0xffffffff)
            d = c; c = b; b = a
            a = band(temp1 + temp2, 0xffffffff)
        end

        h0 = band(h0 + a, 0xffffffff)
        h1 = band(h1 + b, 0xffffffff)
        h2 = band(h2 + c, 0xffffffff)
        h3 = band(h3 + d, 0xffffffff)
        h4 = band(h4 + e, 0xffffffff)
        h5 = band(h5 + f, 0xffffffff)
        h6 = band(h6 + g, 0xffffffff)
        h7 = band(h7 + h, 0xffffffff)
    end

    st.h0, st.h1, st.h2, st.h3 = h0, h1, h2, h3
    st.h4, st.h5, st.h6, st.h7 = h4, h5, h6, h7
end

local Hasher = {}
Hasher.__index = Hasher

function M.new()
    return setmetatable({
        h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a,
        h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19,
        w = {},
        rem = '',
        total_len = 0,
    }, Hasher)
end

-- Update incrementally over either a whole chunk string or a slice (start_idx, end_idx)
-- with zero intermediate substring copies for aligned 64-byte runs!
function Hasher:update(data, start_idx, end_idx)
    if type(data) ~= 'string' then return self end
    local s = start_idx or 1
    local e = end_idx or #data
    if s > e then return self end
    local chunk_len = e - s + 1
    self.total_len = self.total_len + chunk_len

    if #self.rem > 0 then
        local need = 64 - #self.rem
        if chunk_len < need then
            self.rem = self.rem .. sub(data, s, e)
            return self
        end
        local blk = self.rem .. sub(data, s, s + need - 1)
        process_blocks(self, blk, 1, 1)
        self.rem = ''
        s = s + need
    end

    local avail = e - s + 1
    local full_blocks = floor(avail / 64)
    if full_blocks > 0 then
        local last_block_start = s + (full_blocks - 1) * 64
        process_blocks(self, data, s, last_block_start)
        s = s + full_blocks * 64
    end
    if s <= e then
        self.rem = sub(data, s, e)
    end
    return self
end

function Hasher:final()
    local len = self.total_len
    local bit_len_hi = floor(len / 0x20000000)
    local bit_len_lo = (len * 8) % 4294967296
    local rem_len = #self.rem
    local pad_zeros = ((rem_len + 1) % 64 <= 56)
        and (56 - ((rem_len + 1) % 64))
        or (120 - ((rem_len + 1) % 64))
    local tail = self.rem .. '\128' .. string.rep('\0', pad_zeros)
        .. char(
            floor(bit_len_hi / 0x1000000) % 256,
            floor(bit_len_hi / 0x10000) % 256,
            floor(bit_len_hi / 0x100) % 256,
            bit_len_hi % 256,
            floor(bit_len_lo / 0x1000000) % 256,
            floor(bit_len_lo / 0x10000) % 256,
            floor(bit_len_lo / 0x100) % 256,
            bit_len_lo % 256
        )
    process_blocks(self, tail, 1, #tail - 63)
    self.rem = ''
    return hex32(self.h0) .. hex32(self.h1) .. hex32(self.h2) .. hex32(self.h3)
        .. hex32(self.h4) .. hex32(self.h5) .. hex32(self.h6) .. hex32(self.h7)
end

function M.digest(msg)
    if type(msg) ~= 'string' then
        return nil, 'SHA-256 input must be a string'
    end
    local h = M.new()
    h:update(msg, 1, #msg)
    return h:final()
end

return M
