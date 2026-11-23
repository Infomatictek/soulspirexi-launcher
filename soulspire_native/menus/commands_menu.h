#pragma once
#include <cstddef>
#include <cstdint>
#include <cstring>

namespace soulspire::native {

// Native FFXI Commands menu ("menu    menuwind") integration constants.
// All offsets and layout measurements are verified against FFXiMain.dll
// (TimeDateStamp=0x6AE818B4, SizeOfImage=0xC17000) and ROM/118/111.DAT.
static constexpr char     kCommandsMenuFormName[16]     = {'m','e','n','u',' ',' ',' ',' ','m','e','n','u','w','i','n','d'};
static constexpr int16_t  kCommandsSoulspireButtonId    = 16;
static constexpr int16_t  kCommandsVanillaButtonCount   = 15;
static constexpr int16_t  kCommandsExpandedButtonCount  = 16;
static constexpr int16_t  kCommandsVanillaFrameH        = 202;
static constexpr int16_t  kCommandsExpandedFrameH       = 218;
static constexpr int16_t  kCommandsRowPitchPx           = 16;
static constexpr int16_t  kCommandsSoulspireRelX        = 16;
static constexpr int16_t  kCommandsSoulspireRelY        = 22;
static constexpr int16_t  kCommandsSoulspireW           = 88;
static constexpr int16_t  kCommandsSoulspireH           = 16;
static constexpr size_t   kCommandsSpriteTileCount      = 20;
static constexpr size_t   kMaxCommandsSpriteBanks       = 4;
static constexpr size_t   kCommandsSourceSpriteCount    = 5;
static constexpr uint32_t kCommandsButtonStateEnabled   = 0x0Bu;
static constexpr uint32_t kCommandsButtonStatePressed   = 0x01u;
static constexpr int16_t  kCommandsKeyDown              = 1;
static constexpr int16_t  kCommandsKeyUp                = 2;
static constexpr int16_t  kCommandsKeyLeft              = 3;
static constexpr int16_t  kCommandsKeyRight             = 4;
static constexpr int16_t  kCommandsKeyConfirm           = 5;

static constexpr const char kCommandsSoulspireTitle[] = "Soulspire";
static constexpr const char kCommandsSoulspireHelp[]  = "Open SoulspireXI Core.";

// Vanilla ROM/118/111.DAT menu-relative Y positions for menu    menuwind buttons 1..15.
// Buttons 2..12 sit directly below Status (1) and shift down +16px when Soulspire (16) is inserted.
// Buttons 13 (< arrow), 14 (> arrow), and 15 ("Commands" header) must never be shifted.
inline constexpr int16_t commands_vanilla_row_y(int16_t btn_id) noexcept {
    switch (btn_id) {
        case 1:  return 6;   // Status
        case 2:  return 22;  // Equipment
        case 3:  return 38;  // Magic
        case 4:  return 54;  // Items
        case 10: return 70;  // Synthesis
        case 5:  return 86;  // Abilities
        case 6:  return 102; // Party
        case 7:  return 118; // Trade
        case 8:  return 134; // Search
        case 9:  return 150; // Linkshell
        case 11: return 166; // Region Info
        case 12: return 182; // Map / My Room
        default: return -1;
    }
}

inline constexpr bool is_commands_shifted_row_button(int16_t btn_id) noexcept {
    return btn_id >= 2 && btn_id <= 12;
}

inline constexpr int16_t commands_target_row_y(int16_t btn_id, bool injected) noexcept {
    if (btn_id == kCommandsSoulspireButtonId) {
        return injected ? kCommandsSoulspireRelY : -1;
    }
    const int16_t vanilla_y = commands_vanilla_row_y(btn_id);
    if (vanilla_y < 0) return -1;
    if (injected && is_commands_shifted_row_button(btn_id)) {
        return static_cast<int16_t>(vanilla_y + kCommandsRowPitchPx);
    }
    return vanilla_y;
}

// Pure D-pad / keyboard navigation override for menu    menuwind.
// Returns > 0 to override CTkMenuData::GetNextButton, or 0 to delegate to vanilla.
// Mandatory placement:
//   1. Status (btn 1)
//   2. Soulspire (btn 16)
//   3. Equipment (btn 2)
//   4. Magic (btn 3) ... remaining vanilla items in original order.
inline constexpr int16_t resolve_commands_menu_next_button(
    int16_t current_btn_id,
    int16_t direction_key,
    bool injected) noexcept {
    if (!injected) return 0;
    if (direction_key == kCommandsKeyDown) {
        if (current_btn_id == 1) return kCommandsSoulspireButtonId;
        if (current_btn_id == kCommandsSoulspireButtonId) return 2;
        return 0;
    }
    if (direction_key == kCommandsKeyUp) {
        if (current_btn_id == 2) return kCommandsSoulspireButtonId;
        if (current_btn_id == kCommandsSoulspireButtonId) return 1;
        return 0;
    }
    if (direction_key == kCommandsKeyLeft || direction_key == kCommandsKeyRight) {
        if (current_btn_id == kCommandsSoulspireButtonId) return kCommandsSoulspireButtonId;
        return 0;
    }
    return 0;
}

inline bool is_commands_menu_form(const uint8_t* menu_data) noexcept {
    if (menu_data == nullptr) return false;
    return std::memcmp(menu_data + 0x46, kCommandsMenuFormName, sizeof(kCommandsMenuFormName)) == 0;
}

// Packed FFXI MenuButtonRes descriptor (32 bytes, matches CTkMenuButton::Init @ 0x11AEE0).
#pragma pack(push, 1)
struct NativeMenuButtonRes {
    uint16_t flags;        // +0x00
    int16_t  x;            // +0x02
    int16_t  y;            // +0x04
    uint16_t unk06;        // +0x06
    uint16_t unk08;        // +0x08
    int16_t  w;            // +0x0A
    int16_t  h;            // +0x0C
    uint16_t unk0E;        // +0x0E
    uint16_t unk10;        // +0x10
    int16_t  button_id;    // +0x12
    uint16_t unk14;        // +0x14
    uint8_t  unk16;        // +0x16
    int8_t   nav_up;       // +0x17
    int8_t   nav_down;     // +0x18
    int8_t   nav_left;     // +0x19
    int8_t   nav_right;    // +0x1A
    uint8_t  sprite_count; // +0x1B (0 => UpdateSprite skips sheet lookup and uses override_sprite)
    uint32_t unk1C;        // +0x1C
};
#pragma pack(pop)

static_assert(sizeof(NativeMenuButtonRes) == 0x20, "NativeMenuButtonRes must be 32 bytes");
static_assert(offsetof(NativeMenuButtonRes, x) == 0x02);
static_assert(offsetof(NativeMenuButtonRes, y) == 0x04);
static_assert(offsetof(NativeMenuButtonRes, w) == 0x0A);
static_assert(offsetof(NativeMenuButtonRes, h) == 0x0C);
static_assert(offsetof(NativeMenuButtonRes, button_id) == 0x12);
static_assert(offsetof(NativeMenuButtonRes, nav_up) == 0x17);
static_assert(offsetof(NativeMenuButtonRes, nav_down) == 0x18);
static_assert(offsetof(NativeMenuButtonRes, nav_left) == 0x19);
static_assert(offsetof(NativeMenuButtonRes, nav_right) == 0x1A);
static_assert(offsetof(NativeMenuButtonRes, sprite_count) == 0x1B);

// FFXI CTkMenuButtonData descriptor (20 bytes on x86, matches CTkMenuButton::Init @ 0x11AEE0).
struct NativeMenuButtonData {
    const NativeMenuButtonRes* res;       // +0x00
    void*                      sprites;   // +0x04
    const char*                help;      // +0x08 -> g_pHelpWind ("Open SoulspireXI Core.")
    const char*                title;     // +0x0C -> g_pTitleWind ("Soulspire")
    uint32_t                   action_id; // +0x10
};

#if defined(_M_IX86) || defined(__i386__)
static_assert(sizeof(NativeMenuButtonData) == 0x14, "NativeMenuButtonData must be 20 bytes on x86");
#endif

inline constexpr NativeMenuButtonRes make_soulspire_button_res() noexcept {
    NativeMenuButtonRes r{};
    r.x            = kCommandsSoulspireRelX;
    r.y            = kCommandsSoulspireRelY;
    r.w            = kCommandsSoulspireW;
    r.h            = kCommandsSoulspireH;
    r.button_id    = kCommandsSoulspireButtonId;
    r.nav_up       = 1;
    r.nav_down     = 2;
    r.nav_left     = static_cast<int8_t>(kCommandsSoulspireButtonId);
    r.nav_right    = static_cast<int8_t>(kCommandsSoulspireButtonId);
    r.sprite_count = 0;
    return r;
}

// Glyph recipe for synthesizing the native 20-tile "Soulspire" button sprite
// directly from live Commands menu sprites (zero DAT file modifications).
// Source button index map:
//   0 = Status (Btn 1, >=14 tiles)
//   1 = Equipment (Btn 2, >=20 tiles)
//   2 = Trade (Btn 7, >=12 tiles)
//   3 = Linkshell (Btn 9, >=20 tiles)
//   4 = Region Info (Btn 11, >=22 tiles)
struct SoulspireGlyphSpec {
    uint8_t src_idx;
    uint8_t shadow_tile;
    uint8_t fg_tile;
    uint8_t fallback_w;
};

static constexpr int16_t kCommandsSourceButtonIds[kCommandsSourceSpriteCount] = {1, 2, 7, 9, 11};
static constexpr uint32_t kCommandsSourceMinTiles[kCommandsSourceSpriteCount] = {14u, 20u, 12u, 20u, 22u};

static constexpr SoulspireGlyphSpec kSoulspireGlyphSpecs[9] = {
    {0, 2,  8,  9}, // 'S' from Status
    {4, 6,  16, 9}, // 'o' from Region Info
    {0, 6,  12, 9}, // 'u' from Status
    {3, 9,  18, 6}, // 'l' from Linkshell
    {0, 7,  13, 9}, // 's' from Status
    {1, 6,  15, 9}, // 'p' from Equipment
    {1, 5,  14, 5}, // 'i' from Equipment
    {2, 3,  8,  7}, // 'r' from Trade
    {1, 8,  17, 9}, // 'e' from Equipment
};

struct SoulspireSpriteBankKey {
    const uint8_t* src_sprites[kCommandsSourceSpriteCount]{};
    uint8_t        status_sprite_hdr[16]{};
    uint8_t        status_tile0_hdr[32]{};
};

// Immutable synthesized 20-tile CYySprite bank (allocated once per live sprite-sheet
// instance, never overwritten or freed while FFXI may still draw from it).
struct SoulspireMenuSpriteBank {
    bool                   active = false;
    SoulspireSpriteBankKey key{};
    alignas(16) uint8_t    sprite[0x30]{};
    alignas(16) uint8_t    nodes[kCommandsSpriteTileCount][0x18]{};
    alignas(16) uint8_t    tiles[kCommandsSpriteTileCount][0xE0]{};
};

inline bool sprite_list_tile_at(
    const uint8_t* sprite,
    uint32_t index,
    const uint8_t*& out_node,
    const uint8_t*& out_tile) noexcept {
    if (sprite == nullptr) return false;
    uint32_t count = 0;
    std::memcpy(&count, sprite + 0x14, sizeof(count));
    if (index >= count || count > 64u) return false;

    const uint8_t* node = nullptr;
    std::memcpy(&node, sprite + 0x04, sizeof(node));
    uint32_t seen = 0;
    uint32_t guard = 0;
    while (node != nullptr && guard < 128u) {
        ++guard;
        if (node[0x14] == 0) {
            if (seen == index) {
                const uint8_t* tile = nullptr;
                std::memcpy(&tile, node + 0x10, sizeof(tile));
                if (tile == nullptr) return false;
                out_node = node;
                out_tile = tile;
                return true;
            }
            ++seen;
        }
        const uint8_t* next = nullptr;
        std::memcpy(&next, node + 0x00, sizeof(next));
        node = next;
    }
    return false;
}

inline bool commands_sprite_bank_key_matches(
    const SoulspireSpriteBankKey& key,
    const uint8_t* const src_sprites[kCommandsSourceSpriteCount],
    const uint8_t* status_tile0) noexcept {
    if (src_sprites == nullptr || src_sprites[0] == nullptr || status_tile0 == nullptr) return false;
    for (size_t i = 0; i < kCommandsSourceSpriteCount; ++i) {
        if (key.src_sprites[i] != src_sprites[i]) return false;
    }
    return std::memcmp(key.status_sprite_hdr, src_sprites[0], sizeof(key.status_sprite_hdr)) == 0 &&
           std::memcmp(key.status_tile0_hdr, status_tile0, sizeof(key.status_tile0_hdr)) == 0;
}

// Clones 2 pill tiles + 9 shadow tiles + 9 foreground tiles into `bank` to render
// "Soulspire" with FFXI's native font, pill background, highlight, and scaling.
inline bool synthesize_soulspire_menu_sprite(
    SoulspireMenuSpriteBank& bank,
    const uint8_t* const src_sprites[kCommandsSourceSpriteCount]) noexcept {
    if (src_sprites == nullptr) return false;
    for (size_t i = 0; i < kCommandsSourceSpriteCount; ++i) {
        if (src_sprites[i] == nullptr) return false;
        uint32_t tile_count = 0;
        std::memcpy(&tile_count, src_sprites[i] + 0x14, sizeof(tile_count));
        if (tile_count < kCommandsSourceMinTiles[i] || tile_count > 64u) return false;
    }

    const uint8_t* pill_nodes[2]{};
    const uint8_t* pill_tiles[2]{};
    if (!sprite_list_tile_at(src_sprites[0], 0, pill_nodes[0], pill_tiles[0]) ||
        !sprite_list_tile_at(src_sprites[0], 1, pill_nodes[1], pill_tiles[1])) {
        return false;
    }

    const uint8_t* sh_nodes[9]{};
    const uint8_t* sh_tiles[9]{};
    const uint8_t* fg_nodes[9]{};
    const uint8_t* fg_tiles[9]{};
    for (size_t g = 0; g < 9; ++g) {
        const auto& spec = kSoulspireGlyphSpecs[g];
        if (!sprite_list_tile_at(src_sprites[spec.src_idx], spec.shadow_tile, sh_nodes[g], sh_tiles[g]) ||
            !sprite_list_tile_at(src_sprites[spec.src_idx], spec.fg_tile, fg_nodes[g], fg_tiles[g])) {
            return false;
        }
    }

    std::memset(&bank, 0, sizeof(bank));
    std::memcpy(bank.sprite, src_sprites[0], sizeof(bank.sprite));

    // Tiles 0..1: native menu    buttonto pill background ([0..48] + [48..88]).
    for (size_t i = 0; i < 2; ++i) {
        std::memcpy(bank.nodes[i], pill_nodes[i], sizeof(bank.nodes[i]));
        std::memcpy(bank.tiles[i], pill_tiles[i], sizeof(bank.tiles[i]));
    }

    // Tiles 2..10: 9 drop-shadow glyphs (+2,+2); Tiles 11..19: 9 foreground glyphs.
    int16_t cur_fg_x = 5;
    for (size_t g = 0; g < 9; ++g) {
        const size_t sh_dst = 2 + g;
        const size_t fg_dst = 11 + g;
        std::memcpy(bank.nodes[sh_dst], sh_nodes[g], sizeof(bank.nodes[sh_dst]));
        std::memcpy(bank.tiles[sh_dst], sh_tiles[g], sizeof(bank.tiles[sh_dst]));
        std::memcpy(bank.nodes[fg_dst], fg_nodes[g], sizeof(bank.nodes[fg_dst]));
        std::memcpy(bank.tiles[fg_dst], fg_tiles[g], sizeof(bank.tiles[fg_dst]));

        int16_t src_fg_x[4]{};
        std::memcpy(src_fg_x, fg_tiles[g] + 0xC0, sizeof(src_fg_x));
        int16_t width = static_cast<int16_t>(src_fg_x[1] - src_fg_x[0]);
        if (width < 3 || width > 12) {
            width = static_cast<int16_t>(kSoulspireGlyphSpecs[g].fallback_w);
        }

        const int16_t fg_x0 = cur_fg_x;
        const int16_t fg_x1 = static_cast<int16_t>(fg_x0 + width);
        const int16_t sh_x0 = static_cast<int16_t>(fg_x0 + 2);
        const int16_t sh_x1 = static_cast<int16_t>(sh_x0 + width);

        const int16_t sh_xs[4] = {sh_x0, sh_x1, sh_x0, sh_x1};
        const int16_t fg_xs[4] = {fg_x0, fg_x1, fg_x0, fg_x1};
        std::memcpy(bank.tiles[sh_dst] + 0xC0, sh_xs, sizeof(sh_xs));
        std::memcpy(bank.tiles[fg_dst] + 0xC0, fg_xs, sizeof(fg_xs));
        cur_fg_x = fg_x1;
    }

    // Link all 20 CYyListNode entries cleanly in forward/backward order.
    for (size_t i = 0; i < kCommandsSpriteTileCount; ++i) {
        uint8_t* next_ptr = (i + 1 < kCommandsSpriteTileCount) ? bank.nodes[i + 1] : nullptr;
        uint8_t* prev_ptr = (i > 0) ? bank.nodes[i - 1] : nullptr;
        uint8_t* tile_ptr = bank.tiles[i];
        std::memcpy(bank.nodes[i] + 0x00, &next_ptr, sizeof(next_ptr));
        std::memcpy(bank.nodes[i] + 0x04, &prev_ptr, sizeof(prev_ptr));
        std::memcpy(bank.nodes[i] + 0x10, &tile_ptr, sizeof(tile_ptr));
        bank.nodes[i][0x14] = 0;
    }

    uint8_t* head_ptr = bank.nodes[0];
    uint8_t* tail_ptr = bank.nodes[kCommandsSpriteTileCount - 1];
    uint8_t* null_ptr = nullptr;
    const uint32_t tile_count = static_cast<uint32_t>(kCommandsSpriteTileCount);
    std::memcpy(bank.sprite + 0x04, &head_ptr, sizeof(head_ptr));
    std::memcpy(bank.sprite + 0x08, &tail_ptr, sizeof(tail_ptr));
    std::memcpy(bank.sprite + 0x0C, &null_ptr, sizeof(null_ptr));
    std::memcpy(bank.sprite + 0x10, &null_ptr, sizeof(null_ptr));
    std::memcpy(bank.sprite + 0x14, &tile_count, sizeof(tile_count));

    for (size_t i = 0; i < kCommandsSourceSpriteCount; ++i) {
        bank.key.src_sprites[i] = src_sprites[i];
    }
    std::memcpy(bank.key.status_sprite_hdr, src_sprites[0], sizeof(bank.key.status_sprite_hdr));
    std::memcpy(bank.key.status_tile0_hdr, pill_tiles[0], sizeof(bank.key.status_tile0_hdr));
    bank.active = true;
    return true;
}

} // namespace soulspire::native
