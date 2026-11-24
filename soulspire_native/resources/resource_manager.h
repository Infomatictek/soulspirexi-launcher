#pragma once
#include "../core/config.h"
#include "../diagnostics/diagnostics.h"
#include "../equipment/weapon_config_loader.h"
#include "../equipment/weapon_rules.h"
#include "../job_identity/job_identity.h"
#include <cwchar>
#include <memory>

namespace soulspire::native {

#if defined(_WIN32)
inline bool read_bounded_file_w(const wchar_t* path, char* buf, size_t max_bytes, size_t& out_len) noexcept {
    out_len = 0;
    if (path == nullptr || buf == nullptr || max_bytes == 0) return false;
    HANDLE h = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    LARGE_INTEGER sz{};
    const BOOL got_size = GetFileSizeEx(h, &sz);
    if (!got_size || sz.QuadPart <= 0 || static_cast<uint64_t>(sz.QuadPart) > max_bytes) {
        CloseHandle(h);
        return false;
    }
    DWORD total_read = 0;
    const DWORD expected = static_cast<DWORD>(sz.QuadPart);
    while (total_read < expected) {
        DWORD chunk = 0;
        if (!ReadFile(h, buf + total_read, expected - total_read, &chunk, nullptr) || chunk == 0) {
            CloseHandle(h);
            return false;
        }
        total_read += chunk;
    }
    CloseHandle(h);
    out_len = static_cast<size_t>(total_read);
    return true;
}

inline bool build_trusted_data_path(HMODULE mod, const wchar_t* filename, wchar_t* out, size_t out_cap) noexcept {
    if (mod == nullptr || filename == nullptr || out == nullptr || out_cap < 32) return false;
    wchar_t mod_path[MAX_PATH]{};
    const DWORD n = GetModuleFileNameW(mod, mod_path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return false;
    size_t slash_end = 0;
    for (size_t i = 0; mod_path[i] != L'\0'; ++i) {
        if (mod_path[i] == L'\\' || mod_path[i] == L'/') slash_end = i + 1;
    }
    if (slash_end == 0) return false;
    const wchar_t* sub = L"data\\";
    const size_t sub_len = 5;
    const size_t fn_len = std::wcslen(filename);
    if (slash_end + sub_len + fn_len + 1 > out_cap) return false;
    std::memcpy(out, mod_path, slash_end * sizeof(wchar_t));
    std::memcpy(out + slash_end, sub, sub_len * sizeof(wchar_t));
    std::memcpy(out + slash_end + sub_len, filename, (fn_len + 1) * sizeof(wchar_t));
    if (std::wcsstr(out, L"..") != nullptr) return false;
    return true;
}

inline void load_runtime_resources(
    HMODULE mod,
    std::atomic<uint32_t>& action_row_limit,
    WeaponRuleCatalog* weapon_rules_out = nullptr,
    WeaponPresentationManager* presentation_out = nullptr) noexcept {
    static char file_buf[kMaxIdentityFileBytes + 1]{};

    // 1. Load soulspire_native.json (preferred) with backwards-compatible fallback to crystaljobs-presentation.json.
    wchar_t cfg_path[MAX_PATH]{};
    size_t cfg_len = 0;
    bool loaded_cfg = false;
    const char* loaded_name = "soulspire_native.json";
    if (build_trusted_data_path(mod, L"soulspire_native.json", cfg_path, MAX_PATH) &&
        read_bounded_file_w(cfg_path, file_buf, kMaxPresentationFileBytes, cfg_len)) {
        loaded_cfg = true;
    } else if (build_trusted_data_path(mod, L"crystaljobs-presentation.json", cfg_path, MAX_PATH) &&
               read_bounded_file_w(cfg_path, file_buf, kMaxPresentationFileBytes, cfg_len)) {
        loaded_cfg = true;
        loaded_name = "crystaljobs-presentation.json";
    }

    if (loaded_cfg) {
        NativeConfig cfg{};
        if (parse_native_config_json(file_buf, cfg_len, cfg)) {
            set_log_level(cfg.log_level);
            action_row_limit.store(cfg.action_row_max_chars, std::memory_order_relaxed);
            publish_search_presentation(cfg);
            log_message(LOG_LEVEL_INFO, "Loaded %s (tracking=%d, offsetX=%d, widths=%u, modules=0x%X)",
                loaded_name, cfg.tracking_px, cfg.offset_x_px, cfg.use_glyph_widths ? 1u : 0u, cfg.enabled_modules_mask);
        } else {
            publish_search_presentation(cfg);
            log_message(LOG_LEVEL_WARN, "Invalid %s (%s); using default configuration", loaded_name, cfg.warning);
        }
    } else {
        publish_search_presentation(default_native_config());
    }

    // 2. Load authoritative runtime 66-Soul identity table (plugins/data/soul-identities.json).
    wchar_t ident_path[MAX_PATH]{};
    size_t file_len = 0;
    if (build_trusted_data_path(mod, L"soul-identities.json", ident_path, MAX_PATH) &&
        read_bounded_file_w(ident_path, file_buf, kMaxIdentityFileBytes, file_len)) {
        static RuntimeIdentityTable parsed_table{};
        if (parse_runtime_identity_json(file_buf, file_len, parsed_table)) {
            publish_runtime_identity_snapshot(parsed_table);
            log_message(LOG_LEVEL_INFO, "Loaded runtime soul-identities.json (66 souls, hash=%s)",
                parsed_table.registry_hash);
        } else {
            clear_runtime_identity_snapshot(parsed_table.status, parsed_table.warning);
            log_message(LOG_LEVEL_WARN, "Invalid soul-identities.json (%s); using compiled fallback (%s)",
                parsed_table.warning, kRegistryHash);
        }
    } else {
        clear_runtime_identity_snapshot(IDENTITY_STATUS_FILE_MISSING,
            "soul-identities.json missing or unreadable; using compiled fallback");
        log_message(LOG_LEVEL_WARN, "data\\soul-identities.json not found; using compiled fallback (%s)",
            kRegistryHash);
    }

    // 3. Load authoritative registry-generated weapon config (plugins/data/soul-weapon-config.json).
    // Fail-closed on missing, stale, schema-mismatched, or integrity-failed config.
    if (weapon_rules_out != nullptr && presentation_out != nullptr) {
        wchar_t wc_path[MAX_PATH]{};
        size_t wc_len = 0;
        std::unique_ptr<char[]> wc_buf(new (std::nothrow) char[kMaxWeaponConfigFileBytes + 1]{});
        const auto* id_snap = g_active_runtime_identity.load(std::memory_order_acquire);
        const char* expected_hash = (id_snap != nullptr && id_snap->active) ? id_snap->registry_hash : kRegistryHash;

        if (wc_buf != nullptr &&
            build_trusted_data_path(mod, L"soul-weapon-config.json", wc_path, MAX_PATH) &&
            read_bounded_file_w(wc_path, wc_buf.get(), kMaxWeaponConfigFileBytes, wc_len)) {
            bool loaded_ok = false;
            try {
                ParsedWeaponConfig parsed_wc{};
                if (parse_weapon_config_json(wc_buf.get(), wc_len, expected_hash, parsed_wc)) {
                    weapon_rules_out->replace_all(
                        parsed_wc.native_rules.empty() ? nullptr : parsed_wc.native_rules.data(),
                        static_cast<uint32_t>(parsed_wc.native_rules.size()));
                    presentation_out->replace_config(
                        parsed_wc.bindings,
                        parsed_wc.profiles,
                        parsed_wc.registry_hash,
                        parsed_wc.weapon_config_hash);
                    loaded_ok = true;
                    log_message(LOG_LEVEL_INFO,
                        "Loaded runtime soul-weapon-config.json (%u rules, %u profiles, hash=%s)",
                        static_cast<unsigned>(parsed_wc.native_rules.size()),
                        static_cast<unsigned>(parsed_wc.profiles.size()),
                        parsed_wc.weapon_config_hash);

                    // Optional developer-only calibration overrides (strictly disabled by default).
                    wchar_t cal_path[MAX_PATH]{};
                    size_t cal_len = 0;
                    if (build_trusted_data_path(mod, L"soul-weapon-calibration.local.json", cal_path, MAX_PATH) &&
                        read_bounded_file_w(cal_path, wc_buf.get(), kMaxWeaponConfigFileBytes, cal_len)) {
                        if (apply_weapon_calibration_json(wc_buf.get(), cal_len, *presentation_out)) {
                            log_message(LOG_LEVEL_INFO,
                                "Applied developer weapon calibration overrides from soul-weapon-calibration.local.json");
                        }
                    }
                } else {
                    log_message(LOG_LEVEL_WARN,
                        "Invalid soul-weapon-config.json (%s); failing closed to vanilla weapon behavior",
                        parsed_wc.warning);
                }
            } catch (...) {
                log_message(LOG_LEVEL_WARN,
                    "Exception loading soul-weapon-config.json; failing closed to vanilla weapon behavior");
            }
            if (!loaded_ok) {
                weapon_rules_out->clear();
                presentation_out->clear();
            }
        } else {
            weapon_rules_out->clear();
            presentation_out->clear();
            log_message(LOG_LEVEL_WARN,
                "data\\soul-weapon-config.json not found; failing closed to vanilla weapon behavior");
        }
    }
}
#endif

} // namespace soulspire::native
