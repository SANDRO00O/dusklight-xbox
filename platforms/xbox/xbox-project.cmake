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
function(_dusk_xbox_link_stubs)
  if(TARGET dusklight)
    target_sources(dusklight PRIVATE
      "${CMAKE_SOURCE_DIR}/platforms/xbox/abseil_uwp_stubs.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_gfx_probe.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_gfx_probe_deep.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_input_diag.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_crash_diag.cpp"
      "${CMAKE_SOURCE_DIR}/platforms/xbox/xbox_file_picker.cpp")
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

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_sdl_cxx17)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_freetype_system)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_link_stubs)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_package_resources)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_package_assets)
