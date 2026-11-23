#pragma once
#include "../core/api.h"
#include "../job_identity/job_identity.h"
#include <cstdint>
#include <vector>

namespace soulspire::native {

struct WeaponRuleRecord {
    uint8_t  job = 0;
    uint8_t  branch = 0;
    uint8_t  min_effective_level = 10;
    uint8_t  mode = SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_1H;
    uint32_t main_skill_mask = 0;
    uint32_t sub_skill_mask = 0;
    uint16_t main_item_id = 0;
    uint16_t sub_item_id = 0;
};

inline bool validate_and_convert_weapon_rule(const SoulspireNativeWeaponRule& in, WeaponRuleRecord& out) noexcept {
    if (in.size != sizeof(SoulspireNativeWeaponRule)) return false;
    if (in.job < 1 || in.job > 22 || !valid_branch(in.job, in.branch)) return false;
    if (in.min_effective_level < 1 || in.min_effective_level > 99) return false;
    if (in.mode != SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_1H &&
        in.mode != SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H &&
        in.mode != SOULSPIRE_NATIVE_WEAPON_MODE_TWOHAND_SHIELD) return false;
    if (in.main_skill_mask == 0 || in.sub_skill_mask == 0) return false;
    out = {};
    out.job = in.job;
    out.branch = in.branch;
    out.min_effective_level = in.min_effective_level;
    out.mode = in.mode;
    out.main_skill_mask = in.main_skill_mask;
    out.sub_skill_mask = in.sub_skill_mask;
    out.main_item_id = in.main_item_id;
    out.sub_item_id = in.sub_item_id;
    return true;
}

class WeaponRuleCatalog {
public:
    static constexpr uint32_t kMaxEntries = 256;

    bool replace_all(const SoulspireNativeWeaponRule* entries, uint32_t count) {
        if (count > kMaxEntries) return false;
        if (count > 0 && entries == nullptr) return false;
        std::vector<WeaponRuleRecord> next;
        next.reserve(count);
        for (uint32_t i = 0; i < count; ++i) {
            WeaponRuleRecord rec;
            if (!validate_and_convert_weapon_rule(entries[i], rec)) return false;
            next.push_back(rec);
        }
        records_.swap(next);
        ++generation_;
        return true;
    }

    void clear() noexcept {
        records_.clear();
        ++generation_;
    }

    bool has_rules_for(uint8_t job, uint8_t branch) const noexcept {
        for (const auto& rec : records_) {
            if (rec.job == job && rec.branch == branch) return true;
        }
        return false;
    }

    bool allows_sub_weapon(uint8_t job, uint8_t branch, uint8_t effective_level,
                           uint16_t main_skill, uint16_t main_item_id,
                           uint16_t sub_skill, uint16_t sub_item_id) const noexcept {
        if (records_.empty() || job == 0 || branch == 0 || effective_level == 0) return false;
        if (main_skill == 0 || main_skill >= 32u || sub_skill == 0 || sub_skill >= 32u) return false;
        const uint32_t main_bit = 1u << main_skill;
        const uint32_t sub_bit = 1u << sub_skill;
        for (const auto& rec : records_) {
            if (rec.job != job || rec.branch != branch) continue;
            if (effective_level < rec.min_effective_level) continue;
            if (rec.mode != SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_1H &&
                rec.mode != SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H) continue;
            if ((rec.main_skill_mask & main_bit) == 0) continue;
            if ((rec.sub_skill_mask & sub_bit) == 0) continue;
            if (rec.main_item_id != 0 && rec.main_item_id != main_item_id) continue;
            if (rec.sub_item_id != 0 && rec.sub_item_id != sub_item_id) continue;
            return true;
        }
        return false;
    }

    bool allows_dual_2h_menu_item(uint8_t job, uint8_t branch, uint8_t effective_level,
                                  uint16_t sub_skill, uint16_t sub_item_id) const noexcept {
        if (records_.empty() || job == 0 || branch == 0 || effective_level == 0) return false;
        if (sub_skill == 0 || sub_skill >= 32u) return false;
        const uint32_t sub_bit = 1u << sub_skill;
        for (const auto& rec : records_) {
            if (rec.job != job || rec.branch != branch) continue;
            if (effective_level < rec.min_effective_level) continue;
            if (rec.mode != SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H) continue;
            if ((rec.sub_skill_mask & sub_bit) == 0) continue;
            if (rec.sub_item_id != 0 && rec.sub_item_id != sub_item_id) continue;
            return true;
        }
        return false;
    }

    bool allows_2h_main_with_sub(uint8_t job, uint8_t branch, uint8_t effective_level,
                                 uint16_t main_skill, uint16_t main_item_id,
                                 uint16_t sub_skill, uint16_t sub_item_id) const noexcept {
        if (records_.empty() || job == 0 || branch == 0 || effective_level == 0) return false;
        if (main_skill == 0 || main_skill >= 32u || sub_skill == 0 || sub_skill >= 32u) return false;
        const uint32_t main_bit = 1u << main_skill;
        const uint32_t sub_bit = 1u << sub_skill;
        for (const auto& rec : records_) {
            if (rec.job != job || rec.branch != branch) continue;
            if (effective_level < rec.min_effective_level) continue;
            if (rec.mode != SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H &&
                rec.mode != SOULSPIRE_NATIVE_WEAPON_MODE_TWOHAND_SHIELD) continue;
            if ((rec.main_skill_mask & main_bit) == 0) continue;
            if ((rec.sub_skill_mask & sub_bit) == 0) continue;
            if (rec.main_item_id != 0 && rec.main_item_id != main_item_id) continue;
            if (rec.sub_item_id != 0 && rec.sub_item_id != sub_item_id) continue;
            return true;
        }
        return false;
    }

    uint32_t count() const noexcept { return static_cast<uint32_t>(records_.size()); }
    uint32_t generation() const noexcept { return generation_; }

private:
    std::vector<WeaponRuleRecord> records_;
    uint32_t generation_ = 0;
};

} // namespace soulspire::native
