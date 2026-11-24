#pragma once
#include "../core/api.h"
#include "../core/config.h"
#include "../actions/action_catalog.h"
#include <Windows.h>
#include <algorithm>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace soulspire::native {

static constexpr size_t kMaxDatTextFileBytes = 256u * 1024u;
static constexpr size_t kMaxDatTextOverrides = 512u;

struct DatTextOverrideRecord {
    uint8_t  job = 0;
    uint8_t  branch = 0;
    uint8_t  kind = 0;       // 1=spell, 2=ability, 3=weaponskill
    uint8_t  reserved = 0;
    uint16_t action_id = 0;
    uint16_t icon_id = 0;    // 0 = unchanged
    uint16_t icon_id_v2 = 0; // 0 = unchanged
    char     name[48]{};
    char     description[224]{};
};

struct DatTextOverrideTable {
    uint32_t schema_version = 0;
    char     registry_hash[24]{};
    char     integrity_hex[20]{};
    char     warning[96]{};
    std::vector<DatTextOverrideRecord> records;
};

namespace detail_dat_virt {

inline void skip_ws(const char* s, size_t len, size_t& pos) noexcept {
    while (pos < len) {
        const char c = s[pos];
        if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
            ++pos;
        } else {
            break;
        }
    }
}

inline bool parse_json_string(const char* s, size_t len, size_t& pos, char* out, size_t out_cap) noexcept {
    skip_ws(s, len, pos);
    if (pos >= len || s[pos] != '"') return false;
    ++pos;
    size_t w = 0;
    while (pos < len) {
        char c = s[pos++];
        if (c == '"') {
            if (out != nullptr && out_cap > 0) {
                out[w < out_cap ? w : (out_cap - 1)] = '\0';
            }
            return true;
        }
        if (c == '\\') {
            if (pos >= len) return false;
            const char esc = s[pos++];
            switch (esc) {
                case '"':  c = '"'; break;
                case '\\': c = '\\'; break;
                case '/':  c = '/'; break;
                case 'n':  c = ' '; break;
                case 'r':  c = ' '; break;
                case 't':  c = ' '; break;
                case 'u':
                    if (pos + 4 > len) return false;
                    pos += 4;
                    c = '?';
                    break;
                default:
                    c = esc;
                    break;
            }
        }
        const auto uc = static_cast<unsigned char>(c);
        if (uc < 0x20u || uc >= 0x7Fu) c = ' ';
        if (out != nullptr && w + 1 < out_cap) {
            out[w++] = c;
        }
    }
    return false;
}

inline bool parse_json_uint(const char* s, size_t len, size_t& pos, uint32_t& out) noexcept {
    skip_ws(s, len, pos);
    if (pos >= len || s[pos] < '0' || s[pos] > '9') return false;
    uint32_t val = 0;
    while (pos < len && s[pos] >= '0' && s[pos] <= '9') {
        const uint32_t digit = static_cast<uint32_t>(s[pos++] - '0');
        if (val > 429496729u) return false;
        val = val * 10u + digit;
    }
    out = val;
    return true;
}

inline bool skip_json_value(const char* s, size_t len, size_t& pos, int depth = 0) noexcept {
    if (depth > 8) return false;
    skip_ws(s, len, pos);
    if (pos >= len) return false;
    const char c = s[pos];
    if (c == '"') {
        return parse_json_string(s, len, pos, nullptr, 0);
    }
    if (c == '{') {
        ++pos;
        skip_ws(s, len, pos);
        if (pos < len && s[pos] == '}') { ++pos; return true; }
        while (pos < len) {
            if (!parse_json_string(s, len, pos, nullptr, 0)) return false;
            skip_ws(s, len, pos);
            if (pos >= len || s[pos] != ':') return false;
            ++pos;
            if (!skip_json_value(s, len, pos, depth + 1)) return false;
            skip_ws(s, len, pos);
            if (pos < len && s[pos] == ',') { ++pos; continue; }
            if (pos < len && s[pos] == '}') { ++pos; return true; }
            return false;
        }
        return false;
    }
    if (c == '[') {
        ++pos;
        skip_ws(s, len, pos);
        if (pos < len && s[pos] == ']') { ++pos; return true; }
        while (pos < len) {
            if (!skip_json_value(s, len, pos, depth + 1)) return false;
            skip_ws(s, len, pos);
            if (pos < len && s[pos] == ',') { ++pos; continue; }
            if (pos < len && s[pos] == ']') { ++pos; return true; }
            return false;
        }
        return false;
    }
    while (pos < len) {
        const char ch = s[pos];
        if (ch == ',' || ch == '}' || ch == ']' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') break;
        ++pos;
    }
    return true;
}

inline uint64_t record_sort_key(const DatTextOverrideRecord& r) noexcept {
    return (static_cast<uint64_t>(r.job) << 32) |
           (static_cast<uint64_t>(r.branch) << 24) |
           (static_cast<uint64_t>(r.kind) << 16) |
           static_cast<uint64_t>(r.action_id);
}

inline uint64_t compute_fnv1a64(const std::vector<DatTextOverrideRecord>& sorted) noexcept {
    uint64_t h = 14695981039346656037ULL;
    char line[360]{};
    for (const auto& r : sorted) {
        const int n = std::snprintf(
            line, sizeof(line), "%u:%u:%u:%u:%s:%s:%u:%u\n",
            static_cast<unsigned>(r.job),
            static_cast<unsigned>(r.branch),
            static_cast<unsigned>(r.kind),
            static_cast<unsigned>(r.action_id),
            r.name,
            r.description,
            static_cast<unsigned>(r.icon_id),
            static_cast<unsigned>(r.icon_id_v2));
        if (n <= 0) continue;
        const size_t count = static_cast<size_t>(n) < sizeof(line) ? static_cast<size_t>(n) : (sizeof(line) - 1u);
        for (size_t i = 0; i < count; ++i) {
            h ^= static_cast<uint8_t>(line[i]);
            h *= 1099511628211ULL;
        }
    }
    return h;
}

inline void format_hex64(uint64_t v, char* out, size_t out_cap) noexcept {
    if (out == nullptr || out_cap < 17) return;
    std::snprintf(out, out_cap, "%016llx", static_cast<unsigned long long>(v));
}

} // namespace detail_dat_virt

inline bool parse_dat_text_overrides_json(const char* data, size_t len, DatTextOverrideTable& out) noexcept {
    out = {};
    auto fail = [&](const char* msg) -> bool {
        std::snprintf(out.warning, sizeof(out.warning), "%s", msg);
        out.records.clear();
        return false;
    };

    if (data == nullptr || len == 0 || len > kMaxDatTextFileBytes) {
        return fail("dat-text-overrides.json empty or exceeds 256KB limit");
    }

    size_t pos = 0;
    detail_dat_virt::skip_ws(data, len, pos);
    if (pos >= len || data[pos] != '{') return fail("dat-text-overrides.json root must be object");
    ++pos;

    uint32_t declared_count = 0;
    bool has_schema = false;
    bool has_count = false;
    bool has_hash = false;
    bool has_fnv = false;
    bool has_overrides = false;

    while (pos < len) {
        detail_dat_virt::skip_ws(data, len, pos);
        if (pos < len && data[pos] == '}') { ++pos; break; }
        char key[48]{};
        if (!detail_dat_virt::parse_json_string(data, len, pos, key, sizeof(key))) {
            return fail("malformed key in dat-text-overrides.json");
        }
        detail_dat_virt::skip_ws(data, len, pos);
        if (pos >= len || data[pos] != ':') return fail("expected ':' in dat-text-overrides.json");
        ++pos;

        if (std::strcmp(key, "schemaVersion") == 0) {
            if (!detail_dat_virt::parse_json_uint(data, len, pos, out.schema_version)) return fail("invalid schemaVersion");
            has_schema = true;
        } else if (std::strcmp(key, "overrideCount") == 0) {
            if (!detail_dat_virt::parse_json_uint(data, len, pos, declared_count)) return fail("invalid overrideCount");
            has_count = true;
        } else if (std::strcmp(key, "registryHash") == 0) {
            if (!detail_dat_virt::parse_json_string(data, len, pos, out.registry_hash, sizeof(out.registry_hash))) {
                return fail("invalid registryHash");
            }
            has_hash = true;
        } else if (std::strcmp(key, "integrityFnv1a64") == 0) {
            if (!detail_dat_virt::parse_json_string(data, len, pos, out.integrity_hex, sizeof(out.integrity_hex))) {
                return fail("invalid integrityFnv1a64");
            }
            has_fnv = true;
        } else if (std::strcmp(key, "overrides") == 0) {
            detail_dat_virt::skip_ws(data, len, pos);
            if (pos >= len || data[pos] != '[') return fail("overrides must be array");
            ++pos;
            has_overrides = true;
            out.records.clear();

            detail_dat_virt::skip_ws(data, len, pos);
            if (pos < len && data[pos] == ']') {
                ++pos;
            } else {
                while (pos < len) {
                    detail_dat_virt::skip_ws(data, len, pos);
                    if (pos >= len || data[pos] != '{') return fail("override entry must be object");
                    ++pos;

                    DatTextOverrideRecord rec{};
                    uint32_t job_u = 0, branch_u = 0, kind_u = 0, aid_u = 0, icon1_u = 0, icon2_u = 0;
                    bool got_job = false, got_branch = false, got_kind = false, got_aid = false;

                    while (pos < len) {
                        detail_dat_virt::skip_ws(data, len, pos);
                        if (pos < len && data[pos] == '}') { ++pos; break; }
                        char fkey[32]{};
                        if (!detail_dat_virt::parse_json_string(data, len, pos, fkey, sizeof(fkey))) {
                            return fail("malformed override field key");
                        }
                        detail_dat_virt::skip_ws(data, len, pos);
                        if (pos >= len || data[pos] != ':') return fail("expected ':' in override entry");
                        ++pos;

                        if (std::strcmp(fkey, "jobId") == 0) {
                            if (!detail_dat_virt::parse_json_uint(data, len, pos, job_u)) return fail("invalid jobId");
                            got_job = true;
                        } else if (std::strcmp(fkey, "branch") == 0) {
                            if (!detail_dat_virt::parse_json_uint(data, len, pos, branch_u)) return fail("invalid branch");
                            got_branch = true;
                        } else if (std::strcmp(fkey, "kind") == 0) {
                            if (!detail_dat_virt::parse_json_uint(data, len, pos, kind_u)) return fail("invalid kind");
                            got_kind = true;
                        } else if (std::strcmp(fkey, "actionId") == 0) {
                            if (!detail_dat_virt::parse_json_uint(data, len, pos, aid_u)) return fail("invalid actionId");
                            got_aid = true;
                        } else if (std::strcmp(fkey, "iconId") == 0) {
                            if (!detail_dat_virt::parse_json_uint(data, len, pos, icon1_u)) return fail("invalid iconId");
                        } else if (std::strcmp(fkey, "iconIdV2") == 0) {
                            if (!detail_dat_virt::parse_json_uint(data, len, pos, icon2_u)) return fail("invalid iconIdV2");
                        } else if (std::strcmp(fkey, "name") == 0) {
                            if (!detail_dat_virt::parse_json_string(data, len, pos, rec.name, sizeof(rec.name))) {
                                return fail("invalid override name");
                            }
                        } else if (std::strcmp(fkey, "description") == 0) {
                            if (!detail_dat_virt::parse_json_string(data, len, pos, rec.description, sizeof(rec.description))) {
                                return fail("invalid override description");
                            }
                        } else {
                            if (!detail_dat_virt::skip_json_value(data, len, pos)) return fail("malformed unknown override field");
                        }

                        detail_dat_virt::skip_ws(data, len, pos);
                        if (pos < len && data[pos] == ',') { ++pos; continue; }
                        if (pos < len && data[pos] == '}') { ++pos; break; }
                        return fail("expected ',' or '}' in override object");
                    }

                    if (!got_job || !got_branch || !got_kind || !got_aid ||
                        job_u < 1u || job_u > 22u || branch_u < 1u || branch_u > 7u ||
                        kind_u < 1u || kind_u > 3u || aid_u > 0xFFFFu ||
                        !valid_action_id(kind_u, static_cast<uint16_t>(aid_u))) {
                        return fail("override entry out of valid job/branch/kind/actionId bounds");
                    }
                    if (out.records.size() >= kMaxDatTextOverrides) {
                        return fail("dat-text-overrides.json exceeds max override limit (512)");
                    }
                    rec.job = static_cast<uint8_t>(job_u);
                    rec.branch = static_cast<uint8_t>(branch_u);
                    rec.kind = static_cast<uint8_t>(kind_u);
                    rec.action_id = static_cast<uint16_t>(aid_u);
                    rec.icon_id = static_cast<uint16_t>(icon1_u > 0xFFFFu ? 0u : icon1_u);
                    rec.icon_id_v2 = static_cast<uint16_t>(icon2_u > 0xFFFFu ? 0u : icon2_u);
                    out.records.push_back(rec);

                    detail_dat_virt::skip_ws(data, len, pos);
                    if (pos < len && data[pos] == ',') { ++pos; continue; }
                    if (pos < len && data[pos] == ']') { ++pos; break; }
                    return fail("expected ',' or ']' in overrides array");
                }
            }
        } else {
            if (!detail_dat_virt::skip_json_value(data, len, pos)) return fail("malformed top-level field");
        }

        detail_dat_virt::skip_ws(data, len, pos);
        if (pos < len && data[pos] == ',') { ++pos; continue; }
        if (pos < len && data[pos] == '}') { ++pos; break; }
        return fail("expected ',' or '}' at root");
    }

    if (!has_schema || out.schema_version != 1u) return fail("unsupported schemaVersion (expected 1)");
    if (!has_count || !has_hash || !has_fnv || !has_overrides) return fail("missing required metadata fields");
    if (declared_count != out.records.size()) return fail("overrideCount does not match parsed overrides length");

    std::sort(out.records.begin(), out.records.end(), [](const DatTextOverrideRecord& a, const DatTextOverrideRecord& b) {
        return detail_dat_virt::record_sort_key(a) < detail_dat_virt::record_sort_key(b);
    });

    for (size_t i = 1; i < out.records.size(); ++i) {
        if (detail_dat_virt::record_sort_key(out.records[i - 1]) == detail_dat_virt::record_sort_key(out.records[i])) {
            return fail("duplicate (jobId, branch, kind, actionId) override detected");
        }
    }

    char computed_hex[20]{};
    detail_dat_virt::format_hex64(detail_dat_virt::compute_fnv1a64(out.records), computed_hex, sizeof(computed_hex));
    if (std::strcmp(computed_hex, out.integrity_hex) != 0) {
        return fail("integrityFnv1a64 mismatch (corrupt or tampered dat-text-overrides.json)");
    }

    return true;
}

class DatVirtualizationManager {
public:
    static constexpr uint32_t kSchemaVersion = 1;

    void configure(bool enabled_flag) noexcept {
        enabled_.store(enabled_flag, std::memory_order_release);
    }

    bool is_enabled() const noexcept {
        return enabled_.load(std::memory_order_acquire);
    }

    uint32_t generation() const noexcept {
        return generation_.load(std::memory_order_acquire);
    }

    uint32_t override_count() const noexcept {
        return override_count_.load(std::memory_order_acquire);
    }

    bool load_from_json(const char* data, size_t len, bool from_file_flag = true) noexcept {
        DatTextOverrideTable parsed{};
        if (!parse_dat_text_overrides_json(data, len, parsed)) {
            AcquireSRWLockExclusive(&lock_);
            std::snprintf(warning_, sizeof(warning_), "%s", parsed.warning);
            ReleaseSRWLockExclusive(&lock_);
            return false;
        }
        AcquireSRWLockExclusive(&lock_);
        records_ = std::move(parsed.records);
        std::snprintf(registry_hash_, sizeof(registry_hash_), "%s", parsed.registry_hash);
        std::snprintf(integrity_hex_, sizeof(integrity_hex_), "%s", parsed.integrity_hex);
        warning_[0] = '\0';
        loaded_from_file_ = from_file_flag;
        override_count_.store(static_cast<uint32_t>(records_.size()), std::memory_order_release);
        generation_.fetch_add(1u, std::memory_order_acq_rel);
        ReleaseSRWLockExclusive(&lock_);
        return true;
    }

    void record_missing(const char* msg) noexcept {
        AcquireSRWLockExclusive(&lock_);
        std::snprintf(warning_, sizeof(warning_), "%s", msg != nullptr ? msg : "dat-text-overrides.json not found");
        ReleaseSRWLockExclusive(&lock_);
    }

    bool lookup_text(uint8_t job, uint8_t branch, uint32_t kind, uint16_t action_id, bool want_desc,
                     char* out, size_t out_cap) noexcept {
        if (!is_enabled() || out == nullptr || out_cap == 0) return false;
        const uint64_t target =
            (static_cast<uint64_t>(job) << 32) |
            (static_cast<uint64_t>(branch) << 24) |
            (static_cast<uint64_t>(kind) << 16) |
            static_cast<uint64_t>(action_id);

        bool matched = false;
        AcquireSRWLockShared(&lock_);
        size_t lo = 0, hi = records_.size();
        while (lo < hi) {
            const size_t mid = lo + (hi - lo) / 2;
            const uint64_t key = detail_dat_virt::record_sort_key(records_[mid]);
            if (key < target) lo = mid + 1;
            else hi = mid;
        }
        if (lo < records_.size() && detail_dat_virt::record_sort_key(records_[lo]) == target) {
            const char* src = want_desc ? records_[lo].description : records_[lo].name;
            if (src[0] != '\0') {
                std::snprintf(out, out_cap, "%s", src);
                matched = true;
            }
        }
        ReleaseSRWLockShared(&lock_);
        if (matched) {
            hits_.fetch_add(1u, std::memory_order_relaxed);
        } else {
            misses_.fetch_add(1u, std::memory_order_relaxed);
        }
        return matched;
    }

    bool lookup_icon(uint8_t job, uint8_t branch, uint32_t kind, uint16_t action_id,
                     uint32_t& icon_v1, uint32_t& icon_v2) noexcept {
        if (!is_enabled()) return false;
        const uint64_t target =
            (static_cast<uint64_t>(job) << 32) |
            (static_cast<uint64_t>(branch) << 24) |
            (static_cast<uint64_t>(kind) << 16) |
            static_cast<uint64_t>(action_id);

        bool overridden = false;
        AcquireSRWLockShared(&lock_);
        size_t lo = 0, hi = records_.size();
        while (lo < hi) {
            const size_t mid = lo + (hi - lo) / 2;
            const uint64_t key = detail_dat_virt::record_sort_key(records_[mid]);
            if (key < target) lo = mid + 1;
            else hi = mid;
        }
        if (lo < records_.size() && detail_dat_virt::record_sort_key(records_[lo]) == target) {
            if (records_[lo].icon_id != 0u) { icon_v1 = records_[lo].icon_id; overridden = true; }
            if (records_[lo].icon_id_v2 != 0u) { icon_v2 = records_[lo].icon_id_v2; overridden = true; }
        }
        ReleaseSRWLockShared(&lock_);
        return overridden;
    }

    void fill_status(SoulspireNativeDatVirtStatus& st) noexcept {
        st = {};
        st.size = sizeof(st);
        st.schema_version = kSchemaVersion;
        st.enabled = is_enabled() ? 1u : 0u;
        st.override_count = override_count();
        st.generation = generation();
        st.hits = hits_.load(std::memory_order_relaxed);
        st.misses = misses_.load(std::memory_order_relaxed);
        AcquireSRWLockShared(&lock_);
        st.loaded_from_file = loaded_from_file_ ? 1u : 0u;
        std::snprintf(st.registry_hash, sizeof(st.registry_hash), "%s", registry_hash_);
        std::snprintf(st.integrity_fnv1a64, sizeof(st.integrity_fnv1a64), "%s", integrity_hex_);
        std::snprintf(st.warning, sizeof(st.warning), "%s", warning_);
        ReleaseSRWLockShared(&lock_);
    }

    void reset() noexcept {
        AcquireSRWLockExclusive(&lock_);
        records_.clear();
        loaded_from_file_ = false;
        registry_hash_[0] = '\0';
        integrity_hex_[0] = '\0';
        warning_[0] = '\0';
        override_count_.store(0u, std::memory_order_release);
        generation_.fetch_add(1u, std::memory_order_acq_rel);
        hits_.store(0u, std::memory_order_relaxed);
        misses_.store(0u, std::memory_order_relaxed);
        ReleaseSRWLockExclusive(&lock_);
    }

private:
    SRWLOCK lock_ = SRWLOCK_INIT;
    std::vector<DatTextOverrideRecord> records_;
    bool loaded_from_file_ = false;
    char registry_hash_[24]{};
    char integrity_hex_[20]{};
    char warning_[96]{};
    std::atomic<bool> enabled_{true};
    std::atomic<uint32_t> generation_{0};
    std::atomic<uint32_t> override_count_{0};
    std::atomic<uint32_t> hits_{0};
    std::atomic<uint32_t> misses_{0};
};

} // namespace soulspire::native
