#pragma once
#include "../job_identity/job_identity.h"
#include <atomic>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>

namespace soulspire::native {

struct SpriteArgs {
    int x, y;
    float scale_x, scale_y;
    uint32_t color;
    int center, first, count;
};
static_assert(sizeof(SpriteArgs) == 32);

struct SimpleSpriteArgs {
    int x, y;
    uint32_t color;
    int center, first;
};
static_assert(sizeof(SimpleSpriteArgs) == 20);

// Search 3-letter job badge rendering mode:
//   0 = Legacy single-call 0.75x native_text fallback
//   1 = Verified native menu2fon sprite renderer (SoA x[4]/y[4] quad corners at tile+0xC0 + configurable tracking)
//   2 = Aligned native_text fallback (per-character fixed-column 0x1CAD80 native_text)
#ifndef SOULSPIRE_NATIVE_SEARCH_RENDER_MODE
#ifdef CRYSTALJOBS_SEARCH_RENDER_MODE
#define SOULSPIRE_NATIVE_SEARCH_RENDER_MODE CRYSTALJOBS_SEARCH_RENDER_MODE
#else
#define SOULSPIRE_NATIVE_SEARCH_RENDER_MODE 1
#endif
#endif

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
    {118, 214, 7}, // H (SCH) — verified against ROM/118/111.DAT menu2fon DXT3; avoids WHM u=59 W-serif bleed
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
    // [0x50..0xBF] holds FFXI's per-draw D3D8 TLVERTEX screen-position/diffuse buffer.
    uint8_t tile_header_bytes[0x50];
};

struct Menu2fonBank {
    bool active;
    Menu2fonTemplateKey key;
    bool initialized[kGlyphX0Span][26];
    GlyphSlot slots[kGlyphX0Span][26];
};

// Heap-allocated on demand up to kMaxMenu2fonBanks (16 distinct D3D8 device resets/reloads)
// so idle memory footprint is zero while preventing premature sprite-bank exhaustion in long
// sessions. Every handed-out GlyphSlot* remains immutable for deferred D3D8 safety.
static constexpr size_t kMaxMenu2fonBanks = 16;

inline void compute_search_glyph_positions(
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
        if (step < 4) step = 4;
        x[i + 1] = x[i] + step;
    }
    const int32_t right_edge = x[2] + static_cast<int32_t>(widths[2]);
    if (right_edge > 24) {
        int32_t shift = right_edge - 24;
        if (x[0] - shift < kMinGlyphX0) {
            shift = x[0] - kMinGlyphX0;
        }
        if (shift > 0) {
            x[0] -= shift;
            x[1] -= shift;
            x[2] -= shift;
        }
        const int32_t max_x2 = 24 - static_cast<int32_t>(widths[2]);
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

inline bool menu2fon_key_matches(
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

inline void init_glyph_slot(
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

} // namespace soulspire::native
