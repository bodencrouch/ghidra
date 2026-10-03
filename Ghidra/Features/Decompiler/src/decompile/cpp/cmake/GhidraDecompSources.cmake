# Source lists for the standalone CMake build of the decompiler.
#
# ../Makefile is the canonical description of which translation units make
# up each part of the native code.  ghidra_decomp_read_sources() reads its
# CORE, DECCORE, SLEIGH, GHIDRA, SLACOMP and SPECIAL variables and computes
# EXTRA the way the Makefile does (every other *.cc in the directory), so a
# source added to or removed from the Makefile reaches this build without a
# second list to maintain.  Every Ghidra release from 10.3 to the current
# master uses this Makefile layout.
#
# The only knowledge kept here is how EXTRA divides by what each unit needs:
# console support, and the optional BFD loader that this build omits.  Any
# EXTRA unit not named below is part of the decompiler library.
#
# This file is included both by CMakeLists.txt and by the script-mode checks
# in CheckMakefileManifest.cmake.  It only defines functions and variables.

include_guard(GLOBAL)

# Console (command line interface) support.  decomp_console and decomp_test
# need these.
set(GHIDRA_DECOMP_EXTRA_CONSOLE_NAMES
  callgraph ifacedecomp ifaceterm interface rulecompile testfunction unify)
# Need <bfd.h>.
set(GHIDRA_DECOMP_EXTRA_BFD_NAMES
  bfd_arch loadimage_bfd)
# Console commands that also need <bfd.h> (both include loadimage_bfd.hh).
set(GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_NAMES
  analyzesigs codedata)

# Read a Makefile with backslash-newline continuations joined.
function(_ghidra_decomp_read_makefile makefile out_var)
  if(NOT EXISTS "${makefile}")
    message(FATAL_ERROR "decompiler sources: Makefile not found: ${makefile}")
  endif()
  file(READ "${makefile}" _text)
  string(REGEX REPLACE "\\\\[ \t]*\r?\n" " " _text "${_text}")
  string(REPLACE "\r\n" "\n" _text "${_text}")
  set(${out_var} "${_text}" PARENT_SCOPE)
endfunction()

# Raw right-hand side of "VAR=..." or "VAR = ..." at the start of a line.
function(_ghidra_decomp_makefile_value makefile_text var out_var)
  string(REGEX MATCH "(^|\n)${var}[ \t]*=[ \t]*([^\n]*)" _m "${makefile_text}")
  if(NOT _m)
    message(FATAL_ERROR "decompiler sources: variable ${var} not found in the Makefile")
  endif()
  set(${out_var} "${CMAKE_MATCH_2}" PARENT_SCOPE)
endfunction()

# Literal names of a Makefile variable, with $(...) references dropped.
function(_ghidra_decomp_makefile_names makefile_text var out_var)
  _ghidra_decomp_makefile_value("${makefile_text}" ${var} _value)
  string(REGEX REPLACE "\\$\\([^)]*\\)" "" _value "${_value}")
  string(REGEX REPLACE "[ \t]+" ";" _list "${_value}")
  list(REMOVE_ITEM _list "")
  list(REMOVE_DUPLICATES _list)
  set(${out_var} "${_list}" PARENT_SCOPE)
endfunction()

# Members of list_a that are also in list_b, in list_a order.
function(_ghidra_decomp_intersect list_a list_b out_var)
  set(_result)
  foreach(_n IN LISTS list_a)
    if(_n IN_LIST list_b)
      list(APPEND _result "${_n}")
    endif()
  endforeach()
  set(${out_var} "${_result}" PARENT_SCOPE)
endfunction()

# Members of list_a that are not in list_b, in list_a order.
function(_ghidra_decomp_subtract list_a list_b out_var)
  set(_result)
  foreach(_n IN LISTS list_a)
    if(NOT _n IN_LIST list_b)
      list(APPEND _result "${_n}")
    endif()
  endforeach()
  set(${out_var} "${_result}" PARENT_SCOPE)
endfunction()

# ghidra_decomp_read_sources(<makefile> <source dir>)
#
# Sets, in the caller's scope:
#   GHIDRA_DECOMP_CORE_SOURCES               Makefile CORE
#   GHIDRA_DECOMP_LIBSLA_DECCORE_SOURCES     DECCORE units that LIBSLA_NAMES also names
#   GHIDRA_DECOMP_DECCORE_SOURCES            the rest of DECCORE
#   GHIDRA_DECOMP_DECCORE_ALL_SOURCES        all of DECCORE
#   GHIDRA_DECOMP_SLEIGH_SOURCES             Makefile SLEIGH
#   GHIDRA_DECOMP_GHIDRA_SOURCES             Makefile GHIDRA: the JVM-facing process, never
#                                            compiled here (ghidra_process.cc installs a
#                                            SIGSEGV handler that exits the process)
#   GHIDRA_DECOMP_SLACOMP_SOURCES            Makefile SLACOMP: the SLEIGH compiler
#   GHIDRA_DECOMP_SPECIAL_SOURCES            Makefile SPECIAL: program mains
#   GHIDRA_DECOMP_EXTRA_SOURCES              every other *.cc except local *ext_* extensions
#   GHIDRA_DECOMP_EXTRA_BASE_SOURCES         EXTRA units always in the decompiler library
#   GHIDRA_DECOMP_EXTRA_CONSOLE_SOURCES      EXTRA console units
#   GHIDRA_DECOMP_EXTRA_BFD_SOURCES          EXTRA units that need <bfd.h> (not built)
#   GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_SOURCES  EXTRA console units that need <bfd.h> (not built)
#   GHIDRA_DECOMP_LIBSLA_SOURCES             the sla archive (Makefile LIBSLA_NAMES)
#   GHIDRA_DECOMP_LIBDECOMP_SOURCES          the decompiler archive with console support
#                                            (Makefile LIBDECOMP_NAMES without BFD)
function(ghidra_decomp_read_sources makefile source_dir)
  _ghidra_decomp_read_makefile("${makefile}" _text)

  foreach(_group CORE DECCORE SLEIGH GHIDRA SLACOMP SPECIAL)
    _ghidra_decomp_makefile_names("${_text}" ${_group} _mk_${_group})
  endforeach()

  # The units compiled here must exist.  GHIDRA and SPECIAL are only needed
  # to compute EXTRA.
  set(_missing)
  foreach(_group CORE DECCORE SLEIGH SLACOMP)
    foreach(_n IN LISTS _mk_${_group})
      if(NOT EXISTS "${source_dir}/${_n}.cc")
        list(APPEND _missing "${_group}: ${_n}.cc")
      endif()
    endforeach()
  endforeach()
  if(_missing)
    list(JOIN _missing "\n  " _s)
    message(FATAL_ERROR "decompiler sources: ${makefile} names sources that do not exist in ${source_dir}:\n  ${_s}")
  endif()

  # LIBSLA_NAMES adds a few DECCORE units to CORE and SLEIGH by name.
  _ghidra_decomp_makefile_names("${_text}" LIBSLA_NAMES _libsla_literals)
  _ghidra_decomp_intersect("${_mk_DECCORE}" "${_libsla_literals}" _libsla_deccore)
  _ghidra_decomp_subtract("${_mk_DECCORE}" "${_libsla_deccore}" _deccore_rest)

  # EXTRA = $(filter-out $(CORE) $(DECCORE) ...,$(ALL_NAMES)).  Local
  # extension sources (coreext_*, ghidraext_*, consoleext_*) are ignored by
  # ../.gitignore and reach the Makefile only through its *EXT_NAMES
  # variables, so they are left out.
  if(CMAKE_SCRIPT_MODE_FILE)
    file(GLOB _all_cc RELATIVE "${source_dir}" "${source_dir}/*.cc")
  else()
    # A source added to or removed from the directory or the Makefile must
    # reconfigure the build; otherwise the archives keep the old unit list.
    file(GLOB _all_cc CONFIGURE_DEPENDS RELATIVE "${source_dir}" "${source_dir}/*.cc")
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${makefile}")
  endif()
  list(SORT _all_cc)
  list(FILTER _all_cc EXCLUDE REGEX "^(coreext|ghidraext|consoleext)_")
  set(_all_names)
  foreach(_f IN LISTS _all_cc)
    string(REGEX REPLACE "\\.cc$" "" _n "${_f}")
    list(APPEND _all_names "${_n}")
  endforeach()
  set(_grouped ${_mk_CORE} ${_mk_DECCORE} ${_mk_SLEIGH} ${_mk_GHIDRA} ${_mk_SLACOMP} ${_mk_SPECIAL})
  _ghidra_decomp_subtract("${_all_names}" "${_grouped}" _extra)

  _ghidra_decomp_intersect("${_extra}" "${GHIDRA_DECOMP_EXTRA_CONSOLE_NAMES}" _extra_console)
  _ghidra_decomp_intersect("${_extra}" "${GHIDRA_DECOMP_EXTRA_BFD_NAMES}" _extra_bfd)
  _ghidra_decomp_intersect("${_extra}" "${GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_NAMES}" _extra_bfd_console)
  set(_classified ${GHIDRA_DECOMP_EXTRA_CONSOLE_NAMES} ${GHIDRA_DECOMP_EXTRA_BFD_NAMES}
    ${GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_NAMES})
  _ghidra_decomp_subtract("${_extra}" "${_classified}" _extra_base)

  set(GHIDRA_DECOMP_CORE_SOURCES "${_mk_CORE}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_LIBSLA_DECCORE_SOURCES "${_libsla_deccore}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_DECCORE_SOURCES "${_deccore_rest}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_DECCORE_ALL_SOURCES "${_mk_DECCORE}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_SLEIGH_SOURCES "${_mk_SLEIGH}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_GHIDRA_SOURCES "${_mk_GHIDRA}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_SLACOMP_SOURCES "${_mk_SLACOMP}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_SPECIAL_SOURCES "${_mk_SPECIAL}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_EXTRA_SOURCES "${_extra}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_EXTRA_BASE_SOURCES "${_extra_base}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_EXTRA_CONSOLE_SOURCES "${_extra_console}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_EXTRA_BFD_SOURCES "${_extra_bfd}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_SOURCES "${_extra_bfd_console}" PARENT_SCOPE)
  set(GHIDRA_DECOMP_LIBSLA_SOURCES ${_mk_CORE} ${_mk_SLEIGH} ${_libsla_deccore} PARENT_SCOPE)
  set(GHIDRA_DECOMP_LIBDECOMP_SOURCES ${_mk_CORE} ${_mk_SLEIGH} ${_libsla_deccore}
    ${_deccore_rest} ${_extra_base} ${_extra_console} PARENT_SCOPE)
endfunction()
