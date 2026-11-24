#pragma once
#include "../core/api.h"
#include "../registry/runtime_identity.h"
#include "../rendering/weapon_presentation.h"
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

namespace soulspire::native {

static constexpr uint32_t kWeaponConfigSchemaVersion = 1;
static constexpr size_t   kMaxWeaponConfigFileBytes  = 131072;

enum WeaponConfigLoadStatus : uint32_t {
    WEAPON_CFG_NOT_LOADED        = 0,
    WEAPON_CFG_RUNTIME_LOADED    = 1,
    WEAPON_CFG_FILE_MISSING      = 2,
    WEAPON_CFG_FILE_TOO_LARGE    = 3,
    WEAPON_CFG_PARSE_ERROR       = 4,
    WEAPON_CFG_BAD_SCHEMA        = 5,
    WEAPON_CFG_BAD_REGISTRY_HASH = 6,
    WEAPON_CFG_BAD_INTEGRITY     = 7,
};

struct ParsedAppearanceMask {
    char    soul_id[32]{};
    uint8_t job = 0;
    uint8_t branch = 0;
    bool    hide_main = false;
    bool    hide_sub = false;
};

struct ParsedRangedOnly {
    char    soul_id[32]{};
    uint8_t job = 0;
    uint8_t branch = 0;
    bool    firearm_only = false;
    bool    auto_facing = false;
    char    overlay_id[64]{};
};

struct ParsedWeaponConfig {
    bool     valid = false;
    uint32_t status = WEAPON_CFG_NOT_LOADED;
    uint32_t schema_version = 0;
    char     registry_hash[24]{};
    char     weapon_config_hash[24]{};
    char     integrity_fnv1a64[24]{};
    char     warning[128]{};
    std::vector<SoulspireNativeWeaponRule> native_rules{};
    std::vector<SoulWeaponBinding>         bindings{};
    std::vector<PresentationProfileRecord> profiles{};
    std::vector<ParsedAppearanceMask>      appearance_masks{};
    std::vector<ParsedRangedOnly>          ranged_only{};
};

namespace detail {

inline bool parse_json_float(JsonCursor& cur, float& out) noexcept {
    cur.skip_ws();
    if (cur.p >= cur.end) return false;
    const char* start = cur.p;
    if (*cur.p == '-') ++cur.p;
    if (cur.p >= cur.end || *cur.p < '0' || *cur.p > '9') return false;
    while (cur.p < cur.end && *cur.p >= '0' && *cur.p <= '9') ++cur.p;
    if (cur.p < cur.end && *cur.p == '.') {
        ++cur.p;
        if (cur.p >= cur.end || *cur.p < '0' || *cur.p > '9') return false;
        while (cur.p < cur.end && *cur.p >= '0' && *cur.p <= '9') ++cur.p;
    }
    if (cur.p < cur.end && (*cur.p == 'e' || *cur.p == 'E')) {
        ++cur.p;
        if (cur.p < cur.end && (*cur.p == '+' || *cur.p == '-')) ++cur.p;
        if (cur.p >= cur.end || *cur.p < '0' || *cur.p > '9') return false;
        while (cur.p < cur.end && *cur.p >= '0' && *cur.p <= '9') ++cur.p;
    }
    const size_t n = static_cast<size_t>(cur.p - start);
    if (n == 0 || n >= 48) return false;
    char tmp[48]{};
    std::memcpy(tmp, start, n);
    char* endptr = nullptr;
    const double val = std::strtod(tmp, &endptr);
    if (endptr != tmp + n || !std::isfinite(val)) return false;
    out = static_cast<float>(val);
    return true;
}

inline bool parse_vec12_transform(JsonCursor& cur, WeaponAttachmentTransform& out) noexcept {
    if (!cur.consume('[')) return false;
    float vals[12]{};
    for (int i = 0; i < 12; ++i) {
        if (!parse_json_float(cur, vals[i])) return false;
        if (i + 1 < 12 && !cur.consume(',')) return false;
    }
    if (!cur.consume(']')) return false;
    out.tx = vals[0];
    out.ty = vals[1];
    out.tz = vals[2];
    out.pitch_deg = vals[3];
    out.yaw_deg = vals[4];
    out.roll_deg = vals[5];
    out.grip_x = vals[6];
    out.grip_y = vals[7];
    out.grip_z = vals[8];
    out.scale = vals[9];
    out.weapon_separation = vals[10];
    out.back_depth = vals[11];
    return out.scale >= 0.25f && out.scale <= 2.5f;
}

inline void fnv1a64_feed(uint64_t& h, const char* s, size_t n) noexcept {
    constexpr uint64_t prime = 0x100000001B3ULL;
    for (size_t i = 0; i < n; ++i) {
        h ^= static_cast<uint8_t>(s[i]);
        h *= prime;
    }
}

inline void fnv1a64_feed_str(uint64_t& h, const char* s) noexcept {
    fnv1a64_feed(h, s, std::strlen(s));
}

inline const char* profile_kind_name(PresentationProfileKind k) noexcept {
    switch (k) {
        case PresentationProfileKind::Dual2HAttachments: return "dual_2h_attachments";
        case PresentationProfileKind::RangedDualPistolOverlay: return "ranged_dual_pistol_overlay";
        case PresentationProfileKind::TwoHandShieldAttachments: return "twohand_shield_attachments";
        case PresentationProfileKind::Dual1HAttachments: return "dual_1h_attachments";
        default: return "unknown";
    }
}

inline PresentationProfileKind parse_profile_kind(const char* s) noexcept {
    if (s == nullptr) return PresentationProfileKind::Unknown;
    if (std::strcmp(s, "dual_2h_attachments") == 0) return PresentationProfileKind::Dual2HAttachments;
    if (std::strcmp(s, "ranged_dual_pistol_overlay") == 0) return PresentationProfileKind::RangedDualPistolOverlay;
    if (std::strcmp(s, "twohand_shield_attachments") == 0) return PresentationProfileKind::TwoHandShieldAttachments;
    if (std::strcmp(s, "dual_1h_attachments") == 0) return PresentationProfileKind::Dual1HAttachments;
    return PresentationProfileKind::Unknown;
}

inline int32_t round_ten_thousandths(float v) noexcept {
    const double scaled = static_cast<double>(v) * 10000.0;
    return static_cast<int32_t>(std::llround(scaled));
}

inline void append_transform_ten_thousandths(uint64_t& h, const WeaponAttachmentTransform& t, bool leading_comma) noexcept {
    char buf[256]{};
    const int n = std::snprintf(
        buf, sizeof(buf),
        "%s%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d,%d",
        leading_comma ? "," : "",
        round_ten_thousandths(t.tx),
        round_ten_thousandths(t.ty),
        round_ten_thousandths(t.tz),
        round_ten_thousandths(t.pitch_deg),
        round_ten_thousandths(t.yaw_deg),
        round_ten_thousandths(t.roll_deg),
        round_ten_thousandths(t.grip_x),
        round_ten_thousandths(t.grip_y),
        round_ten_thousandths(t.grip_z),
        round_ten_thousandths(t.scale),
        round_ten_thousandths(t.weapon_separation),
        round_ten_thousandths(t.back_depth));
    if (n > 0) fnv1a64_feed(h, buf, static_cast<size_t>(n));
}

inline uint64_t compute_weapon_config_fnv1a64(const ParsedWeaponConfig& cfg,
                                              const std::vector<std::array<char, 48>>& rule_profile_names) noexcept {
    uint64_t h = 0xCBF29CE484222325ULL;
    char line[256]{};
    for (size_t i = 0; i < cfg.bindings.size(); ++i) {
        const auto& b = cfg.bindings[i];
        const char* pname = (i < rule_profile_names.size()) ? rule_profile_names[i].data() : "";
        const int n = std::snprintf(
            line, sizeof(line),
            "R:%s:%u:%u:%u:%u:%u:%u:%u:%u:%s\n",
            b.soul_id,
            static_cast<unsigned>(b.job),
            static_cast<unsigned>(b.branch),
            static_cast<unsigned>(b.min_effective_level),
            static_cast<unsigned>(b.mode),
            static_cast<unsigned>(b.main_skill_mask),
            static_cast<unsigned>(b.sub_skill_mask),
            static_cast<unsigned>(b.main_item_id),
            static_cast<unsigned>(b.sub_item_id),
            pname);
        if (n > 0) fnv1a64_feed(h, line, static_cast<size_t>(n));
    }
    for (const auto& a : cfg.appearance_masks) {
        const int n = std::snprintf(
            line, sizeof(line),
            "A:%s:%u:%u:%u:%u\n",
            a.soul_id,
            static_cast<unsigned>(a.job),
            static_cast<unsigned>(a.branch),
            a.hide_main ? 1u : 0u,
            a.hide_sub ? 1u : 0u);
        if (n > 0) fnv1a64_feed(h, line, static_cast<size_t>(n));
    }
    for (const auto& g : cfg.ranged_only) {
        const int n = std::snprintf(
            line, sizeof(line),
            "G:%s:%u:%u:%u:%u:%s\n",
            g.soul_id,
            static_cast<unsigned>(g.job),
            static_cast<unsigned>(g.branch),
            g.firearm_only ? 1u : 0u,
            g.auto_facing ? 1u : 0u,
            g.overlay_id);
        if (n > 0) fnv1a64_feed(h, line, static_cast<size_t>(n));
    }
    for (const auto& p : cfg.profiles) {
        const unsigned race_count = p.has_races ? 8u : 0u;
        const int n = std::snprintf(
            line, sizeof(line),
            "P:%s:%s:%u:%u\n",
            p.id,
            profile_kind_name(p.kind),
            p.visual_certified ? 1u : 0u,
            race_count);
        if (n > 0) fnv1a64_feed(h, line, static_cast<size_t>(n));
        if (p.has_races) {
            for (size_t r = 0; r < 8; ++r) {
                const int tn = std::snprintf(line, sizeof(line), "T:%u:", static_cast<unsigned>(r + 1));
                if (tn > 0) fnv1a64_feed(h, line, static_cast<size_t>(tn));
                append_transform_ten_thousandths(h, p.races[r].drawn_main, false);
                append_transform_ten_thousandths(h, p.races[r].drawn_sub, true);
                append_transform_ten_thousandths(h, p.races[r].sheathed_main, true);
                append_transform_ten_thousandths(h, p.races[r].sheathed_sub, true);
                fnv1a64_feed_str(h, "\n");
            }
        }
    }
    return h;
}

} // namespace detail

inline bool parse_weapon_config_json(
    const char* data,
    size_t len,
    const char* expected_registry_hash,
    ParsedWeaponConfig& out) {
    out = {};
    if (data == nullptr || len == 0) {
        out.status = WEAPON_CFG_FILE_MISSING;
        std::snprintf(out.warning, sizeof(out.warning), "soul-weapon-config.json empty or missing");
        return false;
    }
    if (len > kMaxWeaponConfigFileBytes) {
        out.status = WEAPON_CFG_FILE_TOO_LARGE;
        std::snprintf(out.warning, sizeof(out.warning), "soul-weapon-config.json exceeds size limit");
        return false;
    }

    detail::JsonCursor cur{data, data + len};
    if (!cur.consume('{')) {
        out.status = WEAPON_CFG_PARSE_ERROR;
        std::snprintf(out.warning, sizeof(out.warning), "expected JSON object");
        return false;
    }

    bool got_schema = false, got_hash = false, got_fnv64 = false;
    std::vector<std::array<char, 48>> rule_profile_names{};

    if (!cur.consume('}')) {
        for (;;) {
            char key[64]{};
            if (!cur.parse_string(key, sizeof(key)) || !cur.consume(':')) {
                out.status = WEAPON_CFG_PARSE_ERROR;
                std::snprintf(out.warning, sizeof(out.warning), "malformed root property");
                return false;
            }
            if (std::strcmp(key, "schemaVersion") == 0) {
                int64_t v = 0;
                if (!cur.parse_int(v) || v < 0) {
                    out.status = WEAPON_CFG_PARSE_ERROR;
                    return false;
                }
                out.schema_version = static_cast<uint32_t>(v);
                got_schema = true;
            } else if (std::strcmp(key, "registryHash") == 0) {
                if (!cur.parse_string(out.registry_hash, sizeof(out.registry_hash))) {
                    out.status = WEAPON_CFG_PARSE_ERROR;
                    return false;
                }
                got_hash = true;
            } else if (std::strcmp(key, "weaponConfigHash") == 0) {
                if (!cur.parse_string(out.weapon_config_hash, sizeof(out.weapon_config_hash))) {
                    out.status = WEAPON_CFG_PARSE_ERROR;
                    return false;
                }
            } else if (std::strcmp(key, "integrityFnv1a64") == 0) {
                if (!cur.parse_string(out.integrity_fnv1a64, sizeof(out.integrity_fnv1a64))) {
                    out.status = WEAPON_CFG_PARSE_ERROR;
                    return false;
                }
                got_fnv64 = true;
            } else if (std::strcmp(key, "rules") == 0) {
                if (!cur.consume('[')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                if (!cur.consume(']')) {
                    for (;;) {
                        if (!cur.consume('{')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                        SoulWeaponBinding b{};
                        std::array<char, 48> pname{};
                        if (!cur.consume('}')) {
                            for (;;) {
                                char rk[48]{};
                                if (!cur.parse_string(rk, sizeof(rk)) || !cur.consume(':')) {
                                    out.status = WEAPON_CFG_PARSE_ERROR;
                                    return false;
                                }
                                int64_t iv = 0;
                                if (std::strcmp(rk, "soulId") == 0) {
                                    if (!cur.parse_string(b.soul_id, sizeof(b.soul_id))) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(rk, "jobId") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 22) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.job = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(rk, "branch") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 3) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.branch = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(rk, "minEffectiveLevel") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 99) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.min_effective_level = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(rk, "modeId") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 3) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.mode = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(rk, "mainSkillMask") == 0) {
                                    if (!cur.parse_int(iv) || iv <= 0) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.main_skill_mask = static_cast<uint32_t>(iv);
                                } else if (std::strcmp(rk, "subSkillMask") == 0) {
                                    if (!cur.parse_int(iv) || iv <= 0) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.sub_skill_mask = static_cast<uint32_t>(iv);
                                } else if (std::strcmp(rk, "mainItemId") == 0) {
                                    if (!cur.parse_int(iv) || iv < 0 || iv > 65535) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.main_item_id = static_cast<uint16_t>(iv);
                                } else if (std::strcmp(rk, "subItemId") == 0) {
                                    if (!cur.parse_int(iv) || iv < 0 || iv > 65535) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    b.sub_item_id = static_cast<uint16_t>(iv);
                                } else if (std::strcmp(rk, "presentationProfile") == 0) {
                                    if (!cur.parse_string(pname.data(), pname.size())) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else {
                                    if (!cur.skip_value()) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                }
                                if (cur.consume(',')) continue;
                                if (cur.consume('}')) break;
                                out.status = WEAPON_CFG_PARSE_ERROR;
                                return false;
                            }
                        }
                        if (b.soul_id[0] == '\0' || b.job == 0 || b.branch == 0 || b.mode == 0 ||
                            b.main_skill_mask == 0 || b.sub_skill_mask == 0 ||
                            out.bindings.size() >= WeaponPresentationManager::kMaxBindings) {
                            out.status = WEAPON_CFG_PARSE_ERROR;
                            return false;
                        }
                        SoulspireNativeWeaponRule nr{};
                        nr.size = sizeof(SoulspireNativeWeaponRule);
                        nr.job = b.job;
                        nr.branch = b.branch;
                        nr.min_effective_level = b.min_effective_level;
                        nr.mode = b.mode;
                        nr.main_skill_mask = b.main_skill_mask;
                        nr.sub_skill_mask = b.sub_skill_mask;
                        nr.main_item_id = b.main_item_id;
                        nr.sub_item_id = b.sub_item_id;
                        out.native_rules.push_back(nr);
                        out.bindings.push_back(b);
                        rule_profile_names.push_back(pname);
                        if (cur.consume(',')) continue;
                        if (cur.consume(']')) break;
                        out.status = WEAPON_CFG_PARSE_ERROR;
                        return false;
                    }
                }
            } else if (std::strcmp(key, "appearanceMasks") == 0) {
                if (!cur.consume('[')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                if (!cur.consume(']')) {
                    for (;;) {
                        if (!cur.consume('{')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                        ParsedAppearanceMask am{};
                        if (!cur.consume('}')) {
                            for (;;) {
                                char ak[48]{};
                                if (!cur.parse_string(ak, sizeof(ak)) || !cur.consume(':')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                int64_t iv = 0;
                                if (std::strcmp(ak, "soulId") == 0) {
                                    if (!cur.parse_string(am.soul_id, sizeof(am.soul_id))) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(ak, "jobId") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 22) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    am.job = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(ak, "branch") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 3) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    am.branch = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(ak, "hideMain") == 0) {
                                    if (!cur.parse_bool(am.hide_main)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(ak, "hideSub") == 0) {
                                    if (!cur.parse_bool(am.hide_sub)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else {
                                    if (!cur.skip_value()) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                }
                                if (cur.consume(',')) continue;
                                if (cur.consume('}')) break;
                                out.status = WEAPON_CFG_PARSE_ERROR;
                                return false;
                            }
                        }
                        out.appearance_masks.push_back(am);
                        if (cur.consume(',')) continue;
                        if (cur.consume(']')) break;
                        out.status = WEAPON_CFG_PARSE_ERROR;
                        return false;
                    }
                }
            } else if (std::strcmp(key, "rangedOnly") == 0) {
                if (!cur.consume('[')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                if (!cur.consume(']')) {
                    for (;;) {
                        if (!cur.consume('{')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                        ParsedRangedOnly ro{};
                        if (!cur.consume('}')) {
                            for (;;) {
                                char gk[48]{};
                                if (!cur.parse_string(gk, sizeof(gk)) || !cur.consume(':')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                int64_t iv = 0;
                                if (std::strcmp(gk, "soulId") == 0) {
                                    if (!cur.parse_string(ro.soul_id, sizeof(ro.soul_id))) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(gk, "jobId") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 22) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    ro.job = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(gk, "branch") == 0) {
                                    if (!cur.parse_int(iv) || iv < 1 || iv > 3) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    ro.branch = static_cast<uint8_t>(iv);
                                } else if (std::strcmp(gk, "firearmOnly") == 0) {
                                    if (!cur.parse_bool(ro.firearm_only)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(gk, "autoFacing") == 0) {
                                    if (!cur.parse_bool(ro.auto_facing)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(gk, "overlayId") == 0) {
                                    if (!cur.parse_string(ro.overlay_id, sizeof(ro.overlay_id))) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else {
                                    if (!cur.skip_value()) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                }
                                if (cur.consume(',')) continue;
                                if (cur.consume('}')) break;
                                out.status = WEAPON_CFG_PARSE_ERROR;
                                return false;
                            }
                        }
                        out.ranged_only.push_back(ro);
                        if (cur.consume(',')) continue;
                        if (cur.consume(']')) break;
                        out.status = WEAPON_CFG_PARSE_ERROR;
                        return false;
                    }
                }
            } else if (std::strcmp(key, "presentationProfiles") == 0) {
                if (!cur.consume('[')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                if (!cur.consume(']')) {
                    for (;;) {
                        if (!cur.consume('{')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                        PresentationProfileRecord prof{};
                        uint8_t race_seen_mask = 0;
                        if (!cur.consume('}')) {
                            for (;;) {
                                char pk[48]{};
                                if (!cur.parse_string(pk, sizeof(pk)) || !cur.consume(':')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                if (std::strcmp(pk, "id") == 0) {
                                    if (!cur.parse_string(prof.id, sizeof(prof.id))) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(pk, "kind") == 0) {
                                    char ks[48]{};
                                    if (!cur.parse_string(ks, sizeof(ks))) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    prof.kind = detail::parse_profile_kind(ks);
                                } else if (std::strcmp(pk, "visualCertified") == 0) {
                                    if (!cur.parse_bool(prof.visual_certified)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(pk, "requiresNative3dBoneHook") == 0) {
                                    if (!cur.parse_bool(prof.requires_native_3d_bone_hook)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                } else if (std::strcmp(pk, "races") == 0) {
                                    if (!cur.consume('[')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                    if (!cur.consume(']')) {
                                        for (;;) {
                                            if (!cur.consume('{')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                            int64_t race_id = 0;
                                            RaceWeaponTransformSet rset{};
                                            bool g_dm = false, g_ds = false, g_sm = false, g_ss = false;
                                            if (!cur.consume('}')) {
                                                for (;;) {
                                                    char fk[48]{};
                                                    if (!cur.parse_string(fk, sizeof(fk)) || !cur.consume(':')) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                                    if (std::strcmp(fk, "raceId") == 0) {
                                                        if (!cur.parse_int(race_id) || race_id < 1 || race_id > 8) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                                    } else if (std::strcmp(fk, "drawnMain") == 0) {
                                                        if (!detail::parse_vec12_transform(cur, rset.drawn_main)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                                        g_dm = true;
                                                    } else if (std::strcmp(fk, "drawnSub") == 0) {
                                                        if (!detail::parse_vec12_transform(cur, rset.drawn_sub)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                                        g_ds = true;
                                                    } else if (std::strcmp(fk, "sheathedMain") == 0) {
                                                        if (!detail::parse_vec12_transform(cur, rset.sheathed_main)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                                        g_sm = true;
                                                    } else if (std::strcmp(fk, "sheathedSub") == 0) {
                                                        if (!detail::parse_vec12_transform(cur, rset.sheathed_sub)) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                                        g_ss = true;
                                                    } else {
                                                        if (!cur.skip_value()) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                                    }
                                                    if (cur.consume(',')) continue;
                                                    if (cur.consume('}')) break;
                                                    out.status = WEAPON_CFG_PARSE_ERROR;
                                                    return false;
                                                }
                                            }
                                            if (race_id < 1 || race_id > 8 || !g_dm || !g_ds || !g_sm || !g_ss) {
                                                out.status = WEAPON_CFG_PARSE_ERROR;
                                                return false;
                                            }
                                            prof.races[static_cast<size_t>(race_id - 1)] = rset;
                                            race_seen_mask = static_cast<uint8_t>(race_seen_mask | (1u << (race_id - 1)));
                                            if (cur.consume(',')) continue;
                                            if (cur.consume(']')) break;
                                            out.status = WEAPON_CFG_PARSE_ERROR;
                                            return false;
                                        }
                                    }
                                    if (race_seen_mask != 0xFFu) {
                                        out.status = WEAPON_CFG_PARSE_ERROR;
                                        std::snprintf(out.warning, sizeof(out.warning), "incomplete playable race set");
                                        return false;
                                    }
                                    prof.has_races = true;
                                } else {
                                    if (!cur.skip_value()) { out.status = WEAPON_CFG_PARSE_ERROR; return false; }
                                }
                                if (cur.consume(',')) continue;
                                if (cur.consume('}')) break;
                                out.status = WEAPON_CFG_PARSE_ERROR;
                                return false;
                            }
                        }
                        if (prof.id[0] == '\0' || prof.kind == PresentationProfileKind::Unknown ||
                            out.profiles.size() >= WeaponPresentationManager::kMaxProfiles) {
                            out.status = WEAPON_CFG_PARSE_ERROR;
                            return false;
                        }
                        out.profiles.push_back(prof);
                        if (cur.consume(',')) continue;
                        if (cur.consume(']')) break;
                        out.status = WEAPON_CFG_PARSE_ERROR;
                        return false;
                    }
                }
            } else {
                if (!cur.skip_value()) {
                    out.status = WEAPON_CFG_PARSE_ERROR;
                    return false;
                }
            }
            if (cur.consume(',')) continue;
            if (cur.consume('}')) break;
            out.status = WEAPON_CFG_PARSE_ERROR;
            return false;
        }
    }

    if (!got_schema || out.schema_version != kWeaponConfigSchemaVersion) {
        out.status = WEAPON_CFG_BAD_SCHEMA;
        std::snprintf(out.warning, sizeof(out.warning), "unsupported soul-weapon-config.json schemaVersion");
        return false;
    }
    if (!got_hash || !detail::is_lower_hex16(out.registry_hash)) {
        out.status = WEAPON_CFG_BAD_REGISTRY_HASH;
        std::snprintf(out.warning, sizeof(out.warning), "invalid registryHash format");
        return false;
    }
    if (expected_registry_hash != nullptr && expected_registry_hash[0] != '\0' &&
        std::strcmp(out.registry_hash, expected_registry_hash) != 0) {
        out.status = WEAPON_CFG_BAD_REGISTRY_HASH;
        std::snprintf(out.warning, sizeof(out.warning), "stale registryHash in soul-weapon-config.json");
        return false;
    }
    if (!got_fnv64 || !detail::is_lower_hex16(out.integrity_fnv1a64)) {
        out.status = WEAPON_CFG_BAD_INTEGRITY;
        std::snprintf(out.warning, sizeof(out.warning), "missing or malformed integrityFnv1a64");
        return false;
    }

    // Link each rule binding to its named presentationProfile (if specified).
    for (size_t i = 0; i < out.bindings.size(); ++i) {
        const char* pname = rule_profile_names[i].data();
        if (pname[0] != '\0') {
            int32_t found = -1;
            for (size_t p = 0; p < out.profiles.size(); ++p) {
                if (std::strcmp(out.profiles[p].id, pname) == 0) {
                    found = static_cast<int32_t>(p);
                    break;
                }
            }
            if (found < 0) {
                out.status = WEAPON_CFG_PARSE_ERROR;
                std::snprintf(out.warning, sizeof(out.warning), "binding references unknown presentationProfile");
                return false;
            }
            out.bindings[i].presentation_profile_index = found;
        }
    }

    // Verify FNV-1a64 integrity digest across all parsed rules, masks, rangedOnly, and presentationProfiles.
    const uint64_t computed = detail::compute_weapon_config_fnv1a64(out, rule_profile_names);
    char expected_hex[24]{};
    std::snprintf(expected_hex, sizeof(expected_hex), "%016llx", static_cast<unsigned long long>(computed));
    if (std::strcmp(expected_hex, out.integrity_fnv1a64) != 0) {
        out.status = WEAPON_CFG_BAD_INTEGRITY;
        std::snprintf(out.warning, sizeof(out.warning), "soul-weapon-config.json integrityFnv1a64 mismatch");
        return false;
    }

    out.valid = true;
    out.status = WEAPON_CFG_RUNTIME_LOADED;
    return true;
}

// Optional developer-only calibration file loader (plugins/data/soul-weapon-calibration.local.json).
// Strictly inert unless diagnosticsEnabled == true in the file.
inline bool apply_weapon_calibration_json(
    const char* data,
    size_t len,
    WeaponPresentationManager& mgr) {
    if (data == nullptr || len == 0 || len > kMaxWeaponConfigFileBytes || !mgr.loaded()) {
        return false;
    }
    detail::JsonCursor cur{data, data + len};
    if (!cur.consume('{')) return false;

    bool diag_enabled = false;
    struct PendingOverride {
        char profile_id[48]{};
        PlayableRace race = PlayableRace::Unknown;
        RaceWeaponTransformSet set{};
    };
    std::vector<PendingOverride> pending{};

    if (!cur.consume('}')) {
        for (;;) {
            char key[64]{};
            if (!cur.parse_string(key, sizeof(key)) || !cur.consume(':')) return false;
            if (std::strcmp(key, "diagnosticsEnabled") == 0) {
                if (!cur.parse_bool(diag_enabled)) return false;
            } else if (std::strcmp(key, "overrides") == 0) {
                if (!cur.consume('[')) return false;
                if (!cur.consume(']')) {
                    for (;;) {
                        if (!cur.consume('{')) return false;
                        PendingOverride ov{};
                        bool g_dm = false, g_ds = false, g_sm = false, g_ss = false;
                        int64_t rid = 0;
                        if (!cur.consume('}')) {
                            for (;;) {
                                char ok[48]{};
                                if (!cur.parse_string(ok, sizeof(ok)) || !cur.consume(':')) return false;
                                if (std::strcmp(ok, "profileId") == 0) {
                                    if (!cur.parse_string(ov.profile_id, sizeof(ov.profile_id))) return false;
                                } else if (std::strcmp(ok, "raceId") == 0) {
                                    if (!cur.parse_int(rid) || rid < 1 || rid > 8) return false;
                                    ov.race = static_cast<PlayableRace>(rid);
                                } else if (std::strcmp(ok, "drawnMain") == 0) {
                                    if (!detail::parse_vec12_transform(cur, ov.set.drawn_main)) return false;
                                    g_dm = true;
                                } else if (std::strcmp(ok, "drawnSub") == 0) {
                                    if (!detail::parse_vec12_transform(cur, ov.set.drawn_sub)) return false;
                                    g_ds = true;
                                } else if (std::strcmp(ok, "sheathedMain") == 0) {
                                    if (!detail::parse_vec12_transform(cur, ov.set.sheathed_main)) return false;
                                    g_sm = true;
                                } else if (std::strcmp(ok, "sheathedSub") == 0) {
                                    if (!detail::parse_vec12_transform(cur, ov.set.sheathed_sub)) return false;
                                    g_ss = true;
                                } else {
                                    if (!cur.skip_value()) return false;
                                }
                                if (cur.consume(',')) continue;
                                if (cur.consume('}')) break;
                                return false;
                            }
                        }
                        if (ov.profile_id[0] != '\0' && valid_playable_race(ov.race) && g_dm && g_ds && g_sm && g_ss) {
                            pending.push_back(ov);
                        }
                        if (cur.consume(',')) continue;
                        if (cur.consume(']')) break;
                        return false;
                    }
                }
            } else {
                if (!cur.skip_value()) return false;
            }
            if (cur.consume(',')) continue;
            if (cur.consume('}')) break;
            return false;
        }
    }

    mgr.set_diagnostics_enabled(diag_enabled);
    if (!diag_enabled) {
        mgr.reset_calibration_overrides();
        return false;
    }
    for (const auto& ov : pending) {
        mgr.set_profile_race_transform_override(ov.profile_id, ov.race, false, false, ov.set.drawn_main);
        mgr.set_profile_race_transform_override(ov.profile_id, ov.race, false, true,  ov.set.drawn_sub);
        mgr.set_profile_race_transform_override(ov.profile_id, ov.race, true,  false, ov.set.sheathed_main);
        mgr.set_profile_race_transform_override(ov.profile_id, ov.race, true,  true,  ov.set.sheathed_sub);
    }
    return !pending.empty();
}

} // namespace soulspire::native
