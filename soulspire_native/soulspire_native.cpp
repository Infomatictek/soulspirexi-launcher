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
#include "rendering/weapon_presentation.h"
#include "menus/menu_hooks.h"
#include "menus/commands_menu.h"
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
static SRWLOCK commands_menu_lock = SRWLOCK_INIT;

static State state;
static Transport transport;
static ActionCatalog action_catalog;
static VisibilityCatalog visibility_catalog;
static WeaponRuleCatalog weapon_rule_catalog;
static WeaponPresentationManager weapon_presentation_mgr;
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
static std::atomic<uint32_t> g_commands_injected{0};
static std::atomic<uint32_t> g_commands_sprite_synthesized{0};
static std::atomic<uint32_t> g_commands_sprite_banks_used{0};
static std::atomic<uint32_t> g_commands_open_injections{0};
static std::atomic<uint32_t> g_commands_nav_overrides{0};
static std::atomic<uint32_t> g_commands_activations{0};
static std::atomic<uint32_t> g_commands_pending_open_requests{0};
static std::atomic<uint32_t> g_commands_last_button_count{kCommandsVanillaButtonCount};
static std::atomic<uint32_t> g_commands_last_frame_height{kCommandsVanillaFrameH};

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
using FfxiOpNew = void* (__cdecl*)(uint32_t);
using FfxiOpDelete = void (__cdecl*)(void*);
using FfxiPlayConfirmSound = void (__cdecl*)(void);
using FfxiFrameUpdateBox = void (__fastcall*)(void*, void*, uint8_t);
using FfxiBtnCtor = void* (__fastcall*)(void*, void*, void*);
using FfxiBtnInit = void (__fastcall*)(void*, void*, const void*);
using FfxiBtnRecalcRect = void (__fastcall*)(void*, void*, int32_t, int32_t, uint8_t);
using FfxiBtnUpdateSprite = void (__fastcall*)(void*, void*, uint8_t);
using FfxiBtnSetState = void (__fastcall*)(void*, void*, uint32_t);
using FfxiPrimSetSelected = void (__fastcall*)(void*, void*, int32_t);
using FfxiListPushBack = void (__fastcall*)(void*, void*, void*);
using FfxiListRemoveNode = void (__fastcall*)(void*, void*, void*);
using FfxiCloseMenu = void (__fastcall*)(void*, void*, void*, int32_t);

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
static FfxiOpNew original_ffxi_new = nullptr;
static FfxiOpDelete original_ffxi_delete = nullptr;
static FfxiPlayConfirmSound original_play_confirm_sound = nullptr;
static FfxiFrameUpdateBox original_frame_update_box = nullptr;
static FfxiBtnCtor original_btn_ctor = nullptr;
static FfxiBtnInit original_btn_init = nullptr;
static FfxiBtnRecalcRect original_btn_recalc_rect = nullptr;
static FfxiBtnUpdateSprite original_btn_update_sprite = nullptr;
static FfxiBtnSetState original_btn_set_state = nullptr;
static FfxiPrimSetSelected original_prim_set_selected = nullptr;
static FfxiListPushBack original_list_push_back = nullptr;
static FfxiListRemoveNode original_list_remove_node = nullptr;
static FfxiCloseMenu original_close_menu = nullptr;

static uintptr_t original_sprite = 0;
static uintptr_t original_sprite_simple = 0;
static uintptr_t original_spell_name = 0;
static uintptr_t original_spell_desc = 0;
static uintptr_t original_ability_name_row = 0;
static uintptr_t original_ability_name_target = 0;
static uintptr_t original_ability_desc = 0;
static uintptr_t original_set_list_count = 0;
static uintptr_t original_spell_elig = 0;
static uintptr_t original_restore_saved_cursor = 0;
static uintptr_t original_get_next_button = 0;
static uintptr_t menuwind_key_item_resume = 0;
static uintptr_t missing_spell_bit_resume = 0;
static uintptr_t soul_sub_weapon_allow_resume = 0;
static uintptr_t soul_sub_weapon_deny_resume = 0;
static uintptr_t soul_sub_menu_allow_resume = 0;
static uintptr_t soul_sub_menu_skip_resume = 0;
static uintptr_t soul_sub_2h_main_allow_resume = 0;
static uintptr_t soul_sub_2h_main_deny_resume = 0;
static uintptr_t soul_pc_sub_model_resume = 0;
static std::atomic<uint32_t> pc_sub_model_calls{0};
static std::atomic<uint32_t> pc_sub_model_remap_hits{0};
static std::atomic<uint32_t> pc_sub_model_deny_disabled{0};
static std::atomic<uint32_t> pc_sub_model_deny_zero_or_shield{0};
static std::atomic<uint32_t> pc_sub_model_deny_actor_id{0};
static std::atomic<uint32_t> pc_sub_model_deny_local_equip{0};
static std::atomic<uint32_t> pc_sub_model_deny_fallback_84{0};
static std::atomic<uint32_t> pc_sub_model_deny_auth{0};
static std::atomic<uint32_t> pc_sub_model_last_actor_id{0};
static std::atomic<uint32_t> pc_sub_model_last_local_char_id{0};
static std::atomic<uint32_t> pc_sub_model_last_is_local{0};
static std::atomic<uint32_t> pc_sub_model_last_look_word{0};
static std::atomic<uint32_t> pc_sub_model_last_sub_model_id{0};
static std::atomic<uint32_t> pc_sub_model_last_result_slot{7};
static std::atomic<uint32_t> pc_sub_model_last_soul_known{0};
static std::atomic<uint32_t> pc_sub_model_last_job{0};
static std::atomic<uint32_t> pc_sub_model_last_branch{0};
static std::atomic<uint32_t> pc_sub_model_last_eff_level{0};
static std::atomic<uint32_t> local_equip_main_item_id{0};
static std::atomic<uint32_t> local_equip_main_skill{0};
static std::atomic<uint32_t> local_equip_sub_item_id{0};
static std::atomic<uint32_t> local_equip_sub_skill{0};

static void** pname_sheet_slot = nullptr;
static void** item_res_mgr_slot = nullptr;
static const uint8_t* main_job_slot = nullptr;
static const uint8_t* main_lvl_slot = nullptr;
static uint8_t** ability_list_slot = nullptr;
static uint8_t** menuwind_singleton_slot = nullptr;
static void* menu_manager_instance = nullptr;

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
        local_equip_main_item_id.store(main_item_id, std::memory_order_relaxed);
        local_equip_main_skill.store(main_skill, std::memory_order_relaxed);
        local_equip_sub_item_id.store(sub_item_id, std::memory_order_relaxed);
        local_equip_sub_skill.store(sub_skill, std::memory_order_relaxed);
        ++weapon_allow_hits;
        return 1;
    }
    ++weapon_deny_hits;
    return 0;
}

// Hook #32 (RVA 0xD3C45 in CXiSkeletonActor::LoadPcEquipmentModels):
// Resolves authorized custom Sub-slot weapon models (slot 7) from the original
// Main-slot FTABLE namespace (slot 6) at runtime while keeping slot 7 as the
// attachment slot so FFXI reuses its native dual-wield Sub-weapon pipeline.
static bool safe_read_actor_server_id(const uint8_t* actor, uint32_t& out_actor_id) noexcept {
    out_actor_id = 0;
    if (actor == nullptr) return false;
#ifdef _MSC_VER
    __try {
        const uint8_t* ent = nullptr;
        std::memcpy(&ent, actor + 0x70, sizeof(ent));
        if (ent == nullptr) return false;
        std::memcpy(&out_actor_id, ent + 0x78, sizeof(out_actor_id));
        return out_actor_id != 0;
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        out_actor_id = 0;
        return false;
    }
#else
    if (!readable_range(actor + 0x70, sizeof(const uint8_t*))) return false;
    const uint8_t* ent = nullptr;
    std::memcpy(&ent, actor + 0x70, sizeof(ent));
    if (ent == nullptr || !readable_range(ent + 0x78, sizeof(uint32_t))) return false;
    std::memcpy(&out_actor_id, ent + 0x78, sizeof(out_actor_id));
    return out_actor_id != 0;
#endif
}

static uint32_t __stdcall soul_resolve_pc_sub_model_table_slot(const uint8_t* actor, uint32_t look_word) noexcept {
    pc_sub_model_calls.fetch_add(1u, std::memory_order_relaxed);
    const uint16_t sub_model_id = static_cast<uint16_t>(look_word & 0x0FFFu);
    pc_sub_model_last_look_word.store(look_word, std::memory_order_relaxed);
    pc_sub_model_last_sub_model_id.store(sub_model_id, std::memory_order_relaxed);
    pc_sub_model_last_result_slot.store(7u, std::memory_order_relaxed);

    if (!module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING)) {
        pc_sub_model_deny_disabled.fetch_add(1u, std::memory_order_relaxed);
        return 7u;
    }
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
    if (!enabled.load(std::memory_order_acquire)) {
        pc_sub_model_deny_disabled.fetch_add(1u, std::memory_order_relaxed);
        return 7u;
    }
#endif
    if (sub_model_id == 0 || is_vanilla_shield_model_id(sub_model_id)) {
        pc_sub_model_deny_zero_or_shield.fetch_add(1u, std::memory_order_relaxed);
        return 7u;
    }

    uint32_t actor_id = 0;
    if (!safe_read_actor_server_id(actor, actor_id)) {
        pc_sub_model_deny_actor_id.fetch_add(1u, std::memory_order_relaxed);
        pc_sub_model_last_actor_id.store(0u, std::memory_order_relaxed);
        return 7u;
    }
    pc_sub_model_last_actor_id.store(actor_id, std::memory_order_relaxed);

    AcquireSRWLockShared(&state_lock);
    const uint32_t local_char_id = (transport.character != 0) ? transport.character : soul_override.character;
    ReleaseSRWLockShared(&state_lock);
    pc_sub_model_last_local_char_id.store(local_char_id, std::memory_order_relaxed);

    const bool is_local = (local_char_id != 0 && actor_id == local_char_id);
    pc_sub_model_last_is_local.store(is_local ? 1u : 0u, std::memory_order_relaxed);
    uint8_t job = 0, branch = 0;
    bool soul_known = false;
    uint8_t effective_level = 0;
    bool has_equipped_skills = false;
    uint16_t main_item_id = 0, main_skill = 0, sub_item_id = 0, sub_skill = 0;

    if (is_local) {
        soul_known = active_action_soul(job, branch);
        effective_level = (main_lvl_slot != nullptr) ? *main_lvl_slot : 0u;
        pc_sub_model_last_soul_known.store(soul_known ? 1u : 0u, std::memory_order_relaxed);
        pc_sub_model_last_job.store(job, std::memory_order_relaxed);
        pc_sub_model_last_branch.store(branch, std::memory_order_relaxed);
        pc_sub_model_last_eff_level.store(effective_level, std::memory_order_relaxed);
        main_item_id = static_cast<uint16_t>(local_equip_main_item_id.load(std::memory_order_relaxed));
        main_skill   = static_cast<uint16_t>(local_equip_main_skill.load(std::memory_order_relaxed));
        sub_item_id  = static_cast<uint16_t>(local_equip_sub_item_id.load(std::memory_order_relaxed));
        sub_skill    = static_cast<uint16_t>(local_equip_sub_skill.load(std::memory_order_relaxed));
        if (main_skill == 0 || sub_skill == 0) {
            pc_sub_model_deny_local_equip.fetch_add(1u, std::memory_order_relaxed);
            return 7u;
        }
        has_equipped_skills = true;
    } else if (sub_model_id == 84u) {
        pc_sub_model_deny_fallback_84.fetch_add(1u, std::memory_order_relaxed);
        return 7u;
    }

    const uint32_t now_ms = static_cast<uint32_t>(GetTickCount());
    AcquireSRWLockShared(&weapon_lock);
    const bool remap = weapon_presentation_mgr.authorizes_sub_main_namespace(
        actor_id, is_local, soul_known, job, branch, effective_level, sub_model_id, now_ms,
        has_equipped_skills, main_skill, main_item_id, sub_skill, sub_item_id);
    ReleaseSRWLockShared(&weapon_lock);

    if (remap) {
        pc_sub_model_remap_hits.fetch_add(1u, std::memory_order_relaxed);
        pc_sub_model_last_result_slot.store(6u, std::memory_order_relaxed);
        return 6u;
    }
    pc_sub_model_deny_auth.fetch_add(1u, std::memory_order_relaxed);
    return 7u;
}

// ============================================================================
// WS3-WEAP-002 — Native 1H Offhand (0x7F Left-Hand) Bone Attachment Reuse
// ============================================================================
// Reuses FFXI's own native 1H offhand bone pipeline (bone 0x7F computed by
// CXiModelPart::UpdateSkeleton @ 0x2A140) per CXiModelMesh* instance without
// mutating shared Main weapon OS2 DAT buffers or duplicating DAT files.

using AttachEquipModelFn = void (__fastcall*)(void* actor, void* edx, void* res_handle,
                                              uint32_t slot_and_model, uint32_t actor_gen, uint8_t flag);
using ModelPartAddMeshFn = void* (__fastcall*)(void* model_part, void* edx, void* os2_res);
using LookupBoneIndexFn  = uint32_t (__fastcall*)(void* model_part, void* edx, int32_t bone_tag);

static AttachEquipModelFn original_attach_equip_model = nullptr;
static ModelPartAddMeshFn original_model_part_add_mesh = nullptr;
static LookupBoneIndexFn  original_lookup_bone_index = nullptr;
static uintptr_t          soul_model_mesh_draw_resume = 0;

struct SubOffhandMeshEntry {
    void* actor      = nullptr;
    void* model_part = nullptr;
    void* mesh       = nullptr;
};

static constexpr size_t kMaxSubOffhandMeshes = 64u;
static SRWLOCK sub_offhand_mesh_lock = SRWLOCK_INIT;
static SubOffhandMeshEntry sub_offhand_meshes[kMaxSubOffhandMeshes]{};
static std::atomic<uint32_t> sub_offhand_mesh_count{0};
static std::atomic<uint32_t> sub_offhand_bone_swaps{0};

static thread_local bool  tls_sub_offhand_attach_active = false;
static thread_local void* tls_sub_offhand_attach_actor  = nullptr;

struct SavedBoneMatrixState {
    bool   active = false;
    float* target = nullptr;
    float  saved[16]{};
};
static thread_local SavedBoneMatrixState tls_saved_main_weapon_bone{};

static void clear_sub_offhand_meshes_for_actor(void* actor) noexcept {
    if (actor == nullptr) return;
    AcquireSRWLockExclusive(&sub_offhand_mesh_lock);
    uint32_t count = 0;
    for (auto& e : sub_offhand_meshes) {
        if (e.actor == actor) {
            e = {};
        } else if (e.mesh != nullptr) {
            ++count;
        }
    }
    sub_offhand_mesh_count.store(count, std::memory_order_release);
    ReleaseSRWLockExclusive(&sub_offhand_mesh_lock);
}

static void clear_all_sub_offhand_meshes() noexcept {
    AcquireSRWLockExclusive(&sub_offhand_mesh_lock);
    for (auto& e : sub_offhand_meshes) {
        e = {};
    }
    sub_offhand_mesh_count.store(0u, std::memory_order_release);
    ReleaseSRWLockExclusive(&sub_offhand_mesh_lock);
}

static void register_sub_offhand_mesh(void* actor, void* model_part, void* mesh) noexcept {
    if (actor == nullptr || model_part == nullptr || mesh == nullptr) return;
    AcquireSRWLockExclusive(&sub_offhand_mesh_lock);
    // Avoid duplicate entry for the same (model_part, mesh)
    SubOffhandMeshEntry* free_slot = nullptr;
    uint32_t count = 0;
    bool exists = false;
    for (auto& e : sub_offhand_meshes) {
        if (e.model_part == model_part && e.mesh == mesh) {
            e.actor = actor;
            exists = true;
        }
        if (e.mesh != nullptr) {
            ++count;
        } else if (free_slot == nullptr) {
            free_slot = &e;
        }
    }
    if (!exists && free_slot != nullptr) {
        free_slot->actor = actor;
        free_slot->model_part = model_part;
        free_slot->mesh = mesh;
        ++count;
    }
    sub_offhand_mesh_count.store(count, std::memory_order_release);
    ReleaseSRWLockExclusive(&sub_offhand_mesh_lock);
}

static bool is_registered_sub_offhand_mesh(void* model_part, void* mesh) noexcept {
    if (model_part == nullptr || mesh == nullptr) return false;
    if (sub_offhand_mesh_count.load(std::memory_order_acquire) == 0u) return false;
    bool found = false;
    AcquireSRWLockShared(&sub_offhand_mesh_lock);
    for (const auto& e : sub_offhand_meshes) {
        if (e.model_part == model_part && e.mesh == mesh) {
            found = true;
            break;
        }
    }
    ReleaseSRWLockShared(&sub_offhand_mesh_lock);
    return found;
}

static bool soul_authorizes_sub_offhand_bone(void* actor, uint32_t sub_model_id_raw) noexcept {
    if (!enabled.load(std::memory_order_acquire) || !module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING)) {
        return false;
    }
    const uint16_t sub_model_id = static_cast<uint16_t>(sub_model_id_raw & 0x0FFFu);
    if (sub_model_id == 0u || is_vanilla_shield_model_id(sub_model_id)) {
        return false;
    }
    uint32_t actor_id = 0;
    if (!safe_read_actor_server_id(static_cast<const uint8_t*>(actor), actor_id)) {
        return false;
    }
    AcquireSRWLockShared(&state_lock);
    const uint32_t local_char_id = (transport.character != 0) ? transport.character : soul_override.character;
    ReleaseSRWLockShared(&state_lock);

    const bool is_local = (local_char_id != 0 && actor_id == local_char_id);
    uint8_t job = 0, branch = 0;
    bool soul_known = false;
    uint8_t effective_level = 0;
    bool has_equipped_skills = false;
    uint16_t main_item_id = 0, main_skill = 0, sub_item_id = 0, sub_skill = 0;
    if (is_local) {
        soul_known = active_action_soul(job, branch);
        effective_level = (main_lvl_slot != nullptr) ? *main_lvl_slot : 0u;
        main_item_id = static_cast<uint16_t>(local_equip_main_item_id.load(std::memory_order_relaxed));
        main_skill   = static_cast<uint16_t>(local_equip_main_skill.load(std::memory_order_relaxed));
        sub_item_id  = static_cast<uint16_t>(local_equip_sub_item_id.load(std::memory_order_relaxed));
        sub_skill    = static_cast<uint16_t>(local_equip_sub_skill.load(std::memory_order_relaxed));
        if (main_skill == 0u || sub_skill == 0u) return false;
        has_equipped_skills = true;
    } else if (sub_model_id == 84u) {
        return false;
    }
    const uint32_t now_ms = static_cast<uint32_t>(GetTickCount());
    AcquireSRWLockShared(&weapon_lock);
    const bool remap = weapon_presentation_mgr.authorizes_sub_main_namespace(
        actor_id, is_local, soul_known, job, branch, effective_level, sub_model_id, now_ms,
        has_equipped_skills, main_skill, main_item_id, sub_skill, sub_item_id);
    ReleaseSRWLockShared(&weapon_lock);
    return remap;
}

static void __fastcall soul_attach_equip_model_hook(
    void* actor, void* edx, void* res_handle, uint32_t slot_and_model, uint32_t actor_gen, uint8_t flag) {
    const uint32_t slot = (slot_and_model >> 12u) & 0x0Fu;
    const bool prev_active = tls_sub_offhand_attach_active;
    void* const prev_actor = tls_sub_offhand_attach_actor;
    if (slot == 7u && actor != nullptr) {
        clear_sub_offhand_meshes_for_actor(actor);
        if (flag != 0u && res_handle != nullptr && soul_authorizes_sub_offhand_bone(actor, slot_and_model)) {
            tls_sub_offhand_attach_actor = actor;
            tls_sub_offhand_attach_active = true;
        } else {
            tls_sub_offhand_attach_actor = nullptr;
            tls_sub_offhand_attach_active = false;
        }
    }
    if (original_attach_equip_model != nullptr) {
        original_attach_equip_model(actor, edx, res_handle, slot_and_model, actor_gen, flag);
    }
    tls_sub_offhand_attach_active = prev_active;
    tls_sub_offhand_attach_actor = prev_actor;
}

static void* __fastcall soul_model_part_add_mesh_hook(void* model_part, void* edx, void* os2_res) {
    void* mesh = (original_model_part_add_mesh != nullptr)
        ? original_model_part_add_mesh(model_part, edx, os2_res)
        : nullptr;
    if (tls_sub_offhand_attach_active && tls_sub_offhand_attach_actor != nullptr &&
        model_part != nullptr && mesh != nullptr) {
        register_sub_offhand_mesh(tls_sub_offhand_attach_actor, model_part, mesh);
    }
    return mesh;
}

static void soul_pre_mesh_draw_swap_impl(void* model_part, void* mesh) noexcept {
    tls_saved_main_weapon_bone.active = false;
    tls_saved_main_weapon_bone.target = nullptr;
    if (!enabled.load(std::memory_order_acquire) || !module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING)) {
        return;
    }
    if (!is_registered_sub_offhand_mesh(model_part, mesh)) {
        return;
    }
    if (original_lookup_bone_index == nullptr) {
        return;
    }
    const uint32_t idx_main = original_lookup_bone_index(model_part, nullptr, 0x7E) & 0xFFu;
    const uint32_t idx_sub  = original_lookup_bone_index(model_part, nullptr, 0x7F) & 0xFFu;
    if (idx_main == 0u || idx_sub == 0u || idx_main == idx_sub || idx_main >= 256u || idx_sub >= 256u) {
        return;
    }
    float* matrices = *reinterpret_cast<float* const*>(reinterpret_cast<uintptr_t>(model_part) + 0x14u);
    if (matrices == nullptr) {
        return;
    }
    float* main_mat = matrices + (static_cast<size_t>(idx_main) * 16u);
    float* sub_mat  = matrices + (static_cast<size_t>(idx_sub) * 16u);
    std::memcpy(tls_saved_main_weapon_bone.saved, main_mat, sizeof(tls_saved_main_weapon_bone.saved));
    std::memcpy(main_mat, sub_mat, sizeof(tls_saved_main_weapon_bone.saved));
    tls_saved_main_weapon_bone.target = main_mat;
    tls_saved_main_weapon_bone.active = true;
    sub_offhand_bone_swaps.fetch_add(1u, std::memory_order_relaxed);
}

static void __stdcall soul_pre_mesh_draw_swap(void* model_part, void* mesh) noexcept {
#ifdef _MSC_VER
    __try {
        soul_pre_mesh_draw_swap_impl(model_part, mesh);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        tls_saved_main_weapon_bone.active = false;
        tls_saved_main_weapon_bone.target = nullptr;
    }
#else
    soul_pre_mesh_draw_swap_impl(model_part, mesh);
#endif
}

static void __stdcall soul_post_mesh_draw_restore() noexcept {
    if (tls_saved_main_weapon_bone.active && tls_saved_main_weapon_bone.target != nullptr) {
        std::memcpy(tls_saved_main_weapon_bone.target, tls_saved_main_weapon_bone.saved,
                    sizeof(tls_saved_main_weapon_bone.saved));
    }
    tls_saved_main_weapon_bone.active = false;
    tls_saved_main_weapon_bone.target = nullptr;
}

static __declspec(naked) void soul_model_mesh_draw_hook() {
    __asm {
        push eax
        push ecx
        push edx
        mov edx, dword ptr [esp + 0x30]
        push ecx
        push edx
        call soul_pre_mesh_draw_swap
        pop edx
        pop ecx
        pop eax
        mov edx, dword ptr [esp + 0x24]
        push ebp
        push edx
        mov edx, dword ptr [esp + 0x34]
        push ebx
        push edx
        call dword ptr [eax + 0x1c]
        push eax
        push ecx
        push edx
        call soul_post_mesh_draw_restore
        pop edx
        pop ecx
        pop eax
        jmp dword ptr [soul_model_mesh_draw_resume]
    }
}

static __declspec(naked) void soul_pc_sub_model_resolve_hook() {
    __asm {
        cmp ebp, 7
        jne stock
        pushfd
        push eax
        push edx
        push ebx
        push edi
        call soul_resolve_pc_sub_model_table_slot
        mov ecx, eax
        pop edx
        pop eax
        popfd
        lea ecx, [ecx + ecx*2]
        shl ecx, 4
        jmp dword ptr [soul_pc_sub_model_resume]
    stock:
        lea ecx, [ebp + ebp*2]
        shl ecx, 4
        jmp dword ptr [soul_pc_sub_model_resume]
    }
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
// Native FFXI Commands Menu ("menu    menuwind") Hooks (Hooks #28 - #31)
// ============================================================================

static const NativeMenuButtonRes g_soulspire_btn_res = make_soulspire_button_res();
static const NativeMenuButtonData g_soulspire_btn_data = {
    &g_soulspire_btn_res,
    nullptr,
    kCommandsSoulspireHelp,
    kCommandsSoulspireTitle,
    0u
};

static std::unique_ptr<SoulspireMenuSpriteBank> g_commands_sprite_banks[kMaxCommandsSpriteBanks]{};
static size_t g_last_commands_sprite_bank = 0;
static std::atomic<const uint8_t*> g_active_menuwind_data{nullptr};
static std::atomic<bool> g_commands_ever_injected{false};

#if defined(SOULSPIRE_NATIVE_SELFTEST) || defined(CRYSTALJOBS_SELFTEST)
static void reset_commands_menu_state_for_test() noexcept {
    AcquireSRWLockExclusive(&commands_menu_lock);
    for (size_t i = 0; i < kMaxCommandsSpriteBanks; ++i) {
        g_commands_sprite_banks[i].reset();
    }
    g_last_commands_sprite_bank = 0;
    ReleaseSRWLockExclusive(&commands_menu_lock);
    g_active_menuwind_data.store(nullptr, std::memory_order_release);
    g_commands_ever_injected.store(false, std::memory_order_release);
    g_commands_injected.store(0, std::memory_order_release);
    g_commands_sprite_synthesized.store(0, std::memory_order_release);
    g_commands_sprite_banks_used.store(0, std::memory_order_release);
    g_commands_open_injections.store(0, std::memory_order_release);
    g_commands_nav_overrides.store(0, std::memory_order_release);
    g_commands_activations.store(0, std::memory_order_release);
    g_commands_pending_open_requests.store(0, std::memory_order_release);
    g_commands_last_button_count.store(kCommandsVanillaButtonCount, std::memory_order_release);
    g_commands_last_frame_height.store(kCommandsVanillaFrameH, std::memory_order_release);
}
#endif

static uint8_t* acquire_soulspire_menu_sprite(
    const uint8_t* const src_sprites[kCommandsSourceSpriteCount]) noexcept {
    if (src_sprites == nullptr || src_sprites[0] == nullptr) return nullptr;
    const uint8_t* status_node0 = nullptr;
    const uint8_t* status_tile0 = nullptr;
    if (!sprite_list_tile_at(src_sprites[0], 0, status_node0, status_tile0)) return nullptr;

    AcquireSRWLockExclusive(&commands_menu_lock);
    if (g_last_commands_sprite_bank < kMaxCommandsSpriteBanks &&
        g_commands_sprite_banks[g_last_commands_sprite_bank] != nullptr &&
        g_commands_sprite_banks[g_last_commands_sprite_bank]->active &&
        commands_sprite_bank_key_matches(
            g_commands_sprite_banks[g_last_commands_sprite_bank]->key, src_sprites, status_tile0)) {
        uint8_t* sp = g_commands_sprite_banks[g_last_commands_sprite_bank]->sprite;
        ReleaseSRWLockExclusive(&commands_menu_lock);
        g_commands_sprite_synthesized.store(1u, std::memory_order_relaxed);
        return sp;
    }

    for (size_t i = 0; i < kMaxCommandsSpriteBanks; ++i) {
        if (g_commands_sprite_banks[i] != nullptr &&
            g_commands_sprite_banks[i]->active &&
            commands_sprite_bank_key_matches(g_commands_sprite_banks[i]->key, src_sprites, status_tile0)) {
            g_last_commands_sprite_bank = i;
            uint8_t* sp = g_commands_sprite_banks[i]->sprite;
            ReleaseSRWLockExclusive(&commands_menu_lock);
            g_commands_sprite_synthesized.store(1u, std::memory_order_relaxed);
            return sp;
        }
    }

    for (size_t i = 0; i < kMaxCommandsSpriteBanks; ++i) {
        if (g_commands_sprite_banks[i] == nullptr) {
            auto fresh = std::unique_ptr<SoulspireMenuSpriteBank>(new (std::nothrow) SoulspireMenuSpriteBank{});
            if (fresh == nullptr) break;
            if (!synthesize_soulspire_menu_sprite(*fresh, src_sprites)) break;
            uint8_t* sp = fresh->sprite;
            g_commands_sprite_banks[i] = std::move(fresh);
            g_last_commands_sprite_bank = i;
            g_commands_sprite_banks_used.fetch_add(1u, std::memory_order_relaxed);
            ReleaseSRWLockExclusive(&commands_menu_lock);
            g_commands_sprite_synthesized.store(1u, std::memory_order_relaxed);
            return sp;
        }
    }

    ReleaseSRWLockExclusive(&commands_menu_lock);
    g_commands_sprite_synthesized.store(0u, std::memory_order_relaxed);
    return nullptr;
}

static bool inject_commands_menu_entry_impl(uint8_t* prim) noexcept {
    if (prim == nullptr) return false;
    uint8_t* menu_data = nullptr;
    std::memcpy(&menu_data, prim + 0x04, sizeof(menu_data));
    if (!is_commands_menu_form(menu_data)) return false;

    if (original_ffxi_new == nullptr || original_btn_ctor == nullptr ||
        original_btn_init == nullptr || original_btn_recalc_rect == nullptr ||
        original_btn_update_sprite == nullptr || original_btn_set_state == nullptr ||
        original_list_push_back == nullptr || original_frame_update_box == nullptr) {
        return false;
    }

    uint8_t* frame = nullptr;
    uint8_t* existing_btn16 = nullptr;
    uint8_t* shifted_buttons[16]{};
    size_t shifted_count = 0;
    const uint8_t* src_sprites[kCommandsSourceSpriteCount]{};

    uint8_t* node = nullptr;
    std::memcpy(&node, prim + 0x14, sizeof(node));
    uint32_t guard = 0;
    while (node != nullptr && guard < 128u) {
        ++guard;
        if (node[0x14] == 0) {
            uint8_t* elem = nullptr;
            std::memcpy(&elem, node + 0x10, sizeof(elem));
            if (elem != nullptr) {
                int16_t elem_type = -1;
                std::memcpy(&elem_type, elem, sizeof(elem_type));
                if (elem_type == 0 && frame == nullptr) {
                    frame = elem;
                } else if (elem_type == 1) {
                    int16_t btn_id = 0;
                    std::memcpy(&btn_id, elem + 0x3A, sizeof(btn_id));
                    if (btn_id == kCommandsSoulspireButtonId) {
                        existing_btn16 = elem;
                    } else {
                        if (is_commands_shifted_row_button(btn_id) && shifted_count < 16u) {
                            shifted_buttons[shifted_count++] = elem;
                        }
                        for (size_t s = 0; s < kCommandsSourceSpriteCount; ++s) {
                            if (btn_id == kCommandsSourceButtonIds[s]) {
                                const uint8_t* sp = nullptr;
                                std::memcpy(&sp, elem + 0x04, sizeof(sp));
                                src_sprites[s] = sp;
                            }
                        }
                    }
                }
            }
        }
        uint8_t* next = nullptr;
        std::memcpy(&next, node + 0x00, sizeof(next));
        node = next;
    }

    uint8_t* soulspire_sprite = acquire_soulspire_menu_sprite(src_sprites);
    if (soulspire_sprite == nullptr) {
        log_message(LOG_LEVEL_WARN,
            "Skipping native Commands menu injection: unable to synthesize Soulspire sprite from live menuwind tiles.");
        return false;
    }

    int16_t origin_x = 0, origin_y = 0;
    std::memcpy(&origin_x, prim + 0x52, sizeof(origin_x));
    std::memcpy(&origin_y, prim + 0x54, sizeof(origin_y));
    const uint8_t use_scale = prim[0x99];

    // 1. Expand menuwind frame from 202px to 218px (+16px) idempotently.
    if (frame != nullptr) {
        uint8_t* frame_data = nullptr;
        std::memcpy(&frame_data, frame + 0x30, sizeof(frame_data));
        uint8_t* frame_res = nullptr;
        if (frame_data != nullptr) {
            std::memcpy(&frame_res, frame_data, sizeof(frame_res));
        }
        if (frame_res != nullptr) {
            int16_t res_h = 0;
            std::memcpy(&res_h, frame_res + 0x0C, sizeof(res_h));
            if (res_h == kCommandsVanillaFrameH) {
                res_h = kCommandsExpandedFrameH;
                std::memcpy(frame_res + 0x0C, &res_h, sizeof(res_h));
            }
            if (use_scale == 0) {
                int16_t scr_h = 0;
                std::memcpy(&scr_h, frame + 0x24, sizeof(scr_h));
                if (scr_h == kCommandsVanillaFrameH) {
                    scr_h = kCommandsExpandedFrameH;
                    std::memcpy(frame + 0x24, &scr_h, sizeof(scr_h));
                }
            }
            original_frame_update_box(frame, nullptr, use_scale);
            int16_t frame_y = 0, frame_h = 0;
            std::memcpy(&frame_y, frame + 0x1C, sizeof(frame_y));
            std::memcpy(&frame_h, frame + 0x24, sizeof(frame_h));
            const int16_t new_bottom = static_cast<int16_t>(frame_y + frame_h);
            std::memcpy(prim + 0x40, &new_bottom, sizeof(new_bottom));
            std::memcpy(prim + 0x48, &new_bottom, sizeof(new_bottom));
            g_commands_last_frame_height.store(static_cast<uint32_t>(res_h), std::memory_order_relaxed);
        }
    }

    // 2. Shift vanilla rows 2..12 down by +16px idempotently (Buttons 1, 13, 14, 15 stay put).
    for (size_t i = 0; i < shifted_count; ++i) {
        uint8_t* btn = shifted_buttons[i];
        int16_t btn_id = 0, rel_top = 0, rel_bottom = 0;
        std::memcpy(&btn_id, btn + 0x3A, sizeof(btn_id));
        std::memcpy(&rel_top, btn + 0x34, sizeof(rel_top));
        std::memcpy(&rel_bottom, btn + 0x38, sizeof(rel_bottom));
        const int16_t vanilla_y = commands_vanilla_row_y(btn_id);
        if (vanilla_y >= 0 && rel_top == vanilla_y) {
            rel_top = static_cast<int16_t>(rel_top + kCommandsRowPitchPx);
            rel_bottom = static_cast<int16_t>(rel_bottom + kCommandsRowPitchPx);
            std::memcpy(btn + 0x34, &rel_top, sizeof(rel_top));
            std::memcpy(btn + 0x38, &rel_bottom, sizeof(rel_bottom));
            original_btn_recalc_rect(btn, nullptr, static_cast<int32_t>(origin_x), static_cast<int32_t>(origin_y), use_scale);
        }
    }

    // 3. Allocate & insert Btn 16 ("Soulspire") if not already present on this primitive.
    if (existing_btn16 == nullptr) {
        void* raw = original_ffxi_new(0x60u);
        if (raw == nullptr) return false;
        uint8_t* btn16 = static_cast<uint8_t*>(original_btn_ctor(raw, nullptr, prim));
        if (btn16 == nullptr) {
            if (original_ffxi_delete != nullptr) original_ffxi_delete(raw);
            return false;
        }
        int16_t btn_count = 0;
        std::memcpy(&btn_count, prim + 0x58, sizeof(btn_count));
        ++btn_count;
        std::memcpy(prim + 0x58, &btn_count, sizeof(btn_count));

        original_btn_init(btn16, nullptr, &g_soulspire_btn_data);
        std::memcpy(btn16 + 0x08, &soulspire_sprite, sizeof(soulspire_sprite));
        btn16[0x48] = 0; // Normal pill highlight & press animation
        original_btn_recalc_rect(btn16, nullptr, static_cast<int32_t>(origin_x), static_cast<int32_t>(origin_y), use_scale);
        original_btn_update_sprite(btn16, nullptr, use_scale);
        original_btn_set_state(btn16, nullptr, kCommandsButtonStateEnabled);
        original_list_push_back(prim + 0x14, nullptr, btn16);
        g_commands_open_injections.fetch_add(1u, std::memory_order_relaxed);
    } else {
        std::memcpy(existing_btn16 + 0x08, &soulspire_sprite, sizeof(soulspire_sprite));
        std::memcpy(existing_btn16 + 0x04, &soulspire_sprite, sizeof(soulspire_sprite));
        existing_btn16[0x48] = 0;
        original_btn_recalc_rect(existing_btn16, nullptr, static_cast<int32_t>(origin_x), static_cast<int32_t>(origin_y), use_scale);
        original_btn_update_sprite(existing_btn16, nullptr, use_scale);
        uint32_t cur_state = 0;
        std::memcpy(&cur_state, existing_btn16 + 0x10, sizeof(cur_state));
        if (cur_state == kCommandsButtonStatePressed) {
            original_btn_set_state(existing_btn16, nullptr, kCommandsButtonStateEnabled);
        }
    }

    int16_t final_btn_count = 0;
    std::memcpy(&final_btn_count, prim + 0x58, sizeof(final_btn_count));
    g_commands_last_button_count.store(static_cast<uint32_t>(final_btn_count), std::memory_order_relaxed);
    g_active_menuwind_data.store(menu_data, std::memory_order_release);
    g_commands_ever_injected.store(true, std::memory_order_release);
    g_commands_injected.store(1u, std::memory_order_release);
    return true;
}

static bool restore_commands_menu_entry_on_prim(uint8_t* prim) noexcept {
    if (prim == nullptr) return false;
    uint8_t* menu_data = nullptr;
    std::memcpy(&menu_data, prim + 0x04, sizeof(menu_data));
    if (!is_commands_menu_form(menu_data)) return false;

    int16_t origin_x = 0, origin_y = 0;
    std::memcpy(&origin_x, prim + 0x52, sizeof(origin_x));
    std::memcpy(&origin_y, prim + 0x54, sizeof(origin_y));
    const uint8_t use_scale = prim[0x99];

    // If saved_cursor or current selection points at Btn 16, reset safely to Status (Btn 1).
    int16_t saved_cursor = 0;
    std::memcpy(&saved_cursor, menu_data + 0x1A, sizeof(saved_cursor));
    if (saved_cursor == kCommandsSoulspireButtonId) {
        saved_cursor = 1;
        std::memcpy(menu_data + 0x1A, &saved_cursor, sizeof(saved_cursor));
    }
    int16_t selected_id = 0;
    std::memcpy(&selected_id, prim + 0x4C, sizeof(selected_id));
    if (selected_id == kCommandsSoulspireButtonId && original_prim_set_selected != nullptr) {
        original_prim_set_selected(prim, nullptr, 1);
    }

    uint8_t* frame = nullptr;
    uint8_t* btn16_node = nullptr;
    uint8_t* btn16_elem = nullptr;
    uint8_t* shifted_buttons[16]{};
    size_t shifted_count = 0;

    uint8_t* node = nullptr;
    std::memcpy(&node, prim + 0x14, sizeof(node));
    uint32_t guard = 0;
    while (node != nullptr && guard < 128u) {
        ++guard;
        uint8_t* next = nullptr;
        std::memcpy(&next, node + 0x00, sizeof(next));
        if (node[0x14] == 0) {
            uint8_t* elem = nullptr;
            std::memcpy(&elem, node + 0x10, sizeof(elem));
            if (elem != nullptr) {
                int16_t elem_type = -1;
                std::memcpy(&elem_type, elem, sizeof(elem_type));
                if (elem_type == 0 && frame == nullptr) {
                    frame = elem;
                } else if (elem_type == 1) {
                    int16_t btn_id = 0;
                    std::memcpy(&btn_id, elem + 0x3A, sizeof(btn_id));
                    if (btn_id == kCommandsSoulspireButtonId) {
                        btn16_node = node;
                        btn16_elem = elem;
                    } else if (is_commands_shifted_row_button(btn_id) && shifted_count < 16u) {
                        shifted_buttons[shifted_count++] = elem;
                    }
                }
            }
        }
        node = next;
    }

    // Restore shifted buttons 2..12 back to exact vanilla Y positions.
    for (size_t i = 0; i < shifted_count; ++i) {
        uint8_t* btn = shifted_buttons[i];
        int16_t btn_id = 0, rel_top = 0, rel_bottom = 0;
        std::memcpy(&btn_id, btn + 0x3A, sizeof(btn_id));
        std::memcpy(&rel_top, btn + 0x34, sizeof(rel_top));
        std::memcpy(&rel_bottom, btn + 0x38, sizeof(rel_bottom));
        const int16_t shifted_y = commands_target_row_y(btn_id, true);
        if (shifted_y >= 0 && rel_top == shifted_y) {
            rel_top = static_cast<int16_t>(rel_top - kCommandsRowPitchPx);
            rel_bottom = static_cast<int16_t>(rel_bottom - kCommandsRowPitchPx);
            std::memcpy(btn + 0x34, &rel_top, sizeof(rel_top));
            std::memcpy(btn + 0x38, &rel_bottom, sizeof(rel_bottom));
            if (original_btn_recalc_rect != nullptr) {
                original_btn_recalc_rect(btn, nullptr, static_cast<int32_t>(origin_x), static_cast<int32_t>(origin_y), use_scale);
            }
        }
    }

    // Remove and free Btn 16 if present.
    if (btn16_node != nullptr && btn16_elem != nullptr &&
        original_list_remove_node != nullptr && original_ffxi_delete != nullptr) {
        original_list_remove_node(prim + 0x14, nullptr, btn16_node);
        original_ffxi_delete(btn16_elem);
        int16_t btn_count = 0;
        std::memcpy(&btn_count, prim + 0x58, sizeof(btn_count));
        if (btn_count > kCommandsVanillaButtonCount) {
            --btn_count;
            std::memcpy(prim + 0x58, &btn_count, sizeof(btn_count));
        }
    }

    // Restore frame height 218 -> 202.
    if (frame != nullptr) {
        uint8_t* frame_data = nullptr;
        std::memcpy(&frame_data, frame + 0x30, sizeof(frame_data));
        uint8_t* frame_res = nullptr;
        if (frame_data != nullptr) {
            std::memcpy(&frame_res, frame_data, sizeof(frame_res));
        }
        if (frame_res != nullptr) {
            int16_t res_h = 0;
            std::memcpy(&res_h, frame_res + 0x0C, sizeof(res_h));
            if (res_h == kCommandsExpandedFrameH) {
                res_h = kCommandsVanillaFrameH;
                std::memcpy(frame_res + 0x0C, &res_h, sizeof(res_h));
            }
            if (use_scale == 0) {
                int16_t scr_h = 0;
                std::memcpy(&scr_h, frame + 0x24, sizeof(scr_h));
                if (scr_h == kCommandsExpandedFrameH) {
                    scr_h = kCommandsVanillaFrameH;
                    std::memcpy(frame + 0x24, &scr_h, sizeof(scr_h));
                }
            }
            if (original_frame_update_box != nullptr) {
                original_frame_update_box(frame, nullptr, use_scale);
            }
            int16_t frame_y = 0, frame_h = 0;
            std::memcpy(&frame_y, frame + 0x1C, sizeof(frame_y));
            std::memcpy(&frame_h, frame + 0x24, sizeof(frame_h));
            const int16_t restored_bottom = static_cast<int16_t>(frame_y + frame_h);
            std::memcpy(prim + 0x40, &restored_bottom, sizeof(restored_bottom));
            std::memcpy(prim + 0x48, &restored_bottom, sizeof(restored_bottom));
        }
    }

    g_commands_injected.store(0u, std::memory_order_release);
    g_active_menuwind_data.store(nullptr, std::memory_order_release);
    g_commands_last_button_count.store(kCommandsVanillaButtonCount, std::memory_order_relaxed);
    g_commands_last_frame_height.store(kCommandsVanillaFrameH, std::memory_order_relaxed);
    return true;
}

static void restore_live_commands_menu_if_present() noexcept {
    if (!g_commands_ever_injected.load(std::memory_order_acquire)) return;
    if (menuwind_singleton_slot == nullptr) {
        g_commands_injected.store(0u, std::memory_order_release);
        g_active_menuwind_data.store(nullptr, std::memory_order_release);
        return;
    }
#ifdef _MSC_VER
    __try {
        uint8_t* mw = *menuwind_singleton_slot;
        if (mw != nullptr) {
            uint8_t* prim = nullptr;
            std::memcpy(&prim, mw + 0x08, sizeof(prim));
            if (prim != nullptr) {
                restore_commands_menu_entry_on_prim(prim);
            }
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        // Ignore teardown races if FFXI already destroyed CMenuWind during shutdown.
    }
#else
    uint8_t* mw = *menuwind_singleton_slot;
    if (mw != nullptr && readable_range(mw + 0x08, sizeof(uint8_t*))) {
        uint8_t* prim = nullptr;
        std::memcpy(&prim, mw + 0x08, sizeof(prim));
        if (prim != nullptr && readable_range(prim, 0x9A)) {
            restore_commands_menu_entry_on_prim(prim);
        }
    }
#endif
    g_commands_injected.store(0u, std::memory_order_release);
    g_active_menuwind_data.store(nullptr, std::memory_order_release);
}

static void __stdcall on_menuwind_before_restore_cursor(uint8_t* prim) noexcept {
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
    if (!enabled.load(std::memory_order_acquire)) return;
#endif
    if (prim == nullptr) return;
#ifdef _MSC_VER
    __try {
        inject_commands_menu_entry_impl(prim);
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        log_message(LOG_LEVEL_ERROR, "Exception caught during native Commands menu injection; keeping vanilla menu.");
    }
#else
    inject_commands_menu_entry_impl(prim);
#endif
}

static int32_t __stdcall resolve_menuwind_next_button_hook(
    const uint8_t* menu_data,
    int32_t cur_btn,
    int32_t dir_key) noexcept {
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
    if (!enabled.load(std::memory_order_acquire)) return 0;
#endif
    if (menu_data == nullptr || menu_data != g_active_menuwind_data.load(std::memory_order_acquire)) return 0;
    const bool injected = g_commands_injected.load(std::memory_order_acquire) != 0;
    const int16_t override_btn = resolve_commands_menu_next_button(
        static_cast<int16_t>(cur_btn), static_cast<int16_t>(dir_key), injected);
    if (override_btn > 0) {
        g_commands_nav_overrides.fetch_add(1u, std::memory_order_relaxed);
        return static_cast<int32_t>(override_btn);
    }
    return 0;
}

static uint8_t __stdcall handle_menuwind_key_item(
    uint8_t* menuwind,
    int32_t key,
    int32_t btn_id) noexcept {
#if !defined(SOULSPIRE_NATIVE_SELFTEST) && !defined(CRYSTALJOBS_SELFTEST)
    if (!enabled.load(std::memory_order_acquire)) return 0;
#endif
    if (key != kCommandsKeyConfirm || btn_id != kCommandsSoulspireButtonId) return 0;
    if (g_commands_injected.load(std::memory_order_acquire) == 0) return 0;

    if (original_play_confirm_sound != nullptr) {
        original_play_confirm_sound();
    }
    if (menuwind != nullptr && original_close_menu != nullptr && menu_manager_instance != nullptr) {
        uint8_t* prim = nullptr;
        std::memcpy(&prim, menuwind + 0x08, sizeof(prim));
        if (prim != nullptr) {
            original_close_menu(menu_manager_instance, nullptr, prim, 1);
        }
    }
    g_commands_activations.fetch_add(1u, std::memory_order_relaxed);
    g_commands_pending_open_requests.fetch_add(1u, std::memory_order_acq_rel);
    return 1;
}

static __declspec(naked) void menuwind_restore_cursor_hook() {
    __asm {
        pushad
        push ecx
        call on_menuwind_before_restore_cursor
        popad
        jmp dword ptr [original_restore_saved_cursor]
    }
}

static __declspec(naked) void menuwind_next_button_hook() {
    __asm {
        pushad
        movsx eax, word ptr [esp + 40]
        movsx edx, word ptr [esp + 36]
        push eax
        push edx
        push ecx
        call resolve_menuwind_next_button_hook
        test eax, eax
        jz stock
        mov [esp + 28], eax
        popad
        ret 8
    stock:
        popad
        jmp dword ptr [original_get_next_button]
    }
}

static __declspec(naked) void menuwind_key_item_hook() {
    __asm {
        pushad
        movsx eax, word ptr [esp + 40]
        movsx edx, word ptr [esp + 36]
        push eax
        push edx
        push ecx
        call handle_menuwind_key_item
        test al, al
        jz stock
        popad
        ret 8
    stock:
        popad
        movsx eax, word ptr [esp + 4]
        jmp dword ptr [menuwind_key_item_resume]
    }
}

// ============================================================================
// Centralized 31-Hook Registry & Lifecycle Management
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
    {0x15F9B8, reinterpret_cast<void*>(&menuwind_restore_cursor_hook)},// Bit 22 (#28 / OpenMenu cached RestoreSavedCursor)
    {0x15FA90, reinterpret_cast<void*>(&menuwind_restore_cursor_hook)},// Bit 23 (#29 / OpenMenu fresh RestoreSavedCursor)
    {0x11979C, reinterpret_cast<void*>(&menuwind_next_button_hook)},   // Bit 24 (#30 / CTkMenuData::GetNextButton)
};

static PrologueDetour can_use_spell_detour{0x22CDE0, reinterpret_cast<void*>(&magic_list_filter_hook), 0xA1u};        // Bit 25 (#23)
static PrologueDetour missing_spell_bit_detour{0x22CB44, reinterpret_cast<void*>(&missing_spell_bit_hook), 0xBDu};    // Bit 26 (#24)
static PrologueDetour soul_sub_weapon_detour{0x133D56, reinterpret_cast<void*>(&soul_sub_weapon_hook), 0x68u};        // Bit 27 (#25)
static PrologueDetour soul_sub_menu_filter_detour{0x21DF85, reinterpret_cast<void*>(&soul_sub_menu_filter_hook), 0x85u}; // Bit 28 (#26)
static PrologueDetour soul_sub_2h_main_detour{0x133DD3, reinterpret_cast<void*>(&soul_sub_2h_main_hook), 0x68u};      // Bit 29 (#27)
static PrologueDetour menuwind_key_item_detour{0x141800, reinterpret_cast<void*>(&menuwind_key_item_hook), 0x0Fu};    // Bit 30 (#31 / CMenuWind::OnKeyItem)
static PrologueDetour soul_pc_sub_model_detour{0x0D3C45, reinterpret_cast<void*>(&soul_pc_sub_model_resolve_hook), 0x8Du}; // Bit 31 (#32 / PC Sub->Main FTABLE namespace)

// Additive Native 1H Offhand (0x7F left-hand) bone attachment hooks (WS3-WEAP-002).
// Kept outside patches[0..24]/detours[0..6] so kExpectedHooks stays 32 and installed_mask bits 0..31 remain ABI-stable.
static PrologueDetour soul_attach_equip_model_detour{0x0D0B50, reinterpret_cast<void*>(&soul_attach_equip_model_hook), 0x8Au};
static Patch          soul_model_part_add_mesh_patch{0x0CFA89, reinterpret_cast<void*>(&soul_model_part_add_mesh_hook)};
static PrologueDetour soul_model_mesh_draw_detour{0x02A6B5, reinterpret_cast<void*>(&soul_model_mesh_draw_hook), 0x8Bu};

static bool offhand_bone_hooks_installed() noexcept {
    return soul_attach_equip_model_detour.site != nullptr &&
           std::memcmp(soul_attach_equip_model_detour.site, soul_attach_equip_model_detour.installed, 5) == 0 &&
           soul_model_part_add_mesh_patch.site != nullptr &&
           std::memcmp(soul_model_part_add_mesh_patch.site, soul_model_part_add_mesh_patch.installed, 5) == 0 &&
           soul_model_mesh_draw_detour.site != nullptr &&
           std::memcmp(soul_model_mesh_draw_detour.site, soul_model_mesh_draw_detour.installed, 5) == 0;
}

static constexpr uint32_t kPatchCount = static_cast<uint32_t>(sizeof(patches) / sizeof(*patches));
static constexpr uint32_t kDetourCount = 7u;
static constexpr uint32_t kExpectedHooks = kPatchCount + kDetourCount;
static_assert(kPatchCount == 25u);
static_assert(kExpectedHooks == 32u);
static_assert(kExpectedHooks == SOULSPIRE_NATIVE_EXPECTED_HOOKS);

static PrologueDetour* detour_at(uint32_t idx) noexcept {
    switch (idx) {
        case 0: return &can_use_spell_detour;
        case 1: return &missing_spell_bit_detour;
        case 2: return &soul_sub_weapon_detour;
        case 3: return &soul_sub_menu_filter_detour;
        case 4: return &soul_sub_2h_main_detour;
        case 5: return &menuwind_key_item_detour;
        case 6: return &soul_pc_sub_model_detour;
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
        if ((soul_attach_equip_model_detour.rva == signature.rva && soul_attach_equip_model_detour.site != nullptr &&
             std::memcmp(soul_attach_equip_model_detour.site, soul_attach_equip_model_detour.installed, 5) == 0) ||
            (soul_model_part_add_mesh_patch.rva == signature.rva && soul_model_part_add_mesh_patch.site != nullptr &&
             std::memcmp(soul_model_part_add_mesh_patch.site, soul_model_part_add_mesh_patch.installed, 5) == 0) ||
            (soul_model_mesh_draw_detour.rva == signature.rva && soul_model_mesh_draw_detour.site != nullptr &&
             std::memcmp(soul_model_mesh_draw_detour.site, soul_model_mesh_draw_detour.installed, 5) == 0)) {
            skip = 5;
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
        if (patch_installed_at(0x15F9B8) &&
            patch_installed_at(0x15FA90) &&
            patch_installed_at(0x11979C) &&
            ((installed_mask & (1u << (kPatchCount + 5u))) != 0)) {
            caps |= SOULSPIRE_NATIVE_CAP_COMMANDS_MENU_ENTRY;
        }
        if (module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING) &&
            ((installed_mask & (1u << (kPatchCount + 6u))) != 0)) {
            caps |= SOULSPIRE_NATIVE_CAP_WEAPON_MODEL_RESOLVE;
        }
        if (module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING) && offhand_bone_hooks_installed()) {
            caps |= SOULSPIRE_NATIVE_CAP_WEAPON_OFFHAND_BONE;
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

    // Step 2: Restore additive offhand-bone hooks, all 7 detours, and 25 CALL patches BEFORE clearing pointers.
    uint32_t failure = 0;
    if (!soul_model_mesh_draw_detour.restore()) failure = 3;
    if (!soul_model_part_add_mesh_patch.restore()) failure = 3;
    if (!soul_attach_equip_model_detour.restore()) failure = 3;
    clear_all_sub_offhand_meshes();
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

    // Step 2b: Restore live menu    menuwind layout & remove injected Soulspire button if still open.
    restore_live_commands_menu_if_present();
    g_commands_pending_open_requests.store(0u, std::memory_order_release);

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
        menuwind_singleton_slot = nullptr;
        menu_manager_instance = nullptr;
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
    AcquireSRWLockExclusive(&weapon_lock);
    load_runtime_resources(mod, action_row_max_chars, &weapon_rule_catalog, &weapon_presentation_mgr);
    ReleaseSRWLockExclusive(&weapon_lock);
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
    menuwind_singleton_slot = reinterpret_cast<uint8_t**>(base + 0x5793F4);
    menu_manager_instance = reinterpret_cast<void*>(base + 0x6229F0);
    original_map_decode = reinterpret_cast<MapDecode>(base + 0xDD6C0);
    original_map_encode = reinterpret_cast<MapEncode>(base + 0xDF7C0);
    original_ffxi_new = reinterpret_cast<FfxiOpNew>(base + 0x3131FB);
    original_ffxi_delete = reinterpret_cast<FfxiOpDelete>(base + 0x3131F0);
    original_play_confirm_sound = reinterpret_cast<FfxiPlayConfirmSound>(base + 0x037B90);
    original_frame_update_box = reinterpret_cast<FfxiFrameUpdateBox>(base + 0x11A9E0);
    original_btn_ctor = reinterpret_cast<FfxiBtnCtor>(base + 0x11AD60);
    original_btn_init = reinterpret_cast<FfxiBtnInit>(base + 0x11AEE0);
    original_btn_recalc_rect = reinterpret_cast<FfxiBtnRecalcRect>(base + 0x11AF60);
    original_btn_update_sprite = reinterpret_cast<FfxiBtnUpdateSprite>(base + 0x11B090);
    original_btn_set_state = reinterpret_cast<FfxiBtnSetState>(base + 0x11AE00);
    original_prim_set_selected = reinterpret_cast<FfxiPrimSetSelected>(base + 0x11A320);
    original_list_push_back = reinterpret_cast<FfxiListPushBack>(base + 0x127910);
    original_list_remove_node = reinterpret_cast<FfxiListRemoveNode>(base + 0x127A10);
    original_close_menu = reinterpret_cast<FfxiCloseMenu>(base + 0x15FD60);
    original_restore_saved_cursor = reinterpret_cast<uintptr_t>(base + 0x119D00);
    original_get_next_button = reinterpret_cast<uintptr_t>(base + 0x11C6B0);

    // Pre-populate all detour resume targets BEFORE installing any hook.
    menuwind_key_item_resume = reinterpret_cast<uintptr_t>(base + 0x141805);
    missing_spell_bit_resume = reinterpret_cast<uintptr_t>(base + 0x22CB49);
    soul_sub_weapon_deny_resume = reinterpret_cast<uintptr_t>(base + 0x133D5B);
    soul_sub_weapon_allow_resume = reinterpret_cast<uintptr_t>(base + 0x133D65);
    soul_sub_menu_allow_resume = reinterpret_cast<uintptr_t>(base + 0x21DF8A);
    soul_sub_menu_skip_resume = reinterpret_cast<uintptr_t>(base + 0x21DFE9);
    soul_sub_2h_main_deny_resume = reinterpret_cast<uintptr_t>(base + 0x133DD8);
    // 0x133DCB (`je 0x133E05`) is the exact non-2H allow target in EquipMenu::TryEquipItem;
    // 0x133DEB sits inside the push 0x99 error-return tail (`xor al, al; ret 0x10`).
    soul_sub_2h_main_allow_resume = reinterpret_cast<uintptr_t>(base + 0x133E05);
    soul_pc_sub_model_resume = reinterpret_cast<uintptr_t>(base + 0x0D3C4C);
    original_model_part_add_mesh = reinterpret_cast<ModelPartAddMeshFn>(base + 0x029F70);
    original_lookup_bone_index = reinterpret_cast<LookupBoneIndexFn>(base + 0x02A9B0);
    soul_model_mesh_draw_resume = reinterpret_cast<uintptr_t>(base + 0x02A6C4);

    AcquireSRWLockExclusive(&weapon_lock);
    load_runtime_resources(pinned, action_row_max_chars, &weapon_rule_catalog, &weapon_presentation_mgr);
    ReleaseSRWLockExclusive(&weapon_lock);
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

    // Install additive Native 1H Offhand (0x7F left-hand) bone attachment hooks (WS3-WEAP-002).
    clear_all_sub_offhand_meshes();
    CanShowSpell attach_tramp = nullptr;
    if (!soul_attach_equip_model_detour.install(base, &attach_tramp)) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_DETOUR_FAIL;
        hook_diag.failed_index = kExpectedHooks;
        hook_diag.failed_rva = static_cast<uint32_t>(soul_attach_equip_model_detour.rva);
        safe_read_bytes(base + soul_attach_equip_model_detour.rva, hook_diag.observed_bytes);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        const uint32_t failure = SoulspireNativeShutdown() == 0 ? 2 : 3;
        last_error.store(failure, std::memory_order_release);
        return failure;
    }
    original_attach_equip_model = reinterpret_cast<AttachEquipModelFn>(attach_tramp);
    if (!soul_model_part_add_mesh_patch.install(base)) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_PATCH_FAIL;
        hook_diag.failed_index = kExpectedHooks + 1u;
        hook_diag.failed_rva = static_cast<uint32_t>(soul_model_part_add_mesh_patch.rva);
        safe_read_bytes(base + soul_model_part_add_mesh_patch.rva, hook_diag.observed_bytes);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        const uint32_t failure = SoulspireNativeShutdown() == 0 ? 2 : 3;
        last_error.store(failure, std::memory_order_release);
        return failure;
    }
    if (!soul_model_mesh_draw_detour.install(base, nullptr)) {
        hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_DETOUR_FAIL;
        hook_diag.failed_index = kExpectedHooks + 2u;
        hook_diag.failed_rva = static_cast<uint32_t>(soul_model_mesh_draw_detour.rva);
        safe_read_bytes(base + soul_model_mesh_draw_detour.rva, hook_diag.observed_bytes);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        const uint32_t failure = SoulspireNativeShutdown() == 0 ? 2 : 3;
        last_error.store(failure, std::memory_order_release);
        return failure;
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

extern "C" uint32_t __stdcall SoulspireNativeSetLocalEquippedWeapons(
    uint32_t main_item_id, uint32_t main_skill, uint32_t sub_item_id, uint32_t sub_skill) {
    local_equip_main_item_id.store(main_item_id & 0xFFFFu, std::memory_order_relaxed);
    local_equip_main_skill.store(main_skill & 0xFFFFu, std::memory_order_relaxed);
    local_equip_sub_item_id.store(sub_item_id & 0xFFFFu, std::memory_order_relaxed);
    local_equip_sub_skill.store(sub_skill & 0xFFFFu, std::memory_order_relaxed);
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeUpsertPeerSoul(
    uint32_t actor_id, uint32_t job, uint32_t branch, uint32_t effective_level) {
    if (actor_id == 0) return 1;
    const uint32_t now_ms = static_cast<uint32_t>(GetTickCount());
    AcquireSRWLockExclusive(&weapon_lock);
    bool ok = false;
    if (job == 0 || branch == 0) {
        weapon_presentation_mgr.peers().revoke(actor_id);
        ok = true;
    } else {
        ok = weapon_presentation_mgr.peers().upsert(
            actor_id, static_cast<uint8_t>(job), static_cast<uint8_t>(branch),
            static_cast<uint8_t>(effective_level), now_ms);
    }
    ReleaseSRWLockExclusive(&weapon_lock);
    return ok ? 0u : 1u;
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
    if (module_enabled(SOULSPIRE_NATIVE_MOD_RENDERING) &&
        (info.capabilities & (SOULSPIRE_NATIVE_CAP_SEARCH_SOUL_LABELS | SOULSPIRE_NATIVE_CAP_WEAPON_MODEL_RESOLVE)) != 0) {
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

extern "C" uint32_t __stdcall SoulspireNativeGetMainMenuStatus(SoulspireNativeMainMenuStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    SoulspireNativeMainMenuStatus st{};
    st.size = sizeof(st);
    st.version = 1;
    st.expected_hooks = kExpectedHooks;

    AcquireSRWLockShared(&lifecycle_lock);
    uint32_t inst_mask = 0, site_mask = 0, caps = 0;
    collect_hook_state(st.total_hooks, inst_mask, site_mask, caps);
    ReleaseSRWLockShared(&lifecycle_lock);

    st.hooks_installed = ((caps & SOULSPIRE_NATIVE_CAP_COMMANDS_MENU_ENTRY) != 0) ? 1u : 0u;
    st.injected = g_commands_injected.load(std::memory_order_acquire);
    st.button_id = static_cast<uint32_t>(kCommandsSoulspireButtonId);
    st.button_count = g_commands_last_button_count.load(std::memory_order_relaxed);
    st.frame_height = g_commands_last_frame_height.load(std::memory_order_relaxed);
    st.sprite_synthesized = g_commands_sprite_synthesized.load(std::memory_order_relaxed);
    st.sprite_banks_used = g_commands_sprite_banks_used.load(std::memory_order_relaxed);
    st.open_injections = g_commands_open_injections.load(std::memory_order_relaxed);
    st.nav_overrides = g_commands_nav_overrides.load(std::memory_order_relaxed);
    st.activations = g_commands_activations.load(std::memory_order_relaxed);
    st.pending_open_requests = g_commands_pending_open_requests.load(std::memory_order_acquire);
    *output = st;
    return 0;
}

extern "C" uint32_t __stdcall SoulspireNativeConsumeCoreOpenRequest(void) {
    return g_commands_pending_open_requests.exchange(0u, std::memory_order_acq_rel);
}

extern "C" uint32_t __stdcall SoulspireNativeGetWeaponModelDiag(SoulspireNativeWeaponModelDiag* output, uint32_t size) {
    if (output == nullptr || size < sizeof(SoulspireNativeWeaponModelDiag)) return 1;
    SoulspireNativeWeaponModelDiag d{};
    d.size                 = sizeof(SoulspireNativeWeaponModelDiag);
    d.version              = 1u;
    d.hook32_calls         = pc_sub_model_calls.load(std::memory_order_relaxed);
    d.hook32_remaps        = pc_sub_model_remap_hits.load(std::memory_order_relaxed);
    d.deny_disabled        = pc_sub_model_deny_disabled.load(std::memory_order_relaxed);
    d.deny_zero_or_shield  = pc_sub_model_deny_zero_or_shield.load(std::memory_order_relaxed);
    d.deny_actor_id        = pc_sub_model_deny_actor_id.load(std::memory_order_relaxed);
    d.deny_local_equip     = pc_sub_model_deny_local_equip.load(std::memory_order_relaxed);
    d.deny_fallback_84     = pc_sub_model_deny_fallback_84.load(std::memory_order_relaxed);
    d.deny_auth            = pc_sub_model_deny_auth.load(std::memory_order_relaxed);
    d.last_actor_id        = pc_sub_model_last_actor_id.load(std::memory_order_relaxed);
    d.last_local_char_id   = pc_sub_model_last_local_char_id.load(std::memory_order_relaxed);
    d.last_is_local        = pc_sub_model_last_is_local.load(std::memory_order_relaxed);
    d.last_look_word       = pc_sub_model_last_look_word.load(std::memory_order_relaxed);
    d.last_sub_model_id    = pc_sub_model_last_sub_model_id.load(std::memory_order_relaxed);
    d.last_result_slot     = pc_sub_model_last_result_slot.load(std::memory_order_relaxed);
    d.last_soul_known      = pc_sub_model_last_soul_known.load(std::memory_order_relaxed);
    d.last_job             = pc_sub_model_last_job.load(std::memory_order_relaxed);
    d.last_branch          = pc_sub_model_last_branch.load(std::memory_order_relaxed);
    d.last_effective_level = pc_sub_model_last_eff_level.load(std::memory_order_relaxed);
    const uint32_t m_id = local_equip_main_item_id.load(std::memory_order_relaxed) & 0xFFFFu;
    const uint32_t m_sk = local_equip_main_skill.load(std::memory_order_relaxed) & 0xFFFFu;
    const uint32_t s_id = local_equip_sub_item_id.load(std::memory_order_relaxed) & 0xFFFFu;
    const uint32_t s_sk = local_equip_sub_skill.load(std::memory_order_relaxed) & 0xFFFFu;
    d.local_main_packed = m_id | (m_sk << 16);
    d.local_sub_packed  = s_id | (s_sk << 16);
    AcquireSRWLockShared(&weapon_lock);
    const uint32_t loaded_bit = weapon_presentation_mgr.loaded() ? 1u : 0u;
    const uint32_t b_cnt = static_cast<uint32_t>(weapon_presentation_mgr.binding_count()) & 0xFFu;
    const uint32_t p_cnt = static_cast<uint32_t>(weapon_presentation_mgr.profile_count()) & 0xFFu;
    ReleaseSRWLockShared(&weapon_lock);
    d.pres_summary_packed = loaded_bit | (b_cnt << 8) | (p_cnt << 16);
    *output = d;
    return 0;
}

static_assert(sizeof(SoulspireNativeWeaponModelDiag) == 92);

static_assert(sizeof(SoulspireNativeStatus) == 68);
static_assert(sizeof(SoulspireNativeActionEntry) == 288);
static_assert(sizeof(SoulspireNativeActionStatus) == 64);
static_assert(sizeof(SoulspireNativeVisibilityEntry) == 16);
static_assert(sizeof(SoulspireNativeVisibilityStatus) == 40);
static_assert(sizeof(SoulspireNativeWeaponRule) == 24);
static_assert(sizeof(SoulspireNativeWeaponStatus) == 36);
static_assert(sizeof(SoulspireNativeHookDiagnostics) == 60);
static_assert(sizeof(SoulspireNativeInterfaceInfo) == 104);
static_assert(sizeof(SoulspireNativeMainMenuStatus) == 60);

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
