# Included once, from the top-level project() call, via CMAKE_PROJECT_TOP_LEVEL_INCLUDES
# (set in cmake/toolchains/xbox-uwp-x64.cmake). See docs/xbox-port.md.
#
# The root CMakeLists.txt sets CMAKE_CXX_STANDARD 20 and every subproject inherits it. The UWP SDL3
# fork compiles its WinRT sources with C++/CX (/ZW), and cl.exe rejects the combination:
#   D8016: '/ZW' and '/std:c++20' command-line options are incompatible
# Setting the target property overrides the inherited default, so SDL (and only SDL) becomes C++17.
# It has to run after Aurora has created the SDL targets, hence the deferred call.

function(_dusk_xbox_sdl_cxx17)
  foreach(_t IN ITEMS SDL3-static SDL3-shared)
    if(TARGET ${_t})
      set_target_properties(${_t} PROPERTIES CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
      message(STATUS "xbox: ${_t} -> CXX_STANDARD 17 (C++/CX /ZW does not support C++20)")
    endif()
  endforeach()
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_sdl_cxx17)
