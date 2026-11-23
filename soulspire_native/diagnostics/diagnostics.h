#pragma once
#include "../core/config.h"
#include <atomic>
#include <cstdarg>
#include <cstdio>

namespace soulspire::native {

inline std::atomic<uint32_t> g_log_level{LOG_LEVEL_WARN};
inline std::atomic<uint32_t> g_suppressed_logs{0};

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
#else
    (void)line;
#endif
}

} // namespace soulspire::native
