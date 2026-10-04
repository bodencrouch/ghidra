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
/* Private typed declarations; include after the unchanged bundled zlib.h. */
#ifdef __cplusplus
extern "C" {
#endif
int ghidra_bundled_deflateInit(z_streamp stream, int level, const char *version, int stream_size);
int ghidra_bundled_deflateEnd(z_streamp stream);
int ghidra_bundled_deflate(z_streamp stream, int flush);
int ghidra_bundled_inflateInit(z_streamp stream, const char *version, int stream_size);
int ghidra_bundled_inflate(z_streamp stream, int flush);
int ghidra_bundled_inflateEnd(z_streamp stream);
#ifdef __cplusplus
}
#endif
