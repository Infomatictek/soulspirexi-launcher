#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include "core/api.h"
#include "core/config.h"
#include "core/state.h"
#include "diagnostics/diagnostics.h"
#include "job_identity/job_identity.h"
#include "actions/action_catalog.h"
#include "equipment/weapon_rules.h"
#include "rendering/menu2fon.h"
#include "menus/menu_hooks.h"
#include "resources/resource_manager.h"
#include "dat_virtualization/dat_virtualization.h"
#include "hooks/layout.h"
#include "hooks/hook_manager.h"
#include "compatibility/crystaljobs_compat.h"
#include "core/plugin.h"

#include <atomic>
#include <cstdio>
#include <cwchar>
#include <memory>
#include <new>

using namespace soulspire::native;

static SRWLOCK state_lock = SRWLOCK_INIT;
static SRWLOCK action_lock = SRWLOCK_INIT;
static SRWLOCK visibility_lock = SRWLOCK_INIT;
static SRWLOCK weapon_lock = SRWLOCK_INIT;
static SRWLOCK lifecycle_lock = SRWLOCK_INIT;
static SRWLOCK menu2fon_lock = SRWLOCK_INIT;

static State state;
static Transport transport;
static ActionCatalog action_catalog;
static VisibilityCatalog visibility_catalog;
static WeaponRuleCatalog weapon_rule_catalog;
static DatVirtualizationManager dat_virt_mgr;
static ActiveSoulOverride soul_override;
static HookDiagnosticsState hook_diag;
static bool ever_started = false;
static HMODULE g_self_module = nullptr;

static std::atomic<uint32_t> last_error{};
static std::atomic<bool> enabled{};
static std::atomic<uint32_t> decoded_rows{}, short_draws{}, full_lookups{}, item_lookups{};
static std::atomic<uint32_t> magic_name_hits{}, magic_desc_hits{}, magic_icon_hits{};
static std::atomic<uint32_t> ability_name_hits{}, ability_desc_hits{}, ability_icon_hits{};
static std::atomic<uint32_t> magic_hidden_count{}, magic_shown_count{}, ability_hidden_count{};
static std::atomic<uint32_t> weapon_allow_hits{}, weapon_deny_hits{};
static std::atomic<uint32_t> action_row_max_chars{16};
static std::atomic<uint32_t> g_menu2fon_banks_used{0};
static std::atomic<uint32_t> g_menu2fon_fallback_draws{0};

using Lookup = const char* (__cdecl*)(int, int);
using Decode = void* (__cdecl*)(const uint8_t*, uint8_t*, int);
using Encode = int (__cdecl*)(const void*, uint8_t*);
using NativeText = int (__cdecl*)(int, int, const char*, uint32_t, float, float, int);
using DrawSprite = int (__fastcall*)(void*, void*, int, int, float, float, uint32_t, int, int, int);
using ActionIcon = void* (__cdecl*)(uint32_t, uint32_t);
using GetInventoryItem = const uint8_t* (__cdecl*)(uint32_t, uint32_t);
using GetItemResource = const uint8_t* (__fastcall*)(void*, void*, uint32_t);
using CanEquipItemInSlot = uint8_t (__fastcall*)(void*, void*, const uint8_t*, uint32_t);
using MapDecode = int (__cdecl*)(uint8_t*, uint32_t, uintptr_t, uintptr_t, const uint8_t*, uint32_t);
using MapEncode = int (__cdecl*)(const uint8_t*, uint32_t, uint8_t*, uint32_t, uintptr_t);

static Lookup original_lookup = nullptr;
static Decode original_decode = nullptr;
static Encode original_encode = nullptr;
static NativeText native_text = nullptr;
static ActionIcon original_action_icon = nullptr;
static CanShowSpell original_can_show_spell = nullptr;
static GetInventoryItem original_get_inv_item = nullptr;
static GetItemResource original_get_item_res = nullptr;
static CanEquipItemInSlot original_can_equip_in_slot = nullptr;
static MapDecode original_map_decode = nullptr;
static MapEncode original_map_encode = nullptr;

static uintptr_t original_sprite = 0;
static uintptr_t original_sprite_simple = 0;
static uintptr_t original_spell_name = 0;
static uintptr_t original_spell_desc = 0;
static uintptr_t original_ability_name_row = 0;
static uintptr_t original_ability_name_target = 0;
static uintptr_t original_ability_desc = 0;
static uintptr_t original_set_list_count = 0;
static uintptr_t original_spell_elig = 0;
static uintptr_t missing_spell_bit_resume = 0;
static uintptr_t soul_sub_weapon_allow_resume = 0;
static uintptr_t soul_sub_weapon_deny_resume = 0;
static uintptr_t soul_sub_menu_allow_resume = 0;
static uintptr_t soul_sub_menu_skip_resume = 0;
static uintptr_t soul_sub_2h_main_allow_resume = 0;
static uintptr_t soul_sub_2h_main_deny_resume = 0;

static void** pname_sheet_slot = nullptr;
static void** item_res_mgr_slot = nullptr;
static const uint8_t* main_job_slot = nullptr;
static const uint8_t* main_lvl_slot = nullptr;
static uint8_t** ability_list_slot = nullptr;

static thread_local int32_t tls_magic_row_id = -1;
static thread_local int32_t tls_ability_row_id = -1;
static thread_local char tls_action_name[80]{};
static thread_local char tls_action_desc[192]{};
static thread_local char tls_action_desc_fmt[192]{};
static thread_local char tls_action_row[80]{};

#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
static bool selftest_alive = false;
static bool selftest_simulate_legacy_conflict = false;
#endif

static bool module_enabled(uint32_t mod_id) noexcept {
    const SearchPresentationConfig& cfg = active_search_presentation();
    return (cfg.enabled_modules_mask & (1u << mod_id)) != 0;
}

static bool alive() noexcept {
#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
    return selftest_alive;
#else
    if (!enabled.load(std::memory_order_acquire)) return false;
    AcquireSRWLockShared(&state_lock);
    const bool valid = state.alive(GetTickCount(), transport.character, transport.job);
    ReleaseSRWLockShared(&state_lock);
    return valid;
#endif
}

static bool session_alive() noexcept {
#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
    return selftest_alive;
#else
    if (!enabled.load(std::memory_order_acquire)) return false;
    AcquireSRWLockShared(&state_lock);
    const bool valid = transport.character != 0 && transport.job >= 1 && transport.job <= 23;
    ReleaseSRWLockShared(&state_lock);
    return valid;
#endif
}

// ============================================================================
// JobIdentity & Search Hooks (Hooks #1 - #10)
// ============================================================================

static const char* __cdecl item_label(int table, int job) noexcept {
    if (table == 2 && job >= 1 && job <= 23 && module_enabled(SOULSPIRE_NATIVE_MOD_JOB_IDENTITY) && alive()) {
        AcquireSRWLockShared(&state_lock);
        const uint8_t branch = (state.known && state.job == static_cast<uint8_t>(job)) ? state.branch : 0;
        ReleaseSRWLockShared(&state_lock);
        if (const char* custom = label_for(static_cast<uint8_t>(job), branch, false)) {
            ++item_lookups;
            return custom;
        }
    }
    return original_lookup(table, job);
}

static int __cdecl encode_request(const void* filters, uint8_t* payload) noexcept {
    const int result = original_encode(filters, payload);
    if (module_enabled(SOULSPIRE_NATIVE_MOD_JOB_IDENTITY) && session_alive()) {
        std::memcpy(payload - 4, &capability, 4);
        AcquireSRWLockExclusive(&state_lock);
        state.clear_rows();
        ReleaseSRWLockExclusive(&state_lock);
    }
    return result;
}

static void* __cdecl decode_row(const uint8_t* input, uint8_t* output, int flags) noexcept {
    void* result = original_decode(input, output, flags);
    AcquireSRWLockExclusive(&state_lock);
    if (enabled.load(std::memory_order_acquire) && module_enabled(SOULSPIRE_NATIVE_MOD_JOB_IDENTITY)) {
        state.decoded(output);
    } else if (output != nullptr && (u32(output + 20) & 0xffffff00u) == marker) {
        std::memset(output + 20, 0, 4);
    }
    ReleaseSRWLockExclusive(&state_lock);
    ++decoded_rows;
    return result;
}

static uint8_t branch_for(const uint8_t* row) noexcept {
    if (!session_alive() || !module_enabled(SOULSPIRE_NATIVE_MOD_JOB_IDENTITY)) return 0;
    AcquireSRWLockShared(&state_lock);
    const uint8_t branch = state.row_branch(row);
    ReleaseSRWLockShared(&state_lock);
    return branch;
}

#if SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 1
static std::unique_ptr<Menu2fonBank> g_menu2fon_banks[kMaxMenu2fonBanks]{};
static size_t g_last_menu2fon_bank = 0;

#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
static void reset_menu2fon_banks_for_test() noexcept {
    AcquireSRWLockExclusive(&menu2fon_lock);
    for (size_t bi = 0; bi < kMaxMenu2fonBanks; ++bi) {
        g_menu2fon_banks[bi].reset();
    }
    g_last_menu2fon_bank = 0;
    g_menu2fon_banks_used.store(0, std::memory_order_relaxed);
    g_menu2fon_fallback_draws.store(0, std::memory_order_relaxed);
    ReleaseSRWLockExclusive(&menu2fon_lock);
}
#endif

static bool draw_menu2fon_label(const char* custom, const SpriteArgs* args) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING)) return false;
    if (pname_sheet_slot == nullptr || original_sprite == 0 || custom == nullptr || args == nullptr) return false;
    auto* sheet = static_cast<uint8_t***>(*pname_sheet_slot);
    if (sheet == nullptr || *sheet == nullptr) return false;
    const uint8_t* src_sprite = (*sheet)[1]; // WAR sprite (1 tile on 'menu    menu2fon') — read-only template!
    if (src_sprite == nullptr || *reinterpret_cast<const uint32_t*>(src_sprite + 0x14) != 1) return false;
    const uint8_t* src_node = *reinterpret_cast<uint8_t* const*>(src_sprite + 0x04);
    if (src_node == nullptr) return false;
    const uint8_t* src_tile = *reinterpret_cast<uint8_t* const*>(src_node + 0x10);
    if (src_tile == nullptr) return false;
    for (int i = 0; i < 3; ++i) {
        if (custom[i] < 'A' || custom[i] > 'Z') return false;
    }

    GlyphSlot* slots[3]{};
    AcquireSRWLockExclusive(&menu2fon_lock);
    Menu2fonBank* bank = nullptr;
    if (g_last_menu2fon_bank < kMaxMenu2fonBanks &&
        g_menu2fon_banks[g_last_menu2fon_bank] != nullptr &&
        g_menu2fon_banks[g_last_menu2fon_bank]->active &&
        menu2fon_key_matches(g_menu2fon_banks[g_last_menu2fon_bank]->key, src_sprite, src_node, src_tile)) {
        bank = g_menu2fon_banks[g_last_menu2fon_bank].get();
    } else {
        for (size_t bi = 0; bi < kMaxMenu2fonBanks; ++bi) {
            if (g_menu2fon_banks[bi] != nullptr &&
                g_menu2fon_banks[bi]->active &&
                menu2fon_key_matches(g_menu2fon_banks[bi]->key, src_sprite, src_node, src_tile)) {
                bank = g_menu2fon_banks[bi].get();
                g_last_menu2fon_bank = bi;
                break;
            }
        }
        if (bank == nullptr) {
            for (size_t bi = 0; bi < kMaxMenu2fonBanks; ++bi) {
                if (g_menu2fon_banks[bi] == nullptr) {
                    auto fresh = std::unique_ptr<Menu2fonBank>(new (std::nothrow) Menu2fonBank{});
                    if (fresh == nullptr) break;
                    fresh->active = true;
                    fresh->key.src_sprite = src_sprite;
                    fresh->key.src_node = src_node;
                    fresh->key.src_tile = src_tile;
                    std::memcpy(fresh->key.sprite_bytes, src_sprite, sizeof(fresh->key.sprite_bytes));
                    std::memcpy(fresh->key.node_bytes, src_node, sizeof(fresh->key.node_bytes));
                    std::memcpy(fresh->key.tile_header_bytes, src_tile, sizeof(fresh->key.tile_header_bytes));
                    bank = fresh.get();
                    g_menu2fon_banks[bi] = std::move(fresh);
                    g_last_menu2fon_bank = bi;
                    g_menu2fon_banks_used.fetch_add(1, std::memory_order_relaxed);
                    break;
                }
            }
        }
    }
    if (bank == nullptr) {
        ReleaseSRWLockExclusive(&menu2fon_lock);
        g_menu2fon_fallback_draws.fetch_add(1, std::memory_order_relaxed);
        return false; // Safe capacity exhausted: never recycle live slots; caller falls back to native_text.
    }

    const SearchPresentationConfig& pres = active_search_presentation();
    const uint8_t widths[3] = {
        menu_glyphs[static_cast<size_t>(custom[0] - 'A')].w,
        menu_glyphs[static_cast<size_t>(custom[1] - 'A')].w,
        menu_glyphs[static_cast<size_t>(custom[2] - 'A')].w,
    };
    int16_t x0s[3]{};
    compute_search_glyph_positions(widths, pres, x0s);

    for (int i = 0; i < 3; ++i) {
        const size_t letter = static_cast<size_t>(custom[i] - 'A');
        const size_t x_idx = static_cast<size_t>(x0s[i] - kMinGlyphX0);
        if (!bank->initialized[x_idx][letter]) {
            init_glyph_slot(bank->slots[x_idx][letter], src_sprite, src_node, src_tile, x0s[i], letter);
            bank->initialized[x_idx][letter] = true;
        }
        slots[i] = &bank->slots[x_idx][letter];
    }
    ReleaseSRWLockExclusive(&menu2fon_lock);

    const auto draw_sprite = reinterpret_cast<DrawSprite>(original_sprite);
    for (int i = 0; i < 3; ++i) {
        draw_sprite(slots[i]->sprite, nullptr, args->x, args->y, args->scale_x, args->scale_y,
                    args->color, args->center, args->first, args->count);
    }
    return true;
}
#endif // SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 1

#if SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 2
static void draw_aligned_native_text_label(const char* custom, const SpriteArgs* args) noexcept {
    if (custom[0] >= 0x21 && custom[0] <= 0x7E &&
        custom[1] >= 0x21 && custom[1] <= 0x7E &&
        custom[2] >= 0x21 && custom[2] <= 0x7E &&
        custom[3] == '\0') {
        const float sx = 0.72f * args->scale_x;
        const float sy = 0.78f * args->scale_y;
        const int y = args->y + static_cast<int>(1.0f * args->scale_y + 0.5f);
        for (int i = 0; i < 3; ++i) {
            const char glyph[2] = {custom[i], '\0'};
            const int x = args->x + static_cast<int>(static_cast<float>(i) * 7.5f * args->scale_x + 0.5f);
            native_text(x, y, glyph, args->color, sx, sy, 0);
        }
        return;
    }
    native_text(args->x, args->y, custom, args->color, 0.75f * args->scale_x, 0.75f * args->scale_y, 0);
}
#endif

static bool __stdcall draw_branch(const uint8_t* row, const SpriteArgs* args) noexcept {
    const uint8_t branch = branch_for(row);
    if (branch == 0 || row == nullptr || args == nullptr || native_text == nullptr) return false;
    const char* custom = label_for(row[32], branch, false);
    if (custom == nullptr) return false;
#if SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 0
    native_text(args->x, args->y, custom, args->color, 0.75f * args->scale_x, 0.75f * args->scale_y, 0);
#elif SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 1
    if (!draw_menu2fon_label(custom, args)) {
        native_text(args->x, args->y, custom, args->color, 0.75f * args->scale_x, 0.75f * args->scale_y, 0);
    }
#else
    draw_aligned_native_text_label(custom, args);
#endif
    ++short_draws;
    return true;
}

static const char* __stdcall full_branch(const uint8_t* row, int table, int job) noexcept {
    if (table == 18 && row != nullptr && job >= 1 && job <= 23 && row[32] == static_cast<uint8_t>(job)) {
        const uint8_t branch = branch_for(row);
        if (const char* custom = label_for(static_cast<uint8_t>(job), branch, true)) {
            ++full_lookups;
            return custom;
        }
    }
    return original_lookup(table, job);
}

static __declspec(naked) void normal_sprite_hook() {
    __asm {
        pushad
        lea eax, [esp + 36]
        push eax
        push ebp
        call draw_branch
        test al, al
        jz stock
        popad
        ret 32
    stock:
        popad
        jmp dword ptr [original_sprite]
    }
}

static __declspec(naked) void master_sprite_hook() {
    __asm {
        pushad
        lea eax, [esp + 36]
        push eax
        push edi
        call draw_branch
        test al, al
        jz stock
        popad
        ret 32
    stock:
        popad
        jmp dword ptr [original_sprite]
    }
}

static bool local_persona_branch(uint8_t job, uint8_t& branch) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_JOB_IDENTITY)) return false;
#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
    if (!selftest_alive) return false;
#else
    if (!enabled.load(std::memory_order_acquire)) return false;
#endif
    AcquireSRWLockShared(&state_lock);
    const bool valid = state.known && state.from_bridge
        && state.character != 0 && state.job == job
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
        && state.character == transport.character && transport.job == job
#endif
        ;
    const uint8_t candidate = valid ? state.branch : 0;
    ReleaseSRWLockShared(&state_lock);
    if (!valid_branch(job, candidate)) return false;
    branch = candidate;
    return true;
}

static bool __stdcall draw_persona_job(const SimpleSpriteArgs* args) noexcept {
    if (args == nullptr || main_job_slot == nullptr || native_text == nullptr) return false;
    const uint8_t job = *main_job_slot;
    if (job < 1 || job > 23) return false;
    uint8_t branch = 0;
    if (!local_persona_branch(job, branch)) return false;
    const char* custom = label_for(job, branch, true);
    if (custom == nullptr) return false;
    native_text(args->x, args->y, custom, args->color, 1.0f, 1.0f, 0);
    ++full_lookups;
    return true;
}

static __declspec(naked) void persona_job_hook() {
    __asm {
        pushad
        lea eax, [esp + 36]
        push eax
        call draw_persona_job
        test al, al
        jz stock
        popad
        ret 20
    stock:
        popad
        jmp dword ptr [original_sprite_simple]
    }
}

// Resolves active local Soul for Actions and Equipment hooks.
// Prevents stale soul_override leakage when the authoritative bridge explicitly
// confirms unsocketed state (known=true, from_bridge=true, branch=0).
static bool active_action_soul(uint8_t& out_job, uint8_t& out_branch, uint32_t* out_source = nullptr) noexcept {
#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
    if (!selftest_alive) return false;
#else
    if (!enabled.load(std::memory_order_acquire)) return false;
#endif
    const uint8_t live_job = (main_job_slot != nullptr) ? *main_job_slot : 0;
    if (main_job_slot != nullptr && (live_job < 1 || live_job > 22)) return false;

    AcquireSRWLockShared(&state_lock);
    const bool bridge_matched_session = state.known && state.from_bridge && state.character != 0
        && (live_job == 0 || state.job == live_job)
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
        && state.character == transport.character && transport.job == state.job
#endif
        ;
    const bool bridge_ok = bridge_matched_session && valid_branch(state.job, state.branch);
    const bool bridge_explicitly_unsocketed = bridge_matched_session && state.branch == 0;
    const uint8_t bridge_job = state.job;
    const uint8_t bridge_branch = state.branch;

    const bool override_ok = !bridge_ok && !bridge_explicitly_unsocketed && soul_override.active
        && valid_branch(soul_override.job, soul_override.branch)
        && (live_job == 0 || soul_override.job == live_job)
        && (transport.character == 0 || soul_override.character == 0 || soul_override.character == transport.character);
    const uint8_t ov_job = soul_override.job;
    const uint8_t ov_branch = soul_override.branch;
    ReleaseSRWLockShared(&state_lock);

    if (bridge_ok) {
        out_job = bridge_job;
        out_branch = bridge_branch;
        if (out_source) *out_source = 1;
        return true;
    }
    if (override_ok) {
        out_job = ov_job;
        out_branch = ov_branch;
        if (out_source) *out_source = 2;
        return true;
    }
    return false;
}

// ============================================================================
// Actions & Visibility Hooks (Hooks #11 - #21, #23 - #24)
// ============================================================================

static const char* resolve_action_string(uint32_t kind, int32_t raw_id, bool want_desc) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_ACTIONS)) return nullptr;
    if (raw_id < 0 || raw_id > 0xFFFF) return nullptr;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return nullptr;
    const uint16_t action_id = static_cast<uint16_t>(raw_id);
    if (!valid_action_id(kind, action_id)) return nullptr;

    bool found = false;
    AcquireSRWLockShared(&action_lock);
    if (const ActionRecord* rec = action_catalog.find(job, branch, kind, action_id)) {
        if (want_desc) {
            if (rec->description[0] != '\0') {
                std::memcpy(tls_action_desc, rec->description, sizeof(tls_action_desc));
                tls_action_desc[sizeof(tls_action_desc) - 1] = '\0';
                found = true;
            }
        } else {
            if (rec->name[0] != '\0') {
                std::memcpy(tls_action_name, rec->name, sizeof(tls_action_name));
                tls_action_name[sizeof(tls_action_name) - 1] = '\0';
                found = true;
            }
        }
    }
    ReleaseSRWLockShared(&action_lock);
    if (!found && module_enabled(SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION)) {
        char* dest = want_desc ? tls_action_desc : tls_action_name;
        const size_t cap = want_desc ? sizeof(tls_action_desc) : sizeof(tls_action_name);
        if (dat_virt_mgr.lookup_text(job, branch, kind, static_cast<uint16_t>(action_id), want_desc, dest, cap)) {
            found = true;
        }
    }
    if (!found) return nullptr;
    return want_desc ? tls_action_desc : tls_action_name;
}

static bool resolve_action_icon(uint32_t kind, uint16_t action_id, uint32_t& icon_v1, uint32_t& icon_v2) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_ACTIONS)) return false;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return false;
    bool overridden = false;
    AcquireSRWLockShared(&action_lock);
    if (const ActionRecord* rec = action_catalog.find(job, branch, kind, action_id)) {
        if (rec->icon_id != 0xFFFFu) { icon_v1 = rec->icon_id; overridden = true; }
        if (rec->icon_id_v2 != 0xFFFFu) { icon_v2 = rec->icon_id_v2; overridden = true; }
    }
    ReleaseSRWLockShared(&action_lock);
    if (!overridden && module_enabled(SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION)) {
        overridden = dat_virt_mgr.lookup_icon(job, branch, kind, action_id, icon_v1, icon_v2);
    }
    return overridden;
}

static uint32_t ability_kind_for_id(int32_t ability_id) noexcept {
    return (ability_id >= 0 && ability_id < 512) ? SOULSPIRE_NATIVE_ACTION_WEAPONSKILL : SOULSPIRE_NATIVE_ACTION_ABILITY;
}

static const char* __stdcall resolve_magic_row_name(int32_t spell_id) noexcept {
    tls_magic_row_id = spell_id;
    if (const char* custom = resolve_action_string(SOULSPIRE_NATIVE_ACTION_SPELL, spell_id, false)) {
        const auto limit = action_row_max_chars.load(std::memory_order_relaxed);
        if (!compact_action_row_name(custom, tls_action_row, sizeof(tls_action_row), limit)) return nullptr;
        ++magic_name_hits;
        return tls_action_row;
    }
    return nullptr;
}

static const char* __stdcall resolve_magic_target_name(int32_t spell_id) noexcept {
    if (const char* custom = resolve_action_string(SOULSPIRE_NATIVE_ACTION_SPELL, spell_id, false)) {
        ++magic_name_hits;
        return custom;
    }
    return nullptr;
}

static const char* __stdcall resolve_magic_desc(int32_t spell_id) noexcept {
    if (const char* custom = resolve_action_string(SOULSPIRE_NATIVE_ACTION_SPELL, spell_id, true)) {
        if (!format_action_description(custom, tls_action_desc_fmt, sizeof(tls_action_desc_fmt), kHelpWindDescMaxChars)) {
            return nullptr;
        }
        ++magic_desc_hits;
        return tls_action_desc_fmt;
    }
    return nullptr;
}

static void* __cdecl magic_icon_hook(uint32_t icon_v1, uint32_t icon_v2) noexcept {
    const int32_t spell_id = tls_magic_row_id;
    tls_magic_row_id = -1;
    if (spell_id >= 0 && spell_id <= 1023) {
        uint32_t v1 = icon_v1, v2 = icon_v2;
        if (resolve_action_icon(SOULSPIRE_NATIVE_ACTION_SPELL, static_cast<uint16_t>(spell_id), v1, v2)) {
            ++magic_icon_hits;
            return original_action_icon(v1, v2);
        }
    }
    return original_action_icon(icon_v1, icon_v2);
}

static const char* __stdcall resolve_ability_row_name(int32_t ability_id) noexcept {
    tls_ability_row_id = ability_id;
    if (const char* custom = resolve_action_string(ability_kind_for_id(ability_id), ability_id, false)) {
        const auto limit = action_row_max_chars.load(std::memory_order_relaxed);
        if (!compact_action_row_name(custom, tls_action_row, sizeof(tls_action_row), limit)) return nullptr;
        ++ability_name_hits;
        return tls_action_row;
    }
    return nullptr;
}

static const char* __stdcall resolve_ability_target_name(int32_t ability_id) noexcept {
    if (const char* custom = resolve_action_string(ability_kind_for_id(ability_id), ability_id, false)) {
        ++ability_name_hits;
        return custom;
    }
    return nullptr;
}

static const char* __stdcall resolve_ability_desc(int32_t ability_id) noexcept {
    if (const char* custom = resolve_action_string(ability_kind_for_id(ability_id), ability_id, true)) {
        if (!format_action_description(custom, tls_action_desc_fmt, sizeof(tls_action_desc_fmt), kHelpWindDescMaxChars)) {
            return nullptr;
        }
        ++ability_desc_hits;
        return tls_action_desc_fmt;
    }
    return nullptr;
}

static void* __cdecl ability_icon_hook(uint32_t icon_v1, uint32_t icon_v2) noexcept {
    const int32_t ability_id = tls_ability_row_id;
    tls_ability_row_id = -1;
    if (ability_id >= 0 && ability_id <= 2047) {
        uint32_t v1 = icon_v1, v2 = icon_v2;
        if (resolve_action_icon(ability_kind_for_id(ability_id), static_cast<uint16_t>(ability_id), v1, v2)) {
            ++ability_icon_hits;
            return original_action_icon(v1, v2);
        }
    }
    return original_action_icon(icon_v1, icon_v2);
}

static __declspec(naked) void magic_row_name_hook() {
    __asm {
        pushad
        mov eax, [esp + 36]
        push eax
        call resolve_magic_row_name
        test eax, eax
        jz stock
        mov [esp + 28], eax
        popad
        ret 4
    stock:
        popad
        jmp dword ptr [original_spell_name]
    }
}

static __declspec(naked) void magic_desc_hook() {
    __asm {
        pushad
        mov eax, [esp + 36]
        push eax
        call resolve_magic_desc
        test eax, eax
        jz stock
        mov [esp + 28], eax
        popad
        ret 4
    stock:
        popad
        jmp dword ptr [original_spell_desc]
    }
}

static __declspec(naked) void magic_target_hook() {
    __asm {
        pushad
        mov eax, [esp + 36]
        push eax
        call resolve_magic_target_name
        test eax, eax
        jz stock
        mov [esp + 28], eax
        popad
        ret 4
    stock:
        popad
        jmp dword ptr [original_spell_name]
    }
}

static __declspec(naked) void ability_row_name_hook() {
    __asm {
        pushad
        mov eax, [esp + 36]
        push eax
        call resolve_ability_row_name
        test eax, eax
        jz stock
        mov [esp + 28], eax
        popad
        ret 4
    stock:
        popad
        jmp dword ptr [original_ability_name_row]
    }
}

static __declspec(naked) void ability_desc_hook() {
    __asm {
        pushad
        mov eax, [esp + 36]
        push eax
        call resolve_ability_desc
        test eax, eax
        jz stock
        mov [esp + 28], eax
        popad
        ret 4
    stock:
        popad
        jmp dword ptr [original_ability_desc]
    }
}

static __declspec(naked) void ability_target_hook() {
    __asm {
        pushad
        mov eax, [esp + 36]
        push eax
        call resolve_ability_target_name
        test eax, eax
        jz stock
        mov [esp + 28], eax
        popad
        ret 4
    stock:
        popad
        jmp dword ptr [original_ability_name_target]
    }
}

static VisibilityDecision decide_local_visibility(uint32_t kind, uint16_t action_id) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_ACTIONS)) return VisibilityDecision::Unmanaged;
    if (main_lvl_slot == nullptr) return VisibilityDecision::Unmanaged;
    const uint8_t effective_level = *main_lvl_slot;
    if (effective_level == 0) return VisibilityDecision::Unmanaged;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return VisibilityDecision::Unmanaged;
    AcquireSRWLockShared(&visibility_lock);
    const VisibilityDecision decision = visibility_catalog.decide(job, branch, kind, action_id, effective_level);
    ReleaseSRWLockShared(&visibility_lock);
    return decision;
}

static uint8_t __cdecl magic_list_filter_hook(const uint8_t* spell_resource) noexcept {
    if (spell_resource != nullptr) {
        const uint16_t spell_id = u16(spell_resource);
        if (spell_id > 0 && spell_id <= 1023u) {
            const VisibilityDecision decision = decide_local_visibility(SOULSPIRE_NATIVE_ACTION_SPELL, spell_id);
            if (decision == VisibilityDecision::Hide) {
                ++magic_hidden_count;
                return 0;
            }
            if (decision == VisibilityDecision::Show) {
                ++magic_shown_count;
                return 1;
            }
        }
    }
    return original_can_show_spell(spell_resource);
}

static uint8_t __stdcall soul_knows_missing_spell(const uint8_t* spell_resource) noexcept {
    if (spell_resource == nullptr) return 0;
    const uint16_t spell_id = u16(spell_resource);
    if (spell_id == 0 || spell_id > 1023u) return 0;
    return decide_local_visibility(SOULSPIRE_NATIVE_ACTION_SPELL, spell_id) == VisibilityDecision::Show ? 1 : 0;
}

static __declspec(naked) void missing_spell_bit_hook() {
    __asm {
        pushfd
        pushad
        push edi
        call soul_knows_missing_spell
        test al, al
        jz stock
        popad
        popfd
        jmp dword ptr [missing_spell_bit_resume]
    stock:
        popad
        popfd
        mov ebp, 0xfffffffe
        jmp dword ptr [missing_spell_bit_resume]
    }
}

static int32_t __stdcall decide_menu_spell_elig(const uint8_t* spell_resource) noexcept {
    if (spell_resource == nullptr) return -1;
    const uint16_t spell_id = u16(spell_resource);
    if (spell_id == 0 || spell_id > 1023u) return -1;
    const VisibilityDecision decision = decide_local_visibility(SOULSPIRE_NATIVE_ACTION_SPELL, spell_id);
    if (decision == VisibilityDecision::Show) return 1;
    if (decision == VisibilityDecision::Hide) return 0;
    return -1;
}

static __declspec(naked) void menu_spell_elig_hook() {
    __asm {
        pushad
        push esi
        call decide_menu_spell_elig
        test eax, eax
        js stock
        mov [esp + 28], eax
        popad
        ret
    stock:
        popad
        jmp dword ptr [original_spell_elig]
    }
}

// ============================================================================
// Equipment & Weapon Rules Hooks (Hooks #22, #25, #26, #27)
// ============================================================================

static uint8_t __stdcall soul_allows_sub_weapon(const uint8_t* sub_item_res, const uint8_t* stack_frame) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_EQUIPMENT)) return 0;
    if (sub_item_res == nullptr || stack_frame == nullptr) return 0;
    if (main_lvl_slot == nullptr || original_get_inv_item == nullptr ||
        original_get_item_res == nullptr || item_res_mgr_slot == nullptr) {
        return 0;
    }
    const uint8_t effective_level = *main_lvl_slot;
    if (effective_level == 0) return 0;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return 0;

    AcquireSRWLockShared(&weapon_lock);
    const bool has_rules = weapon_rule_catalog.has_rules_for(job, branch);
    ReleaseSRWLockShared(&weapon_lock);
    if (!has_rules) return 0;

    const uint8_t main_slot = stack_frame[0x10];
    if (main_slot == 0 || main_slot == 0xFFu) {
        ++weapon_deny_hits;
        return 0;
    }
    const uint32_t main_container = u32(stack_frame + 0x18);
    const uint8_t* main_inv = original_get_inv_item(main_container, static_cast<uint32_t>(main_slot));
    if (main_inv == nullptr) {
        ++weapon_deny_hits;
        return 0;
    }
    const uint16_t main_item_id = u16(main_inv);
    if (main_item_id == 0) {
        ++weapon_deny_hits;
        return 0;
    }
    void* res_mgr = *item_res_mgr_slot;
    if (res_mgr == nullptr) {
        ++weapon_deny_hits;
        return 0;
    }
    const uint8_t* main_res = original_get_item_res(res_mgr, nullptr, static_cast<uint32_t>(main_item_id));
    if (main_res == nullptr) {
        ++weapon_deny_hits;
        return 0;
    }
    const uint16_t main_skill = u16(main_res + 0x10);
    const uint16_t sub_item_id = u16(sub_item_res);
    const uint16_t sub_skill = u16(sub_item_res + 0x10);

    AcquireSRWLockShared(&weapon_lock);
    const bool allowed = weapon_rule_catalog.allows_sub_weapon(
        job, branch, effective_level, main_skill, main_item_id, sub_skill, sub_item_id);
    ReleaseSRWLockShared(&weapon_lock);

    if (allowed) {
        ++weapon_allow_hits;
        return 1;
    }
    ++weapon_deny_hits;
    return 0;
}

static __declspec(naked) void soul_sub_weapon_hook() {
    __asm {
        pushfd
        pushad
        lea eax, [esp + 36]
        push eax
        push esi
        call soul_allows_sub_weapon
        test al, al
        jz stock
        popad
        popfd
        jmp dword ptr [soul_sub_weapon_allow_resume]
    stock:
        popad
        popfd
        push 0x8b
        jmp dword ptr [soul_sub_weapon_deny_resume]
    }
}

// Hook #26 (RVA 0x21DF85): Native Equipment Sub-slot picker filter for DUAL_2H Souls.
static uint8_t __stdcall soul_allows_dual_2h_menu_item(uint32_t item_id) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_EQUIPMENT)) return 0;
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
    if (!enabled.load(std::memory_order_acquire)) return 0;
#endif
    if (item_id == 0 || item_id > 0xFFFFu) return 0;
    if (main_lvl_slot == nullptr || item_res_mgr_slot == nullptr || original_get_item_res == nullptr) return 0;
    const uint8_t effective_level = *main_lvl_slot;
    if (effective_level == 0) return 0;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return 0;

    AcquireSRWLockShared(&weapon_lock);
    const bool has_rules = weapon_rule_catalog.has_rules_for(job, branch);
    ReleaseSRWLockShared(&weapon_lock);
    if (!has_rules) return 0;

    void* res_mgr = *item_res_mgr_slot;
    if (res_mgr == nullptr) return 0;
    const uint8_t* sub_res = original_get_item_res(res_mgr, nullptr, item_id);
    if (sub_res == nullptr) return 0;
    const uint16_t sub_skill = u16(sub_res + 0x10);

    AcquireSRWLockShared(&weapon_lock);
    const bool allowed = weapon_rule_catalog.allows_dual_2h_menu_item(
        job, branch, effective_level, sub_skill, static_cast<uint16_t>(item_id));
    ReleaseSRWLockShared(&weapon_lock);
    if (allowed) {
        ++weapon_allow_hits;
        return 1;
    }
    ++weapon_deny_hits;
    return 0;
}

static __declspec(naked) void soul_sub_menu_filter_hook() {
    __asm {
        test [esi - 0x0C], eax
        jnz allow_item
        cmp eax, 2
        jne skip_item
        test dword ptr [esi - 0x0C], 1
        jz skip_item
        pushfd
        pushad
        movzx eax, di
        push eax
        call soul_allows_dual_2h_menu_item
        test al, al
        jz deny_item
        popad
        popfd
    allow_item:
        jmp dword ptr [soul_sub_menu_allow_resume]
    deny_item:
        popad
        popfd
    skip_item:
        jmp dword ptr [soul_sub_menu_skip_resume]
    }
}

// Hook #27 (RVA 0x133DD3): Allow Sub item while holding a 2H Main weapon for DUAL_2H / TWOHAND_SHIELD Souls.
static uint8_t __stdcall soul_allows_2h_main_with_sub(const uint8_t* main_res, const uint8_t* sub_res) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_EQUIPMENT)) return 0;
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
    if (!enabled.load(std::memory_order_acquire)) return 0;
#endif
    if (main_res == nullptr || sub_res == nullptr || main_lvl_slot == nullptr) return 0;
    const uint8_t effective_level = *main_lvl_slot;
    if (effective_level == 0) return 0;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return 0;

    const uint16_t main_item_id = u16(main_res);
    const uint16_t main_skill = u16(main_res + 0x10);
    const uint16_t sub_item_id = u16(sub_res);
    const uint16_t sub_skill = u16(sub_res + 0x10);

    AcquireSRWLockShared(&weapon_lock);
    const bool allowed = weapon_rule_catalog.allows_2h_main_with_sub(
        job, branch, effective_level, main_skill, main_item_id, sub_skill, sub_item_id);
    ReleaseSRWLockShared(&weapon_lock);

    if (allowed) {
        ++weapon_allow_hits;
        return 1;
    }
    ++weapon_deny_hits;
    return 0;
}

static __declspec(naked) void soul_sub_2h_main_hook() {
    __asm {
        pushfd
        pushad
        push esi
        push edi
        call soul_allows_2h_main_with_sub
        test al, al
        jz stock
        popad
        popfd
        jmp dword ptr [soul_sub_2h_main_allow_resume]
    stock:
        popad
        popfd
        push 0x99
        jmp dword ptr [soul_sub_2h_main_deny_resume]
    }
}

// Hook #22 (CALL patch at RVA 0x133E33 -> CanEquipItemInSlot 0x133580):
// Vanilla 2H weapons have slots == 1 (Main-only). Permit equipping in Sub (slot 1)
// only when CanEquipItemInSlot(item, 0) passes and an active DUAL_2H rule matches.
static uint8_t __fastcall soul_can_equip_in_slot_hook(
    void* self, void*, const uint8_t* parsed_item, uint32_t equip_slot) noexcept {
    if (original_can_equip_in_slot == nullptr) return 0;
    if (original_can_equip_in_slot(self, nullptr, parsed_item, equip_slot) != 0) return 1;
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_EQUIPMENT)) return 0;
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
    if (!enabled.load(std::memory_order_acquire)) return 0;
#endif
    if (equip_slot != 1u || parsed_item == nullptr) return 0;
    if (original_can_equip_in_slot(self, nullptr, parsed_item, 0u) == 0) return 0;
    if (main_lvl_slot == nullptr) return 0;
    const uint8_t effective_level = *main_lvl_slot;
    if (effective_level == 0) return 0;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return 0;

    const uint16_t sub_item_id = u16(parsed_item + 0x14B0);
    const uint16_t* skill_ptr = *reinterpret_cast<const uint16_t* const*>(parsed_item + 0x14E4);
    if (skill_ptr == nullptr) return 0;
    const uint16_t sub_skill = *skill_ptr;

    AcquireSRWLockShared(&weapon_lock);
    const bool allowed = weapon_rule_catalog.allows_dual_2h_menu_item(
        job, branch, effective_level, sub_skill, sub_item_id);
    ReleaseSRWLockShared(&weapon_lock);

    if (allowed) {
        ++weapon_allow_hits;
        return 1;
    }
    ++weapon_deny_hits;
    return 0;
}

static void __stdcall compact_ability_menu_rows(uint8_t* menu_obj, int32_t* count_ptr, int32_t* saved_sel_ptr) noexcept {
    if (!module_enabled(SOULSPIRE_NATIVE_MOD_ACTIONS)) return;
    if (menu_obj == nullptr || count_ptr == nullptr || *count_ptr <= 0) return;
    if (ability_list_slot == nullptr || main_lvl_slot == nullptr) return;
    const uint8_t effective_level = *main_lvl_slot;
    if (effective_level == 0) return;
    uint8_t job = 0, branch = 0;
    if (!active_action_soul(job, branch)) return;

    AcquireSRWLockShared(&visibility_lock);
    const bool has_rules = visibility_catalog.count() > 0;
    ReleaseSRWLockShared(&visibility_lock);
    if (!has_rules) return;

    uint8_t* list_obj = *ability_list_slot;
    if (list_obj == nullptr) return;
    auto* rows = *reinterpret_cast<uint32_t**>(menu_obj + 0x20);
    const int32_t capacity = *reinterpret_cast<const int32_t*>(menu_obj + 0x44);
    if (rows == nullptr || capacity <= 0) return;

    const int32_t total_raw = *reinterpret_cast<const int32_t*>(list_obj + 0x1760);
    if (total_raw <= 0 || total_raw > 0xB00) return;
    const auto* raw_ids = reinterpret_cast<const uint16_t*>(list_obj + 0x160);

    const int32_t count = (*count_ptr < capacity) ? *count_ptr : capacity;
    const int32_t orig_sel = (saved_sel_ptr != nullptr) ? *saved_sel_ptr : -1;
    int32_t new_sel = -1;
    int32_t write = 0;

    AcquireSRWLockShared(&visibility_lock);
    for (int32_t i = 0; i < count; ++i) {
        const uint32_t raw_idx = rows[i * 2];
        bool hide = false;
        if (raw_idx < static_cast<uint32_t>(total_raw)) {
            const uint16_t ability_id = raw_ids[raw_idx];
            const uint32_t kind = ability_kind_for_id(ability_id);
            if (visibility_catalog.decide(job, branch, kind, ability_id, effective_level) == VisibilityDecision::Hide) {
                hide = true;
            }
        }
        if (hide) {
            ++ability_hidden_count;
            continue;
        }
        if (i == orig_sel) new_sel = write;
        if (write != i) {
            rows[write * 2] = rows[i * 2];
            rows[write * 2 + 1] = rows[i * 2 + 1];
        }
        ++write;
    }
    ReleaseSRWLockShared(&visibility_lock);

    *count_ptr = write;
    if (saved_sel_ptr != nullptr && orig_sel >= 0 && orig_sel < count) {
        *saved_sel_ptr = new_sel;
    }
}

static __declspec(naked) void ability_list_filter_hook() {
    __asm {
        pushad
        lea eax, [esp + 36]
        lea edx, [esp + 72]
        push edx
        push eax
        push ecx
        call compact_ability_menu_rows
        popad
        jmp dword ptr [original_set_list_count]
    }
}

static __declspec(naked) void full_job_hook() {
    __asm {
        pushad
        mov eax, [esp + 40]
        mov edx, [esp + 36]
        push eax
        push edx
        push esi
        call full_branch
        mov [esp + 28], eax
        popad
        ret
    }
}

// ============================================================================
// Packet Transport Hooks (Hooks #9 - #10)
// ============================================================================

static uint32_t received_packets(uint8_t* packets, uint32_t length, uint32_t now) noexcept {
    if (!whole_packets(packets, length)) return length;
    uint32_t at = 0;
    while (at + 4 <= length) {
        const uint32_t size = packet_size(packets + at);
        if (size == 0) break;
        bool consume = false;
        if (enabled.load(std::memory_order_acquire)) {
            AcquireSRWLockExclusive(&state_lock);
            const uint16_t pid = u16(packets + at) & 0x1ffu;
            if (pid == 0x00au || pid == 0x00bu || pid == 0x061u) {
                soul_override = {};
                tls_magic_row_id = -1;
                tls_ability_row_id = -1;
            }
            consume = transport.incoming(packets + at, size, now, state);
            ReleaseSRWLockExclusive(&state_lock);
        } else {
            consume = (u16(packets + at) & 0x1ffu) == 0x1ffu && size >= 12 &&
                std::memcmp(packets + at + 4, "CRYS", 4) == 0 && u16(packets + at + 10) >= 0x8000u;
        }
        if (consume) {
            std::memmove(packets + at, packets + at + size, length - at - size);
            length -= size;
        } else {
            at += size;
        }
    }
    return length;
}

static int __cdecl map_decode(uint8_t* output, uint32_t capacity, uintptr_t context, uintptr_t tree, const uint8_t* wire, uint32_t length) noexcept {
    const int result = original_map_decode(output, capacity, context, tree, wire, length);
    if (result <= 28 || static_cast<uint32_t>(result) > capacity || result > 10000) return result;
    return 28 + static_cast<int>(received_packets(output + 28, static_cast<uint32_t>(result - 28), GetTickCount()));
}

static int __cdecl map_encode(const uint8_t* packets, uint32_t length, uint8_t* output, uint32_t capacity, uintptr_t table) noexcept {
    if (!enabled.load(std::memory_order_acquire) || length < 4 || length > 10000 || !whole_packets(packets, length)) {
        return original_map_encode(packets, length, output, capacity, table);
    }
    uint8_t combined[10016];
    uint32_t at = 0;
    AcquireSRWLockExclusive(&state_lock);
    while (at + 4 <= length) {
        const uint32_t size = packet_size(packets + at);
        if (size == 0) break;
        if ((u16(packets + at) & 0x1ffu) == 0x00du) {
            soul_override = {};
            tls_magic_row_id = -1;
            tls_ability_row_id = -1;
        }
        transport.outgoing(packets + at, state);
        at += size;
    }
    const uint32_t room = capacity == 0 ? 0 : (capacity - 1) / 3 * 2;
    const bool append = at >= 4 && length + 16 <= room && length + 16 <= 10000 &&
        transport.prepare(combined + at, packets + 2, GetTickCount(), &state);
    ReleaseSRWLockExclusive(&state_lock);
    if (!append) return original_map_encode(packets, length, output, capacity, table);
    std::memcpy(combined, packets, at);
    std::memcpy(combined + at + 16, packets + at, length - at);
    const int result = original_map_encode(combined, length + 16, output, capacity, table);
    if (result < 0) {
        AcquireSRWLockExclusive(&state_lock);
        transport.pending = 0;
        transport.refresh = true;
        ReleaseSRWLockExclusive(&state_lock);
    }
    return result;
}

// ============================================================================
// Centralized 27-Hook Registry & Lifecycle Management
// ============================================================================

static Patch patches[] = {
    {0x0D8CCD, reinterpret_cast<void*>(&encode_request)},              // Bit 0  (#1)
    {0x0E2282, reinterpret_cast<void*>(&decode_row)},                  // Bit 1  (#2)
    {0x13C302, reinterpret_cast<void*>(&item_label)},                  // Bit 2  (#3)
    {0x14868F, reinterpret_cast<void*>(&persona_job_hook)},            // Bit 3  (#4)
    {0x1CBD4C, reinterpret_cast<void*>(&normal_sprite_hook)},          // Bit 4  (#5)
    {0x1CC086, reinterpret_cast<void*>(&master_sprite_hook)},          // Bit 5  (#6)
    {0x1DEE6D, reinterpret_cast<void*>(&full_job_hook)},               // Bit 6  (#7)
    {0x1DEEFB, reinterpret_cast<void*>(&full_job_hook)},               // Bit 7  (#8)
    {0x0FA795, reinterpret_cast<void*>(&map_decode)},                  // Bit 8  (#9)
    {0x0DD5F6, reinterpret_cast<void*>(&map_encode)},                  // Bit 9  (#10)
    {0x22E4F5, reinterpret_cast<void*>(&magic_row_name_hook)},         // Bit 10 (#11)
    {0x22E245, reinterpret_cast<void*>(&magic_desc_hook)},             // Bit 11 (#12)
    {0x22DED1, reinterpret_cast<void*>(&magic_target_hook)},           // Bit 12 (#13)
    {0x22E51B, reinterpret_cast<void*>(&magic_icon_hook)},             // Bit 13 (#14)
    {0x226129, reinterpret_cast<void*>(&ability_row_name_hook)},       // Bit 14 (#15)
    {0x225F5D, reinterpret_cast<void*>(&ability_desc_hook)},           // Bit 15 (#16)
    {0x225916, reinterpret_cast<void*>(&ability_target_hook)},         // Bit 16 (#17)
    {0x22614E, reinterpret_cast<void*>(&ability_icon_hook)},           // Bit 17 (#18)
    {0x22DAB9, reinterpret_cast<void*>(&magic_list_filter_hook)},      // Bit 18 (#19)
    {0x22562F, reinterpret_cast<void*>(&ability_list_filter_hook)},    // Bit 19 (#20)
    {0x22E64D, reinterpret_cast<void*>(&menu_spell_elig_hook)},        // Bit 20 (#21)
    {0x133E33, reinterpret_cast<void*>(&soul_can_equip_in_slot_hook)}, // Bit 21 (#22 / CanEquipItemInSlot)
};

static PrologueDetour can_use_spell_detour{0x22CDE0, reinterpret_cast<void*>(&magic_list_filter_hook), 0xA1u};        // Bit 22 (#23)
static PrologueDetour missing_spell_bit_detour{0x22CB44, reinterpret_cast<void*>(&missing_spell_bit_hook), 0xBDu};    // Bit 23 (#24)
static PrologueDetour soul_sub_weapon_detour{0x133D56, reinterpret_cast<void*>(&soul_sub_weapon_hook), 0x68u};        // Bit 24 (#25)
static PrologueDetour soul_sub_menu_filter_detour{0x21DF85, reinterpret_cast<void*>(&soul_sub_menu_filter_hook), 0x85u}; // Bit 25 (#26)
static PrologueDetour soul_sub_2h_main_detour{0x133DD3, reinterpret_cast<void*>(&soul_sub_2h_main_hook), 0x68u};      // Bit 26 (#27)

static constexpr uint32_t kPatchCount = static_cast<uint32_t>(sizeof(patches) / sizeof(*patches));
static constexpr uint32_t kDetourCount = 5u;
static constexpr uint32_t kExpectedHooks = kPatchCount + kDetourCount;
static_assert(kPatchCount == 22u);
static_assert(kExpectedHooks == 27u);
static_assert(kExpectedHooks == SOULSPIRE_NATIVE_EXPECTED_HOOKS);

static PrologueDetour* detour_at(uint32_t idx) noexcept {
    switch (idx) {
        case 0: return &can_use_spell_detour;
        case 1: return &missing_spell_bit_detour;
        case 2: return &soul_sub_weapon_detour;
        case 3: return &soul_sub_menu_filter_detour;
        case 4: return &soul_sub_2h_main_detour;
        default: return nullptr;
    }
}

static bool supported_impl(uint8_t* base) noexcept {
    hook_diag = {};
    hook_diag.ffxi_base = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(base));
    if (base == nullptr || (reinterpret_cast<uintptr_t>(base) & 0xFFFFu) != 0) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_BAD_PE;
        return false;
    }
#ifndef _MSC_VER
    if (!readable_range(base, sizeof(IMAGE_DOS_HEADER))) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_BAD_PE;
        return false;
    }
#endif
    const auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 || dos->e_lfanew > 0x1000) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_BAD_PE;
        return false;
    }
#ifndef _MSC_VER
    if (!readable_range(base + dos->e_lfanew, sizeof(IMAGE_NT_HEADERS32))) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_BAD_PE;
        return false;
    }
#endif
    const auto* pe = reinterpret_cast<IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
    hook_diag.ffxi_timestamp = pe->FileHeader.TimeDateStamp;
    hook_diag.ffxi_image_size = pe->OptionalHeader.SizeOfImage;
    if (pe->Signature != IMAGE_NT_SIGNATURE || pe->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
        pe->FileHeader.TimeDateStamp != kExpectedFfxiTimestamp ||
        pe->OptionalHeader.SizeOfImage != kExpectedFfxiImageSize) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_BAD_PE;
        return false;
    }
    const uint32_t delta = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(base) - 0x10000000u);
    uint32_t sig_index = 0;
    for (const auto& signature : signatures) {
#ifndef _MSC_VER
        if (!readable_range(base + signature.rva, sizeof(signature.bytes))) {
            hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_SIG_MISMATCH;
            hook_diag.failed_rva = static_cast<uint32_t>(signature.rva);
            hook_diag.failed_index = sig_index;
            return false;
        }
#endif
        uint8_t expected[24];
        std::memcpy(expected, signature.bytes, sizeof(expected));
        relocate_signature(signature.rva, expected, delta);
        if ((signature.rva == 0xDD6C0 || signature.rva == 0xDF7C0) && host_detour(base + signature.rva,
            expected, sizeof(expected), signature.rva == 0xDD6C0 ? 10 : 5, GetModuleHandleW(L"Ashita.dll"))) {
            ++sig_index;
            continue;
        }
        size_t skip = 0;
        for (const auto& patch : patches) {
            if (patch.rva == signature.rva && patch.site != nullptr && std::memcmp(patch.site, patch.installed, 5) == 0) {
                skip = 5;
            }
        }
        for (uint32_t j = 0; j < kDetourCount; ++j) {
            const auto* d = detour_at(j);
            if (d->rva == signature.rva && d->site != nullptr && std::memcmp(d->site, d->installed, 5) == 0) {
                skip = 5;
            }
        }
        if (std::memcmp(base + signature.rva + skip, expected + skip, sizeof(expected) - skip) != 0) {
            hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_SIG_MISMATCH;
            hook_diag.failed_rva = static_cast<uint32_t>(signature.rva);
            hook_diag.failed_index = sig_index;
            std::memcpy(hook_diag.observed_bytes, base + signature.rva, sizeof(hook_diag.observed_bytes));
            return false;
        }
        ++sig_index;
    }
    return true;
}

static bool supported(uint8_t* base) noexcept {
#ifdef _MSC_VER
    __try {
        return supported_impl(base);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_BAD_PE;
        return false;
    }
#else
    return supported_impl(base);
#endif
}

static bool patch_installed_at(uintptr_t rva) noexcept {
    for (const auto& patch : patches) {
        if (patch.rva == rva) {
            return patch.site != nullptr && std::memcmp(patch.site, patch.installed, 5) == 0;
        }
    }
    return false;
}

static uint32_t hook_rva_at(uint32_t index) noexcept {
    if (index < kPatchCount) return static_cast<uint32_t>(patches[index].rva);
    if (index < kExpectedHooks) return static_cast<uint32_t>(detour_at(index - kPatchCount)->rva);
    return 0;
}

static const uint8_t* hook_site_at(uint32_t index) noexcept {
    if (index < kPatchCount) return patches[index].site;
    if (index < kExpectedHooks) return detour_at(index - kPatchCount)->site;
    return nullptr;
}

// Caller must hold lifecycle_lock (shared or exclusive).
static void collect_hook_state(uint32_t& total, uint32_t& installed_mask, uint32_t& site_set_mask, uint32_t& caps) noexcept {
    total = 0;
    installed_mask = 0;
    site_set_mask = 0;
    caps = 0;
    for (uint32_t i = 0; i < kPatchCount; ++i) {
        const auto& patch = patches[i];
        if (patch.site != nullptr) {
            site_set_mask |= (1u << i);
            if (std::memcmp(patch.site, patch.installed, 5) == 0) {
                installed_mask |= (1u << i);
                ++total;
            }
        }
    }
    for (uint32_t j = 0; j < kDetourCount; ++j) {
        const auto* d = detour_at(j);
        const uint32_t bit = kPatchCount + j;
        if (d->site != nullptr) {
            site_set_mask |= (1u << bit);
            if (std::memcmp(d->site, d->installed, 5) == 0) {
                installed_mask |= (1u << bit);
                ++total;
            }
        }
    }
    if (enabled.load(std::memory_order_acquire)) {
        if (module_enabled(SOULSPIRE_NATIVE_MOD_JOB_IDENTITY) && patch_installed_at(0x14868F)) {
            caps |= SOULSPIRE_NATIVE_CAP_EQUIPMENT_SOUL_NAME;
        }
        if (module_enabled(SOULSPIRE_NATIVE_MOD_JOB_IDENTITY) &&
            patch_installed_at(0x1CBD4C) && patch_installed_at(0x1CC086) &&
            patch_installed_at(0x1DEE6D) && patch_installed_at(0x1DEEFB)) {
            caps |= SOULSPIRE_NATIVE_CAP_SEARCH_SOUL_LABELS;
        }
        if (module_enabled(SOULSPIRE_NATIVE_MOD_ACTIONS)) {
            if (patch_installed_at(0x22E4F5)) caps |= SOULSPIRE_NATIVE_CAP_MAGIC_MENU_NAMES;
            if (patch_installed_at(0x22E245)) caps |= SOULSPIRE_NATIVE_CAP_MAGIC_MENU_DESC;
            if (patch_installed_at(0x22DED1)) caps |= SOULSPIRE_NATIVE_CAP_MAGIC_TARGET_HEADER;
            if (patch_installed_at(0x22E51B)) caps |= SOULSPIRE_NATIVE_CAP_MAGIC_MENU_ICONS;
            if (patch_installed_at(0x226129)) caps |= SOULSPIRE_NATIVE_CAP_ABILITY_MENU_NAMES;
            if (patch_installed_at(0x225F5D)) caps |= SOULSPIRE_NATIVE_CAP_ABILITY_MENU_DESC;
            if (patch_installed_at(0x225916)) caps |= SOULSPIRE_NATIVE_CAP_ABILITY_TARGET_HDR;
            if (patch_installed_at(0x22614E)) caps |= SOULSPIRE_NATIVE_CAP_ABILITY_MENU_ICONS;
            if (patch_installed_at(0x22DAB9)) caps |= SOULSPIRE_NATIVE_CAP_MAGIC_MENU_FILTER;
            if (patch_installed_at(0x22562F)) caps |= SOULSPIRE_NATIVE_CAP_ABILITY_MENU_FILTER;
            if (patch_installed_at(0x22E64D) &&
                ((installed_mask & (1u << kPatchCount)) != 0) &&
                ((installed_mask & (1u << (kPatchCount + 1u))) != 0)) {
                caps |= SOULSPIRE_NATIVE_CAP_SOUL_CAST_LOOKUP;
            }
        }
        if (module_enabled(SOULSPIRE_NATIVE_MOD_EQUIPMENT)) {
            if ((installed_mask & (1u << (kPatchCount + 2u))) != 0) {
                caps |= SOULSPIRE_NATIVE_CAP_SOUL_SUB_WEAPON;
            }
            if ((installed_mask & (1u << (kPatchCount + 2u))) != 0 &&
                (installed_mask & (1u << (kPatchCount + 3u))) != 0 &&
                (installed_mask & (1u << (kPatchCount + 4u))) != 0 &&
                patch_installed_at(0x133E33)) {
                caps |= SOULSPIRE_NATIVE_CAP_SOUL_SUB_2H;
            }
        }
        if (module_enabled(SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION) && dat_virt_mgr.is_enabled() &&
            dat_virt_mgr.override_count() > 0) {
            caps |= SOULSPIRE_NATIVE_CAP_DAT_VIRTUALIZATION;
        }
    }
}

// ============================================================================
// Public C ABI Exports (SoulspireNative*)
// ============================================================================

extern "C" uint32_t __stdcall SoulspireNativeShutdown() {
    AcquireSRWLockExclusive(&lifecycle_lock);
    // Step 1: Disable hooks FIRST so any concurrent FFXI frame takes the safe vanilla
    // passthrough path while all original_* and *_resume pointers remain valid.
    enabled.store(false, std::memory_order_release);

    // Step 2: Restore all 5 detours and 22 CALL patches BEFORE clearing pointers.
    uint32_t failure = 0;
    for (uint32_t j = kDetourCount; j-- > 0;) {
        if (!detour_at(j)->restore()) failure = 3;
    }
    for (size_t index = kPatchCount; index-- > 0;) {
        auto& patch = patches[index];
        // Late high-ID CRYS replies must still be consumed after their last request was sent.
        if (ever_started && (patch.rva == 0x0FA795 || patch.rva == 0x0E2282) &&
            patch.site != nullptr && std::memcmp(patch.site, patch.installed, 5) == 0) {
            continue;
        }
        if (!patch.restore()) failure = 3;
    }

    // Step 3: Clear session/override state and TLS cursors.
    AcquireSRWLockExclusive(&state_lock);
    transport.reset(state);
    soul_override = {};
    ReleaseSRWLockExclusive(&state_lock);
    tls_magic_row_id = -1;
    tls_ability_row_id = -1;

    // Step 4: Only clear data slots after restore succeeded; never zero *_resume or
    // original_* jump targets while an in-flight call or un-restored hook could branch through them.
    if (failure == 0) {
        pname_sheet_slot = nullptr;
        item_res_mgr_slot = nullptr;
        main_job_slot = nullptr;
        main_lvl_slot = nullptr;
        ability_list_slot = nullptr;
    }

    last_error.store(failure, std::memory_order_release);
    ReleaseSRWLockExclusive(&lifecycle_lock);
    return failure;
}

extern "C" uint32_t __stdcall SoulspireNativeReloadConfig() {
    AcquireSRWLockExclusive(&lifecycle_lock);
    HMODULE mod = g_self_module;
    if (mod == nullptr) {
        GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&normal_sprite_hook), &mod);
    }
    if (mod == nullptr) {
        ReleaseSRWLockExclusive(&lifecycle_lock);
        return 1;
    }
    load_runtime_resources(mod, action_row_max_chars, &dat_virt_mgr);
    dat_virt_mgr.configure(module_enabled(SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION));
    ReleaseSRWLockExclusive(&lifecycle_lock);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeInitialize() {
    AcquireSRWLockExclusive(&lifecycle_lock);
    if (enabled.load(std::memory_order_acquire)) {
        ReleaseSRWLockExclusive(&lifecycle_lock);
        return 0;
    }

    HMODULE pinned = nullptr;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&normal_sprite_hook), &pinned)) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_PIN_FAIL;
        last_error.store(2, std::memory_order_release);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        return 2;
    }
    g_self_module = pinned;

    // Mutual-exclusion guard: never patch FFXiMain.dll if legacy crystaljobs.dll is loaded simultaneously.
#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
    const bool legacy_conflict = selftest_simulate_legacy_conflict || detect_legacy_crystaljobs_conflict(pinned);
#else
    const bool legacy_conflict = detect_legacy_crystaljobs_conflict(pinned);
#endif
    if (legacy_conflict) {
        hook_diag = {};
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_CONFLICT_LEGACY_DLL;
        log_message(LOG_LEVEL_ERROR,
            "Refusing to initialize: legacy crystaljobs.dll is loaded simultaneously. "
            "Remove plugins\\crystaljobs.dll via SoulspireLauncher.");
        last_error.store(2, std::memory_order_release);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        return 2;
    }

    auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(L"FFXiMain.dll"));
    if (!supported(base)) {
        log_message(LOG_LEVEL_ERROR,
            "Unsupported FFXiMain.dll build or signature mismatch (stage=%u, rva=0x%X, idx=%u)",
            hook_diag.init_stage, hook_diag.failed_rva, hook_diag.failed_index);
        last_error.store(1, std::memory_order_release);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        return 1;
    }

    original_lookup = reinterpret_cast<Lookup>(base + 0x1544C0);
    original_decode = reinterpret_cast<Decode>(base + 0x106300);
    original_encode = reinterpret_cast<Encode>(base + 0x104330);
    native_text = reinterpret_cast<NativeText>(base + 0x1CAD80);
    original_action_icon = reinterpret_cast<ActionIcon>(base + 0x222350);
    original_can_show_spell = reinterpret_cast<CanShowSpell>(base + 0x22CDE0);
    original_get_inv_item = reinterpret_cast<GetInventoryItem>(base + 0xEB5D0);
    original_get_item_res = reinterpret_cast<GetItemResource>(base + 0x15D210);
    original_can_equip_in_slot = reinterpret_cast<CanEquipItemInSlot>(base + 0x133580);
    original_sprite = reinterpret_cast<uintptr_t>(base + 0x121110);
    original_sprite_simple = reinterpret_cast<uintptr_t>(base + 0x120FF0);
    original_spell_name = reinterpret_cast<uintptr_t>(base + 0x22D510);
    original_spell_desc = reinterpret_cast<uintptr_t>(base + 0x22D590);
    original_ability_name_row = reinterpret_cast<uintptr_t>(base + 0x225120);
    original_ability_name_target = reinterpret_cast<uintptr_t>(base + 0x2250A0);
    original_ability_desc = reinterpret_cast<uintptr_t>(base + 0x225190);
    original_set_list_count = reinterpret_cast<uintptr_t>(base + 0x223090);
    original_spell_elig = reinterpret_cast<uintptr_t>(base + 0x1021A0);
    pname_sheet_slot = reinterpret_cast<void**>(base + 0x664014);
    item_res_mgr_slot = reinterpret_cast<void**>(base + 0x6229C0);
    main_job_slot = base + 0x4867F0;
    main_lvl_slot = base + 0x4867F1;
    ability_list_slot = reinterpret_cast<uint8_t**>(base + 0x668308);
    original_map_decode = reinterpret_cast<MapDecode>(base + 0xDD6C0);
    original_map_encode = reinterpret_cast<MapEncode>(base + 0xDF7C0);

    // Pre-populate all detour resume targets BEFORE installing any hook.
    missing_spell_bit_resume = reinterpret_cast<uintptr_t>(base + 0x22CB49);
    soul_sub_weapon_deny_resume = reinterpret_cast<uintptr_t>(base + 0x133D5B);
    soul_sub_weapon_allow_resume = reinterpret_cast<uintptr_t>(base + 0x133D65);
    soul_sub_menu_allow_resume = reinterpret_cast<uintptr_t>(base + 0x21DF8A);
    soul_sub_menu_skip_resume = reinterpret_cast<uintptr_t>(base + 0x21DFE9);
    soul_sub_2h_main_deny_resume = reinterpret_cast<uintptr_t>(base + 0x133DD8);
    soul_sub_2h_main_allow_resume = reinterpret_cast<uintptr_t>(base + 0x133DEB);

    load_runtime_resources(pinned, action_row_max_chars, &dat_virt_mgr);
    dat_virt_mgr.configure(module_enabled(SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION));

    for (uint32_t i = 0; i < kPatchCount; ++i) {
        auto& patch = patches[i];
        if (!patch.install(base)) {
            hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_PATCH_FAIL;
            hook_diag.failed_index = i;
            hook_diag.failed_rva = static_cast<uint32_t>(patch.rva);
            safe_read_bytes(base + patch.rva, hook_diag.observed_bytes);
            ReleaseSRWLockExclusive(&lifecycle_lock);
            const uint32_t failure = SoulspireNativeShutdown() == 0 ? 2 : 3;
            last_error.store(failure, std::memory_order_release);
            return failure;
        }
    }

    for (uint32_t j = 0; j < kDetourCount; ++j) {
        auto* d = detour_at(j);
        CanShowSpell* tramp_out = (j == 0) ? &original_can_show_spell : nullptr;
        if (!d->install(base, tramp_out)) {
            hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_DETOUR_FAIL;
            hook_diag.failed_index = kPatchCount + j;
            hook_diag.failed_rva = static_cast<uint32_t>(d->rva);
            safe_read_bytes(base + d->rva, hook_diag.observed_bytes);
            ReleaseSRWLockExclusive(&lifecycle_lock);
            const uint32_t failure = SoulspireNativeShutdown() == 0 ? 2 : 3;
            last_error.store(failure, std::memory_order_release);
            return failure;
        }
    }

    AcquireSRWLockExclusive(&state_lock);
    transport.reset(state);
    soul_override = {};
    ReleaseSRWLockExclusive(&state_lock);

    ever_started = true;
    hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_OK;
    hook_diag.failed_rva = 0;
    hook_diag.failed_index = 0xFFFFFFFFu;
    std::memset(hook_diag.observed_bytes, 0, sizeof(hook_diag.observed_bytes));
    last_error.store(0, std::memory_order_release);
    enabled.store(true, std::memory_order_release);
    log_message(LOG_LEVEL_INFO, "Initialized all %u native hooks cleanly (ABI v%u)",
        kExpectedHooks, static_cast<unsigned>(SOULSPIRE_NATIVE_ABI_VERSION));
    ReleaseSRWLockExclusive(&lifecycle_lock);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeSetState(const uint8_t* bytes, uint32_t size) {
    if (bytes == nullptr || size != 8 || bytes[0] != 1 || bytes[1] > 1 || bytes[2] > 23 || bytes[3] > 7 ||
        !enabled.load(std::memory_order_acquire)) {
        return 1;
    }
    AcquireSRWLockExclusive(&state_lock);
    const uint32_t id = u32(bytes + 4);
    if (id != 0 && bytes[2] >= 1 && bytes[2] <= 23 && (transport.character == 0 || transport.character == id)) {
        transport.character = id;
        transport.job = bytes[2];
    }
    const bool valid = id == transport.character && bytes[2] == transport.job && id != 0;
    if (valid) {
        const uint8_t prev_branch = state.branch;
        const uint8_t prev_job = state.job;
        state.update(bytes, size, GetTickCount());
        // Clear any stale addon override whenever authoritative bridge updates Soul state.
        if (state.known || prev_branch != state.branch || prev_job != state.job) {
            soul_override = {};
        }
    } else if (id == 0 && bytes[1] == 0) {
        state.known = false;
        state.branch = 0;
        state.from_bridge = false;
        soul_override = {};
    }
    ReleaseSRWLockExclusive(&state_lock);
    return valid ? 0 : 1;
}

extern "C" uint32_t __stdcall SoulspireNativeGetStatus(SoulspireNativeStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeStatus status{};
    status.size = sizeof(status);
    status.version = 1;
    AcquireSRWLockShared(&lifecycle_lock);
    uint32_t total = 0, inst_mask = 0, site_mask = 0, caps = 0;
    collect_hook_state(total, inst_mask, site_mask, caps);
    status.hooks = total;
    if (enabled.load(std::memory_order_acquire) && status.hooks != kExpectedHooks) {
        enabled.store(false, std::memory_order_release);
        last_error.store(3, std::memory_order_release);
    }
    status.enabled = enabled.load(std::memory_order_acquire) ? 1u : 0u;
    ReleaseSRWLockShared(&lifecycle_lock);
    AcquireSRWLockShared(&state_lock);
    status.character_id = transport.character;
    status.job = transport.job;
    status.known = (status.enabled && state.known && state.alive(GetTickCount(), transport.character, transport.job)) ? 1u : 0u;
    status.branch = status.known ? state.branch : 0;
    for (const auto& row : state.rows) {
        if (row.character != 0 && row.branch != 0) ++status.search_rows;
    }
    status.queries_sent = transport.sent;
    status.replies_accepted = transport.accepted;
    status.replies_rejected = transport.rejected;
    status.last_error = last_error.load(std::memory_order_acquire);
    if (status.last_error == 0) {
        status.last_error = transport.next_request > 0xffffu ? 5u : (transport.timeouts >= 3 ? 4u : 0u);
    }
    ReleaseSRWLockShared(&state_lock);
    status.decoded_rows = decoded_rows.load(std::memory_order_relaxed);
    status.item_labels = item_lookups.load(std::memory_order_relaxed);
    status.search_labels = short_draws.load(std::memory_order_relaxed);
    status.full_labels = full_lookups.load(std::memory_order_relaxed);
    *output = status;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeGetIdentityDiagnostics(SoulspireNativeIdentityDiagnostics* output, uint32_t size) {
    if (output == nullptr || size < sizeof(SoulspireNativeIdentityDiagnostics)) return 1;
    SoulspireNativeIdentityDiagnostics diag{};
    diag.size = sizeof(SoulspireNativeIdentityDiagnostics);
    diag.version = 1;
    const auto* snap = g_active_runtime_identity.load(std::memory_order_acquire);
    if (snap != nullptr && snap->active) {
        diag.source = 1;
        diag.status = snap->status;
        diag.schema_version = snap->schema_version;
        diag.soul_count = snap->soul_count;
        std::snprintf(diag.active_registry_hash, sizeof(diag.active_registry_hash), "%s", snap->registry_hash);
        std::snprintf(diag.warning, sizeof(diag.warning), "%s", snap->warning);
    } else {
        diag.source = 0;
        diag.status = g_last_identity_status;
        diag.schema_version = kIdentitySchemaVersion;
        diag.soul_count = 66;
        std::snprintf(diag.active_registry_hash, sizeof(diag.active_registry_hash), "%s", kRegistryHash);
        std::snprintf(diag.warning, sizeof(diag.warning), "%s", g_last_identity_warning);
    }
    std::snprintf(diag.compiled_registry_hash, sizeof(diag.compiled_registry_hash), "%s", kRegistryHash);
    const SearchPresentationConfig& pres = active_search_presentation();
    diag.tracking_px = pres.tracking_px;
    diag.offset_x_px = pres.offset_x_px;
    diag.use_glyph_widths = pres.use_glyph_widths ? 1u : 0u;
    diag.presentation_from_file = pres.from_file ? 1u : 0u;
    *output = diag;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeReplaceCatalog(const SoulspireNativeActionEntry* entries, uint32_t count) {
    AcquireSRWLockExclusive(&action_lock);
    const bool ok = action_catalog.replace_all(entries, count);
    ReleaseSRWLockExclusive(&action_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall SoulspireNativeUpsertAction(const SoulspireNativeActionEntry* entry) {
    if (entry == nullptr) return 1;
    AcquireSRWLockExclusive(&action_lock);
    const bool ok = action_catalog.upsert(*entry);
    ReleaseSRWLockExclusive(&action_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall SoulspireNativeClearCatalog() {
    AcquireSRWLockExclusive(&action_lock);
    action_catalog.clear();
    ReleaseSRWLockExclusive(&action_lock);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeSetActiveSoul(uint32_t job, uint32_t branch, uint32_t character_id) {
    if (job < 1 || job > 22 || !valid_branch(static_cast<uint8_t>(job), static_cast<uint8_t>(branch))) return 1;
    AcquireSRWLockExclusive(&state_lock);
    soul_override.active = true;
    soul_override.job = static_cast<uint8_t>(job);
    soul_override.branch = static_cast<uint8_t>(branch);
    soul_override.character = character_id;
    ReleaseSRWLockExclusive(&state_lock);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeClearActiveSoul() {
    AcquireSRWLockExclusive(&state_lock);
    soul_override = {};
    ReleaseSRWLockExclusive(&state_lock);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeSetActionRowLimit(uint32_t max_chars) {
    if (max_chars < 8 || max_chars > 48) return 1;
    action_row_max_chars.store(max_chars, std::memory_order_relaxed);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeGetActionStatus(SoulspireNativeActionStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeActionStatus st{};
    st.size = sizeof(st);
    st.version = 1;
    st.expected_hooks = kExpectedHooks;

    AcquireSRWLockShared(&lifecycle_lock);
    uint32_t inst_mask = 0, site_mask = 0;
    collect_hook_state(st.total_hooks, inst_mask, site_mask, st.capabilities);
    ReleaseSRWLockShared(&lifecycle_lock);

    AcquireSRWLockShared(&action_lock);
    st.catalog_count = action_catalog.count();
    st.catalog_generation = action_catalog.generation();
    ReleaseSRWLockShared(&action_lock);

    uint8_t active_job = 0, active_branch = 0;
    uint32_t source = 0;
    if (active_action_soul(active_job, active_branch, &source)) {
        st.active_job = active_job;
        st.active_branch = active_branch;
        st.active_source = source;
    }

    st.magic_name_hits = magic_name_hits.load(std::memory_order_relaxed);
    st.magic_desc_hits = magic_desc_hits.load(std::memory_order_relaxed);
    st.magic_icon_hits = magic_icon_hits.load(std::memory_order_relaxed);
    st.ability_name_hits = ability_name_hits.load(std::memory_order_relaxed);
    st.ability_desc_hits = ability_desc_hits.load(std::memory_order_relaxed);
    st.ability_icon_hits = ability_icon_hits.load(std::memory_order_relaxed);
    *output = st;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeReplaceVisibility(const SoulspireNativeVisibilityEntry* entries, uint32_t count) {
    AcquireSRWLockExclusive(&visibility_lock);
    const bool ok = visibility_catalog.replace_all(entries, count);
    ReleaseSRWLockExclusive(&visibility_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall SoulspireNativeClearVisibility() {
    AcquireSRWLockExclusive(&visibility_lock);
    visibility_catalog.clear();
    ReleaseSRWLockExclusive(&visibility_lock);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeGetVisibilityStatus(SoulspireNativeVisibilityStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeVisibilityStatus st{};
    st.size = sizeof(st);
    st.version = 1;
    st.expected_hooks = kExpectedHooks;

    AcquireSRWLockShared(&lifecycle_lock);
    uint32_t inst_mask = 0, site_mask = 0, caps = 0;
    collect_hook_state(st.total_hooks, inst_mask, site_mask, caps);
    ReleaseSRWLockShared(&lifecycle_lock);

    AcquireSRWLockShared(&visibility_lock);
    st.policy_count = visibility_catalog.count();
    st.policy_generation = visibility_catalog.generation();
    ReleaseSRWLockShared(&visibility_lock);

    st.effective_level = (main_lvl_slot != nullptr) ? *main_lvl_slot : 0u;
    st.magic_hidden_count = magic_hidden_count.load(std::memory_order_relaxed);
    st.magic_shown_count = magic_shown_count.load(std::memory_order_relaxed);
    st.ability_hidden_count = ability_hidden_count.load(std::memory_order_relaxed);
    *output = st;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeReplaceWeaponRules(const SoulspireNativeWeaponRule* entries, uint32_t count) {
    AcquireSRWLockExclusive(&weapon_lock);
    const bool ok = weapon_rule_catalog.replace_all(entries, count);
    ReleaseSRWLockExclusive(&weapon_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall SoulspireNativeClearWeaponRules() {
    AcquireSRWLockExclusive(&weapon_lock);
    weapon_rule_catalog.clear();
    ReleaseSRWLockExclusive(&weapon_lock);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeGetWeaponStatus(SoulspireNativeWeaponStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeWeaponStatus st{};
    st.size = sizeof(st);
    st.version = 1;
    st.expected_hooks = kExpectedHooks;

    AcquireSRWLockShared(&lifecycle_lock);
    uint32_t inst_mask = 0, site_mask = 0, caps = 0;
    collect_hook_state(st.total_hooks, inst_mask, site_mask, caps);
    ReleaseSRWLockShared(&lifecycle_lock);

    AcquireSRWLockShared(&weapon_lock);
    st.rule_count = weapon_rule_catalog.count();
    st.rule_generation = weapon_rule_catalog.generation();
    ReleaseSRWLockShared(&weapon_lock);

    st.effective_level = (main_lvl_slot != nullptr) ? *main_lvl_slot : 0u;
    st.allow_hits = weapon_allow_hits.load(std::memory_order_relaxed);
    st.deny_hits = weapon_deny_hits.load(std::memory_order_relaxed);
    *output = st;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeGetHookDiagnostics(SoulspireNativeHookDiagnostics* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeHookDiagnostics d{};
    d.size = sizeof(d);
    d.version = 1;
    d.expected_hooks = kExpectedHooks;

    AcquireSRWLockShared(&lifecycle_lock);
    collect_hook_state(d.total_hooks, d.installed_mask, d.site_set_mask, d.capabilities);
    d.ffxi_base = hook_diag.ffxi_base;
    d.ffxi_timestamp = hook_diag.ffxi_timestamp;
    d.ffxi_image_size = hook_diag.ffxi_image_size;
    d.init_stage = hook_diag.init_stage;
    d.failed_rva = hook_diag.failed_rva;
    d.failed_index = hook_diag.failed_index;
    std::memcpy(d.observed_bytes, hook_diag.observed_bytes, sizeof(d.observed_bytes));

    if (d.init_stage == SOULSPIRE_NATIVE_INIT_OK && d.total_hooks < d.expected_hooks) {
        for (uint32_t i = 0; i < kExpectedHooks; ++i) {
            if ((d.installed_mask & (1u << i)) == 0) {
                d.failed_index = i;
                d.failed_rva = hook_rva_at(i);
                const uint8_t* site = hook_site_at(i);
                if (site == nullptr && d.ffxi_base != 0 && d.failed_rva != 0) {
                    site = reinterpret_cast<const uint8_t*>(static_cast<uintptr_t>(d.ffxi_base) + d.failed_rva);
                }
                safe_read_bytes(site, d.observed_bytes);
                break;
            }
        }
    }
    ReleaseSRWLockShared(&lifecycle_lock);

    *output = d;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeGetInterfaceInfo(SoulspireNativeInterfaceInfo* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeInterfaceInfo info{};
    info.size = sizeof(info);
    info.abi_version = SOULSPIRE_NATIVE_ABI_VERSION;
    info.expected_hooks = kExpectedHooks;

    AcquireSRWLockShared(&lifecycle_lock);
    uint32_t inst_mask = 0, site_mask = 0;
    collect_hook_state(info.installed_hooks, inst_mask, site_mask, info.capabilities);
    ReleaseSRWLockShared(&lifecycle_lock);

    const SearchPresentationConfig& cfg = active_search_presentation();
    info.enabled_modules_mask = cfg.enabled_modules_mask;
    uint32_t active_mask = 0;
    if ((info.capabilities & (SOULSPIRE_NATIVE_CAP_EQUIPMENT_SOUL_NAME | SOULSPIRE_NATIVE_CAP_SEARCH_SOUL_LABELS)) != 0) {
        active_mask |= (1u << SOULSPIRE_NATIVE_MOD_JOB_IDENTITY);
    }
    if ((info.capabilities & (SOULSPIRE_NATIVE_CAP_MAGIC_MENU_NAMES | SOULSPIRE_NATIVE_CAP_ABILITY_MENU_NAMES)) != 0) {
        active_mask |= (1u << SOULSPIRE_NATIVE_MOD_ACTIONS);
    }
    if ((info.capabilities & (SOULSPIRE_NATIVE_CAP_SOUL_SUB_WEAPON | SOULSPIRE_NATIVE_CAP_SOUL_SUB_2H)) != 0) {
        active_mask |= (1u << SOULSPIRE_NATIVE_MOD_EQUIPMENT);
    }
    if (module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING) && (info.capabilities & SOULSPIRE_NATIVE_CAP_SEARCH_SOUL_LABELS) != 0) {
        active_mask |= (1u << SOULSPIRE_NATIVE_MOD_RENDERING);
    }
    if ((info.capabilities & SOULSPIRE_NATIVE_CAP_DAT_VIRTUALIZATION) != 0) {
        active_mask |= (1u << SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION);
    }
    info.active_modules_mask = active_mask;
    info.menu2fon_banks_used = g_menu2fon_banks_used.load(std::memory_order_relaxed);
    info.menu2fon_banks_max = static_cast<uint32_t>(kMaxMenu2fonBanks);
    info.menu2fon_fallback_draws = g_menu2fon_fallback_draws.load(std::memory_order_relaxed);
    info.config_from_file = cfg.from_file ? 1u : 0u;
    info.log_level = get_log_level();
    std::snprintf(info.project_name, sizeof(info.project_name), "%s", "Soulspire Native");

    const auto* snap = g_active_runtime_identity.load(std::memory_order_acquire);
    const char* active_hash = (snap != nullptr && snap->active) ? snap->registry_hash : kRegistryHash;
    std::snprintf(info.registry_hash, sizeof(info.registry_hash), "%s", active_hash);
    *output = info;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeGetDatVirtualizationStatus(SoulspireNativeDatVirtStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeDatVirtStatus st{};
    dat_virt_mgr.fill_status(st);
    *output = st;
    return 0;
}

static_assert(sizeof(SoulspireNativeStatus) == 68);
static_assert(sizeof(SoulspireNativeActionEntry) == 288);
static_assert(sizeof(SoulspireNativeActionStatus) == 64);
static_assert(sizeof(SoulspireNativeVisibilityEntry) == 16);
static_assert(sizeof(SoulspireNativeVisibilityStatus) == 40);
static_assert(sizeof(SoulspireNativeWeaponRule) == 24);
static_assert(sizeof(SoulspireNativeWeaponStatus) == 36);
static_assert(sizeof(SoulspireNativeHookDiagnostics) == 60);
static_assert(sizeof(SoulspireNativeInterfaceInfo) == 104);
static_assert(sizeof(SoulspireNativeDatVirtStatus) == 172);

// ============================================================================
// Temporary Backwards-Compatible CrystalJobs* Forwarding Exports
// ============================================================================

extern "C" uint32_t __stdcall CrystalJobsInitialize(void) { return SoulspireNativeInitialize(); }
extern "C" uint32_t __stdcall CrystalJobsShutdown(void) { return SoulspireNativeShutdown(); }
extern "C" uint32_t __stdcall CrystalJobsGetStatus(CrystalJobsStatus* s, uint32_t sz) { return SoulspireNativeGetStatus(s, sz); }
extern "C" uint32_t __stdcall CrystalJobsSetState(const uint8_t* b, uint32_t sz) { return SoulspireNativeSetState(b, sz); }
extern "C" uint32_t __stdcall CrystalJobsReplaceCatalog(const CrystalJobsActionEntry* e, uint32_t c) { return SoulspireNativeReplaceCatalog(e, c); }
extern "C" uint32_t __stdcall CrystalJobsUpsertAction(const CrystalJobsActionEntry* e) { return SoulspireNativeUpsertAction(e); }
extern "C" uint32_t __stdcall CrystalJobsClearCatalog(void) { return SoulspireNativeClearCatalog(); }
extern "C" uint32_t __stdcall CrystalJobsSetActiveSoul(uint32_t j, uint32_t b, uint32_t c) { return SoulspireNativeSetActiveSoul(j, b, c); }
extern "C" uint32_t __stdcall CrystalJobsClearActiveSoul(void) { return SoulspireNativeClearActiveSoul(); }
extern "C" uint32_t __stdcall CrystalJobsGetActionStatus(CrystalJobsActionStatus* s, uint32_t sz) { return SoulspireNativeGetActionStatus(s, sz); }
extern "C" uint32_t __stdcall CrystalJobsSetActionRowLimit(uint32_t m) { return SoulspireNativeSetActionRowLimit(m); }
extern "C" uint32_t __stdcall CrystalJobsReplaceVisibility(const CrystalJobsVisibilityEntry* e, uint32_t c) { return SoulspireNativeReplaceVisibility(e, c); }
extern "C" uint32_t __stdcall CrystalJobsClearVisibility(void) { return SoulspireNativeClearVisibility(); }
extern "C" uint32_t __stdcall CrystalJobsGetVisibilityStatus(CrystalJobsVisibilityStatus* s, uint32_t sz) { return SoulspireNativeGetVisibilityStatus(s, sz); }
extern "C" uint32_t __stdcall CrystalJobsReplaceWeaponRules(const CrystalJobsWeaponRule* e, uint32_t c) { return SoulspireNativeReplaceWeaponRules(e, c); }
extern "C" uint32_t __stdcall CrystalJobsClearWeaponRules(void) { return SoulspireNativeClearWeaponRules(); }
extern "C" uint32_t __stdcall CrystalJobsGetWeaponStatus(CrystalJobsWeaponStatus* s, uint32_t sz) { return SoulspireNativeGetWeaponStatus(s, sz); }
extern "C" uint32_t __stdcall CrystalJobsGetHookDiagnostics(CrystalJobsHookDiagnostics* d, uint32_t sz) { return SoulspireNativeGetHookDiagnostics(d, sz); }
extern "C" uint32_t __stdcall CrystalJobsGetIdentityDiagnostics(CrystalJobsIdentityDiagnostics* d, uint32_t sz) { return SoulspireNativeGetIdentityDiagnostics(d, sz); }

// ============================================================================
// Ashita v4 Plugin Entrypoints
// ============================================================================

extern "C" double __stdcall expGetInterfaceVersion(void) {
    return kAshitaInterfaceVersion;
}

extern "C" void* __stdcall expCreatePlugin(const char*) {
    return new (std::nothrow) SoulspireNativePlugin();
}

extern "C" void __stdcall expDestroyPlugin(void* instance) {
    delete static_cast<SoulspireNativePlugin*>(instance);
}
