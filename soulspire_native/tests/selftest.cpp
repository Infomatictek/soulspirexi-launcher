#define SOULSPIRE_NATIVE_SELFTEST
#include "../soulspire_native.cpp"
#include <cassert>

static uint8_t row_a[72]{}, row_b[72]{};
static uint32_t sprite_calls, simple_sprite_calls, text_calls, persona_text_calls, last_persona_color;
static const char* last_text;
static char last_text_buf[32]{};
static const char* last_persona_text;

static int __cdecl fake_text(int x, int y, const char* text, uint32_t color, float sx, float sy, int center) {
#if SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 2
    assert(text != nullptr && color == 0x80808080u && center == 0);
    if (std::strlen(text) == 1) {
        assert(x >= 100 && x <= 116 && y == 51 && sx == 0.72f && sy == 0.78f);
    } else {
        assert(x == 100 && y == 50 && sx == 0.75f && sy == 0.75f);
    }
#else
    assert(x == 100 && y == 50 && color == 0x80808080u && sx == 0.75f && sy == 0.75f && center == 0);
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

static const uint8_t* recorded_sprites[2048]{};
static size_t recorded_sprite_count = 0;
static int __fastcall fake_sprite(void* self, void*, int x, int y, float sx, float sy, uint32_t color, int center, int first, int count) {
    assert(x == 100 && y == 50 && sx == 1.0f && sy == 1.0f && color == 0x80808080u && center == 0 && first == 0 && count == 0);
    if (recorded_sprite_count < 2048) {
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

static __declspec(naked) int32_t ability_filter_abi(void*, int32_t, int32_t) {
    __asm {
        push ebp
        push ebx
        push esi
        push edi
        sub esp, 0x24
        mov ecx, [esp + 0x38]
        mov eax, [esp + 0x3c]
        mov edx, [esp + 0x40]
        mov [esp + 0x1c], edx
        mov ebx, 11223344h
        mov esi, 22334455h
        mov edi, 33445566h
        mov ebp, 44556677h
        push 0
        push eax
        call ability_list_filter_hook
        mov eax, [esp + 0x1c]
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

    // Job 23 (MON) has no soul crystals; job 22 (RUN) does.
    uint8_t job[16]; make_packet(job, 0x061, 16); job[12] = 23;
    model.incoming(job, 16, 2300, labels); assert(model.job == 23 && !labels.known);
    assert(!model.prepare(request, counter, 2400));
    job[12] = 22;
    model.incoming(job, 16, 2450, labels); assert(model.job == 22 && !labels.known);
    assert(model.prepare(request, counter, 2500) && request[12] == 22);
    make_reply(reply, model.pending, 3, 22, 99);
    assert(model.incoming(reply, 64, 2550, labels) && labels.known && labels.job == 22 && labels.branch == 3);
    uint8_t logout[4]; make_packet(logout, 0x00d, 4);
    model.outgoing(logout, labels); assert(model.character == 0);

    // Verify timeout saturation and recovery on job change (0x061) and zone reset (0x00A).
    model.incoming(login, sizeof(login), 3000, labels);
    assert(model.prepare(request, counter, 3000));
    assert(model.prepare(request, counter, 5000));
    assert(model.prepare(request, counter, 7000));
    assert(!model.prepare(request, counter, 9000) && model.timeouts == 3);
    job[12] = 13;
    model.incoming(job, 16, 9500, labels);
    assert(model.timeouts == 0 && model.prepare(request, counter, 9600));

    // Verify next_request saturation within one zone and clean reclaim on zone change (0x00A).
    model.incoming(login, sizeof(login), 10000, labels);
    model.next_request = 0xffff;
    assert(model.prepare(request, counter, 10000) && model.pending == 0xffff);
    make_reply(reply, 0xffff);
    model.incoming(reply, 64, 10100, labels);
    assert(!model.prepare(request, counter, 12000) && model.next_request == 0x10000);
    model.incoming(login, sizeof(login), 13000, labels);
    assert(model.next_request == 0x8000 && model.prepare(request, counter, 13001));

    original_map_decode = &fake_map_decode;
    original_map_encode = &fake_map_encode;
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
    decoded[94] = 0xff; decoded[95] = 0xff;
    const uint16_t oversized = 0x016 | (100 << 9); std::memcpy(decoded + 92, &oversized, 2);
    fake_decode_result = 96;
    assert(map_decode(decoded, 512, 11, 12, nullptr, 13) == 96 && transport.accepted == accepted);
    enabled.store(false);
    make_reply(decoded + 28, 0x8002); fake_decode_result = 92;
    assert(map_decode(decoded, 512, 11, 12, nullptr, 13) == 28);
}

static void multi_job_checks() {
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
    make_row(row_a, 303, marker | 3, 19); state.decoded(row_a);
    assert(state.row_branch(row_a) == 3 && std::strcmp(full_abi(row_a, 19), label_for(19, 3, true)) == 0);
    make_row(row_a, 304, marker | 2, 20); state.decoded(row_a);
    assert(state.row_branch(row_a) == 2 && std::strcmp(full_abi(row_a, 20), label_for(20, 2, true)) == 0);
    make_row(row_a, 305, marker | 1, 22); state.decoded(row_a);
    assert(state.row_branch(row_a) == 1 && std::strcmp(full_abi(row_a, 22), label_for(22, 1, true)) == 0);

    uint8_t run_event[8] = {1, 1, 22, 2, 100, 0, 0, 0};
    state.update(run_event, 8, GetTickCount());
    assert(std::strcmp(item_label(2, 22), label_for(22, 2, false)) == 0);
    assert(std::strcmp(item_label(2, 1), "WAR") == 0);

    uint8_t mock_tile[0xE0]{}, mock_node[0x20]{}, mock_sprite[0x30]{};
    const int16_t war_corners[8] = {0, 24, 0, 24, -1, -1, 9, 9};
    const float war_uv[2] = {0.0f, 184.0f / 256.0f};
    std::memcpy(mock_tile + 0xC0, war_corners, sizeof(war_corners));
    std::memcpy(mock_tile + 0x64, war_uv, sizeof(war_uv));
    uint8_t* tile_ptr = mock_tile;
    std::memcpy(mock_node + 0x10, &tile_ptr, sizeof(tile_ptr));
    uint8_t* node_ptr = mock_node;
    std::memcpy(mock_sprite + 0x04, &node_ptr, sizeof(node_ptr));
    std::memcpy(mock_sprite + 0x08, &node_ptr, sizeof(node_ptr));
    std::memcpy(mock_sprite + 0x0C, &node_ptr, sizeof(node_ptr));
    const uint32_t one_tile = 1;
    std::memcpy(mock_sprite + 0x14, &one_tile, sizeof(one_tile));
    uint8_t* sprite_entries[2] = {nullptr, mock_sprite};
    uint8_t** sprite_table = sprite_entries;
    void* sheet_obj = &sprite_table;
    pname_sheet_slot = &sheet_obj;

    sprite_calls = 0; text_calls = 0; recorded_sprite_count = 0;
#if SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 1
    reset_menu2fon_banks_for_test();
#endif
    make_row(row_a, 320, marker | 2, 1); state.decoded(row_a);
    assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
#if SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 0
    assert(sprite_calls == 0 && text_calls == 1 && recorded_sprite_count == 0);
#elif SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 1
    assert(sprite_calls == 3 && text_calls == 0 && recorded_sprite_count == 3);
#else
    assert(sprite_calls == 0 && text_calls == 3 && recorded_sprite_count == 0);
#endif
    assert(std::memcmp(mock_tile + 0xC0, war_corners, sizeof(war_corners)) == 0);

#if SOULSPIRE_NATIVE_SEARCH_RENDER_MODE == 1
    SearchPresentationConfig legacy_pres = default_presentation_config();
    legacy_pres.tracking_px = 0;
    legacy_pres.offset_x_px = 0;
    legacy_pres.use_glyph_widths = false;
    publish_search_presentation(legacy_pres);

    uint8_t orig_sprite_copy[0x30], orig_node_copy[0x20], orig_tile_copy[0xE0];
    std::memcpy(orig_sprite_copy, mock_sprite, sizeof(orig_sprite_copy));
    std::memcpy(orig_node_copy, mock_node, sizeof(orig_node_copy));
    std::memcpy(orig_tile_copy, mock_tile, sizeof(orig_tile_copy));

    struct DeferredExpectation { const uint8_t* sprite; char letter; int pos; };
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
                const char* abr = label_for(j, b, false);
                for (int gi = 0; gi < 3; ++gi) {
                    deferred_queue[deferred_count++] = {recorded_sprites[rec_start + gi], abr[gi], gi};
                }
            }
        }
    }
    assert(deferred_count == 3 * 66 * 3);
    for (size_t i = 0; i < 66 * 3; ++i) {
        assert(deferred_queue[i].sprite == deferred_queue[i + 66 * 3].sprite);
        assert(deferred_queue[i].sprite == deferred_queue[i + 2 * 66 * 3].sprite);
    }
    assert(std::memcmp(mock_sprite, orig_sprite_copy, sizeof(orig_sprite_copy)) == 0);
    assert(std::memcmp(mock_node, orig_node_copy, sizeof(orig_node_copy)) == 0);
    assert(std::memcmp(mock_tile, orig_tile_copy, sizeof(orig_tile_copy)) == 0);

    // Exhaust all 16 distinct sheet reloads (kMaxMenu2fonBanks == 16) and verify 17th falls back safely.
    reset_menu2fon_banks_for_test();
    recorded_sprite_count = 0;
    const uint8_t* bank_sprites[kMaxMenu2fonBanks][3]{};
    make_row(row_a, 700, marker | 2, 1); state.decoded(row_a);
    const char* war_b2 = label_for(1, 2, false);
    for (size_t gen = 0; gen < kMaxMenu2fonBanks; ++gen) {
        mock_tile[0x08] = static_cast<uint8_t>(0x10u + gen);
        sprite_calls = 0; text_calls = 0;
        const size_t rec_start = recorded_sprite_count;
        assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
        assert(sprite_calls == 3 && text_calls == 0);
        for (int gi = 0; gi < 3; ++gi) bank_sprites[gen][gi] = recorded_sprites[rec_start + gi];
    }
    assert(g_menu2fon_banks_used.load() == kMaxMenu2fonBanks);
    mock_tile[0x08] = static_cast<uint8_t>(0x10u + kMaxMenu2fonBanks);
    sprite_calls = 0; text_calls = 0; last_text = nullptr;
    assert(sprite_abi(reinterpret_cast<void*>(&normal_sprite_hook), row_a));
    assert(sprite_calls == 0 && text_calls == 1 && last_text != nullptr && std::strcmp(last_text, war_b2) == 0);
    assert(g_menu2fon_fallback_draws.load() == 1);
    for (size_t gen = 0; gen < kMaxMenu2fonBanks; ++gen) {
        for (int gi = 0; gi < 3; ++gi) {
            const uint8_t* spr = bank_sprites[gen][gi];
            const uint8_t* node = *reinterpret_cast<uint8_t* const*>(spr + 0x04);
            const uint8_t* tile = *reinterpret_cast<uint8_t* const*>(node + 0x10);
            assert(tile[0x08] == static_cast<uint8_t>(0x10u + gen));
        }
    }
    std::memcpy(mock_tile, orig_tile_copy, sizeof(orig_tile_copy));
    publish_search_presentation(default_presentation_config());
#endif
    pname_sheet_slot = nullptr;
    selftest_alive = false;
}

static void equipment_persona_checks() {
    original_sprite_simple = reinterpret_cast<uintptr_t>(&fake_sprite_simple);
    native_text = &fake_persona_text;
    uint8_t mock_main_job = 13;
    main_job_slot = &mock_main_job;
    selftest_alive = true;
    simple_sprite_calls = 0; persona_text_calls = 0;
    last_persona_text = nullptr; last_persona_color = 0;

    uint8_t ev[8] = {1, 1, 13, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 1 && simple_sprite_calls == 0);
    assert(std::strcmp(last_persona_text, "Shinobi") == 0);

    // Long idle preserves local persona label until explicit revocation.
    state.updated = GetTickCount() - lease_ms - 60000u;
    assert(!state.alive(GetTickCount(), 100, 13));
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(persona_text_calls == 2 && std::strcmp(last_persona_text, "Shinobi") == 0);

    ev[3] = 2; state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(std::strcmp(last_persona_text, "Kagemusha") == 0);

    ev[3] = 0; state.update(ev, 8, GetTickCount());
    assert(persona_abi(reinterpret_cast<void*>(&persona_job_hook), 0x80808080u));
    assert(simple_sprite_calls == 1);

    main_job_slot = nullptr;
    native_text = &fake_text;
    selftest_alive = false;
}

static SoulspireNativeActionEntry make_action(uint8_t job, uint8_t branch, uint32_t kind, uint16_t id,
                                              const char* name, const char* desc,
                                              uint16_t icon_v1 = 0xFFFFu, uint16_t icon_v2 = 0xFFFFu) {
    SoulspireNativeActionEntry e{};
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

    SoulspireNativeActionEntry batch[5] = {
        make_action(13, 1, SOULSPIRE_NATIVE_ACTION_SPELL, 338, "Shadow Squadron: Ichi", "Summon 2 offensive shadow clones.", 12, 1024),
        make_action(13, 1, SOULSPIRE_NATIVE_ACTION_SPELL, 339, "Shadow Squadron: Ni", "Summon 3 offensive shadow clones."),
        make_action(13, 2, SOULSPIRE_NATIVE_ACTION_SPELL, 338, "Mirror Decoy: Ichi", "Kagemusha decoy clone technique."),
        make_action(13, 1, SOULSPIRE_NATIVE_ACTION_WEAPONSKILL, 128, "Shadow Rend", "Shinobi shadow-infused weapon skill.", 7, 1007),
        make_action(13, 1, SOULSPIRE_NATIVE_ACTION_ABILITY, 600, "Phantom Veil", "Shinobi stealth stance."),
    };
    assert(SoulspireNativeReplaceCatalog(batch, 5) == 0);
    SoulspireNativeActionEntry dup[2] = { batch[0], batch[0] };
    assert(SoulspireNativeReplaceCatalog(dup, 2) == 1);
    assert(action_catalog.count() == 5);

    uint8_t ev[8] = {1, 1, 13, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Shadow Sq.: Ichi") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_target_hook), 338), "Shadow Squadron: Ichi") == 0);
    assert(magic_icon_hook(99, 200) == reinterpret_cast<void*>(0x13579bdfu) && last_icon_v1 == 12 && last_icon_v2 == 1024);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_desc_hook), 338), "Summon 2 offensive shadow clones.") == 0);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&ability_row_name_hook), 128), "Shadow Rend") == 0);
    assert(ability_icon_hook(5, 50) == reinterpret_cast<void*>(0x13579bdfu) && last_icon_v1 == 7 && last_icon_v2 == 1007);

    // Regression fix check: unsocketing a Soul (bridge confirms known=1, branch=0) must NOT fall back to stale soul_override!
    assert(SoulspireNativeSetActiveSoul(13, 1, 0) == 0);
    ev[1] = 1; ev[3] = 0; state.update(ev, 8, GetTickCount());
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Utsusemi: Ichi") == 0);

    // Module-level isolation check: disabling actions module suppresses overrides while preserving catalog.
    ev[1] = 1; ev[3] = 1; state.update(ev, 8, GetTickCount());
    SearchPresentationConfig no_actions = default_presentation_config();
    no_actions.enabled_modules_mask &= ~(1u << SOULSPIRE_NATIVE_MOD_ACTIONS);
    publish_search_presentation(no_actions);
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Utsusemi: Ichi") == 0);
    publish_search_presentation(default_presentation_config());
    assert(std::strcmp(action_str_abi(reinterpret_cast<void*>(&magic_row_name_hook), 338), "Shadow Sq.: Ichi") == 0);

    assert(SoulspireNativeClearActiveSoul() == 0);
    assert(SoulspireNativeClearCatalog() == 0);
    main_job_slot = nullptr;
    selftest_alive = false;
}

static SoulspireNativeVisibilityEntry make_vis(uint8_t job, uint8_t branch, uint32_t kind, uint16_t id,
                                               uint8_t min_lvl, uint8_t rule) {
    SoulspireNativeVisibilityEntry e{};
    e.size = sizeof(e);
    e.job = job; e.branch = branch; e.kind = kind;
    e.action_id = id; e.min_effective_level = min_lvl; e.rule = rule;
    return e;
}

static uint32_t fake_spell_elig_calls = 0;
static uint8_t fake_spell_elig_return = 0;
static uint8_t __cdecl fake_spell_elig_fn(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t,
                                          uint32_t, uint32_t, uint32_t, uint32_t, uint32_t) noexcept {
    ++fake_spell_elig_calls;
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
    fake_can_show_calls = fake_set_list_count_calls = fake_spell_elig_calls = 0;

    uint8_t mock_job = 13, mock_lvl = 25;
    main_job_slot = &mock_job; main_lvl_slot = &mock_lvl;
    selftest_alive = true;

    SoulspireNativeVisibilityEntry rules[4] = {
        make_vis(13, 1, SOULSPIRE_NATIVE_ACTION_SPELL, 338, 10, SOULSPIRE_NATIVE_VIS_RULE_UNLOCK),
        make_vis(13, 1, SOULSPIRE_NATIVE_ACTION_SPELL, 339, 37, SOULSPIRE_NATIVE_VIS_RULE_UNLOCK),
        make_vis(13, 1, SOULSPIRE_NATIVE_ACTION_WEAPONSKILL, 128, 37, SOULSPIRE_NATIVE_VIS_RULE_UNLOCK),
        make_vis(13, 1, SOULSPIRE_NATIVE_ACTION_ABILITY, 600, 1, SOULSPIRE_NATIVE_VIS_RULE_HIDDEN),
    };
    assert(SoulspireNativeReplaceVisibility(rules, 4) == 0);

    uint8_t spell338[4]{}, spell339[4]{};
    const uint16_t id338 = 338, id339 = 339;
    std::memcpy(spell338, &id338, 2);
    std::memcpy(spell339, &id339, 2);

    uint8_t ev[8] = {1, 1, 13, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());
    mock_lvl = 10;
    assert(magic_list_filter_hook(spell338) == 1);
    assert(magic_list_filter_hook(spell339) == 0);
    assert(soul_knows_missing_spell(spell338) == 1 && soul_knows_missing_spell(spell339) == 0);
    assert(menu_spell_elig_abi(spell338, 0) == 1 && menu_spell_elig_abi(spell339, 0) == 0);
    mock_lvl = 37;
    assert(magic_list_filter_hook(spell339) == 1);

    uint8_t fake_list_obj[0x1780]{};
    const int32_t raw_total = 4;
    std::memcpy(fake_list_obj + 0x1760, &raw_total, 4);
    const uint16_t raw_ids[4] = {128, 129, 600, 601};
    std::memcpy(fake_list_obj + 0x160, raw_ids, sizeof(raw_ids));
    uint8_t* list_ptr = fake_list_obj;
    ability_list_slot = &list_ptr;

    uint32_t rows[16]{};
    rows[0] = 0; rows[1] = 0xAA; rows[2] = 1; rows[3] = 0xBB;
    rows[4] = 2; rows[5] = 0xCC; rows[6] = 3; rows[7] = 0xDD;
    uint8_t fake_menu[0x60]{};
    uint32_t* rows_ptr = rows;
    const int32_t cap = 8;
    std::memcpy(fake_menu + 0x20, &rows_ptr, sizeof(rows_ptr));
    std::memcpy(fake_menu + 0x44, &cap, sizeof(cap));

    mock_lvl = 25;
    assert(ability_filter_abi(fake_menu, 4, 3) == 1 && last_set_list_count == 2);
    assert(rows[0] == 1 && rows[2] == 3);

    assert(SoulspireNativeClearVisibility() == 0);
    ability_list_slot = nullptr; main_lvl_slot = nullptr; main_job_slot = nullptr;
    selftest_alive = false;
}

static SoulspireNativeWeaponRule make_weapon_rule(uint8_t job, uint8_t branch, uint8_t min_lvl,
                                                  uint8_t mode, uint32_t main_mask, uint32_t sub_mask,
                                                  uint16_t main_item_id = 0, uint16_t sub_item_id = 0) {
    SoulspireNativeWeaponRule r{};
    r.size = sizeof(r);
    r.job = job; r.branch = branch; r.min_effective_level = min_lvl; r.mode = mode;
    r.main_skill_mask = main_mask; r.sub_skill_mask = sub_mask;
    r.main_item_id = main_item_id; r.sub_item_id = sub_item_id;
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
static uint8_t fake_sub_item_res[0x20]{};
static const uint8_t* __fastcall fake_get_item_res_fn(void* mgr, void*, uint32_t item_id) noexcept {
    assert(mgr == reinterpret_cast<void*>(0x12340000u));
    if (item_id != 0 && item_id == u16(fake_main_item_res)) return fake_main_item_res;
    if (item_id != 0 && item_id == u16(fake_sub_item_res)) return fake_sub_item_res;
    return nullptr;
}

static uint8_t fake_can_equip_main_ok = 1;
static uint8_t fake_can_equip_sub_ok = 0;
static uint8_t __fastcall fake_can_equip_in_slot_fn(void*, void*, const uint8_t*, uint32_t slot) noexcept {
    if (slot == 0u) return fake_can_equip_main_ok;
    if (slot == 1u) return fake_can_equip_sub_ok;
    return 0;
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

static uint32_t sub_2h_resume_result = 0;
static __declspec(naked) void fake_sub_2h_allow_resume() {
    __asm {
        mov sub_2h_resume_result, 1
        ret
    }
}
static __declspec(naked) void fake_sub_2h_deny_resume() {
    __asm {
        cmp dword ptr [esp], 0x99
        jne bad_push
        add esp, 4
        mov sub_2h_resume_result, 2
        ret
    bad_push:
        add esp, 4
        mov sub_2h_resume_result, 0xBAD00099
        ret
    }
}

static __declspec(naked) uint32_t __cdecl sub_2h_main_abi(const uint8_t*, const uint8_t*) {
    __asm {
        push ebp
        push ebx
        push esi
        push edi
        mov edi, [esp + 20] ; main_res
        mov esi, [esp + 24] ; sub_res
        mov ebx, 0x11223344
        mov ecx, 0x22334455
        mov edx, 0x33445566
        mov ebp, 0x55667788
        call soul_sub_2h_main_hook
        xor eax, eax
        cmp ebx, 0x11223344
        jne bad
        cmp ecx, 0x22334455
        jne bad
        cmp edx, 0x33445566
        jne bad
        cmp ebp, 0x55667788
        jne bad
        mov eax, sub_2h_resume_result
    bad:
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
    original_can_equip_in_slot = &fake_can_equip_in_slot_fn;
    void* fake_mgr = reinterpret_cast<void*>(0x12340000u);
    item_res_mgr_slot = &fake_mgr;
    soul_sub_weapon_allow_resume = reinterpret_cast<uintptr_t>(&fake_sub_weapon_allow_resume);
    soul_sub_weapon_deny_resume = reinterpret_cast<uintptr_t>(&fake_sub_weapon_deny_resume);
    soul_sub_2h_main_allow_resume = reinterpret_cast<uintptr_t>(&fake_sub_2h_allow_resume);
    soul_sub_2h_main_deny_resume = reinterpret_cast<uintptr_t>(&fake_sub_2h_deny_resume);

    uint8_t mock_job = 10, mock_lvl = 10;
    main_job_slot = &mock_job; main_lvl_slot = &mock_lvl;
    selftest_alive = true;

    constexpr uint32_t kDaggerBit   = 1u << 2;
    constexpr uint32_t kSwordBit    = 1u << 3;
    constexpr uint32_t kGreatAxeBit = 1u << 6;
    constexpr uint32_t kPolearmBit  = 1u << 8;
    constexpr uint32_t kClubBit     = 1u << 11;

    SoulspireNativeWeaponRule bad = make_weapon_rule(10, 1, 10, 99, kDaggerBit, kSwordBit);
    assert(SoulspireNativeReplaceWeaponRules(&bad, 1) == 1);

    SoulspireNativeWeaponRule rules[3] = {
        make_weapon_rule(10, 1, 10, SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_1H, kDaggerBit | kSwordBit, kDaggerBit | kSwordBit),
        make_weapon_rule(1, 2, 10, SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H, kGreatAxeBit, kGreatAxeBit),
        make_weapon_rule(1, 3, 10, SOULSPIRE_NATIVE_WEAPON_MODE_TWOHAND_SHIELD, kPolearmBit, kClubBit),
    };
    assert(SoulspireNativeReplaceWeaponRules(rules, 3) == 0);
    assert(weapon_rule_catalog.count() == 3);

    // 1. Test Hook #25 (DUAL_1H) for BRD Adventurer.
    uint8_t sub_dagger[0x20]{}, sub_club[0x20]{};
    make_item_res(sub_dagger, 16448, 2);
    make_item_res(sub_club, 17024, 11);
    uint8_t ev[8] = {1, 1, 10, 1, 100, 0, 0, 0};
    state.update(ev, 8, GetTickCount());
    fake_inv_expected_container = 0; fake_inv_expected_slot = 5; fake_inv_item_id = 16535;
    make_item_res(fake_main_item_res, 16535, 3);
    assert(sub_weapon_abi(sub_dagger, 5, 0) == 1);
    assert(sub_weapon_abi(sub_club, 5, 0) == 2);

    // 2. Test Hooks #25, #26, #27, and #22 (CanEquipItemInSlot) for WAR Berserker DUAL_2H!
    mock_job = 1; mock_lvl = 10;
    ev[2] = 1; ev[3] = 2; state.update(ev, 8, GetTickCount());
    make_item_res(fake_main_item_res, 16704, 6); // Butterfly Axe (Great Axe)
    make_item_res(fake_sub_item_res, 16705, 6);  // Great Axe #2
    fake_inv_item_id = 16704;
    assert(sub_weapon_abi(fake_sub_item_res, 5, 0) == 1);
    assert(soul_allows_dual_2h_menu_item(16705) == 1);
    assert(sub_2h_main_abi(fake_main_item_res, fake_sub_item_res) == 1);

    // Hook #22: CanEquipItemInSlot(parsed_item, 1) passes for Main-capable 2H Great Axe under WAR Berserker!
    static uint8_t parsed_item[0x1500]{};
    const uint16_t axe_id = 16705;
    uint16_t axe_skill = 6;
    const uint16_t* skill_ptr = &axe_skill;
    std::memcpy(parsed_item + 0x14B0, &axe_id, 2);
    std::memcpy(parsed_item + 0x14E4, &skill_ptr, sizeof(skill_ptr));
    fake_can_equip_main_ok = 1; fake_can_equip_sub_ok = 0;
    assert(soul_can_equip_in_slot_hook(nullptr, nullptr, parsed_item, 1u) == 1);
    // Non-Great-Axe (e.g. Polearm=8) must be denied for WAR Berserker.
    axe_skill = 8;
    assert(soul_can_equip_in_slot_hook(nullptr, nullptr, parsed_item, 1u) == 0);
    // Below min level (Lv 9) must be denied.
    axe_skill = 6; mock_lvl = 9;
    assert(soul_can_equip_in_slot_hook(nullptr, nullptr, parsed_item, 1u) == 0);
    assert(sub_2h_main_abi(fake_main_item_res, fake_sub_item_res) == 2);

    assert(SoulspireNativeClearWeaponRules() == 0);
    item_res_mgr_slot = nullptr; original_get_inv_item = nullptr;
    original_get_item_res = nullptr; original_can_equip_in_slot = nullptr;
    soul_sub_weapon_allow_resume = 0; soul_sub_weapon_deny_resume = 0;
    soul_sub_2h_main_allow_resume = 0; soul_sub_2h_main_deny_resume = 0;
    main_lvl_slot = nullptr; main_job_slot = nullptr;
    selftest_alive = false;
}

static void runtime_identity_and_config_checks() {
    static char raw_buf[kMaxIdentityFileBytes + 1]{};
    size_t raw_len = 0;
    assert(read_bounded_file_w(L"..\\plugins\\ashita4\\data\\soul-identities.json", raw_buf, kMaxIdentityFileBytes, raw_len));
    static RuntimeIdentityTable t1{};
    assert(parse_runtime_identity_json(raw_buf, raw_len, t1));
    assert(t1.active && t1.soul_count == 66 && t1.schema_version == 1);
    assert(std::strcmp(t1.registry_hash, kRegistryHash) == 0);
    publish_runtime_identity_snapshot(t1);
    assert(std::strcmp(label_for(4, 1, false), "GOE") == 0);
    assert(std::strcmp(label_for(4, 1, true), "Goetist") == 0);
    assert(std::strcmp(label_for(13, 3, true), "Fuin") == 0);

    SoulspireNativeIdentityDiagnostics idiag{};
    assert(SoulspireNativeGetIdentityDiagnostics(&idiag, sizeof(idiag)) == 0);
    assert(idiag.source == 1 && idiag.soul_count == 66 && std::strcmp(idiag.active_registry_hash, t1.registry_hash) == 0);

    // Load canonical plugins/ashita4/data/soulspire_native.json.
    NativeConfig cfg{};
    size_t cfg_len = 0;
    assert(read_bounded_file_w(L"..\\plugins\\ashita4\\data\\soulspire_native.json", raw_buf, kMaxPresentationFileBytes, cfg_len));
    assert(parse_native_config_json(raw_buf, cfg_len, cfg));
    assert(cfg.from_file && cfg.tracking_px == -1 && cfg.offset_x_px == 1 && !cfg.use_glyph_widths);
    assert(cfg.log_level == LOG_LEVEL_WARN && cfg.enabled_modules_mask == kAllModulesMask && cfg.action_row_max_chars == 16);

    // Backwards-compatible legacy crystaljobs-presentation.json payload must also parse cleanly.
    const char* legacy_pres = "{\"schemaVersion\":1,\"searchBadge\":{\"trackingPx\":-1,\"offsetXPx\":1,\"useGlyphWidths\":false}}";
    NativeConfig leg_cfg{};
    assert(parse_native_config_json(legacy_pres, std::strlen(legacy_pres), leg_cfg));
    assert(leg_cfg.from_file && leg_cfg.tracking_px == -1 && leg_cfg.offset_x_px == 1 && !leg_cfg.use_glyph_widths);

    // Verify SCH H glyph {118, 214, 7} and uniform 7px pitch for HRB/HEL/HLC.
    const MenuGlyph h_glyph = menu_glyphs['H' - 'A'];
    assert(h_glyph.u == 118 && h_glyph.v == 214 && h_glyph.w == 7);
    const char* h_abbrs[3] = {"HRB", "HEL", "HLC"};
    for (const char* abbr : h_abbrs) {
        const uint8_t hw[3] = {
            menu_glyphs[abbr[0] - 'A'].w,
            menu_glyphs[abbr[1] - 'A'].w,
            menu_glyphs[abbr[2] - 'A'].w,
        };
        int16_t hx[3]{};
        compute_search_glyph_positions(hw, cfg, hx);
        assert(hx[0] == 1 && hx[1] == 8 && hx[2] == 15 && (hx[2] + hw[2]) <= 23);
    }

    publish_runtime_identity_snapshot(t1);
    publish_search_presentation(cfg);
}

static void dat_virtualization_poc_checks() {
    // End-to-end Phase F POC: registry-compiled dat-text-overrides.json drives native FFXI
    // menu text overrides directly without editing any DAT file or pushing a Lua catalog.
    action_catalog.clear();
    dat_virt_mgr.reset();
    dat_virt_mgr.configure(true);
    state = {};
    soul_override = {};
    transport = {};
    uint8_t mock_job = 3; // WHM
    main_job_slot = &mock_job;
    selftest_alive = true;

    // 1. Load the actual registry-compiled plugins/ashita4/data/dat-text-overrides.json
    std::unique_ptr<char[]> file_buf(new char[kMaxDatTextFileBytes + 1]);
    size_t file_len = 0;
    const bool read_ok = read_bounded_file_w(L"..\\plugins\\ashita4\\data\\dat-text-overrides.json",
        file_buf.get(), kMaxDatTextFileBytes, file_len);
    assert(read_ok && file_len > 1000);
    file_buf[file_len] = '\0';
    assert(dat_virt_mgr.load_from_json(file_buf.get(), file_len, true));
    assert(dat_virt_mgr.override_count() >= 160u);
    const uint32_t gen1 = dat_virt_mgr.generation();
    assert(gen1 >= 1u);

    // 2. Verify Soul-scoped isolation on shared spell ID 28 (WHM Zealot vs WHM Valkyrie vs unsocketed)
    assert(SoulspireNativeSetActiveSoul(3, 2, 0) == 0); // WHM Zealot
    const char* zealot_name = resolve_magic_row_name(28);
    assert(zealot_name != nullptr && std::strcmp(zealot_name, "Dawnfire") == 0);
    const char* zealot_desc = resolve_magic_desc(28);
    assert(zealot_desc != nullptr && std::strstr(zealot_desc, "light") != nullptr);

    // Switch Soul -> stale Zealot identity MUST immediately invalidate!
    assert(SoulspireNativeSetActiveSoul(3, 3, 0) == 0); // WHM Valkyrie
    const char* valk_name = resolve_magic_row_name(28);
    assert(valk_name != nullptr && std::strcmp(valk_name, "Vigil Lance") == 0);

    // Unsocket -> MUST fall back cleanly to pristine vanilla DAT (nullptr)
    assert(SoulspireNativeClearActiveSoul() == 0);
    assert(resolve_magic_row_name(28) == nullptr);

    // 3. Simulate authoritative registry edit ("Dawnfire" -> "Solaris Flare") and reload WITHOUT touching DATs
    DatTextOverrideRecord rec{};
    rec.job = 3; rec.branch = 2; rec.kind = 1; rec.action_id = 28;
    std::snprintf(rec.name, sizeof(rec.name), "Solaris Flare");
    std::snprintf(rec.description, sizeof(rec.description), "Unleash a focused solar flare. 6s recast.");
    std::vector<DatTextOverrideRecord> one{rec};
    char fnv_hex[20]{};
    detail_dat_virt::format_hex64(detail_dat_virt::compute_fnv1a64(one), fnv_hex, sizeof(fnv_hex));
    char updated_json[1024]{};
    const int n = std::snprintf(
        updated_json, sizeof(updated_json),
        "{\"schemaVersion\":1,\"registryHash\":\"deadbeef12345678\",\"integrityFnv1a64\":\"%s\","
        "\"overrideCount\":1,\"overrides\":[{\"jobId\":3,\"branch\":2,\"kind\":1,\"actionId\":28,"
        "\"name\":\"Solaris Flare\",\"description\":\"Unleash a focused solar flare. 6s recast.\","
        "\"iconId\":0,\"iconIdV2\":0}]}",
        fnv_hex);
    assert(n > 0);
    assert(dat_virt_mgr.load_from_json(updated_json, static_cast<size_t>(n), false));
    assert(dat_virt_mgr.generation() == gen1 + 1u);

    assert(SoulspireNativeSetActiveSoul(3, 2, 0) == 0);
    const char* updated_name = resolve_magic_row_name(28);
    assert(updated_name != nullptr && std::strcmp(updated_name, "Solaris Flare") == 0);

    // 4. Tampered JSON (corrupted integrityFnv1a64) MUST fail closed and keep valid snapshot
    const char* tampered =
        "{\"schemaVersion\":1,\"registryHash\":\"bad\",\"integrityFnv1a64\":\"0000000000000000\","
        "\"overrideCount\":1,\"overrides\":[{\"jobId\":3,\"branch\":2,\"kind\":1,\"actionId\":28,"
        "\"name\":\"Tampered\",\"description\":\"Bad\",\"iconId\":0,\"iconIdV2\":0}]}";
    assert(!dat_virt_mgr.load_from_json(tampered, std::strlen(tampered), false));
    const char* still_valid = resolve_magic_row_name(28);
    assert(still_valid != nullptr && std::strcmp(still_valid, "Solaris Flare") == 0);

    // 5. Disabling DatVirtualization module falls back cleanly to vanilla DAT
    dat_virt_mgr.configure(false);
    assert(resolve_magic_row_name(28) == nullptr);
    dat_virt_mgr.configure(true);
    assert(std::strcmp(resolve_magic_row_name(28), "Solaris Flare") == 0);

    // 6. Diagnostics export reflects live counts, generation, hits, and hash
    SoulspireNativeDatVirtStatus dv{};
    assert(SoulspireNativeGetDatVirtualizationStatus(&dv, sizeof(dv)) == 0);
    assert(dv.size == sizeof(dv) && dv.schema_version == 1 && dv.enabled == 1);
    assert(dv.override_count == 1 && dv.generation == gen1 + 1u && dv.hits >= 3u);
    assert(std::strcmp(dv.registry_hash, "deadbeef12345678") == 0);

    assert(SoulspireNativeClearActiveSoul() == 0);
    dat_virt_mgr.reset();
    main_job_slot = nullptr;
    selftest_alive = false;
}

int main() {
    runtime_identity_and_config_checks();

    // Mutual-exclusion check against legacy crystaljobs.dll.
    selftest_simulate_legacy_conflict = true;
    assert(SoulspireNativeInitialize() == 2);
    assert(hook_diag.init_stage == SOULSPIRE_NATIVE_INIT_CONFLICT_LEGACY_DLL);
    selftest_simulate_legacy_conflict = false;
    hook_diag = {};

    // Unsupported client build check.
    assert(!supported(nullptr));

    // Atomic Patch & PrologueDetour (8-byte cmpxchg8b) tests.
    auto* memory = static_cast<uint8_t*>(VirtualAlloc(nullptr, 4096, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE));
    assert(memory != nullptr);
    const uint8_t original[5] = {0xe8, 1, 2, 3, 4}; std::memcpy(memory, original, 5);
    Patch patch{0, reinterpret_cast<void*>(&normal_sprite_hook)};
    assert(patch.install(memory) && std::memcmp(memory, original, 5) != 0);
    assert(patch.restore() && std::memcmp(memory, original, 5) == 0);

    // Verify PrologueDetour preserves trailing bytes [5..7] atomically.
    const uint8_t sub_weapon_instruction[8] = {0x68, 0x8b, 0x00, 0x00, 0x00, 0xAA, 0xBB, 0xCC};
    std::memcpy(memory + 0x100, sub_weapon_instruction, 8);
    const uintptr_t saved_rva = soul_sub_weapon_detour.rva;
    soul_sub_weapon_detour.rva = 0x100;
    assert(soul_sub_weapon_detour.install(memory));
    assert(memory[0x105] == 0xAA && memory[0x106] == 0xBB && memory[0x107] == 0xCC);

    // Per-hook diagnostics bit position check for all 27 hooks (soul_sub_weapon_detour = kPatchCount + 2 = bit 24).
    hook_diag = {};
    hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_OK;
    SoulspireNativeHookDiagnostics diag{};
    assert(SoulspireNativeGetHookDiagnostics(&diag, sizeof(diag)) == 0);
    assert(diag.total_hooks == 1 && diag.expected_hooks == 27);
    assert((diag.installed_mask & (1u << (kPatchCount + 2u))) != 0);
    memory[0x100] = 0x90; // Simulate external overwrite.
    assert(SoulspireNativeGetHookDiagnostics(&diag, sizeof(diag)) == 0);
    assert(diag.total_hooks == 0 && (diag.installed_mask & (1u << (kPatchCount + 2u))) == 0);
    std::memcpy(memory + 0x100, soul_sub_weapon_detour.installed, 5);
    assert(soul_sub_weapon_detour.restore());
    assert(std::memcmp(memory + 0x100, sub_weapon_instruction, 8) == 0);
    soul_sub_weapon_detour.rva = saved_rva;
    hook_diag = {};

    // Verify safe Shutdown preserves resume pointer (never zeroes jump targets before restore).
    soul_sub_weapon_deny_resume = 0x12345678u;
    assert(SoulspireNativeShutdown() == 0);
    assert(soul_sub_weapon_deny_resume == 0x12345678u);
    soul_sub_weapon_deny_resume = 0;

    VirtualFree(memory, 0, MEM_RELEASE);

    transport_checks();
    multi_job_checks();
    equipment_persona_checks();
    action_catalog_checks();
    visibility_checks();
    weapon_rule_checks();
    dat_virtualization_poc_checks();

    // Load compiled soulspire_native.dll and verify ALL canonical + compatibility + Ashita v4 exports!
    const HMODULE dll = LoadLibraryA("soulspire_native.dll");
    assert(dll != nullptr);
    const char* required_exports[] = {
        "SoulspireNativeInitialize", "SoulspireNativeShutdown", "SoulspireNativeGetStatus",
        "SoulspireNativeSetState", "SoulspireNativeReloadConfig",
        "SoulspireNativeReplaceCatalog", "SoulspireNativeUpsertAction", "SoulspireNativeClearCatalog",
        "SoulspireNativeSetActiveSoul", "SoulspireNativeClearActiveSoul", "SoulspireNativeGetActionStatus",
        "SoulspireNativeSetActionRowLimit", "SoulspireNativeReplaceVisibility", "SoulspireNativeClearVisibility",
        "SoulspireNativeGetVisibilityStatus", "SoulspireNativeReplaceWeaponRules", "SoulspireNativeClearWeaponRules",
        "SoulspireNativeGetWeaponStatus", "SoulspireNativeGetHookDiagnostics", "SoulspireNativeGetIdentityDiagnostics",
        "SoulspireNativeGetInterfaceInfo", "SoulspireNativeGetDatVirtualizationStatus",
        "CrystalJobsInitialize", "CrystalJobsShutdown", "CrystalJobsGetStatus", "CrystalJobsSetState",
        "CrystalJobsReplaceCatalog", "CrystalJobsUpsertAction", "CrystalJobsClearCatalog",
        "CrystalJobsSetActiveSoul", "CrystalJobsClearActiveSoul", "CrystalJobsGetActionStatus",
        "CrystalJobsSetActionRowLimit", "CrystalJobsReplaceVisibility", "CrystalJobsClearVisibility",
        "CrystalJobsGetVisibilityStatus", "CrystalJobsReplaceWeaponRules", "CrystalJobsClearWeaponRules",
        "CrystalJobsGetWeaponStatus", "CrystalJobsGetHookDiagnostics", "CrystalJobsGetIdentityDiagnostics",
        "expCreatePlugin", "expDestroyPlugin", "expGetInterfaceVersion",
    };
    for (const char* name : required_exports) {
        assert(GetProcAddress(dll, name) != nullptr);
    }

    const auto get_iface_info = reinterpret_cast<uint32_t(__stdcall*)(SoulspireNativeInterfaceInfo*, uint32_t)>(
        GetProcAddress(dll, "SoulspireNativeGetInterfaceInfo"));
    SoulspireNativeInterfaceInfo info{};
    assert(get_iface_info(&info, sizeof(info)) == 0);
    assert(info.size == sizeof(info) && info.abi_version == SOULSPIRE_NATIVE_ABI_VERSION);
    assert(info.expected_hooks == 27 && std::strcmp(info.project_name, "Soulspire Native") == 0);

    const auto get_diag = reinterpret_cast<uint32_t(__stdcall*)(SoulspireNativeHookDiagnostics*, uint32_t)>(
        GetProcAddress(dll, "SoulspireNativeGetHookDiagnostics"));
    SoulspireNativeHookDiagnostics dll_diag{};
    assert(get_diag(&dll_diag, sizeof(dll_diag)) == 0 && dll_diag.expected_hooks == 27);

    const auto get_compat_diag = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsHookDiagnostics*, uint32_t)>(
        GetProcAddress(dll, "CrystalJobsGetHookDiagnostics"));
    CrystalJobsHookDiagnostics compat_diag{};
    assert(get_compat_diag(&compat_diag, sizeof(compat_diag)) == 0 && compat_diag.expected_hooks == 27);

    const auto get_iface = reinterpret_cast<double(__stdcall*)()>(GetProcAddress(dll, "expGetInterfaceVersion"));
    const auto create_plugin = reinterpret_cast<void*(__stdcall*)(const char*)>(GetProcAddress(dll, "expCreatePlugin"));
    const auto destroy_plugin = reinterpret_cast<void(__stdcall*)(void*)>(GetProcAddress(dll, "expDestroyPlugin"));
    assert(get_iface() == 4.30);
    auto* plugin = static_cast<AshitaPluginBase*>(create_plugin(""));
    assert(plugin != nullptr);
    assert(std::strcmp(plugin->GetName(), "soulspire_native") == 0);
    assert(plugin->GetVersion() == 2.00);
    destroy_plugin(plugin);
    FreeLibrary(dll);

    std::printf("[Soulspire Native] selftest PASSED (all 27 hooks, ABI v2, and CrystalJobs compat verified).\n");
    return 0;
}
