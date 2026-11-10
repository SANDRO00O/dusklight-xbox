# Experimental toolchain file: Xbox One S / One X / Series X|S in Dev Mode (UWP, x64).
#
# CMake only supports CMAKE_SYSTEM_NAME=WindowsStore with the Visual Studio generators,
# so this does not work with the Ninja presets used by the other platforms.
#
# Usage:
#   cmake -S . -B build/xbox-uwp-x64 -A x64 "-DCMAKE_TOOLCHAIN_FILE=cmake/toolchains/xbox-uwp-x64.cmake"
#   cmake --build build/xbox-uwp-x64 --config RelWithDebInfo --target dusklight
# (no -G: CMake picks the newest installed Visual Studio; quote the -D argument in PowerShell)
#
# STATUS: scaffolding only. See docs/xbox-port.md for the known blockers.

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

# CMake treats WindowsStore as cross-compiling. Dawn's protobuf.cmake then requires a host protoc
# ("When cross-compiling, you must specify a host protoc"). Protobuf is only used for Tint's IR
# binary format and fuzzers, and TINT_BUILD_IR_BINARY defaults to DAWN_BUILD_PROTOBUF, so turn both
# off explicitly.
set(DAWN_BUILD_PROTOBUF OFF CACHE BOOL "" FORCE)
set(TINT_BUILD_IR_BINARY OFF CACHE BOOL "" FORCE)

# UWP projects enable /sdl by default. /sdl promotes C4146, C4703 and C4996 to errors, which breaks
# third-party code (Dawn Device.cpp / BufferD3D11.cpp, libpng pngread.c / pngwrite.c). Turn it off.
set(CMAKE_C_FLAGS_INIT "/sdl-")
set(CMAKE_CXX_FLAGS_INIT "/sdl-")

# sqlite3 (Aurora's shader/pipeline cache) uses CreateFileA/W, GetFileSize, HeapValidate etc., which
# are not in the UWP app API partition. SQLITE_OS_WINRT selects its WinRT file layer instead.
set(CMAKE_C_FLAGS_INIT "${CMAKE_C_FLAGS_INIT} /DSQLITE_OS_WINRT=1")
