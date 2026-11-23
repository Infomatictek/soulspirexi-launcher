#define CRYSTALJOBS_SELFTEST
#include "crystaljobs.cpp"
#include <cassert>

static uint8_t row_a[72]{}, row_b[72]{};
static uint32_t sprite_calls, simple_sprite_calls, text_calls, persona_text_calls, last_persona_color;
static const char* last_text;
static char last_text_buf[32]{};
static const char* last_persona_text;
static int __cdecl fake_text(int x, int y, const char* text, uint32_t color, float sx, float sy, int center) {
#if CRYSTALJOBS_SEARCH_RENDER_MODE == 2
    assert(text != nullptr && color == 0x80808080u && center == 0);
    if (std::strlen(text) == 1) {
        assert(x >= 100 && x <= 116 && y == 51 && sx == 0.72f && sy == 0.78f);
    } else {
        assert(x == 100 && y == 50 && sx == 0.75f && sy == 0.75f);
    }
#else
    assert(x == 100 && y == 50 && color == 0x80808080 && sx == 0.75f && sy == 0.75f && center == 0);
#endif
    ++text_calls;
    if (text != nullptr) {
        std::snprintf(last_text_buf, sizeof(last_text_buf), "%s", text);
        last_text = last_text_buf;
    } else {
        last_text = nullptr;
    }
    return x;
}
static int __cdecl fake_persona_text(int x, int y, const char* text, uint32_t color, float sx, float sy, int center) {
    assert(x == 142 && y == 69 && sx == 1.0f && sy == 1.0f && center == 0);
    ++persona_text_calls; last_persona_text = text; last_persona_color = color; return x;
}
static const uint8_t* recorded_sprites[1024]{};
static size_t recorded_sprite_count = 0;
static int __fastcall fake_sprite(void* self, void*, int x, int y, float sx, float sy, uint32_t color, int center, int first, int count) {
    assert(x == 100 && y == 50 && sx == 1.0f && sy == 1.0f && color == 0x80808080 && center == 0 && first == 0 && count == 0);
    if (recorded_sprite_count < 1024) {
        recorded_sprites[recorded_sprite_count++] = static_cast<const uint8_t*>(self);
    }
    ++sprite_calls; return 1;
}
static void __fastcall fake_sprite_simple(void* self, void*, int x, int y, uint32_t color, int center, int first) {
    assert(reinterpret_cast<uintptr_t>(self) == 0x34567890u && x == 142 && y == 69 && (color == 0x80808080u || color == 0x802060a0u) && center == 0 && first == 0);
    ++simple_sprite_calls;
}
static uint32_t fake_spell_name_calls, fake_spell_desc_calls, fake_abil_name_calls, fake_abil_desc_calls, fake_icon_calls;
static uint32_t last_icon_v1, last_icon_v2;
static const char* __fastcall fake_spell_name_fn(void* self, void*, int id) {
    assert(reinterpret_cast<uintptr_t>(self) == 0x2468ace0u);
    ++fake_spell_name_calls;
    if (id == 338) return "Utsusemi: Ichi";
    if (id == 339) return "Utsusemi: Ni";
    return "Vanilla Spell";
}
static const char* __fastcall fake_spell_desc_fn(void* self, void*, int id) {
    assert(reinterpret_cast<uintptr_t>(self) == 0x2468ace0u);
    ++fake_spell_desc_calls;
    return id == 338 ? "Vanilla Utsusemi Ichi desc." : "Vanilla Spell desc.";
}
static const char* __fastcall fake_abil_name_fn(void* self, void*, int id) {
    assert(reinterpret_cast<uintptr_t>(self) == 0x2468ace0u);
    ++fake_abil_name_calls;
    if (id == 128) return "Blade: Jin";
    if (id == 600) return "Yonin";
    return "Vanilla Ability";
}
static const char* __fastcall fake_abil_desc_fn(void* self, void*, int id) {
    assert(reinterpret_cast<uintptr_t>(self) == 0x2468ace0u);
    ++fake_abil_desc_calls;
    return id == 128 ? "Vanilla WS desc." : "Vanilla JA desc.";
}
static void* __cdecl fake_action_icon_fn(uint32_t v1, uint32_t v2) {
    ++fake_icon_calls;
    last_icon_v1 = v1;
    last_icon_v2 = v2;
    return reinterpret_cast<void*>(0x13579bdfu);
}
static uint32_t fake_can_show_calls, fake_set_list_count_calls;
static int32_t last_set_list_count, last_set_list_flags;
static uint8_t __cdecl fake_can_show_spell_fn(const uint8_t* spell_res) {
    ++fake_can_show_calls;
    return (spell_res != nullptr && u16(spell_res) != 999u) ? 1 : 0;
}
static void __fastcall fake_set_list_count_fn(void*, void*, int32_t count, int32_t flags) {
    ++fake_set_list_count_calls;
    last_set_list_count = count;
    last_set_list_flags = flags;
}
static const char* __cdecl fake_lookup(int table, int job) {
    assert(table == 18 || table == 2);
    if (table == 2) {
        switch (job) {
            case 1: return "WAR";
            case 2: return "MNK";
            case 4: return "BLM";
            case 12: return "SAM";
            case 19: return "DNC";
            case 20: return "SCH";
            case 22: return "RUN";
            default: return "OTH";
        }
    }
    return job == 1 ? "Warrior" : "Monk";
}

// Naked fixtures keep the row in the real caller's register without relying on a compiler frame pointer.
static __declspec(naked) bool sprite_abi(void*, const uint8_t*) {
    __asm {
        push ebp
        push ebx
        push esi
        push edi
        mov ebp, [esp + 24]
        mov edi, ebp
        mov ebx, 12345678h
        mov esi, 23456789h
        push 45678901h
        push 0
        push 0
        push 0
        push 80808080h
        push 3f800000h
        push 3f800000h
        push 50
        push 100
        mov ecx, 34567890h
        call dword ptr [esp + 56]
        xor eax, eax
        cmp dword ptr [esp], 45678901h
        jne failed
        cmp ebx, 12345678h
        jne failed
        cmp esi, 23456789h
        jne failed
        cmp edi, ebp
        jne failed
        cmp ebp, [esp + 28]
        jne failed
        mov eax, 1
    failed:
        add esp, 4
        pop edi
        pop esi
        pop ebx
        pop ebp
        ret
    }
}

static __declspec(naked) bool persona_abi(void*, uint32_t) {
    __asm {
        push ebp
        push ebx
        push esi
        push edi
        mov ebx, 12345678h
        mov esi, 23456789h
        mov edi, 3456789ah
        mov ebp, 456789abh
        mov eax, [esp + 24]
        push 56789abch
        push 0
        push 0
        push eax
        push 69
        push 142
        mov ecx, 34567890h
        call dword ptr [esp + 44]
        xor eax, eax
        cmp dword ptr [esp], 56789abch
        jne failed
        cmp ebx, 12345678h
        jne failed
        cmp esi, 23456789h
        jne failed
        cmp edi, 3456789ah
        jne failed
        cmp ebp, 456789abh
        jne failed
        mov eax, 1
    failed:
        add esp, 4
        pop edi
        pop esi
        pop ebx
        pop ebp
        ret
    }
}

static __declspec(naked) const char* action_str_abi(void*, int32_t) {
    __asm {
        push ebp
        push ebx
        push esi
        push edi
        mov ebx, 11223344h
        mov esi, 22334455h
        mov edi, 33445566h
        mov ebp, 44556677h
        mov eax, [esp + 24]
        push 55667788h
        push eax
        mov ecx, 2468ace0h
        call dword ptr [esp + 28]
        cmp dword ptr [esp], 55667788h
        jne failed
        cmp ebx, 11223344h
        jne failed
        cmp esi, 22334455h
        jne failed
        cmp edi, 33445566h
        jne failed
        cmp ebp, 44556677h
        jne failed
        jmp done
    failed:
        xor eax, eax
    done:
        add esp, 4
        pop edi
        pop esi
        pop ebx
        pop ebp
        ret
    }
}

// Mirrors 0x102254d0's exact stack frame: saved_sel sits at [esp + 0x1c] after SetListCount's ret 8.
static __declspec(naked) int32_t ability_filter_abi(void*, int32_t, int32_t) {
    __asm {
        push ebp
        push ebx
        push esi
        push edi
        sub esp, 0x24
        mov ecx, [esp + 0x38]       ; menu_obj
        mov eax, [esp + 0x3c]       ; count
        mov edx, [esp + 0x40]       ; saved_sel
        mov [esp + 0x1c], edx
        mov ebx, 11223344h
        mov esi, 22334455h
        mov edi, 33445566h
        mov ebp, 44556677h
        push 0
        push eax
        call ability_list_filter_hook
        mov eax, [esp + 0x1c]       ; return updated saved_sel
        cmp ebx, 11223344h
        jne bad
        cmp esi, 22334455h
        jne bad
        cmp edi, 33445566h
        jne bad
        cmp ebp, 44556677h
        je ok
    bad:
        mov eax, -999
    ok:
        add esp, 0x24
        pop edi
        pop esi
        pop ebx
        pop ebp
        ret
    }
}

static __declspec(naked) const char* full_abi(const uint8_t*, int) {
    __asm {
        push esi
        mov esi, [esp + 8]
        push dword ptr [esp + 12]
        push 18
        call full_job_hook
        add esp, 8
        cmp esi, [esp + 8]
        je good
        xor eax, eax
    good:
        pop esi
        ret
    }
}

static void make_row(uint8_t* row, uint32_t id, uint32_t tag, uint8_t job = 1, uint32_t privacy = 0) {
    std::memset(row, 0, 72);
    const uint32_t fields = 0x4140;
    std::memcpy(row, &fields, 4);
    std::memcpy(row + 20, &tag, 4);
    std::memcpy(row + 24, &id, 4);
    std::memcpy(row + 48, &privacy, 4);
    row[32] = job;
}

static void make_packet(uint8_t* bytes, uint16_t id, uint32_t size) {
    std::memset(bytes, 0, size);
    const uint16_t header = static_cast<uint16_t>(id | ((size / 4) << 9));
    std::memcpy(bytes, &header, 2);
}

static void make_reply(uint8_t* bytes, uint16_t request, uint8_t branch = 2, uint8_t job = 1, uint8_t lvl = 75) {
    make_packet(bytes, 0x1ff, 64);
    std::memcpy(bytes + 4, "CRYS", 4); bytes[8] = 1;
    std::memcpy(bytes + 10, &request, 2); bytes[12] = job; bytes[13] = 24;
    bytes[14] = lvl; bytes[15] = 0;
    bytes[16 + job * 2] = 14;
    bytes[16 + job * 2 + 1] = branch;
}

static int fake_decode_result;
static void* __cdecl fake_search_decode(const uint8_t* input, uint8_t* output, int flags) {
    assert(input == nullptr && flags == 1);
    return output + 72;
}
static int __cdecl fake_map_decode(uint8_t*, uint32_t capacity, uintptr_t context, uintptr_t tree, const uint8_t* wire, uint32_t length) {
    assert(capacity == 512 && context == 11 && tree == 12 && wire == nullptr && length == 13);
    return fake_decode_result;
}
static int __cdecl fake_map_encode(const uint8_t* bytes, uint32_t length, uint8_t* output, uint32_t capacity, uintptr_t table) {
    assert(capacity == 512 && table == 11 && length <= capacity);
    std::memcpy(output, bytes, length);
    return static_cast<int>(length);
}

static void transport_checks() {
    Transport model;
    State labels;
    uint8_t login[0xb8], request[16], reply[64];
    make_packet(login, 0x00a, sizeof(login));
    const uint32_t id = 100;
    std::memcpy(login + 4, &id, 4); login[0xb4] = 1;
    assert(whole_packets(login, sizeof(login)));
    model.incoming(login, sizeof(login), 1000, labels);
    const uint8_t counter[] = {0x34, 0x12};
    assert(model.prepare(request, counter, 1001));
    assert(u16(request) == (0x11f | (4 << 9)) && u16(request + 2) == 0x1234 && u16(request + 10) == 0x8000);
    assert(request[8] == 1 && request[9] == 0 && request[12] == 1);
    make_reply(reply, 0x8001);
    assert(model.incoming(reply, 64, 1100, labels) && !labels.known);
    make_reply(reply, 0x8000);
    assert(model.incoming(reply, 64, 1100, labels) && labels.known && labels.branch == 2);
    assert(!model.prepare(request, counter, 1500));
    assert(model.prepare(request, counter, 2100));
    make_reply(reply, model.pending); reply[19] = 4;
    model.incoming(reply, 64, 2200, labels); assert(!labels.known);
    make_reply(reply, 20); assert(!model.incoming(reply, 64, 2250, labels));
    assert(model.refresh);
    // Job 23 (MON) has no soul crystals, so prepare() does not poll.
    uint8_t job[16]; make_packet(job, 0x061, 16); job[12] = 23;
    model.incoming(job, 16, 2300, labels); assert(model.job == 23 && !labels.known);
    assert(!model.prepare(request, counter, 2400));
    // Job 22 (RUN) has soul crystals (Spellblade/Lifebinder/Inquisitor), so prepare() polls with job=22.
    job[12] = 22;
    model.incoming(job, 16, 2450, labels); assert(model.job == 22 && !labels.known);
    assert(model.prepare(request, counter, 2500) && request[12] == 22);
    make_reply(reply, model.pending, 3, 22, 99);
    assert(model.incoming(reply, 64, 2550, labels) && labels.known && labels.job == 22 && labels.branch == 3);
    uint8_t logout[4]; make_packet(logout, 0x00d, 4);
    model.outgoing(logout, labels); assert(model.character == 0);
    model.incoming(login, sizeof(login), 3000, labels);
    assert(model.prepare(request, counter, 3000));
    assert(model.prepare(request, counter, 5000));
    assert(model.prepare(request, counter, 7000));
    assert(!model.prepare(request, counter, 9000) && model.timeouts == 3);
    model.incoming(login, sizeof(login), 10000, labels); model.next_request = 0xffff;
    assert(model.prepare(request, counter, 10000) && model.pending == 0xffff);
    make_reply(reply, 0xffff); model.incoming(reply, 64, 10100, labels);
    assert(!model.prepare(request, counter, 12000) && model.next_request == 0x10000);

    original_map_decode = &fake_map_decode; original_map_encode = &fake_map_encode;
    enabled.store(true);
    transport = {}; state = {};
    transport.incoming(login, sizeof(login), GetTickCount(), state);
    uint8_t stock[8], encoded[512]{};
    make_packet(stock, 0x015, 4); stock[2] = 0x34; stock[3] = 0x12;
    std::memset(stock + 4, 0, 4);
    assert(map_encode(stock, 8, encoded, 512, 11) == 24);
    assert(std::memcmp(stock, encoded, 4) == 0 && u16(encoded + 4) == (0x11f | (4 << 9)) && u16(encoded + 6) == 0x1234);
    assert(u32(encoded + 20) == 0);
    uint8_t decoded[512]; std::memset(decoded, 0x55, 28);
    make_packet(decoded + 28, 0x015, 4);
    make_reply(decoded + 32, transport.pending);
    make_packet(decoded + 96, 0x016, 4);
    fake_decode_result = 100;
    assert(map_decode(decoded, 512, 11, 12, nullptr, 13) == 36);
    assert(decoded[0] == 0x55 && decoded[27] == 0x55 && (u16(decoded + 28) & 0x1ff) == 0x015 && (u16(decoded + 32) & 0x1ff) == 0x016);
    assert(state.known && state.branch == 2);
    const uint32_t accepted = transport.accepted;
    make_reply(decoded + 28, 0x8001); decoded[28 + 13] = 2;
    make_packet(decoded + 92, 0x016, 4);
    decoded[94] = 0xff; decoded[95] = 0xff; // Valid counter; the declared size below is the malformed boundary.
    const uint16_t oversized = 0x016 | (100 << 9); std::memcpy(decoded + 92, &oversized, 2);
    fake_decode_result = 96;
    assert(map_decode(decoded, 512, 11, 12, nullptr, 13) == 96 && transport.accepted == accepted);
    enabled.store(false);
    make_reply(decoded + 28, 0x8002); fake_decode_result = 92;
    assert(map_decode(decoded, 512, 11, 12, nullptr, 13) == 28); // Shutdown's late-reply sink.
}

static void multi_job_checks() {
    // Verify all 22 SoulspireXI jobs x 3 branches against registry-generated labels.
    for (uint8_t j = 1; j <= 22; ++j) {
        assert(label_for(j, 0, false) == nullptr);
        assert(label_for(j, 4, false) == nullptr);
        for (uint8_t b = 1; b <= 3; ++b) {
            const char* abr = label_for(j, b, false);
            const char* full = label_for(j, b, true);
            assert(abr != nullptr && std::strlen(abr) == 3);
            assert(full != nullptr && std::strlen(full) >= 2);
            const char* fb_abr = generated_label_for(j, b, false);
            const char* fb_full = generated_label_for(j, b, true);
            assert(fb_abr != nullptr && std::strlen(fb_abr) == 3);
            assert(fb_full != nullptr && std::strlen(fb_full) >= 2);
        }
    }
    assert(label_for(0, 1, false) == nullptr);
    assert(label_for(23, 1, false) == nullptr);

    original_lookup = &fake_lookup;
    original_sprite = reinterpret_cast<uintptr_t>(&fake_sprite);
    native_text = &fake_text;
    selftest_alive = true;

    // Test Search rows for MNK, BLM, SAM, DNC, SCH, RUN against registry-generated labels.
    state = {};
    make_row(row_a, 301, marker | 1, 2); state.decoded(row_a);
    assert(state.row_branch(row_a) == 1 && std::strcmp(full_abi(row_a, 2), label_for(2, 1, true)) == 0);
    make_row(row_a, 306, marker | 2, 2); state.decoded(row_a);
    assert(state.row_branch(row_a) == 2 && std::strcmp(full_abi(row_a, 2), label_for(2, 2, true)) == 0);
    make_row(row_a, 307, marker | 3, 2); state.decoded(row_a);
    assert(state.row_branch(row_a) == 3 && std::strcmp(full_abi(row_a, 2), label_for(2, 3, true)) == 0);
    make_row(row_a, 302, marker | 3, 4); state.decoded(row_a);
    assert(state.row_branch(row_a) == 3 && std::strcmp(full_abi(row_a, 4), label_for(4, 3, true)) == 0);
    make_row(row_a, 308, marker | 1, 12); state.decoded(row_a);
    assert(state.row_branch(row_a) == 1 && std::strcmp(full_abi(row_a, 12), label_for(12, 1, true)) == 0);
    make_row(row_a, 309, marker | 2, 12); state.decoded(row_a);
    assert(state.row_branch(row_a) == 2 && std::strcmp(full_abi(row_a, 12), label_for(12, 2, true)) == 0);
    make_row(row_a, 310, marker | 3, 12); state.decoded(row_a);
    assert(state.row_branch(row_a) == 3 && std::strcmp(full_abi(row_a, 12), label_for(12, 3, true)) == 0);
    make_row(row_a, 303, marker | 3, 19); state.decoded(row_a);
    assert(state.row_branch(row_a) == 3 && std::strcmp(full_abi(row_a, 19), label_for(19, 3, true)) == 0);
    make_row(row_a, 304, marker | 2, 20); state.decoded(row_a);
    assert(state.row_branch(row_a) == 2 && std::strcmp(full_abi(row_a, 20), label_for(20, 2, true)) == 0);
    make_row(row_a, 305, marker | 1, 22); state.decoded(row_a);
    assert(state.row_branch(row_a) == 1 && std::strcmp(full_abi(row_a, 22), label_for(22, 1, true)) == 0);

    // Test item_label for RUN and SAM against registry-generated abbreviations.
    uint8_t run_event[8] = {1, 1, 22, 2, 100, 0, 0, 0};
    state.update(run_event, 8, GetTickCount());
    assert(std::strcmp(item_label(2, 22), label_for(22, 2, false)) == 0);
    assert(std::strcmp(item_label(2, 1), "WAR") == 0);
    uint8_t sam_event[8] = {1, 1, 12, 2, 100, 0, 0, 0};
    state.update(sam_event, 8, GetTickCount());
    assert(std::strcmp(item_label(2, 12), label_for(12, 2, false)) == 0);

    // Test menu2fon 3-glyph sprite rendering (24px wide: x0 = 0, 8, 16) and tile restoration.
    uint8_t mock_tile[0xE0]{}, mock_node[0x20]{}, mock_sprite[0x30]{};
    const int16_t war_corners[8] = {0, 24, 0, 24, -1, -1, 9, 9};
    const float war_uv[2] = {0.0f, 184.0f / 256.0f};
    std::memcpy(mock_tile + 0xC0, war_corners, sizeof(war_corners));
    std::memcpy(mock_tile + 0x64, war_uv, sizeof(war_uv));
    uint8_t* tile_ptr = mock_tile;
    std::memcpy(mock_node + 0x10, &tile_ptr, sizeof(tile_ptr));
    uint8_t* node_ptr = mock_node;
    std::memcpy(mock_sprite + 0x04, &node_ptr, sizeof(node_ptr));
    std::memcpy(mock_sprite + 0x08, &node_ptr, sizeof(node_ptr)); // CYyList tail
    std::memcpy(mock_sprite + 0x0C, &node_ptr, sizeof(node_ptr)); // CYyList cursor
    const uint32_t one_tile = 1;
    std::memcpy(mock_sprite + 0x14, &one_tile, sizeof(one_tile));
    uint8_t* sprite_entries[2] = {nullptr, mock_sprite};
    uint8_t** sprite_table = sprite_entries;
    void* sheet_obj = &sprite_table;
    pname_sheet_slot = &sheet_obj;

    sprite_calls = 0; text_calls = 0; recorded_sprite_count = 0;
#if CRYSTALJOBS_SEARCH_RENDER_MODE == 1
    reset_menu2fon_banks_for_test();
#endif
    make_row(row_a, 320, marker | 2, 1); state.decoded(row_a); // WAR branch 2 = BRZ
    assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
#if CRYSTALJOBS_SEARCH_RENDER_MODE == 0
    // Candidate A (Legacy 4f0fdb3): single native_text call, zero menu2fon sprite mutation.
    assert(sprite_calls == 0 && text_calls == 1 && recorded_sprite_count == 0);
    assert(last_text != nullptr && std::strcmp(last_text, label_for(1, 2, false)) == 0);
#elif CRYSTALJOBS_SEARCH_RENDER_MODE == 1
    assert(sprite_calls == 3 && text_calls == 0 && recorded_sprite_count == 3);
#else
    // Candidate C (Aligned native_text): 3 per-glyph native_text calls, zero menu2fon sprite mutation.
    assert(sprite_calls == 0 && text_calls == 3 && recorded_sprite_count == 0);
#endif
    // Shared WAR template tile must NEVER be mutated in-place.
    assert(std::memcmp(mock_tile + 0xC0, war_corners, sizeof(war_corners)) == 0);
    assert(std::memcmp(mock_tile + 0x64, war_uv, sizeof(war_uv)) == 0);

#if CRYSTALJOBS_SEARCH_RENDER_MODE == 2
    // Verify draw_aligned_native_text_label produces 3 calls across all 66 Souls with zero sprite touches.
    for (uint8_t j = 1; j <= 22; ++j) {
        for (uint8_t b = 1; b <= 3; ++b) {
            const char* abr = label_for(j, b, false);
            assert(abr != nullptr && std::strlen(abr) == 3);
            SpriteArgs sa{100, 50, 1.0f, 1.0f, 0x80808080u, 0, 0, 1};
            sprite_calls = 0; text_calls = 0;
            draw_aligned_native_text_label(abr, &sa);
            assert(sprite_calls == 0 && text_calls == 3);
        }
    }
#endif

#if CRYSTALJOBS_SEARCH_RENDER_MODE == 1
    // Set legacy pos*8 presentation for the 594-draw deferred regression check.
    SearchPresentationConfig legacy_pres = default_presentation_config();
    legacy_pres.tracking_px = 0;
    legacy_pres.offset_x_px = 0;
    legacy_pres.use_glyph_widths = false;
    publish_search_presentation(legacy_pres);

    // Deferred multi-frame, multi-row Search regression exceeding old 192-slot capacity:
    // Queue 3 consecutive frames x 66 Souls x 3 glyphs = 594 deferred draws, then verify
    // EVERY queued sprite* pointer from Frame 1..3 remains intact, immutable, and non-aliasing.
    uint8_t orig_sprite_copy[0x30], orig_node_copy[0x20], orig_tile_copy[0xE0];
    std::memcpy(orig_sprite_copy, mock_sprite, sizeof(orig_sprite_copy));
    std::memcpy(orig_node_copy, mock_node, sizeof(orig_node_copy));
    std::memcpy(orig_tile_copy, mock_tile, sizeof(orig_tile_copy));

    struct DeferredExpectation {
        const uint8_t* sprite;
        char letter;
        int pos;
    };
    static DeferredExpectation deferred_queue[3 * 66 * 3]{};
    size_t deferred_count = 0;
    recorded_sprite_count = 0;
    reset_menu2fon_banks_for_test();

    for (int frame = 0; frame < 3; ++frame) {
        for (uint8_t j = 1; j <= 22; ++j) {
            for (uint8_t b = 1; b <= 3; ++b) {
                sprite_calls = 0; text_calls = 0;
                const size_t rec_start = recorded_sprite_count;
                make_row(row_a, 400 + j * 4 + b, marker | b, j);
                state.decoded(row_a);
                assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
                assert(sprite_calls == 3 && text_calls == 0);
                assert(recorded_sprite_count == rec_start + 3);

                const char* abr = label_for(j, b, false);
                assert(abr != nullptr && std::strlen(abr) == 3);
                for (int gi = 0; gi < 3; ++gi) {
                    deferred_queue[deferred_count++] = {recorded_sprites[rec_start + gi], abr[gi], gi};
                }
            }
        }
    }
    assert(deferred_count == 3 * 66 * 3); // 594 > 192

    // Simulate deferred D3D8 consumption AFTER all 3 consecutive frames have been queued.
    for (size_t idx = 0; idx < deferred_count; ++idx) {
        const uint8_t* spr = deferred_queue[idx].sprite;
        assert(spr != nullptr && spr != mock_sprite);
        const uint8_t* node = *reinterpret_cast<uint8_t* const*>(spr + 0x04);
        assert(node != nullptr && node != mock_node);
        const uint8_t* tile = *reinterpret_cast<uint8_t* const*>(node + 0x10);
        assert(tile != nullptr && tile != mock_tile);

        const MenuGlyph g = menu_glyphs[deferred_queue[idx].letter - 'A'];
        const int16_t expected_x0 = static_cast<int16_t>(deferred_queue[idx].pos * 8);
        const int16_t expected_x1 = static_cast<int16_t>(expected_x0 + g.w);
        int16_t obs_corners[8]{};
        std::memcpy(obs_corners, tile + 0xC0, sizeof(obs_corners));
        assert(obs_corners[0] == expected_x0 && obs_corners[1] == expected_x1 &&
               obs_corners[2] == expected_x0 && obs_corners[3] == expected_x1 &&
               obs_corners[4] == -1 && obs_corners[5] == -1 &&
               obs_corners[6] == 9 && obs_corners[7] == 9);
        float obs_uv0[2]{};
        std::memcpy(obs_uv0, tile + 0x64, sizeof(obs_uv0));
        assert(obs_uv0[0] == static_cast<float>(g.u) * (1.0f / 256.0f));
        assert(obs_uv0[1] == static_cast<float>(g.v) * (1.0f / 256.0f));
    }
    // Consecutive frames must reuse the exact same immutable slot pointers (zero churn/overwrite).
    for (size_t i = 0; i < 66 * 3; ++i) {
        assert(deferred_queue[i].sprite == deferred_queue[i + 66 * 3].sprite);
        assert(deferred_queue[i].sprite == deferred_queue[i + 2 * 66 * 3].sprite);
    }
    // Verify shared template (*sheet)[1] remained 100% untouched across all 594 draws.
    assert(std::memcmp(mock_sprite, orig_sprite_copy, sizeof(orig_sprite_copy)) == 0);
    assert(std::memcmp(mock_node, orig_node_copy, sizeof(orig_node_copy)) == 0);
    assert(std::memcmp(mock_tile, orig_tile_copy, sizeof(orig_tile_copy)) == 0);

    // Flintlock (COR job 17, branch 1 = "FLT") reproduction + CYyList tail/cursor repointing
    // + simulated FFXI WAR TLVERTEX [0x50..0xBF] mutations across 25 scrolls/searches.
    reset_menu2fon_banks_for_test();
    recorded_sprite_count = 0;
    make_row(row_a, 650, marker | 1, 17); state.decoded(row_a); // COR branch 1 = FLT
    const char* flt_abr = label_for(17, 1, false);
    assert(flt_abr != nullptr && std::strcmp(flt_abr, "FLT") == 0);
    for (int scroll = 0; scroll < 25; ++scroll) {
        // Simulate FFXI 0x121110 updating screen Y and diffuse color in WAR's TLVERTEX buffer [0x50..0xBF]
        const float fake_y = 100.0f + static_cast<float>(scroll * 16);
        const uint32_t fake_color = 0x80808080u + static_cast<uint32_t>(scroll);
        std::memcpy(mock_tile + 0x54, &fake_y, sizeof(fake_y));
        std::memcpy(mock_tile + 0x60, &fake_color, sizeof(fake_color));
        sprite_calls = 0; text_calls = 0;
        const size_t rec_start = recorded_sprite_count;
        assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
        assert(sprite_calls == 3 && text_calls == 0); // Must NEVER exhaust banks or fall back to native_text!
        for (int gi = 0; gi < 3; ++gi) {
            const uint8_t* spr = recorded_sprites[rec_start + gi];
            const uint8_t* head = *reinterpret_cast<uint8_t* const*>(spr + 0x04);
            const uint8_t* tail = *reinterpret_cast<uint8_t* const*>(spr + 0x08);
            const uint8_t* cur  = *reinterpret_cast<uint8_t* const*>(spr + 0x0C);
            assert(head != mock_node && tail == head && cur == head);
            const uint8_t* tile = *reinterpret_cast<uint8_t* const*>(head + 0x10);
            const MenuGlyph g = menu_glyphs[flt_abr[gi] - 'A'];
            int16_t obs_corners[8]{};
            std::memcpy(obs_corners, tile + 0xC0, sizeof(obs_corners));
            assert(obs_corners[0] == static_cast<int16_t>(gi * 8));
            assert(obs_corners[1] == static_cast<int16_t>(gi * 8 + g.w));
            assert(obs_corners[2] == static_cast<int16_t>(gi * 8));
            assert(obs_corners[3] == static_cast<int16_t>(gi * 8 + g.w));
            assert(obs_corners[4] == -1 && obs_corners[5] == -1 && obs_corners[6] == 9 && obs_corners[7] == 9);
            assert(obs_corners[1] <= 23); // Fits flush before level digits at +23
        }
    }
    // Confirm only 1 bank was claimed across all 25 TLVERTEX mutations!
    size_t active_banks = 0;
    for (size_t bi = 0; bi < kMaxMenu2fonBanks; ++bi) if (g_menu2fon_banks[bi].active) ++active_banks;
    assert(active_banks == 1);
    std::memcpy(mock_tile, orig_tile_copy, sizeof(orig_tile_copy));

    // Safe capacity exhaustion test: exhaust all kMaxMenu2fonBanks distinct sheet reloads,
    // verify the (kMaxMenu2fonBanks + 1)-th reload falls back cleanly to native_text WITHOUT
    // mutating any previously queued GlyphSlot from generations 0..kMaxMenu2fonBanks-1.
    reset_menu2fon_banks_for_test();
    recorded_sprite_count = 0;
    const uint8_t* bank_sprites[kMaxMenu2fonBanks][3]{};
    make_row(row_a, 700, marker | 2, 1); state.decoded(row_a); // WAR branch 2 = BRZ
    const char* war_b2 = label_for(1, 2, false);
    assert(war_b2 != nullptr);
    for (size_t gen = 0; gen < kMaxMenu2fonBanks; ++gen) {
        mock_tile[0x08] = static_cast<uint8_t>(0x10u + gen);
        sprite_calls = 0; text_calls = 0;
        const size_t rec_start = recorded_sprite_count;
        assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
        assert(sprite_calls == 3 && text_calls == 0);
        for (int gi = 0; gi < 3; ++gi) {
            bank_sprites[gen][gi] = recorded_sprites[rec_start + gi];
        }
    }
    // Reload #9 exceeds safe bank capacity: must fall back to native_text, never recycle slots.
    mock_tile[0x08] = static_cast<uint8_t>(0x10u + kMaxMenu2fonBanks);
    sprite_calls = 0; text_calls = 0; last_text = nullptr;
    assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
    assert(sprite_calls == 0 && text_calls == 1 && last_text != nullptr && std::strcmp(last_text, war_b2) == 0);
    // Verify all previously queued sprites from generations 0..7 are still 100% intact.
    for (size_t gen = 0; gen < kMaxMenu2fonBanks; ++gen) {
        for (int gi = 0; gi < 3; ++gi) {
            const uint8_t* spr = bank_sprites[gen][gi];
            const uint8_t* node = *reinterpret_cast<uint8_t* const*>(spr + 0x04);
            const uint8_t* tile = *reinterpret_cast<uint8_t* const*>(node + 0x10);
            assert(tile[0x08] == static_cast<uint8_t>(0x10u + gen));
            const MenuGlyph g = menu_glyphs[war_b2[gi] - 'A'];
            float obs_uv0[2]{};
            std::memcpy(obs_uv0, tile + 0x64, sizeof(obs_uv0));
            assert(obs_uv0[0] == static_cast<float>(g.u) * (1.0f / 256.0f));
            assert(obs_uv0[1] == static_cast<float>(g.v) * (1.0f / 256.0f));
        }
    }
    // Returning to an already-cached generation (gen 0) still hits its immutable bank.
    mock_tile[0x08] = 0x10u;
    sprite_calls = 0; text_calls = 0;
    assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
    assert(sprite_calls == 3 && text_calls == 0);
    std::memcpy(mock_tile, orig_tile_copy, sizeof(orig_tile_copy));
    publish_search_presentation(default_presentation_config());
#endif // CRYSTALJOBS_SEARCH_RENDER_MODE == 1
    pname_sheet_slot = nullptr;

    selftest_alive = false;
}

static void equipment_persona_checks() {
    original_sprite_simple = reinterpret_cast<uintptr_t>(&fake_sprite_simple);
    native_text = &fake_persona_text;
    uint8_t mock_main_job = 13; // NIN
    main_job_slot = &mock_main_job;
    selftest_alive = true;
    simple_sprite_calls = 0;
    persona_text_calls = 0;
    last_persona_text = nullptr;
    last_persona_color = 0;

    // Active NIN (13) Soul branch 1 -> "Shinobi", preserving normal and level-sync colors.
    const uint32_t before_full = full_lookups.load();
    uint8_t ev[8] = {1, 1, 13, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 1 && simple_sprite_calls == 0);
    assert(std::strcmp(last_persona_text, "Shinobi") == 0 && last_persona_color == 0x80808080u);
    assert(full_lookups.load() == before_full + 1);

    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x802060a0u));
    assert(persona_text_calls == 2 && simple_sprite_calls == 0);
    assert(std::strcmp(last_persona_text, "Shinobi") == 0 && last_persona_color == 0x802060a0u);

    // Long idle: the short search/session heartbeat lease has expired, but the
    // local persona must keep its last confirmed Soul until explicit revocation.
    state.updated = GetTickCount() - lease_ms - 60000u;
    assert(!state.alive(GetTickCount(), 100, 13));
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 3 && simple_sprite_calls == 0);
    assert(std::strcmp(last_persona_text, "Shinobi") == 0);

    // Live Soul switch without closing the Equipment menu.
    ev[3] = 2; state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 4 && std::strcmp(last_persona_text, "Kagemusha") == 0);
    ev[3] = 3; state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 5 && std::strcmp(last_persona_text, "Fuin") == 0);

    // Other jobs (e.g., BLM Goetist, RDM Thornveil).
    mock_main_job = 4; ev[2] = 4; ev[3] = 1; state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 6 && std::strcmp(last_persona_text, "Goetist") == 0);
    mock_main_job = 5; ev[2] = 5; ev[3] = 1; state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 7 && std::strcmp(last_persona_text, "Thornveil") == 0);

    // Fallback to stock sprite on job mismatch, no Soul, explicit revoke, or disabled session.
    mock_main_job = 13; // state.job is still 5
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 7 && simple_sprite_calls == 1);

    ev[2] = 13; ev[3] = 0; state.update(ev, 8, GetTickCount()); // branch 0 = no Soul
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 7 && simple_sprite_calls == 2);

    ev[1] = 0; ev[3] = 1; state.update(ev, 8, GetTickCount()); // unknown
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 7 && simple_sprite_calls == 3);

    ev[1] = 1; ev[3] = 1; state.update(ev, 8, GetTickCount());
    selftest_alive = false; // explicitly disabled / zoning
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 7 && simple_sprite_calls == 4);

    // Verify 0x14868F signature relocation for relocated FFXiMain.dll (e.g. 0x04860000).
    uint8_t persona_sig[24];
    std::memcpy(persona_sig, signatures[16].bytes, 24);
    assert(signatures[16].rva == 0x14868F);
    relocate_signature(0x14868F, persona_sig, static_cast<uint32_t>(0x04860000u - 0x10000000u));
    assert(u32(persona_sig + 6) == 0x04860000u + 0x4867F2u);
    assert(u32(persona_sig + 17) == 0x04860000u + 0x4867F3u);

    main_job_slot = nullptr;
    native_text = &fake_text;
}

static CrystalJobsActionEntry make_action(uint8_t job, uint8_t branch, uint32_t kind, uint16_t id,
                                          const char* name, const char* desc,
                                          uint16_t icon_v1 = 0xFFFFu, uint16_t icon_v2 = 0xFFFFu) {
    CrystalJobsActionEntry e{};
    e.size = sizeof(e);
    e.job = job;
    e.branch = branch;
    e.kind = kind;
    e.action_id = id;
    e.icon_id = icon_v1;
    e.icon_id_v2 = icon_v2;
    if (name) copy_cstr_bounded(e.name, sizeof(e.name), name, sizeof(e.name));
    if (desc) copy_cstr_bounded(e.description, sizeof(e.description), desc, sizeof(e.description));
    return e;
}

static void action_catalog_checks() {
    original_spell_name = reinterpret_cast<uintptr_t>(&fake_spell_name_fn);
    original_spell_desc = reinterpret_cast<uintptr_t>(&fake_spell_desc_fn);
    original_ability_name_row = reinterpret_cast<uintptr_t>(&fake_abil_name_fn);
    original_ability_name_target = reinterpret_cast<uintptr_t>(&fake_abil_name_fn);
    original_ability_desc = reinterpret_cast<uintptr_t>(&fake_abil_desc_fn);
    original_action_icon = &fake_action_icon_fn;

    fake_spell_name_calls = fake_spell_desc_calls = fake_abil_name_calls = fake_abil_desc_calls = fake_icon_calls = 0;
    uint8_t mock_job = 13;
    main_job_slot = &mock_job;
    selftest_alive = true;

    // Atomic replace with multiple Souls mapping the SAME underlying action IDs differently.
    CrystalJobsActionEntry batch[5] = {
        make_action(13, 1, CRYSTALJOBS_ACTION_SPELL, 338, "Shadow Squadron: Ichi",
                    "Summon 2 offensive shadow clones.", 12, 1024),
        make_action(13, 1, CRYSTALJOBS_ACTION_SPELL, 339, "Shadow Squadron: Ni",
                    "Summon 3 offensive shadow clones."),
        make_action(13, 2, CRYSTALJOBS_ACTION_SPELL, 338, "Mirror Decoy: Ichi",
                    "Kagemusha decoy clone technique."),
        make_action(13, 1, CRYSTALJOBS_ACTION_WEAPONSKILL, 128, "Shadow Rend",
                    "Shinobi shadow-infused weapon skill.", 7, 1007),
        make_action(13, 1, CRYSTALJOBS_ACTION_ABILITY, 600, "Phantom Veil",
                    "Shinobi stealth stance."),
    };
    assert(CrystalJobsReplaceCatalog(batch, 5) == 0);

    // Reject duplicate keys without corrupting existing catalog.
    CrystalJobsActionEntry dup[2] = { batch[0], batch[0] };
    assert(CrystalJobsReplaceCatalog(dup, 2) == 1);
    assert(action_catalog.count() == 5);

    // Row width is adjustable without recompilation; invalid values fail safely.
    assert(CrystalJobsSetActionRowLimit(7) == 1);
    assert(CrystalJobsSetActionRowLimit(49) == 1);
    assert(CrystalJobsSetActionRowLimit(16) == 0);
    char compact[80]{};
    assert(compact_action_row_name("Utsusemi: Ichi", compact, sizeof(compact), 16));
    assert(std::strcmp(compact, "Utsusemi: Ichi") == 0);
    assert(compact_action_row_name("Shadow Squadron: Ichi", compact, sizeof(compact), 16));
    assert(std::strcmp(compact, "Shadow Sq.: Ichi") == 0);
    assert(compact_action_row_name("Extraordinarily Long Action Name", compact, sizeof(compact), 16));
    assert(std::strcmp(compact, "Extraordinari...") == 0);

    // Active NIN (13) branch 1 (Shinobi) via bridge state.
    uint8_t ev[8] = {1, 1, 13, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Shadow Sq.: Ichi") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_target_hook), 338), "Shadow Squadron: Ichi") == 0);
    assert(magic_icon_hook(99, 200) == reinterpret_cast<void*>(0x13579bdfu) && last_icon_v1 == 12 && last_icon_v2 == 1024);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_desc_hook), 338), "Summon 2 offensive shadow clones.") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 339), "Shadow Sq.: Ni") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_target_hook), 339), "Shadow Squadron: Ni") == 0);

    // Weapon skill (id < 512) and Job Ability (id >= 512) resolve independently.
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&ability_row_name_hook), 128), "Shadow Rend") == 0);
    assert(ability_icon_hook(5, 50) == reinterpret_cast<void*>(0x13579bdfu) && last_icon_v1 == 7 && last_icon_v2 == 1007);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&ability_desc_hook), 128), "Shinobi shadow-infused weapon skill.") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&ability_target_hook), 600), "Phantom Veil") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&ability_desc_hook), 600), "Shinobi stealth stance.") == 0);
    assert(fake_spell_name_calls == 0 && fake_spell_desc_calls == 0 && fake_abil_name_calls == 0 && fake_abil_desc_calls == 0);

    // Switch Soul to Kagemusha (branch 2): same spell ID 338 maps to a different name; 339 falls back to vanilla.
    ev[3] = 2; state.update(ev, 8, GetTickCount());
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Mirror De.: Ichi") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 339), "Utsusemi: Ni") == 0);
    assert(fake_spell_name_calls == 1);

    // Switch to Nightblade (branch 3, unmapped): falls back to vanilla for 338.
    ev[3] = 3; state.update(ev, 8, GetTickCount());
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Utsusemi: Ichi") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_desc_hook), 338), "Vanilla Utsusemi Ichi desc.") == 0);

    // Job change mismatch: live job is WAR (1) while state is NIN (13) -> stock fallback!
    ev[3] = 1; state.update(ev, 8, GetTickCount());
    mock_job = 1;
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Utsusemi: Ichi") == 0);
    mock_job = 13;

    // Explicit SetActiveSoul / ClearActiveSoul when bridge state is unknown.
    ev[1] = 0; ev[3] = 0; state.update(ev, 8, GetTickCount());
    assert(CrystalJobsSetActiveSoul(13, 1, 0) == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Shadow Sq.: Ichi") == 0);
    assert(CrystalJobsClearActiveSoul() == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Utsusemi: Ichi") == 0);

    // Full target labels always remain unshortened, even with narrower row budget.
    assert(CrystalJobsSetActionRowLimit(12) == 0);
    assert(CrystalJobsSetActiveSoul(13, 1, 0) == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Shadow: Ichi") != 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_target_hook), 338), "Shadow Squadron: Ichi") == 0);
    assert(CrystalJobsSetActionRowLimit(16) == 0);
    assert(CrystalJobsClearActiveSoul() == 0);

    // Verify relocations for all new action signatures (base 0x04860000).
    const uint32_t delta = static_cast<uint32_t>(0x04860000u - 0x10000000u);
    for (const auto& sig : signatures) {
        uint8_t buf[24];
        std::memcpy(buf, sig.bytes, 24);
        relocate_signature(sig.rva, buf, delta);
        if (sig.rva == 0x22E245) assert(u32(buf + 7) == 0x04860000u + 0x5793B0u);
        if (sig.rva == 0x22DED1) assert(u32(buf + 7) == 0x04860000u + 0x579638u);
        if (sig.rva == 0x225F5D) {
            assert(u32(buf + 7) == 0x04860000u + 0x5793B0u);
            const uint32_t expected21 = 0x04860000u + 0x6682FCu;
            assert(std::memcmp(buf + 21, &expected21, 3) == 0);
        }
        if (sig.rva == 0x225916) assert(u32(buf + 7) == 0x04860000u + 0x579638u);
        if (sig.rva == 0x22D510) assert(u32(buf + 18) == 0x04860000u + 0x457BD8u);
        if (sig.rva == 0x225120 || sig.rva == 0x2250A0) assert(u32(buf + 2) == 0x04860000u + 0x457BD8u);
    }

    assert(CrystalJobsClearCatalog() == 0 && action_catalog.count() == 0);
    main_job_slot = nullptr;
    selftest_alive = false;
}

static CrystalJobsVisibilityEntry make_vis(uint8_t job, uint8_t branch, uint32_t kind, uint16_t id,
                                           uint8_t min_lvl, uint8_t rule) {
    CrystalJobsVisibilityEntry e{};
    e.size = sizeof(e);
    e.job = job;
    e.branch = branch;
    e.kind = kind;
    e.action_id = id;
    e.min_effective_level = min_lvl;
    e.rule = rule;
    return e;
}

static uint32_t fake_spell_elig_calls = 0;
static uint8_t fake_spell_elig_return = 0;
static uint32_t fake_spell_elig_last_arg0 = 0;
static uint8_t __cdecl fake_spell_elig_fn(uint32_t a0, uint32_t, uint32_t, uint32_t, uint32_t,
                                          uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) noexcept {
    ++fake_spell_elig_calls;
    fake_spell_elig_last_arg0 = a0;
    return fake_spell_elig_return;
}

static __declspec(naked) uint8_t __cdecl menu_spell_elig_abi(const uint8_t*, uint32_t) {
    __asm {
        push esi
        mov esi, [esp + 8]
        mov eax, [esp + 12]
        push 0
        push 0
        push 0
        push 0
        push 0
        push 0
        push 0
        push 0
        push 0
        push eax
        call menu_spell_elig_hook
        add esp, 40
        pop esi
        ret
    }
}

static void visibility_checks() {
    original_can_show_spell = &fake_can_show_spell_fn;
    original_set_list_count = reinterpret_cast<uintptr_t>(&fake_set_list_count_fn);
    original_spell_elig = reinterpret_cast<uintptr_t>(&fake_spell_elig_fn);
    fake_can_show_calls = 0;
    fake_set_list_count_calls = 0;
    fake_spell_elig_calls = 0;
    fake_spell_elig_return = 0;
    fake_spell_elig_last_arg0 = 0;

    uint8_t mock_job = 13;
    uint8_t mock_lvl = 25;
    main_job_slot = &mock_job;
    main_lvl_slot = &mock_lvl;
    selftest_alive = true;

    CrystalJobsVisibilityEntry rules[6] = {
        make_vis(13, 1, CRYSTALJOBS_ACTION_SPELL, 338, 10, CRYSTALJOBS_VIS_RULE_UNLOCK),
        make_vis(13, 1, CRYSTALJOBS_ACTION_SPELL, 339, 37, CRYSTALJOBS_VIS_RULE_UNLOCK),
        make_vis(13, 2, CRYSTALJOBS_ACTION_SPELL, 339, 1,  CRYSTALJOBS_VIS_RULE_HIDDEN),
        make_vis(13, 1, CRYSTALJOBS_ACTION_WEAPONSKILL, 128, 37, CRYSTALJOBS_VIS_RULE_UNLOCK),
        make_vis(13, 1, CRYSTALJOBS_ACTION_ABILITY, 600, 1, CRYSTALJOBS_VIS_RULE_HIDDEN),
        make_vis(21, 3, CRYSTALJOBS_ACTION_SPELL, 160, 10, CRYSTALJOBS_VIS_RULE_UNLOCK),
    };
    assert(CrystalJobsReplaceVisibility(rules, 6) == 0);
    // Reject duplicates without corrupting active policy.
    CrystalJobsVisibilityEntry dup[2] = { rules[0], rules[0] };
    assert(CrystalJobsReplaceVisibility(dup, 2) == 1);
    assert(visibility_catalog.count() == 6);

    uint8_t spell338[4]{}, spell339[4]{}, spell340[4]{};
    const uint16_t id338 = 338, id339 = 339, id340 = 340;
    std::memcpy(spell338, &id338, 2);
    std::memcpy(spell339, &id339, 2);
    std::memcpy(spell340, &id340, 2);

    // Shinobi (NIN 13 / branch 1): Lv 10..36 -> Ichi (338) visible, Ni (339) hidden.
    uint8_t ev[8] = {1, 1, 13, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());
    mock_lvl = 10;
    assert(magic_list_filter_hook(spell338) == 1);
    assert(magic_list_filter_hook(spell339) == 0);
    mock_lvl = 36;
    assert(magic_list_filter_hook(spell338) == 1);
    assert(magic_list_filter_hook(spell339) == 0);
    // Unmanaged spell 340 always falls through to vanilla check.
    assert(magic_list_filter_hook(spell340) == 1 && fake_can_show_calls == 1);

    // Lv 37 -> Both Ichi and Ni visible.
    mock_lvl = 37;
    assert(magic_list_filter_hook(spell338) == 1);
    assert(magic_list_filter_hook(spell339) == 1);

    // Level synced down to 36 -> Ni hidden again.
    mock_lvl = 36;
    assert(magic_list_filter_hook(spell339) == 0);

    // Switch Soul to Kagemusha (branch 2): 339 explicitly hidden even at Lv 75; 338 unmanaged -> vanilla.
    mock_lvl = 75;
    ev[3] = 2; state.update(ev, 8, GetTickCount());
    assert(magic_list_filter_hook(spell339) == 0);
    assert(magic_list_filter_hook(spell338) == 1 && fake_can_show_calls == 2);

    // Switch Soul to Nightblade (branch 3): unmanaged -> vanilla.
    ev[3] = 3; state.update(ev, 8, GetTickCount());
    assert(magic_list_filter_hook(spell339) == 1 && fake_can_show_calls == 3);

    // A missing learned-spell bitmap bit must only be ignored for the active
    // Soul's unlocked spell; the generic resolver and server remain intact.
    uint8_t spell160[4]{};
    const uint16_t id160 = 160;
    std::memcpy(spell160, &id160, 2);
    mock_job = 21; mock_lvl = 9; ev[2] = 21; ev[3] = 3;
    state.update(ev, 8, GetTickCount());
    assert(soul_knows_missing_spell(spell160) == 0);
    // Magic Menu pre-cast validator (0x22E64D -> 0x1021A0) must reject below unlock,
    // allow at GEO10..30 even when vanilla 114.DAT returns 0, and fall through for unmanaged spells.
    fake_spell_elig_return = 0;
    assert(menu_spell_elig_abi(spell160, 0x11223344u) == 0 && fake_spell_elig_calls == 0);
    mock_lvl = 10;
    assert(soul_knows_missing_spell(spell160) == 1);
    assert(soul_knows_missing_spell(spell339) == 0);
    assert(menu_spell_elig_abi(spell160, 0x11223344u) == 1 && fake_spell_elig_calls == 0);
    mock_lvl = 30;
    assert(soul_knows_missing_spell(spell160) == 1);
    assert(menu_spell_elig_abi(spell160, 0x11223344u) == 1 && fake_spell_elig_calls == 0);
    assert(menu_spell_elig_abi(spell339, 0x11223344u) == 0 && fake_spell_elig_calls == 1 && fake_spell_elig_last_arg0 == 0x11223344u);
    fake_spell_elig_return = 1;
    assert(menu_spell_elig_abi(spell339, 0x55667788u) == 1 && fake_spell_elig_calls == 2 && fake_spell_elig_last_arg0 == 0x55667788u);
    mock_lvl = 35;
    assert(soul_knows_missing_spell(spell160) == 1);
    assert(menu_spell_elig_abi(spell160, 0x11223344u) == 1 && fake_spell_elig_calls == 2);
    mock_job = 13;
    assert(soul_knows_missing_spell(spell160) == 0);
    fake_spell_elig_return = 0;
    assert(menu_spell_elig_abi(spell160, 0x99AABBCCu) == 0 && fake_spell_elig_calls == 3 && fake_spell_elig_last_arg0 == 0x99AABBCCu);
    mock_job = 13; ev[2] = 13; ev[3] = 1;
    state.update(ev, 8, GetTickCount());

    // Ability & Weapon Skill list compaction + selection remapping ABI test.
    ev[3] = 1; state.update(ev, 8, GetTickCount());
    mock_lvl = 25; // WS 128 locked (<37), JA 600 hidden; WS 129 & JA 601 unmanaged -> kept.
    uint8_t fake_list_obj[0x1780]{};
    const int32_t raw_total = 4;
    std::memcpy(fake_list_obj + 0x1760, &raw_total, 4);
    const uint16_t raw_ids[4] = {128, 129, 600, 601};
    std::memcpy(fake_list_obj + 0x160, raw_ids, sizeof(raw_ids));
    uint8_t* list_ptr = fake_list_obj;
    ability_list_slot = &list_ptr;

    uint32_t rows[16]{};
    // Initial rows: [0]=raw 0 (WS 128, hide), [1]=raw 1 (WS 129, keep), [2]=raw 2 (JA 600, hide), [3]=raw 3 (JA 601, keep)
    rows[0] = 0; rows[1] = 0xAA;
    rows[2] = 1; rows[3] = 0xBB;
    rows[4] = 2; rows[5] = 0xCC;
    rows[6] = 3; rows[7] = 0xDD;
    uint8_t fake_menu[0x60]{};
    uint32_t* rows_ptr = rows;
    const int32_t cap = 8;
    std::memcpy(fake_menu + 0x20, &rows_ptr, sizeof(rows_ptr));
    std::memcpy(fake_menu + 0x44, &cap, sizeof(cap));

    // Selecting row 3 (JA 601) must compact to index 1 with count=2 and zero blank rows.
    const int32_t remapped_sel = ability_filter_abi(fake_menu, 4, 3);
    assert(remapped_sel == 1);
    assert(fake_set_list_count_calls == 1 && last_set_list_count == 2 && last_set_list_flags == 0);
    assert(rows[0] == 1 && rows[1] == 0xBB && rows[2] == 3 && rows[3] == 0xDD);

    // Selecting a hidden row (row 0 = WS 128) must reset selection to -1.
    rows[0] = 0; rows[2] = 1; rows[4] = 2; rows[6] = 3;
    const int32_t hidden_sel = ability_filter_abi(fake_menu, 4, 0);
    assert(hidden_sel == -1 && last_set_list_count == 2);

    // Level 37 unlocks WS 128 -> count=3 (128, 129, 601), only JA 600 hidden.
    mock_lvl = 37;
    rows[0] = 0; rows[2] = 1; rows[4] = 2; rows[6] = 3;
    assert(ability_filter_abi(fake_menu, 4, 3) == 2 && last_set_list_count == 3);
    assert(rows[0] == 0 && rows[2] == 1 && rows[4] == 3);

    // Zero-row list stays zero cleanly.
    assert(ability_filter_abi(fake_menu, 0, -1) == -1 && last_set_list_count == 0);

    // Verify 0x22CDE0 signature relocation.
    const uint32_t delta = static_cast<uint32_t>(0x04860000u - 0x10000000u);
    for (const auto& sig : signatures) {
        if (sig.rva == 0x22CDE0) {
            uint8_t buf[24];
            std::memcpy(buf, sig.bytes, 24);
            relocate_signature(sig.rva, buf, delta);
            assert(u32(buf + 1) == 0x04860000u + 0x4867F0u);
        }
    }

    assert(CrystalJobsClearVisibility() == 0 && visibility_catalog.count() == 0);
    ability_list_slot = nullptr;
    main_lvl_slot = nullptr;
    main_job_slot = nullptr;
    selftest_alive = false;
}

static CrystalJobsWeaponRule make_weapon_rule(uint8_t job, uint8_t branch, uint8_t min_lvl,
                                              uint32_t main_mask, uint32_t sub_mask,
                                              uint16_t main_item_id = 0, uint16_t sub_item_id = 0) {
    CrystalJobsWeaponRule r{};
    r.size = sizeof(r);
    r.job = job;
    r.branch = branch;
    r.min_effective_level = min_lvl;
    r.mode = CRYSTALJOBS_WEAPON_MODE_DUAL_1H;
    r.main_skill_mask = main_mask;
    r.sub_skill_mask = sub_mask;
    r.main_item_id = main_item_id;
    r.sub_item_id = sub_item_id;
    return r;
}

static uint16_t fake_inv_item_id = 0;
static uint32_t fake_inv_expected_container = 0;
static uint32_t fake_inv_expected_slot = 0;
static uint8_t fake_inv_entry[4]{};
static const uint8_t* __cdecl fake_get_inv_item_fn(uint32_t container, uint32_t slot) noexcept {
    if (fake_inv_item_id == 0) return nullptr;
    assert(container == fake_inv_expected_container && slot == fake_inv_expected_slot);
    std::memcpy(fake_inv_entry, &fake_inv_item_id, 2);
    return fake_inv_entry;
}

static uint8_t fake_main_item_res[0x20]{};
static const uint8_t* __fastcall fake_get_item_res_fn(void* mgr, void*, uint32_t item_id) noexcept {
    assert(mgr == reinterpret_cast<void*>(0x12340000u));
    if (item_id == 0 || item_id != u16(fake_main_item_res)) return nullptr;
    return fake_main_item_res;
}

static uint32_t sub_weapon_resume_result = 0;
static __declspec(naked) void fake_sub_weapon_allow_resume() {
    __asm {
        mov sub_weapon_resume_result, 1
        ret
    }
}
static __declspec(naked) void fake_sub_weapon_deny_resume() {
    __asm {
        cmp dword ptr [esp], 0x8b
        jne bad_push
        add esp, 4
        mov sub_weapon_resume_result, 2
        ret
    bad_push:
        add esp, 4
        mov sub_weapon_resume_result, 0xBAD0008B
        ret
    }
}

// Mirrors EquipMenu::TryEquipItem (0x133D56) exact register & stack frame ABI:
// esi = sub CItemResource*, [esp+0x10] = main_slot, [esp+0x18] = main_container.
static __declspec(naked) uint32_t __cdecl sub_weapon_abi(const uint8_t*, uint32_t, uint32_t) {
    __asm {
        push ebp
        push ebx
        push esi
        push edi
        sub esp, 0x1C
        mov dword ptr [esp + 0x00], 0x55667788
        mov eax, [esp + 0x34]
        mov [esp + 0x0C], eax
        mov eax, [esp + 0x38]
        mov [esp + 0x14], eax
        mov esi, [esp + 0x30]
        mov ebx, 0x11223344
        mov ecx, 0x22334455
        mov edx, 0x33445566
        mov edi, 0x44556677
        mov ebp, 0x55667788
        call soul_sub_weapon_hook
        xor eax, eax
        cmp dword ptr [esp + 0x00], 0x55667788
        jne corrupted
        cmp ebx, 0x11223344
        jne corrupted
        cmp ecx, 0x22334455
        jne corrupted
        cmp edx, 0x33445566
        jne corrupted
        cmp edi, 0x44556677
        jne corrupted
        cmp ebp, 0x55667788
        jne corrupted
        cmp esi, [esp + 0x30]
        jne corrupted
        mov eax, sub_weapon_resume_result
    corrupted:
        add esp, 0x1C
        pop edi
        pop esi
        pop ebx
        pop ebp
        ret
    }
}

static void make_item_res(uint8_t (&buf)[0x20], uint16_t item_id, uint16_t skill) {
    std::memset(buf, 0, sizeof(buf));
    std::memcpy(buf + 0x00, &item_id, 2);
    std::memcpy(buf + 0x10, &skill, 2);
}

static void weapon_rule_checks() {
    original_get_inv_item = &fake_get_inv_item_fn;
    original_get_item_res = &fake_get_item_res_fn;
    void* fake_mgr = reinterpret_cast<void*>(0x12340000u);
    item_res_mgr_slot = &fake_mgr;
    soul_sub_weapon_allow_resume = reinterpret_cast<uintptr_t>(&fake_sub_weapon_allow_resume);
    soul_sub_weapon_deny_resume = reinterpret_cast<uintptr_t>(&fake_sub_weapon_deny_resume);

    uint8_t mock_job = 10; // BRD
    uint8_t mock_lvl = 10;
    main_job_slot = &mock_job;
    main_lvl_slot = &mock_lvl;
    selftest_alive = true;

    constexpr uint32_t kDaggerBit = 1u << 2;
    constexpr uint32_t kSwordBit  = 1u << 3;
    constexpr uint32_t kClubBit   = 1u << 11;

    // Validate malformed rule rejection without corrupting catalog.
    CrystalJobsWeaponRule bad = make_weapon_rule(10, 1, 10, kDaggerBit | kSwordBit, kDaggerBit | kSwordBit);
    bad.size = 4;
    assert(CrystalJobsReplaceWeaponRules(&bad, 1) == 1);
    bad = make_weapon_rule(10, 1, 10, kDaggerBit, 0);
    assert(CrystalJobsReplaceWeaponRules(&bad, 1) == 1);
    bad = make_weapon_rule(10, 1, 10, kDaggerBit, kSwordBit);
    bad.mode = 99;
    assert(CrystalJobsReplaceWeaponRules(&bad, 1) == 1);

    // Load BRD Adventurer (job=10, branch=1, minLv=10): Dagger/Sword <-> Dagger/Sword.
    CrystalJobsWeaponRule rules[1] = {
        make_weapon_rule(10, 1, 10, kDaggerBit | kSwordBit, kDaggerBit | kSwordBit),
    };
    assert(CrystalJobsReplaceWeaponRules(rules, 1) == 0);
    assert(weapon_rule_catalog.count() == 1);

    uint8_t sub_dagger[0x20]{}, sub_sword[0x20]{}, sub_club[0x20]{};
    make_item_res(sub_dagger, 16448, 2); // Wind Knife +1 (Dagger)
    make_item_res(sub_sword,  16535, 3); // Onion Sword (Sword)
    make_item_res(sub_club,   17024, 11); // Bronze Hammer (Club)

    // Active BRD10 Adventurer (job=10, branch=1).
    uint8_t ev[8] = {1, 1, 10, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());

    // Main = Onion Sword (3) in inventory slot 5 -> Sub = Wind Knife +1 (2) ALLOWED.
    fake_inv_expected_container = 0; fake_inv_expected_slot = 5;
    fake_inv_item_id = 16535;
    make_item_res(fake_main_item_res, 16535, 3);
    assert(sub_weapon_abi(sub_dagger, 5, 0) == 1);
    // Main = Onion Sword (3) -> Sub = Onion Sword (3) ALLOWED.
    assert(sub_weapon_abi(sub_sword, 5, 0) == 1);
    // Main = Onion Sword (3) -> Sub = Bronze Hammer (Club, 11) DENIED.
    assert(sub_weapon_abi(sub_club, 5, 0) == 2);

    // Main = Wind Knife +1 (Dagger, 2) in Wardrobe 1 (container=8, slot=12) -> Sub = Sword ALLOWED.
    fake_inv_expected_container = 8; fake_inv_expected_slot = 12;
    fake_inv_item_id = 16448;
    make_item_res(fake_main_item_res, 16448, 2);
    assert(sub_weapon_abi(sub_sword, 12, 8) == 1);

    // Empty main-hand (slot=0 or 0xFF) -> DENIED.
    assert(sub_weapon_abi(sub_sword, 0, 0) == 2);
    assert(sub_weapon_abi(sub_sword, 0xFFu, 0) == 2);

    // Main = Club (11) -> Sub = Dagger DENIED.
    fake_inv_expected_container = 0; fake_inv_expected_slot = 3;
    fake_inv_item_id = 17024;
    make_item_res(fake_main_item_res, 17024, 11);
    assert(sub_weapon_abi(sub_dagger, 3, 0) == 2);

    // Level synced below 10 (BRD9 Adventurer) -> DENIED.
    fake_inv_expected_container = 0; fake_inv_expected_slot = 5;
    fake_inv_item_id = 16535;
    make_item_res(fake_main_item_res, 16535, 3);
    mock_lvl = 9;
    assert(sub_weapon_abi(sub_dagger, 5, 0) == 2);
    mock_lvl = 10;

    // Switch Soul to BRD Musician (branch=2, no rules) -> DENIED (vanilla).
    ev[3] = 2; state.update(ev, 8, GetTickCount());
    assert(sub_weapon_abi(sub_dagger, 5, 0) == 2);

    // Unsocketed BRD (branch=0) -> DENIED.
    ev[3] = 0; state.update(ev, 8, GetTickCount());
    assert(sub_weapon_abi(sub_dagger, 5, 0) == 2);

    // Verify 0xEB5D0 signature relocation under ASLR delta.
    const uint32_t delta = static_cast<uint32_t>(0x04860000u - 0x10000000u);
    bool checked_eb5d0 = false;
    for (const auto& sig : signatures) {
        if (sig.rva == 0xEB5D0) {
            uint8_t buf[24];
            std::memcpy(buf, sig.bytes, 24);
            relocate_signature(sig.rva, buf, delta);
            assert(u32(buf + 2) == 0x04860000u + 0x4E0F48u);
            checked_eb5d0 = true;
        }
    }
    assert(checked_eb5d0);

    // Verify unused bit mask check does not trip compiler warnings.
    (void)kClubBit;

    assert(CrystalJobsClearWeaponRules() == 0 && weapon_rule_catalog.count() == 0);
    item_res_mgr_slot = nullptr;
    original_get_inv_item = nullptr;
    original_get_item_res = nullptr;
    soul_sub_weapon_allow_resume = 0;
    soul_sub_weapon_deny_resume = 0;
    main_lvl_slot = nullptr;
    main_job_slot = nullptr;
    selftest_alive = false;
}

static void runtime_identity_and_spacing_checks() {
    // 1. Load real generated plugins/ashita4/data/soul-identities.json and verify all 66 Souls.
    static char raw_buf[kMaxIdentityFileBytes + 1]{};
    size_t raw_len = 0;
    assert(read_bounded_file_w(L"..\\..\\plugins\\ashita4\\data\\soul-identities.json", raw_buf, kMaxIdentityFileBytes, raw_len));
    static RuntimeIdentityTable t1{};
    assert(parse_runtime_identity_json(raw_buf, raw_len, t1));
    assert(t1.active && t1.soul_count == 66 && t1.schema_version == 1);
    assert(std::strcmp(t1.registry_hash, "f8abc95e3c88cce7") == 0);
    publish_runtime_identity_snapshot(t1);
    assert(std::strcmp(label_for(4, 1, false), "GOE") == 0);
    assert(std::strcmp(label_for(4, 1, true), "Goetist") == 0);
    assert(std::strcmp(label_for(13, 3, true), "Fuin") == 0);

    CrystalJobsIdentityDiagnostics idiag{};
    assert(CrystalJobsGetIdentityDiagnostics(&idiag, sizeof(idiag)) == 0);
    assert(idiag.source == 1 && idiag.soul_count == 66 && std::strcmp(idiag.active_registry_hash, "f8abc95e3c88cce7") == 0);

    // 2. Same binary, second valid 66-Soul fixture renaming BLM branch 1 (AST -> GOE) without DLL rebuild!
    static RuntimeIdentityTable t2 = t1;
    std::snprintf(t2.entries[4][1].abbr, sizeof(t2.entries[4][1].abbr), "GOE");
    const uint64_t t2_fnv = detail::compute_table_fnv1a64(t2);
    static char renamed_json[kMaxIdentityFileBytes]{};
    int pos = std::snprintf(renamed_json, sizeof(renamed_json),
        "{\"schemaVersion\":1,\"registryVersion\":\"test-rename\",\"registryHash\":\"1122334455667788\","
        "\"integrityFnv1a64\":\"%016llx\",\"soulCount\":66,\"souls\":[",
        static_cast<unsigned long long>(t2_fnv));
    assert(pos > 0);
    bool first = true;
    for (uint8_t j = 1; j <= 22; ++j) {
        for (uint8_t b = 1; b <= 3; ++b) {
            const auto& e = t2.entries[j][b];
            const int n = std::snprintf(renamed_json + pos, sizeof(renamed_json) - static_cast<size_t>(pos),
                "%s{\"jobId\":%u,\"branch\":%u,\"name\":\"%s\",\"abbr\":\"%s\"}",
                first ? "" : ",", static_cast<unsigned>(j), static_cast<unsigned>(b), e.name, e.abbr);
            assert(n > 0);
            pos += n;
            first = false;
        }
    }
    pos += std::snprintf(renamed_json + pos, sizeof(renamed_json) - static_cast<size_t>(pos), "]}");
    static RuntimeIdentityTable parsed_t2{};
    assert(parse_runtime_identity_json(renamed_json, static_cast<size_t>(pos), parsed_t2));
    publish_runtime_identity_snapshot(parsed_t2);
    assert(std::strcmp(label_for(4, 1, false), "GOE") == 0);
    assert(CrystalJobsGetIdentityDiagnostics(&idiag, sizeof(idiag)) == 0);
    assert(idiag.source == 1 && std::strcmp(idiag.active_registry_hash, "1122334455667788") == 0);

    // 3. Reject corrupted / tampered / bad-schema / duplicate / overlong identity payloads & verify safe fallback.
    static RuntimeIdentityTable bad{};
    assert(!parse_runtime_identity_json("", 0, bad) && bad.status == IDENTITY_STATUS_FILE_MISSING);
    const char* bad_schema = "{\"schemaVersion\":99,\"registryHash\":\"0e3278fac7296cb3\",\"integrityFnv1a64\":\"0000000000000000\",\"soulCount\":66,\"souls\":[]}";
    assert(!parse_runtime_identity_json(bad_schema, std::strlen(bad_schema), bad) && bad.status == IDENTITY_STATUS_BAD_SCHEMA);
    // Tamper 1 byte in renamed_json integrity hash
    renamed_json[std::strstr(renamed_json, "integrityFnv1a64") - renamed_json + 19] ^= 1;
    assert(!parse_runtime_identity_json(renamed_json, static_cast<size_t>(pos), bad) && bad.status == IDENTITY_STATUS_BAD_INTEGRITY);

    clear_runtime_identity_snapshot(IDENTITY_STATUS_BAD_INTEGRITY, "tampered fixture");
    assert(std::strcmp(label_for(4, 1, false), "AST") == 0); // Safe compiled fallback
    assert(CrystalJobsGetIdentityDiagnostics(&idiag, sizeof(idiag)) == 0);
    assert(idiag.source == 0 && idiag.status == IDENTITY_STATUS_BAD_INTEGRITY && idiag.warning[0] != '\0');

    // 4. Presentation config parsing, bounds validation, and glyph spacing algorithm.
    SearchPresentationConfig pres{};
    size_t pres_len = 0;
    assert(read_bounded_file_w(L"..\\..\\plugins\\ashita4\\data\\crystaljobs-presentation.json", raw_buf, kMaxPresentationFileBytes, pres_len));
    assert(parse_presentation_config_json(raw_buf, pres_len, pres));
    assert(pres.from_file && pres.tracking_px == -1 && pres.offset_x_px == 1 && !pres.use_glyph_widths);

    const char* bad_pres = "{\"schemaVersion\":1,\"searchBadge\":{\"trackingPx\":-9,\"offsetXPx\":0,\"useGlyphWidths\":true}}";
    SearchPresentationConfig bad_p{};
    assert(!parse_presentation_config_json(bad_pres, std::strlen(bad_pres), bad_p));
    assert(!bad_p.from_file && bad_p.tracking_px == -1);

#if CRYSTALJOBS_SEARCH_RENDER_MODE == 1
    // AST widths: A=7, S=8, T=7. Fixed 7px pitch (tracking=-1, offsetX=1, useGlyphWidths=false) -> x0 = {1, 8, 15}, right edge = 22 <= 24.
    const uint8_t ast_w[3] = {menu_glyphs['A' - 'A'].w, menu_glyphs['S' - 'A'].w, menu_glyphs['T' - 'A'].w};
    int16_t ast_x[3]{};
    compute_search_glyph_positions(ast_w, pres, ast_x);
    assert(ast_x[0] == 1 && ast_x[1] == 8 && ast_x[2] == 15 && (ast_x[2] + ast_w[2]) == 22);

    // Legacy spacing mode without recompiling: tracking=0, offsetX=0, useGlyphWidths=false -> {0, 8, 16}.
    SearchPresentationConfig leg = default_presentation_config();
    leg.tracking_px = 0; leg.offset_x_px = 0; leg.use_glyph_widths = false;
    compute_search_glyph_positions(ast_w, leg, ast_x);
    assert(ast_x[0] == 0 && ast_x[1] == 8 && ast_x[2] == 16);

    // Max-width WWW (8,8,8) with max tracking=+2 and max offsetX=+3 still stays <= 24px (badge column).
    const uint8_t www_w[3] = {8, 8, 8};
    SearchPresentationConfig wide = default_presentation_config();
    wide.tracking_px = 2; wide.offset_x_px = 3; wide.use_glyph_widths = true;
    int16_t www_x[3]{};
    compute_search_glyph_positions(www_w, wide, www_x);
    assert(www_x[0] >= kMinGlyphX0 && (www_x[2] + www_w[2]) <= 24);
#endif
    publish_runtime_identity_snapshot(t1);
    publish_search_presentation(pres);
}

int main() {
    runtime_identity_and_spacing_checks();
    uint8_t event[8] = {1, 1, 1, 2, 100, 0, 0, 0};
    state.update(event, 8, 0xffffff00);
    assert(state.alive(0xffffff10, 100, 1));
    assert(state.alive(0x500, 100, 1));
    assert(!state.alive(0x1000, 100, 1));
    assert(!state.alive(0xffffff10, 101, 1));
    assert(!state.alive(0xffffff10, 100, 2));
    make_row(row_a, 101, marker | 1); state.decoded(row_a);
    make_row(row_b, 102, marker | 3); state.decoded(row_b);
    assert(u32(row_a + 20) == 0 && state.row_branch(row_a) == 1 && state.row_branch(row_b) == 3);
    make_row(row_b, 102, 0); state.decoded(row_b);
    assert(state.row_branch(row_b) == 3 && state.row_branch(row_a) == 1);
    make_row(row_b, 102, 0, 2); state.decoded(row_b);
    assert(state.row_branch(row_b) == 0 && state.row_branch(row_a) == 1);
    make_row(row_b, 102, marker | 3, 1); state.decoded(row_b);
    assert(state.row_branch(row_b) == 3);
    make_row(row_b, 102, marker | 0, 1); state.decoded(row_b);
    assert(state.row_branch(row_b) == 0 && state.row_branch(row_a) == 1);
    make_row(row_b, 102, marker | 1, 23); state.decoded(row_b); assert(state.row_branch(row_b) == 0);
    make_row(row_b, 102, marker | 2, 1, 0x4000); state.decoded(row_b); assert(state.row_branch(row_b) == 0);
    make_row(row_b, 102, marker | 4); state.decoded(row_b); assert(state.row_branch(row_b) == 0 && u32(row_b + 20) == 0);
    make_row(row_b, 102, 0x12345678); state.decoded(row_b); assert(u32(row_b + 20) == 0x12345678);
    original_lookup = &fake_lookup;
    original_sprite = reinterpret_cast<uintptr_t>(&fake_sprite);
    native_text = &fake_text;
    selftest_alive = true;
    assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
    assert(sprite_abi(reinterpret_cast<void*>(&master_sprite_hook), row_a));
#if CRYSTALJOBS_SEARCH_RENDER_MODE == 2
    assert(text_calls == 6 && sprite_calls == 0 && std::strcmp(last_text, "R") == 0);
#else
    assert(text_calls == 2 && sprite_calls == 0 && std::strcmp(last_text, "CDR") == 0);
#endif
    assert(std::strcmp(full_abi(row_a, 1), "Commander") == 0);
    assert(std::strcmp(full_abi(row_a, 2), "Monk") == 0);
    selftest_alive = false;
    assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
    assert(sprite_abi(reinterpret_cast<void*>(&master_sprite_hook), row_a));
    assert(sprite_calls == 2);
    assert(std::strcmp(full_abi(row_a, 1), "Warrior") == 0);
    event[0] = 2; state.update(event, 8, 0); assert(state.character == 0 && state.row_branch(row_a) == 0);
    assert(!supported(nullptr));
    auto* memory = static_cast<uint8_t*>(VirtualAlloc(nullptr, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
    assert(memory != nullptr);
    const uint8_t original[5] = {0xe8, 1, 2, 3, 4}; std::memcpy(memory, original, 5);
    Patch patch{0, reinterpret_cast<void*>(&normal_sprite_hook)};
    assert(patch.install(memory) && std::memcmp(memory, original, 5) != 0);
    assert(memory[0] == 0xe8 && memory[5] == 0);
    assert(patch.restore() && std::memcmp(memory, original, 5) == 0);
    assert(patch.install(memory)); memory[1] ^= 1;
    assert(!patch.restore());
    memory[58] = 0xaa; memory[64] = 0xbb;
    std::memcpy(memory + 59, original, 5);
    Patch boundary{59, reinterpret_cast<void*>(&normal_sprite_hook)};
    assert(boundary.install(memory) && memory[58] == 0xaa && memory[59] == 0xe8 && memory[64] == 0xbb);
    assert(boundary.restore() && std::memcmp(memory + 59, original, 5) == 0);
    std::memcpy(memory + 62, original, 5);
    Patch crossing{62, reinterpret_cast<void*>(&normal_sprite_hook)};
    assert(!crossing.install(memory) && std::memcmp(memory + 62, original, 5) == 0);
    uint8_t wrong[5]; std::memcpy(wrong, original, 5); wrong[1] ^= 0x40;
    assert(!Patch::write(memory + 62, wrong, original));
    std::memcpy(memory, original, 5);
    assert(!Patch::write(memory, wrong, original) && std::memcmp(memory, original, 5) == 0);
    uint8_t expected[24]; std::memset(expected, 0x55, 24);
    std::memcpy(memory, expected, 24); memory[0] = 0xe9;
    const uint32_t target = static_cast<uint32_t>(reinterpret_cast<uintptr_t>(&fake_text) - reinterpret_cast<uintptr_t>(memory + 5));
    std::memcpy(memory + 1, &target, 4); std::memset(memory + 5, 0x90, 5);
    assert(host_detour(memory, expected, 24, 10, GetModuleHandleW(nullptr)));
    std::memset(memory + 5, 0xcc, 5); // Microsoft Detours 0xCC padding
    assert(host_detour(memory, expected, 24, 10, GetModuleHandleW(nullptr)));
    assert(!host_detour(memory, expected, 24, 10, nullptr));
    memory[10] ^= 1; assert(!host_detour(memory, expected, 24, 10, GetModuleHandleW(nullptr)));
    const uint8_t missing_bit_instruction[5] = {0xbd, 0xfe, 0xff, 0xff, 0xff};
    std::memcpy(memory, missing_bit_instruction, 5);
    PrologueDetour missing_bit_test{0, reinterpret_cast<void*>(&missing_spell_bit_hook), 0xBDu};
    assert(missing_bit_test.install(memory) && memory[0] == 0xe9 && missing_bit_test.site == memory &&
           std::memcmp(missing_bit_test.site, missing_bit_test.installed, 5) == 0);
    assert(missing_bit_test.restore() && std::memcmp(memory, missing_bit_instruction, 5) == 0);
    const uint8_t sub_weapon_instruction[5] = {0x68, 0x8b, 0x00, 0x00, 0x00};
    std::memcpy(memory, sub_weapon_instruction, 5);
    PrologueDetour sub_weapon_test{0, reinterpret_cast<void*>(&soul_sub_weapon_hook), 0x68u};
    assert(sub_weapon_test.install(memory) && memory[0] == 0xe9 && sub_weapon_test.site == memory &&
           std::memcmp(sub_weapon_test.site, sub_weapon_test.installed, 5) == 0);
    assert(sub_weapon_test.restore() && std::memcmp(memory, sub_weapon_instruction, 5) == 0);

    // Verify per-hook diagnostics distinguish never-installed vs post-init overwritten hooks.
    {
        std::memcpy(memory + 0x100, sub_weapon_instruction, 5);
        memory[0x105] = 0xAA; memory[0x106] = 0xBB; memory[0x107] = 0xCC;
        const uintptr_t saved_rva = soul_sub_weapon_detour.rva;
        soul_sub_weapon_detour.rva = 0x100;
        assert(soul_sub_weapon_detour.install(memory));
        hook_diag = {};
        hook_diag.init_stage = CRYSTALJOBS_INIT_OK;
        CrystalJobsHookDiagnostics diag{};
        assert(CrystalJobsGetHookDiagnostics(&diag, sizeof(diag)) == 0);
        assert(diag.total_hooks == 1 && diag.expected_hooks == 24);
        assert((diag.installed_mask & (1u << 23)) != 0 && (diag.site_set_mask & (1u << 23)) != 0);
        // Simulate external overwrite of hook #24 in memory.
        memory[0x100] = 0x90;
        assert(CrystalJobsGetHookDiagnostics(&diag, sizeof(diag)) == 0);
        assert(diag.total_hooks == 0 && (diag.installed_mask & (1u << 23)) == 0 && (diag.site_set_mask & (1u << 23)) != 0);
        // Restore cleanly (force expected bytes back before restore so restore succeeds).
        std::memcpy(memory + 0x100, soul_sub_weapon_detour.installed, 5);
        assert(soul_sub_weapon_detour.restore());
        soul_sub_weapon_detour.rva = saved_rva;
        hook_diag = {};
    }
    VirtualFree(memory, 0, MEM_RELEASE);
    // Verify signature relocation when FFXiMain.dll is relocated (e.g. 0x04860000 under Ashita v4).
    uint8_t reloc_sig[24];
    std::memcpy(reloc_sig, signatures[2].bytes, 24);
    relocate_signature(0x13C302, reloc_sig, static_cast<uint32_t>(0x04860000u - 0x10000000u));
    assert(u32(reloc_sig + 11) == 0x04860000u + 0x370DF8u);
    transport_checks();
    multi_job_checks();
    equipment_persona_checks();
    action_catalog_checks();
    visibility_checks();
    weapon_rule_checks();
    enabled.store(false); state = {};
    original_decode = &fake_search_decode;
    make_row(row_b, 200, marker | 3);
    assert(decode_row(nullptr, row_b, 1) == row_b + 72 && u32(row_b + 20) == 0 && state.row_branch(row_b) == 0);
    make_row(row_b, 200, 0x12345678);
    decode_row(nullptr, row_b, 1); assert(u32(row_b + 20) == 0x12345678);
    const HMODULE dll = LoadLibraryA("crystaljobs.dll");
    assert(dll != nullptr);
    const auto initialize = reinterpret_cast<uint32_t(__stdcall*)()>(GetProcAddress(dll, "CrystalJobsInitialize"));
    const auto shutdown = reinterpret_cast<uint32_t(__stdcall*)()>(GetProcAddress(dll, "CrystalJobsShutdown"));
    const auto status = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsStatus*, uint32_t)>(GetProcAddress(dll, "CrystalJobsGetStatus"));
    const auto get_iface = reinterpret_cast<double(__stdcall*)()>(GetProcAddress(dll, "expGetInterfaceVersion"));
    const auto create_plugin = reinterpret_cast<void*(__stdcall*)(const char*)>(GetProcAddress(dll, "expCreatePlugin"));
    const auto destroy_plugin = reinterpret_cast<void(__stdcall*)(void*)>(GetProcAddress(dll, "expDestroyPlugin"));
    assert(initialize != nullptr && shutdown != nullptr && status != nullptr && GetProcAddress(dll, "CrystalJobsSetState") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsReplaceCatalog") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsUpsertAction") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsSetActionRowLimit") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsClearCatalog") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsSetActiveSoul") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsClearActiveSoul") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsReplaceVisibility") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsClearVisibility") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsReplaceWeaponRules") != nullptr);
    assert(GetProcAddress(dll, "CrystalJobsClearWeaponRules") != nullptr);
    const auto get_wpn_st = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsWeaponStatus*, uint32_t)>(GetProcAddress(dll, "CrystalJobsGetWeaponStatus"));
    assert(get_wpn_st != nullptr);
    CrystalJobsWeaponStatus wpn_st{};
    assert(get_wpn_st(&wpn_st, sizeof(wpn_st)) == 0 && wpn_st.version == 1 && wpn_st.expected_hooks == 24 && wpn_st.total_hooks == 0);
    const auto get_diag = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsHookDiagnostics*, uint32_t)>(GetProcAddress(dll, "CrystalJobsGetHookDiagnostics"));
    assert(get_diag != nullptr);
    CrystalJobsHookDiagnostics dll_diag{};
    const auto get_id_diag = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsIdentityDiagnostics*, uint32_t)>(GetProcAddress(dll, "CrystalJobsGetIdentityDiagnostics"));
    assert(get_id_diag != nullptr);
    CrystalJobsIdentityDiagnostics dll_id_diag{};
    assert(get_id_diag(&dll_id_diag, sizeof(dll_id_diag)) == 0 && dll_id_diag.version == 1 && dll_id_diag.soul_count == 66);
    assert(get_diag(&dll_diag, sizeof(dll_diag)) == 0 && dll_diag.size == 60 && dll_diag.version == 1 &&
           dll_diag.expected_hooks == 24 && dll_diag.total_hooks == 0 && dll_diag.init_stage == CRYSTALJOBS_INIT_NOT_RUN);
    const auto get_vis_st = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsVisibilityStatus*, uint32_t)>(GetProcAddress(dll, "CrystalJobsGetVisibilityStatus"));
    assert(get_vis_st != nullptr);
    CrystalJobsVisibilityStatus vis_st{};
    assert(get_vis_st(&vis_st, sizeof(vis_st)) == 0 && vis_st.version == 1 && vis_st.expected_hooks == 24 && vis_st.total_hooks == 0);
    const auto get_action_st = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsActionStatus*, uint32_t)>(GetProcAddress(dll, "CrystalJobsGetActionStatus"));
    assert(get_action_st != nullptr);
    CrystalJobsActionStatus act_st{};
    assert(get_action_st(&act_st, sizeof(act_st)) == 0 && act_st.version == 1 && act_st.expected_hooks == 24 && act_st.total_hooks == 0);
    assert(get_iface != nullptr && create_plugin != nullptr && destroy_plugin != nullptr);
    assert(get_iface() == 4.30);
    void* plugin = create_plugin("");
    assert(plugin != nullptr);
    destroy_plugin(plugin);
    CrystalJobsStatus snapshot{};
    assert(status(&snapshot, sizeof(snapshot)) == 0 && snapshot.version == 1 && snapshot.hooks == 0);
    assert(initialize() == 1 && status(&snapshot, sizeof(snapshot)) == 0 && snapshot.hooks == 0 && snapshot.last_error == 1);
    assert(get_diag(&dll_diag, sizeof(dll_diag)) == 0 && dll_diag.init_stage == CRYSTALJOBS_INIT_BAD_PE);
    assert(shutdown() == 0);
    FreeLibrary(dll);
    std::puts("PASS: all 7 SoulspireXI soul jobs (WAR/MNK/BLM/SAM/DNC/SCH/RUN), mixed rows/privacy/revoke/lease, x86 adapter ABI, patch restore/conflict, native codec preservation/correlation/bounds, timeout/nonce exhaustion, late-reply sink.");
}
