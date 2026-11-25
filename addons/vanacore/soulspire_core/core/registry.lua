-- SoulspireXI Core: dynamic modular navigation registry.
-- Module names, icons, order, availability, and controllers come exclusively
-- from this registry so the unified top navigation header stays extensible
-- as new SoulspireXI modules are integrated.

local Registry = {}
Registry.__index = Registry

local okSoulReg, soulRegistry = pcall(require, 'core.soul_registry_generated')
if not okSoulReg or type(soulRegistry) ~= 'table' then soulRegistry = nil end
Registry.souls = soulRegistry

local DEFAULT_MODULES = {
    {
        id             = 'character',
        label          = 'Character',
        short_key      = 'character',
        aliases        = { 'soul', 'crystals', 'soul_crystals', 'identity' },
        icon           = 'character',
        order          = 10,
        available      = true,
        badge          = 'LIVE',
        accent         = 'violet',
        summary        = 'Inspect your active Soul Identity, job mastery profile, and socketed Soul Crystals.',
        details        = 'Powered by CrystalSocket protocol (0x11F/0x1FF CRYS) and VanaCore-native vana.soulspire diagnostics. All Soul swaps remain server-authoritative.',
        existing_addon = 'soulspire_core',
    },
    {
        id             = 'weapon_mastery',
        label          = 'Weapon Mastery',
        short_key      = 'soulforge',
        aliases        = { 'ws', 'ws_talents', 'weapons', 'forge' },
        icon           = 'weapon_mastery',
        order          = 20,
        available      = true,
        badge          = 'LIVE',
        accent         = 'gold',
        summary        = 'Forge Weapon Skill talent trees, Skillchain augment tiers, and 4-slot spec mastery in The Soulforge.',
        details        = 'Powered by shared Soulforge state and UI (0x11F/0x1FD OXTL). Supports full D-Pad, Left Stick, keyboard, and mouse navigation.',
        existing_addon = 'soulspire_talents',
    },
    {
        id             = 'soul_talents',
        label          = 'Soul Talents',
        short_key      = 'talents',
        aliases        = { 'mastery', 'soul_mastery', 'progression' },
        icon           = 'soul_talents',
        order          = 30,
        available      = true,
        badge          = 'LIVE',
        accent         = 'cyan',
        summary        = 'Review your Soul talent point ledger, active 4-WS spec loadout, invested techniques, and live Soul mechanics.',
        details        = 'Synchronizes live Soulforge point allocation with your active Soul identity and Universal Soul HUD telemetry.',
        existing_addon = 'soulspire_soulhud',
    },
    {
        id             = 'abilities',
        label          = 'Soul Actions',
        short_key      = 'abilities',
        aliases        = { 'actions', 'spells', 'soulactions' },
        icon           = 'abilities',
        order          = 40,
        available      = true,
        badge          = 'LIVE',
        accent         = 'cyan',
        summary        = 'Unified Soul Actions, spells, visibility rules, and native hook diagnostics.',
        details        = 'Powered natively by VanaCore src/core/soulspire/ action & visibility hooks (#11-#24).',
        existing_addon = 'soulspire_core',
    },
    {
        id             = 'equipment',
        label          = 'Equipment',
        short_key      = 'equipment',
        aliases        = { 'gear', 'equip' },
        icon           = 'equipment',
        order          = 50,
        available      = false,
        badge          = 'PHASE D',
        accent         = 'gold',
        summary        = 'Unified Soul-aware equipment sets and weapon presentation (Phase D).',
        details        = 'Phase D weapon presentation migration is scheduled after Core foundation certification.',
        existing_addon = 'soulspire_core',
    },
    {
        id             = 'journal',
        label          = 'Diagnostics',
        short_key      = 'diag',
        aliases        = { 'journal', 'diagnostics', 'status', 'mobs', 'flintlock' },
        icon           = 'journal',
        order          = 60,
        available      = true,
        badge          = 'LIVE',
        accent         = 'cyan',
        summary        = 'Live VanaCore-native diagnostics, Mob Status (0x1FE/[OXMOB]), and Flintlock state.',
        details        = 'Exposes real-time vana.soulspire hook matrix, texture cache, UI input ownership, and packet telemetry.',
        existing_addon = 'soulspire_core',
    },
}

local function copy_list(src)
    if type(src) ~= 'table' then return {} end
    local out = {}
    for i, v in ipairs(src) do out[i] = v end
    return out
end

local function copy_module(src, insert_seq)
    local dst = {}
    for k, v in pairs(src) do
        if k == 'aliases' then
            dst[k] = copy_list(v)
        else
            dst[k] = v
        end
    end
    dst.aliases = dst.aliases or {}
    dst.icon = dst.icon or dst.id
    dst.order = tonumber(dst.order) or (insert_seq * 10)
    if dst.available == nil then
        dst.available = (dst.badge ~= 'UNAVAILABLE' and dst.badge ~= 'PLACEHOLDER')
    else
        dst.available = (dst.available == true)
    end
    dst.badge = dst.badge or (dst.available and 'LIVE' or 'UNAVAILABLE')
    dst._seq = insert_seq
    return dst
end

function Registry.new(initial_modules)
    local self = setmetatable({
        _ordered = {},
        _by_id   = {},
        _seq     = 0,
    }, Registry)
    local list = initial_modules or DEFAULT_MODULES
    for _, mod in ipairs(list) do
        self:register(mod)
    end
    return self
end

function Registry:_rebuild_index()
    table.sort(self._ordered, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return (a._seq or 0) < (b._seq or 0)
    end)
    self._by_id = {}
    for idx, entry in ipairs(self._ordered) do
        self._by_id[entry.id] = idx
    end
end

function Registry:register(mod)
    assert(type(mod) == 'table' and type(mod.id) == 'string' and mod.id ~= '',
        'Module requires a non-empty string id')
    assert(type(mod.label) == 'string' and mod.label ~= '',
        'Module requires a non-empty string label')

    local existing_idx = self._by_id[mod.id]
    local seq = existing_idx and self._ordered[existing_idx]._seq or (self._seq + 1)
    if not existing_idx then
        self._seq = seq
    end

    local entry = copy_module(mod, seq)
    if existing_idx then
        -- Preserve attached controller unless explicitly replaced
        if entry.controller == nil and self._ordered[existing_idx].controller ~= nil then
            entry.controller = self._ordered[existing_idx].controller
        end
        self._ordered[existing_idx] = entry
    else
        self._ordered[#self._ordered + 1] = entry
    end
    self:_rebuild_index()
    return self._by_id[entry.id]
end

function Registry:unregister(id)
    local idx = self._by_id[id]
    if not idx then return false end
    table.remove(self._ordered, idx)
    self:_rebuild_index()
    return true
end

function Registry:attach_controller(id, controller, available)
    local idx = self._by_id[id]
    if not idx then return false end
    local entry = self._ordered[idx]
    entry.controller = controller
    if available ~= nil then
        entry.available = (available == true)
        entry.badge = entry.available and 'LIVE' or 'UNAVAILABLE'
    end
    return true
end

function Registry:set_available(id, available, reason)
    local idx = self._by_id[id]
    if not idx then return false end
    local entry = self._ordered[idx]
    entry.available = (available == true)
    entry.badge = entry.available and 'LIVE' or 'UNAVAILABLE'
    if type(reason) == 'string' and reason ~= '' then
        entry.unavailable_reason = reason
    end
    return true
end

function Registry:sections()
    return self._ordered
end

Registry.modules = Registry.sections

function Registry:available_modules()
    local out = {}
    for _, entry in ipairs(self._ordered) do
        if entry.available then
            out[#out + 1] = entry
        end
    end
    return out
end

function Registry:count()
    return #self._ordered
end

function Registry:get(index)
    return self._ordered[index]
end

function Registry:get_by_id(id)
    local idx = self._by_id[id]
    return idx and self._ordered[idx] or nil
end

function Registry:index_of(id)
    return self._by_id[id]
end

-- Step module index forward/backward with wrap-around; optionally skip unavailable modules.
function Registry:step_index(current_idx, delta, skip_unavailable)
    local n = #self._ordered
    if n == 0 then return nil end
    local cur = tonumber(current_idx) or 1
    if cur < 1 or cur > n then cur = 1 end
    local step = (delta and delta < 0) and -1 or 1

    for _ = 1, n do
        cur = ((cur - 1 + step) % n) + 1
        if not skip_unavailable or self._ordered[cur].available then
            return cur
        end
    end
    return current_idx
end

function Registry:find_index(query)
    if type(query) ~= 'string' or query == '' then return nil end
    local q = query:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if self._by_id[q] then return self._by_id[q] end
    for idx, entry in ipairs(self._ordered) do
        if entry.short_key and entry.short_key:lower() == q then
            return idx
        end
        if entry.label:lower() == q then
            return idx
        end
        for _, alias in ipairs(entry.aliases or {}) do
            if tostring(alias):lower() == q then
                return idx
            end
        end
    end
    for idx, entry in ipairs(self._ordered) do
        if entry.id:lower():find(q, 1, true) or entry.label:lower():find(q, 1, true) then
            return idx
        end
    end
    return nil
end

return Registry
