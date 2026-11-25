#pragma once
#include "../core/api.h"
#include "layout.h"
#include <cstdint>
#include <cstring>

namespace soulspire::native {

using CanShowSpell = uint8_t (__cdecl*)(const uint8_t*);

struct HookDescriptor {
    uint32_t    index;
    uintptr_t   rva;
    const char* name;
    uint32_t    module_id;
    bool        is_detour;
};

struct HookDiagnosticsState {
    uint32_t ffxi_base = 0;
    uint32_t ffxi_timestamp = 0;
    uint32_t ffxi_image_size = 0;
    uint32_t init_stage = SOULSPIRE_NATIVE_INIT_NOT_RUN;
    uint32_t failed_rva = 0;
    uint32_t failed_index = 0xFFFFFFFFu;
    uint8_t  observed_bytes[8]{};
};

#if defined(_WIN32)
#ifndef _MSC_VER
inline bool readable_range(const void* ptr, size_t len) noexcept {
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

inline void safe_read_bytes(const void* src, uint8_t (&out)[8]) noexcept {
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

enum class ClientHostKind : uint8_t {
    Unknown  = 0,
    Ashita   = 1,
    VanaCore = 2,
};

inline bool host_detour(uint8_t* entry, const uint8_t* expected, size_t length, size_t stolen, HMODULE host) noexcept {
    if (host == nullptr || entry == nullptr || entry[0] != 0xe9u || stolen < 5 || stolen >= length) return false;
    for (size_t at = 5; at < stolen; ++at) {
        if (entry[at] != 0x90u && entry[at] != 0xccu && entry[at] != expected[at]) return false;
    }
    if (std::memcmp(entry + stolen, expected + stolen, length - stolen) != 0) return false;
    const uintptr_t target = reinterpret_cast<uintptr_t>(entry + 5) + read_u32_le(entry + 1);
    MEMORY_BASIC_INFORMATION region{};
    if (VirtualQuery(reinterpret_cast<void*>(target), &region, sizeof(region)) != sizeof(region) ||
        region.AllocationBase != host || region.Type != MEM_IMAGE || region.State != MEM_COMMIT ||
        (region.Protect & PAGE_GUARD) != 0) return false;
    const DWORD protection = region.Protect & 0xffu;
    return protection == PAGE_EXECUTE || protection == PAGE_EXECUTE_READ ||
           protection == PAGE_EXECUTE_READWRITE || protection == PAGE_EXECUTE_WRITECOPY;
}

inline HMODULE detect_vanacore_host_module() noexcept {
    if (HMODULE m = GetModuleHandleW(L"VanaCore.Core.dll")) return m;
    if (HMODULE m = GetModuleHandleW(L"SoulspireClient.Core.dll")) return m;
    return nullptr;
}

inline ClientHostKind detect_client_host(HMODULE* out_module = nullptr) noexcept {
    if (HMODULE m = GetModuleHandleW(L"Ashita.dll")) {
        if (out_module != nullptr) *out_module = m;
        return ClientHostKind::Ashita;
    }
    if (HMODULE m = detect_vanacore_host_module()) {
        if (out_module != nullptr) *out_module = m;
        return ClientHostKind::VanaCore;
    }
    if (out_module != nullptr) *out_module = nullptr;
    return ClientHostKind::Unknown;
}

// Fail-closed dual-host callee detour validator for FFXiMain.dll functions that Ashita.dll or
// VanaCore.Core.dll / SoulspireClient.Core.dll legitimately detour before soulspire_native.dll
// initializes. All listed RVAs are callee-only in soulspire_native.dll (never patched/detoured by
// us), so chaining through the host's verified 0xE9 detour is safe.
//   - 0xDD6C0 (MapDecode / packet decrypt): Ashita 10B, VanaCore packets.cpp 10B
//   - 0xDF7C0 (MapEncode / packet encrypt): Ashita 5B, VanaCore 5B/7B
//   - 0x1CAD80 (native_text / centred text draw): VanaCore chatfont.cpp 8B
//   - 0x121110 (YmMenuShape::Draw scaled): VanaCore buttons.cpp 5B
//   - 0x120FF0 (YmMenuShape::Draw plain): VanaCore buttons.cpp 7B
// Never skips signature validation for unknown modules, corrupted trailing bytes, or any hook site.
inline bool host_packet_detour_matches(
    uintptr_t rva,
    uint8_t* entry,
    const uint8_t* expected,
    size_t length,
    HMODULE ashita_host,
    HMODULE vanacore_host) noexcept {
    if (rva == 0xDD6C0u) {
        return host_detour(entry, expected, length, 10, ashita_host) ||
               host_detour(entry, expected, length, 10, vanacore_host);
    }
    if (rva == 0xDF7C0u) {
        return host_detour(entry, expected, length, 5, ashita_host) ||
               host_detour(entry, expected, length, 5, vanacore_host) ||
               host_detour(entry, expected, length, 7, vanacore_host);
    }
    if (rva == 0x1CAD80u) {
        return host_detour(entry, expected, length, 8, vanacore_host);
    }
    if (rva == 0x121110u) {
        return host_detour(entry, expected, length, 5, vanacore_host);
    }
    if (rva == 0x120FF0u) {
        return host_detour(entry, expected, length, 7, vanacore_host);
    }
    return false;
}

// Atomic 5-byte CALL displacement patcher (opcode 0xE8 stays invariant; 4-byte displacement swapped via lock cmpxchg).
struct Patch {
    uintptr_t rva;
    void* replacement;
    uint8_t original[5]{}, installed[5]{};
    uint8_t* site = nullptr;

    static bool compare_exchange(uint8_t* operand, uint32_t expected, uint32_t desired) noexcept {
        const LONG prev = InterlockedCompareExchange(
            reinterpret_cast<volatile LONG*>(operand),
            static_cast<LONG>(desired),
            static_cast<LONG>(expected));
        return static_cast<uint32_t>(prev) == expected;
    }

    static bool write(uint8_t* target, const uint8_t* expected, const uint8_t* desired) noexcept {
        if (target == nullptr || target[0] != 0xe8u || expected[0] != 0xe8u || desired[0] != 0xe8u ||
            (reinterpret_cast<uintptr_t>(target + 1) & 63u) > 60u) return false;
        DWORD protection = 0, discarded = 0;
        if (!VirtualProtect(target, 5, PAGE_EXECUTE_READWRITE, &protection)) return false;
        const bool exchanged = target[0] == 0xe8u && compare_exchange(target + 1, read_u32_le(expected + 1), read_u32_le(desired + 1));
        const bool opcode_intact = target[0] == 0xe8u;
        const bool flushed = FlushInstructionCache(GetCurrentProcess(), target, 5) != 0;
        const bool restored = VirtualProtect(target, 5, protection, &discarded) != 0;
        return exchanged && opcode_intact && flushed && restored;
    }

    bool install(uint8_t* base) noexcept {
        if (site != nullptr) return std::memcmp(site, installed, 5) == 0;
        site = base + rva;
        if (*site != 0xe8u) { site = nullptr; return false; }
        std::memcpy(original, site, 5);
        installed[0] = 0xe8u;
        const uint32_t relative = static_cast<uint32_t>(
            reinterpret_cast<uintptr_t>(replacement) - reinterpret_cast<uintptr_t>(site + 5));
        std::memcpy(installed + 1, &relative, 4);
        if (write(site, original, installed)) return true;
        write(site, installed, original);
        site = nullptr;
        return false;
    }

    bool restore() noexcept {
        if (site == nullptr) return true;
        if (std::memcmp(site, original, 5) == 0) { site = nullptr; return true; }
        const bool ours = std::memcmp(site, installed, 5) == 0;
        const bool restored = ours && write(site, installed, original);
        site = nullptr;
        return restored;
    }
};

// Atomic 5-byte JMP prologue detour using 8-byte lock cmpxchg8b (InterlockedCompareExchange64)
// so live FFXI threads never observe a torn opcode/displacement write during install or shutdown.
struct PrologueDetour {
    uintptr_t rva;
    void* replacement;
    uint8_t first_opcode = 0xA1u;
    uint8_t original[5]{}, installed[5]{};
    uint8_t* site = nullptr;
    uint8_t* trampoline = nullptr;

    static bool write_atomic5(uint8_t* target, const uint8_t expected[5], const uint8_t desired[5]) noexcept {
        if (target == nullptr) return false;
        DWORD protection = 0, discarded = 0;
        if (!VirtualProtect(target, 8, PAGE_EXECUTE_READWRITE, &protection)) return false;
        uint8_t cur8[8]{};
        std::memcpy(cur8, target, 8);
        bool ok = false;
        if (std::memcmp(cur8, expected, 5) == 0) {
            uint8_t next8[8]{};
            std::memcpy(next8, cur8, 8);
            std::memcpy(next8, desired, 5);
            LONGLONG exp64 = 0, des64 = 0;
            std::memcpy(&exp64, cur8, 8);
            std::memcpy(&des64, next8, 8);
            const LONGLONG prev = InterlockedCompareExchange64(
                reinterpret_cast<volatile LONGLONG*>(target), des64, exp64);
            ok = (prev == exp64);
        }
        const bool flushed = FlushInstructionCache(GetCurrentProcess(), target, 8) != 0;
        const bool restored = VirtualProtect(target, 8, protection, &discarded) != 0;
        return ok && flushed && restored;
    }

    bool install(uint8_t* base, CanShowSpell* out_trampoline = nullptr) noexcept {
        if (site != nullptr) return std::memcmp(site, installed, 5) == 0;
        uint8_t* target = base + rva;
        if (target[0] != first_opcode) return false;
        if (out_trampoline != nullptr) {
            if (trampoline == nullptr) {
                trampoline = static_cast<uint8_t*>(
                    VirtualAlloc(nullptr, 16, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
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

        if (!write_atomic5(target, original, installed)) return false;
        site = target;
        return true;
    }

    bool restore() noexcept {
        if (site == nullptr) return true;
        if (std::memcmp(site, original, 5) == 0) { site = nullptr; return true; }
        if (std::memcmp(site, installed, 5) != 0) { site = nullptr; return false; }
        const bool restored = write_atomic5(site, installed, original);
        site = nullptr;
        return restored;
    }
};
#endif

} // namespace soulspire::native
