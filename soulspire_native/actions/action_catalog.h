#pragma once
#include "../core/api.h"
#include "../job_identity/job_identity.h"
#include <algorithm>
#include <cstdint>
#include <cstring>
#include <vector>

namespace soulspire::native {

struct ActionRecord {
    uint8_t  job = 0;
    uint8_t  branch = 0;
    uint16_t action_id = 0;
    uint32_t kind = 0;
    uint16_t icon_id = 0xFFFFu;
    uint16_t icon_id_v2 = 0xFFFFu;
    char     name[80]{};
    char     description[192]{};
};

struct ActionKey {
    uint8_t  job;
    uint8_t  branch;
    uint32_t kind;
    uint16_t action_id;
};

inline bool action_key_less(const ActionRecord& a, const ActionKey& b) noexcept {
    if (a.job != b.job) return a.job < b.job;
    if (a.branch != b.branch) return a.branch < b.branch;
    if (a.kind != b.kind) return a.kind < b.kind;
    return a.action_id < b.action_id;
}

inline bool action_record_less(const ActionRecord& a, const ActionRecord& b) noexcept {
    return action_key_less(a, ActionKey{b.job, b.branch, b.kind, b.action_id});
}

inline bool action_key_equal(const ActionRecord& a, const ActionKey& b) noexcept {
    return a.job == b.job && a.branch == b.branch && a.kind == b.kind && a.action_id == b.action_id;
}

inline bool valid_action_kind(uint32_t kind) noexcept {
    return kind == SOULSPIRE_NATIVE_ACTION_SPELL ||
           kind == SOULSPIRE_NATIVE_ACTION_ABILITY ||
           kind == SOULSPIRE_NATIVE_ACTION_WEAPONSKILL;
}

inline bool valid_action_id(uint32_t kind, uint16_t id) noexcept {
    if (kind == SOULSPIRE_NATIVE_ACTION_SPELL) return id <= 1023u;
    if (kind == SOULSPIRE_NATIVE_ACTION_WEAPONSKILL) return id <= 511u;
    if (kind == SOULSPIRE_NATIVE_ACTION_ABILITY) return id <= 2047u;
    return false;
}

inline void copy_cstr_bounded(char* dst, size_t dst_size, const char* src, size_t src_max) noexcept {
    if (dst == nullptr || dst_size == 0) return;
    dst[0] = '\0';
    if (src == nullptr) return;
    size_t in = 0;
    size_t out = 0;
    const size_t out_limit = dst_size - 1;
    while (in < src_max && src[in] != '\0' && out < out_limit) {
        const unsigned char ch = static_cast<unsigned char>(src[in]);
        if (ch == 0xE2u && in + 2 < src_max && static_cast<unsigned char>(src[in + 1]) == 0x80u) {
            const unsigned char b2 = static_cast<unsigned char>(src[in + 2]);
            if (b2 == 0x98u || b2 == 0x99u) {
                dst[out++] = '\'';
                in += 3;
                continue;
            }
            if (b2 == 0x9Cu || b2 == 0x9Du) {
                dst[out++] = '"';
                in += 3;
                continue;
            }
            if (b2 == 0x93u || b2 == 0x94u) {
                dst[out++] = '-';
                in += 3;
                continue;
            }
            if (b2 == 0xA6u) {
                for (int k = 0; k < 3 && out < out_limit; ++k) dst[out++] = '.';
                in += 3;
                continue;
            }
        }
        if (ch < 0x20u || ch >= 0x7Fu) {
            if (out == 0 || dst[out - 1] != ' ') dst[out++] = ' ';
            ++in;
            while (in < src_max && (static_cast<unsigned char>(src[in]) & 0xC0u) == 0x80u) ++in;
            continue;
        }
        dst[out++] = static_cast<char>(ch);
        ++in;
    }
    while (out > 0 && dst[out - 1] == ' ') --out;
    dst[out] = '\0';
}

inline bool format_action_description(const char* full, char* output,
                                      size_t capacity, size_t max_chars) noexcept {
    if (!full || !output || capacity < 8 || max_chars < 16 || max_chars >= capacity) return false;
    size_t length = 0;
    while (length < capacity && full[length] != '\0') ++length;
    if (length >= capacity) return false;
    if (length <= max_chars) {
        std::memcpy(output, full, length + 1);
        return true;
    }
    size_t cut = max_chars - 3;
    size_t word_cut = cut;
    while (word_cut > max_chars / 2 && full[word_cut] != ' ') --word_cut;
    if (word_cut > max_chars / 2) cut = word_cut;
    while (cut > 0 && full[cut - 1] == ' ') --cut;
    if (cut == 0) return false;
    std::memcpy(output, full, cut);
    std::memcpy(output + cut, "...", 4);
    return true;
}

inline bool validate_and_convert(const SoulspireNativeActionEntry& in, ActionRecord& out) noexcept {
    if (in.size != sizeof(SoulspireNativeActionEntry)) return false;
    if (in.job < 1 || in.job > 22 || !valid_branch(in.job, in.branch)) return false;
    if (!valid_action_kind(in.kind) || !valid_action_id(in.kind, in.action_id)) return false;

    out = {};
    out.job = in.job;
    out.branch = in.branch;
    out.action_id = in.action_id;
    out.kind = in.kind;
    out.icon_id = in.icon_id;
    out.icon_id_v2 = in.icon_id_v2;
    copy_cstr_bounded(out.name, sizeof(out.name), in.name, sizeof(in.name));
    copy_cstr_bounded(out.description, sizeof(out.description), in.description, sizeof(in.description));

    const bool has_name = out.name[0] != '\0';
    const bool has_desc = out.description[0] != '\0';
    const bool has_icon = out.icon_id != 0xFFFFu || out.icon_id_v2 != 0xFFFFu;
    return has_name || has_desc || has_icon;
}

inline bool compact_action_row_name(const char* full, char* output,
                                    size_t capacity, size_t max_chars) noexcept {
    if (!full || !output || capacity < 2 || max_chars < 8 || max_chars >= capacity) return false;
    size_t length = 0;
    while (length < capacity && full[length] != '\0') ++length;
    if (length >= capacity) return false;
    if (length <= max_chars) {
        std::memcpy(output, full, length + 1);
        return true;
    }
    size_t suffix = length;
    for (size_t i = 0; i + 1 < length; ++i) {
        if (full[i] == ':' && full[i + 1] == ' ') suffix = i;
    }
    if (suffix < length && length - suffix < max_chars / 2) {
        const size_t tail = length - suffix;
        const size_t reserved_suffix = (tail < 6) ? 6 : tail;
        const size_t prefix_max = max_chars > reserved_suffix + 1
            ? max_chars - reserved_suffix - 1 : 0;
        if (prefix_max >= 3) {
            size_t end = prefix_max;
            while (end > 0 && (static_cast<unsigned char>(full[end]) & 0xC0u) == 0x80u) --end;
            if (end >= 3) {
                while (end && full[end - 1] == ' ') --end;
                std::memcpy(output, full, end);
                output[end] = '.';
                std::memcpy(output + end + 1, full + suffix, tail);
                output[end + 1 + tail] = '\0';
                return true;
            }
        }
    }
    size_t end = max_chars - 3;
    while (end > 0 && (static_cast<unsigned char>(full[end]) & 0xC0u) == 0x80u) --end;
    if (end == 0) return false;
    std::memcpy(output, full, end);
    std::memcpy(output + end, "...", 4);
    return true;
}

class ActionCatalog {
public:
    static constexpr uint32_t kMaxEntries = 4096;

    bool replace_all(const SoulspireNativeActionEntry* entries, uint32_t count) {
        if (count > kMaxEntries) return false;
        if (count > 0 && entries == nullptr) return false;
        std::vector<ActionRecord> next;
        next.reserve(count);
        for (uint32_t i = 0; i < count; ++i) {
            ActionRecord rec;
            if (!validate_and_convert(entries[i], rec)) return false;
            next.push_back(rec);
        }
        std::sort(next.begin(), next.end(), action_record_less);
        for (size_t i = 1; i < next.size(); ++i) {
            if (action_key_equal(next[i - 1], ActionKey{next[i].job, next[i].branch, next[i].kind, next[i].action_id})) {
                return false;
            }
        }
        records_.swap(next);
        ++generation_;
        return true;
    }

    bool upsert(const SoulspireNativeActionEntry& entry) {
        ActionRecord rec;
        if (!validate_and_convert(entry, rec)) return false;
        const ActionKey key{rec.job, rec.branch, rec.kind, rec.action_id};
        auto it = std::lower_bound(records_.begin(), records_.end(), key, action_key_less);
        if (it != records_.end() && action_key_equal(*it, key)) {
            *it = rec;
        } else {
            if (records_.size() >= kMaxEntries) return false;
            records_.insert(it, rec);
        }
        ++generation_;
        return true;
    }

    void clear() noexcept {
        records_.clear();
        ++generation_;
    }

    const ActionRecord* find(uint8_t job, uint8_t branch, uint32_t kind, uint16_t action_id) const noexcept {
        if (records_.empty() || job == 0 || branch == 0) return nullptr;
        const ActionKey key{job, branch, kind, action_id};
        auto it = std::lower_bound(records_.begin(), records_.end(), key, action_key_less);
        if (it != records_.end() && action_key_equal(*it, key)) {
            return &(*it);
        }
        return nullptr;
    }

    uint32_t count() const noexcept { return static_cast<uint32_t>(records_.size()); }
    uint32_t generation() const noexcept { return generation_; }

private:
    std::vector<ActionRecord> records_;
    uint32_t generation_ = 0;
};

enum class VisibilityDecision : uint8_t {
    Unmanaged = 0,
    Show      = 1,
    Hide      = 2,
};

struct VisibilityRecord {
    uint8_t  job = 0;
    uint8_t  branch = 0;
    uint8_t  min_effective_level = 1;
    uint8_t  rule = SOULSPIRE_NATIVE_VIS_RULE_UNLOCK;
    uint32_t kind = 0;
    uint16_t action_id = 0;
};

inline bool vis_key_less(const VisibilityRecord& a, const ActionKey& b) noexcept {
    if (a.job != b.job) return a.job < b.job;
    if (a.branch != b.branch) return a.branch < b.branch;
    if (a.kind != b.kind) return a.kind < b.kind;
    return a.action_id < b.action_id;
}

inline bool vis_record_less(const VisibilityRecord& a, const VisibilityRecord& b) noexcept {
    return vis_key_less(a, ActionKey{b.job, b.branch, b.kind, b.action_id});
}

inline bool vis_key_equal(const VisibilityRecord& a, const ActionKey& b) noexcept {
    return a.job == b.job && a.branch == b.branch && a.kind == b.kind && a.action_id == b.action_id;
}

inline bool validate_and_convert_visibility(const SoulspireNativeVisibilityEntry& in, VisibilityRecord& out) noexcept {
    if (in.size != sizeof(SoulspireNativeVisibilityEntry)) return false;
    if (in.job < 1 || in.job > 22 || !valid_branch(in.job, in.branch)) return false;
    if (!valid_action_kind(in.kind) || !valid_action_id(in.kind, in.action_id)) return false;
    if (in.min_effective_level < 1 || in.min_effective_level > 99) return false;
    if (in.rule != SOULSPIRE_NATIVE_VIS_RULE_UNLOCK && in.rule != SOULSPIRE_NATIVE_VIS_RULE_HIDDEN) return false;
    out = {};
    out.job = in.job;
    out.branch = in.branch;
    out.min_effective_level = in.min_effective_level;
    out.rule = in.rule;
    out.kind = in.kind;
    out.action_id = in.action_id;
    return true;
}

class VisibilityCatalog {
public:
    static constexpr uint32_t kMaxEntries = 4096;

    bool replace_all(const SoulspireNativeVisibilityEntry* entries, uint32_t count) {
        if (count > kMaxEntries) return false;
        if (count > 0 && entries == nullptr) return false;
        std::vector<VisibilityRecord> next;
        next.reserve(count);
        for (uint32_t i = 0; i < count; ++i) {
            VisibilityRecord rec;
            if (!validate_and_convert_visibility(entries[i], rec)) return false;
            next.push_back(rec);
        }
        std::sort(next.begin(), next.end(), vis_record_less);
        for (size_t i = 1; i < next.size(); ++i) {
            if (vis_key_equal(next[i - 1], ActionKey{next[i].job, next[i].branch, next[i].kind, next[i].action_id})) {
                return false;
            }
        }
        records_.swap(next);
        ++generation_;
        return true;
    }

    void clear() noexcept {
        records_.clear();
        ++generation_;
    }

    VisibilityDecision decide(uint8_t job, uint8_t branch, uint32_t kind, uint16_t action_id, uint8_t effective_level) const noexcept {
        if (records_.empty() || job == 0 || branch == 0 || effective_level == 0) return VisibilityDecision::Unmanaged;
        const ActionKey key{job, branch, kind, action_id};
        auto it = std::lower_bound(records_.begin(), records_.end(), key, vis_key_less);
        if (it == records_.end() || !vis_key_equal(*it, key)) return VisibilityDecision::Unmanaged;
        if (it->rule == SOULSPIRE_NATIVE_VIS_RULE_HIDDEN || effective_level < it->min_effective_level) {
            return VisibilityDecision::Hide;
        }
        return VisibilityDecision::Show;
    }

    uint32_t count() const noexcept { return static_cast<uint32_t>(records_.size()); }
    uint32_t generation() const noexcept { return generation_; }

private:
    std::vector<VisibilityRecord> records_;
    uint32_t generation_ = 0;
};

} // namespace soulspire::native
