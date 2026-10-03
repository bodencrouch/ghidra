/* ###
 * IP: GHIDRA
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
#ifdef GHIDRA_TEST_PACKED
#pragma pack(push, 1)
#endif
#include "zlib.h"
#ifdef GHIDRA_TEST_PACKED
#pragma pack(pop)
#endif
#include "BundledZlibAdapter.h"
#include <cstring>
#include <iostream>

int main() {
  z_stream stream = {};
  unsigned char before[sizeof(stream)];
  std::memcpy(before, &stream, sizeof(stream));
  if (ghidra_bundled_deflateInit(&stream, 1, "invalid", sizeof(stream)) != Z_VERSION_ERROR ||
      ghidra_bundled_inflateInit(&stream, "invalid", sizeof(stream)) != Z_VERSION_ERROR ||
      ghidra_bundled_deflateInit(&stream, 1, ZLIB_VERSION, -1) != Z_VERSION_ERROR ||
      ghidra_bundled_inflateInit(&stream, ZLIB_VERSION, -1) != Z_VERSION_ERROR ||
      std::memcmp(before, &stream, sizeof(stream))) return 1;
#ifdef GHIDRA_TEST_PACKED
  // Deliberately incompatible caller: zlib must reject before touching it.
  if (ghidra_bundled_deflateInit(&stream, 1, ZLIB_VERSION, sizeof(stream)) != Z_VERSION_ERROR ||
      ghidra_bundled_inflateInit(&stream, ZLIB_VERSION, sizeof(stream)) != Z_VERSION_ERROR ||
      std::memcmp(before, &stream, sizeof(stream))) return 2;
  std::cout << "Packed caller rejected unchanged, sizeof(z_stream)=" << sizeof(stream) << '\n';
#else
  if (ghidra_bundled_deflateInit(&stream, 1, ZLIB_VERSION, sizeof(stream)) != Z_OK ||
      ghidra_bundled_deflateEnd(&stream) != Z_OK) return 3;
  stream = z_stream{};
  if (ghidra_bundled_inflateInit(&stream, ZLIB_VERSION, sizeof(stream)) != Z_OK ||
      ghidra_bundled_inflateEnd(&stream) != Z_OK) return 4;
  std::cout << "Normal caller initialized, sizeof(z_stream)=" << sizeof(stream) << '\n';
#endif
  return 0;
}
