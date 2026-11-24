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

// ============================================================================
// Native Commands Menu ("menu    menuwind") Unit & ABI Self-Tests
// ============================================================================

struct MockSpriteBundle {
    uint8_t sprite[0x30]{};
    uint8_t nodes[24][0x18]{};
    uint8_t tiles[24][0xE0]{};

    void init(uint32_t tile_count, uint8_t tag) {
        std::memset(this, 0, sizeof(*this));
        sprite[0] = tag;
        for (uint32_t i = 0; i < tile_count; ++i) {
            uint8_t* next_p = (i + 1 < tile_count) ? nodes[i + 1] : nullptr;
            uint8_t* prev_p = (i > 0) ? nodes[i - 1] : nullptr;
            uint8_t* tile_p = tiles[i];
            std::memcpy(nodes[i] + 0x00, &next_p, sizeof(next_p));
            std::memcpy(nodes[i] + 0x04, &prev_p, sizeof(prev_p));
            std::memcpy(nodes[i] + 0x10, &tile_p, sizeof(tile_p));
            nodes[i][0x14] = 0;
            tiles[i][0] = tag;
            tiles[i][1] = static_cast<uint8_t>(i);
            const int16_t w = (i < 2) ? static_cast<int16_t>(i == 0 ? 48 : 40) : 8;
            const int16_t xs[4] = {0, w, 0, w};
            const int16_t ys[4] = {3, 3, 12, 12};
            std::memcpy(tiles[i] + 0xC0, xs, sizeof(xs));
            std::memcpy(tiles[i] + 0xC8, ys, sizeof(ys));
        }
        uint8_t* head_p = nodes[0];
        uint8_t* tail_p = nodes[tile_count - 1];
        std::memcpy(sprite + 0x04, &head_p, sizeof(head_p));
        std::memcpy(sprite + 0x08, &tail_p, sizeof(tail_p));
        std::memcpy(sprite + 0x14, &tile_count, sizeof(tile_count));
    }
};

struct MockListNode {
    uint8_t raw[0x18]{};
};

static uint32_t mock_cmd_new_calls = 0;
static uint32_t mock_cmd_delete_calls = 0;
static uint32_t mock_cmd_sound_calls = 0;
static uint32_t mock_cmd_close_calls = 0;
static void*    mock_cmd_closed_prim = nullptr;
static int32_t  mock_cmd_selected_override = -1;
static uint32_t mock_cmd_frame_box_updates = 0;
static uint32_t mock_cmd_recalc_calls = 0;
static uint32_t mock_cmd_update_sprite_calls = 0;
static MockListNode mock_cmd_extra_nodes[8]{};
static uint32_t mock_cmd_extra_node_idx = 0;

static void* __cdecl mock_ffxi_new(uint32_t sz) noexcept {
    ++mock_cmd_new_calls;
    return ::operator new(sz, std::nothrow);
}
static void __cdecl mock_ffxi_delete(void* p) noexcept {
    ++mock_cmd_delete_calls;
    ::operator delete(p);
}
static void __cdecl mock_play_confirm_sound() noexcept {
    ++mock_cmd_sound_calls;
}
static void __fastcall mock_frame_update_box(void* frame_ptr, void*, uint8_t) noexcept {
    ++mock_cmd_frame_box_updates;
    auto* frame = static_cast<uint8_t*>(frame_ptr);
    uint8_t* fd = nullptr;
    std::memcpy(&fd, frame + 0x30, sizeof(fd));
    if (fd != nullptr) {
        uint8_t* fres = nullptr;
        std::memcpy(&fres, fd, sizeof(fres));
        if (fres != nullptr) {
            int16_t h = 0;
            std::memcpy(&h, fres + 0x0C, sizeof(h));
            std::memcpy(frame + 0x24, &h, sizeof(h));
        }
    }
}
static void* __fastcall mock_btn_ctor(void* raw, void*, void*) noexcept {
    auto* b = static_cast<uint8_t*>(raw);
    std::memset(b, 0, 0x60);
    const int16_t type = 1;
    std::memcpy(b, &type, sizeof(type));
    b[0x4A] = 1;
    return b;
}
static void __fastcall mock_btn_init(void* btn_ptr, void*, const void* data_ptr) noexcept {
    auto* b = static_cast<uint8_t*>(btn_ptr);
    const auto* d = static_cast<const NativeMenuButtonData*>(data_ptr);
    std::memcpy(b + 0x0C, &d, sizeof(d));
    const int16_t r_left = d->res->x;
    const int16_t r_top = d->res->y;
    const int16_t r_right = static_cast<int16_t>(d->res->x + d->res->w);
    const int16_t r_bottom = static_cast<int16_t>(d->res->y + d->res->h);
    std::memcpy(b + 0x32, &r_left, 2);
    std::memcpy(b + 0x34, &r_top, 2);
    std::memcpy(b + 0x36, &r_right, 2);
    std::memcpy(b + 0x38, &r_bottom, 2);
    std::memcpy(b + 0x3A, &d->res->button_id, 2);
    std::memcpy(b + 0x40, &d->help, sizeof(d->help));
    std::memcpy(b + 0x44, &d->title, sizeof(d->title));
}
static void __fastcall mock_btn_recalc_rect(void* btn_ptr, void*, int32_t ox, int32_t oy, uint8_t) noexcept {
    ++mock_cmd_recalc_calls;
    auto* b = static_cast<uint8_t*>(btn_ptr);
    int16_t l = 0, t = 0, r = 0, bt = 0;
    std::memcpy(&l, b + 0x32, 2);
    std::memcpy(&t, b + 0x34, 2);
    std::memcpy(&r, b + 0x36, 2);
    std::memcpy(&bt, b + 0x38, 2);
    const int16_t sx = static_cast<int16_t>(ox + l);
    const int16_t sy = static_cast<int16_t>(oy + t);
    const int16_t sw = static_cast<int16_t>(r - l);
    const int16_t sh = static_cast<int16_t>(bt - t);
    std::memcpy(b + 0x2A, &sx, 2);
    std::memcpy(b + 0x2C, &sy, 2);
    std::memcpy(b + 0x2E, &sw, 2);
    std::memcpy(b + 0x30, &sh, 2);
}
static void __fastcall mock_btn_update_sprite(void* btn_ptr, void*, uint8_t) noexcept {
    ++mock_cmd_update_sprite_calls;
    auto* b = static_cast<uint8_t*>(btn_ptr);
    void* ov = nullptr;
    std::memcpy(&ov, b + 0x08, sizeof(ov));
    if (ov != nullptr) {
        std::memcpy(b + 0x04, &ov, sizeof(ov));
    }
}
static void __fastcall mock_btn_set_state(void* btn_ptr, void*, uint32_t st) noexcept {
    auto* b = static_cast<uint8_t*>(btn_ptr);
    std::memcpy(b + 0x10, &st, sizeof(st));
}
static void __fastcall mock_prim_set_selected(void* prim_ptr, void*, int32_t btn_id) noexcept {
    mock_cmd_selected_override = btn_id;
    auto* p = static_cast<uint8_t*>(prim_ptr);
    const int16_t id16 = static_cast<int16_t>(btn_id);
    std::memcpy(p + 0x4C, &id16, 2);
}
static void __fastcall mock_list_push_back(void* list_ptr, void*, void* elem) noexcept {
    auto* list = static_cast<uint8_t*>(list_ptr);
    assert(mock_cmd_extra_node_idx < 8u);
    uint8_t* node = mock_cmd_extra_nodes[mock_cmd_extra_node_idx++].raw;
    std::memset(node, 0, 0x18);
    std::memcpy(node + 0x10, &elem, sizeof(elem));
    uint8_t* tail = nullptr;
    std::memcpy(&tail, list + 0x04, sizeof(tail));
    if (tail == nullptr) {
        std::memcpy(list + 0x00, &node, sizeof(node));
        std::memcpy(list + 0x04, &node, sizeof(node));
    } else {
        std::memcpy(tail + 0x00, &node, sizeof(node));
        std::memcpy(node + 0x04, &tail, sizeof(tail));
        std::memcpy(list + 0x04, &node, sizeof(node));
    }
    uint32_t cnt = 0;
    std::memcpy(&cnt, list + 0x10, sizeof(cnt));
    ++cnt;
    std::memcpy(list + 0x10, &cnt, sizeof(cnt));
}
static void __fastcall mock_list_remove_node(void* list_ptr, void*, void* node_ptr) noexcept {
    auto* list = static_cast<uint8_t*>(list_ptr);
    auto* node = static_cast<uint8_t*>(node_ptr);
    uint8_t* next = nullptr;
    uint8_t* prev = nullptr;
    std::memcpy(&next, node + 0x00, sizeof(next));
    std::memcpy(&prev, node + 0x04, sizeof(prev));
    if (prev != nullptr) std::memcpy(prev + 0x00, &next, sizeof(next));
    else std::memcpy(list + 0x00, &next, sizeof(next));
    if (next != nullptr) std::memcpy(next + 0x04, &prev, sizeof(prev));
    else std::memcpy(list + 0x04, &prev, sizeof(prev));
    uint32_t cnt = 0;
    std::memcpy(&cnt, list + 0x10, sizeof(cnt));
    if (cnt > 0) --cnt;
    std::memcpy(list + 0x10, &cnt, sizeof(cnt));
}
static void __fastcall mock_close_menu(void* mgr, void*, void* prim, int32_t save_cursor) noexcept {
    assert(mgr == reinterpret_cast<void*>(0x23450000u));
    assert(save_cursor == 1);
    ++mock_cmd_close_calls;
    mock_cmd_closed_prim = prim;
}

static int32_t mock_stock_next_btn_calls = 0;
static int16_t __fastcall mock_stock_get_next_btn(void*, void*, int16_t cur, int16_t) noexcept {
    ++mock_stock_next_btn_calls;
    return static_cast<int16_t>(cur + 100);
}

static int32_t mock_stock_key_item_calls = 0;
static int32_t mock_stock_key_item_last_eax = -1;
static __declspec(naked) void mock_stock_key_item_resume() {
    __asm {
        mov mock_stock_key_item_last_eax, eax
        inc mock_stock_key_item_calls
        ret 8
    }
}

static __declspec(naked) int32_t __cdecl call_next_button_hook_abi(const void*, int32_t, int32_t) {
    __asm {
        push ebx
        push esi
        push edi
        mov ecx, [esp + 16]
        mov eax, [esp + 24]
        push eax
        mov eax, [esp + 24]
        push eax
        call menuwind_next_button_hook
        movsx eax, ax
        pop edi
        pop esi
        pop ebx
        ret
    }
}

static __declspec(naked) void __cdecl call_key_item_hook_abi(void*, int32_t, int32_t) {
    __asm {
        push ebx
        push esi
        push edi
        mov ecx, [esp + 16]
        mov eax, [esp + 24]
        push eax
        mov eax, [esp + 24]
        push eax
        call menuwind_key_item_hook
        pop edi
        pop esi
        pop ebx
        ret
    }
}

static void commands_menu_checks() {
    reset_commands_menu_state_for_test();
    mock_cmd_new_calls = 0;
    mock_cmd_delete_calls = 0;
    mock_cmd_sound_calls = 0;
    mock_cmd_close_calls = 0;
    mock_cmd_closed_prim = nullptr;
    mock_cmd_selected_override = -1;
    mock_cmd_frame_box_updates = 0;
    mock_cmd_recalc_calls = 0;
    mock_cmd_update_sprite_calls = 0;
    mock_cmd_extra_node_idx = 0;
    mock_stock_next_btn_calls = 0;
    mock_stock_key_item_calls = 0;
    mock_stock_key_item_last_eax = -1;

    // 1. Pure layout and navigation invariants (Status -> Soulspire -> Equipment -> Magic...).
    assert(commands_target_row_y(1, true) == 6);
    assert(commands_target_row_y(16, true) == 22);
    assert(commands_target_row_y(2, true) == 38);
    assert(commands_target_row_y(3, true) == 54);
    assert(commands_target_row_y(12, true) == 198);
    assert(commands_target_row_y(13, true) == -1);
    assert(commands_target_row_y(14, true) == -1);
    assert(commands_target_row_y(15, true) == -1);

    assert(resolve_commands_menu_next_button(1, kCommandsKeyDown, true) == 16);
    assert(resolve_commands_menu_next_button(16, kCommandsKeyDown, true) == 2);
    assert(resolve_commands_menu_next_button(2, kCommandsKeyUp, true) == 16);
    assert(resolve_commands_menu_next_button(16, kCommandsKeyUp, true) == 1);
    assert(resolve_commands_menu_next_button(16, kCommandsKeyLeft, true) == 16);
    assert(resolve_commands_menu_next_button(16, kCommandsKeyRight, true) == 16);
    assert(resolve_commands_menu_next_button(2, kCommandsKeyDown, true) == 0);
    assert(resolve_commands_menu_next_button(1, kCommandsKeyUp, true) == 0);
    assert(resolve_commands_menu_next_button(1, kCommandsKeyDown, false) == 0);

    // 2. Wire mock FFXI functions and build a full mock menu    menuwind primitive.
    original_ffxi_new = &mock_ffxi_new;
    original_ffxi_delete = &mock_ffxi_delete;
    original_play_confirm_sound = &mock_play_confirm_sound;
    original_frame_update_box = &mock_frame_update_box;
    original_btn_ctor = &mock_btn_ctor;
    original_btn_init = &mock_btn_init;
    original_btn_recalc_rect = &mock_btn_recalc_rect;
    original_btn_update_sprite = &mock_btn_update_sprite;
    original_btn_set_state = &mock_btn_set_state;
    original_prim_set_selected = &mock_prim_set_selected;
    original_list_push_back = &mock_list_push_back;
    original_list_remove_node = &mock_list_remove_node;
    original_close_menu = &mock_close_menu;
    original_get_next_button = reinterpret_cast<uintptr_t>(&mock_stock_get_next_btn);
    menuwind_key_item_resume = reinterpret_cast<uintptr_t>(&mock_stock_key_item_resume);
    menu_manager_instance = reinterpret_cast<void*>(0x23450000u);

    static MockSpriteBundle sp_status, sp_equip, sp_trade, sp_ls, sp_region;
    sp_status.init(14, 0x11);
    sp_equip.init(20, 0x22);
    sp_trade.init(12, 0x33);
    sp_ls.init(20, 0x44);
    sp_region.init(22, 0x55);

    uint8_t mock_menu_data[0x80]{};
    std::memcpy(mock_menu_data + 0x46, kCommandsMenuFormName, sizeof(kCommandsMenuFormName));
    const int16_t init_saved_cursor = 1;
    std::memcpy(mock_menu_data + 0x1A, &init_saved_cursor, 2);

    uint8_t mock_frame_res[0x20]{};
    int16_t f_w = 112, f_h = kCommandsVanillaFrameH;
    std::memcpy(mock_frame_res + 0x0A, &f_w, 2);
    std::memcpy(mock_frame_res + 0x0C, &f_h, 2);
    uint8_t* frame_res_ptr = mock_frame_res;
    uint8_t mock_frame_data[0x10]{};
    std::memcpy(mock_frame_data, &frame_res_ptr, sizeof(frame_res_ptr));
    uint8_t mock_frame[0x50]{};
    int16_t frame_type = 0, frame_y = 48;
    std::memcpy(mock_frame + 0x00, &frame_type, 2);
    std::memcpy(mock_frame + 0x1C, &frame_y, 2);
    std::memcpy(mock_frame + 0x24, &f_h, 2);
    uint8_t* frame_data_ptr = mock_frame_data;
    std::memcpy(mock_frame + 0x30, &frame_data_ptr, sizeof(frame_data_ptr));

    uint8_t mock_buttons[15][0x60]{};
    MockListNode mock_nodes[16]{}; // node 0 = frame, nodes 1..15 = buttons 1..15
    uint8_t mock_prim[0xC0]{};
    uint8_t* menu_data_ptr = mock_menu_data;
    std::memcpy(mock_prim + 0x04, &menu_data_ptr, sizeof(menu_data_ptr));
    int16_t ox = 384, oy = 48, init_count = 15, init_sel = 1;
    std::memcpy(mock_prim + 0x52, &ox, 2);
    std::memcpy(mock_prim + 0x54, &oy, 2);
    std::memcpy(mock_prim + 0x58, &init_count, 2);
    std::memcpy(mock_prim + 0x4C, &init_sel, 2);

    for (int i = 0; i < 16; ++i) {
        uint8_t* next_p = (i + 1 < 16) ? mock_nodes[i + 1].raw : nullptr;
        uint8_t* prev_p = (i > 0) ? mock_nodes[i - 1].raw : nullptr;
        uint8_t* elem_p = (i == 0) ? mock_frame : mock_buttons[i - 1];
        std::memcpy(mock_nodes[i].raw + 0x00, &next_p, sizeof(next_p));
        std::memcpy(mock_nodes[i].raw + 0x04, &prev_p, sizeof(prev_p));
        std::memcpy(mock_nodes[i].raw + 0x10, &elem_p, sizeof(elem_p));
    }
    uint8_t* head_n = mock_nodes[0].raw;
    uint8_t* tail_n = mock_nodes[15].raw;
    uint32_t list_cnt = 16;
    std::memcpy(mock_prim + 0x14 + 0x00, &head_n, sizeof(head_n));
    std::memcpy(mock_prim + 0x14 + 0x04, &tail_n, sizeof(tail_n));
    std::memcpy(mock_prim + 0x14 + 0x10, &list_cnt, sizeof(list_cnt));

    for (int16_t id = 1; id <= 15; ++id) {
        uint8_t* b = mock_buttons[id - 1];
        const int16_t btype = 1;
        std::memcpy(b + 0x00, &btype, 2);
        std::memcpy(b + 0x3A, &id, 2);
        const int16_t vy = commands_vanilla_row_y(id);
        const int16_t top = (vy >= 0) ? vy : static_cast<int16_t>(id == 15 ? 0 : 7);
        const int16_t bot = static_cast<int16_t>(top + 16);
        const int16_t left = (id == 13) ? -16 : (id == 14 ? 113 : (id == 15 ? 0 : 16));
        const int16_t right = static_cast<int16_t>(left + 88);
        std::memcpy(b + 0x32, &left, 2);
        std::memcpy(b + 0x34, &top, 2);
        std::memcpy(b + 0x36, &right, 2);
        std::memcpy(b + 0x38, &bot, 2);
        uint8_t* sp = nullptr;
        if (id == 1) sp = sp_status.sprite;
        else if (id == 2) sp = sp_equip.sprite;
        else if (id == 7) sp = sp_trade.sprite;
        else if (id == 9) sp = sp_ls.sprite;
        else if (id == 11) sp = sp_region.sprite;
        std::memcpy(b + 0x04, &sp, sizeof(sp));
    }

    // 3. First injection: verify insertion, frame height 202->218, row shifts, 20-tile sprite, row count 15->16.
    assert(inject_commands_menu_entry_impl(mock_prim));
    assert(mock_cmd_new_calls == 1);
    int16_t after_count = 0, after_frame_h = 0, prim_bottom = 0;
    std::memcpy(&after_count, mock_prim + 0x58, 2);
    std::memcpy(&after_frame_h, mock_frame_res + 0x0C, 2);
    std::memcpy(&prim_bottom, mock_prim + 0x40, 2);
    assert(after_count == 16);
    assert(after_frame_h == kCommandsExpandedFrameH);
    assert(prim_bottom == 48 + kCommandsExpandedFrameH);

    // Check Status stays at y=6, Equipment shifted 22->38, Map shifted 182->198, arrows/header untouched.
    int16_t y_status = 0, y_equip = 0, y_map = 0, y_arrow = 0;
    std::memcpy(&y_status, mock_buttons[0] + 0x34, 2);
    std::memcpy(&y_equip, mock_buttons[1] + 0x34, 2);
    std::memcpy(&y_map, mock_buttons[11] + 0x34, 2);
    std::memcpy(&y_arrow, mock_buttons[12] + 0x34, 2);
    assert(y_status == 6 && y_equip == 38 && y_map == 198 && y_arrow == 7);

    // Locate injected Btn 16 and verify its properties and 20-tile synthesized sprite.
    uint8_t* tail_after = nullptr;
    std::memcpy(&tail_after, mock_prim + 0x14 + 0x04, sizeof(tail_after));
    uint8_t* btn16 = nullptr;
    std::memcpy(&btn16, tail_after + 0x10, sizeof(btn16));
    assert(btn16 != nullptr);
    int16_t btn16_id = 0, btn16_y = 0, btn16_sy = 0;
    std::memcpy(&btn16_id, btn16 + 0x3A, 2);
    std::memcpy(&btn16_y, btn16 + 0x34, 2);
    std::memcpy(&btn16_sy, btn16 + 0x2C, 2);
    assert(btn16_id == 16 && btn16_y == 22 && btn16_sy == 70 && btn16[0x48] == 0);
    const char* btn16_title = nullptr;
    const char* btn16_help = nullptr;
    std::memcpy(&btn16_help, btn16 + 0x40, sizeof(btn16_help));
    std::memcpy(&btn16_title, btn16 + 0x44, sizeof(btn16_title));
    assert(std::strcmp(btn16_title, "Soulspire") == 0);
    assert(std::strcmp(btn16_help, "Open SoulspireXI Core.") == 0);
    uint8_t* sp16 = nullptr;
    std::memcpy(&sp16, btn16 + 0x04, sizeof(sp16));
    assert(sp16 != nullptr);
    uint32_t sp16_tiles = 0;
    std::memcpy(&sp16_tiles, sp16 + 0x14, sizeof(sp16_tiles));
    assert(sp16_tiles == kCommandsSpriteTileCount);

    // 4. Repeated open cycles must be strictly idempotent (no duplicate Btn 16, no double-shift).
    for (int cycle = 0; cycle < 4; ++cycle) {
        const uint32_t pressed = kCommandsButtonStatePressed;
        std::memcpy(btn16 + 0x10, &pressed, 4);
        assert(inject_commands_menu_entry_impl(mock_prim));
        std::memcpy(&after_count, mock_prim + 0x58, 2);
        std::memcpy(&y_equip, mock_buttons[1] + 0x34, 2);
        uint32_t st16 = 0;
        std::memcpy(&st16, btn16 + 0x10, 4);
        assert(after_count == 16 && y_equip == 38 && mock_cmd_new_calls == 1);
        assert(st16 == kCommandsButtonStateEnabled);
    }

    // 5. ABI test Hook #30 (CTkMenuData::GetNextButton) D-pad navigation & non-menuwind isolation.
    assert(call_next_button_hook_abi(mock_menu_data, 1, kCommandsKeyDown) == 16);
    assert(call_next_button_hook_abi(mock_menu_data, 16, kCommandsKeyDown) == 2);
    assert(call_next_button_hook_abi(mock_menu_data, 2, kCommandsKeyUp) == 16);
    assert(call_next_button_hook_abi(mock_menu_data, 16, kCommandsKeyUp) == 1);
    assert(call_next_button_hook_abi(mock_menu_data, 16, kCommandsKeyLeft) == 16);
    assert(call_next_button_hook_abi(mock_menu_data, 16, kCommandsKeyRight) == 16);
    assert(mock_stock_next_btn_calls == 0);
    // Vanilla buttons delegate cleanly to stock GetNextButton.
    assert(call_next_button_hook_abi(mock_menu_data, 3, kCommandsKeyDown) == 103);
    uint8_t other_menu_data[0x80]{};
    assert(call_next_button_hook_abi(other_menu_data, 1, kCommandsKeyDown) == 101);
    assert(mock_stock_next_btn_calls == 2);

    // 6. ABI test Hook #31 (CMenuWind::OnKeyItem): Confirm on Btn 16 opens Core; Cancel/Left/Right/vanilla pass through.
    uint8_t mock_menuwind[0x20]{};
    uint8_t* prim_ptr = mock_prim;
    std::memcpy(mock_menuwind + 0x08, &prim_ptr, sizeof(prim_ptr));

    assert(SoulspireNativeConsumeCoreOpenRequest() == 0);
    call_key_item_hook_abi(mock_menuwind, kCommandsKeyConfirm, 16);
    assert(mock_cmd_sound_calls == 1 && mock_cmd_close_calls == 1 && mock_cmd_closed_prim == mock_prim);
    assert(mock_stock_key_item_calls == 0);

    SoulspireNativeMainMenuStatus mm_st{};
    assert(SoulspireNativeGetMainMenuStatus(&mm_st, sizeof(mm_st)) == 0);
    assert(mm_st.injected == 1 && mm_st.button_id == 16 && mm_st.button_count == 16);
    assert(mm_st.frame_height == 218 && mm_st.sprite_synthesized == 1 && mm_st.sprite_banks_used == 1);
    assert(mm_st.activations == 1 && mm_st.pending_open_requests == 1 && mm_st.nav_overrides == 6);
    assert(SoulspireNativeConsumeCoreOpenRequest() == 1);
    assert(SoulspireNativeConsumeCoreOpenRequest() == 0);

    // Cancel (6), Left (3), Right (4) on Btn 16 and Confirm (5) on Status (1) must reach stock handler.
    call_key_item_hook_abi(mock_menuwind, 6, 16);
    assert(mock_stock_key_item_calls == 1 && mock_stock_key_item_last_eax == 6);
    call_key_item_hook_abi(mock_menuwind, 3, 16);
    assert(mock_stock_key_item_calls == 2 && mock_stock_key_item_last_eax == 3);
    call_key_item_hook_abi(mock_menuwind, kCommandsKeyConfirm, 1);
    assert(mock_stock_key_item_calls == 3 && mock_stock_key_item_last_eax == 5);
    assert(SoulspireNativeConsumeCoreOpenRequest() == 0);

    // 7. Clean shutdown restore: saved_cursor 16->1, selected 16->1, frame 218->202, rows shifted back, Btn 16 freed.
    const int16_t sel16 = 16;
    std::memcpy(mock_menu_data + 0x1A, &sel16, 2);
    std::memcpy(mock_prim + 0x4C, &sel16, 2);
    assert(restore_commands_menu_entry_on_prim(mock_prim));
    int16_t restored_saved = 0, restored_sel = 0, restored_cnt = 0, restored_h = 0;
    std::memcpy(&restored_saved, mock_menu_data + 0x1A, 2);
    std::memcpy(&restored_sel, mock_prim + 0x4C, 2);
    std::memcpy(&restored_cnt, mock_prim + 0x58, 2);
    std::memcpy(&restored_h, mock_frame_res + 0x0C, 2);
    std::memcpy(&y_equip, mock_buttons[1] + 0x34, 2);
    std::memcpy(&y_map, mock_buttons[11] + 0x34, 2);
    assert(restored_saved == 1 && restored_sel == 1 && mock_cmd_selected_override == 1);
    assert(restored_cnt == 15 && restored_h == kCommandsVanillaFrameH);
    assert(y_equip == 22 && y_map == 182 && mock_cmd_delete_calls == 1);

    // 8. Safe fallback when source sprites have unexpected tile counts (non-standard DAT).
    sp_status.init(4, 0x99); // too few tiles
    assert(!inject_commands_menu_entry_impl(mock_prim));
    std::memcpy(&restored_cnt, mock_prim + 0x58, 2);
    assert(restored_cnt == 15);

    // Clean up mock pointers.
    reset_commands_menu_state_for_test();
    original_ffxi_new = nullptr;
    original_ffxi_delete = nullptr;
    original_play_confirm_sound = nullptr;
    original_frame_update_box = nullptr;
    original_btn_ctor = nullptr;
    original_btn_init = nullptr;
    original_btn_recalc_rect = nullptr;
    original_btn_update_sprite = nullptr;
    original_btn_set_state = nullptr;
    original_prim_set_selected = nullptr;
    original_list_push_back = nullptr;
    original_list_remove_node = nullptr;
    original_close_menu = nullptr;
    original_get_next_button = 0;
    menuwind_key_item_resume = 0;
    menu_manager_instance = nullptr;
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

    // Per-hook diagnostics bit position check for all 31 hooks (soul_sub_weapon_detour = kPatchCount + 2 = bit 27).
    hook_diag = {};
    hook_diag.init_stage = SOULSPIRE_NATIVE_INIT_OK;
    SoulspireNativeHookDiagnostics diag{};
    assert(SoulspireNativeGetHookDiagnostics(&diag, sizeof(diag)) == 0);
    assert(diag.total_hooks == 1 && diag.expected_hooks == 31);
    assert((diag.installed_mask & (1u << (kPatchCount + 2u))) != 0);
    memory[0x100] = 0x90; // Simulate external overwrite.
    assert(SoulspireNativeGetHookDiagnostics(&diag, sizeof(diag)) == 0);
    assert(diag.total_hooks == 0 && (diag.installed_mask & (1u << (kPatchCount + 2u))) == 0);
    std::memcpy(memory + 0x100, soul_sub_weapon_detour.installed, 5);
    assert(soul_sub_weapon_detour.restore());
    assert(std::memcmp(memory + 0x100, sub_weapon_instruction, 8) == 0);
    soul_sub_weapon_detour.rva = saved_rva;
    hook_diag = {};

    // Verify PrologueDetour #31 (CMenuWind::OnKeyItem @ 0x141800, 0x0F opcode) atomic install & restore.
    const uint8_t key_item_instruction[8] = {0x0f, 0xbf, 0x44, 0x24, 0x04, 0x83, 0xc0, 0xfd};
    std::memcpy(memory + 0x200, key_item_instruction, 8);
    const uintptr_t saved_key_rva = menuwind_key_item_detour.rva;
    menuwind_key_item_detour.rva = 0x200;
    assert(menuwind_key_item_detour.install(memory));
    assert(memory[0x205] == 0x83 && memory[0x206] == 0xc0 && memory[0x207] == 0xfd);
    assert(menuwind_key_item_detour.restore());
    assert(std::memcmp(memory + 0x200, key_item_instruction, 8) == 0);
    menuwind_key_item_detour.rva = saved_key_rva;

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
    commands_menu_checks();

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
        "SoulspireNativeGetInterfaceInfo", "SoulspireNativeGetMainMenuStatus", "SoulspireNativeConsumeCoreOpenRequest",
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
    assert(info.expected_hooks == 31 && std::strcmp(info.project_name, "Soulspire Native") == 0);

    const auto get_main_menu = reinterpret_cast<uint32_t(__stdcall*)(SoulspireNativeMainMenuStatus*, uint32_t)>(
        GetProcAddress(dll, "SoulspireNativeGetMainMenuStatus"));
    const auto consume_open = reinterpret_cast<uint32_t(__stdcall*)(void)>(
        GetProcAddress(dll, "SoulspireNativeConsumeCoreOpenRequest"));
    SoulspireNativeMainMenuStatus dll_mm{};
    assert(get_main_menu(&dll_mm, sizeof(dll_mm)) == 0);
    assert(dll_mm.size == sizeof(dll_mm) && dll_mm.expected_hooks == 31 && dll_mm.button_id == 16);
    assert(consume_open() == 0);

    const auto get_diag = reinterpret_cast<uint32_t(__stdcall*)(SoulspireNativeHookDiagnostics*, uint32_t)>(
        GetProcAddress(dll, "SoulspireNativeGetHookDiagnostics"));
    SoulspireNativeHookDiagnostics dll_diag{};
    assert(get_diag(&dll_diag, sizeof(dll_diag)) == 0 && dll_diag.expected_hooks == 31);

    const auto get_compat_diag = reinterpret_cast<uint32_t(__stdcall*)(CrystalJobsHookDiagnostics*, uint32_t)>(
        GetProcAddress(dll, "CrystalJobsGetHookDiagnostics"));
    CrystalJobsHookDiagnostics compat_diag{};
    assert(get_compat_diag(&compat_diag, sizeof(compat_diag)) == 0 && compat_diag.expected_hooks == 31);

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

    std::printf("[Soulspire Native] selftest PASSED (all 31 hooks, native Commands menu, ABI v2, and CrystalJobs compat verified).\n");
    return 0;
}
