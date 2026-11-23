#pragma once
#include <stdint.h>

#if defined(_WIN32)
#define SOULSPIRE_NATIVE_CALL __stdcall
#else
#define SOULSPIRE_NATIVE_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Canonical Soulspire Native ABI version (versioned contract with Soulspire Core & addons). */
enum {
    SOULSPIRE_NATIVE_ABI_VERSION       = 2,
    SOULSPIRE_NATIVE_LEGACY_ABI_VER    = 1,
    SOULSPIRE_NATIVE_EXPECTED_HOOKS    = 27
};

/* Initialization / lifecycle result codes:
   0 = success
   1 = unsupported client / binary fingerprint mismatch
   2 = initialization failure (or legacy crystaljobs.dll conflict)
   3 = restore / integrity conflict */
typedef struct SoulspireNativeStatus {
    uint32_t size, version, enabled, hooks, character_id, job, known, branch;
    uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
    uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
} SoulspireNativeStatus;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeInitialize(void);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeShutdown(void);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetStatus(SoulspireNativeStatus* status, uint32_t size);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeSetState(const uint8_t* bytes, uint32_t size);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeReloadConfig(void);

/* Action kind constants. */
enum {
    SOULSPIRE_NATIVE_ACTION_SPELL       = 1,
    SOULSPIRE_NATIVE_ACTION_ABILITY     = 2,
    SOULSPIRE_NATIVE_ACTION_WEAPONSKILL = 3
};

/* Runtime capability bitmask. */
enum {
    SOULSPIRE_NATIVE_CAP_EQUIPMENT_SOUL_NAME = 1u << 0,
    SOULSPIRE_NATIVE_CAP_SEARCH_SOUL_LABELS  = 1u << 1,
    SOULSPIRE_NATIVE_CAP_MAGIC_MENU_NAMES    = 1u << 2,
    SOULSPIRE_NATIVE_CAP_MAGIC_MENU_DESC     = 1u << 3,
    SOULSPIRE_NATIVE_CAP_MAGIC_TARGET_HEADER = 1u << 4,
    SOULSPIRE_NATIVE_CAP_MAGIC_MENU_ICONS    = 1u << 5,
    SOULSPIRE_NATIVE_CAP_ABILITY_MENU_NAMES  = 1u << 6,
    SOULSPIRE_NATIVE_CAP_ABILITY_MENU_DESC   = 1u << 7,
    SOULSPIRE_NATIVE_CAP_ABILITY_TARGET_HDR  = 1u << 8,
    SOULSPIRE_NATIVE_CAP_ABILITY_MENU_ICONS  = 1u << 9,
    SOULSPIRE_NATIVE_CAP_MAGIC_MENU_FILTER   = 1u << 10,
    SOULSPIRE_NATIVE_CAP_ABILITY_MENU_FILTER = 1u << 11,
    SOULSPIRE_NATIVE_CAP_SOUL_CAST_LOOKUP    = 1u << 12,
    SOULSPIRE_NATIVE_CAP_SOUL_SUB_WEAPON     = 1u << 13,
    SOULSPIRE_NATIVE_CAP_SOUL_SUB_2H         = 1u << 14,
    SOULSPIRE_NATIVE_CAP_DAT_VIRTUALIZATION  = 1u << 15
};

/* Weapon template modes. */
enum {
    SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_1H        = 1,
    SOULSPIRE_NATIVE_WEAPON_MODE_DUAL_2H        = 2,
    SOULSPIRE_NATIVE_WEAPON_MODE_TWOHAND_SHIELD = 3
};

/* Action visibility rules. */
enum {
    SOULSPIRE_NATIVE_VIS_RULE_UNLOCK = 1,
    SOULSPIRE_NATIVE_VIS_RULE_HIDDEN = 2
};

/* Subsystem module identifiers for diagnostics & failure isolation. */
enum {
    SOULSPIRE_NATIVE_MOD_JOB_IDENTITY       = 0,
    SOULSPIRE_NATIVE_MOD_ACTIONS            = 1,
    SOULSPIRE_NATIVE_MOD_EQUIPMENT          = 2,
    SOULSPIRE_NATIVE_MOD_RENDERING          = 3,
    SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION = 4,
    SOULSPIRE_NATIVE_MOD_COUNT              = 5
};

typedef struct SoulspireNativeActionEntry {
    uint32_t size;
    uint8_t  job;
    uint8_t  branch;
    uint16_t action_id;
    uint32_t kind;
    uint16_t icon_id;
    uint16_t icon_id_v2;
    char     name[80];
    char     description[192];
} SoulspireNativeActionEntry;

typedef struct SoulspireNativeActionStatus {
    uint32_t size;
    uint32_t version;
    uint32_t capabilities;
    uint32_t catalog_count;
    uint32_t catalog_generation;
    uint32_t active_job;
    uint32_t active_branch;
    uint32_t active_source;
    uint32_t magic_name_hits;
    uint32_t magic_desc_hits;
    uint32_t magic_icon_hits;
    uint32_t ability_name_hits;
    uint32_t ability_desc_hits;
    uint32_t ability_icon_hits;
    uint32_t total_hooks;
    uint32_t expected_hooks;
} SoulspireNativeActionStatus;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeReplaceCatalog(const SoulspireNativeActionEntry* entries, uint32_t count);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeUpsertAction(const SoulspireNativeActionEntry* entry);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeClearCatalog(void);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeSetActiveSoul(uint32_t job, uint32_t branch, uint32_t character_id);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeClearActiveSoul(void);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetActionStatus(SoulspireNativeActionStatus* status, uint32_t size);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeSetActionRowLimit(uint32_t max_chars);

typedef struct SoulspireNativeVisibilityEntry {
    uint32_t size;
    uint8_t  job;
    uint8_t  branch;
    uint8_t  min_effective_level;
    uint8_t  rule;
    uint32_t kind;
    uint16_t action_id;
    uint16_t reserved;
} SoulspireNativeVisibilityEntry;

typedef struct SoulspireNativeVisibilityStatus {
    uint32_t size;
    uint32_t version;
    uint32_t policy_count;
    uint32_t policy_generation;
    uint32_t effective_level;
    uint32_t magic_hidden_count;
    uint32_t magic_shown_count;
    uint32_t ability_hidden_count;
    uint32_t total_hooks;
    uint32_t expected_hooks;
} SoulspireNativeVisibilityStatus;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeReplaceVisibility(const SoulspireNativeVisibilityEntry* entries, uint32_t count);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeClearVisibility(void);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetVisibilityStatus(SoulspireNativeVisibilityStatus* status, uint32_t size);

typedef struct SoulspireNativeWeaponRule {
    uint32_t size;
    uint8_t  job;
    uint8_t  branch;
    uint8_t  min_effective_level;
    uint8_t  mode;
    uint32_t main_skill_mask;
    uint32_t sub_skill_mask;
    uint16_t main_item_id;
    uint16_t sub_item_id;
    uint32_t reserved;
} SoulspireNativeWeaponRule;

typedef struct SoulspireNativeWeaponStatus {
    uint32_t size;
    uint32_t version;
    uint32_t rule_count;
    uint32_t rule_generation;
    uint32_t effective_level;
    uint32_t allow_hits;
    uint32_t deny_hits;
    uint32_t total_hooks;
    uint32_t expected_hooks;
} SoulspireNativeWeaponStatus;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeReplaceWeaponRules(const SoulspireNativeWeaponRule* entries, uint32_t count);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeClearWeaponRules(void);
uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetWeaponStatus(SoulspireNativeWeaponStatus* status, uint32_t size);

/* Per-hook initialization & live integrity diagnostics. */
enum {
    SOULSPIRE_NATIVE_INIT_NOT_RUN              = 0,
    SOULSPIRE_NATIVE_INIT_BAD_PE               = 1,
    SOULSPIRE_NATIVE_INIT_SIG_MISMATCH         = 2,
    SOULSPIRE_NATIVE_INIT_PIN_FAIL             = 3,
    SOULSPIRE_NATIVE_INIT_PATCH_FAIL           = 4,
    SOULSPIRE_NATIVE_INIT_DETOUR_FAIL          = 5,
    SOULSPIRE_NATIVE_INIT_OK                   = 6,
    SOULSPIRE_NATIVE_INIT_CONFLICT_LEGACY_DLL  = 7
};

typedef struct SoulspireNativeHookDiagnostics {
    uint32_t size;
    uint32_t version;
    uint32_t total_hooks;
    uint32_t expected_hooks;
    uint32_t installed_mask;
    uint32_t site_set_mask;
    uint32_t capabilities;
    uint32_t ffxi_base;
    uint32_t ffxi_timestamp;
    uint32_t ffxi_image_size;
    uint32_t init_stage;
    uint32_t failed_rva;
    uint32_t failed_index;
    uint8_t  observed_bytes[8];
} SoulspireNativeHookDiagnostics;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetHookDiagnostics(SoulspireNativeHookDiagnostics* diag, uint32_t size);

typedef struct SoulspireNativeIdentityDiagnostics {
    uint32_t size;
    uint32_t version;
    uint32_t source;               /* 0=compiled-fallback, 1=runtime-json */
    uint32_t status;               /* IdentityLoadStatus */
    uint32_t schema_version;
    uint32_t soul_count;
    int32_t  tracking_px;
    int32_t  offset_x_px;
    uint32_t use_glyph_widths;
    uint32_t presentation_from_file;
    char     active_registry_hash[24];
    char     compiled_registry_hash[24];
    char     warning[128];
} SoulspireNativeIdentityDiagnostics;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetIdentityDiagnostics(SoulspireNativeIdentityDiagnostics* diag, uint32_t size);

/* Versioned Soulspire Native <-> Soulspire Core interface & module diagnostics (ABI v2). */
typedef struct SoulspireNativeInterfaceInfo {
    uint32_t size;
    uint32_t abi_version;
    uint32_t expected_hooks;
    uint32_t installed_hooks;
    uint32_t capabilities;
    uint32_t enabled_modules_mask;
    uint32_t active_modules_mask;
    uint32_t menu2fon_banks_used;
    uint32_t menu2fon_banks_max;
    uint32_t menu2fon_fallback_draws;
    uint32_t config_from_file;
    uint32_t log_level;
    char     project_name[32];
    char     registry_hash[24];
} SoulspireNativeInterfaceInfo;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetInterfaceInfo(SoulspireNativeInterfaceInfo* info, uint32_t size);

/* Registry-driven DAT Virtualization diagnostics (Phase E/F). */
typedef struct SoulspireNativeDatVirtStatus {
    uint32_t size;
    uint32_t schema_version;
    uint32_t enabled;
    uint32_t loaded_from_file;
    uint32_t override_count;
    uint32_t generation;
    uint32_t hits;
    uint32_t misses;
    char     registry_hash[24];
    char     integrity_fnv1a64[20];
    char     warning[96];
} SoulspireNativeDatVirtStatus;

uint32_t SOULSPIRE_NATIVE_CALL SoulspireNativeGetDatVirtualizationStatus(SoulspireNativeDatVirtStatus* status, uint32_t size);

#ifdef __cplusplus
}
#endif
