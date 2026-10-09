# Standalone CMake build of the decompiler and SLEIGH.
#
# This build does not replace the Gradle build.  It exists so that the
# native code can be built, tested and consumed without a JVM or Gradle:
#
#   cmake -S . -B ../../../build/cmake -G Ninja
#   cmake --build ../../../build/cmake
#   ctest --test-dir ../../../build/cmake --output-on-failure
#
# Keep the build directory outside src/decompile: the Gradle source
# distribution packages that whole tree.
#
# See cmake/README.md for the options, the test list and a consumer example.
#
# Source lists live in cmake/GhidraDecompSources.cmake and are checked
# against ../Makefile at configure time (cmake/CheckMakefileManifest.cmake).
# No source is moved and generated parsers remain the committed ones. Existing
# source changes remove the unused BFD-dependent include from analyzesigs.cc
# and enable output-write checks only in the CMake-built SLEIGH compiler; the
# legacy Make/Gradle compiler behavior is unchanged.

cmake_minimum_required(VERSION 3.24)

# Reject source aliases and ancestor outputs before candidate-owned writes.
# CMake itself may create startup metadata before evaluating this guard.
include("${CMAKE_CURRENT_SOURCE_DIR}/cmake/BuildSafety.cmake")
get_filename_component(_decompile_source "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)
get_filename_component(_default_processors "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../Processors" ABSOLUTE)
if(DEFINED GHIDRA_DECOMP_PROCESSORS_ROOT)
  set(_source_processors "${GHIDRA_DECOMP_PROCESSORS_ROOT}")
else()
  set(_source_processors "${_default_processors}")
endif()
if(DEFINED GHIDRA_DECOMP_SLEIGH_HOME)
  set(_output_home "${GHIDRA_DECOMP_SLEIGH_HOME}")
else()
  set(_output_home "${CMAKE_CURRENT_BINARY_DIR}/sleigh-home")
endif()
foreach(_source "${_decompile_source}" "${_source_processors}")
  ghidra_decomp_reject_overlap("${CMAKE_CURRENT_BINARY_DIR}" "${_source}")
  ghidra_decomp_reject_overlap("${_output_home}" "${_source}")
  ghidra_decomp_reject_overlap("${CMAKE_CURRENT_BINARY_DIR}/.ghidra-cmake/datatests" "${_source}")
endforeach()

# ---------------------------------------------------------------------------
# Version: Ghidra/application.properties, falling back to 0.0.0 when the cpp
# directory is built outside a Ghidra checkout.
get_filename_component(GHIDRA_DECOMP_GHIDRA_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../.." ABSOLUTE)
set(GHIDRA_DECOMP_GHIDRA_VERSION "0.0.0")
if(EXISTS "${GHIDRA_DECOMP_GHIDRA_DIR}/application.properties")
  file(STRINGS "${GHIDRA_DECOMP_GHIDRA_DIR}/application.properties" _ghidra_version_line
       REGEX "^application\\.version=")
  if(_ghidra_version_line MATCHES "^application\\.version=([0-9]+(\\.[0-9]+)*)")
    set(GHIDRA_DECOMP_GHIDRA_VERSION "${CMAKE_MATCH_1}")
  endif()
endif()

project(GhidraDecompiler VERSION ${GHIDRA_DECOMP_GHIDRA_VERSION} LANGUAGES CXX)

include(CMakeDependentOption)
include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
find_package(Threads REQUIRED)

# ---------------------------------------------------------------------------
# Options.  Defaults give a system-zlib host build with the console; the
# Gradle sleigh build differs in that it compiles the bundled zlib.
option(GHIDRA_DECOMP_LOCAL_ZLIB "Compile the bundled ../zlib instead of linking the system zlib" OFF)
option(GHIDRA_DECOMP_CONSOLE "Build the console command interface (needed by decomp_console and decomp_test)" ON)
cmake_dependent_option(GHIDRA_DECOMP_TERMINAL "Terminal line editing for the console (defines __TERMINAL__)" ON
  "GHIDRA_DECOMP_CONSOLE;UNIX" OFF)
option(GHIDRA_DECOMP_CPUI_DEBUG "Define CPUI_DEBUG (debug checks; changes class layouts)" OFF)
set(GHIDRA_DECOMP_SANITIZE "" CACHE STRING "Value for -fsanitize= applied to every target (empty: none)")
option(GHIDRA_DECOMP_BUILD_TOOLS "Build sleigh_compiler and decomp_console" ON)
option(GHIDRA_DECOMP_BUILD_TESTS "Build decomp_test and the smoke programs and register ctest tests" ${PROJECT_IS_TOP_LEVEL})
set(GHIDRA_DECOMP_SPEC_PROCESSORS "x86;ARM;AARCH64;Toy;PowerPC;MIPS" CACHE STRING
  "Processor directories (Ghidra/Processors/<P>) whose .slaspec files are compiled into the sleigh home (empty: none)")
set(GHIDRA_DECOMP_CXX_STANDARD 11 CACHE STRING "C++ standard used to compile the sources")
option(GHIDRA_DECOMP_INSTALL "Generate install and export rules" ${PROJECT_IS_TOP_LEVEL})
set(GHIDRA_DECOMP_TEST_STATIC_ZLIB "" CACHE FILEPATH "Optional external static gzip libz for installed co-link regression")
set(GHIDRA_DECOMP_TEST_ZLIB_INCLUDE_DIR "" CACHE PATH "Header directory matching the external static gzip libz")
option(GHIDRA_DECOMP_CHECK_MANIFEST "Compare cmake/GhidraDecompSources.cmake with ../Makefile at configure time" ON)
set(GHIDRA_DECOMP_MASTER_MAKEFILE "" CACHE FILEPATH
  "Optional path to another checkout's decompiler Makefile; adds the ctest manifest_matches_makefile_master")
set(GHIDRA_DECOMP_SLEIGH_HOME "${CMAKE_CURRENT_BINARY_DIR}/sleigh-home" CACHE PATH
  "Root of the generated sleigh home tree (Ghidra/Processors/<P>/data/languages/*.sla)")
set(GHIDRA_DECOMP_PROCESSORS_ROOT "${GHIDRA_DECOMP_GHIDRA_DIR}/Processors" CACHE PATH
  "Directory holding the processor modules (Ghidra/Processors)")

if(NOT PROJECT_IS_TOP_LEVEL)
  # A superbuild reads the sleigh home location from here.
  set(GHIDRA_DECOMP_SLEIGH_HOME "${GHIDRA_DECOMP_SLEIGH_HOME}" PARENT_SCOPE)
endif()

if(GHIDRA_DECOMP_TERMINAL AND NOT GHIDRA_DECOMP_CONSOLE)
  message(FATAL_ERROR "GHIDRA_DECOMP_TERMINAL needs GHIDRA_DECOMP_CONSOLE")
endif()

if(NOT DEFINED CMAKE_POSITION_INDEPENDENT_CODE)
  # The archives are meant to be linked into shared objects as well.
  set(CMAKE_POSITION_INDEPENDENT_CODE ON)
endif()

if(GHIDRA_DECOMP_SANITIZE)
  if(MSVC)
    message(FATAL_ERROR "GHIDRA_DECOMP_SANITIZE uses the GCC/Clang -fsanitize= syntax; it is not supported with MSVC")
  endif()
  add_compile_options(-fsanitize=${GHIDRA_DECOMP_SANITIZE} -fno-omit-frame-pointer)
  add_link_options(-fsanitize=${GHIDRA_DECOMP_SANITIZE})
endif()

# ---------------------------------------------------------------------------
# Facts parsed from the sources for the exported config.
file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/slaformat.cc" _sla_format_line
     REGEX "^const int4 FORMAT_VERSION[ \t]*=")
if(_sla_format_line MATCHES "=[ \t]*([0-9]+)")
  set(GHIDRA_DECOMP_SLA_FORMAT_VERSION "${CMAKE_MATCH_1}")
else()
  message(FATAL_ERROR "Could not parse FORMAT_VERSION from slaformat.cc")
endif()
message(STATUS "GhidraDecompiler ${PROJECT_VERSION}, .sla format ${GHIDRA_DECOMP_SLA_FORMAT_VERSION}")

# ---------------------------------------------------------------------------
# Sources and manifest check.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(GhidraDecompSources)
include(CheckMakefileManifest)
include(SleighCompileSpecs)

if(GHIDRA_DECOMP_CHECK_MANIFEST)
  ghidra_decomp_check_manifest("${CMAKE_CURRENT_SOURCE_DIR}/Makefile" "${CMAKE_CURRENT_SOURCE_DIR}")
endif()

# ---------------------------------------------------------------------------
# Compile settings shared by every target.  The definitions that change
# class layouts (__TERMINAL__, CPUI_DEBUG) or header selection (LOCAL_ZLIB)
# are exported so that consumers see the same layouts.
set(GHIDRA_DECOMP_PUBLIC_DEFINITIONS)
if(GHIDRA_DECOMP_TERMINAL)
  list(APPEND GHIDRA_DECOMP_PUBLIC_DEFINITIONS __TERMINAL__)
endif()
if(GHIDRA_DECOMP_CPUI_DEBUG)
  list(APPEND GHIDRA_DECOMP_PUBLIC_DEFINITIONS CPUI_DEBUG)
endif()
if(GHIDRA_DECOMP_LOCAL_ZLIB)
  list(APPEND GHIDRA_DECOMP_PUBLIC_DEFINITIONS LOCAL_ZLIB)
endif()
set(GHIDRA_DECOMP_PRIVATE_DEFINITIONS)
if(WIN32)
  # filemanage.cc needs _WINDOWS; public types do not depend on it.
  list(APPEND GHIDRA_DECOMP_PRIVATE_DEFINITIONS _WINDOWS)
endif()

set(GHIDRA_DECOMP_INSTALL_INCLUDEDIR "${CMAKE_INSTALL_INCLUDEDIR}/ghidra/decompiler")
set(GHIDRA_DECOMP_INSTALL_ZLIB_INCLUDEDIR "${CMAKE_INSTALL_INCLUDEDIR}/ghidra/zlib")
set(GHIDRA_DECOMP_INSTALL_SLEIGH_HOME "${CMAKE_INSTALL_DATADIR}/ghidra-decompiler/sleigh-home")

function(_ghidra_decomp_compile_settings target)
  target_link_libraries(${target} PRIVATE Threads::Threads)
  set_target_properties(${target} PROPERTIES
    CXX_STANDARD ${GHIDRA_DECOMP_CXX_STANDARD}
    CXX_STANDARD_REQUIRED ON
    CXX_EXTENSIONS OFF)
  target_compile_options(${target} PRIVATE
    $<$<CXX_COMPILER_ID:GNU,Clang,AppleClang>:-Wall -Wno-sign-compare>
    $<$<CXX_COMPILER_ID:MSVC>:/EHsc /W3>)
  target_compile_definitions(${target} PRIVATE ${GHIDRA_DECOMP_PUBLIC_DEFINITIONS} ${GHIDRA_DECOMP_PRIVATE_DEFINITIONS})
  target_include_directories(${target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
endfunction()

# Usage requirements of the archives.
function(_ghidra_decomp_archive_interface target)
  target_link_libraries(${target} INTERFACE Threads::Threads)
  if(GHIDRA_DECOMP_SANITIZE)
    target_link_options(${target} INTERFACE -fsanitize=${GHIDRA_DECOMP_SANITIZE})
  endif()
  target_compile_definitions(${target} INTERFACE ${GHIDRA_DECOMP_PUBLIC_DEFINITIONS})
  target_compile_features(${target} INTERFACE cxx_std_${GHIDRA_DECOMP_CXX_STANDARD})
  target_include_directories(${target} INTERFACE
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
    $<INSTALL_INTERFACE:${GHIDRA_DECOMP_INSTALL_INCLUDEDIR}>)
endfunction()

function(_ghidra_decomp_object_library name)
  set(_srcs)
  foreach(_n IN LISTS ARGN)
    if(GHIDRA_DECOMP_LOCAL_ZLIB AND _n STREQUAL "compression")
      list(APPEND _srcs "${CMAKE_CURRENT_BINARY_DIR}/bundled-zlib/compression.cc")
    else()
      list(APPEND _srcs "${CMAKE_CURRENT_SOURCE_DIR}/${_n}.cc")
    endif()
  endforeach()
  add_library(${name} OBJECT ${_srcs})
  _ghidra_decomp_compile_settings(${name})
  target_include_directories(${name} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
  if(NOT GHIDRA_DECOMP_LOCAL_ZLIB)
    target_link_libraries(${name} PRIVATE ZLIB::ZLIB)
  endif()
endfunction()

# ---------------------------------------------------------------------------
# zlib
if(GHIDRA_DECOMP_LOCAL_ZLIB)
  enable_language(C)
  if(NOT CMAKE_C_COMPILER_ID MATCHES "^(GNU|Clang|AppleClang|MSVC)$")
    message(FATAL_ERROR "Bundled zlib: unsupported C compiler for private preinclude")
  endif()
  include(BundledZlib)
  ghidra_prepare_bundled_zlib("${CMAKE_CURRENT_SOURCE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/bundled-zlib")
  file(GLOB _zlib_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../zlib/*.c")
  add_library(ghidra_zlib_objs OBJECT ${_zlib_sources} cmake/BundledZlibAdapter.c)
  target_include_directories(ghidra_zlib_objs PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zlib")
  set(_prefix_header "${CMAKE_CURRENT_BINARY_DIR}/bundled-zlib/BundledZlibPrefix.h")
  if(CMAKE_C_COMPILER_ID STREQUAL "MSVC" OR CMAKE_C_COMPILER_FRONTEND_VARIANT STREQUAL "MSVC")
    target_compile_options(ghidra_zlib_objs PRIVATE "$<$<COMPILE_LANGUAGE:C>:/FI${_prefix_header}>")
  else()
    target_compile_options(ghidra_zlib_objs PRIVATE "$<$<COMPILE_LANGUAGE:C>:-include;${_prefix_header}>")
  endif()
  include(CheckCSourceCompiles)
  unset(_ghidra_zlib_configuration CACHE)
  check_c_source_compiles("#include \"${_prefix_header}\"\n#include \"${CMAKE_CURRENT_SOURCE_DIR}/../zlib/zlib.h\"\nint main(void) { return 0; }" _ghidra_zlib_configuration)
  if(NOT _ghidra_zlib_configuration)
    message(FATAL_ERROR "Bundled zlib: incompatible ambient prefix/DLL/WinCE/no-memcpy flags; see compiler probe")
  endif()
  target_compile_definitions(ghidra_zlib_objs PRIVATE NO_GZIP)
  include(CheckCXXSourceCompiles)
  unset(_ghidra_zlib_cxx_configuration CACHE)
  check_cxx_source_compiles("#if defined(Z_PREFIX) || defined(Z_PREFIX_SET) || defined(ZLIB_DLL)\n#error Incompatible public stream types\n#endif\nint main() { return 0; }" _ghidra_zlib_cxx_configuration)
  if(NOT _ghidra_zlib_cxx_configuration)
    message(FATAL_ERROR "Bundled zlib: incompatible ambient C++ prefix/DLL flags")
  endif()
  set(_zlib_objects $<TARGET_OBJECTS:ghidra_zlib_objs>)
  set(_zlib_link)
else()
  find_package(ZLIB REQUIRED)
  set(_zlib_objects)
  set(_zlib_link ZLIB::ZLIB)
endif()

# ---------------------------------------------------------------------------
# Object libraries, one per Makefile source set.
_ghidra_decomp_object_library(ghidra_core_objs ${GHIDRA_DECOMP_CORE_SOURCES})
_ghidra_decomp_object_library(ghidra_sleigh_objs ${GHIDRA_DECOMP_SLEIGH_SOURCES})
# The four DECCORE units that the Makefile's LIBSLA_NAMES also needs.
_ghidra_decomp_object_library(ghidra_sladeccore_objs ${GHIDRA_DECOMP_LIBSLA_DECCORE_SOURCES})
_ghidra_decomp_object_library(ghidra_deccore_objs ${GHIDRA_DECOMP_DECCORE_SOURCES})

set(_extra_sources ${GHIDRA_DECOMP_EXTRA_BASE_SOURCES})
if(GHIDRA_DECOMP_CONSOLE)
  list(APPEND _extra_sources ${GHIDRA_DECOMP_EXTRA_CONSOLE_SOURCES})
endif()
_ghidra_decomp_object_library(ghidra_extra_objs ${_extra_sources})

# ---------------------------------------------------------------------------
# sla: Makefile LIBSLA_NAMES = CORE + SLEIGH + loadimage sleigh memstate
# emulate opbehavior.  Disassembly, p-code, emulation; no decompiler.
add_library(sla STATIC
  $<TARGET_OBJECTS:ghidra_core_objs>
  $<TARGET_OBJECTS:ghidra_sleigh_objs>
  $<TARGET_OBJECTS:ghidra_sladeccore_objs>
  ${_zlib_objects})
_ghidra_decomp_archive_interface(sla)
target_link_libraries(sla PUBLIC ${_zlib_link})
add_library(ghidra::sla ALIAS sla)

# decomp_archive: Makefile LIBDECOMP_NAMES = CORE + DECCORE + EXTRA + SLEIGH,
# without bfd_arch/loadimage_bfd.
add_library(decomp_archive STATIC
  $<TARGET_OBJECTS:ghidra_core_objs>
  $<TARGET_OBJECTS:ghidra_sleigh_objs>
  $<TARGET_OBJECTS:ghidra_sladeccore_objs>
  $<TARGET_OBJECTS:ghidra_deccore_objs>
  $<TARGET_OBJECTS:ghidra_extra_objs>
  ${_zlib_objects})
_ghidra_decomp_archive_interface(decomp_archive)
target_link_libraries(decomp_archive PUBLIC ${_zlib_link})
add_library(ghidra::decomp_archive ALIAS decomp_archive)

# decomp: the archive linked whole.  The capability singletons (xml, raw,
# c-language, java-language, ...) register themselves from static
# initializers, and a plain archive drops the objects nothing references.
add_library(decomp INTERFACE)
target_link_libraries(decomp INTERFACE
  $<LINK_LIBRARY:WHOLE_ARCHIVE,$<TARGET_NAME:decomp_archive>>)
add_library(ghidra::decomp ALIAS decomp)

# ---------------------------------------------------------------------------
# Programs.
set(_want_sleigh_compiler FALSE)
if(GHIDRA_DECOMP_BUILD_TOOLS OR GHIDRA_DECOMP_SPEC_PROCESSORS)
  set(_want_sleigh_compiler TRUE)
endif()

if(_want_sleigh_compiler)
  _ghidra_decomp_object_library(ghidra_slacomp_objs ${GHIDRA_DECOMP_SLACOMP_SOURCES})
  target_compile_definitions(ghidra_slacomp_objs PRIVATE GHIDRA_SLEIGH_CHECK_OUTPUT_ERRORS=1)
  add_executable(sleigh_compiler $<TARGET_OBJECTS:ghidra_slacomp_objs>)
  set_target_properties(sleigh_compiler PROPERTIES OUTPUT_NAME sleigh_compiler)
  target_link_libraries(sleigh_compiler PRIVATE sla)
  add_executable(ghidra::sleigh_compiler ALIAS sleigh_compiler)
endif()

if(GHIDRA_DECOMP_BUILD_TOOLS AND GHIDRA_DECOMP_CONSOLE)
  add_executable(decomp_console consolemain.cc)
  _ghidra_decomp_compile_settings(decomp_console)
  target_link_libraries(decomp_console PRIVATE decomp)
  add_executable(ghidra::decomp_console ALIAS decomp_console)
endif()

# ---------------------------------------------------------------------------
# Processor specifications.
set(_have_specs FALSE)
if(GHIDRA_DECOMP_SPEC_PROCESSORS)
  # Large specs each need more than 1 GB; serialize them even with -j2.
  set_property(GLOBAL APPEND PROPERTY JOB_POOLS sleigh_specs=1)
  ghidra_sleigh_compile_specs(
    TARGET ghidra_specs
    PROCESSORS ${GHIDRA_DECOMP_SPEC_PROCESSORS}
    PROCESSORS_ROOT "${GHIDRA_DECOMP_PROCESSORS_ROOT}"
    OUTPUT_DIR "${GHIDRA_DECOMP_SLEIGH_HOME}"
    COMPILER sleigh_compiler
    OUT_VAR GHIDRA_DECOMP_SLA_FILES)
  set(_have_specs TRUE)
endif()

# ---------------------------------------------------------------------------
# Tests.
if(GHIDRA_DECOMP_BUILD_TESTS)
  enable_testing()
  set(_cmake_dir "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
  set(_test_binaries)
  if(CMAKE_NM)
    find_program(_ghidra_decomp_cxxfilt NAMES c++filt llvm-cxxfilt)
    if(NOT _ghidra_decomp_cxxfilt)
      message(FATAL_ERROR "Native symbol tests require c++filt or llvm-cxxfilt")
    endif()
  endif()
  add_test(NAME nm_symbol_parser COMMAND "${CMAKE_COMMAND}"
    -P "${_cmake_dir}/TestNmSymbolParsing.cmake")
  set_tests_properties(nm_symbol_parser PROPERTIES LABELS "isolation")
  add_test(NAME install_home_ownership COMMAND "${CMAKE_COMMAND}"
    "-DWORK=${CMAKE_CURRENT_BINARY_DIR}" -P "${_cmake_dir}/TestInstallSleighHome.cmake")
  add_test(NAME bundled_zlib_drift COMMAND "${CMAKE_COMMAND}"
    "-DWORK=${CMAKE_CURRENT_BINARY_DIR}" "-DSOURCE=${CMAKE_CURRENT_SOURCE_DIR}"
    -P "${_cmake_dir}/TestBundledZlib.cmake")
  set_tests_properties(install_home_ownership bundled_zlib_drift PROPERTIES LABELS "install;isolation")
  add_test(NAME installed_header_contract COMMAND "${CMAKE_COMMAND}"
    "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
    "-DTEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}"
    "-DCXX=${CMAKE_CXX_COMPILER}"
    "-DGENERATOR=${CMAKE_GENERATOR}"
    -P "${_cmake_dir}/TestHeaderContract.cmake")
  set_tests_properties(installed_header_contract PROPERTIES LABELS "install;contract")
  if(GHIDRA_DECOMP_LOCAL_ZLIB AND UNIX AND CMAKE_NM)
    add_test(NAME bundled_zlib_symbols COMMAND "${CMAKE_COMMAND}" "-DNM=${CMAKE_NM}"
      "-DAPPLE=${APPLE}" "-DCXXFILT=${_ghidra_decomp_cxxfilt}"
      "-DARCHIVES=$<TARGET_FILE:sla>;$<TARGET_FILE:decomp_archive>"
      "-DOBJECTS=$<TARGET_OBJECTS:ghidra_zlib_objs>"
      "-DSYMBOLS=${CMAKE_CURRENT_BINARY_DIR}/bundled-zlib/symbols.txt"
      "-DC_COMPILER_ID=${CMAKE_C_COMPILER_ID}" "-DSANITIZE=${GHIDRA_DECOMP_SANITIZE}"
      -P "${_cmake_dir}/TestBundledZlibSymbols.cmake")
    add_test(NAME bundled_zlib_symbol_guard COMMAND "${CMAKE_COMMAND}"
      "-DWORK=${CMAKE_CURRENT_BINARY_DIR}" "-DSOURCE=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DCC=${CMAKE_C_COMPILER}" "-DNM=${CMAKE_NM}" "-DAPPLE=${APPLE}"
      "-DCXXFILT=${_ghidra_decomp_cxxfilt}"
      "-DC_COMPILER_ID=${CMAKE_C_COMPILER_ID}" "-DSANITIZE=${GHIDRA_DECOMP_SANITIZE}"
      "-DPREFIX=${_prefix_header}" "-DSYMBOLS=${CMAKE_CURRENT_BINARY_DIR}/bundled-zlib/symbols.txt"
      -P "${_cmake_dir}/TestBundledZlibSymbolGuard.cmake")
    set_tests_properties(bundled_zlib_symbols bundled_zlib_symbol_guard PROPERTIES LABELS "isolation")
  endif()
  if(GHIDRA_DECOMP_LOCAL_ZLIB)
    set(_adapter_tests bundled_zlib_adapter)
    if(CMAKE_SIZEOF_VOID_P EQUAL 8)
      list(APPEND _adapter_tests bundled_zlib_packed_adapter)
    endif()
    foreach(_target IN LISTS _adapter_tests)
      add_executable(${_target} cmake/BundledZlibAdapterTest.cc $<TARGET_OBJECTS:ghidra_zlib_objs>)
      target_include_directories(${_target} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/../zlib" "${_cmake_dir}")
      target_compile_features(${_target} PRIVATE cxx_std_11)
      if(_target STREQUAL "bundled_zlib_packed_adapter")
        target_compile_definitions(${_target} PRIVATE GHIDRA_TEST_PACKED)
      endif()
      add_test(NAME ${_target} COMMAND ${_target})
      set_tests_properties(${_target} PROPERTIES LABELS "isolation")
    endforeach()
  endif()

  if(GHIDRA_DECOMP_CONSOLE)
    file(GLOB _unittest_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../unittests/*.cc")
    add_executable(decomp_test test.cc ${_unittest_sources})
    _ghidra_decomp_compile_settings(decomp_test)
    target_link_libraries(decomp_test PRIVATE decomp)
    list(APPEND _test_binaries decomp_test)
  endif()

  add_executable(sleigh_smoke "${_cmake_dir}/smoke/sleigh_smoke.cc")
  _ghidra_decomp_compile_settings(sleigh_smoke)
  target_link_libraries(sleigh_smoke PRIVATE sla)
  list(APPEND _test_binaries sleigh_smoke)

  add_executable(decomp_smoke "${_cmake_dir}/smoke/decomp_smoke.cc")
  _ghidra_decomp_compile_settings(decomp_smoke)
  target_link_libraries(decomp_smoke PRIVATE decomp)
  list(APPEND _test_binaries decomp_smoke)

  if(TARGET sleigh_compiler)
    list(APPEND _test_binaries sleigh_compiler)
  endif()
  if(TARGET decomp_console)
    list(APPEND _test_binaries decomp_console)
  endif()

  # Manifest.
  add_test(NAME manifest_matches_makefile
    COMMAND "${CMAKE_COMMAND}"
      -DMAKEFILE=${CMAKE_CURRENT_SOURCE_DIR}/Makefile
      -DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}
      -P "${_cmake_dir}/CheckMakefileManifest.cmake")
  set_tests_properties(manifest_matches_makefile PROPERTIES LABELS "manifest")
  add_test(NAME manifest_rejects_archive_drift
    COMMAND "${CMAKE_COMMAND}"
      -DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}
      -DTEST_DIR=${CMAKE_CURRENT_BINARY_DIR}/manifest-regression
      -P "${_cmake_dir}/TestMakefileManifest.cmake")
  set_tests_properties(manifest_rejects_archive_drift PROPERTIES LABELS "manifest")
  set(_spec_test_compiler)
  if(TARGET sleigh_compiler AND NOT CMAKE_CROSSCOMPILING)
    set(_spec_test_compiler "-DCOMPILER=$<TARGET_FILE:sleigh_compiler>")
  else()
    message(STATUS "sleigh_specs_incremental: metadata-only copy fallback (no runnable native compiler)")
  endif()
  add_test(NAME sleigh_specs_incremental
    COMMAND "${CMAKE_COMMAND}"
      "-DMODULE=${_cmake_dir}/SleighCompileSpecs.cmake"
      "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DTEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}/cmake-tests"
      ${_spec_test_compiler}
      -P "${_cmake_dir}/TestSleighCompileSpecs.cmake")
  set_tests_properties(sleigh_specs_incremental PROPERTIES LABELS "specs")
  add_test(NAME build_safety_guard COMMAND "${CMAKE_COMMAND}"
    "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
    "-DTEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}/cmake-tests"
    -P "${_cmake_dir}/TestBuildSafety.cmake")
  set_tests_properties(build_safety_guard PROPERTIES LABELS "isolation")
  if(TARGET decomp_test AND NOT CMAKE_CROSSCOMPILING)
    add_test(NAME data_test_guard COMMAND "${CMAKE_COMMAND}"
      "-DBINARY=$<TARGET_FILE:decomp_test>"
      "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DSLEIGH_HOME=${GHIDRA_DECOMP_SLEIGH_HOME}"
      "-DTEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}/cmake-tests"
      -P "${_cmake_dir}/TestDataTests.cmake")
    set_tests_properties(data_test_guard PROPERTIES LABELS "data;isolation")
  endif()
  if(GHIDRA_DECOMP_MASTER_MAKEFILE)
    get_filename_component(_master_dir "${GHIDRA_DECOMP_MASTER_MAKEFILE}" DIRECTORY)
    add_test(NAME manifest_matches_makefile_master
      COMMAND "${CMAKE_COMMAND}"
        -DMAKEFILE=${GHIDRA_DECOMP_MASTER_MAKEFILE}
        -DSOURCE_DIR=${_master_dir}
        -P "${_cmake_dir}/CheckMakefileManifest.cmake")
    set_tests_properties(manifest_matches_makefile_master PROPERTIES LABELS "manifest")
  endif()

  # Unit tests name languages from all of these processor modules; data tests
  # are filtered independently below.
  set(_unittest_processors x86 Toy PowerPC MIPS AARCH64)
  set(_have_unittest_processors TRUE)
  foreach(_processor IN LISTS _unittest_processors)
    if(NOT _processor IN_LIST GHIDRA_DECOMP_SPEC_PROCESSORS)
      set(_have_unittest_processors FALSE)
    endif()
  endforeach()
  if(TARGET decomp_test AND _have_unittest_processors)
    add_test(NAME decomp_unittests
      COMMAND decomp_test -sleighpath "${GHIDRA_DECOMP_SLEIGH_HOME}" unittests
      WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
    set_tests_properties(decomp_unittests PROPERTIES LABELS "unit")
  endif()

  if(TARGET decomp_test AND _have_specs)
    # Select the data tests whose language is produced by the compiled
    # processors.  Language ids come from the .ldefs files.
    set(_langids)
    foreach(_proc IN LISTS GHIDRA_DECOMP_SPEC_PROCESSORS)
      file(GLOB _ldefs "${GHIDRA_DECOMP_PROCESSORS_ROOT}/${_proc}/data/languages/*.ldefs")
      foreach(_ld IN LISTS _ldefs)
        file(READ "${_ld}" _ld_text)
        string(REGEX MATCHALL "id=\"[^\":]+:[^\":]+:[^\":]+:[^\":]+\"" _ids "${_ld_text}")
        foreach(_id IN LISTS _ids)
          string(REGEX REPLACE "^id=\"|\"$" "" _id "${_id}")
          list(APPEND _langids "${_id}")
        endforeach()
      endforeach()
    endforeach()
    list(REMOVE_DUPLICATES _langids)

    file(REAL_PATH "${CMAKE_CURRENT_BINARY_DIR}" _canonical_build)
    set(_datatest_dir "${_canonical_build}/.ghidra-cmake/datatests")
    file(GLOB _datatests CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../datatests/*.xml")
    set(_selected 0)
    set(_selected_files)
    set(_total 0)
    foreach(_xml IN LISTS _datatests)
      math(EXPR _total "${_total} + 1")
      file(STRINGS "${_xml}" _arch_line REGEX "arch=\"" LIMIT_COUNT 1)
      if(_arch_line MATCHES "arch=\"([^\":]+:[^\":]+:[^\":]+:[^\":]+)")
        if("${CMAKE_MATCH_1}" IN_LIST _langids)
          list(APPEND _selected_files "${_xml}")
          math(EXPR _selected "${_selected} + 1")
        endif()
      endif()
    endforeach()
    ghidra_decomp_stage_datatests("${_datatest_dir}" ${_selected_files})
    message(STATUS "data tests: ${_selected} of ${_total} cover the compiled processors")
    if(_selected GREATER 0)
      add_test(NAME decomp_datatests
        COMMAND "${CMAKE_COMMAND}" "-DBINARY=$<TARGET_FILE:decomp_test>"
          "-DSLEIGH_HOME=${GHIDRA_DECOMP_SLEIGH_HOME}" "-DDATA_DIR=${_datatest_dir}"
          -P "${_cmake_dir}/RunDataTests.cmake"
        WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
      set_tests_properties(decomp_datatests PROPERTIES LABELS "data")
    endif()
  endif()

  # SLEIGH smoke tests: fixed byte strings, expected output committed.
  if(_have_specs)
    foreach(_case x86-64 arm-thumb aarch64)
      if(_case STREQUAL "x86-64")
        set(_processor x86)
      elseif(_case STREQUAL "arm-thumb")
        set(_processor ARM)
      else()
        set(_processor AARCH64)
      endif()
      if(NOT _processor IN_LIST GHIDRA_DECOMP_SPEC_PROCESSORS)
        continue()
      endif()
      add_test(NAME sleigh_smoke_${_case}
        COMMAND sleigh_smoke "${GHIDRA_DECOMP_SLEIGH_HOME}" ${_case}
                --expect "${_cmake_dir}/smoke/expected/${_case}.txt")
      set_tests_properties(sleigh_smoke_${_case} PROPERTIES LABELS "smoke")
    endforeach()
  endif()

  add_test(NAME capability_linkage COMMAND decomp_smoke --check-capabilities)
  set_tests_properties(capability_linkage PROPERTIES LABELS "smoke;isolation")

  # These isolation checks use Unix object/runtime tools and execute target
  # binaries, so they are native-Unix tests only.
  if(UNIX AND NOT CMAKE_CROSSCOMPILING)
    set(_binary_files)
    foreach(_t IN LISTS _test_binaries)
      list(APPEND _binary_files "$<TARGET_FILE:${_t}>")
    endforeach()
    list(JOIN _binary_files "$<SEMICOLON>" _binary_files)
    add_test(NAME no_jvm_linkage
      COMMAND "${CMAKE_COMMAND}" -DMODE=linkage "-DBINARIES=${_binary_files}"
              -P "${_cmake_dir}/NoJvmCheck.cmake")
    set_tests_properties(no_jvm_linkage PROPERTIES LABELS "isolation")
    add_test(NAME no_jvm_guard
      COMMAND "${CMAKE_COMMAND}" "-DBINARY=$<TARGET_FILE:decomp_smoke>"
              -P "${_cmake_dir}/TestNoJvmCheck.cmake")
    set_tests_properties(no_jvm_guard PROPERTIES LABELS "isolation")

    if("x86" IN_LIST GHIDRA_DECOMP_SPEC_PROCESSORS)
      find_program(GHIDRA_DECOMP_STRACE strace)
      set(_strace_arg)
      if(GHIDRA_DECOMP_STRACE)
        set(_strace_arg "-DSTRACE=${GHIDRA_DECOMP_STRACE}")
      endif()
      add_test(NAME no_jvm_runtime
        COMMAND "${CMAKE_COMMAND}" -DMODE=runtime
                "-DBINARY=$<TARGET_FILE:sleigh_smoke>"
                "-DARGS=${GHIDRA_DECOMP_SLEIGH_HOME}$<SEMICOLON>x86-64$<SEMICOLON>--expect$<SEMICOLON>${_cmake_dir}/smoke/expected/x86-64.txt"
                "-DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}"
                ${_strace_arg}
                -P "${_cmake_dir}/NoJvmCheck.cmake")
      set_tests_properties(no_jvm_runtime PROPERTIES LABELS "isolation")
    endif()

    if(CMAKE_NM)
      add_test(NAME no_ghidra_process_symbols
        COMMAND "${CMAKE_COMMAND}" -DMODE=symbols "-DNM=${CMAKE_NM}" "-DAPPLE=${APPLE}"
                "-DCXXFILT=${_ghidra_decomp_cxxfilt}"
                "-DARCHIVE=$<TARGET_FILE:decomp_archive>"
                "-DPATTERN=GhidraCapability|GhidraCommand"
                -P "${_cmake_dir}/NoJvmCheck.cmake")
      set_tests_properties(no_ghidra_process_symbols PROPERTIES LABELS "isolation")
    else()
      message(STATUS "no_ghidra_process_symbols not registered: CMAKE_NM is not set")
    endif()
  endif()
endif()

# ---------------------------------------------------------------------------
# Install and export.
if(GHIDRA_DECOMP_INSTALL)
  set(_sleigh_install_files)
  set(_sleigh_install_home "${GHIDRA_DECOMP_SLEIGH_HOME}")
  if(_have_specs)
    get_target_property(_sleigh_install_files ghidra_specs GHIDRA_SLEIGH_INSTALLABLE_FILES)
    get_target_property(_sleigh_install_home ghidra_specs GHIDRA_SLEIGH_HOME)
  endif()
  configure_file(cmake/InstallSleighHome.cmake.in InstallSleighHomePreflight.cmake @ONLY)
  # Must precede archives, headers, and all other package writes, including
  # component-only installs. Only the SleighHome component commits selection.
  install(SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/InstallSleighHomePreflight.cmake" ALL_COMPONENTS)
  set(_install_targets sla decomp_archive decomp)
  if(TARGET sleigh_compiler AND GHIDRA_DECOMP_BUILD_TOOLS)
    list(APPEND _install_targets sleigh_compiler)
  endif()
  if(TARGET decomp_console)
    list(APPEND _install_targets decomp_console)
  endif()
  install(TARGETS ${_install_targets} EXPORT GhidraDecompilerTargets
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

  file(GLOB _headers CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/*.hh" "${CMAKE_CURRENT_SOURCE_DIR}/*.h")
  # These implementation families are absent from both installed archives.
  # Retain the console include closure of unchanged libdecomp.hh even with
  # console OFF; linking those optional declarations requires HAVE_CONSOLE.
  # analyzesigs.hh includes unchanged codedata.hh. Install that declaration
  # dependency even though the BFD-dependent codedata implementation is absent.
  set(_unsupported_headers ${GHIDRA_DECOMP_GHIDRA_SOURCES}
    ${GHIDRA_DECOMP_EXTRA_BFD_SOURCES}
    ${GHIDRA_DECOMP_SLACOMP_SOURCES})
  foreach(_name IN LISTS _unsupported_headers)
    list(REMOVE_ITEM _headers "${CMAKE_CURRENT_SOURCE_DIR}/${_name}.hh"
      "${CMAKE_CURRENT_SOURCE_DIR}/${_name}.h")
  endforeach()
  install(FILES ${_headers} DESTINATION "${GHIDRA_DECOMP_INSTALL_INCLUDEDIR}" COMPONENT Headers)
  if(GHIDRA_DECOMP_LOCAL_ZLIB)
    # compression.hh includes "../zlib/zlib.h" under LOCAL_ZLIB.
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../zlib/zlib.h" "${CMAKE_CURRENT_SOURCE_DIR}/../zlib/zconf.h"
      DESTINATION "${GHIDRA_DECOMP_INSTALL_ZLIB_INCLUDEDIR}" COMPONENT Headers)
  endif()

  set(_config_dir "${CMAKE_INSTALL_LIBDIR}/cmake/GhidraDecompiler")
  install(EXPORT GhidraDecompilerTargets
    NAMESPACE ghidra::
    FILE GhidraDecompilerTargets.cmake
    DESTINATION "${_config_dir}")
  configure_package_config_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/GhidraDecompilerConfig.cmake.in"
    "${CMAKE_CURRENT_BINARY_DIR}/GhidraDecompilerConfig.cmake"
    INSTALL_DESTINATION "${_config_dir}"
    PATH_VARS GHIDRA_DECOMP_INSTALL_INCLUDEDIR GHIDRA_DECOMP_INSTALL_SLEIGH_HOME)
  write_basic_package_version_file(
    "${CMAKE_CURRENT_BINARY_DIR}/GhidraDecompilerConfigVersion.cmake"
    VERSION "${PROJECT_VERSION}"
    COMPATIBILITY ExactVersion)
  install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/GhidraDecompilerConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/GhidraDecompilerConfigVersion.cmake"
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/SleighCompileSpecs.cmake"
    "${CMAKE_CURRENT_SOURCE_DIR}/cmake/BuildSafety.cmake"
    DESTINATION "${_config_dir}")
  install(CODE "set(GHIDRA_INSTALL_PHASE commit)\ninclude(\"${CMAKE_CURRENT_SOURCE_DIR}/cmake/InstallSleighHome.cmake\")"
    COMPONENT SleighHome)
  if(GHIDRA_DECOMP_BUILD_TESTS AND PROJECT_IS_TOP_LEVEL AND NOT CMAKE_CROSSCOMPILING)
    configure_file(cmake/InstalledConsumer.cmake.in InstalledConsumer.cmake @ONLY)
    add_test(NAME installed_consumer
      COMMAND "${CMAKE_COMMAND}" "-DCONFIG=$<CONFIG>"
        -P "${CMAKE_CURRENT_BINARY_DIR}/InstalledConsumer.cmake")
    set_tests_properties(installed_consumer PROPERTIES LABELS "install;smoke")
  endif()
endif()
