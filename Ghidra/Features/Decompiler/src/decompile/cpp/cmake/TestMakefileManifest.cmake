# Changing only a final archive composition must invalidate the manifest.
cmake_minimum_required(VERSION 3.24)
if(NOT SOURCE_DIR OR NOT TEST_DIR)
  message(FATAL_ERROR "SOURCE_DIR and TEST_DIR are required")
endif()
file(MAKE_DIRECTORY "${TEST_DIR}")
file(READ "${SOURCE_DIR}/Makefile" original)
foreach(library LIBSLA LIBDECOMP)
  # xml is a real source, so only the archive membership check can reject
  # this removal; the component sets and source-existence check still pass.
  string(REGEX REPLACE "(\n${library}_NAMES=)[^\n]*"
    "\\1xml" modified "${original}")
  if(modified STREQUAL original)
    message(FATAL_ERROR "Could not mutate ${library}_NAMES")
  endif()
  set(makefile "${TEST_DIR}/${library}.Makefile")
  file(WRITE "${makefile}" "${modified}")
  execute_process(COMMAND "${CMAKE_COMMAND}" "-DMAKEFILE=${makefile}"
    "-DSOURCE_DIR=${SOURCE_DIR}"
    -P "${CMAKE_CURRENT_LIST_DIR}/CheckMakefileManifest.cmake"
    RESULT_VARIABLE result OUTPUT_VARIABLE output ERROR_VARIABLE error)
  if(result EQUAL 0 OR NOT "${output}${error}" MATCHES "${library}_NAMES: only-in-CMake")
    message(FATAL_ERROR "${library} drift was not diagnosed: ${output}\n${error}")
  endif()
endforeach()
