#pragma once
#include <stdint.h>
#if defined(_WIN32)
#define CRYSTALJOBS_CALL __stdcall
#else
#define CRYSTALJOBS_CALL
#endif
#ifdef __cplusplus
extern "C" {
#endif

typedef struct CrystalJobsStatus {
    uint32_t size, version, enabled, hooks, character_id, job, known, branch;
    uint32_t search_rows, decoded_rows, item_labels, search_labels, full_labels;
    uint32_t queries_sent, replies_accepted, replies_rejected, last_error;
} CrystalJobsStatus;

/* Call outside DllMain, after FFXiMain has unpacked and before character login.
   0=success; 1=unsupported client/layout; 2=initialization failure; 3=restore conflict. */
uint32_t CRYSTALJOBS_CALL CrystalJobsInitialize(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsShutdown(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetStatus(CrystalJobsStatus* status, uint32_t size);
/* Optional existing-addon bridge; never required for standalone operation. */
uint32_t CRYSTALJOBS_CALL CrystalJobsSetState(const uint8_t* bytes, uint32_t size);

/* Generic native Soul Action catalog API (version 1). */
enum {
    CRYSTALJOBS_ACTION_SPELL       = 1,
    CRYSTALJOBS_ACTION_ABILITY     = 2,
    CRYSTALJOBS_ACTION_WEAPONSKILL = 3
};

enum {
    CRYSTALJOBS_CAP_EQUIPMENT_SOUL_NAME = 1u << 0,
    CRYSTALJOBS_CAP_SEARCH_SOUL_LABELS  = 1u << 1,
    CRYSTALJOBS_CAP_MAGIC_MENU_NAMES    = 1u << 2,
    CRYSTALJOBS_CAP_MAGIC_MENU_DESC     = 1u << 3,
    CRYSTALJOBS_CAP_MAGIC_TARGET_HEADER = 1u << 4,
    CRYSTALJOBS_CAP_MAGIC_MENU_ICONS    = 1u << 5,
    CRYSTALJOBS_CAP_ABILITY_MENU_NAMES  = 1u << 6,
    CRYSTALJOBS_CAP_ABILITY_MENU_DESC   = 1u << 7,
    CRYSTALJOBS_CAP_ABILITY_TARGET_HDR  = 1u << 8,
    CRYSTALJOBS_CAP_ABILITY_MENU_ICONS  = 1u << 9,
    CRYSTALJOBS_CAP_MAGIC_MENU_FILTER   = 1u << 10,
    CRYSTALJOBS_CAP_ABILITY_MENU_FILTER = 1u << 11,
    CRYSTALJOBS_CAP_SOUL_CAST_LOOKUP    = 1u << 12,
    CRYSTALJOBS_CAP_SOUL_SUB_WEAPON     = 1u << 13
};

enum {
    CRYSTALJOBS_WEAPON_MODE_DUAL_1H = 1
};

enum {
    CRYSTALJOBS_VIS_RULE_UNLOCK = 1,
    CRYSTALJOBS_VIS_RULE_HIDDEN = 2
};

typedef struct CrystalJobsActionEntry {
    uint32_t size;
    uint8_t  job;
    uint8_t  branch;
    uint16_t action_id;
    uint32_t kind;
    uint16_t icon_id;
    uint16_t icon_id_v2;
    char     name[80];
    char     description[192];
} CrystalJobsActionEntry;

typedef struct CrystalJobsActionStatus {
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
} CrystalJobsActionStatus;

uint32_t CRYSTALJOBS_CALL CrystalJobsReplaceCatalog(const CrystalJobsActionEntry* entries, uint32_t count);
uint32_t CRYSTALJOBS_CALL CrystalJobsUpsertAction(const CrystalJobsActionEntry* entry);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearCatalog(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsSetActiveSoul(uint32_t job, uint32_t branch, uint32_t character_id);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearActiveSoul(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetActionStatus(CrystalJobsActionStatus* status, uint32_t size);
/* Configurable menu-row glyph budget; 8..48 chars. 0=success, 1=invalid. */
uint32_t CRYSTALJOBS_CALL CrystalJobsSetActionRowLimit(uint32_t max_chars);

/* Generic native Soul Action Visibility Policy API (version 1). */
typedef struct CrystalJobsVisibilityEntry {
    uint32_t size;
    uint8_t  job;
    uint8_t  branch;
    uint8_t  min_effective_level;
    uint8_t  rule;
    uint32_t kind;
    uint16_t action_id;
    uint16_t reserved;
} CrystalJobsVisibilityEntry;

typedef struct CrystalJobsVisibilityStatus {
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
} CrystalJobsVisibilityStatus;

uint32_t CRYSTALJOBS_CALL CrystalJobsReplaceVisibility(const CrystalJobsVisibilityEntry* entries, uint32_t count);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearVisibility(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetVisibilityStatus(CrystalJobsVisibilityStatus* status, uint32_t size);

/* Generic native Soul Weapon Configuration API (version 1). */
typedef struct CrystalJobsWeaponRule {
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
} CrystalJobsWeaponRule;

typedef struct CrystalJobsWeaponStatus {
    uint32_t size;
    uint32_t version;
    uint32_t rule_count;
    uint32_t rule_generation;
    uint32_t effective_level;
    uint32_t allow_hits;
    uint32_t deny_hits;
    uint32_t total_hooks;
    uint32_t expected_hooks;
} CrystalJobsWeaponStatus;

uint32_t CRYSTALJOBS_CALL CrystalJobsReplaceWeaponRules(const CrystalJobsWeaponRule* entries, uint32_t count);
uint32_t CRYSTALJOBS_CALL CrystalJobsClearWeaponRules(void);
uint32_t CRYSTALJOBS_CALL CrystalJobsGetWeaponStatus(CrystalJobsWeaponStatus* status, uint32_t size);

/* Per-hook initialization & live integrity diagnostics (version 1). */
enum {
    CRYSTALJOBS_INIT_NOT_RUN        = 0,
    CRYSTALJOBS_INIT_BAD_PE         = 1,
    CRYSTALJOBS_INIT_SIG_MISMATCH   = 2,
    CRYSTALJOBS_INIT_PIN_FAIL       = 3,
    CRYSTALJOBS_INIT_PATCH_FAIL     = 4,
    CRYSTALJOBS_INIT_DETOUR_FAIL    = 5,
    CRYSTALJOBS_INIT_OK             = 6
};

typedef struct CrystalJobsHookDiagnostics {
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
} CrystalJobsHookDiagnostics;

uint32_t CRYSTALJOBS_CALL CrystalJobsGetHookDiagnostics(CrystalJobsHookDiagnostics* diag, uint32_t size);

/* Runtime Soul identity loader & Search badge presentation diagnostics (version 1). */
typedef struct CrystalJobsIdentityDiagnostics {
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
} CrystalJobsIdentityDiagnostics;

uint32_t CRYSTALJOBS_CALL CrystalJobsGetIdentityDiagnostics(CrystalJobsIdentityDiagnostics* diag, uint32_t size);

#ifdef __cplusplus
}
#endif
