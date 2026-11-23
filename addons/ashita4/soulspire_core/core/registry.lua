-- SoulspireXI Core: modular section registry.
-- Phase 1A registers the 7 foundation sections as clearly labeled placeholders.
-- Subsequent phases can replace individual section renderers without rewriting
-- the Core shell, navigation state machine, or menu bridge.

local Registry = {}
Registry.__index = Registry

local okSoulReg, soulRegistry = pcall(require, 'core.soul_registry_generated')
if not okSoulReg or type(soulRegistry) ~= 'table' then soulRegistry = nil end
Registry.souls = soulRegistry

local DEFAULT_SECTIONS = {
    {
        id = 'soul_crystals',
        label = 'Soul Crystals',
        short_key = 'crystals',
        badge = 'PLACEHOLDER',
        accent = 'gold',
        summary = 'Socket, inspect, and switch job-specific Soul Crystals.',
        details = 'Phase 1A placeholder. Existing CrystalSocket addon remains active in the native Equipment menu and continues syncing native job labels and weapon rules via soulspire_native.dll.',
        existing_addon = 'crystalsocket',
    },
    {
        id = 'ws_talents',
        label = 'Weapon Skill Talents',
        short_key = 'talents',
        badge = 'PLACEHOLDER',
        accent = 'cyan',
        summary = 'Browse and allocate Weapon Skill evolution and talent trees.',
        details = 'Phase 1A placeholder. Existing soulspire_talents addon remains active and untouched until the dedicated migration milestone.',
        existing_addon = 'soulspire_talents',
    },
    {
        id = 'soul_mastery',
        label = 'Soul Mastery',
        short_key = 'mastery',
        badge = 'PLACEHOLDER',
        accent = 'gold',
        summary = 'Review Soul progression, active Soul Actions, and mastery milestones.',
        details = 'Phase 1A placeholder. Existing soulspire_soulhud and soulspire_soul_actions addons remain active with full native action visibility and naming.',
        existing_addon = 'soulspire_soul_actions',
    },
    {
        id = 'combat_records',
        label = 'Combat Records',
        short_key = 'records',
        badge = 'PLACEHOLDER',
        accent = 'cyan',
        summary = 'View personal encounters, combat logs, and Soul performance metrics.',
        details = 'Phase 1A placeholder. Existing metrics addon and server combat analytics remain active and independent.',
        existing_addon = 'metrics',
    },
    {
        id = 'expeditions',
        label = 'Expeditions',
        short_key = 'expeditions',
        badge = 'PLACEHOLDER',
        accent = 'gold',
        summary = 'Track SoulspireXI custom expeditions, delves, and seasonal objectives.',
        details = 'Phase 1A placeholder. Reserved for future unified expedition tracking and party readiness tools.',
        existing_addon = nil,
    },
    {
        id = 'player_guides',
        label = 'Player Guides',
        short_key = 'guides',
        badge = 'PLACEHOLDER',
        accent = 'cyan',
        summary = 'In-game reference for Soul mechanics, weapon rules, and server systems.',
        details = 'Phase 1A placeholder. Reserved for concise in-client Soul guides synchronized with server design contracts.',
        existing_addon = nil,
    },
    {
        id = 'settings',
        label = 'Settings',
        short_key = 'settings',
        badge = 'PLACEHOLDER',
        accent = 'gold',
        summary = 'Configure SoulspireXI Core menu integration, navigation, and HUD preferences.',
        details = 'Phase 1A placeholder. Displays current integration mode (native-styled Main Menu fallback) and navigation bindings.',
        existing_addon = nil,
    },
}

local function copy_section(src)
    local dst = {}
    for k, v in pairs(src) do
        dst[k] = v
    end
    return dst
end

function Registry.new(initial_sections)
    local self = setmetatable({
        _ordered = {},
        _by_id = {},
    }, Registry)
    local list = initial_sections or DEFAULT_SECTIONS
    for _, sec in ipairs(list) do
        self:register(sec)
    end
    return self
end

function Registry:register(section)
    assert(type(section) == 'table' and type(section.id) == 'string' and section.id ~= '',
        'Section requires a non-empty string id')
    assert(type(section.label) == 'string' and section.label ~= '',
        'Section requires a non-empty string label')

    local entry = copy_section(section)
    local existing_idx = self._by_id[entry.id]
    if existing_idx then
        self._ordered[existing_idx] = entry
        return existing_idx
    end
    local idx = #self._ordered + 1
    self._ordered[idx] = entry
    self._by_id[entry.id] = idx
    return idx
end

function Registry:sections()
    return self._ordered
end

function Registry:count()
    return #self._ordered
end

function Registry:get(index)
    return self._ordered[index]
end

function Registry:find_index(query)
    if type(query) ~= 'string' or query == '' then return nil end
    local q = query:lower():gsub('^%s+', ''):gsub('%s+$', '')
    if self._by_id[q] then return self._by_id[q] end
    for idx, sec in ipairs(self._ordered) do
        if (sec.short_key and sec.short_key:lower() == q)
            or sec.label:lower() == q
            or sec.id:lower():find(q, 1, true)
            or sec.label:lower():find(q, 1, true) then
            return idx
        end
    end
    return nil
end

return Registry
