#pragma once
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>

namespace soulspire::native {

// Reusable Soul Weapon Presentation System (C++17).
//
// Design guarantees:
//   1. Fail-closed on unknown, expired, or unsynchronized Soul identity.
//   2. Never infers Berserker eligibility from WAR base job alone.
//   3. Evaluates local and remote characters strictly from the observed actor's
//      own verified Soul and equipped weapons (never local player's Soul for peers).
//   4. Independently preserves each equipped Great Axe's actual model ID.
//   5. Supports all 8 playable FFXI character models with drawn (right/left hand)
//      and sheathed (crossed-back X formation with depth separation) transforms.
//   6. Developer live-adjustment overrides are disabled by default.

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

enum class WeaponPresentationState : uint8_t {
    Vanilla        = 0,
    DrawnDual2H    = 1,
    SheathedCrossX = 2,
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

inline RaceWeaponTransformSet default_berserker_race_transforms(PlayableRace race) noexcept {
    // Matches plugins/ashita4/data/soul-weapon-presentation.json defaults across all 8 playable models.
    auto make_set = [](float dtx, float dty, float dtz, float dpitch, float droll, float dgrip_y, float scale, float dsep,
                       float stx, float sty, float stz, float spitch, float syaw, float sroll, float sgrip_y, float ssep,
                       float depth_sep) noexcept -> RaceWeaponTransformSet {
        RaceWeaponTransformSet s{};
        s.drawn_main    = { -dtx, dty, dtz, dpitch, 0.0f, -droll, 0.0f, dgrip_y, 0.0f, scale, dsep, 0.0f };
        s.drawn_sub     = {  dtx, dty, dtz, dpitch, 0.0f,  droll, 0.0f, dgrip_y, 0.0f, scale, dsep, 0.0f };
        s.sheathed_main = { -stx, sty, stz, spitch, -syaw,  sroll, 0.0f, sgrip_y, 0.0f, scale, ssep, stz };
        s.sheathed_sub  = {  stx, sty, stz + depth_sep, spitch,  syaw, -sroll, 0.0f, sgrip_y, 0.0f, scale, ssep, stz + depth_sep };
        return s;
    };

    switch (race) {
        case PlayableRace::HumeMale:
            return make_set(0.012f, 0.008f, -0.015f, 8.0f, 6.0f, -0.180f, 0.94f, 0.040f,
                            0.045f, 0.060f,  0.145f, 6.0f, 8.0f, 42.0f, -0.120f, 0.090f, 0.038f);
        case PlayableRace::HumeFemale:
            return make_set(0.010f, 0.006f, -0.014f, 8.0f, 5.5f, -0.165f, 0.90f, 0.036f,
                            0.040f, 0.055f,  0.135f, 5.5f, 7.5f, 41.0f, -0.110f, 0.080f, 0.036f);
        case PlayableRace::ElvaanMale:
            return make_set(0.014f, 0.010f, -0.016f, 7.5f, 6.0f, -0.200f, 0.96f, 0.044f,
                            0.050f, 0.075f,  0.155f, 6.5f, 8.0f, 43.0f, -0.130f, 0.100f, 0.040f);
        case PlayableRace::ElvaanFemale:
            return make_set(0.012f, 0.008f, -0.015f, 7.5f, 5.5f, -0.185f, 0.92f, 0.038f,
                            0.044f, 0.068f,  0.145f, 6.0f, 7.5f, 42.0f, -0.120f, 0.088f, 0.038f);
        case PlayableRace::TarutaruMale:
            return make_set(0.008f, 0.012f, -0.012f, 11.0f, 7.0f, -0.115f, 0.78f, 0.030f,
                            0.032f, 0.045f,  0.115f, 7.0f, 9.0f, 39.0f, -0.080f, 0.064f, 0.032f);
        case PlayableRace::TarutaruFemale:
            return make_set(0.008f, 0.012f, -0.012f, 11.0f, 7.0f, -0.115f, 0.78f, 0.030f,
                            0.032f, 0.045f,  0.118f, 7.0f, 9.0f, 39.0f, -0.080f, 0.064f, 0.032f);
        case PlayableRace::Mithra:
            return make_set(0.011f, 0.007f, -0.015f, 8.5f, 6.0f, -0.170f, 0.91f, 0.038f,
                            0.042f, 0.058f,  0.142f, 6.0f, 8.0f, 41.5f, -0.115f, 0.084f, 0.036f);
        case PlayableRace::Galka:
            return make_set(0.018f, 0.014f, -0.020f, 7.0f, 6.5f, -0.220f, 1.04f, 0.055f,
                            0.062f, 0.085f,  0.205f, 8.0f, 9.5f, 44.0f, -0.145f, 0.124f, 0.044f);
        default:
            return default_berserker_race_transforms(PlayableRace::HumeMale);
    }
}

class WeaponPresentationManager {
public:
    static constexpr uint8_t  kWarJobId          = 1;
    static constexpr uint8_t  kBerserkerBranch   = 2;
    static constexpr uint8_t  kBerserkerMinLevel = 10;
    static constexpr uint16_t kGreatAxeSkill     = 6;

    WeaponPresentationManager() noexcept {
        reset_transforms();
    }

    void reset_transforms() noexcept {
        for (uint8_t r = 1; r <= 8; ++r) {
            race_transforms_[r - 1] = default_berserker_race_transforms(static_cast<PlayableRace>(r));
        }
    }

    // Diagnostics are strictly disabled by default.
    bool diagnostics_enabled() const noexcept { return diagnostics_enabled_; }
    void set_diagnostics_enabled(bool enabled) noexcept { diagnostics_enabled_ = enabled; }

    bool set_race_transform_override(PlayableRace race, bool sheathed, bool is_sub,
                                     const WeaponAttachmentTransform& xform) noexcept {
        if (!diagnostics_enabled_ || !valid_playable_race(race)) {
            return false;
        }
        if (xform.scale < 0.25f || xform.scale > 2.5f) {
            return false;
        }
        auto& slot = race_transforms_[static_cast<size_t>(static_cast<uint8_t>(race) - 1u)];
        if (sheathed) {
            if (is_sub) slot.sheathed_sub = xform;
            else slot.sheathed_main = xform;
        } else {
            if (is_sub) slot.drawn_sub = xform;
            else slot.drawn_main = xform;
        }
        return true;
    }

    const RaceWeaponTransformSet& transforms_for(PlayableRace race) const noexcept {
        const size_t idx = valid_playable_race(race) ? static_cast<size_t>(static_cast<uint8_t>(race) - 1u) : 0u;
        return race_transforms_[idx];
    }

    PeerSoulRegistry& peers() noexcept { return peers_; }
    const PeerSoulRegistry& peers() const noexcept { return peers_; }

    ActorPresentationDecision evaluate(const ActorPresentationQuery& q) const noexcept {
        ActorPresentationDecision out{};
        if (q.is_dead || !q.distinct_items) {
            return out;
        }
        if (!valid_playable_race(q.race)) {
            return out;
        }
        if (q.main_item_id == 0 || q.sub_item_id == 0 || q.main_model_id == 0 || q.sub_model_id == 0) {
            return out;
        }
        if (q.main_skill != kGreatAxeSkill || q.sub_skill != kGreatAxeSkill) {
            return out;
        }

        // Strict Soul gate: local uses local confirmed Soul; remote uses ONLY remote peer's OXSI Soul.
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

        // Strictly exclusive to active WAR Berserker (job=1, branch=2, effective_level>=10).
        if (resolved_job != kWarJobId || resolved_branch != kBerserkerBranch || resolved_level < kBerserkerMinLevel) {
            return out;
        }

        const auto& set = transforms_for(q.race);
        out.main_model_id = q.main_model_id;
        out.sub_model_id  = q.sub_model_id;
        if (q.is_engaged) {
            out.state          = WeaponPresentationState::DrawnDual2H;
            out.main_transform = set.drawn_main;
            out.sub_transform  = set.drawn_sub;
        } else {
            out.state          = WeaponPresentationState::SheathedCrossX;
            out.main_transform = set.sheathed_main;
            out.sub_transform  = set.sheathed_sub;
        }
        return out;
    }

private:
    std::array<RaceWeaponTransformSet, 8> race_transforms_{};
    PeerSoulRegistry peers_{};
    bool diagnostics_enabled_ = false;
};

} // namespace soulspire::native
