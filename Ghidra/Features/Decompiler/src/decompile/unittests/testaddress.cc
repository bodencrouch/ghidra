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
#include "test.hh"
#include "address.hh"
#include <limits>

namespace ghidra {

// Build the signed value one bit at a time.  Every intermediate is representable,
// including the final negative value when the sign bit is the full-width bit.
static intb referenceSignExtend(intb value,int4 bit)

{
  intb result = (((uintb)value >> bit) & 1) != 0 ? -1 : 0;
  for(int4 i=bit-1;i>=0;--i)
    result = result * 2 + (intb)(((uintb)value >> i) & 1);
  return result;
}

TEST(address_sign_extend) {
  ASSERT_EQUALS(sign_extend((intb)197,3),(intb)5);
  ASSERT_EQUALS(sign_extend((intb)197,2),(intb)-3);
  const intb values[] = { 0, 1, -1, 197, -197,
    std::numeric_limits<intb>::min(), std::numeric_limits<intb>::max(),
    std::numeric_limits<intb>::min() + 1, std::numeric_limits<intb>::max() - 1 };
  for(int4 bit=0;bit<8*sizeof(intb);++bit) {
    for(int4 i=0;i<sizeof(values)/sizeof(values[0]);++i)
      ASSERT_EQUALS(sign_extend(values[i],bit),referenceSignExtend(values[i],bit));
    uintb sign = (uintb)1 << bit;
    intb boundary = (intb)(sign - 1);
    ASSERT_EQUALS(sign_extend(boundary,bit),boundary);
    ASSERT_EQUALS(sign_extend(-1 - boundary,bit),-1 - boundary);
  }
  uintb pattern = 0x9e3779b97f4a7c15ULL;
  for(int4 sample=0;sample<1024;++sample) {
    pattern ^= pattern << 13;
    pattern ^= pattern >> 7;
    pattern ^= pattern << 17;
    // Each cast fits intb; the low bit chooses the sign without an out-of-range
    // unsigned-to-signed conversion, and all full-width bit patterns are possible.
    intb value = (intb)(pattern >> 1);
    if ((pattern & 1) != 0)
      value = -1 - value;
    for(int4 bit=0;bit<8*sizeof(intb);++bit)
      ASSERT_EQUALS(sign_extend(value,bit),referenceSignExtend(value,bit));
  }
}

} // End namespace ghidra
