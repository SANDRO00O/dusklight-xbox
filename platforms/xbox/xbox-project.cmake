# Included once, from the top-level project() call, via CMAKE_PROJECT_TOP_LEVEL_INCLUDES
# (set in cmake/toolchains/xbox-uwp-x64.cmake). See docs/xbox-port.md.
#
# Everything here runs deferred, at the end of the top-level directory, so that the targets created
# by Aurora/Borealis and the game already exist.

# The toolchain file is evaluated more than once by CMake, which can queue this include twice.
get_property(_dusk_xbox_project_done GLOBAL PROPERTY DUSK_XBOX_PROJECT_INCLUDE_DONE)
if(_dusk_xbox_project_done)
  return()
endif()
set_property(GLOBAL PROPERTY DUSK_XBOX_PROJECT_INCLUDE_DONE TRUE)

# --- SDL3: build as C++17 -----------------------------------------------------------------------
# The root CMakeLists.txt sets CMAKE_CXX_STANDARD 20 and every subproject inherits it. The UWP SDL3
# fork compiles its WinRT sources with C++/CX (/ZW), and cl.exe rejects the combination:
#   D8016: '/ZW' and '/std:c++20' command-line options are incompatible
# Setting the target property overrides the inherited default, so SDL (and only SDL) becomes C++17.
function(_dusk_xbox_sdl_cxx17)
  foreach(_t IN ITEMS SDL3-static SDL3-shared)
    if(TARGET ${_t})
      set_target_properties(${_t} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
      message(STATUS "xbox: ${_t} -> CXX_STANDARD 17 (C++/CX /ZW does not support C++20)")
    endif()
  endforeach()
endfunction()

# --- FreeType: portable system layer ------------------------------------------------------------
# FreeType's CMake picks builds/windows/ftsystem.c whenever WIN32 is set. That file calls CreateFileA
# (and friends), which are not in the UWP API set; the missing declaration made cl.exe assume an
# `int` return (warnings C4013/C4047), truncating the 64-bit HANDLE. src/base/ftsystem.c is the
# portable stdio implementation and builds everywhere.
function(_dusk_xbox_freetype_system)
  if(NOT TARGET freetype)
    return()
  endif()
  get_target_property(_srcs freetype SOURCES)
  if(NOT _srcs)
    return()
  endif()
  set(_new "")
  set(_replaced FALSE)
  foreach(_s IN LISTS _srcs)
    if(_s MATCHES "builds/windows/ftsystem\\.c$")
      string(REGEX REPLACE "builds/windows/ftsystem\\.c$" "src/base/ftsystem.c" _s "${_s}")
      set(_replaced TRUE)
    endif()
    list(APPEND _new "${_s}")
  endforeach()
  if(_replaced)
    set_property(TARGET freetype PROPERTY SOURCES ${_new})
    message(STATUS "xbox: freetype uses src/base/ftsystem.c (builds/windows/ftsystem.c needs CreateFileA)")
  else()
    message(STATUS "xbox: freetype sources do not use builds/windows/ftsystem.c, nothing to replace")
  endif()
endfunction()

# --- Extra sources for the game executable ------------------------------------------------------
# * abseil_uwp_stubs.cpp: Dawn's abseil references GetWindowsLocalTimeZone(), which is not built for
#   UWP (see the file).
# * xbox_gfx_probe.cpp, xbox_gfx_probe_deep.cpp: SEH-guarded D3D11/D3D12 probe run before Aurora
#   initialises (see the files and the m_Do_main.cpp patch in Apply-Patches.ps1).
# * xbox_input_diag.cpp: enables SDL's WGI joystick driver + controller diagnostics (input-diag.log),
#   same hook.
# * xbox_crash_diag.cpp: crash / hang diagnostics (crash-diag.log), started from xbox_input_diag.cpp.
#   The linker writes a map (/MAP) that ci.ps1 turns into symbols/dusklight.sym (see below).
# * xbox_file_picker.cpp: FileOpenPicker for the disc image, called from borealis' file_select.cpp
#   (patched in Apply-Patches.ps1).
# * xbox_jit_probe.cpp: one-time feasibility probe for native mods (executable memory, image patching,
#   module loading); writes jit-probe.log, starts itself from a static initialiser.
function(_dusk_xbox_link_stubs)
  if(TARGET dusklight)
    target_sources(dusklight PRIVATE
      "${CMAKE_SOURCE_DIR}/platforms/xbox/abseil_uwp_stubs.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_gfx_probe.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_gfx_probe_deep.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_input_diag.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_crash_diag.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_file_picker.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_jit_probe.cpp")
    target_link_options(dusklight PRIVATE "/MAP:${CMAKE_BINARY_DIR}/dusklight.map")
    message(STATUS "xbox: added abseil_uwp_stubs.cpp, xbox_gfx_probe*.cpp, xbox_input_diag.cpp, xbox_crash_diag.cpp and xbox_file_picker.cpp to dusklight; linker map -> ${CMAKE_BINARY_DIR}/dusklight.map")
  endif()
endfunction()

# --- res/ into the MSIX package -----------------------------------------------------------------
# The game loads fonts, RmlUi stylesheets, images and more from <exe dir>/res. The top-level
# CMakeLists copies res/ next to the exe after linking, but a UWP package only contains files that
# are marked as deployment content in the Visual Studio project, so the installed app had no res/
# (log: "Failed to open file ...\\res\\FiraSans-Regular.ttf"). Add every file under res/ as content,
# deployed to the same relative directory inside the package.
#
# Also packaged: <build>/dusklight.sym -> symbols/dusklight.sym, the function table used by
# xbox_crash_diag.cpp. ci.ps1 writes a placeholder before configuring, then replaces it with the real
# table (generated from the linker map by Make-Symbols.ps1) and builds again to repackage it.
function(_dusk_xbox_package_resources)
  if(NOT TARGET dusklight)
    return()
  endif()
  file(GLOB_RECURSE _res_files CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/res/*")
  set(_count 0)
  foreach(_f IN LISTS _res_files)
    if(IS_DIRECTORY "${_f}")
      continue()
    endif()
    file(RELATIVE_PATH _rel "${CMAKE_SOURCE_DIR}" "${_f}")
    get_filename_component(_dir "${_rel}" DIRECTORY)
    target_sources(dusklight PRIVATE "${_f}")
    set_source_files_properties("${_f}" PROPERTIES
      VS_DEPLOYMENT_CONTENT 1
      VS_DEPLOYMENT_LOCATION "${_dir}")
    math(EXPR _count "${_count}+1")
  endforeach()
  message(STATUS "xbox: ${_count} file(s) under res/ marked as package content")

  set(_sym "${CMAKE_BINARY_DIR}/dusklight.sym")
  if(NOT EXISTS "${_sym}")
    file(WRITE "${_sym}" "no symbols in this build\n")
  endif()
  target_sources(dusklight PRIVATE "${_sym}")
  set_source_files_properties("${_sym}" PROPERTIES
    GENERATED TRUE
    VS_DEPLOYMENT_CONTENT 1
    VS_DEPLOYMENT_LOCATION "symbols")
  message(STATUS "xbox: ${_sym} marked as package content (symbols/)")

  # Symbol manifest for native mods (by-name hooks). The AppX package is built BEFORE the post-build step that
  # embeds the manifest into dusklight.exe (build.log of 2026-11-28), so the packaged exe has none. ci.ps1 copies
  # the blob out of the built exe into this file and builds again; manifest.cpp (Apply-Patches-Manifest.ps1)
  # reads it when the exe has no embedded manifest. Placeholder text (shorter than a header) is ignored.
  set(_symdb "${CMAKE_BINARY_DIR}/dusklight.symdb")
  if(NOT EXISTS "${_symdb}")
    file(WRITE "${_symdb}" "no symbol manifest in this build\n")
  endif()
  target_sources(dusklight PRIVATE "${_symdb}")
  set_source_files_properties("${_symdb}" PROPERTIES
    GENERATED TRUE
    VS_DEPLOYMENT_CONTENT 1
    VS_DEPLOYMENT_LOCATION "symbols")
  message(STATUS "xbox: ${_symdb} marked as package content (symbols/)")
endfunction()

# --- Branded tile/logo/splash images in the MSIX package -----------------------------------------
# CMake's default manifest (it writes one because the target has no *.appxmanifest source) points at
# placeholder PNGs under CMakeFiles/dusklight.dir that it adds only as plain Image items, WITHOUT
# deployment content, so they never enter the package. On the console the splash screen then showed the
# manifest's background colour (#336699, blue) and a square with an X (image missing).
# The fork 999sian/dusklight packages its images as Image items that are also deployment content in the
# package's Assets folder ("Image items must enter the PRI index so unqualified manifest paths
# resolve"). Do the same: generate the PNGs from res/icon.png at configure time and add them that way.
# Patch-Manifest.ps1 then points the manifest at Assets\<name>.png, but only when the project really
# contains these files (otherwise the package could not be installed).
function(_dusk_xbox_package_assets)
  if(NOT TARGET dusklight)
    return()
  endif()
  set(_assets_dir "${CMAKE_BINARY_DIR}/Assets")
  execute_process(
    COMMAND powershell.exe -NoProfile -ExecutionPolicy Bypass
            -File "${CMAKE_SOURCE_DIR}/platforms/xbox/Generate-Assets.ps1"
            -InputPng "${CMAKE_SOURCE_DIR}/res/icon.png" -OutputDir "${_assets_dir}"
    RESULT_VARIABLE _rc OUTPUT_VARIABLE _out ERROR_VARIABLE _err)
  if(NOT _rc EQUAL 0)
    message(WARNING "xbox: Generate-Assets.ps1 failed (${_rc}): ${_err} ${_out}")
    return()
  endif()
  set(_count 0)
  foreach(_name IN ITEMS StoreLogo Square44x44Logo Square150x150Logo SplashScreen)
    set(_png "${_assets_dir}/${_name}.png")
    if(NOT EXISTS "${_png}")
      message(WARNING "xbox: ${_png} was not generated")
      continue()
    endif()
    target_sources(dusklight PRIVATE "${_png}")
    set_source_files_properties("${_png}" PROPERTIES
      VS_TOOL_OVERRIDE Image
      VS_DEPLOYMENT_CONTENT TRUE
      VS_DEPLOYMENT_LOCATION "Assets")
    math(EXPR _count "${_count}+1")
  endforeach()
  message(STATUS "xbox: ${_count} branded image(s) in ${_assets_dir} added as package content (Assets/)")
endfunction()

# --- Bundled pipeline list in the package root ---------------------------------------------------
# Fetch-PipelineSeed.ps1 (run by Apply-Patches-Disc.ps1 before configure) stages upstream's
# initial_pipeline_cache.db. Aurora looks for it next to the executable (resourcesPath) at start and
# merges it into pipeline_cache.db, so every known material is compiled in the background instead of on
# first use. Same packaging as the fork 999sian/dusklight (package root, deployment content).
function(_dusk_xbox_package_pipeline_seed)
  if(NOT TARGET dusklight)
    return()
  endif()
  set(_seed "${CMAKE_SOURCE_DIR}/build/ext/pipeline-seed/initial_pipeline_cache.db")
  if(NOT EXISTS "${_seed}")
    message(WARNING "xbox: ${_seed} not found; shaders will only be compiled when first used")
    return()
  endif()
  target_sources(dusklight PRIVATE "${_seed}")
  set_source_files_properties("${_seed}" PROPERTIES
    VS_DEPLOYMENT_CONTENT TRUE
    VS_DEPLOYMENT_LOCATION "."
    VS_COPY_TO_OUT_DIR Always)
  message(STATUS "xbox: ${_seed} added to the package root")
endfunction()

# --- HTTP backend for borealis::http (online mods) ----------------------------------------------------
# The toolchain builds borealis with BOREALIS_HTTP_BACKEND=none (its Windows backend, WinHTTP, is not part
# of the UWP API set), so borealis::http::available() was false and the online mod browser was disabled.
# Replace borealis' stub src/http/no_backend.cpp in the borealis_http target with
# platforms/xbox/xbox_http_winrt.cpp, a transport on Windows.Web.Http (C++/WinRT). It needs the C++/WinRT
# headers of the Windows SDK (<kit>/Include/<version>/cppwinrt); when they are not found the stub stays
# and the build is as before.
function(_dusk_xbox_http_backend)
  if(NOT TARGET borealis_http)
    return()
  endif()
  set(_impl "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_http_winrt.cpp")
  if(NOT EXISTS "${_impl}")
    return()
  endif()

  set(_roots "")
  if(DEFINED ENV{WindowsSdkDir})
    list(APPEND _roots "$ENV{WindowsSdkDir}")
  endif()
  foreach(_view IN ITEMS "" "WOW6432Node\\")
    get_filename_component(_reg
      "[HKEY_LOCAL_MACHINE\\SOFTWARE\\${_view}Microsoft\\Windows Kits\\Installed Roots;KitsRoot10]"
      ABSOLUTE)
    if(_reg AND NOT _reg MATCHES "HKEY")
      list(APPEND _roots "${_reg}")
    endif()
  endforeach()
  list(APPEND _roots "C:/Program Files (x86)/Windows Kits/10")

  set(_versions "")
  if(CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION)
    list(APPEND _versions "${CMAKE_VS_WINDOWS_TARGET_PLATFORM_VERSION}")
  endif()
  set(_cppwinrt "")
  foreach(_root IN LISTS _roots)
    file(TO_CMAKE_PATH "${_root}" _root)
    set(_candidates ${_versions})
    file(GLOB _found RELATIVE "${_root}/Include" "${_root}/Include/10.*")
    list(SORT _found COMPARE NATURAL ORDER DESCENDING)
    list(APPEND _candidates ${_found})
    foreach(_v IN LISTS _candidates)
      if(EXISTS "${_root}/Include/${_v}/cppwinrt/winrt/Windows.Web.Http.h")
        set(_cppwinrt "${_root}/Include/${_v}/cppwinrt")
        break()
      endif()
    endforeach()
    if(_cppwinrt)
      break()
    endif()
  endforeach()
  if(NOT _cppwinrt)
    message(WARNING "xbox: C++/WinRT headers not found; borealis::http stays without a backend (online mods unavailable)")
    return()
  endif()

  get_target_property(_srcs borealis_http SOURCES)
  set(_new "")
  set(_replaced FALSE)
  foreach(_s IN LISTS _srcs)
    if(_s MATCHES "http/no_backend\\.cpp$")
      list(APPEND _new "${_impl}")
      set(_replaced TRUE)
    else()
      list(APPEND _new "${_s}")
    endif()
  endforeach()
  if(NOT _replaced)
    message(WARNING "xbox: borealis_http has no src/http/no_backend.cpp (sources: ${_srcs}); HTTP backend not replaced")
    return()
  endif()
  set_property(TARGET borealis_http PROPERTY SOURCES ${_new})
  target_include_directories(borealis_http PRIVATE
    "${CMAKE_SOURCE_DIR}/extern/borealis/src"
    "${_cppwinrt}")
  message(STATUS "xbox: borealis_http uses platforms/xbox/xbox_http_winrt.cpp (Windows.Web.Http); C++/WinRT headers: ${_cppwinrt}")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_sdl_cxx17)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_freetype_system)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_link_stubs)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_package_resources)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_package_assets)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_package_pipeline_seed)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_http_backend)
