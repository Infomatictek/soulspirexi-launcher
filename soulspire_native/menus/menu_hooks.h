#pragma once
#include <cstddef>

namespace soulspire::native {

// Bounded single-line helpwind description limit so long Soul descriptions never
// overflow FFXI's top help bar.
static constexpr size_t kHelpWindDescMaxChars = 96;

} // namespace soulspire::native
