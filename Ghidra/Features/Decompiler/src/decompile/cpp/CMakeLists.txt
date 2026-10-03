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
# Source lists are read from ../Makefile at configure time
# (cmake/GhidraDecompSources.cmake), so this file works unchanged on every
# Ghidra release that uses that Makefile layout (10.3 to the current master).
# No upstream source is modified or moved; generated parsers are the
# committed ones.

cmake_minimum_required(VERSION 3.24)

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
option(GHIDRA_DECOMP_CHECK_MANIFEST "Check at configure time that the archives match the Makefile's LIBSLA_NAMES and LIBDECOMP_NAMES" ON)
set(GHIDRA_DECOMP_MASTER_MAKEFILE "" CACHE FILEPATH
  "Optional path to another checkout's decompiler Makefile; adds the ctest manifest_matches_makefile_master")
set(GHIDRA_DECOMP_SLEIGH_HOME "${CMAKE_CURRENT_BINARY_DIR}/sleigh-home" CACHE PATH
  "Root of the generated sleigh home tree (Ghidra/Processors/<P>/data/languages/*.sla)")
set(GHIDRA_DECOMP_PROCESSORS_ROOT "${GHIDRA_DECOMP_GHIDRA_DIR}/Processors" CACHE PATH
  "Directory holding the processor modules (Ghidra/Processors)")
set(GHIDRA_DECOMP_SLEIGH_COMPILER "" CACHE FILEPATH
  "SLEIGH compiler that runs on the build host, used for the specifications instead of the one built here (needed when cross-compiling without an emulator)")

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
# Facts parsed from the sources for the exported config.  slaformat.cc (and
# compressed .sla files) exist from Ghidra 11.1 on.
set(GHIDRA_DECOMP_SLA_FORMAT_VERSION "")
if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/slaformat.cc")
  file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/slaformat.cc" _sla_format_line
       REGEX "^const int4 FORMAT_VERSION[ \t]*=")
  if(_sla_format_line MATCHES "=[ \t]*([0-9]+)")
    set(GHIDRA_DECOMP_SLA_FORMAT_VERSION "${CMAKE_MATCH_1}")
  else()
    message(FATAL_ERROR "Could not parse FORMAT_VERSION from slaformat.cc")
  endif()
  message(STATUS "GhidraDecompiler ${PROJECT_VERSION}, .sla format ${GHIDRA_DECOMP_SLA_FORMAT_VERSION}")
else()
  message(STATUS "GhidraDecompiler ${PROJECT_VERSION}, no slaformat.cc: uncompressed .sla files")
endif()

# ---------------------------------------------------------------------------
# Sources, read from the Makefile, and the archive check.
list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(GhidraDecompSources)
include(CheckMakefileManifest)
include(SleighCompileSpecs)

ghidra_decomp_read_sources("${CMAKE_CURRENT_SOURCE_DIR}/Makefile" "${CMAKE_CURRENT_SOURCE_DIR}")
if(GHIDRA_DECOMP_CHECK_MANIFEST)
  ghidra_decomp_check_manifest("${CMAKE_CURRENT_SOURCE_DIR}/Makefile" "${CMAKE_CURRENT_SOURCE_DIR}")
endif()

# zlib is needed only where the sources compress .sla files (11.1 and later).
set(_needs_zlib FALSE)
if("compression" IN_LIST GHIDRA_DECOMP_SLEIGH_SOURCES OR "compression" IN_LIST GHIDRA_DECOMP_CORE_SOURCES)
  set(_needs_zlib TRUE)
endif()
set(GHIDRA_DECOMP_NEEDS_ZLIB ${_needs_zlib})
if(GHIDRA_DECOMP_LOCAL_ZLIB AND NOT _needs_zlib)
  message(STATUS "GHIDRA_DECOMP_LOCAL_ZLIB has no effect: these sources do not use zlib")
endif()
if(GHIDRA_DECOMP_LOCAL_ZLIB AND _needs_zlib AND NOT EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/../zlib/zlib.h")
  message(FATAL_ERROR "GHIDRA_DECOMP_LOCAL_ZLIB is ON but ${CMAKE_CURRENT_SOURCE_DIR}/../zlib/zlib.h does not exist")
endif()
set(_use_local_zlib FALSE)
if(GHIDRA_DECOMP_LOCAL_ZLIB AND _needs_zlib)
  set(_use_local_zlib TRUE)
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
if(_use_local_zlib)
  list(APPEND GHIDRA_DECOMP_PUBLIC_DEFINITIONS LOCAL_ZLIB)
endif()
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND GHIDRA_DECOMP_PUBLIC_DEFINITIONS LINUX _LINUX)
elseif(WIN32)
  # filemanage.cc and types.h select their Windows code on _WINDOWS, which
  # the Gradle build defines together with WINDOWS.
  list(APPEND GHIDRA_DECOMP_PUBLIC_DEFINITIONS WINDOWS _WINDOWS)
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
  target_compile_definitions(${target} PRIVATE ${GHIDRA_DECOMP_PUBLIC_DEFINITIONS})
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
    list(APPEND _srcs "${CMAKE_CURRENT_SOURCE_DIR}/${_n}.cc")
  endforeach()
  add_library(${name} OBJECT ${_srcs})
  _ghidra_decomp_compile_settings(${name})
  if(_needs_zlib AND NOT _use_local_zlib)
    target_link_libraries(${name} PRIVATE ZLIB::ZLIB)
  endif()
endfunction()

# ---------------------------------------------------------------------------
# zlib
set(_zlib_objects)
set(_zlib_link)
if(_use_local_zlib)
  enable_language(C)
  file(GLOB _zlib_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../zlib/*.c")
  add_library(ghidra_zlib_objs OBJECT ${_zlib_sources})
  target_compile_definitions(ghidra_zlib_objs PRIVATE NO_GZIP)
  set(_zlib_objects $<TARGET_OBJECTS:ghidra_zlib_objs>)
elseif(_needs_zlib)
  find_package(ZLIB REQUIRED)
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
add_library(ghidra_sla STATIC
  $<TARGET_OBJECTS:ghidra_core_objs>
  $<TARGET_OBJECTS:ghidra_sleigh_objs>
  $<TARGET_OBJECTS:ghidra_sladeccore_objs>
  ${_zlib_objects})
_ghidra_decomp_archive_interface(ghidra_sla)
target_link_libraries(ghidra_sla PUBLIC ${_zlib_link})
set_target_properties(ghidra_sla PROPERTIES OUTPUT_NAME sla EXPORT_NAME sla)
add_library(ghidra::sla ALIAS ghidra_sla)

# decomp_archive: Makefile LIBDECOMP_NAMES = CORE + DECCORE + EXTRA + SLEIGH,
# without bfd_arch/loadimage_bfd.
add_library(ghidra_decomp_archive STATIC
  $<TARGET_OBJECTS:ghidra_core_objs>
  $<TARGET_OBJECTS:ghidra_sleigh_objs>
  $<TARGET_OBJECTS:ghidra_sladeccore_objs>
  $<TARGET_OBJECTS:ghidra_deccore_objs>
  $<TARGET_OBJECTS:ghidra_extra_objs>
  ${_zlib_objects})
_ghidra_decomp_archive_interface(ghidra_decomp_archive)
target_link_libraries(ghidra_decomp_archive PUBLIC ${_zlib_link})
set_target_properties(ghidra_decomp_archive PROPERTIES
  OUTPUT_NAME decomp_archive EXPORT_NAME decomp_archive)
add_library(ghidra::decomp_archive ALIAS ghidra_decomp_archive)

# decomp: the archive linked whole.  The capability singletons (xml, raw,
# c-language, java-language, ...) register themselves from static
# initializers, and a plain archive drops the objects nothing references.
#
# Every target name here starts with ghidra_ so that a project including
# this directory (add_subdirectory, FetchContent) cannot collide with it.
# The exported names (ghidra::sla, ghidra::decomp, ...) and the file names
# (libsla.a, sleigh_compiler, ...) are the short ones.
add_library(ghidra_decomp INTERFACE)
target_link_libraries(ghidra_decomp INTERFACE
  $<LINK_LIBRARY:WHOLE_ARCHIVE,$<TARGET_NAME:ghidra_decomp_archive>>)
set_target_properties(ghidra_decomp PROPERTIES EXPORT_NAME decomp)
add_library(ghidra::decomp ALIAS ghidra_decomp)

# ---------------------------------------------------------------------------
# Programs.
# The specifications are compiled by the sleigh_compiler built here unless
# GHIDRA_DECOMP_SLEIGH_COMPILER names one that runs on the build host.  When
# cross-compiling, the built one runs through CMAKE_CROSSCOMPILING_EMULATOR.
if(GHIDRA_DECOMP_SPEC_PROCESSORS AND CMAKE_CROSSCOMPILING AND NOT GHIDRA_DECOMP_SLEIGH_COMPILER
   AND NOT CMAKE_CROSSCOMPILING_EMULATOR)
  message(FATAL_ERROR "Cross-compiling with GHIDRA_DECOMP_SPEC_PROCESSORS set: the sleigh_compiler "
    "built here cannot run on the build host.  Set GHIDRA_DECOMP_SLEIGH_COMPILER to a host build "
    "of sleigh_compiler, set CMAKE_CROSSCOMPILING_EMULATOR, or set GHIDRA_DECOMP_SPEC_PROCESSORS to "
    "an empty string.")
endif()
if(GHIDRA_DECOMP_SLEIGH_COMPILER AND NOT EXISTS "${GHIDRA_DECOMP_SLEIGH_COMPILER}")
  message(FATAL_ERROR "GHIDRA_DECOMP_SLEIGH_COMPILER does not exist: ${GHIDRA_DECOMP_SLEIGH_COMPILER}")
endif()

set(_want_sleigh_compiler FALSE)
if(GHIDRA_DECOMP_BUILD_TOOLS OR (GHIDRA_DECOMP_SPEC_PROCESSORS AND NOT GHIDRA_DECOMP_SLEIGH_COMPILER))
  set(_want_sleigh_compiler TRUE)
endif()

if(_want_sleigh_compiler)
  _ghidra_decomp_object_library(ghidra_slacomp_objs ${GHIDRA_DECOMP_SLACOMP_SOURCES})
  add_executable(ghidra_sleigh_compiler $<TARGET_OBJECTS:ghidra_slacomp_objs>)
  set_target_properties(ghidra_sleigh_compiler PROPERTIES
    OUTPUT_NAME sleigh_compiler EXPORT_NAME sleigh_compiler)
  target_link_libraries(ghidra_sleigh_compiler PRIVATE ghidra_sla)
  add_executable(ghidra::sleigh_compiler ALIAS ghidra_sleigh_compiler)
endif()

if(GHIDRA_DECOMP_BUILD_TOOLS AND GHIDRA_DECOMP_CONSOLE)
  add_executable(ghidra_decomp_console consolemain.cc)
  _ghidra_decomp_compile_settings(ghidra_decomp_console)
  set_target_properties(ghidra_decomp_console PROPERTIES
    OUTPUT_NAME decomp_console EXPORT_NAME decomp_console)
  target_link_libraries(ghidra_decomp_console PRIVATE ghidra_decomp)
  add_executable(ghidra::decomp_console ALIAS ghidra_decomp_console)
endif()

# ---------------------------------------------------------------------------
# Processor specifications.
set(_have_specs FALSE)
if(GHIDRA_DECOMP_SPEC_PROCESSORS)
  # Two specs at a time: x86-64 and AARCH64 each need more than 1 GB.
  set_property(GLOBAL APPEND PROPERTY JOB_POOLS sleigh_specs=2)
  if(GHIDRA_DECOMP_SLEIGH_COMPILER)
    set(_spec_compiler "${GHIDRA_DECOMP_SLEIGH_COMPILER}")
  else()
    set(_spec_compiler ghidra_sleigh_compiler)
  endif()
  ghidra_sleigh_compile_specs(
    TARGET ghidra_specs
    PROCESSORS ${GHIDRA_DECOMP_SPEC_PROCESSORS}
    PROCESSORS_ROOT "${GHIDRA_DECOMP_PROCESSORS_ROOT}"
    OUTPUT_DIR "${GHIDRA_DECOMP_SLEIGH_HOME}"
    COMPILER ${_spec_compiler}
    OUT_VAR GHIDRA_DECOMP_SLA_FILES)
  set(_have_specs TRUE)
endif()

# ---------------------------------------------------------------------------
# Tests.
if(GHIDRA_DECOMP_BUILD_TESTS)
  enable_testing()
  set(_cmake_dir "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
  set(_test_binaries)

  if(GHIDRA_DECOMP_CONSOLE)
    file(GLOB _unittest_sources CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../unittests/*.cc")
    add_executable(ghidra_decomp_test test.cc ${_unittest_sources})
    _ghidra_decomp_compile_settings(ghidra_decomp_test)
    set_target_properties(ghidra_decomp_test PROPERTIES OUTPUT_NAME decomp_test)
    target_link_libraries(ghidra_decomp_test PRIVATE ghidra_decomp)
    list(APPEND _test_binaries ghidra_decomp_test)
  endif()

  add_executable(ghidra_sleigh_smoke "${_cmake_dir}/smoke/sleigh_smoke.cc")
  _ghidra_decomp_compile_settings(ghidra_sleigh_smoke)
  set_target_properties(ghidra_sleigh_smoke PROPERTIES OUTPUT_NAME sleigh_smoke)
  if(NOT GHIDRA_DECOMP_SLA_FORMAT_VERSION)
    # Sources older than Ghidra 11.1 read .sla files as XML documents.
    target_compile_definitions(ghidra_sleigh_smoke PRIVATE GHIDRA_DECOMP_XML_SLA)
  endif()
  target_link_libraries(ghidra_sleigh_smoke PRIVATE ghidra_sla)
  list(APPEND _test_binaries ghidra_sleigh_smoke)

  add_executable(ghidra_decomp_smoke "${_cmake_dir}/smoke/decomp_smoke.cc")
  _ghidra_decomp_compile_settings(ghidra_decomp_smoke)
  set_target_properties(ghidra_decomp_smoke PROPERTIES OUTPUT_NAME decomp_smoke)
  target_link_libraries(ghidra_decomp_smoke PRIVATE ghidra_decomp)
  list(APPEND _test_binaries ghidra_decomp_smoke)

  if(TARGET ghidra_sleigh_compiler)
    list(APPEND _test_binaries ghidra_sleigh_compiler)
  endif()
  if(TARGET ghidra_decomp_console)
    list(APPEND _test_binaries ghidra_decomp_console)
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
  add_test(NAME sleigh_specs_incremental
    COMMAND "${CMAKE_COMMAND}"
      "-DMODULE=${_cmake_dir}/SleighCompileSpecs.cmake"
      "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}"
      "-DTEST_ROOT=${CMAKE_CURRENT_BINARY_DIR}/cmake-tests"
      -P "${_cmake_dir}/TestSleighCompileSpecs.cmake")
  set_tests_properties(sleigh_specs_incremental PROPERTIES LABELS "specs")
  set(_gradle_file "${CMAKE_CURRENT_SOURCE_DIR}/../../../buildNatives.gradle")
  if(EXISTS "${_gradle_file}")
    add_test(NAME manifest_matches_gradle
      COMMAND "${CMAKE_COMMAND}"
        -DMAKEFILE=${CMAKE_CURRENT_SOURCE_DIR}/Makefile
        -DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}
        -DGRADLE=${_gradle_file}
        -DGRADLE_STRICT=ON
        -P "${_cmake_dir}/CheckMakefileManifest.cmake")
    set_tests_properties(manifest_matches_gradle PROPERTIES LABELS "manifest")
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

  # The unit tests build architectures for the languages they name.  Find the
  # processor modules that declare those languages and register the tests
  # only when all of them are compiled.  Data tests are filtered below.
  file(GLOB _unittest_files "${CMAKE_CURRENT_SOURCE_DIR}/../unittests/*.cc")
  set(_unittest_ids)
  foreach(_src IN LISTS _unittest_files)
    file(STRINGS "${_src}" _lines REGEX "[A-Za-z0-9_]+:(LE|BE):[0-9]+:")
    foreach(_line IN LISTS _lines)
      string(REGEX MATCHALL "[A-Za-z0-9_]+:(LE|BE):[0-9]+:[A-Za-z0-9_.-]+" _ids "${_line}")
      list(APPEND _unittest_ids ${_ids})
    endforeach()
  endforeach()
  list(REMOVE_DUPLICATES _unittest_ids)
  file(GLOB _all_ldefs "${GHIDRA_DECOMP_PROCESSORS_ROOT}/*/data/languages/*.ldefs")
  set(_unittest_processors)
  set(_have_unittest_processors TRUE)
  foreach(_id IN LISTS _unittest_ids)
    set(_found "")
    foreach(_ld IN LISTS _all_ldefs)
      file(READ "${_ld}" _ld_text)
      string(FIND "${_ld_text}" "id=\"${_id}\"" _pos)
      if(NOT _pos EQUAL -1)
        get_filename_component(_found "${_ld}" DIRECTORY)
        get_filename_component(_found "${_found}" DIRECTORY)
        get_filename_component(_found "${_found}" DIRECTORY)
        get_filename_component(_found "${_found}" NAME)
        break()
      endif()
    endforeach()
    if(_found)
      list(APPEND _unittest_processors "${_found}")
    else()
      message(STATUS "unit tests: no processor module declares language ${_id}")
      set(_have_unittest_processors FALSE)
    endif()
  endforeach()
  list(REMOVE_DUPLICATES _unittest_processors)
  foreach(_processor IN LISTS _unittest_processors)
    if(NOT _processor IN_LIST GHIDRA_DECOMP_SPEC_PROCESSORS)
      set(_have_unittest_processors FALSE)
    endif()
  endforeach()
  string(REPLACE ";" " " _s "${_unittest_processors}")
  message(STATUS "unit tests need processors: ${_s}; registered: ${_have_unittest_processors}")
  if(TARGET ghidra_decomp_test AND _have_unittest_processors)
    add_test(NAME decomp_unittests
      COMMAND ghidra_decomp_test -sleighpath "${GHIDRA_DECOMP_SLEIGH_HOME}" unittests
      WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}")
    set_tests_properties(decomp_unittests PROPERTIES LABELS "unit")
  endif()

  if(TARGET ghidra_decomp_test AND _have_specs)
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

    set(_datatest_dir "${CMAKE_CURRENT_BINARY_DIR}/datatests")
    file(REMOVE_RECURSE "${_datatest_dir}")
    file(MAKE_DIRECTORY "${_datatest_dir}")
    file(GLOB _datatests CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/../datatests/*.xml")
    set(_selected 0)
    set(_total 0)
    foreach(_xml IN LISTS _datatests)
      math(EXPR _total "${_total} + 1")
      file(STRINGS "${_xml}" _arch_line REGEX "arch=\"" LIMIT_COUNT 1)
      if(_arch_line MATCHES "arch=\"([^\":]+:[^\":]+:[^\":]+:[^\":]+)")
        if("${CMAKE_MATCH_1}" IN_LIST _langids)
          get_filename_component(_name "${_xml}" NAME)
          configure_file("${_xml}" "${_datatest_dir}/${_name}" COPYONLY)
          math(EXPR _selected "${_selected} + 1")
        endif()
      endif()
    endforeach()
    message(STATUS "data tests: ${_selected} of ${_total} cover the compiled processors")
    if(_selected GREATER 0)
      add_test(NAME decomp_datatests
        COMMAND ghidra_decomp_test -sleighpath "${GHIDRA_DECOMP_SLEIGH_HOME}" -path "${_datatest_dir}" datatests
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
      # The expected output names the fingerprint of the specification
      # sources it was recorded from.  Output that differs on other sources
      # is reported as skipped (77), not as a pass or a failure.
      ghidra_sleigh_spec_fingerprint("${GHIDRA_DECOMP_PROCESSORS_ROOT}/${_processor}/data/languages" _fingerprint)
      set(_smoke_fingerprint_${_case} "${_fingerprint}")
      file(WRITE "${CMAKE_CURRENT_BINARY_DIR}/smoke-fingerprints/${_case}.txt" "${_fingerprint}\n")
      add_test(NAME sleigh_smoke_${_case}
        COMMAND ghidra_sleigh_smoke "${GHIDRA_DECOMP_SLEIGH_HOME}" ${_case}
                --expect "${_cmake_dir}/smoke/expected/${_case}.txt"
                --spec-fingerprint "${_fingerprint}")
      set_tests_properties(sleigh_smoke_${_case} PROPERTIES LABELS "smoke" SKIP_RETURN_CODE 77)
    endforeach()
  endif()

  add_test(NAME sleigh_smoke_self_test COMMAND ghidra_sleigh_smoke --self-test)
  set_tests_properties(sleigh_smoke_self_test PROPERTIES LABELS "smoke")
  add_test(NAME capability_linkage COMMAND ghidra_decomp_smoke --check-capabilities)
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
      COMMAND "${CMAKE_COMMAND}" "-DBINARY=$<TARGET_FILE:ghidra_decomp_smoke>"
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
                "-DBINARY=$<TARGET_FILE:ghidra_sleigh_smoke>"
                "-DARGS=${GHIDRA_DECOMP_SLEIGH_HOME}$<SEMICOLON>x86-64$<SEMICOLON>--expect$<SEMICOLON>${_cmake_dir}/smoke/expected/x86-64.txt$<SEMICOLON>--spec-fingerprint$<SEMICOLON>${_smoke_fingerprint_x86-64}"
                -DACCEPT_RC=77
                "-DWORKDIR=${CMAKE_CURRENT_BINARY_DIR}"
                ${_strace_arg}
                -P "${_cmake_dir}/NoJvmCheck.cmake")
      set_tests_properties(no_jvm_runtime PROPERTIES LABELS "isolation")
    endif()

    if(CMAKE_NM)
      add_test(NAME no_ghidra_process_symbols
        COMMAND "${CMAKE_COMMAND}" -DMODE=symbols "-DNM=${CMAKE_NM}"
                "-DARCHIVE=$<TARGET_FILE:ghidra_decomp_archive>"
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
  set(_install_targets ghidra_sla ghidra_decomp_archive ghidra_decomp)
  if(TARGET ghidra_sleigh_compiler AND GHIDRA_DECOMP_BUILD_TOOLS)
    list(APPEND _install_targets ghidra_sleigh_compiler)
  endif()
  if(TARGET ghidra_decomp_console)
    list(APPEND _install_targets ghidra_decomp_console)
  endif()
  install(TARGETS ${_install_targets} EXPORT GhidraDecompilerTargets
    ARCHIVE DESTINATION "${CMAKE_INSTALL_LIBDIR}"
    RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")

  file(GLOB _headers CONFIGURE_DEPENDS
    "${CMAKE_CURRENT_SOURCE_DIR}/*.hh" "${CMAKE_CURRENT_SOURCE_DIR}/*.h")
  install(FILES ${_headers} DESTINATION "${GHIDRA_DECOMP_INSTALL_INCLUDEDIR}")
  if(_use_local_zlib)
    # compression.hh includes "../zlib/zlib.h" under LOCAL_ZLIB.
    install(FILES "${CMAKE_CURRENT_SOURCE_DIR}/../zlib/zlib.h" "${CMAKE_CURRENT_SOURCE_DIR}/../zlib/zconf.h"
      DESTINATION "${GHIDRA_DECOMP_INSTALL_ZLIB_INCLUDEDIR}")
  endif()
  if(_have_specs)
    install(DIRECTORY "${GHIDRA_DECOMP_SLEIGH_HOME}/" DESTINATION "${GHIDRA_DECOMP_INSTALL_SLEIGH_HOME}"
      PATTERN ".support-files.stamp" EXCLUDE
      PATTERN ".sleigh-home-owned-by-cmake" EXCLUDE)
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
    COMPATIBILITY SameMajorVersion)
  install(FILES
    "${CMAKE_CURRENT_BINARY_DIR}/GhidraDecompilerConfig.cmake"
    "${CMAKE_CURRENT_BINARY_DIR}/GhidraDecompilerConfigVersion.cmake"
    DESTINATION "${_config_dir}")
  if(GHIDRA_DECOMP_BUILD_TESTS AND PROJECT_IS_TOP_LEVEL AND NOT CMAKE_CROSSCOMPILING)
    configure_file(cmake/InstalledConsumer.cmake.in InstalledConsumer.cmake @ONLY)
    add_test(NAME installed_consumer
      COMMAND "${CMAKE_COMMAND}" "-DCONFIG=$<CONFIG>"
        -P "${CMAKE_CURRENT_BINARY_DIR}/InstalledConsumer.cmake")
    set_tests_properties(installed_consumer PROPERTIES LABELS "install;smoke")
  endif()
endif()
