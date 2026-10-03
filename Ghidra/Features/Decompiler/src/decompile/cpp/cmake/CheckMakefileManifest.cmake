# Consistency checks for the source lists read from the Makefile.
#
# Usage (script mode):
#   cmake -DMAKEFILE=<path to Makefile> [-DSOURCE_DIR=<cpp dir>]
#         [-DGRADLE=<path to buildNatives.gradle> [-DGRADLE_STRICT=ON]]
#         -P CheckMakefileManifest.cmake
#
# ghidra_decomp_check_manifest(<makefile> <source dir>) reads the source lists
# with ghidra_decomp_read_sources() (GhidraDecompSources.cmake) and checks
# that the two archives this build makes have exactly the members of the
# Makefile's LIBSLA_NAMES and LIBDECOMP_NAMES (the latter without the BFD
# loader, which this build omits).  A mismatch is a configure error.
#
# ghidra_decomp_check_gradle(<buildNatives.gradle> <makefile> <source dir>
# <strict>) compares the sources Gradle compiles into its decompile and
# sleigh executables with the Makefile's GHIDRA_NAMES and SLEIGH_NAMES.  A
# Makefile name whose `include` line Gradle keeps commented out (grammar.cc,
# used only by the console) is a deliberate omission, not a difference.  It
# reports both directions and fails only when <strict> is true, because a
# difference there is between two upstream files, not in this build.

include("${CMAKE_CURRENT_LIST_DIR}/GhidraDecompSources.cmake")

# Expand a Makefile library variable built from $(GROUP) references and
# literal names.  Needs the lists set by ghidra_decomp_read_sources().
function(_ghidra_decomp_expand_names makefile_text var out_var)
  _ghidra_decomp_makefile_value("${makefile_text}" ${var} _value)
  foreach(_group CORE DECCORE SLEIGH GHIDRA SLACOMP SPECIAL EXTRA)
    if(_group STREQUAL "DECCORE")
      set(_members "${GHIDRA_DECOMP_DECCORE_ALL_SOURCES}")
    else()
      set(_members "${GHIDRA_DECOMP_${_group}_SOURCES}")
    endif()
    string(REPLACE ";" " " _members "${_members}")
    string(REPLACE "$(${_group})" " ${_members} " _value "${_value}")
  endforeach()
  if(_value MATCHES "\\$\\(")
    message(FATAL_ERROR "manifest check: unsupported reference in ${var}: ${_value}")
  endif()
  string(REGEX REPLACE "[ \t]+" ";" _list "${_value}")
  list(REMOVE_ITEM _list "")
  # LIBSLA_NAMES names sleigh both directly and through SLEIGH.
  list(REMOVE_DUPLICATES _list)
  set(${out_var} "${_list}" PARENT_SCOPE)
endfunction()

# Compare two name sets and report the differences in both directions.
function(_ghidra_decomp_compare_set name list_a label_a list_b label_b mode result_var)
  set(_a ${list_a})
  set(_b ${list_b})
  list(SORT _a)
  list(SORT _b)
  _ghidra_decomp_subtract("${_a}" "${_b}" _only_a)
  _ghidra_decomp_subtract("${_b}" "${_a}" _only_b)
  set(_ok TRUE)
  if(_only_a)
    string(REPLACE ";" " " _s "${_only_a}")
    message(${mode} "${name}: only-in-${label_a}: ${_s}")
    set(_ok FALSE)
  endif()
  if(_only_b)
    string(REPLACE ";" " " _s "${_only_b}")
    message(${mode} "${name}: only-in-${label_b}: ${_s}")
    set(_ok FALSE)
  endif()
  list(LENGTH _a _count)
  message(STATUS "${name}: ${_count} names, match=${_ok}")
  set(${result_var} ${_ok} PARENT_SCOPE)
endfunction()

function(ghidra_decomp_check_manifest makefile source_dir)
  ghidra_decomp_read_sources("${makefile}" "${source_dir}")
  foreach(_set CORE DECCORE_ALL SLEIGH GHIDRA SLACOMP SPECIAL EXTRA_BASE EXTRA_CONSOLE
               EXTRA_BFD EXTRA_BFD_CONSOLE)
    list(LENGTH GHIDRA_DECOMP_${_set}_SOURCES _n)
    message(STATUS "manifest check: ${_set}: ${_n} names")
  endforeach()

  _ghidra_decomp_read_makefile("${makefile}" _text)
  set(_all_ok TRUE)
  foreach(_library LIBSLA LIBDECOMP)
    _ghidra_decomp_expand_names("${_text}" ${_library}_NAMES _members)
    if(_library STREQUAL "LIBDECOMP")
      # This build omits the optional BFD loader.
      set(_bfd ${GHIDRA_DECOMP_EXTRA_BFD_SOURCES} ${GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_SOURCES})
      _ghidra_decomp_subtract("${_members}" "${_bfd}" _members)
    endif()
    # Each member must be compiled exactly once.
    set(_cmake ${GHIDRA_DECOMP_${_library}_SOURCES})
    set(_dedup ${_cmake})
    list(REMOVE_DUPLICATES _dedup)
    list(LENGTH _cmake _n1)
    list(LENGTH _dedup _n2)
    if(NOT _n1 EQUAL _n2)
      message(SEND_ERROR "manifest check: ${_library}_NAMES: a unit is listed twice")
      set(_all_ok FALSE)
    endif()
    _ghidra_decomp_compare_set("manifest check: ${_library}_NAMES" "${_members}" Makefile
      "${_cmake}" CMake SEND_ERROR _ok)
    if(NOT _ok)
      set(_all_ok FALSE)
    endif()
  endforeach()

  if(NOT _all_ok)
    message(FATAL_ERROR "manifest check: the CMake archives differ from ${makefile}")
  endif()
  message(STATUS "manifest check: the CMake archives match ${makefile}")
endfunction()

# `include "<name>.cc"` lines of one Gradle NativeExecutableSpec block: the
# active ones in <out_var>, the commented-out ones in <commented_var>.
function(_ghidra_decomp_gradle_component gradle_text component out_var commented_var)
  set(_marker "${component}(NativeExecutableSpec)")
  string(FIND "${gradle_text}" "${_marker}" _start)
  if(_start EQUAL -1)
    message(FATAL_ERROR "gradle check: component ${component} not found")
  endif()
  string(LENGTH "${_marker}" _len)
  math(EXPR _start "${_start} + ${_len}")
  string(SUBSTRING "${gradle_text}" ${_start} -1 _rest)
  # The block ends where the next component starts, or at the end of the
  # components section.
  string(FIND "${_rest}" "(NativeExecutableSpec)" _next)
  if(NOT _next EQUAL -1)
    string(SUBSTRING "${_rest}" 0 ${_next} _rest)
  endif()
  string(FIND "${_rest}" "end components" _end)
  if(NOT _end EQUAL -1)
    string(SUBSTRING "${_rest}" 0 ${_end} _rest)
  endif()
  string(REPLACE "\r\n" "\n" _rest "${_rest}")
  string(REPLACE ";" "," _rest "${_rest}")
  string(REPLACE "\n" ";" _lines "${_rest}")
  set(_names)
  set(_commented)
  foreach(_line IN LISTS _lines)
    if(_line MATCHES "^[ \t]*include[ \t]+\"([A-Za-z0-9_]+)\\.cc\"")
      list(APPEND _names "${CMAKE_MATCH_1}")
    elseif(_line MATCHES "^[ \t]*//[ \t]*include[ \t]+\"([A-Za-z0-9_]+)\\.cc\"")
      list(APPEND _commented "${CMAKE_MATCH_1}")
    endif()
  endforeach()
  list(REMOVE_DUPLICATES _names)
  set(${out_var} "${_names}" PARENT_SCOPE)
  set(${commented_var} "${_commented}" PARENT_SCOPE)
endfunction()

function(ghidra_decomp_check_gradle gradle makefile source_dir strict)
  if(NOT EXISTS "${gradle}")
    message(FATAL_ERROR "gradle check: file not found: ${gradle}")
  endif()
  ghidra_decomp_read_sources("${makefile}" "${source_dir}")
  _ghidra_decomp_read_makefile("${makefile}" _text)
  file(READ "${gradle}" _gradle)
  if(strict)
    set(_mode SEND_ERROR)
  else()
    set(_mode WARNING)
  endif()
  set(_all_ok TRUE)
  foreach(_pair "decompile;GHIDRA_NAMES" "sleigh;SLEIGH_NAMES")
    list(GET _pair 0 _component)
    list(GET _pair 1 _var)
    _ghidra_decomp_gradle_component("${_gradle}" ${_component} _gradle_names _gradle_commented)
    _ghidra_decomp_expand_names("${_text}" ${_var} _make_names)
    _ghidra_decomp_intersect("${_gradle_commented}" "${_make_names}" _omitted)
    _ghidra_decomp_subtract("${_omitted}" "${_gradle_names}" _omitted)
    if(_omitted)
      string(REPLACE ";" " " _s "${_omitted}")
      message(STATUS "gradle check: ${_component}: commented out in Gradle: ${_s}")
      _ghidra_decomp_subtract("${_make_names}" "${_omitted}" _make_names)
    endif()
    _ghidra_decomp_compare_set("gradle check: ${_component} vs ${_var}" "${_gradle_names}" Gradle
      "${_make_names}" Makefile ${_mode} _ok)
    if(NOT _ok)
      set(_all_ok FALSE)
    endif()
  endforeach()
  if(NOT _all_ok AND strict)
    message(FATAL_ERROR "gradle check: ${gradle} and ${makefile} name different sources")
  endif()
endfunction()

if(CMAKE_SCRIPT_MODE_FILE AND CMAKE_SCRIPT_MODE_FILE STREQUAL CMAKE_CURRENT_LIST_FILE)
  if(NOT MAKEFILE)
    message(FATAL_ERROR "usage: cmake -DMAKEFILE=<Makefile> [-DSOURCE_DIR=<cpp dir>] [-DGRADLE=<buildNatives.gradle> [-DGRADLE_STRICT=ON]] -P CheckMakefileManifest.cmake")
  endif()
  if(NOT SOURCE_DIR)
    get_filename_component(SOURCE_DIR "${MAKEFILE}" DIRECTORY)
  endif()
  if(GRADLE)
    ghidra_decomp_check_gradle("${GRADLE}" "${MAKEFILE}" "${SOURCE_DIR}" "${GRADLE_STRICT}")
  else()
    ghidra_decomp_check_manifest("${MAKEFILE}" "${SOURCE_DIR}")
  endif()
endif()
