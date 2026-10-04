# Source and final archive composition drift must invalidate the manifest.
cmake_minimum_required(VERSION 3.24)
if(NOT SOURCE_DIR OR NOT TEST_DIR)
  message(FATAL_ERROR "SOURCE_DIR and TEST_DIR are required")
endif()
file(MAKE_DIRECTORY "${TEST_DIR}")
file(READ "${SOURCE_DIR}/Makefile" original)
foreach(library CORE LIBSLA LIBDECOMP)
  # xml is a real source. For the two archive mutations, component sets and
  # source-existence checks still pass; only archive membership can reject.
  if(library STREQUAL "CORE")
    set(variable CORE)
  else()
    set(variable "${library}_NAMES")
  endif()
  string(REGEX REPLACE "(\n${variable}=)[^\n]*"
    "\\1xml" modified "${original}")
  if(modified STREQUAL original)
    message(FATAL_ERROR "Could not mutate ${variable}")
  endif()
  set(makefile "${TEST_DIR}/${library}.Makefile")
  file(WRITE "${makefile}" "${modified}")
  execute_process(COMMAND "${CMAKE_COMMAND}" "-DMAKEFILE=${makefile}"
    "-DSOURCE_DIR=${SOURCE_DIR}"
    -P "${CMAKE_CURRENT_LIST_DIR}/CheckMakefileManifest.cmake"
    RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
  if(result EQUAL 0 OR NOT "${output}${error}" MATCHES "${variable}: only-in-CMake"
      OR "${output}${error}" MATCHES "CMake (Warning|Deprecation)")
    message(FATAL_ERROR "${library} drift was not diagnosed: ${output}\n${error}")
  endif()
endforeach()

# A catalog regrouping must not silently remove independent signature support.
file(READ "${CMAKE_CURRENT_LIST_DIR}/GhidraDecompSources.cmake" catalog)
string(REPLACE "  analyzesigs callgraph" "  callgraph" mutated "${catalog}")
string(REPLACE "set(GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_SOURCES\n  codedata"
  "set(GHIDRA_DECOMP_EXTRA_BFD_CONSOLE_SOURCES\n  analyzesigs codedata" mutated "${mutated}")
if(mutated STREQUAL catalog)
  message(FATAL_ERROR "Could not mutate signature source grouping")
endif()
set(catalog_file "${TEST_DIR}/signature-omitted.cmake")
file(WRITE "${catalog_file}" "${mutated}")
execute_process(COMMAND "${CMAKE_COMMAND}" "-DMAKEFILE=${SOURCE_DIR}/Makefile"
  "-DSOURCE_DIR=${SOURCE_DIR}" "-DSOURCES_CMAKE=${catalog_file}"
  -P "${CMAKE_CURRENT_LIST_DIR}/CheckMakefileManifest.cmake"
  RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
if(result EQUAL 0 OR NOT "${output}${error}" MATCHES "LIBDECOMP_NAMES: only-in-Makefile[^\n]*analyzesigs"
    OR "${output}${error}" MATCHES "CMake (Warning|Deprecation)")
  message(FATAL_ERROR "Missing independent signature unit was not diagnosed: ${output}\n${error}")
endif()
