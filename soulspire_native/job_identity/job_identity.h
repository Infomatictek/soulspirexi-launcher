#pragma once
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "../registry/labels_generated.h"
#include "../registry/runtime_identity.h"

namespace soulspire::native {

constexpr uint32_t capability = 0x43525901u;
constexpr uint32_t marker     = 0x43525900u;
constexpr uint32_t lease_ms   = 2500u;

// Immutable double-buffered runtime identity snapshot (published on init/reload;
// lock-free reads during per-frame rendering; never points to temporary or unloaded memory).
inline RuntimeIdentityTable g_runtime_identity_slots[2]{};
inline std::atomic<uint32_t> g_runtime_identity_slot_idx{0};
inline std::atomic<const RuntimeIdentityTable*> g_active_runtime_identity{nullptr};
inline uint32_t g_last_identity_status = IDENTITY_STATUS_COMPILED_FALLBACK;
inline char g_last_identity_warning[128]{};

inline SearchPresentationConfig g_search_presentation_slots[2]{
    default_presentation_config(),
    default_presentation_config(),
};
inline std::atomic<uint32_t> g_search_presentation_slot_idx{0};
inline std::atomic<const SearchPresentationConfig*> g_active_search_presentation{&g_search_presentation_slots[0]};

inline void publish_runtime_identity_snapshot(const RuntimeIdentityTable& table) noexcept {
    const uint32_t next = (g_runtime_identity_slot_idx.fetch_add(1, std::memory_order_relaxed) + 1u) & 1u;
    g_runtime_identity_slots[next] = table;
    g_last_identity_status = table.status;
    std::snprintf(g_last_identity_warning, sizeof(g_last_identity_warning), "%s", table.warning);
    g_active_runtime_identity.store(&g_runtime_identity_slots[next], std::memory_order_release);
}

inline void clear_runtime_identity_snapshot(uint32_t status, const char* warning) noexcept {
    g_active_runtime_identity.store(nullptr, std::memory_order_release);
    g_last_identity_status = status;
    std::snprintf(g_last_identity_warning, sizeof(g_last_identity_warning), "%s", warning ? warning : "");
}

inline void publish_search_presentation(const SearchPresentationConfig& cfg) noexcept {
    const uint32_t next = (g_search_presentation_slot_idx.fetch_add(1, std::memory_order_relaxed) + 1u) & 1u;
    g_search_presentation_slots[next] = cfg;
    g_active_search_presentation.store(&g_search_presentation_slots[next], std::memory_order_release);
}

inline const SearchPresentationConfig& active_search_presentation() noexcept {
    const auto* ptr = g_active_search_presentation.load(std::memory_order_acquire);
    return ptr != nullptr ? *ptr : g_search_presentation_slots[0];
}

// Runtime Soul labels (primary: validated plugins/data/soul-identities.json;
// fallback: compiled registry/labels_generated.h from soulspirexi-src/registry/souls.json).
inline const char* label_for(uint8_t job, uint8_t branch, bool full = false) noexcept {
    if (job >= 1 && job <= 22 && branch >= 1 && branch <= 3) {
        const auto* snap = g_active_runtime_identity.load(std::memory_order_acquire);
        if (snap != nullptr && snap->active) {
            const auto& entry = snap->entries[job][branch];
            if (entry.present) {
                return full ? entry.name : entry.abbr;
            }
        }
    }
    return generated_label_for(job, branch, full);
}

inline bool has_soul_labels(uint8_t job) noexcept {
    return label_for(job, 1, false) != nullptr;
}

inline bool valid_branch(uint8_t job, uint8_t branch) noexcept {
    return branch != 0 && label_for(job, branch, false) != nullptr;
}

inline const char* label(uint8_t branch, bool full = false) noexcept {
    if (const char* custom = label_for(1, branch, full)) return custom;
    return full ? "Warrior" : "WAR";
}

inline uint32_t u32(const void* data) noexcept {
    uint32_t value = 0;
    std::memcpy(&value, data, sizeof(value));
    return value;
}

inline uint16_t u16(const void* bytes) noexcept {
    uint16_t value = 0;
    std::memcpy(&value, bytes, 2);
    return value;
}

inline uint32_t packet_size(const uint8_t* packet) noexcept {
    return (u16(packet) >> 9) * 4u;
}

inline bool whole_packets(const uint8_t* bytes, uint32_t size) noexcept {
    if (bytes == nullptr) return false;
    uint32_t at = 0;
    while (at + 4 <= size) {
        const uint32_t length = packet_size(bytes + at);
        if (length == 0) break;
        if (length < 4 || length > size - at) return false;
        at += length;
    }
    while (at < size) {
        if (bytes[at++] != 0) return false;
    }
    return true;
}

struct State {
    uint32_t character = 0;
    uint32_t updated = 0;
    uint8_t job = 0, branch = 0;
    bool known = false;
    bool from_bridge = false;
    struct Entry { uint32_t character; uint8_t job; uint8_t branch; } rows[512]{};
    uint32_t next_row = 0;

    void clear_rows() noexcept {
        std::memset(rows, 0, sizeof(rows));
        next_row = 0;
    }

    void update(const uint8_t* bytes, uint32_t size, uint32_t now) noexcept {
        if (size != 8 || bytes == nullptr || bytes[0] != 1 || bytes[1] > 1 || bytes[2] > 23 || bytes[3] > 7) {
            *this = {};
            return;
        }
        const uint32_t id = u32(bytes + 4);
        if (id != character) clear_rows();
        character = id;
        updated = now;
        known = bytes[1] == 1;
        job = bytes[2];
        branch = (known && valid_branch(job, bytes[3])) ? bytes[3] : 0;
        from_bridge = known;
    }

    bool alive(uint32_t now, uint32_t local_id, uint8_t local_job) const noexcept {
        return character != 0 && character == local_id && job != 0 && job == local_job && now - updated <= lease_ms;
    }

    void decoded(uint8_t* record) noexcept {
        if (record == nullptr) return;
        const uint32_t tag = u32(record + 20), id = u32(record + 24);
        const bool ours = (tag & 0xffffff00u) == marker;
        // Consume our reserved-field extension before any legacy client consumer sees it.
        if (ours) std::memset(record + 20, 0, 4);
        const uint8_t branch_value = static_cast<uint8_t>(tag);
        const uint8_t row_job = record[32];
        const bool visible = (u32(record) & 0x140u) == 0x140u && (u32(record + 48) & 0x4000u) == 0;
        const uint8_t value = (ours && visible && valid_branch(row_job, branch_value)) ? branch_value : 0;
        for (auto& row : rows) {
            if (row.character == id && id != 0) {
                if (row.job != row_job) {
                    row.job = row_job;
                    row.branch = value;
                } else if (ours) {
                    row.branch = value;
                }
                return;
            }
        }
        if (id != 0 && value != 0) rows[next_row++ % 512u] = {id, row_job, value};
    }

    uint8_t row_branch(const uint8_t* record) const noexcept {
        if (record == nullptr || (u32(record) & 0x140u) != 0x140u || (u32(record + 48) & 0x4000u) != 0) return 0;
        const uint32_t id = u32(record + 24);
        const uint8_t row_job = record[32];
        for (const auto& row : rows) {
            if (id != 0 && row.character == id) {
                return (row.job == row_job && valid_branch(row_job, row.branch)) ? row.branch : 0;
            }
        }
        return 0;
    }
};

struct Transport {
    uint32_t character = 0, last_query = 0;
    uint16_t pending = 0;
    uint32_t next_request = 0x8000u;
    uint8_t job = 0;
    bool refresh = false;
    uint8_t timeouts = 0;
    uint32_t sent = 0, accepted = 0, rejected = 0;

    void reset(State& state) noexcept {
        character = 0;
        job = 0;
        pending = 0;
        refresh = false;
        timeouts = 0;
        // Reclaim request namespace cleanly across zone/login boundaries so long
        // multi-zone sessions never permanently exhaust next_request.
        if (next_request > 0xffffu) next_request = 0x8000u;
        state = {};
    }

    static bool response(const uint8_t* packet, uint32_t size) noexcept {
        if (packet == nullptr) return false;
        if (size != 64 || (u16(packet) & 0x1ffu) != 0x1ffu || packet_size(packet) != size ||
            std::memcmp(packet + 4, "CRYS", 4) != 0 || packet[8] != 1 || packet[9] > 4 ||
            packet[12] > 23 || packet[13] != 24 || packet[14] > 99 || packet[15] != 0) return false;
        for (uint32_t at = 16; at < 64; at += 2) {
            const uint8_t owned = packet[at], active = packet[at + 1];
            if ((owned & 1u) != 0 || active > 7 || (active != 0 && (owned & (1u << active)) == 0)) return false;
        }
        return true;
    }

    // Returns true only for this DLL's CRYS response namespace, consumed before native dispatch.
    bool incoming(const uint8_t* packet, uint32_t size, uint32_t now, State& state) noexcept {
        if (packet == nullptr || size < 4) return false;
        const uint16_t id = u16(packet) & 0x1ffu;
        if (id == 0x00au && size > 0xb4u) {
            reset(state);
            character = u32(packet + 4);
            job = packet[0xb4];
            refresh = character != 0 && job > 0 && job <= 23;
        } else if (id == 0x00bu) {
            reset(state);
        } else if (id == 0x061u && size > 0x0cu && packet[0x0c] != job) {
            job = packet[0x0c];
            pending = 0;
            timeouts = 0; // Fresh job transition should not inherit prior job timeouts.
            state = {};
            refresh = character != 0 && job > 0 && job <= 23;
        } else if (id == 0x1ffu && size >= 12 && std::memcmp(packet + 4, "CRYS", 4) == 0) {
            const uint16_t request = u16(packet + 10);
            const bool valid = response(packet, size);
            if (request < 0x8000u) {
                if (valid) refresh = true;
                return false;
            }
            if (request == pending && pending != 0 && now - last_query <= 2500u) {
                pending = 0;
                if (valid && packet[9] == 0 && packet[12] == job && character != 0 && job >= 1 && job <= 23) {
                    const uint8_t active_branch = packet[16 + job * 2 + 1];
                    state.character = character;
                    state.job = job;
                    state.known = true;
                    state.from_bridge = false;
                    state.branch = valid_branch(job, active_branch) ? active_branch : 0;
                    state.updated = now;
                    timeouts = 0;
                    ++accepted;
                } else {
                    state.known = false;
                    state.branch = 0;
                    state.from_bridge = false;
                    ++rejected;
                }
            } else {
                ++rejected;
            }
            return true;
        }
        return false;
    }

    void outgoing(const uint8_t* packet, State& state) noexcept {
        if (packet != nullptr && (u16(packet) & 0x1ffu) == 0x00du) reset(state);
    }

    bool prepare(uint8_t* request, const uint8_t* counter, uint32_t now, const State* current_state = nullptr) noexcept {
        if (request == nullptr || counter == nullptr) return false;
        if (pending != 0 && now - last_query >= 2000u) {
            pending = 0;
            ++timeouts;
        }
        if (current_state != nullptr && current_state->from_bridge && current_state->alive(now, character, job)) return false;
        if (character == 0 || !has_soul_labels(job) || timeouts >= 3 || next_request > 0xffffu ||
            (pending != 0 && now - last_query < 2000u) ||
            (!refresh && now - last_query < 1000u)) return false;
        std::memset(request, 0, 16);
        const uint16_t header = 0x11fu | (4u << 9);
        std::memcpy(request, &header, 2);
        std::memcpy(request + 2, counter, 2);
        std::memcpy(request + 4, "CRYS", 4);
        request[8] = 1;
        request[12] = job;
        pending = static_cast<uint16_t>(next_request++);
        std::memcpy(request + 10, &pending, 2);
        last_query = now;
        refresh = false;
        ++sent;
        return true;
    }
};

} // namespace soulspire::native
