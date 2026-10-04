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
/* C deliberately isolates an external zlib header from Ghidra's C++ types. */
#include <zlib.h>
#include <string.h>
#include <stdio.h>
int external_gzip_roundtrip(const char *path) {
  const char input[] = "independent external static gzip stream\n";
  char output[sizeof(input) + 1];
  gzFile file = gzopen(path, "wb");
  int size, closed;
  if (!file) return 1;
  size = gzwrite(file, input, sizeof(input));
  closed = gzclose(file);
  if (size != sizeof(input) || closed != Z_OK) return 2;
  file = gzopen(path, "rb");
  if (!file) return 3;
  size = gzread(file, output, sizeof(output));
  closed = gzclose(file);
  if (size != sizeof(input) || closed != Z_OK || memcmp(input, output, sizeof(input))) return 4;
  if (remove(path)) return 5;
  puts("external static gzip roundtrip passed");
  return 0;
}
