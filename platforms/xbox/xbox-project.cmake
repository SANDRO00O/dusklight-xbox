# Included once, from the top-level project() call, via CMAKE_PROJECT_TOP_LEVEL_INCLUDES
# (set in cmake/toolchains/xbox-uwp-x64.cmake). See docs/xbox-port.md.
#
# Everything here runs deferred, at the end of the top-level directory, so that the targets created
# by Aurora/Borealis and the game already exist.

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

# --- Link stubs for the game executable ---------------------------------------------------------
# Dawn's abseil references GetWindowsLocalTimeZone(), which is not built for UWP (see the file).
function(_dusk_xbox_link_stubs)
  if(TARGET dusklight)
    target_sources(dusklight PRIVATE "${CMAKE_SOURCE_DIR}/platforms/xbox/abseil_uwp_stubs.cpp")
    message(STATUS "xbox: added abseil_uwp_stubs.cpp to dusklight")
  endif()
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_sdl_cxx17)
cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_link_stubs)
