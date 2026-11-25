#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

namespace soulspire::native {

// Generic, Data-Driven Soul Weapon Presentation Engine (C++17).
//
// Zero hardcoded Soul names, job IDs, branch IDs, level gates, weapon skills,
// or race transform defaults live in this module. All rules, bindings, and
// reusable 8-race presentation profiles are loaded in memory from the
// authoritative registry-generated plugins/data/soul-weapon-config.json.
//
// Guarantees:
//   1. Fail-closed when config is missing, stale, schema-mismatched, or invalid.
//   2. Fail-closed on unknown, expired, or unsynchronized Soul identity.
//   3. Evaluates local actors from confirmed local Soul and remote actors
//      strictly from the observed peer's OXSI Soul (never local player's Soul).
//   4. Resolves actual equipped weapon model IDs dynamically per Main/Sub slot.
//   5. Developer live-adjustment calibration overrides are disabled by default.

enum class PlayableRace : uint8_t {
    Unknown        = 0,
    HumeMale       = 1,
    HumeFemale     = 2,
    ElvaanMale     = 3,
    ElvaanFemale   = 4,
    TarutaruMale   = 5,
    TarutaruFemale = 6,
    Mithra         = 7,
    Galka          = 8,
};

enum class PresentationProfileKind : uint8_t {
    Unknown                  = 0,
    Dual2HAttachments        = 1,
    RangedDualPistolOverlay  = 2,
    TwoHandShieldAttachments = 3,
    Dual1HAttachments        = 4,
};

enum class WeaponPresentationState : uint8_t {
    Vanilla               = 0,
    DrawnDual2H           = 1,
    SheathedCrossX        = 2,
    DrawnTwoHandShield    = 3,
    SheathedTwoHandShield = 4,
    DrawnDual1H           = 5,
    SheathedDual1H        = 6,
};

struct WeaponAttachmentTransform {
    float tx                = 0.0f;
    float ty                = 0.0f;
    float tz                = 0.0f;
    float pitch_deg         = 0.0f;
    float yaw_deg           = 0.0f;
    float roll_deg          = 0.0f;
    float grip_x            = 0.0f;
    float grip_y            = 0.0f;
    float grip_z            = 0.0f;
    float scale             = 1.0f;
    float weapon_separation = 0.0f;
    float back_depth        = 0.0f;
};

struct RaceWeaponTransformSet {
    WeaponAttachmentTransform drawn_main{};
    WeaponAttachmentTransform drawn_sub{};
    WeaponAttachmentTransform sheathed_main{};
    WeaponAttachmentTransform sheathed_sub{};
};

struct PresentationProfileRecord {
    char id[48]{};
    PresentationProfileKind kind = PresentationProfileKind::Unknown;
    bool visual_certified = false;
    bool requires_native_3d_bone_hook = false;
    bool has_races = false;
    std::array<RaceWeaponTransformSet, 8> races{};
};

struct SoulWeaponBinding {
    char     soul_id[32]{};
    uint8_t  job = 0;
    uint8_t  branch = 0;
    uint8_t  min_effective_level = 10;
    uint8_t  mode = 0;
    uint32_t main_skill_mask = 0;
    uint32_t sub_skill_mask = 0;
    uint16_t main_item_id = 0;
    uint16_t sub_item_id = 0;
    int32_t  presentation_profile_index = -1;
};

struct PeerSoulRecord {
    uint32_t actor_id        = 0;
    uint8_t  job             = 0;
    uint8_t  branch          = 0;
    uint8_t  effective_level = 0;
    uint32_t updated_ms      = 0;
    bool     active          = false;
};

struct ActorPresentationQuery {
    uint32_t actor_id        = 0;
    bool     is_local        = false;
    bool     soul_known      = false;
    uint8_t  job             = 0;
    uint8_t  branch          = 0;
    uint8_t  effective_level = 0;
    PlayableRace race        = PlayableRace::Unknown;
    bool     is_engaged      = false;
    bool     is_dead         = false;
    uint16_t main_item_id    = 0;
    uint16_t main_skill      = 0;
    uint16_t main_model_id   = 0;
    uint16_t sub_item_id     = 0;
    uint16_t sub_skill       = 0;
    uint16_t sub_model_id    = 0;
    bool     distinct_items  = true;
    uint32_t now_ms          = 0;
};

struct ActorPresentationDecision {
    WeaponPresentationState state = WeaponPresentationState::Vanilla;
    uint16_t main_model_id        = 0;
    uint16_t sub_model_id         = 0;
    char     soul_id[32]{};
    char     profile_id[48]{};
    WeaponAttachmentTransform main_transform{};
    WeaponAttachmentTransform sub_transform{};
};

class PeerSoulRegistry {
public:
    static constexpr size_t   kMaxPeers = 128;
    static constexpr uint32_t kTtlMs    = 120000u;

    bool upsert(uint32_t actor_id, uint8_t job, uint8_t branch, uint8_t effective_level, uint32_t now_ms) noexcept {
        if (actor_id == 0 || job < 1 || job > 22 || branch < 1 || branch > 3) {
            return false;
        }
        size_t free_slot = kMaxPeers;
        for (size_t i = 0; i < kMaxPeers; ++i) {
            if (entries_[i].active && entries_[i].actor_id == actor_id) {
                entries_[i].job = job;
                entries_[i].branch = branch;
                entries_[i].effective_level = effective_level;
                entries_[i].updated_ms = now_ms;
                return true;
            }
            if (!entries_[i].active && free_slot == kMaxPeers) {
                free_slot = i;
            }
        }
        if (free_slot == kMaxPeers) {
            free_slot = next_evict_++ % kMaxPeers;
        }
        entries_[free_slot] = {actor_id, job, branch, effective_level, now_ms, true};
        return true;
    }

    void revoke(uint32_t actor_id) noexcept {
        if (actor_id == 0) return;
        for (auto& rec : entries_) {
            if (rec.active && rec.actor_id == actor_id) {
                rec = {};
                return;
            }
        }
    }

    void clear() noexcept {
        entries_ = {};
        next_evict_ = 0;
    }

    bool lookup(uint32_t actor_id, uint32_t now_ms, PeerSoulRecord& out) const noexcept {
        if (actor_id == 0) return false;
        for (const auto& rec : entries_) {
            if (rec.active && rec.actor_id == actor_id) {
                if (now_ms - rec.updated_ms > kTtlMs) {
                    return false;
                }
                out = rec;
                return true;
            }
        }
        return false;
    }

private:
    std::array<PeerSoulRecord, kMaxPeers> entries_{};
    size_t next_evict_ = 0;
};

inline bool valid_playable_race(PlayableRace race) noexcept {
    const uint8_t id = static_cast<uint8_t>(race);
    return id >= 1u && id <= 8u;
}

// Exact vanilla FFXiMain.dll (0xD3CB2..0xD3CF1) Sub-slot shield model ranges.
// Shields must ALWAYS resolve from the Sub-slot FTABLE namespace (slot 7).
inline bool is_vanilla_shield_model_id(uint16_t model_id) noexcept {
    return (model_id <= 0x003Fu) ||
           (model_id >= 0x0075u && model_id <= 0x008Fu) ||
           (model_id >= 0x01D7u && model_id <= 0x01FFu) ||
           (model_id >= 0x0280u && model_id <= 0x02BFu) ||
           (model_id >= 0x049Cu && model_id <= 0x04ABu);
}

class WeaponPresentationManager {
public:
    static constexpr size_t kMaxBindings = 256;
    static constexpr size_t kMaxProfiles = 32;

    void clear() noexcept {
        loaded_ = false;
        bindings_.clear();
        profiles_.clear();
        calibration_profiles_.clear();
        has_calibration_override_ = false;
        registry_hash_[0] = '\0';
        weapon_config_hash_[0] = '\0';
    }

    bool replace_config(const std::vector<SoulWeaponBinding>& bindings,
                        const std::vector<PresentationProfileRecord>& profiles,
                        const char* registry_hash,
                        const char* weapon_config_hash) {
        if (bindings.size() > kMaxBindings || profiles.size() > kMaxProfiles) {
            clear();
            return false;
        }
        for (const auto& b : bindings) {
            if (b.job < 1 || b.job > 22 || b.branch < 1 || b.branch > 3) {
                clear();
                return false;
            }
            if (b.presentation_profile_index >= static_cast<int32_t>(profiles.size())) {
                clear();
                return false;
            }
        }
        bindings_ = bindings;
        profiles_ = profiles;
        calibration_profiles_ = profiles;
        has_calibration_override_ = false;
        std::memset(registry_hash_, 0, sizeof(registry_hash_));
        std::memset(weapon_config_hash_, 0, sizeof(weapon_config_hash_));
        if (registry_hash != nullptr) {
            std::snprintf(registry_hash_, sizeof(registry_hash_), "%s", registry_hash);
        }
        if (weapon_config_hash != nullptr) {
            std::snprintf(weapon_config_hash_, sizeof(weapon_config_hash_), "%s", weapon_config_hash);
        }
        loaded_ = true;
        return true;
    }

    bool loaded() const noexcept { return loaded_; }
    size_t binding_count() const noexcept { return bindings_.size(); }
    size_t profile_count() const noexcept { return profiles_.size(); }
    const char* registry_hash() const noexcept { return registry_hash_; }
    const char* weapon_config_hash() const noexcept { return weapon_config_hash_; }

    // Diagnostics are strictly disabled by default.
    bool diagnostics_enabled() const noexcept { return diagnostics_enabled_; }
    void set_diagnostics_enabled(bool enabled) noexcept { diagnostics_enabled_ = enabled; }

    void reset_calibration_overrides() noexcept {
        calibration_profiles_ = profiles_;
        has_calibration_override_ = false;
    }

    int32_t find_profile_index(const char* profile_id) const noexcept {
        if (profile_id == nullptr || profile_id[0] == '\0') return -1;
        for (size_t i = 0; i < profiles_.size(); ++i) {
            if (std::strcmp(profiles_[i].id, profile_id) == 0) {
                return static_cast<int32_t>(i);
            }
        }
        return -1;
    }

    bool set_profile_race_transform_override(const char* profile_id, PlayableRace race,
                                             bool sheathed, bool is_sub,
                                             const WeaponAttachmentTransform& xform) noexcept {
        if (!diagnostics_enabled_ || !loaded_ || !valid_playable_race(race)) {
            return false;
        }
        if (xform.scale < 0.25f || xform.scale > 2.5f) {
            return false;
        }
        const int32_t pidx = find_profile_index(profile_id);
        if (pidx < 0 || static_cast<size_t>(pidx) >= calibration_profiles_.size()) {
            return false;
        }
        auto& prof = calibration_profiles_[static_cast<size_t>(pidx)];
        if (!prof.has_races) return false;
        auto& slot = prof.races[static_cast<size_t>(static_cast<uint8_t>(race) - 1u)];
        if (sheathed) {
            if (is_sub) slot.sheathed_sub = xform;
            else slot.sheathed_main = xform;
        } else {
            if (is_sub) slot.drawn_sub = xform;
            else slot.drawn_main = xform;
        }
        has_calibration_override_ = true;
        return true;
    }

    const RaceWeaponTransformSet* transforms_for(const char* profile_id, PlayableRace race) const noexcept {
        if (!loaded_ || !valid_playable_race(race)) return nullptr;
        const int32_t pidx = find_profile_index(profile_id);
        if (pidx < 0) return nullptr;
        const auto& source = (diagnostics_enabled_ && has_calibration_override_) ? calibration_profiles_ : profiles_;
        const auto& prof = source[static_cast<size_t>(pidx)];
        if (!prof.has_races) return nullptr;
        return &prof.races[static_cast<size_t>(static_cast<uint8_t>(race) - 1u)];
    }

    PeerSoulRegistry& peers() noexcept { return peers_; }
    const PeerSoulRegistry& peers() const noexcept { return peers_; }

    // Registry-driven runtime authorization for resolving an actor's Sub-slot
    // weapon model (slot 7) from the original Main-slot FTABLE namespace (slot 6).
    //
    // Guarantees:
    //   * Fails closed when config is unloaded or Soul identity is unknown/expired.
    //   * Never remaps empty models (0) or vanilla shield model ranges.
    //   * Local actor requires an active Dual2HAttachments binding AND matching
    //     equipped Main/Sub weapon skills (preserving vanilla 1H dual-wield even
    //     when a Dual2H Soul equips 1H weapons).
    //   * Remote actor uses strictly the remote peer's own OXSI Soul identity.
    bool authorizes_sub_main_namespace(uint32_t actor_id, bool is_local, bool soul_known,
                                       uint8_t job, uint8_t branch, uint8_t effective_level,
                                       uint16_t sub_model_id, uint32_t now_ms,
                                       bool has_equipped_skills, uint16_t main_skill,
                                       uint16_t main_item_id, uint16_t sub_skill,
                                       uint16_t sub_item_id) const noexcept {
        if (!loaded_ || sub_model_id == 0 || is_vanilla_shield_model_id(sub_model_id)) {
            return false;
        }
        uint8_t resolved_job = 0;
        uint8_t resolved_branch = 0;
        uint8_t resolved_level = 0;
        if (is_local) {
            if (!soul_known) return false;
            resolved_job = job;
            resolved_branch = branch;
            resolved_level = effective_level;
        } else {
            PeerSoulRecord peer{};
            if (!peers_.lookup(actor_id, now_ms, peer)) {
                return false;
            }
            resolved_job = peer.job;
            resolved_branch = peer.branch;
            resolved_level = peer.effective_level;
        }

        const uint32_t main_bit = (main_skill > 0 && main_skill < 32u) ? (1u << main_skill) : 0u;
        const uint32_t sub_bit  = (sub_skill > 0 && sub_skill < 32u) ? (1u << sub_skill) : 0u;
        for (const auto& b : bindings_) {
            if (b.job != resolved_job || b.branch != resolved_branch) continue;
            if (resolved_level < b.min_effective_level) continue;
            if (b.presentation_profile_index < 0 ||
                static_cast<size_t>(b.presentation_profile_index) >= profiles_.size()) {
                continue;
            }
            if (profiles_[static_cast<size_t>(b.presentation_profile_index)].kind !=
                PresentationProfileKind::Dual2HAttachments) {
                continue;
            }
            if (has_equipped_skills) {
                if ((b.main_skill_mask & main_bit) == 0 || (b.sub_skill_mask & sub_bit) == 0) {
                    continue;
                }
                if (b.main_item_id != 0 && b.main_item_id != main_item_id) continue;
                if (b.sub_item_id != 0 && b.sub_item_id != sub_item_id) continue;
            }
            return true;
        }
        return false;
    }

    ActorPresentationDecision evaluate(const ActorPresentationQuery& q) const noexcept {
        ActorPresentationDecision out{};
        if (!loaded_) {
            return out; // Fail closed when authoritative config is unavailable.
        }
        if (q.is_dead || !q.distinct_items) {
            return out;
        }
        if (!valid_playable_race(q.race)) {
            return out;
        }
        if (q.main_item_id == 0 || q.sub_item_id == 0 || q.main_model_id == 0 || q.sub_model_id == 0) {
            return out;
        }
        if (q.main_skill == 0 || q.main_skill >= 32u || q.sub_skill == 0 || q.sub_skill >= 32u) {
            return out;
        }

        // Strict Soul gate: local uses confirmed local Soul; remote uses ONLY remote peer's OXSI Soul.
        uint8_t resolved_job = 0;
        uint8_t resolved_branch = 0;
        uint8_t resolved_level = 0;
        if (q.is_local) {
            if (!q.soul_known) return out;
            resolved_job = q.job;
            resolved_branch = q.branch;
            resolved_level = q.effective_level;
        } else {
            PeerSoulRecord peer{};
            if (!peers_.lookup(q.actor_id, q.now_ms, peer)) {
                return out; // Fail closed when remote actor's Soul is unknown or expired.
            }
            resolved_job = peer.job;
            resolved_branch = peer.branch;
            resolved_level = peer.effective_level;
        }

        const uint32_t main_bit = 1u << q.main_skill;
        const uint32_t sub_bit = 1u << q.sub_skill;
        const SoulWeaponBinding* matched = nullptr;
        for (const auto& b : bindings_) {
            if (b.job != resolved_job || b.branch != resolved_branch) continue;
            if (resolved_level < b.min_effective_level) continue;
            if ((b.main_skill_mask & main_bit) == 0) continue;
            if ((b.sub_skill_mask & sub_bit) == 0) continue;
            if (b.main_item_id != 0 && b.main_item_id != q.main_item_id) continue;
            if (b.sub_item_id != 0 && b.sub_item_id != q.sub_item_id) continue;
            if (b.presentation_profile_index < 0 ||
                static_cast<size_t>(b.presentation_profile_index) >= profiles_.size()) {
                continue;
            }
            matched = &b;
            break;
        }
        if (matched == nullptr) {
            return out;
        }

        const auto& source = (diagnostics_enabled_ && has_calibration_override_) ? calibration_profiles_ : profiles_;
        const auto& prof = source[static_cast<size_t>(matched->presentation_profile_index)];
        if (!prof.has_races) {
            return out;
        }

        WeaponPresentationState drawn_state = WeaponPresentationState::Vanilla;
        WeaponPresentationState sheathed_state = WeaponPresentationState::Vanilla;
        switch (prof.kind) {
            case PresentationProfileKind::Dual2HAttachments:
                drawn_state = WeaponPresentationState::DrawnDual2H;
                sheathed_state = WeaponPresentationState::SheathedCrossX;
                break;
            case PresentationProfileKind::TwoHandShieldAttachments:
                drawn_state = WeaponPresentationState::DrawnTwoHandShield;
                sheathed_state = WeaponPresentationState::SheathedTwoHandShield;
                break;
            case PresentationProfileKind::Dual1HAttachments:
                drawn_state = WeaponPresentationState::DrawnDual1H;
                sheathed_state = WeaponPresentationState::SheathedDual1H;
                break;
            default:
                return out;
        }

        const auto& set = prof.races[static_cast<size_t>(static_cast<uint8_t>(q.race) - 1u)];
        out.main_model_id = q.main_model_id;
        out.sub_model_id  = q.sub_model_id;
        std::snprintf(out.soul_id, sizeof(out.soul_id), "%s", matched->soul_id);
        std::snprintf(out.profile_id, sizeof(out.profile_id), "%s", prof.id);
        if (q.is_engaged) {
            out.state          = drawn_state;
            out.main_transform = set.drawn_main;
            out.sub_transform  = set.drawn_sub;
        } else {
            out.state          = sheathed_state;
            out.main_transform = set.sheathed_main;
            out.sub_transform  = set.sheathed_sub;
        }
        return out;
    }

private:
    bool loaded_ = false;
    std::vector<SoulWeaponBinding> bindings_{};
    std::vector<PresentationProfileRecord> profiles_{};
    std::vector<PresentationProfileRecord> calibration_profiles_{};
    bool has_calibration_override_ = false;
    char registry_hash_[24]{};
    char weapon_config_hash_[24]{};
    PeerSoulRegistry peers_{};
    bool diagnostics_enabled_ = false;
};

} // namespace soulspire::native
