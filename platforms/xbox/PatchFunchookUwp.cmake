# Patches funchook v1.1.3 (the FetchContent copy) so it builds and works in a UWP app (Xbox Dev Mode).
# Run as   cmake -DSOURCE_DIR=<funchook-src> -P PatchFunchookUwp.cmake
# (platforms/xbox/xbox-mods.cmake declares funchook with this as PATCH_COMMAND; the declaration wins over
# the one in the top-level CMakeLists.txt because the first FetchContent_Declare of a name is the one used.)
#
# What UWP changes for funchook (src/funchook_windows.c):
#  * VirtualAlloc / VirtualProtect cannot create or change executable pages in a UWP app. The *FromApp
#    variants (needs the "codeGeneration" capability, declared by Patch-Manifest.ps1) can. platforms/xbox/
#    xbox_jit_probe.cpp showed on the console: RW<->RX and RWX work, executable image pages can be patched.
#  * GetMappedFileNameA (psapi) is only used for debug logging: stubbed out.
#  * FormatMessageA only formats error texts: stubbed (the numeric error code is still printed).
#  * GetModuleHandleEx is replaced by VirtualQuery(...).AllocationBase (the module base of an image mapping).
#  * the psapi link dependency is dropped, and the project no longer enables the ASM language (Visual Studio
#    generators do not support plain "ASM"; funchook has no assembly sources on x86-64).
# Idempotent (marker dusk_xbox_uwp). Fails (exit code 1 through message(FATAL_ERROR)) if an anchor is missing.

if(NOT SOURCE_DIR)
  message(FATAL_ERROR "PatchFunchookUwp.cmake: pass -DSOURCE_DIR=<funchook source dir>")
endif()

function(_patch_file path)
  # remaining arguments: pairs  <anchor> <replacement>  (read through ARGV<n>, they contain ';')
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "PatchFunchookUwp.cmake: ${path} does not exist")
  endif()
  file(READ "${path}" _c)
  string(REPLACE "\r\n" "\n" _c "${_c}")
  if(_c MATCHES "dusk_xbox_uwp")
    return()
  endif()
  set(_i 1)
  while(_i LESS ARGC)
    math(EXPR _j "${_i}+1")
    set(_anchor "${ARGV${_i}}")
    set(_repl "${ARGV${_j}}")
    string(FIND "${_c}" "${_anchor}" _pos)
    if(_pos EQUAL -1)
      message(FATAL_ERROR "PatchFunchookUwp.cmake: anchor not found in ${path}: ${_anchor}")
    endif()
    string(REPLACE "${_anchor}" "${_repl}" _c "${_c}")
    math(EXPR _i "${_i}+2")
  endwhile()
  file(WRITE "${path}" "${_c}")
endfunction()

set(_shim [=[#include "funchook_internal.h"

/* dusk_xbox_uwp: UWP port, see platforms/xbox/PatchFunchookUwp.cmake */
#undef GetMappedFileNameA
#define GetMappedFileNameA(p, a, b, s) ((DWORD)0)
#undef FormatMessageA
#define FormatMessageA(f, s, id, lang, buf, n, args) ((DWORD)0)
static BOOL dusk_uwp_module_from_addr(const void *addr, HMODULE *out)
{
    MEMORY_BASIC_INFORMATION mbi;
    if (VirtualQuery(addr, &mbi, sizeof(mbi)) == 0 || mbi.AllocationBase == NULL) {
        return FALSE;
    }
    *out = (HMODULE)mbi.AllocationBase;
    return TRUE;
}
#undef GetModuleHandleEx
#define GetModuleHandleEx(flags, addr, out) dusk_uwp_module_from_addr((addr), (out))
#define VirtualAlloc(a, s, t, p) VirtualAllocFromApp((a), (s), (t), (p))
#define VirtualProtect(a, s, n, o) VirtualProtectFromApp((a), (s), (n), (o))]=])

_patch_file("${SOURCE_DIR}/src/funchook_windows.c"
  "#include <psapi.h>" "/* psapi.h is not used in the UWP port */"
  "#include \"funchook_internal.h\"" "${_shim}")

_patch_file("${SOURCE_DIR}/CMakeLists.txt"
  "project(funchook LANGUAGES C ASM)" "project(funchook LANGUAGES C) # dusk_xbox_uwp"
  "set(FUNCHOOK_DEPS psapi)" "set(FUNCHOOK_DEPS)")

message(STATUS "PatchFunchookUwp: funchook patched for UWP")
