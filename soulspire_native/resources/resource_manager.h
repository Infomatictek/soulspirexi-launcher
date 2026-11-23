#pragma once
#include "../core/config.h"
#include "../dat_virtualization/dat_virtualization.h"
#include "../diagnostics/diagnostics.h"
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

inline void load_runtime_resources(HMODULE mod, std::atomic<uint32_t>& action_row_limit,
                                   DatVirtualizationManager* dat_virt = nullptr) noexcept {
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

    // 3. Load registry-compiled DAT text overrides (plugins/data/dat-text-overrides.json).
    if (dat_virt != nullptr) {
        dat_virt->configure(module_enabled(SOULSPIRE_NATIVE_MOD_DAT_VIRTUALIZATION));
        wchar_t dat_path[MAX_PATH]{};
        size_t dat_len = 0;
        std::unique_ptr<char[]> dat_buf(new (std::nothrow) char[kMaxDatTextFileBytes + 1]);
        if (dat_buf && build_trusted_data_path(mod, L"dat-text-overrides.json", dat_path, MAX_PATH) &&
            read_bounded_file_w(dat_path, dat_buf.get(), kMaxDatTextFileBytes, dat_len)) {
            dat_buf[dat_len] = '\0';
            if (dat_virt->load_from_json(dat_buf.get(), dat_len, true)) {
                log_message(LOG_LEVEL_INFO,
                    "Loaded runtime dat-text-overrides.json (%u overrides, gen=%u)",
                    dat_virt->override_count(), dat_virt->generation());
            } else {
                SoulspireNativeDatVirtStatus st{};
                dat_virt->fill_status(st);
                log_message(LOG_LEVEL_WARN,
                    "Invalid dat-text-overrides.json (%s); preserving vanilla DAT fallback",
                    st.warning);
            }
        } else {
            dat_virt->record_missing("data\\dat-text-overrides.json not found; vanilla DAT fallback active");
        }
    }
}
#endif

} // namespace soulspire::native
