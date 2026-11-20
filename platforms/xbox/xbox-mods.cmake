# Native (code) mods support for the Xbox build. Included once from the top-level project() call, via
# CMAKE_PROJECT_TOP_LEVEL_INCLUDES (cmake/toolchains/xbox-uwp-x64.cmake), after xbox-project.cmake.
# Does nothing when DUSK_ENABLE_CODE_MODS is off (platforms/xbox/code-mods.txt).

get_property(_dusk_xbox_mods_done GLOBAL PROPERTY DUSK_XBOX_MODS_INCLUDE_DONE)
if(_dusk_xbox_mods_done)
  return()
endif()
set_property(GLOBAL PROPERTY DUSK_XBOX_MODS_INCLUDE_DONE TRUE)

# --- Native (code) mods: funchook for UWP -----------------------------------------------------------
# DUSK_ENABLE_CODE_MODS is decided in the toolchain file (platforms/xbox/code-mods.txt). The top-level
# CMakeLists.txt then fetches funchook v1.1.3 with FetchContent; the first FetchContent_Declare of a name
# wins, so declaring it here (this file runs from the project() call, before the top-level declaration)
# swaps in the UWP patch (VirtualAllocFromApp / VirtualProtectFromApp, no psapi, see
# PatchFunchookUwp.cmake). Same repository and tag as the top-level declaration.
if(DUSK_ENABLE_CODE_MODS)
  include(FetchContent)
  FetchContent_Declare(funchook
    GIT_REPOSITORY https://github.com/kubo/funchook.git
    GIT_TAG v1.1.3
    GIT_SHALLOW TRUE
    GIT_PROGRESS TRUE
    PATCH_COMMAND ${CMAKE_COMMAND} -DSOURCE_DIR=<SOURCE_DIR> -P ${CMAKE_CURRENT_LIST_DIR}/PatchFunchookUwp.cmake
    EXCLUDE_FROM_ALL
  )
  message(STATUS "xbox: native mods ON: funchook declared with platforms/xbox/PatchFunchookUwp.cmake")
else()
  message(STATUS "xbox: native mods OFF (platforms/xbox/code-mods.txt or fallback)")
endif()

# --- Visual C++ runtime DLLs for desktop-built mods ----------------------------------------------------
# A native mod (mod.dll) built with the normal Windows toolchain imports vcruntime140.dll / msvcp140.dll.
# A UWP package only gets the *_app variants from the VCLibs framework, so loading such a mod failed with
# "module not found" (error 126, see jit-probe.log). With crt = on in platforms/xbox/code-mods.txt the
# redistributable DLLs of the build machine are added as package content (package root, next to
# dusklight.exe, which is on the DLL search path of the mod loader). Only when native mods are on, and only
# DLLs that exist are added. Experimental: whether the console loads these desktop DLLs is untested.
function(_dusk_xbox_package_mod_crt)
  if(NOT TARGET dusklight OR NOT DUSK_ENABLE_CODE_MODS)
    return()
  endif()
  set(_cfg "${CMAKE_SOURCE_DIR}/platforms/xbox/code-mods.txt")
  if(EXISTS "${_cfg}")
    file(READ "${_cfg}" _txt)
    if(_txt MATCHES "(^|\n)[ \t]*crt[ \t]*=[ \t]*off")
      message(STATUS "xbox: crt = off, no VC runtime DLLs bundled")
      return()
    endif()
  endif()
  # <VS>/VC/Tools/MSVC/<ver>/bin/Hostx64/x64/cl.exe  ->  <VS>/VC
  get_filename_component(_cl_dir "${CMAKE_CXX_COMPILER}" DIRECTORY)
  set(_vc "${_cl_dir}")
  foreach(_i RANGE 5)
    get_filename_component(_vc "${_vc}" DIRECTORY)
  endforeach()
  set(_redist_dirs "")
  if(DEFINED ENV{VCToolsRedistDir})
    file(TO_CMAKE_PATH "$ENV{VCToolsRedistDir}" _env_redist)
    file(GLOB _d "${_env_redist}/x64/Microsoft.VC*.CRT")
    list(APPEND _redist_dirs ${_d})
  endif()
  file(GLOB _d "${_vc}/Redist/MSVC/*/x64/Microsoft.VC*.CRT")
  list(SORT _d COMPARE NATURAL ORDER DESCENDING)
  list(APPEND _redist_dirs ${_d})
  set(_crt_dir "")
  foreach(_d IN LISTS _redist_dirs)
    if(EXISTS "${_d}/vcruntime140.dll")
      set(_crt_dir "${_d}")
      break()
    endif()
  endforeach()
  if(NOT _crt_dir)
    message(WARNING "xbox: VC runtime redistributable DLLs not found (looked under ${_vc}/Redist/MSVC); desktop-built mods may fail to load")
    return()
  endif()
  set(_count 0)
  foreach(_name IN ITEMS vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll)
    set(_dll "${_crt_dir}/${_name}")
    if(NOT EXISTS "${_dll}")
      continue()
    endif()
    target_sources(dusklight PRIVATE "${_dll}")
    set_source_files_properties("${_dll}" PROPERTIES
      VS_DEPLOYMENT_CONTENT TRUE
      VS_DEPLOYMENT_LOCATION "."
      VS_COPY_TO_OUT_DIR Always)
    math(EXPR _count "${_count}+1")
  endforeach()
  message(STATUS "xbox: ${_count} VC runtime DLL(s) from ${_crt_dir} added to the package root (for desktop-built mods)")
endfunction()

cmake_language(DEFER DIRECTORY "${CMAKE_SOURCE_DIR}" CALL _dusk_xbox_package_mod_crt)
