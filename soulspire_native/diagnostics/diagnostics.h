#pragma once
#include "../core/config.h"
#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cwchar>

namespace soulspire::native {

inline std::atomic<uint32_t> g_log_level{LOG_LEVEL_INFO};
inline std::atomic<uint32_t> g_suppressed_logs{0};

#if defined(_WIN32)
inline void append_log_file_line(const char* line) noexcept {
    if (line == nullptr) return;
    HMODULE self = nullptr;
    if (!GetModuleHandleExW(
            GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
            reinterpret_cast<LPCWSTR>(&append_log_file_line),
            &self) || self == nullptr) {
        return;
    }
    wchar_t path[MAX_PATH]{};
    const DWORD len = GetModuleFileNameW(self, path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH - 24) return;
    wchar_t* slash = nullptr;
    for (DWORD i = 0; i < len; ++i) {
        if (path[i] == L'\\' || path[i] == L'/') slash = path + i;
    }
    if (slash == nullptr) return;
    std::swprintf(slash + 1, static_cast<size_t>(MAX_PATH - (slash + 1 - path)), L"soulspire_native.log");
    FILE* f = nullptr;
    if (_wfopen_s(&f, path, L"a") == 0 && f != nullptr) {
        std::fputs(line, f);
        std::fclose(f);
    }
}
#endif

inline void set_log_level(uint32_t level) noexcept {
    if (level > LOG_LEVEL_DEBUG) level = LOG_LEVEL_DEBUG;
    g_log_level.store(level, std::memory_order_relaxed);
}

inline uint32_t get_log_level() noexcept {
    return g_log_level.load(std::memory_order_relaxed);
}

inline void log_message(uint32_t level, const char* fmt, ...) noexcept {
    if (level > g_log_level.load(std::memory_order_relaxed)) {
        g_suppressed_logs.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    const char* tag = "INFO";
    if (level == LOG_LEVEL_ERROR) tag = "ERROR";
    else if (level == LOG_LEVEL_WARN) tag = "WARN";
    else if (level == LOG_LEVEL_DEBUG) tag = "DEBUG";

    char body[256]{};
    va_list args;
    va_start(args, fmt);
    std::vsnprintf(body, sizeof(body), fmt, args);
    va_end(args);

    char line[320]{};
    std::snprintf(line, sizeof(line), "[Soulspire Native] [%s] %s\n", tag, body);
#if defined(_WIN32)
    OutputDebugStringA(line);
    if (level <= LOG_LEVEL_INFO) {
        append_log_file_line(line);
    }
#else
    (void)line;
#endif
}

} // namespace soulspire::native
