cmake_minimum_required(VERSION 3.24)
include("${CMAKE_CURRENT_LIST_DIR}/NmSymbols.cmake")

set(_elf_inventory
  "ghidra_z_deflate T 00000000 20\nz_deflate U\n_ZN6ghidra8Compress7deflateEPhib T 00000020 10\n")
ghidra_parse_nm_inventory("${_elf_inventory}" FALSE _elf_symbols _elf_definitions)
foreach(_expected ghidra_z_deflate z_deflate _ZN6ghidra8Compress7deflateEPhib)
  if(NOT _expected IN_LIST _elf_symbols)
    message(FATAL_ERROR "ELF nm row was not parsed: ${_expected}")
  endif()
endforeach()
if(z_deflate IN_LIST _elf_definitions)
  message(FATAL_ERROR "An undefined ELF symbol was reported as a definition")
endif()

set(_macho_inventory
  "_ghidra_z_deflate T 00000000 20\n_z_deflate U\n__ZN6ghidra8Compress7deflateEPhib T 00000020 10\n")
ghidra_parse_nm_inventory("${_macho_inventory}" TRUE _macho_symbols _macho_definitions)
foreach(_expected ghidra_z_deflate z_deflate _ZN6ghidra8Compress7deflateEPhib)
  if(NOT _expected IN_LIST _macho_symbols)
    message(FATAL_ERROR "Mach-O nm row was not normalized: ${_expected}")
  endif()
endforeach()
if(z_deflate IN_LIST _macho_definitions)
  message(FATAL_ERROR "An undefined Mach-O symbol was reported as a definition")
endif()

find_program(_cxxfilt NAMES c++filt llvm-cxxfilt)
if(_cxxfilt)
  ghidra_demangle_nm_symbols("_ZN6ghidra8Compress7deflateEPhib" "${_cxxfilt}" _demangled)
  if(NOT _demangled MATCHES "ghidra::Compress::deflate\\(")
    message(FATAL_ERROR "Mach-O Itanium symbol did not demangle: ${_demangled}")
  endif()
  # Exceed the common per-argument limit to guard against regressions that
  # pass the full archive inventory as c++filt command-line arguments.
  string(REPEAT "x" 200000 _large_symbol)
  ghidra_demangle_nm_symbols("${_large_symbol}" "${_cxxfilt}" _large_demangled)
  if(NOT _large_demangled STREQUAL _large_symbol)
    message(FATAL_ERROR "Large symbol was changed by stdin demangling")
  endif()
endif()

message(STATUS "ELF and Mach-O nm symbol rows parsed and normalized")
