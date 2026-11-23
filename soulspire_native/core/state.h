#pragma once
#include <cstdint>

namespace soulspire::native {

struct ActiveSoulOverride {
    bool active = false;
    uint8_t job = 0;
    uint8_t branch = 0;
    uint32_t character = 0;
};

} // namespace soulspire::native
