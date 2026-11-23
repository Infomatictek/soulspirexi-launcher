#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include "crystaljobs.h"
#include "transport.h"
#include "labels.h"
#include "actions.h"
#include "layout.h"
#include <atomic>
#include <cstdio>
#include <cwchar>
#include <new>

using namespace crystaljobs;
static SRWLOCK state_lock = SRWLOCK_INIT;
static SRWLOCK action_lock = SRWLOCK_INIT;
static SRWLOCK visibility_lock = SRWLOCK_INIT;
static SRWLOCK weapon_lock = SRWLOCK_INIT;
static State state;
static Transport transport;
static ActionCatalog action_catalog;
static VisibilityCatalog visibility_catalog;
static WeaponRuleCatalog weapon_rule_catalog;
struct ActiveSoulOverride {
    bool active = false;
    uint8_t job = 0;
    uint8_t branch = 0;
    uint32_t character = 0;
};
static ActiveSoulOverride soul_override;
static std::atomic<uint32_t> last_error{};
static std::atomic<bool> enabled{};
static std::atomic<uint32_t> decoded_rows{}, short_draws{}, full_lookups{}, item_lookups{};
static std::atomic<uint32_t> magic_name_hits{}, magic_desc_hits{}, magic_icon_hits{};
static std::atomic<uint32_t> ability_name_hits{}, ability_desc_hits{}, ability_icon_hits{};
static std::atomic<uint32_t> magic_hidden_count{}, magic_shown_count{}, ability_hidden_count{};
static std::atomic<uint32_t> weapon_allow_hits{}, weapon_deny_hits{};
using Lookup = const char* (__cdecl*)(int, int);
using Decode = void* (__cdecl*)(const uint8_t*, uint8_t*, int);
using Encode = int (__cdecl*)(const void*, uint8_t*);
using NativeText = int (__cdecl*)(int, int, const char*, uint32_t, float, float, int);
using DrawSprite = int (__fastcall*)(void*, void*, int, int, float, float, uint32_t, int, int, int);
using ActionIcon = void* (__cdecl*)(uint32_t, uint32_t);
using CanShowSpell = uint8_t (__cdecl*)(const uint8_t*);
using GetInventoryItem = const uint8_t* (__cdecl*)(uint32_t, uint32_t);
using GetItemResource = const uint8_t* (__fastcall*)(void*, void*, uint32_t);
static Lookup original_lookup;
static Decode original_decode;
static Encode original_encode;
static NativeText native_text;
static ActionIcon original_action_icon;
static CanShowSpell original_can_show_spell;
static GetInventoryItem original_get_inv_item;
static GetItemResource original_get_item_res;
static uintptr_t original_sprite;
static uintptr_t original_sprite_simple;
static uintptr_t original_spell_name;
static uintptr_t original_spell_desc;
static uintptr_t original_ability_name_row;
static uintptr_t original_ability_name_target;
static uintptr_t original_ability_desc;
static uintptr_t original_set_list_count;
static uintptr_t original_spell_elig;
static void** pname_sheet_slot;
static void** item_res_mgr_slot;
static const uint8_t* main_job_slot;
static const uint8_t* main_lvl_slot;
static uint8_t** ability_list_slot;
static thread_local int32_t tls_magic_row_id = -1;
static thread_local int32_t tls_ability_row_id = -1;
static thread_local char tls_action_name[80]{};
static thread_local char tls_action_desc[192]{};
static thread_local char tls_action_desc_fmt[192]{};
static thread_local char tls_action_row[80]{};
static constexpr size_t kHelpWindDescMaxChars = 96;
static std::atomic<uint32_t> action_row_max_chars{16};
#ifdef CRYSTALJOBS_SELFTEST
static bool selftest_alive;
#endif

static bool alive() noexcept {
#ifdef CRYSTALJOBS_SELFTEST
    return selftest_alive;
#endif
    if (!enabled.load()) return false;
    AcquireSRWLockShared(&state_lock);
    const bool valid = state.alive(GetTickCount(), transport.character, transport.job);
    ReleaseSRWLockShared(&state_lock);
    return valid;
}

static bool session_alive() noexcept {
#ifdef CRYSTALJOBS_SELFTEST
    return selftest_alive;
#else
    if (!enabled.load()) return false;
    AcquireSRWLockShared(&state_lock);
    const bool valid = transport.character != 0 && transport.job >= 1 && transport.job <= 23;
    ReleaseSRWLockShared(&state_lock);
    return valid;
#endif
}

static const char* __cdecl item_label(int table, int job) noexcept {
    if (table == 2 && job >= 1 && job <= 23 && alive()) {
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
    if (session_alive()) {
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
    if (enabled.load()) state.decoded(output);
    else if ((u32(output + 20) & 0xffffff00u) == marker) std::memset(output + 20, 0, 4);
    ReleaseSRWLockExclusive(&state_lock);
    ++decoded_rows;
    return result;
}

static uint8_t branch_for(const uint8_t* row) noexcept {
    if (!session_alive()) return 0;
    AcquireSRWLockShared(&state_lock);
    const uint8_t branch = state.row_branch(row);
    ReleaseSRWLockShared(&state_lock);
    return branch;
}

struct SpriteArgs { int x, y; float scale_x, scale_y; uint32_t color; int center, first, count; };
static_assert(sizeof(SpriteArgs) == 32);

struct SimpleSpriteArgs { int x, y; uint32_t color; int center, first; };
static_assert(sizeof(SimpleSpriteArgs) == 20);

// Search 3-letter job badge rendering mode (compile-time selectable for isolated Testing candidates):
//   0 = Legacy historical native_text (4f0fdb3 baseline: single-call 0.75x native_text; zero sprite mutation)
//   1 = Verified native menu2fon sprite renderer (SoA x[4]/y[4] quad corners at tile+0xC0 + configurable tracking)
//   2 = Aligned native_text fallback (per-character fixed-column 0x1CAD80 native_text; zero sprite mutation)
#ifndef CRYSTALJOBS_SEARCH_RENDER_MODE
#define CRYSTALJOBS_SEARCH_RENDER_MODE 1
#endif

#if CRYSTALJOBS_SEARCH_RENDER_MODE == 1
struct MenuGlyph { uint8_t u, v, w; };
// 8x10 job-abbreviation glyphs on 'menu    menu2fon' (256x256 texture in ROM/118/111.DAT).
static constexpr MenuGlyph menu_glyphs[26] = {
    {9, 184, 7},   // A (WAR)
    {1, 214, 8},   // B (BLU)
    {92, 214, 8},  // C (DNC)
    {77, 194, 8},  // D (DRG)
    {204, 214, 7}, // E (GEO)
    {143, 184, 8}, // F (THF)
    {196, 214, 8}, // G (GEO)
    {59, 184, 7},  // H (WHM)
    {59, 194, 8},  // I (NIN)
    {94, 161, 8},  // J
    {41, 184, 8},  // K (MNK)
    {85, 184, 7},  // L (BLM)
    {26, 184, 8},  // M (MNK)
    {51, 194, 8},  // N (NIN)
    {34, 214, 7},  // O (COR)
    {67, 214, 8},  // P (PUP)
    {169, 161, 8}, // Q
    {16, 184, 8},  // R (WAR)
    {26, 194, 8},  // S (SAM)
    {219, 184, 7}, // T (BST)
    {16, 214, 8},  // U (BLU)
    {221, 161, 8}, // V
    {0, 184, 8},   // W (WAR)
    {244, 161, 8}, // X
    {3, 173, 8},   // Y
    {13, 173, 8},  // Z
};

struct GlyphSlot {
    uint8_t sprite[0x30];
    uint8_t node[0x20];
    uint8_t tile[0xE0];
};

struct Menu2fonTemplateKey {
    const uint8_t* src_sprite;
    const uint8_t* src_node;
    const uint8_t* src_tile;
    uint8_t sprite_bytes[0x30];
    uint8_t node_bytes[0x20];
    // Compare only the static tile header/texture prefix [0x00..0x4F].
    // [0x50..0xBF] holds FFXI's per-draw D3D8 TLVERTEX screen-position/diffuse buffer
    // (4 x 28-byte vertices with UVs at 0x64, 0x80, 0x9C, 0xB8), which FFXI's 0x121110
    // mutates on every vanilla WAR draw at a different screen Y or highlight color.
    uint8_t tile_header_bytes[0x50];
};

struct Menu2fonBank {
    bool active;
    Menu2fonTemplateKey key;
    bool initialized[kGlyphX0Span][26];
    GlyphSlot slots[kGlyphX0Span][26];
};

// Because FFXI's sprite renderer (0x121110) may queue raw sprite/node/tile pointers for
// deferred submission and we cannot assume when a queued pointer is retired, a GlyphSlot
// must NEVER be mutated once handed to draw_sprite. Indexing by (x0 - kMinGlyphX0, letter)
// across bounded x0 in [-2, 21] (24 x 26 slots) guarantees every glyph quad for ANY valid
// trackingPx / offsetXPx / useGlyphWidths layout is immutable once initialized, with zero
// aliasing across different letter-width combinations (e.g., AST vs FLT vs WAR).
static constexpr size_t kMaxMenu2fonBanks = 4;
static SRWLOCK menu2fon_lock = SRWLOCK_INIT;
static Menu2fonBank g_menu2fon_banks[kMaxMenu2fonBanks]{};
static size_t g_last_menu2fon_bank = 0;

static void compute_search_glyph_positions(
    const uint8_t widths[3],
    const SearchPresentationConfig& cfg,
    int16_t out_x0[3]) noexcept {
    const int32_t tracking = (cfg.tracking_px < kMinTrackingPx) ? kMinTrackingPx
                           : (cfg.tracking_px > kMaxTrackingPx) ? kMaxTrackingPx : cfg.tracking_px;
    const int32_t offset_x = (cfg.offset_x_px < kMinOffsetXPx) ? kMinOffsetXPx
                           : (cfg.offset_x_px > kMaxOffsetXPx) ? kMaxOffsetXPx : cfg.offset_x_px;
    int32_t x[3];
    x[0] = offset_x;
    for (int i = 0; i < 2; ++i) {
        const int32_t base_w = cfg.use_glyph_widths ? static_cast<int32_t>(widths[i]) : 8;
        int32_t step = base_w + tracking;
        if (step < 4) step = 4; // Prevent glyph collapse/overlap
        x[i + 1] = x[i] + step;
    }
    // Keep right edge strictly within the 23px Search job column (clear of level digits at +23).
    const int32_t right_edge = x[2] + static_cast<int32_t>(widths[2]);
    if (right_edge > 23) {
        int32_t shift = right_edge - 23;
        if (x[0] - shift < kMinGlyphX0) {
            shift = x[0] - kMinGlyphX0;
        }
        if (shift > 0) {
            x[0] -= shift;
            x[1] -= shift;
            x[2] -= shift;
        }
        const int32_t max_x2 = 23 - static_cast<int32_t>(widths[2]);
        if (x[2] > max_x2) {
            x[2] = max_x2;
            const int32_t mid = x[0] + (x[2] - x[0]) / 2;
            if (x[1] > mid) x[1] = mid;
        }
    }
    for (int i = 0; i < 3; ++i) {
        if (x[i] < kMinGlyphX0) x[i] = kMinGlyphX0;
        if (x[i] > kMaxGlyphX0) x[i] = kMaxGlyphX0;
        out_x0[i] = static_cast<int16_t>(x[i]);
    }
}

static bool menu2fon_key_matches(
    const Menu2fonTemplateKey& key,
    const uint8_t* src_sprite,
    const uint8_t* src_node,
    const uint8_t* src_tile) noexcept {
    return key.src_sprite == src_sprite &&
           key.src_node == src_node &&
           key.src_tile == src_tile &&
           std::memcmp(key.sprite_bytes, src_sprite, sizeof(key.sprite_bytes)) == 0 &&
           std::memcmp(key.node_bytes, src_node, sizeof(key.node_bytes)) == 0 &&
           std::memcmp(key.tile_header_bytes, src_tile, sizeof(key.tile_header_bytes)) == 0;
}

static void init_glyph_slot(
    GlyphSlot& slot,
    const uint8_t* src_sprite,
    const uint8_t* src_node,
    const uint8_t* src_tile,
    int16_t x0,
    size_t letter) noexcept {
    std::memcpy(slot.sprite, src_sprite, sizeof(slot.sprite));
    std::memcpy(slot.node, src_node, sizeof(slot.node));
    std::memcpy(slot.tile, src_tile, sizeof(slot.tile));

    uint8_t* node_ptr = slot.node;
    uint8_t* tile_ptr = slot.tile;
    // Repoint CYyList head (+0x04) and any matching tail/cursor (+0x08, +0x0C) so
    // list traversal inside FFXI 0x121110 never leaks back to WAR's shared src_node.
    std::memcpy(slot.sprite + 0x04, &node_ptr, sizeof(node_ptr));
    for (size_t off : {size_t{0x08}, size_t{0x0C}}) {
        const uint8_t* existing = nullptr;
        std::memcpy(&existing, slot.sprite + off, sizeof(existing));
        if (existing == src_node) {
            std::memcpy(slot.sprite + off, &node_ptr, sizeof(node_ptr));
        }
    }
    std::memcpy(slot.node + 0x10, &tile_ptr, sizeof(tile_ptr));

    const MenuGlyph g = menu_glyphs[letter];
    const int16_t x1 = static_cast<int16_t>(x0 + g.w);
    // FFXI CXiSpriteTile stores quad corners at +0xC0 as Structure-of-Arrays:
    //   +0xC0: int16_t x[4] = { x0, x1, x0, x1 } (TL, TR, BL, BR)
    //   +0xC8: int16_t y[4] = { -1, -1,  9,  9 } (TL, TR, BL, BR)
    const int16_t corners[8] = {x0, x1, x0, x1, -1, -1, 9, 9};
    const float u0 = static_cast<float>(g.u) * (1.0f / 256.0f);
    const float u1 = static_cast<float>(g.u + g.w) * (1.0f / 256.0f);
    const float v0 = static_cast<float>(g.v) * (1.0f / 256.0f);
    const float v1 = static_cast<float>(g.v + 10) * (1.0f / 256.0f);
    const float uv0[2] = {u0, v0}, uv1[2] = {u1, v0}, uv2[2] = {u0, v1}, uv3[2] = {u1, v1};

    std::memcpy(slot.tile + 0xC0, corners, sizeof(corners));
    std::memcpy(slot.tile + 0x64, uv0, sizeof(uv0));
    std::memcpy(slot.tile + 0x80, uv1, sizeof(uv1));
    std::memcpy(slot.tile + 0x9C, uv2, sizeof(uv2));
    std::memcpy(slot.tile + 0xB8, uv3, sizeof(uv3));
}

#ifdef CRYSTALJOBS_SELFTEST
static void reset_menu2fon_banks_for_test() noexcept {
    AcquireSRWLockExclusive(&menu2fon_lock);
    std::memset(g_menu2fon_banks, 0, sizeof(g_menu2fon_banks));
    g_last_menu2fon_bank = 0;
    ReleaseSRWLockExclusive(&menu2fon_lock);
}
#endif

static bool draw_menu2fon_label(const char* custom, const SpriteArgs* args) noexcept {
    if (pname_sheet_slot == nullptr || original_sprite == 0) return false;
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
        g_menu2fon_banks[g_last_menu2fon_bank].active &&
        menu2fon_key_matches(g_menu2fon_banks[g_last_menu2fon_bank].key, src_sprite, src_node, src_tile)) {
        bank = &g_menu2fon_banks[g_last_menu2fon_bank];
    } else {
        for (size_t bi = 0; bi < kMaxMenu2fonBanks; ++bi) {
            if (g_menu2fon_banks[bi].active &&
                menu2fon_key_matches(g_menu2fon_banks[bi].key, src_sprite, src_node, src_tile)) {
                bank = &g_menu2fon_banks[bi];
                g_last_menu2fon_bank = bi;
                break;
            }
        }
        if (bank == nullptr) {
            for (size_t bi = 0; bi < kMaxMenu2fonBanks; ++bi) {
                if (!g_menu2fon_banks[bi].active) {
                    bank = &g_menu2fon_banks[bi];
                    bank->active = true;
                    bank->key.src_sprite = src_sprite;
                    bank->key.src_node = src_node;
                    bank->key.src_tile = src_tile;
                    std::memcpy(bank->key.sprite_bytes, src_sprite, sizeof(bank->key.sprite_bytes));
                    std::memcpy(bank->key.node_bytes, src_node, sizeof(bank->key.node_bytes));
                    std::memcpy(bank->key.tile_header_bytes, src_tile, sizeof(bank->key.tile_header_bytes));
                    std::memset(bank->initialized, 0, sizeof(bank->initialized));
                    g_last_menu2fon_bank = bi;
                    break;
                }
            }
        }
    }
    if (bank == nullptr) {
        ReleaseSRWLockExclusive(&menu2fon_lock);
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
        draw_sprite(slots[i]->sprite, nullptr, args->x, args->y, args->scale_x, args->scale_y, args->color, args->center, args->first, args->count);
    }
    return true;
}
#endif // CRYSTALJOBS_SEARCH_RENDER_MODE == 1

#if CRYSTALJOBS_SEARCH_RENDER_MODE == 2
static void draw_aligned_native_text_label(const char* custom, const SpriteArgs* args) noexcept {
    // Render each uppercase letter into a fixed column inside the 23px Search job badge slot
    // using FFXI's safe text pipeline (0x1CAD80) with zero menu2fon sprite/tile manipulation.
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
    if (branch == 0 || row == nullptr) return false;
    const char* custom = label_for(row[32], branch, false);
    if (custom == nullptr) return false;
#if CRYSTALJOBS_SEARCH_RENDER_MODE == 0
    // Historical working baseline (4f0fdb3): fit FFXI's native_text into the 23px job column.
    native_text(args->x, args->y, custom, args->color, 0.75f * args->scale_x, 0.75f * args->scale_y, 0);
#elif CRYSTALJOBS_SEARCH_RENDER_MODE == 1
    // Experimental menu2fon job sprite sheet renderer (24px: 0, 8, 16) with native_text fallback.
    if (!draw_menu2fon_label(custom, args)) {
        native_text(args->x, args->y, custom, args->color, 0.75f * args->scale_x, 0.75f * args->scale_y, 0);
    }
#else
    // Safe default: per-character fixed-column native_text (readable first, zero sprite mutation).
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

// Each adapter replaces a CALL, preserving all saved registers and the original callee's stack cleanup.
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

// The Equipment persona is a *local* identity label, not a search-row cache.
// Do not require the 2.5s network/animation lease here: a throttled or inactive
// Ashita rendering loop can stop heartbeats while the game is idle.
// Explicit CrystalJobsSetState revocation, job changes and shutdown still clear it.
// Remote/search hooks keep the strict short lease.
static bool local_persona_branch(uint8_t job, uint8_t& branch) noexcept {
#ifdef CRYSTALJOBS_SELFTEST
    if (!selftest_alive) return false;
#else
    if (!enabled.load()) return false;
#endif
    AcquireSRWLockShared(&state_lock);
    const bool valid = state.known && state.from_bridge
        && state.character != 0 && state.job == job
#ifdef CRYSTALJOBS_SELFTEST
        ;
#else
        && state.character == transport.character && transport.job == job;
#endif
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
    // Equipment status panel ('menu    persona ') draws "Lv%d" via native_text at scale 1.0f,
    // then draws the full main-job name sprite at (end_x + 2, win_y + 0x13) with color in args->color.
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

static bool active_action_soul(uint8_t& out_job, uint8_t& out_branch, uint32_t* out_source = nullptr) noexcept {
#ifdef CRYSTALJOBS_SELFTEST
    if (!selftest_alive) return false;
#else
    if (!enabled.load()) return false;
#endif
    const uint8_t live_job = (main_job_slot != nullptr) ? *main_job_slot : 0;
    if (main_job_slot != nullptr && (live_job < 1 || live_job > 22)) return false;

    AcquireSRWLockShared(&state_lock);
    const bool bridge_ok = state.known && state.from_bridge && state.character != 0
        && valid_branch(state.job, state.branch)
        && (live_job == 0 || state.job == live_job)
#ifndef CRYSTALJOBS_SELFTEST
        && state.character == transport.character && transport.job == state.job
#endif
        ;
    const uint8_t bridge_job = state.job;
    const uint8_t bridge_branch = state.branch;

    const bool override_ok = !bridge_ok && soul_override.active
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

static const char* resolve_action_string(uint32_t kind, int32_t raw_id, bool want_desc) noexcept {
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
    return (ability_id >= 0 && ability_id < 512) ? CRYSTALJOBS_ACTION_WEAPONSKILL : CRYSTALJOBS_ACTION_ABILITY;
}

static const char* __stdcall resolve_magic_row_name(int32_t spell_id) noexcept {
    tls_magic_row_id = spell_id;
    if (const char* custom = resolve_action_string(CRYSTALJOBS_ACTION_SPELL, spell_id, false)) {
        // Compact ONLY the stock list row. Target banners retain full names.
        const auto limit = action_row_max_chars.load(std::memory_order_relaxed);
        if (!compact_action_row_name(custom, tls_action_row, sizeof(tls_action_row), limit)) return nullptr;
        ++magic_name_hits;
        return tls_action_row;
    }
    return nullptr;
}

static const char* __stdcall resolve_magic_target_name(int32_t spell_id) noexcept {
    if (const char* custom = resolve_action_string(CRYSTALJOBS_ACTION_SPELL, spell_id, false)) {
        ++magic_name_hits;
        return custom;
    }
    return nullptr;
}

static const char* __stdcall resolve_magic_desc(int32_t spell_id) noexcept {
    if (const char* custom = resolve_action_string(CRYSTALJOBS_ACTION_SPELL, spell_id, true)) {
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
        if (resolve_action_icon(CRYSTALJOBS_ACTION_SPELL, static_cast<uint16_t>(spell_id), v1, v2)) {
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
            const VisibilityDecision decision = decide_local_visibility(CRYSTALJOBS_ACTION_SPELL, spell_id);
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

static uintptr_t missing_spell_bit_resume;

// The /ma name resolver checks the learned-spell bitmap before CanUseSpell.
// Its missing-bit branch stores -2 in EBP, which survives a successful
// CanUseSpell call. Only a current Soul unlock may clear that local rejection;
// the server still validates the actual cast.
static uint8_t __stdcall soul_knows_missing_spell(const uint8_t* spell_resource) noexcept {
    if (spell_resource == nullptr) return 0;
    const uint16_t spell_id = u16(spell_resource);
    if (spell_id == 0 || spell_id > 1023u) return 0;
    return decide_local_visibility(CRYSTALJOBS_ACTION_SPELL, spell_id) == VisibilityDecision::Show ? 1 : 0;
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

// The Magic Menu pre-cast validator (0x22E540, called by 0x22DDC0 on menu cast
// confirmation and 0x22E4B0 on row coloring) checks static ROM/118/114.DAT job
// levels via 0x1021A0 at 0x22E64D without calling CanUseSpell (0x22CDE0).
// Intercept that call so active-Soul unlocked spells pass the job/level check
// while preserving silence, recast, MP, BLU set-spell, and vanilla/subjob checks.
static int32_t __stdcall decide_menu_spell_elig(const uint8_t* spell_resource) noexcept {
    if (spell_resource == nullptr) return -1;
    const uint16_t spell_id = u16(spell_resource);
    if (spell_id == 0 || spell_id > 1023u) return -1;
    const VisibilityDecision decision = decide_local_visibility(CRYSTALJOBS_ACTION_SPELL, spell_id);
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

static uintptr_t soul_sub_weapon_allow_resume;
static uintptr_t soul_sub_weapon_deny_resume;

// EquipMenu::TryEquipItem (0x133BD0) gates non-vanilla Dual Wield jobs at
// 0x133D56 before checking main-hand presence, IsTwoHanded, CanEquipItem,
// Wardrobe ownership, and sending native 0x050. Both the native Equipment
// menu (controller / keyboard) and /equip sub route through 0x133BD0.
// Vanilla DW jobs (NIN/THF/DNC/BLU main or sub) and non-weapon sub items
// (shields, grips) bypass 0x133D56 entirely.
static uint8_t __stdcall soul_allows_sub_weapon(const uint8_t* sub_item_res, const uint8_t* stack_frame) noexcept {
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

static void __stdcall compact_ability_menu_rows(uint8_t* menu_obj, int32_t* count_ptr, int32_t* saved_sel_ptr) noexcept {
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

using MapDecode = int (__cdecl*)(uint8_t*, uint32_t, uintptr_t, uintptr_t, const uint8_t*, uint32_t);
using MapEncode = int (__cdecl*)(const uint8_t*, uint32_t, uint8_t*, uint32_t, uintptr_t);
static MapDecode original_map_decode;
static MapEncode original_map_encode;

static uint32_t received_packets(uint8_t* packets, uint32_t length, uint32_t now) {
    if (!whole_packets(packets, length)) return length;
    uint32_t at = 0;
    while (at + 4 <= length) {
        const uint32_t size = packet_size(packets + at);
        if (size == 0) break;
        bool consume;
        if (enabled.load()) {
            AcquireSRWLockExclusive(&state_lock);
            const uint16_t pid = u16(packets + at) & 0x1ff;
            if (pid == 0x00a || pid == 0x00b || pid == 0x061) soul_override = {};
            consume = transport.incoming(packets + at, size, now, state);
            ReleaseSRWLockExclusive(&state_lock);
        } else {
            consume = (u16(packets + at) & 0x1ff) == 0x1ff && size >= 12 &&
                std::memcmp(packets + at + 4, "CRYS", 4) == 0 && u16(packets + at + 10) >= 0x8000;
        }
        if (consume) {
            std::memmove(packets + at, packets + at + size, length - at - size);
            length -= size;
        } else at += size;
    }
    return length;
}

static int __cdecl map_decode(uint8_t* output, uint32_t capacity, uintptr_t context, uintptr_t tree, const uint8_t* wire, uint32_t length) noexcept {
    const int result = original_map_decode(output, capacity, context, tree, wire, length);
    if (result <= 28 || static_cast<uint32_t>(result) > capacity || result > 10000) return result;
    return 28 + static_cast<int>(received_packets(output + 28, result - 28, GetTickCount()));
}

static int __cdecl map_encode(const uint8_t* packets, uint32_t length, uint8_t* output, uint32_t capacity, uintptr_t table) noexcept {
    if (!enabled.load() || length < 4 || length > 10000 || !whole_packets(packets, length))
        return original_map_encode(packets, length, output, capacity, table);
    uint8_t combined[10016];
    uint32_t at = 0;
    AcquireSRWLockExclusive(&state_lock);
    while (at + 4 <= length) {
        const uint32_t size = packet_size(packets + at);
        if (size == 0) break;
        if ((u16(packets + at) & 0x1ff) == 0x00d) soul_override = {};
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

struct Patch {
    uintptr_t rva;
    void* replacement;
    uint8_t original[5]{}, installed[5]{};
    uint8_t* site = nullptr;

    static bool compare_exchange(uint8_t* operand, uint32_t expected, uint32_t desired) {
        uint8_t exchanged;
        __asm {
            mov edx, operand
            mov eax, expected
            mov ecx, desired
            lock cmpxchg dword ptr [edx], ecx
            sete al
            mov exchanged, al
        }
        return exchanged != 0;
    }
    static bool write(uint8_t* target, const uint8_t* expected, const uint8_t* desired) {
        if (target[0] != 0xe8 || expected[0] != 0xe8 || desired[0] != 0xe8 ||
            (reinterpret_cast<uintptr_t>(target + 1) & 63) > 60) return false;
        DWORD protection, discarded;
        if (!VirtualProtect(target, 5, PAGE_EXECUTE_READWRITE, &protection)) return false;
        const bool exchanged = target[0] == 0xe8 && compare_exchange(target + 1, u32(expected + 1), u32(desired + 1));
        const bool opcode_intact = target[0] == 0xe8;
        const bool flushed = FlushInstructionCache(GetCurrentProcess(), target, 5) != 0;
        const bool restored = VirtualProtect(target, 5, protection, &discarded) != 0;
        return exchanged && opcode_intact && flushed && restored;
    }
    bool install(uint8_t* base) {
        if (site != nullptr) return std::memcmp(site, installed, 5) == 0;
        site = base + rva;
        if (*site != 0xe8) { site = nullptr; return false; }
        std::memcpy(original, site, 5);
        installed[0] = 0xe8;
        const uint32_t relative = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(replacement) - reinterpret_cast<uintptr_t>(site + 5));
        std::memcpy(installed + 1, &relative, 4);
        if (write(site, original, installed)) return true;
        write(site, installed, original);
        return false;
    }
    bool restore() {
        if (site == nullptr) return true;
        if (std::memcmp(site, original, 5) == 0) { site = nullptr; return true; }
        const bool ours = std::memcmp(site, installed, 5) == 0;
        const bool restored = ours && write(site, installed, original);
        site = nullptr;
        return restored;
    }
};

static Patch patches[] = {
    {0xD8CCD, reinterpret_cast<void*>(&encode_request)},
    {0xE2282, reinterpret_cast<void*>(&decode_row)},
    {0x13C302, reinterpret_cast<void*>(&item_label)},
    {0x14868F, reinterpret_cast<void*>(&persona_job_hook)},
    {0x1CBD4C, reinterpret_cast<void*>(&normal_sprite_hook)},
    {0x1CC086, reinterpret_cast<void*>(&master_sprite_hook)},
    {0x1DEE6D, reinterpret_cast<void*>(&full_job_hook)},
    {0x1DEEFB, reinterpret_cast<void*>(&full_job_hook)},
    {0xFA795, reinterpret_cast<void*>(&map_decode)},
    {0xDD5F6, reinterpret_cast<void*>(&map_encode)},
    {0x22E4F5, reinterpret_cast<void*>(&magic_row_name_hook)},
    {0x22E245, reinterpret_cast<void*>(&magic_desc_hook)},
    {0x22DED1, reinterpret_cast<void*>(&magic_target_hook)},
    {0x22E51B, reinterpret_cast<void*>(&magic_icon_hook)},
    {0x226129, reinterpret_cast<void*>(&ability_row_name_hook)},
    {0x225F5D, reinterpret_cast<void*>(&ability_desc_hook)},
    {0x225916, reinterpret_cast<void*>(&ability_target_hook)},
    {0x22614E, reinterpret_cast<void*>(&ability_icon_hook)},
    {0x22DAB9, reinterpret_cast<void*>(&magic_list_filter_hook)},
    {0x22562F, reinterpret_cast<void*>(&ability_list_filter_hook)},
    {0x22E64D, reinterpret_cast<void*>(&menu_spell_elig_hook)},
};

// Detour the central FFXI CanUseSpell function (0x22CDE0) itself so BOTH the
// Magic Menu display AND cast-execution / /ma command checks consult the active
// Soul's visibility/eligibility policy instead of rejecting Soul-backported
// spells against static ROM/118/114.DAT job levels.
// The verified 5-byte prologue at 0x22CDE0 is a single self-contained
// `mov eax, ds:[main_job_slot]` (0xA1 imm32) instruction.
struct PrologueDetour {
    uintptr_t rva;
    void* replacement;
    uint8_t first_opcode = 0xA1u;
    uint8_t original[5]{}, installed[5]{};
    uint8_t* site = nullptr;
    uint8_t* trampoline = nullptr;

    bool install(uint8_t* base, CanShowSpell* out_trampoline = nullptr) {
        if (site != nullptr) return std::memcmp(site, installed, 5) == 0;
        uint8_t* target = base + rva;
        if (target[0] != first_opcode) return false;
        if (out_trampoline != nullptr) {
            if (trampoline == nullptr) {
                trampoline = static_cast<uint8_t*>(VirtualAlloc(nullptr, 16, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
                if (trampoline == nullptr) return false;
            }
            std::memcpy(original, target, 5);
            std::memcpy(trampoline, original, 5);
            trampoline[5] = 0xE9u;
            const uint32_t back_rel = static_cast<uint32_t>(
                reinterpret_cast<uintptr_t>(target + 5) - reinterpret_cast<uintptr_t>(trampoline + 10));
            std::memcpy(trampoline + 6, &back_rel, 4);
            FlushInstructionCache(GetCurrentProcess(), trampoline, 10);
            *out_trampoline = reinterpret_cast<CanShowSpell>(trampoline);
        } else {
            std::memcpy(original, target, 5);
        }

        installed[0] = 0xE9u;
        const uint32_t jmp_rel = static_cast<uint32_t>(
            reinterpret_cast<uintptr_t>(replacement) - reinterpret_cast<uintptr_t>(target + 5));
        std::memcpy(installed + 1, &jmp_rel, 4);

        DWORD protection = 0, discarded = 0;
        if (!VirtualProtect(target, 5, PAGE_EXECUTE_READWRITE, &protection)) return false;
        std::memcpy(target, installed, 5);
        const bool flushed = FlushInstructionCache(GetCurrentProcess(), target, 5) != 0;
        const bool restored = VirtualProtect(target, 5, protection, &discarded) != 0;
        if (!flushed || !restored) return false;
        site = target;
        return true;
    }

    bool restore() {
        if (site == nullptr) return true;
        if (std::memcmp(site, original, 5) == 0) { site = nullptr; return true; }
        if (std::memcmp(site, installed, 5) != 0) { site = nullptr; return false; }
        DWORD protection = 0, discarded = 0;
        if (!VirtualProtect(site, 5, PAGE_EXECUTE_READWRITE, &protection)) return false;
        std::memcpy(site, original, 5);
        const bool flushed = FlushInstructionCache(GetCurrentProcess(), site, 5) != 0;
        const bool restored = VirtualProtect(site, 5, protection, &discarded) != 0;
        site = nullptr;
        return flushed && restored;
    }
};

static PrologueDetour can_use_spell_detour{0x22CDE0, reinterpret_cast<void*>(&magic_list_filter_hook)};
static PrologueDetour missing_spell_bit_detour{0x22CB44, reinterpret_cast<void*>(&missing_spell_bit_hook), 0xBDu};
static PrologueDetour soul_sub_weapon_detour{0x133D56, reinterpret_cast<void*>(&soul_sub_weapon_hook), 0x68u};

static bool host_detour(uint8_t* entry, const uint8_t* expected, size_t length, size_t stolen, HMODULE host) noexcept {
    if (host == nullptr || entry[0] != 0xe9 || stolen < 5 || stolen >= length) return false;
    for (size_t at = 5; at < stolen; ++at) {
        if (entry[at] != 0x90 && entry[at] != 0xcc && entry[at] != expected[at]) return false;
    }
    if (std::memcmp(entry + stolen, expected + stolen, length - stolen) != 0) return false;
    const uintptr_t target = reinterpret_cast<uintptr_t>(entry + 5) + u32(entry + 1);
    MEMORY_BASIC_INFORMATION region{};
    if (VirtualQuery(reinterpret_cast<void*>(target), &region, sizeof(region)) != sizeof(region) ||
        region.AllocationBase != host || region.Type != MEM_IMAGE || region.State != MEM_COMMIT || (region.Protect & PAGE_GUARD) != 0) return false;
    const DWORD protection = region.Protect & 0xff;
    return protection == PAGE_EXECUTE || protection == PAGE_EXECUTE_READ || protection == PAGE_EXECUTE_READWRITE || protection == PAGE_EXECUTE_WRITECOPY;
}

static void relocate_signature(uintptr_t rva, uint8_t (&expected)[24], uint32_t delta) noexcept {
    if (delta == 0) return;
    if (rva == 0x13C302) {
        const uint32_t relocated = u32(expected + 11) + delta;
        std::memcpy(expected + 11, &relocated, 4);
    } else if (rva == 0x14868F) {
        const uint32_t sub_job = u32(expected + 6) + delta;
        const uint32_t sub_lvl = u32(expected + 17) + delta;
        std::memcpy(expected + 6, &sub_job, 4);
        std::memcpy(expected + 17, &sub_lvl, 4);
    } else if (rva == 0x1DEEFB) {
        const uint32_t relocated = u32(expected + 20) + delta;
        std::memcpy(expected + 20, &relocated, 4);
    } else if (rva == 0x22E245 || rva == 0x22DED1 || rva == 0x225916) {
        const uint32_t relocated = u32(expected + 7) + delta;
        std::memcpy(expected + 7, &relocated, 4);
    } else if (rva == 0x225F5D) {
        const uint32_t helpwind = u32(expected + 7) + delta;
        std::memcpy(expected + 7, &helpwind, 4);
        const uint32_t abisort = 0x106682FCu + delta;
        std::memcpy(expected + 21, &abisort, 3);
    } else if (rva == 0x22D510) {
        const uint32_t lang_ptr = u32(expected + 18) + delta;
        std::memcpy(expected + 18, &lang_ptr, 4);
    } else if (rva == 0x225120 || rva == 0x2250A0) {
        const uint32_t lang_ptr = u32(expected + 2) + delta;
        std::memcpy(expected + 2, &lang_ptr, 4);
    } else if (rva == 0x22CDE0) {
        const uint32_t job_ptr = u32(expected + 1) + delta;
        std::memcpy(expected + 1, &job_ptr, 4);
    } else if (rva == 0xEB5D0) {
        const uint32_t inv_ptr = u32(expected + 2) + delta;
        std::memcpy(expected + 2, &inv_ptr, 4);
    }
}

#ifndef _MSC_VER
static bool readable_range(const void* ptr, size_t len) noexcept {
    const auto start = reinterpret_cast<uintptr_t>(ptr);
    if (start == 0 || len == 0 || start + len < start) return false;
    uintptr_t cur = start;
    const uintptr_t end = start + len;
    while (cur < end) {
        MEMORY_BASIC_INFORMATION mbi{};
        if (VirtualQuery(reinterpret_cast<const void*>(cur), &mbi, sizeof(mbi)) != sizeof(mbi) ||
            mbi.State != MEM_COMMIT || (mbi.Protect & (PAGE_NOACCESS | PAGE_GUARD)) != 0) return false;
        const uintptr_t region_end = reinterpret_cast<uintptr_t>(mbi.BaseAddress) + mbi.RegionSize;
        if (region_end <= cur) return false;
        cur = region_end;
    }
    return true;
}
#endif

static SRWLOCK lifecycle_lock = SRWLOCK_INIT;
static bool ever_started;

struct HookDiagnosticsState {
    uint32_t ffxi_base = 0;
    uint32_t ffxi_timestamp = 0;
    uint32_t ffxi_image_size = 0;
    uint32_t init_stage = CRYSTALJOBS_INIT_NOT_RUN;
    uint32_t failed_rva = 0;
    uint32_t failed_index = 0xFFFFFFFFu;
    uint8_t  observed_bytes[8]{};
};
static HookDiagnosticsState hook_diag;

static void safe_read_bytes(const void* src, uint8_t (&out)[8]) noexcept {
    std::memset(out, 0, sizeof(out));
    if (src == nullptr) return;
#ifdef _MSC_VER
    __try {
        std::memcpy(out, src, sizeof(out));
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        std::memset(out, 0, sizeof(out));
    }
#else
    if (readable_range(src, sizeof(out))) {
        std::memcpy(out, src, sizeof(out));
    }
#endif
}

static constexpr uint32_t kPatchCount = static_cast<uint32_t>(sizeof(patches) / sizeof(*patches));
static constexpr uint32_t kExpectedHooks = kPatchCount + 3u;
static_assert(kPatchCount == 21u);
static_assert(kExpectedHooks == 24u);

static bool supported_impl(uint8_t* base) noexcept {
    hook_diag = {};
    hook_diag.ffxi_base = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(base));
    if (base == nullptr || (reinterpret_cast<uintptr_t>(base) & 0xFFFFu) != 0) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_BAD_PE;
        return false;
    }
#ifndef _MSC_VER
    if (!readable_range(base, sizeof(IMAGE_DOS_HEADER))) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_BAD_PE;
        return false;
    }
#endif
    const auto* dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < 0 || dos->e_lfanew > 0x1000) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_BAD_PE;
        return false;
    }
#ifndef _MSC_VER
    if (!readable_range(base + dos->e_lfanew, sizeof(IMAGE_NT_HEADERS32))) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_BAD_PE;
        return false;
    }
#endif
    const auto* pe = reinterpret_cast<IMAGE_NT_HEADERS32*>(base + dos->e_lfanew);
    hook_diag.ffxi_timestamp = pe->FileHeader.TimeDateStamp;
    hook_diag.ffxi_image_size = pe->OptionalHeader.SizeOfImage;
    if (pe->Signature != IMAGE_NT_SIGNATURE || pe->FileHeader.Machine != IMAGE_FILE_MACHINE_I386 ||
        pe->FileHeader.TimeDateStamp != 0x6ae818b4 || pe->OptionalHeader.SizeOfImage != 0xc17000) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_BAD_PE;
        return false;
    }
    const uint32_t delta = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(base) - 0x10000000u);
    uint32_t sig_index = 0;
    for (const auto& signature : signatures) {
#ifndef _MSC_VER
        if (!readable_range(base + signature.rva, sizeof(signature.bytes))) {
            hook_diag.init_stage = CRYSTALJOBS_INIT_SIG_MISMATCH;
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
            if (patch.rva == signature.rva && patch.site != nullptr && std::memcmp(patch.site, patch.installed, 5) == 0) skip = 5;
        }
        if (signature.rva == can_use_spell_detour.rva && can_use_spell_detour.site != nullptr &&
            std::memcmp(can_use_spell_detour.site, can_use_spell_detour.installed, 5) == 0) skip = 5;
        if (signature.rva == missing_spell_bit_detour.rva && missing_spell_bit_detour.site != nullptr &&
            std::memcmp(missing_spell_bit_detour.site, missing_spell_bit_detour.installed, 5) == 0) skip = 5;
        if (signature.rva == soul_sub_weapon_detour.rva && soul_sub_weapon_detour.site != nullptr &&
            std::memcmp(soul_sub_weapon_detour.site, soul_sub_weapon_detour.installed, 5) == 0) skip = 5;
        if (std::memcmp(base + signature.rva + skip, expected + skip, sizeof(expected) - skip) != 0) {
            hook_diag.init_stage = CRYSTALJOBS_INIT_SIG_MISMATCH;
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
        hook_diag.init_stage = CRYSTALJOBS_INIT_BAD_PE;
        return false;
    }
#else
    return supported_impl(base);
#endif
}

extern "C" uint32_t __stdcall CrystalJobsShutdown() {
    AcquireSRWLockExclusive(&lifecycle_lock);
    enabled.store(false);
    pname_sheet_slot = nullptr;
    item_res_mgr_slot = nullptr;
    main_job_slot = nullptr;
    main_lvl_slot = nullptr;
    ability_list_slot = nullptr;
    original_get_inv_item = nullptr;
    original_get_item_res = nullptr;
    soul_sub_weapon_allow_resume = 0;
    soul_sub_weapon_deny_resume = 0;
    AcquireSRWLockExclusive(&state_lock);
    transport.reset(state);
    soul_override = {};
    ReleaseSRWLockExclusive(&state_lock);
    uint32_t failure = 0;
    if (!soul_sub_weapon_detour.restore()) failure = 3;
    if (!missing_spell_bit_detour.restore()) failure = 3;
    if (!can_use_spell_detour.restore()) failure = 3;
    for (size_t index = sizeof(patches) / sizeof(*patches); index-- > 0;) {
        auto& patch = patches[index];
        // Late high-ID replies must still be consumed after their last request was sent.
        if (ever_started && (patch.rva == 0xFA795 || patch.rva == 0xE2282) && patch.site != nullptr && std::memcmp(patch.site, patch.installed, 5) == 0) continue;
        if (!patch.restore()) failure = 3;
    }
    last_error.store(failure);
    ReleaseSRWLockExclusive(&lifecycle_lock);
    return failure;
}

static bool read_bounded_file_w(const wchar_t* path, char* buf, size_t max_bytes, size_t& out_len) noexcept {
    out_len = 0;
    if (path == nullptr || buf == nullptr || max_bytes == 0) return false;
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz{};
    const BOOL got_size = GetFileSizeEx(h, &sz);
    if (!got_size || sz.QuadPart <= 0 || static_cast<uint64_t>(sz.QuadPart) > max_bytes) {
        CloseHandle(h);
        return false;
    }
    DWORD total_read = 0;
    const DWORD expected = static_cast<DWORD>(sz.QuadPart);
    while (total_read < expected) {
        DWORD chunk = 0;
        if (!ReadFile(h, buf + total_read, expected - total_read, &chunk, nullptr) || chunk == 0) {
            CloseHandle(h);
            return false;
        }
        total_read += chunk;
    }
    CloseHandle(h);
    out_len = static_cast<size_t>(total_read);
    return true;
}

static bool build_trusted_data_path(HMODULE mod, const wchar_t* filename, wchar_t* out, size_t out_cap) noexcept {
    if (mod == nullptr || filename == nullptr || out == nullptr || out_cap < 32) return false;
    wchar_t mod_path[MAX_PATH]{};
    const DWORD n = GetModuleFileNameW(mod, mod_path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    size_t slash_end = 0;
    for (size_t i = 0; mod_path[i] != L'\0'; ++i) {
        if (mod_path[i] == L'\\' || mod_path[i] == L'/') slash_end = i + 1;
    }
    if (slash_end == 0) return false;
    const wchar_t* sub = L"data\\";
    const size_t sub_len = 5;
    const size_t fn_len = std::wcslen(filename);
    if (slash_end + sub_len + fn_len + 1 > out_cap) return false;
    std::memcpy(out, mod_path, slash_end * sizeof(wchar_t));
    std::memcpy(out + slash_end, sub, sub_len * sizeof(wchar_t));
    std::memcpy(out + slash_end + sub_len, filename, (fn_len + 1) * sizeof(wchar_t));
    // Reject any relative traversal sequences.
    if (std::wcsstr(out, L"..") != nullptr) return false;
    return true;
}

static void load_runtime_identity_and_presentation(HMODULE mod) noexcept {
    wchar_t ident_path[MAX_PATH]{};
    static char file_buf[kMaxIdentityFileBytes + 1]{};
    size_t file_len = 0;
    if (build_trusted_data_path(mod, L"soul-identities.json", ident_path, MAX_PATH) &&
        read_bounded_file_w(ident_path, file_buf, kMaxIdentityFileBytes, file_len)) {
        static RuntimeIdentityTable parsed_table{};
        if (parse_runtime_identity_json(file_buf, file_len, parsed_table)) {
            publish_runtime_identity_snapshot(parsed_table);
            char msg[160]{};
            std::snprintf(msg, sizeof(msg), "[crystaljobs] Loaded runtime soul-identities.json (66 souls, hash=%s)\n",
                parsed_table.registry_hash);
            OutputDebugStringA(msg);
        } else {
            clear_runtime_identity_snapshot(parsed_table.status, parsed_table.warning);
            char msg[192]{};
            std::snprintf(msg, sizeof(msg), "[crystaljobs] WARNING: Invalid soul-identities.json (%s); using compiled fallback (%s)\n",
                parsed_table.warning, kRegistryHash);
            OutputDebugStringA(msg);
        }
    } else {
        clear_runtime_identity_snapshot(IDENTITY_STATUS_FILE_MISSING, "soul-identities.json missing or unreadable; using compiled fallback");
        char msg[192]{};
        std::snprintf(msg, sizeof(msg), "[crystaljobs] WARNING: data\\soul-identities.json not found; using compiled fallback (%s)\n",
            kRegistryHash);
        OutputDebugStringA(msg);
    }

    wchar_t pres_path[MAX_PATH]{};
    size_t pres_len = 0;
    if (build_trusted_data_path(mod, L"crystaljobs-presentation.json", pres_path, MAX_PATH) &&
        read_bounded_file_w(pres_path, file_buf, kMaxPresentationFileBytes, pres_len)) {
        SearchPresentationConfig cfg{};
        if (parse_presentation_config_json(file_buf, pres_len, cfg)) {
            publish_search_presentation(cfg);
            char msg[160]{};
            std::snprintf(msg, sizeof(msg), "[crystaljobs] Loaded crystaljobs-presentation.json (tracking=%d, offsetX=%d, widths=%u)\n",
                cfg.tracking_px, cfg.offset_x_px, cfg.use_glyph_widths ? 1u : 0u);
            OutputDebugStringA(msg);
        } else {
            publish_search_presentation(cfg);
            char msg[192]{};
            std::snprintf(msg, sizeof(msg), "[crystaljobs] WARNING: Invalid crystaljobs-presentation.json (%s); using default spacing\n",
                cfg.warning);
            OutputDebugStringA(msg);
        }
    } else {
        publish_search_presentation(default_presentation_config());
    }
}

extern "C" uint32_t __stdcall CrystalJobsInitialize() {
    AcquireSRWLockExclusive(&lifecycle_lock);
    if (enabled.load()) { ReleaseSRWLockExclusive(&lifecycle_lock); return 0; }
    auto* base = reinterpret_cast<uint8_t*>(GetModuleHandleW(L"FFXiMain.dll"));
    if (!supported(base)) {
        last_error.store(1); ReleaseSRWLockExclusive(&lifecycle_lock); return 1;
    }
    original_lookup = reinterpret_cast<Lookup>(base + 0x1544C0);
    original_decode = reinterpret_cast<Decode>(base + 0x106300);
    original_encode = reinterpret_cast<Encode>(base + 0x104330);
    native_text = reinterpret_cast<NativeText>(base + 0x1CAD80);
    original_action_icon = reinterpret_cast<ActionIcon>(base + 0x222350);
    original_can_show_spell = reinterpret_cast<CanShowSpell>(base + 0x22CDE0);
    original_get_inv_item = reinterpret_cast<GetInventoryItem>(base + 0xEB5D0);
    original_get_item_res = reinterpret_cast<GetItemResource>(base + 0x15D210);
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
    HMODULE pinned;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&normal_sprite_hook), &pinned)) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_PIN_FAIL;
        last_error.store(2); ReleaseSRWLockExclusive(&lifecycle_lock); return 2;
    }
    load_runtime_identity_and_presentation(pinned);
    for (uint32_t i = 0; i < kPatchCount; ++i) {
        auto& patch = patches[i];
        if (!patch.install(base)) {
            hook_diag.init_stage = CRYSTALJOBS_INIT_PATCH_FAIL;
            hook_diag.failed_index = i;
            hook_diag.failed_rva = static_cast<uint32_t>(patch.rva);
            safe_read_bytes(base + patch.rva, hook_diag.observed_bytes);
            ReleaseSRWLockExclusive(&lifecycle_lock);
            const uint32_t failure = CrystalJobsShutdown() == 0 ? 2 : 3;
            last_error.store(failure); return failure;
        }
    }
    if (!can_use_spell_detour.install(base, &original_can_show_spell)) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_DETOUR_FAIL;
        hook_diag.failed_index = kPatchCount;
        hook_diag.failed_rva = static_cast<uint32_t>(can_use_spell_detour.rva);
        safe_read_bytes(base + can_use_spell_detour.rva, hook_diag.observed_bytes);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        const uint32_t failure = CrystalJobsShutdown() == 0 ? 2 : 3;
        last_error.store(failure); return failure;
    }
    missing_spell_bit_resume = reinterpret_cast<uintptr_t>(base + 0x22CB49);
    if (!missing_spell_bit_detour.install(base)) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_DETOUR_FAIL;
        hook_diag.failed_index = kPatchCount + 1u;
        hook_diag.failed_rva = static_cast<uint32_t>(missing_spell_bit_detour.rva);
        safe_read_bytes(base + missing_spell_bit_detour.rva, hook_diag.observed_bytes);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        const uint32_t failure = CrystalJobsShutdown() == 0 ? 2 : 3;
        last_error.store(failure); return failure;
    }
    soul_sub_weapon_deny_resume = reinterpret_cast<uintptr_t>(base + 0x133D5B);
    soul_sub_weapon_allow_resume = reinterpret_cast<uintptr_t>(base + 0x133D65);
    if (!soul_sub_weapon_detour.install(base)) {
        hook_diag.init_stage = CRYSTALJOBS_INIT_DETOUR_FAIL;
        hook_diag.failed_index = kPatchCount + 2u;
        hook_diag.failed_rva = static_cast<uint32_t>(soul_sub_weapon_detour.rva);
        safe_read_bytes(base + soul_sub_weapon_detour.rva, hook_diag.observed_bytes);
        ReleaseSRWLockExclusive(&lifecycle_lock);
        const uint32_t failure = CrystalJobsShutdown() == 0 ? 2 : 3;
        last_error.store(failure); return failure;
    }
    AcquireSRWLockExclusive(&state_lock);
    transport.reset(state);
    soul_override = {};
    ReleaseSRWLockExclusive(&state_lock);
    ever_started = true;
    hook_diag.init_stage = CRYSTALJOBS_INIT_OK;
    hook_diag.failed_rva = 0;
    hook_diag.failed_index = 0xFFFFFFFFu;
    std::memset(hook_diag.observed_bytes, 0, sizeof(hook_diag.observed_bytes));
    last_error.store(0);
    enabled.store(true);
    ReleaseSRWLockExclusive(&lifecycle_lock);
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsSetState(const uint8_t* bytes, uint32_t size) {
    if (bytes == nullptr || size != 8 || bytes[0] != 1 || bytes[1] > 1 || bytes[2] > 23 || bytes[3] > 7 || !enabled.load()) return 1;
    AcquireSRWLockExclusive(&state_lock);
    const uint32_t id = u32(bytes + 4);
    if (id != 0 && bytes[2] >= 1 && bytes[2] <= 23 && (transport.character == 0 || transport.character == id)) {
        transport.character = id;
        transport.job = bytes[2];
    }
    const bool valid = id == transport.character && bytes[2] == transport.job && id != 0;
    if (valid) state.update(bytes, size, GetTickCount());
    else if (id == 0 && bytes[1] == 0) { state.known = false; state.branch = 0; state.from_bridge = false; }
    ReleaseSRWLockExclusive(&state_lock);
    return valid ? 0 : 1;
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
    if (index == kPatchCount) return static_cast<uint32_t>(can_use_spell_detour.rva);
    if (index == kPatchCount + 1u) return static_cast<uint32_t>(missing_spell_bit_detour.rva);
    if (index == kPatchCount + 2u) return static_cast<uint32_t>(soul_sub_weapon_detour.rva);
    return 0;
}

static const uint8_t* hook_site_at(uint32_t index) noexcept {
    if (index < kPatchCount) return patches[index].site;
    if (index == kPatchCount) return can_use_spell_detour.site;
    if (index == kPatchCount + 1u) return missing_spell_bit_detour.site;
    if (index == kPatchCount + 2u) return soul_sub_weapon_detour.site;
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
    const PrologueDetour* detours[3] = {
        &can_use_spell_detour,
        &missing_spell_bit_detour,
        &soul_sub_weapon_detour,
    };
    for (uint32_t j = 0; j < 3u; ++j) {
        const uint32_t bit = kPatchCount + j;
        if (detours[j]->site != nullptr) {
            site_set_mask |= (1u << bit);
            if (std::memcmp(detours[j]->site, detours[j]->installed, 5) == 0) {
                installed_mask |= (1u << bit);
                ++total;
            }
        }
    }
    if (enabled.load()) {
        if (patch_installed_at(0x14868F)) caps |= CRYSTALJOBS_CAP_EQUIPMENT_SOUL_NAME;
        if (patch_installed_at(0x1CBD4C) && patch_installed_at(0x1CC086) &&
            patch_installed_at(0x1DEE6D) && patch_installed_at(0x1DEEFB)) {
            caps |= CRYSTALJOBS_CAP_SEARCH_SOUL_LABELS;
        }
        if (patch_installed_at(0x22E4F5)) caps |= CRYSTALJOBS_CAP_MAGIC_MENU_NAMES;
        if (patch_installed_at(0x22E245)) caps |= CRYSTALJOBS_CAP_MAGIC_MENU_DESC;
        if (patch_installed_at(0x22DED1)) caps |= CRYSTALJOBS_CAP_MAGIC_TARGET_HEADER;
        if (patch_installed_at(0x22E51B)) caps |= CRYSTALJOBS_CAP_MAGIC_MENU_ICONS;
        if (patch_installed_at(0x226129)) caps |= CRYSTALJOBS_CAP_ABILITY_MENU_NAMES;
        if (patch_installed_at(0x225F5D)) caps |= CRYSTALJOBS_CAP_ABILITY_MENU_DESC;
        if (patch_installed_at(0x225916)) caps |= CRYSTALJOBS_CAP_ABILITY_TARGET_HDR;
        if (patch_installed_at(0x22614E)) caps |= CRYSTALJOBS_CAP_ABILITY_MENU_ICONS;
        if (patch_installed_at(0x22DAB9)) caps |= CRYSTALJOBS_CAP_MAGIC_MENU_FILTER;
        if (patch_installed_at(0x22562F)) caps |= CRYSTALJOBS_CAP_ABILITY_MENU_FILTER;
        if (patch_installed_at(0x22E64D) &&
            ((installed_mask & (1u << kPatchCount)) != 0) &&
            ((installed_mask & (1u << (kPatchCount + 1u))) != 0)) {
            caps |= CRYSTALJOBS_CAP_SOUL_CAST_LOOKUP;
        }
        if ((installed_mask & (1u << (kPatchCount + 2u))) != 0) {
            caps |= CRYSTALJOBS_CAP_SOUL_SUB_WEAPON;
        }
    }
}

extern "C" uint32_t __stdcall CrystalJobsGetStatus(CrystalJobsStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    CrystalJobsStatus status{};
    status.size = sizeof(status); status.version = 1;
    AcquireSRWLockShared(&lifecycle_lock);
    uint32_t total = 0, inst_mask = 0, site_mask = 0, caps = 0;
    collect_hook_state(total, inst_mask, site_mask, caps);
    status.hooks = total;
    if (enabled.load() && status.hooks != kExpectedHooks) { enabled.store(false); last_error.store(3); }
    status.enabled = enabled.load();
    ReleaseSRWLockShared(&lifecycle_lock);
    AcquireSRWLockShared(&state_lock);
    status.character_id = transport.character; status.job = transport.job;
    status.known = status.enabled && state.known && state.alive(GetTickCount(), transport.character, transport.job); status.branch = status.known ? state.branch : 0;
    for (const auto& row : state.rows) if (row.character != 0 && row.branch != 0) ++status.search_rows;
    status.queries_sent = transport.sent; status.replies_accepted = transport.accepted; status.replies_rejected = transport.rejected;
    status.last_error = last_error.load();
    if (status.last_error == 0) status.last_error = transport.next_request > 0xffff ? 5 : transport.timeouts >= 3 ? 4 : 0;
    ReleaseSRWLockShared(&state_lock);
    status.decoded_rows = decoded_rows.load(); status.item_labels = item_lookups.load(); status.search_labels = short_draws.load(); status.full_labels = full_lookups.load();
    *output = status;
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsGetIdentityDiagnostics(CrystalJobsIdentityDiagnostics* output, uint32_t size) {
    if (output == nullptr || size < sizeof(CrystalJobsIdentityDiagnostics)) return 1;
    CrystalJobsIdentityDiagnostics diag{};
    diag.size = sizeof(CrystalJobsIdentityDiagnostics);
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
static_assert(sizeof(CrystalJobsStatus) == 68);
static_assert(sizeof(CrystalJobsActionEntry) == 288);
static_assert(sizeof(CrystalJobsActionStatus) == 64);

extern "C" uint32_t __stdcall CrystalJobsReplaceCatalog(const CrystalJobsActionEntry* entries, uint32_t count) {
    AcquireSRWLockExclusive(&action_lock);
    const bool ok = action_catalog.replace_all(entries, count);
    ReleaseSRWLockExclusive(&action_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall CrystalJobsUpsertAction(const CrystalJobsActionEntry* entry) {
    if (entry == nullptr) return 1;
    AcquireSRWLockExclusive(&action_lock);
    const bool ok = action_catalog.upsert(*entry);
    ReleaseSRWLockExclusive(&action_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall CrystalJobsClearCatalog() {
    AcquireSRWLockExclusive(&action_lock);
    action_catalog.clear();
    ReleaseSRWLockExclusive(&action_lock);
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsSetActiveSoul(uint32_t job, uint32_t branch, uint32_t character_id) {
    if (job < 1 || job > 22 || !valid_branch(static_cast<uint8_t>(job), static_cast<uint8_t>(branch))) return 1;
    AcquireSRWLockExclusive(&state_lock);
    soul_override.active = true;
    soul_override.job = static_cast<uint8_t>(job);
    soul_override.branch = static_cast<uint8_t>(branch);
    soul_override.character = character_id;
    ReleaseSRWLockExclusive(&state_lock);
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsClearActiveSoul() {
    AcquireSRWLockExclusive(&state_lock);
    soul_override = {};
    ReleaseSRWLockExclusive(&state_lock);
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsSetActionRowLimit(uint32_t max_chars) {
    if (max_chars < 8 || max_chars > 48) return 1;
    action_row_max_chars.store(max_chars, std::memory_order_relaxed);
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsGetActionStatus(CrystalJobsActionStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    CrystalJobsActionStatus st{};
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

    st.magic_name_hits = magic_name_hits.load();
    st.magic_desc_hits = magic_desc_hits.load();
    st.magic_icon_hits = magic_icon_hits.load();
    st.ability_name_hits = ability_name_hits.load();
    st.ability_desc_hits = ability_desc_hits.load();
    st.ability_icon_hits = ability_icon_hits.load();
    *output = st;
    return 0;
}

static_assert(sizeof(CrystalJobsVisibilityEntry) == 16);
static_assert(sizeof(CrystalJobsVisibilityStatus) == 40);

extern "C" uint32_t __stdcall CrystalJobsReplaceVisibility(const CrystalJobsVisibilityEntry* entries, uint32_t count) {
    AcquireSRWLockExclusive(&visibility_lock);
    const bool ok = visibility_catalog.replace_all(entries, count);
    ReleaseSRWLockExclusive(&visibility_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall CrystalJobsClearVisibility() {
    AcquireSRWLockExclusive(&visibility_lock);
    visibility_catalog.clear();
    ReleaseSRWLockExclusive(&visibility_lock);
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsGetVisibilityStatus(CrystalJobsVisibilityStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    CrystalJobsVisibilityStatus st{};
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
    st.magic_hidden_count = magic_hidden_count.load();
    st.magic_shown_count = magic_shown_count.load();
    st.ability_hidden_count = ability_hidden_count.load();
    *output = st;
    return 0;
}

static_assert(sizeof(CrystalJobsWeaponRule) == 24);
static_assert(sizeof(CrystalJobsWeaponStatus) == 36);
static_assert(sizeof(CrystalJobsHookDiagnostics) == 60);

extern "C" uint32_t __stdcall CrystalJobsReplaceWeaponRules(const CrystalJobsWeaponRule* entries, uint32_t count) {
    AcquireSRWLockExclusive(&weapon_lock);
    const bool ok = weapon_rule_catalog.replace_all(entries, count);
    ReleaseSRWLockExclusive(&weapon_lock);
    return ok ? 0 : 1;
}

extern "C" uint32_t __stdcall CrystalJobsClearWeaponRules() {
    AcquireSRWLockExclusive(&weapon_lock);
    weapon_rule_catalog.clear();
    ReleaseSRWLockExclusive(&weapon_lock);
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsGetWeaponStatus(CrystalJobsWeaponStatus* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    CrystalJobsWeaponStatus st{};
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
    st.allow_hits = weapon_allow_hits.load();
    st.deny_hits = weapon_deny_hits.load();
    *output = st;
    return 0;
}

extern "C" uint32_t __stdcall CrystalJobsGetHookDiagnostics(CrystalJobsHookDiagnostics* output, uint32_t size) {
    if (output == nullptr || size < sizeof(*output)) return 1;
    CrystalJobsHookDiagnostics d{};
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

    if (d.init_stage == CRYSTALJOBS_INIT_OK && d.total_hooks < d.expected_hooks) {
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

// Ashita v4 IPlugin interface (ASHITA_INTERFACE_VERSION = 4.30)
namespace {
constexpr double kAshitaInterfaceVersion = 4.30;

struct AshitaPluginBase {
    virtual const char* GetName(void) const = 0;
    virtual const char* GetAuthor(void) const = 0;
    virtual const char* GetDescription(void) const = 0;
    virtual const char* GetLink(void) const = 0;
    virtual double GetVersion(void) const = 0;
    virtual double GetInterfaceVersion(void) const = 0;
    virtual int32_t GetPriority(void) const = 0;
    virtual uint32_t GetFlags(void) const = 0;
    virtual bool Initialize(void* core, void* logger, uint32_t id) = 0;
    virtual void Release(void) = 0;
    virtual void HandleEvent(const char* eventName, const void* eventData, uint32_t eventSize) = 0;
    virtual bool HandleCommand(int32_t mode, const char* command, bool injected) = 0;
    virtual bool HandleIncomingText(int32_t mode, bool indent, const char* message, int32_t* modifiedMode, bool* modifiedIndent, char* modifiedMessage, bool injected, bool blocked) = 0;
    virtual bool HandleOutgoingText(int32_t mode, const char* message, int32_t* modifiedMode, char* modifiedMessage, bool injected, bool blocked) = 0;
    virtual bool HandleIncomingPacket(uint16_t id, uint32_t size, const uint8_t* data, uint8_t* modified, uint32_t sizeChunk, const uint8_t* dataChunk, bool injected, bool blocked) = 0;
    virtual bool HandleOutgoingPacket(uint16_t id, uint32_t size, const uint8_t* data, uint8_t* modified, uint32_t sizeChunk, const uint8_t* dataChunk, bool injected, bool blocked) = 0;
    virtual bool Direct3DInitialize(void* device) = 0;
    virtual void Direct3DBeginScene(bool isRenderingBackBuffer) = 0;
    virtual void Direct3DEndScene(bool isRenderingBackBuffer) = 0;
    virtual void Direct3DPresent(const RECT* pSourceRect, const RECT* pDestRect, HWND hDestWindowOverride, const RGNDATA* pDirtyRegion) = 0;
    virtual bool Direct3DSetRenderState(uint32_t State, DWORD* Value) = 0;
    virtual bool Direct3DDrawPrimitive(uint32_t PrimitiveType, UINT StartVertex, UINT PrimitiveCount) = 0;
    virtual bool Direct3DDrawIndexedPrimitive(uint32_t PrimitiveType, UINT minIndex, UINT NumVertices, UINT startIndex, UINT primCount) = 0;
    virtual bool Direct3DDrawPrimitiveUP(uint32_t PrimitiveType, UINT PrimitiveCount, const void* pVertexStreamZeroData, UINT VertexStreamZeroStride) = 0;
    virtual bool Direct3DDrawIndexedPrimitiveUP(uint32_t PrimitiveType, UINT MinVertexIndex, UINT NumVertexIndices, UINT PrimitiveCount, const void* pIndexData, uint32_t IndexDataFormat, const void* pVertexStreamZeroData, UINT VertexStreamZeroStride) = 0;
};

class CrystalJobsPlugin final : public AshitaPluginBase {
public:
    CrystalJobsPlugin() = default;
    ~CrystalJobsPlugin() = default;

    const char* GetName(void) const override { return "crystaljobs"; }
    const char* GetAuthor(void) const override { return "SoulspireXI"; }
    const char* GetDescription(void) const override { return "SoulspireXI native soul job labels for Equipment, Inventory, and Search."; }
    const char* GetLink(void) const override { return "https://github.com/Infomatictek/overlordsxi-launcher"; }
    double GetVersion(void) const override { return 1.00; }
    double GetInterfaceVersion(void) const override { return kAshitaInterfaceVersion; }
    int32_t GetPriority(void) const override { return 0; }
    uint32_t GetFlags(void) const override { return 0; }

    bool Initialize(void*, void*, uint32_t) override {
        CrystalJobsInitialize();
        return true;
    }

    void Release(void) override {
        CrystalJobsShutdown();
    }

    void HandleEvent(const char*, const void*, uint32_t) override {}
    bool HandleCommand(int32_t, const char*, bool) override { return false; }
    bool HandleIncomingText(int32_t, bool, const char*, int32_t*, bool*, char*, bool, bool) override { return false; }
    bool HandleOutgoingText(int32_t, const char*, int32_t*, char*, bool, bool) override { return false; }
    bool HandleIncomingPacket(uint16_t, uint32_t, const uint8_t*, uint8_t*, uint32_t, const uint8_t*, bool, bool) override { return false; }
    bool HandleOutgoingPacket(uint16_t, uint32_t, const uint8_t*, uint8_t*, uint32_t, const uint8_t*, bool, bool) override { return false; }
    bool Direct3DInitialize(void*) override {
        CrystalJobsInitialize();
        return true;
    }
    void Direct3DBeginScene(bool) override {}
    void Direct3DEndScene(bool) override {}
    void Direct3DPresent(const RECT*, const RECT*, HWND, const RGNDATA*) override {}
    bool Direct3DSetRenderState(uint32_t, DWORD*) override { return false; }
    bool Direct3DDrawPrimitive(uint32_t, UINT, UINT) override { return false; }
    bool Direct3DDrawIndexedPrimitive(uint32_t, UINT, UINT, UINT, UINT) override { return false; }
    bool Direct3DDrawPrimitiveUP(uint32_t, UINT, const void*, UINT) override { return false; }
    bool Direct3DDrawIndexedPrimitiveUP(uint32_t, UINT, UINT, UINT, const void*, uint32_t, const void*, UINT) override { return false; }
};
} // namespace

extern "C" double __stdcall expGetInterfaceVersion(void) {
    return kAshitaInterfaceVersion;
}

extern "C" void* __stdcall expCreatePlugin(const char*) {
    return new (std::nothrow) CrystalJobsPlugin();
}

extern "C" void __stdcall expDestroyPlugin(void* instance) {
    delete static_cast<CrystalJobsPlugin*>(instance);
}
