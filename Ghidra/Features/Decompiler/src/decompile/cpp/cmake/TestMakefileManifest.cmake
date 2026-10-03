# The source lists follow the Makefile, and inconsistent Makefiles are
# rejected.  Works on a copy of the Makefile with empty stub sources.
cmake_minimum_required(VERSION 3.24)
if(NOT SOURCE_DIR OR NOT TEST_DIR)
  message(FATAL_ERROR "SOURCE_DIR and TEST_DIR are required")
endif()
set(_checker "${CMAKE_CURRENT_LIST_DIR}/CheckMakefileManifest.cmake")
include("${CMAKE_CURRENT_LIST_DIR}/GhidraDecompSources.cmake")
file(READ "${SOURCE_DIR}/Makefile" _original)

# A directory holding <makefile text> and one empty stub per source the real
# directory has.
function(make_tree dir makefile_text)
  file(REMOVE_RECURSE "${dir}")
  file(MAKE_DIRECTORY "${dir}")
  file(WRITE "${dir}/Makefile" "${makefile_text}")
  file(GLOB _sources RELATIVE "${SOURCE_DIR}" "${SOURCE_DIR}/*.cc")
  foreach(_f IN LISTS _sources)
    file(WRITE "${dir}/${_f}" "")
  endforeach()
endfunction()

function(run_checker dir expect_success out_var)
  execute_process(COMMAND "${CMAKE_COMMAND}" "-DMAKEFILE=${dir}/Makefile" "-DSOURCE_DIR=${dir}"
    -P "${_checker}" RESULT_VARIABLE _rc OUTPUT_VARIABLE _out ERROR_VARIABLE _err)
  if(expect_success AND NOT _rc EQUAL 0)
    message(FATAL_ERROR "check of ${dir} failed:\n${_out}\n${_err}")
  elseif(NOT expect_success AND _rc EQUAL 0)
    message(FATAL_ERROR "check of ${dir} passed but should have failed:\n${_out}\n${_err}")
  endif()
  set(${out_var} "${_out}${_err}" PARENT_SCOPE)
endfunction()

# (a) The unmodified Makefile passes.
make_tree("${TEST_DIR}/baseline" "${_original}")
run_checker("${TEST_DIR}/baseline" TRUE _out)

# (b) A unit added to a Makefile group reaches the build, and
# (c) an unlisted source joins the decompiler library, and
# (d) a local extension source does not.
string(REGEX REPLACE "(\nDECCORE[ \t]*=[ \t]*)" "\\1cmaketest_added " _added "${_original}")
if(_added STREQUAL _original)
  message(FATAL_ERROR "Could not add a unit to DECCORE")
endif()
make_tree("${TEST_DIR}/added" "${_added}")
file(WRITE "${TEST_DIR}/added/cmaketest_added.cc" "")
file(WRITE "${TEST_DIR}/added/cmaketest_extra.cc" "")
file(WRITE "${TEST_DIR}/added/coreext_cmaketest.cc" "")
run_checker("${TEST_DIR}/added" TRUE _out)
ghidra_decomp_read_sources("${TEST_DIR}/added/Makefile" "${TEST_DIR}/added")
if(NOT "cmaketest_added" IN_LIST GHIDRA_DECOMP_DECCORE_SOURCES)
  message(FATAL_ERROR "A unit added to DECCORE is not built: ${GHIDRA_DECOMP_DECCORE_SOURCES}")
endif()
if(NOT "cmaketest_extra" IN_LIST GHIDRA_DECOMP_EXTRA_BASE_SOURCES)
  message(FATAL_ERROR "An unlisted source is not in the library: ${GHIDRA_DECOMP_EXTRA_BASE_SOURCES}")
endif()
if("coreext_cmaketest" IN_LIST GHIDRA_DECOMP_EXTRA_SOURCES)
  message(FATAL_ERROR "A local extension source was treated as part of EXTRA")
endif()

# (e) A Makefile that names a missing source is rejected and the file named.
ghidra_decomp_read_sources("${SOURCE_DIR}/Makefile" "${SOURCE_DIR}")
list(GET GHIDRA_DECOMP_CORE_SOURCES 0 _victim)
make_tree("${TEST_DIR}/missing" "${_original}")
file(REMOVE "${TEST_DIR}/missing/${_victim}.cc")
run_checker("${TEST_DIR}/missing" FALSE _out)
if(NOT _out MATCHES "CORE: ${_victim}\\.cc")
  message(FATAL_ERROR "The missing source was not named:\n${_out}")
endif()

# (f) An archive that names a unit outside every group is rejected.
string(REGEX REPLACE "(\nLIBSLA_NAMES[ \t]*=[^\n]*)" "\\1 cmaketest_stray" _stray "${_original}")
if(_stray STREQUAL _original)
  message(FATAL_ERROR "Could not change LIBSLA_NAMES")
endif()
make_tree("${TEST_DIR}/stray" "${_stray}")
file(WRITE "${TEST_DIR}/stray/cmaketest_stray.cc" "")
run_checker("${TEST_DIR}/stray" FALSE _out)
if(NOT _out MATCHES "LIBSLA_NAMES: only-in-Makefile: cmaketest_stray")
  message(FATAL_ERROR "The stray archive member was not reported:\n${_out}")
endif()

file(REMOVE_RECURSE "${TEST_DIR}")
message(STATUS "Makefile-derived sources: additions, extensions, missing files and archive drift behave as expected")
