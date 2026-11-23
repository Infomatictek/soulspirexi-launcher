#pragma once
#include "../core/api.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Backwards-compatible CrystalJobs C ABI type and constant aliases.
   Preserves binary ABI compatibility for existing Ashita addons during migration
   to soulspire_native.dll without maintaining duplicate implementations. */
#define CRYSTALJOBS_CALL SOULSPIRE_NATIVE_CALL

typedef SoulspireNativeStatus              CrystalJobsStatus;
typedef SoulspireNativeActionEntry         CrystalJobsActionEntry;
typedef SoulspireNativeActionStatus        CrystalJobsActionStatus;
typedef SoulspireNativeVisibilityEntry     CrystalJobsVisibilityEntry;
typedef SoulspireNativeVisibilityStatus    CrystalJobsVisibilityStatus;
typedef SoulspireNativeWeaponRule          CrystalJobsWeaponRule;
typedef SoulspireNativeWeaponStatus        CrystalJobsWeaponStatus;
typedef SoulspireNativeHookDiagnostics     CrystalJobsHookDiagnostics;
typedef SoulspireNativeIdentityDiagnostics CrystalJobsIdentityDiagnostics;

enum {
    CRYSTALJOBS_ACTION_SPELL       = SOULSPIRE_NATIVE_ACTION_SPELL,
    CRYSTALJOBS_ACTION_ABILITY     = SOULSPIRE_NATIVE_ACTION_ABILITY,
    CRYSTALJOBS_ACTION_WEAPONSKILL = SOULSPIRE_NATIVE_ACTION_WEAPONSKILL
};

enum {
    CRYSTALJOBS_CAP_EQUIPMENT_SOUL_NAME = SOULSPIRE_NATIVE_CAP_EQUIPMENT_SOUL_NAME,
    CRYSTALJOBS_CAP_SEARCH_SOUL_LABELS  = SOULSPIRE_NATIVE_CAP_SEARCH_SOUL_LABELS,
    CRYSTALJOBS_CAP_MAGIC_MENU_NAMES    = SOULSPIRE_NATIVE_CAP_MAGIC_MENU_NAMES,
    CRYSTALJOBS_CAP_MAGIC_MENU_DESC     = SOULSPIRE_NATIVE_CAP_MAGIC_MENU_DESC,
    CRYSTALJOBS_CAP_MAGIC_TARGET_HEADER = SOULSPIRE_NATIVE_CAP_MAGIC_TARGET_HEADER,
    CRYSTALJOBS_CAP_MAGIC_MENU_ICONS    = SOULSPIRE_NATIVE_CAP_MAGIC_MENU_ICONS,
    CRYSTALJOBS_CAP_ABILITY_MENU_NAMES  = SOULSPIRE_NATIVE_CAP_ABILITY_MENU_NAMES,
    CRYSTALJOBS_CAP_ABILITY_MENU_DESC   = SOULSPIRE_NATIVE_CAP_ABILITY_MENU_DESC,
    CRYSTALJOBS_CAP_ABILITY_TARGET_HDR  = SOULSPIRE_NATIVE_CAP_ABILITY_TARGET_HDR,
    CRYSTALJOBS_CAP_ABILITY_MENU_ICONS  = SOULSPIRE_NATIVE_CAP_ABILITY_MENU_ICONS,
    CRYSTALJOBS_CAP_MAGIC_MENU_FILTER   = SOULSPIRE_NATIVE_CAP_MAGIC_MENU_FILTER,
    CRYSTALJOBS_CAP_ABILITY_MENU_FILTER = SOULSPIRE_NATIVE_CAP_ABILITY_MENU_FILTER,
    CRYSTALJOBS_CAP_SOUL_CAST_LOOKUP    = SOULSPIRE_NATIVE_CAP_SOUL_CAST_LOOKUP,
    CRYSTALJOBS_CAP_SOUL_SUB_WEAPON     = SOULSPIRE_NATIVE_CAP_SOUL_SUB_WEAPON,
    CRYSTALJOBS_CAP_SOUL_SUB_2H         = SOULSPIRE_NATIVE_CAP_SOUL_SUB_2H
};

enum {
    CRYSTALJOBS_WEAPON_MODE_DUAL_1H        = SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_1H,
    CRYSTALJOBS_WEAPON_MODE_DUAL_2H        = SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H,
    CRYSTALJOBS_WEAPON_MODE_TWOHAND_SHIELD = SOULSPIRE_NATIVE_WEAPON_MODE_TWOHAND_SHIELD
};

enum {
    CRYSTALJOBS_VIS_RULE_UNLOCK = SOULSPIRE_NATIVE_VIS_RULE_UNLOCK,
    CRYSTALJOBS_VIS_RULE_HIDDEN = SOULSPIRE_NATIVE_VIS_RULE_HIDDEN
};

enum {
    CRYSTALJOBS_INIT_NOT_RUN             = SOULSPIRE_NATIVE_INIT_NOT_RUN,
    CRYSTALJOBS_INIT_BAD_PE              = SOULSPIRE_NATIVE_INIT_BAD_PE,
    CRYSTALJOBS_INIT_SIG_MISMATCH        = SOULSPIRE_NATIVE_INIT_SIG_MISMATCH,
    CRYSTALJOBS_INIT_PIN_FAIL            = SOULSPIRE_NATIVE_INIT_PIN_FAIL,
    CRYSTALJOBS_INIT_PATCH_FAIL          = SOULSPIRE_NATIVE_INIT_PATCH_FAIL,
    CRYSTALJOBS_INIT_DETOUR_FAIL         = SOULSPIRE_NATIVE_INIT_DETOUR_FAIL,
    CRYSTALJOBS_INIT_OK                  = SOULSPIRE_NATIVE_INIT_OK,
    CRYSTALJOBS_INIT_CONFLICT_LEGACY_DLL = SOULSPIRE_NATIVE_INIT_CONFLICT_LEGACY_DLL
};

uint32_t CRYSTALJOBS_CALL CrystalJobsInitialize(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsShutdown(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetStatus(CrystalJobsStatus* status, uint32_t size);
uint32_t CRYSTALJOBS_CALL CrystalJobsSetState(const uint8_t* bytes, uint32_t size);
uint32_t CRYSTALJOBS_CALL CrystalJobsReplaceCatalog(const CrystalJobsActionEntry* entries, uint32_t count);
uint32_t CRYSTALJOBS_CALL CrystalJobsUpsertAction(const CrystalJobsActionEntry* entry);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearCatalog(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsSetActiveSoul(uint32_t job, uint32_t branch, uint32_t character_id);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearActiveSoul(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetActionStatus(CrystalJobsActionStatus* status, uint32_t size);
uint32_t CRYSTALJOBS_CALL CrystalJobsSetActionRowLimit(uint32_t max_chars);
uint32_t CRYSTALJOBS_CALL CrystalJobsReplaceVisibility(const CrystalJobsVisibilityEntry* entries, uint32_t count);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearVisibility(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetVisibilityStatus(CrystalJobsVisibilityStatus* status, uint32_t size);
uint32_t CRYSTALJOBS_CALL CrystalJobsReplaceWeaponRules(const CrystalJobsWeaponRule* entries, uint32_t count);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearWeaponRules(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetWeaponStatus(CrystalJobsWeaponStatus* status, uint32_t size);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetHookDiagnostics(CrystalJobsHookDiagnostics* diag, uint32_t size);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetIdentityDiagnostics(CrystalJobsIdentityDiagnostics* diag, uint32_t size);

#ifdef __cplusplus
}
#endif

namespace soulspire::native {

#if defined(_WIN32)
// Mutual-exclusion check preventing simultaneous loading of legacy crystaljobs.dll
// and canonical soulspire_native.dll in the same pol.exe process.
inline bool detect_legacy_crystaljobs_conflict(HMODULE self_module) noexcept {
    const HMODULE legacy = GetModuleHandleW(L"crystaljobs.dll");
    return legacy != nullptr && legacy != self_module;
}
#endif

} // namespace soulspire::native
