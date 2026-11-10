# Experimental toolchain file: Xbox One S / One X / Series X|S in Dev Mode (UWP, x64).
#
# CMake only supports CMAKE_SYSTEM_NAME=WindowsStore with the Visual Studio generators,
# so this does not work with the Ninja presets used by the other platforms.
#
# Usage:
#   cmake -S . -B build/xbox-uwp-x64 -G "Visual Studio 17 2022" -A x64 ^
#         -DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xbox-uwp-x64.cmake
#   cmake --build build/xbox-uwp-x64 --config RelWithDebInfo --target dusklight
#
# STATUS: scaffolding only, untested. See docs/xbox-port.md for the known blockers.

set(CMAKE_SYSTEM_NAME WindowsStore)
set(CMAKE_SYSTEM_VERSION 10.0)
set(CMAKE_SYSTEM_PROCESSOR AMD64)

set(DUSK_PLATFORM_XBOX ON CACHE BOOL "Building for Xbox (UWP, Dev Mode)" FORCE)

# UWP apps use the DLL C runtime (VCLibs framework package).
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>DLL" CACHE STRING "" FORCE)

# Static libraries only: avoids packaging extra DLLs into the AppX.
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)

# Features that cannot work (or are unnecessary) on a Dev Mode UWP target.
# Code mods rely on funchook runtime code patching.
set(DUSK_ENABLE_CODE_MODS OFF CACHE BOOL "" FORCE)
set(DUSK_ENABLE_OPUS OFF CACHE BOOL "" FORCE)
set(BOREALIS_ENABLE_DISCORD OFF CACHE BOOL "" FORCE)
set(BOREALIS_ENABLE_SENTRY OFF CACHE BOOL "" FORCE)
# 'none' keeps the borealis::http/ws/update targets (the game links them) but with stub backends.
set(BOREALIS_HTTP_BACKEND none CACHE STRING "" FORCE)

# Aurora has no prebuilt SDL3/Dawn/nod packages for WindowsStore, so build from source.
set(AURORA_SDL3_PROVIDER vendor CACHE STRING "" FORCE)
set(AURORA_SDL3_LINKAGE static CACHE STRING "" FORCE)
set(AURORA_DAWN_PROVIDER vendor CACHE STRING "" FORCE)
set(AURORA_DAWN_LINKAGE static CACHE STRING "" FORCE)
set(AURORA_NOD_PROVIDER vendor CACHE STRING "" FORCE)
set(AURORA_NOD_LINKAGE static CACHE STRING "" FORCE)
