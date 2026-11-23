#pragma once
#include "../registry/runtime_identity.h"

namespace soulspire::native {

// Canonical configuration alias (soulspire_native.json, with automatic fallback to legacy crystaljobs-presentation.json).
using NativeConfig = SearchPresentationConfig;

inline bool parse_native_config_json(const char* data, size_t len, NativeConfig& out) noexcept {
    return parse_presentation_config_json(data, len, out);
}

inline NativeConfig default_native_config() noexcept {
    return default_presentation_config();
}

} // namespace soulspire::native
