#pragma once
#include <atomic>
#include <cstdint>
#include <cstring>
#include "labels_generated.h"
#include "runtime_identity.h"

namespace crystaljobs {
constexpr uint32_t capability = 0x43525901;
constexpr uint32_t marker = 0x43525900;
constexpr uint32_t lease_ms = 2500;

// Immutable double-buffered runtime identity snapshot (published once at initialize/test;
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
// fallback: compiled labels_generated.h from soulspirexi-src/registry/souls.json).
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

inline uint32_t u32(const void* data) {
    uint32_t value;
    std::memcpy(&value, data, sizeof(value));
    return value;
}

struct State {
    uint32_t character = 0;
    uint32_t updated = 0;
    uint8_t job = 0, branch = 0;
    bool known = false;
    bool from_bridge = false;
    struct Entry { uint32_t character; uint8_t job; uint8_t branch; } rows[512]{};
    uint32_t next_row = 0;

    void clear_rows() { std::memset(rows, 0, sizeof(rows)); next_row = 0; }

    void update(const uint8_t* bytes, uint32_t size, uint32_t now) {
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

    bool alive(uint32_t now, uint32_t local_id, uint8_t local_job) const {
        return character != 0 && character == local_id && job != 0 && job == local_job && now - updated <= lease_ms;
    }

    void decoded(uint8_t* record) {
        const uint32_t tag = u32(record + 20), id = u32(record + 24);
        const bool ours = (tag & 0xffffff00u) == marker;
        // Consume our reserved-field extension before any legacy client consumer sees it.
        if (ours) std::memset(record + 20, 0, 4);
        const uint8_t branch_value = static_cast<uint8_t>(tag);
        const uint8_t row_job = record[32];
        const bool visible = (u32(record) & 0x140) == 0x140 && (u32(record + 48) & 0x4000) == 0;
        const uint8_t value = (ours && visible && valid_branch(row_job, branch_value)) ? branch_value : 0;
        // A row without our extension must not erase a previously decoded Soul
        // for the same character during a multi-packet search refresh.
        // A different job invalidates the old mapping instead of leaking it.
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
        if (id != 0 && value != 0) rows[next_row++ % 512] = {id, row_job, value};
    }

    uint8_t row_branch(const uint8_t* record) const {
        if (record == nullptr || (u32(record) & 0x140) != 0x140 || (u32(record + 48) & 0x4000) != 0) return 0;
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
}
