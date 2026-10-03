# Private linked-symbol namespace for the unchanged, audited zlib 1.3.1 bundle.
# Intentionally fail closed when the vendored inventory changes: review new
# global definitions before updating these fingerprints, not just the table.
function(ghidra_prepare_bundled_zlib source output)
  set(_inventory
    adler32.c=d2af81a407f981ca99f88ce96c96920f0fa4687450b9f19b094411a9b90b15bc
    deflate.c=86c2bb5370b892e4d995fc14661af48353dcd53994693534364dba059a7a428a
    deflate.h=6294259c16d84f9125ecdcc10a37a09e0bd5fc8b4ebaeeb6c8415ecda3525c70
    gzguts.h=d772c783884af9c42a429ce7912b53f1b56281df7517fad2e9e9887bde89860d
    inffast.c=db28cf4a63a393dcc3b48501442c39520ae6c3cc6e4e105b6b0ee6bbfe234ed0
    inffast.h=ffa287937f391015ac93c30e1f663cae491348cf054b24b7d605fbfb212d01cd
    inffixed.h=ecdd7c90aa0336a9c5225d330ab12029c8cdcf21ae20bb95d570404f673135b4
    inflate.c=2bf18aca68cf441583132dffeb4f58fc829e874eb3b3d74507a6d11563ea0c12
    inflate.h=5cab8e1905005d20203078506199a9ade312ae47658d370b8e7e2fec3faa9ad2
    inftrees.c=8c7cc065f8aaed52befa04ec75ee09f3ccf46699fc4f6cea12fdb645d98b4411
    inftrees.h=298daca458b45d57502c4631eb0b015fdd3c18be31418b56a1675992fcbe59c8
    trees.c=24dee2a43a0511521962dec1a9b5a8eacf00e5cab50e6d90802d775e639bc417
    trees.h=44268612648ff3a69841d8a36cb78f793b751c5c47d2ef3f2f7a69ad11948e2d
    zconf.h=4f73e2d80113813452f7e3c0117e0847db323902a795902dca0466d3488e53a7
    zlib.h=5b3dc1c20e9b852ec1ef77f598c89129bae58de98d3773f91a4fc3071dd8cabf
    zutil.c=c368365bfb0325ac2c8dae3bb9b503daf371515707f020c54060e38ceb4d1206
    zutil.h=d757abb6e1bfe3fbc97f8179a8ca9865988a5eafacfe6ee48b5c6de6f18be8de)
  set(_expected)
  foreach(_item IN LISTS _inventory)
    string(REPLACE "=" ";" _pair "${_item}")
    list(GET _pair 0 _name)
    list(GET _pair 1 _expected_hash)
    list(APPEND _expected "${_name}")
    if(NOT EXISTS "${source}/../zlib/${_name}")
      message(FATAL_ERROR "Bundled zlib inventory drift: missing ${_name}")
    endif()
    file(READ "${source}/../zlib/${_name}" _content)
    # Git autocrlf must not change this source contract.
    string(REPLACE "\r\n" "\n" _content "${_content}")
    string(SHA256 _hash "${_content}")
    if(NOT _hash STREQUAL _expected_hash)
      message(FATAL_ERROR "Bundled zlib inventory drift: review linked globals in ${_name}")
    endif()
  endforeach()
  if(CMAKE_SCRIPT_MODE_FILE)
    file(GLOB _actual RELATIVE "${source}/../zlib" "${source}/../zlib/*.[ch]")
  else()
    file(GLOB _actual CONFIGURE_DEPENDS RELATIVE "${source}/../zlib" "${source}/../zlib/*.[ch]")
    foreach(_name IN LISTS _actual)
      set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${source}/../zlib/${_name}")
    endforeach()
    set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${source}/compression.cc")
  endif()
  list(SORT _actual)
  list(SORT _expected)
  if(NOT _actual STREQUAL _expected)
    message(FATAL_ERROR "Bundled zlib source inventory drift")
  endif()
  file(READ "${source}/../zlib/zconf.h" _conf)
  string(FIND "${_conf}" "/* all linked symbols and init macros */" _begin)
  string(FIND "${_conf}" "/* all zlib typedefs in zlib.h and zconf.h */" _end)
  math(EXPR _len "${_end} - ${_begin}")
  string(SUBSTRING "${_conf}" ${_begin} ${_len} _table)
  string(REGEX MATCHALL "#[ \t]+define[ \t]+[A-Za-z_0-9]+[ \t]+z_[A-Za-z_0-9]+" _rows "${_table}")
  set(_map "")
  set(_symbols z_errmsg z_verbose z_error zmemcpy zmemcmp zmemzero)
  foreach(_row IN LISTS _rows)
    string(REGEX REPLACE "#[ \t]+define[ \t]+([A-Za-z_0-9]+)[ \t]+z_[A-Za-z_0-9]+" "\\1" _symbol "${_row}")
    list(APPEND _symbols "${_symbol}")
    if(_symbol MATCHES "^gz" OR _symbol MATCHES "^(deflateInit|deflateInit2|inflateInit|inflateInit2|inflateBackInit)$")
      continue() # aliases are defined by zlib.h; the bundle has no gzip units
    endif()
    string(APPEND _map "#define ${_symbol} ghidra_z_${_symbol}\n")
  endforeach()
  # Supplemental globals absent from zconf.h, checked by zutil.[ch] hashes.
  string(APPEND _map "#define z_errmsg ghidra_z_z_errmsg\n#define z_verbose ghidra_z_z_verbose\n#define z_error ghidra_z_z_error\n")
  set(GHIDRA_ZLIB_SOURCE "${source}/../zlib")
  set(GHIDRA_ZLIB_MAP "${_map}")
  file(MAKE_DIRECTORY "${output}")
  configure_file("${CMAKE_CURRENT_FUNCTION_LIST_DIR}/BundledZlibPrefix.h.in" "${output}/BundledZlibPrefix.h" @ONLY)
  file(WRITE "${output}/symbols.txt" "${_symbols}")
  file(READ "${source}/compression.cc" _compression)
  string(REPLACE "\r\n" "\n" _compression "${_compression}")
  string(SHA256 _compression_hash "${_compression}")
  if(NOT _compression_hash STREQUAL "654bf55f981c97347e83422fc3c387632b94d42f2185d5da6f5bc03bdc6c4027")
    message(FATAL_ERROR "Bundled zlib compression call-site inventory drift: review compression.cc")
  endif()
  set(_calls "deflateInit(&compStream, level)" "deflateEnd(&compStream)" "::deflate(&compStream, flush)"
    "inflateInit(&compStream)" "::inflate(&compStream, Z_NO_FLUSH)" "inflateEnd(&compStream)")
  set(_names deflateInit deflateEnd deflate inflateInit inflate inflateEnd)
  foreach(_i RANGE 0 5)
    list(GET _calls ${_i} _call)
    list(GET _names ${_i} _name)
    string(REPLACE "${_call}" "" _without "${_compression}")
    string(LENGTH "${_compression}" _before)
    string(LENGTH "${_without}" _after)
    string(LENGTH "${_call}" _call_size)
    math(EXPR _removed "${_before} - ${_after}")
    if(NOT _removed EQUAL _call_size)
      message(FATAL_ERROR "Bundled zlib compression call-site drift: ${_call}")
    endif()
    string(REGEX REPLACE "^(::)?${_name}" "ghidra_bundled_${_name}" _replacement "${_call}")
    # Preserve the original C++ init macros' caller version/sizeof check.
    # Computing sizeof inside the C adapter would hide incompatible packing.
    if(_name STREQUAL "deflateInit")
      set(_replacement "ghidra_bundled_deflateInit(&compStream, level, ZLIB_VERSION, (int)sizeof(z_stream))")
    elseif(_name STREQUAL "inflateInit")
      set(_replacement "ghidra_bundled_inflateInit(&compStream, ZLIB_VERSION, (int)sizeof(z_stream))")
    endif()
    string(REPLACE "${_call}" "${_replacement}" _compression "${_compression}")
  endforeach()
  string(REPLACE "#include \"compression.hh\"" "#include \"compression.hh\"\n#include \"BundledZlibAdapter.h\"" _compression "${_compression}")
  file(CONFIGURE OUTPUT "${output}/compression.cc" CONTENT "${_compression}" @ONLY)
endfunction()
