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

# --- Link stubs for the game executable ---------------------------------------------------------
# Dawn's abseil references GetWindowsLocalTimeZone(), which is not built for UWP (see the file).
function(_dusk_xbox_link_stubs)
  if(TARGET dusklight)
    target_sources(dusklight PRIVATE "${CMAKE_SOURCE_DIR}/platforms/xbox/abseil_uwp_stubs.cpp")
    message(STATUS "xbox: added abseil_uwp_stubs.cpp to dusklight")
  endif()
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_sdl_cxx17)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_freetype_system)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_link_stubs)
