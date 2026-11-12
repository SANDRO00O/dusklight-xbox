// Link-time stubs for the Xbox (UWP) build. See platforms/xbox/xbox-project.cmake.

#include <string>

// Dawn bundles abseil. absl's cctz time-zone code calls GetWindowsLocalTimeZone() under _WIN32, but
// its definition (time_zone_name_win.cc) is not part of the UWP abseil build: it loads icu.dll from
// the System32 directory, which a UWP app cannot do. An empty result is the documented "lookup
// failed" value: cctz keeps its default zone (UTC, or whatever TZ says).
//
// The namespaces are written out without abseil's inline ABI namespace on purpose: the unresolved
// symbol reported by the linker is ?GetWindowsLocalTimeZone@cctz@time_internal@absl@@..., i.e.
// Dawn's abseil is built with the inline namespace disabled.
namespace absl {
namespace time_internal {
namespace cctz {

std::string GetWindowsLocalTimeZone() {
    return {};
}

}  // namespace cctz
}  // namespace time_internal
}  // namespace absl
