#pragma once
#include <cstdint>
#include <cstring>
#include "labels_generated.h"

namespace crystaljobs {
constexpr uint32_t capability = 0x43525901;
constexpr uint32_t marker = 0x43525900;
constexpr uint32_t lease_ms = 2500;

// Registry-generated Soul labels (source: soulspirexi-src/registry/souls.json).
inline const char* label_for(uint8_t job, uint8_t branch, bool full = false) noexcept {
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
