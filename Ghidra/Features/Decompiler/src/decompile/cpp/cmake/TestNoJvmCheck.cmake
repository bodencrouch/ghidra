# Exercise the linkage guard itself, including each tool failure path.
# cmake -DBINARY=<built-native-executable> -P TestNoJvmCheck.cmake
if(NOT BINARY)
  message(FATAL_ERROR "TestNoJvmCheck: BINARY is required")
endif()

function(check_linkage name binary expect_success)
  execute_process(COMMAND "${CMAKE_COMMAND}" -DMODE=linkage
    "-DBINARIES=${binary}" ${ARGN} -P "${CMAKE_CURRENT_LIST_DIR}/NoJvmCheck.cmake"
    OUTPUT_VARIABLE output ERROR_VARIABLE error RESULT_VARIABLE result)
  if(expect_success)
    if(NOT result EQUAL 0 OR NOT output MATCHES "no JVM library")
      message(FATAL_ERROR "${name}: valid binary rejected:\n${output}\n${error}")
    endif()
  elseif(result EQUAL 0 OR output MATCHES "no JVM library" OR NOT error MATCHES "cannot inspect")
    message(FATAL_ERROR "${name}: inspection failure was not rejected:\n${output}\n${error}")
  endif()
endfunction()

check_linkage(native "${BINARY}" TRUE)
check_linkage(invalid "${CMAKE_CURRENT_LIST_FILE}" FALSE)
# CMake is an existing executable, but rejects these dependency-tool arguments.
# Override find_program results to exercise failures without platform tool shims.
check_linkage(fallback "${BINARY}" FALSE
  "-D_ldd=${CMAKE_COMMAND}" "-D_readelf=${CMAKE_COMMAND}")
check_linkage(ldd_only "${BINARY}" FALSE
  "-D_ldd=${CMAKE_COMMAND}" -D_readelf=FALSE)
check_linkage(otool "${BINARY}" FALSE
  -D_ldd=FALSE "-D_otool=${CMAKE_COMMAND}")
check_linkage(readelf "${BINARY}" FALSE
  -D_ldd=FALSE -D_otool=FALSE "-D_readelf=${CMAKE_COMMAND}")
message(STATUS "NoJvmCheck: valid binary accepted; invalid input and tool failures rejected")
