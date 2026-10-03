# Exercise the linkage guard itself: a JVM dependency is detected, and each
# tool failure path is rejected.
# cmake -DBINARY=<built-native-executable> -DWORK_DIR=<scratch dir> -P TestNoJvmCheck.cmake
cmake_minimum_required(VERSION 3.24)
if(NOT BINARY OR NOT WORK_DIR)
  message(FATAL_ERROR "TestNoJvmCheck: BINARY and WORK_DIR are required")
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

# A dependency listing that names libjvm must be rejected.
file(REMOVE_RECURSE "${WORK_DIR}")
file(MAKE_DIRECTORY "${WORK_DIR}")
set(_fake_ldd "${WORK_DIR}/ldd-with-jvm")
file(WRITE "${_fake_ldd}" "#!/bin/sh\necho '\tlibjvm.so => /opt/jdk/lib/server/libjvm.so (0x00007f0000000000)'\n")
file(CHMOD "${_fake_ldd}" PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE)
execute_process(COMMAND "${CMAKE_COMMAND}" -DMODE=linkage "-DBINARIES=${BINARY}"
  "-D_ldd=${_fake_ldd}" -P "${CMAKE_CURRENT_LIST_DIR}/NoJvmCheck.cmake"
  OUTPUT_VARIABLE output ERROR_VARIABLE error RESULT_VARIABLE result)
if(result EQUAL 0 OR NOT error MATCHES "links a JVM library")
  message(FATAL_ERROR "jvm_dependency: a JVM dependency was not rejected:\n${output}\n${error}")
endif()
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
file(REMOVE_RECURSE "${WORK_DIR}")
message(STATUS "NoJvmCheck: valid binary accepted; a JVM dependency, invalid input and tool failures rejected")
