cmake_minimum_required(VERSION 3.24)
# Unique test-owned tree: preserve earlier receipts and never delete a prefix.
string(RANDOM LENGTH 10 ALPHABET 0123456789abcdef _id)
set(root "${BUILD}/installed-consumer-${_id}")
set(prefix "${root}/prefix")
function(run)
  execute_process(COMMAND ${ARGV} RESULT_VARIABLE result)
  if(NOT result EQUAL 0)
    message(FATAL_ERROR "Installed consumer command failed (${result}): ${ARGV}")
  endif()
endfunction()
run("${CMAKE_COMMAND}" --install "${BUILD}" --prefix "${prefix}" --config "${CONFIG}")
file(MAKE_DIRECTORY "${root}/source")
foreach(file CMakeLists.txt toy_decompile.cc external_gzip.c signature_commands.cc)
  configure_file("${SOURCE}/cmake/consumer/${file}" "${root}/source/${file}" COPYONLY)
endforeach()
configure_file("${SOURCE}/cmake/smoke/decomp_smoke.cc" "${root}/source/decomp_smoke.cc" COPYONLY)
set(toy OFF)
if("Toy" IN_LIST PROCESSORS)
  set(toy ON)
  file(READ "${SOURCE}/../datatests/skipnext2.xml" _fixture)
  string(REGEX MATCH "<binaryimage[^>]*>.*</binaryimage>" _image "${_fixture}")
  if(NOT _image MATCHES "^<binaryimage arch=\"Toy:BE:32:builder.align2:default\">" OR NOT _image MATCHES "<symbol name=\"skipinst\"")
    message(FATAL_ERROR "Installed consumer fixture drift: expected Toy skipinst image")
  endif()
  file(WRITE "${root}/source/skipnext2-image.xml" "${_image}\n")
endif()
run("${CMAKE_COMMAND}" -S "${root}/source" -B "${root}/build" -G "${GENERATOR}"
  "-DCMAKE_CXX_COMPILER=${CXX}" "-DGhidraDecompiler_DIR=${prefix}/${LIBDIR}/cmake/GhidraDecompiler"
  "-DCMAKE_BUILD_TYPE=${CONFIG}" "-DTEST_TOY=${toy}" "-DSTATIC_ZLIB=${STATIC_ZLIB}"
  "-DSTATIC_ZLIB_INCLUDE=${STATIC_ZLIB_INCLUDE}" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON)
run("${CMAKE_COMMAND}" --build "${root}/build" --config "${CONFIG}" --parallel 2)
run("${CTEST}" --test-dir "${root}/build" -C "${CONFIG}" --output-on-failure)
if(toy)
  # A selected but missing installed language must not find checkout specs.
  # This is our fresh test-owned prefix; restore its exact file before checking
  # the diagnostic, including after an unexpected configure result.
  # Respect a non-default configured data layout, as the package does.
  set(sla "${prefix}/${INSTALL_HOME}/Ghidra/Processors/Toy/data/languages/toy_builder_be_align2.sla")
  file(RENAME "${sla}" "${sla}.test-saved")
  execute_process(COMMAND "${CMAKE_COMMAND}" -S "${root}/source" -B "${root}/missing-toy-build"
    -G "${GENERATOR}" "-DCMAKE_CXX_COMPILER=${CXX}"
    "-DGhidraDecompiler_DIR=${prefix}/${LIBDIR}/cmake/GhidraDecompiler" -DTEST_TOY=ON
    "-DSTATIC_ZLIB=${STATIC_ZLIB}" "-DSTATIC_ZLIB_INCLUDE=${STATIC_ZLIB_INCLUDE}"
    RESULT_VARIABLE missing_result OUTPUT_VARIABLE missing_output ERROR_VARIABLE missing_error)
  file(RENAME "${sla}.test-saved" "${sla}")
  if(missing_result EQUAL 0 OR NOT "${missing_output}${missing_error}" MATCHES "Selected installed Toy language missing")
    message(FATAL_ERROR "Missing selected Toy was not rejected: ${missing_output}${missing_error}")
  endif()
  message(STATUS "Missing selected installed Toy rejected without source fallback")
endif()
message(STATUS "Installed consumer receipt: ${root}")
