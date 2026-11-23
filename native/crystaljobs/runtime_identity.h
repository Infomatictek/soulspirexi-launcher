#pragma once
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace crystaljobs {

static constexpr uint32_t kIdentitySchemaVersion = 1;
static constexpr uint32_t kPresentationSchemaVersion = 1;
static constexpr size_t   kMaxIdentityFileBytes = 65536;
static constexpr size_t   kMaxPresentationFileBytes = 8192;
static constexpr size_t   kMaxSoulNameLen = 31;
static constexpr int32_t  kMinTrackingPx = -2;
static constexpr int32_t  kMaxTrackingPx = 2;
static constexpr int32_t  kMinOffsetXPx = -2;
static constexpr int32_t  kMaxOffsetXPx = 3;
static constexpr int32_t  kMinGlyphX0 = -2;
static constexpr int32_t  kMaxGlyphX0 = 21;
static constexpr size_t   kGlyphX0Span = static_cast<size_t>(kMaxGlyphX0 - kMinGlyphX0 + 1); // 24

enum IdentityLoadStatus : uint32_t {
    IDENTITY_STATUS_COMPILED_FALLBACK = 0,
    IDENTITY_STATUS_RUNTIME_LOADED    = 1,
    IDENTITY_STATUS_FILE_MISSING      = 2,
    IDENTITY_STATUS_FILE_TOO_LARGE    = 3,
    IDENTITY_STATUS_PARSE_ERROR       = 4,
    IDENTITY_STATUS_BAD_SCHEMA        = 5,
    IDENTITY_STATUS_BAD_COUNT         = 6,
    IDENTITY_STATUS_BAD_ENTRY         = 7,
    IDENTITY_STATUS_DUPLICATE_SLOT    = 8,
    IDENTITY_STATUS_DUPLICATE_ABBR    = 9,
    IDENTITY_STATUS_BAD_INTEGRITY     = 10,
};

struct RuntimeSoulEntry {
    bool present;
    char name[32];
    char abbr[4];
};

struct RuntimeIdentityTable {
    bool active;
    uint32_t schema_version;
    uint32_t soul_count;
    uint32_t status;
    char registry_version[64];
    char registry_hash[24];
    char integrity_hex[24];
    char warning[128];
    RuntimeSoulEntry entries[23][4]; // job 1..22, branch 1..3
};

struct SearchPresentationConfig {
    bool from_file;
    uint32_t schema_version;
    int32_t tracking_px;
    int32_t offset_x_px;
    bool use_glyph_widths;
    char warning[128];
};

inline SearchPresentationConfig default_presentation_config() noexcept {
    SearchPresentationConfig cfg{};
    cfg.from_file = false;
    cfg.schema_version = kPresentationSchemaVersion;
    cfg.tracking_px = -1;
    cfg.offset_x_px = 0;
    cfg.use_glyph_widths = true;
    return cfg;
}

namespace detail {

struct JsonCursor {
    const char* p;
    const char* end;

    void skip_ws() noexcept {
        while (p < end && (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n')) ++p;
    }

    bool consume(char ch) noexcept {
        skip_ws();
        if (p < end && *p == ch) { ++p; return true; }
        return false;
    }

    bool parse_string(char* out, size_t out_cap) noexcept {
        skip_ws();
        if (p >= end || *p != '"') return false;
        ++p;
        size_t n = 0;
        while (p < end) {
            const unsigned char c = static_cast<unsigned char>(*p++);
            if (c == '"') {
                if (out != nullptr && out_cap > 0) out[n] = '\0';
                return true;
            }
            if (c < 0x20u) return false;
            char ch = static_cast<char>(c);
            if (c == '\\') {
                if (p >= end) return false;
                const char esc = *p++;
                switch (esc) {
                    case '"':  ch = '"'; break;
                    case '\\': ch = '\\'; break;
                    case '/':  ch = '/'; break;
                    case 'b':  ch = '\b'; break;
                    case 'f':  ch = '\f'; break;
                    case 'n':  ch = '\n'; break;
                    case 'r':  ch = '\r'; break;
                    case 't':  ch = '\t'; break;
                    default: return false;
                }
            }
            if (out != nullptr && out_cap > 0) {
                if (n + 1 >= out_cap) return false; // Reject overlong strings
                out[n++] = ch;
            }
        }
        return false;
    }

    bool parse_int(int64_t& out) noexcept {
        skip_ws();
        if (p >= end) return false;
        bool neg = false;
        if (*p == '-') { neg = true; ++p; }
        if (p >= end || *p < '0' || *p > '9') return false;
        int64_t val = 0;
        int digits = 0;
        while (p < end && *p >= '0' && *p <= '9') {
            if (++digits > 12) return false;
            val = val * 10 + (*p - '0');
            ++p;
        }
        if (p < end && (*p == '.' || *p == 'e' || *p == 'E')) return false;
        out = neg ? -val : val;
        return true;
    }

    bool parse_bool(bool& out) noexcept {
        skip_ws();
        if (end - p >= 4 && std::memcmp(p, "true", 4) == 0) { p += 4; out = true; return true; }
        if (end - p >= 5 && std::memcmp(p, "false", 5) == 0) { p += 5; out = false; return true; }
        return false;
    }

    bool skip_value(int depth = 0) noexcept {
        if (depth > 8) return false;
        skip_ws();
        if (p >= end) return false;
        const char c = *p;
        if (c == '"') return parse_string(nullptr, 0);
        if (c == '{') {
            ++p;
            if (consume('}')) return true;
            for (;;) {
                if (!parse_string(nullptr, 0)) return false;
                if (!consume(':')) return false;
                if (!skip_value(depth + 1)) return false;
                if (consume(',')) continue;
                return consume('}');
            }
        }
        if (c == '[') {
            ++p;
            if (consume(']')) return true;
            for (;;) {
                if (!skip_value(depth + 1)) return false;
                if (consume(',')) continue;
                return consume(']');
            }
        }
        if (c == 't' && end - p >= 4 && std::memcmp(p, "true", 4) == 0) { p += 4; return true; }
        if (c == 'f' && end - p >= 5 && std::memcmp(p, "false", 5) == 0) { p += 5; return true; }
        if (c == 'n' && end - p >= 4 && std::memcmp(p, "null", 4) == 0) { p += 4; return true; }
        if (c == '-' || (c >= '0' && c <= '9')) {
            if (*p == '-') ++p;
            if (p >= end || *p < '0' || *p > '9') return false;
            while (p < end && ((*p >= '0' && *p <= '9') || *p == '.' || *p == 'e' || *p == 'E' || *p == '+' || *p == '-')) ++p;
            return true;
        }
        return false;
    }
};

inline bool is_lower_hex16(const char* s) noexcept {
    if (s == nullptr || std::strlen(s) != 16) return false;
    for (size_t i = 0; i < 16; ++i) {
        const char c = s[i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
    }
    return true;
}

inline bool is_valid_soul_name(const char* s) noexcept {
    if (s == nullptr) return false;
    const size_t n = std::strlen(s);
    if (n == 0 || n > kMaxSoulNameLen) return false;
    for (size_t i = 0; i < n; ++i) {
        const unsigned char c = static_cast<unsigned char>(s[i]);
        if (c < 0x20u || c > 0x7Eu) return false;
    }
    return true;
}

inline bool is_valid_abbr(const char* s) noexcept {
    if (s == nullptr || std::strlen(s) != 3) return false;
    for (size_t i = 0; i < 3; ++i) {
        if (s[i] < 'A' || s[i] > 'Z') return false;
    }
    return true;
}

inline uint64_t compute_table_fnv1a64(const RuntimeIdentityTable& table) noexcept {
    uint64_t h = 0xCBF29CE484222325ULL;
    constexpr uint64_t prime = 0x100000001B3ULL;
    for (uint8_t j = 1; j <= 22; ++j) {
        for (uint8_t b = 1; b <= 3; ++b) {
            const auto& e = table.entries[j][b];
            char line[64]{};
            const int len = std::snprintf(line, sizeof(line), "%u:%u:%s:%s\n",
                static_cast<unsigned>(j), static_cast<unsigned>(b), e.abbr, e.name);
            if (len <= 0) continue;
            for (int i = 0; i < len; ++i) {
                h ^= static_cast<uint8_t>(line[i]);
                h *= prime;
            }
        }
    }
    return h;
}

} // namespace detail

inline bool parse_runtime_identity_json(
    const char* data,
    size_t len,
    RuntimeIdentityTable& out) noexcept {
    std::memset(&out, 0, sizeof(out));
    if (data == nullptr || len == 0) {
        out.status = IDENTITY_STATUS_FILE_MISSING;
        std::snprintf(out.warning, sizeof(out.warning), "soul-identities.json is empty or missing");
        return false;
    }
    if (len > kMaxIdentityFileBytes) {
        out.status = IDENTITY_STATUS_FILE_TOO_LARGE;
        std::snprintf(out.warning, sizeof(out.warning), "soul-identities.json exceeds 64 KiB limit");
        return false;
    }
    // Skip optional UTF-8 BOM
    if (len >= 3 && static_cast<uint8_t>(data[0]) == 0xEF &&
        static_cast<uint8_t>(data[1]) == 0xBB && static_cast<uint8_t>(data[2]) == 0xBF) {
        data += 3;
        len -= 3;
    }

    detail::JsonCursor cur{data, data + len};
    if (!cur.consume('{')) {
        out.status = IDENTITY_STATUS_PARSE_ERROR;
        std::snprintf(out.warning, sizeof(out.warning), "soul-identities.json root is not a JSON object");
        return false;
    }

    bool seen_schema = false, seen_count = false, seen_souls = false;
    int64_t declared_schema = 0, declared_count = 0;
    uint32_t parsed_souls = 0;
    char seen_abbrs[66][4]{};

    if (!cur.consume('}')) {
        for (;;) {
            char key[48]{};
            if (!cur.parse_string(key, sizeof(key)) || !cur.consume(':')) {
                out.status = IDENTITY_STATUS_PARSE_ERROR;
                std::snprintf(out.warning, sizeof(out.warning), "malformed key in soul-identities.json");
                return false;
            }
            if (std::strcmp(key, "schemaVersion") == 0) {
                if (!cur.parse_int(declared_schema)) {
                    out.status = IDENTITY_STATUS_BAD_SCHEMA;
                    std::snprintf(out.warning, sizeof(out.warning), "invalid schemaVersion type");
                    return false;
                }
                seen_schema = true;
            } else if (std::strcmp(key, "registryVersion") == 0) {
                if (!cur.parse_string(out.registry_version, sizeof(out.registry_version))) {
                    out.status = IDENTITY_STATUS_PARSE_ERROR;
                    std::snprintf(out.warning, sizeof(out.warning), "invalid registryVersion");
                    return false;
                }
            } else if (std::strcmp(key, "registryHash") == 0) {
                if (!cur.parse_string(out.registry_hash, sizeof(out.registry_hash))) {
                    out.status = IDENTITY_STATUS_PARSE_ERROR;
                    std::snprintf(out.warning, sizeof(out.warning), "invalid registryHash");
                    return false;
                }
            } else if (std::strcmp(key, "integrityFnv1a64") == 0) {
                if (!cur.parse_string(out.integrity_hex, sizeof(out.integrity_hex))) {
                    out.status = IDENTITY_STATUS_PARSE_ERROR;
                    std::snprintf(out.warning, sizeof(out.warning), "invalid integrityFnv1a64");
                    return false;
                }
            } else if (std::strcmp(key, "soulCount") == 0) {
                if (!cur.parse_int(declared_count)) {
                    out.status = IDENTITY_STATUS_BAD_COUNT;
                    std::snprintf(out.warning, sizeof(out.warning), "invalid soulCount type");
                    return false;
                }
                seen_count = true;
            } else if (std::strcmp(key, "souls") == 0) {
                if (seen_souls || !cur.consume('[')) {
                    out.status = IDENTITY_STATUS_PARSE_ERROR;
                    std::snprintf(out.warning, sizeof(out.warning), "invalid souls array");
                    return false;
                }
                seen_souls = true;
                if (!cur.consume(']')) {
                    for (;;) {
                        if (parsed_souls >= 66) {
                            out.status = IDENTITY_STATUS_BAD_COUNT;
                            std::snprintf(out.warning, sizeof(out.warning), "souls array exceeds 66 entries");
                            return false;
                        }
                        if (!cur.consume('{')) {
                            out.status = IDENTITY_STATUS_PARSE_ERROR;
                            std::snprintf(out.warning, sizeof(out.warning), "soul entry is not an object");
                            return false;
                        }
                        int64_t jid = 0, bid = 0;
                        bool has_j = false, has_b = false, has_n = false, has_a = false;
                        char name_buf[32]{}, abbr_buf[8]{};
                        if (!cur.consume('}')) {
                            for (;;) {
                                char ek[32]{};
                                if (!cur.parse_string(ek, sizeof(ek)) || !cur.consume(':')) {
                                    out.status = IDENTITY_STATUS_PARSE_ERROR;
                                    std::snprintf(out.warning, sizeof(out.warning), "malformed soul entry key");
                                    return false;
                                }
                                if (std::strcmp(ek, "jobId") == 0) {
                                    if (!cur.parse_int(jid)) { out.status = IDENTITY_STATUS_BAD_ENTRY; return false; }
                                    has_j = true;
                                } else if (std::strcmp(ek, "branch") == 0) {
                                    if (!cur.parse_int(bid)) { out.status = IDENTITY_STATUS_BAD_ENTRY; return false; }
                                    has_b = true;
                                } else if (std::strcmp(ek, "name") == 0) {
                                    if (!cur.parse_string(name_buf, sizeof(name_buf))) {
                                        out.status = IDENTITY_STATUS_BAD_ENTRY;
                                        std::snprintf(out.warning, sizeof(out.warning), "overlong or invalid soul name");
                                        return false;
                                    }
                                    has_n = true;
                                } else if (std::strcmp(ek, "abbr") == 0) {
                                    if (!cur.parse_string(abbr_buf, sizeof(abbr_buf))) {
                                        out.status = IDENTITY_STATUS_BAD_ENTRY;
                                        std::snprintf(out.warning, sizeof(out.warning), "invalid soul abbr");
                                        return false;
                                    }
                                    has_a = true;
                                } else {
                                    if (!cur.skip_value()) { out.status = IDENTITY_STATUS_PARSE_ERROR; return false; }
                                }
                                if (cur.consume(',')) continue;
                                if (!cur.consume('}')) { out.status = IDENTITY_STATUS_PARSE_ERROR; return false; }
                                break;
                            }
                        }
                        if (!has_j || !has_b || !has_n || !has_a ||
                            jid < 1 || jid > 22 || bid < 1 || bid > 3 ||
                            !detail::is_valid_soul_name(name_buf) ||
                            !detail::is_valid_abbr(abbr_buf)) {
                            out.status = IDENTITY_STATUS_BAD_ENTRY;
                            std::snprintf(out.warning, sizeof(out.warning), "invalid soul entry fields or bounds");
                            return false;
                        }
                        auto& slot = out.entries[jid][bid];
                        if (slot.present) {
                            out.status = IDENTITY_STATUS_DUPLICATE_SLOT;
                            std::snprintf(out.warning, sizeof(out.warning), "duplicate (jobId=%lld, branch=%lld)", jid, bid);
                            return false;
                        }
                        for (uint32_t k = 0; k < parsed_souls; ++k) {
                            if (std::strcmp(seen_abbrs[k], abbr_buf) == 0) {
                                out.status = IDENTITY_STATUS_DUPLICATE_ABBR;
                                std::snprintf(out.warning, sizeof(out.warning), "duplicate abbreviation %s", abbr_buf);
                                return false;
                            }
                        }
                        slot.present = true;
                        std::memcpy(slot.name, name_buf, sizeof(slot.name));
                        std::memcpy(slot.abbr, abbr_buf, 4);
                        std::memcpy(seen_abbrs[parsed_souls], abbr_buf, 4);
                        ++parsed_souls;

                        if (cur.consume(',')) continue;
                        if (!cur.consume(']')) { out.status = IDENTITY_STATUS_PARSE_ERROR; return false; }
                        break;
                    }
                }
            } else {
                if (!cur.skip_value()) {
                    out.status = IDENTITY_STATUS_PARSE_ERROR;
                    std::snprintf(out.warning, sizeof(out.warning), "malformed value in soul-identities.json");
                    return false;
                }
            }
            if (cur.consume(',')) continue;
            if (!cur.consume('}')) {
                out.status = IDENTITY_STATUS_PARSE_ERROR;
                std::snprintf(out.warning, sizeof(out.warning), "unterminated root object");
                return false;
            }
            break;
        }
    }

    if (!seen_schema || declared_schema != static_cast<int64_t>(kIdentitySchemaVersion)) {
        out.status = IDENTITY_STATUS_BAD_SCHEMA;
        std::snprintf(out.warning, sizeof(out.warning), "unsupported schemaVersion=%lld", declared_schema);
        return false;
    }
    if (!seen_count || !seen_souls || declared_count != 66 || parsed_souls != 66) {
        out.status = IDENTITY_STATUS_BAD_COUNT;
        std::snprintf(out.warning, sizeof(out.warning), "expected 66 souls, got %u", parsed_souls);
        return false;
    }
    if (!detail::is_lower_hex16(out.registry_hash) || !detail::is_lower_hex16(out.integrity_hex)) {
        out.status = IDENTITY_STATUS_BAD_INTEGRITY;
        std::snprintf(out.warning, sizeof(out.warning), "invalid registryHash or integrityFnv1a64 format");
        return false;
    }
    const uint64_t actual_fnv = detail::compute_table_fnv1a64(out);
    char expected_hex[24]{};
    std::snprintf(expected_hex, sizeof(expected_hex), "%016llx", static_cast<unsigned long long>(actual_fnv));
    if (std::strcmp(expected_hex, out.integrity_hex) != 0) {
        out.status = IDENTITY_STATUS_BAD_INTEGRITY;
        std::snprintf(out.warning, sizeof(out.warning), "integrityFnv1a64 mismatch");
        return false;
    }

    out.active = true;
    out.schema_version = kIdentitySchemaVersion;
    out.soul_count = parsed_souls;
    out.status = IDENTITY_STATUS_RUNTIME_LOADED;
    out.warning[0] = '\0';
    return true;
}

inline bool parse_presentation_config_json(
    const char* data,
    size_t len,
    SearchPresentationConfig& out) noexcept {
    out = default_presentation_config();
    if (data == nullptr || len == 0 || len > kMaxPresentationFileBytes) {
        std::snprintf(out.warning, sizeof(out.warning), "presentation config missing or oversized; using defaults");
        return false;
    }
    if (len >= 3 && static_cast<uint8_t>(data[0]) == 0xEF &&
        static_cast<uint8_t>(data[1]) == 0xBB && static_cast<uint8_t>(data[2]) == 0xBF) {
        data += 3;
        len -= 3;
    }
    detail::JsonCursor cur{data, data + len};
    if (!cur.consume('{')) {
        std::snprintf(out.warning, sizeof(out.warning), "presentation config root is not an object");
        return false;
    }
    bool seen_schema = false;
    int64_t schema = 0;
    int64_t tracking = out.tracking_px;
    int64_t offset_x = out.offset_x_px;
    bool use_widths = out.use_glyph_widths;

    if (!cur.consume('}')) {
        for (;;) {
            char key[48]{};
            if (!cur.parse_string(key, sizeof(key)) || !cur.consume(':')) {
                std::snprintf(out.warning, sizeof(out.warning), "malformed key in presentation config");
                return false;
            }
            if (std::strcmp(key, "schemaVersion") == 0) {
                if (!cur.parse_int(schema)) return false;
                seen_schema = true;
            } else if (std::strcmp(key, "searchBadge") == 0) {
                if (!cur.consume('{')) return false;
                if (!cur.consume('}')) {
                    for (;;) {
                        char bk[48]{};
                        if (!cur.parse_string(bk, sizeof(bk)) || !cur.consume(':')) return false;
                        if (std::strcmp(bk, "trackingPx") == 0) {
                            if (!cur.parse_int(tracking)) return false;
                        } else if (std::strcmp(bk, "offsetXPx") == 0) {
                            if (!cur.parse_int(offset_x)) return false;
                        } else if (std::strcmp(bk, "useGlyphWidths") == 0) {
                            if (!cur.parse_bool(use_widths)) return false;
                        } else {
                            if (!cur.skip_value()) return false;
                        }
                        if (cur.consume(',')) continue;
                        if (!cur.consume('}')) return false;
                        break;
                    }
                }
            } else {
                if (!cur.skip_value()) return false;
            }
            if (cur.consume(',')) continue;
            if (!cur.consume('}')) return false;
            break;
        }
    }
    if (!seen_schema || schema != static_cast<int64_t>(kPresentationSchemaVersion)) {
        std::snprintf(out.warning, sizeof(out.warning), "unsupported presentation schemaVersion=%lld", schema);
        return false;
    }
    if (tracking < kMinTrackingPx || tracking > kMaxTrackingPx ||
        offset_x < kMinOffsetXPx || offset_x > kMaxOffsetXPx) {
        std::snprintf(out.warning, sizeof(out.warning), "presentation spacing out of safe bounds");
        return false;
    }
    out.from_file = true;
    out.schema_version = kPresentationSchemaVersion;
    out.tracking_px = static_cast<int32_t>(tracking);
    out.offset_x_px = static_cast<int32_t>(offset_x);
    out.use_glyph_widths = use_widths;
    out.warning[0] = '\0';
    return true;
}

} // namespace crystaljobs
