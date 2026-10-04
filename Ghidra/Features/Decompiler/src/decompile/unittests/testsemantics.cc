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
#include "semantics.hh"
#include "test.hh"

namespace ghidra {

TEST(semantics_consttpl_selector_initialized) {
  ConstTpl defaultValue;
  ConstTpl defaultCopy(defaultValue);
  ASSERT(defaultCopy.getSelect() == ConstTpl::v_space);

  ConstTpl contextValue(ConstTpl::j_start);
  ConstTpl contextCopy(contextValue);
  ASSERT(contextCopy.getSelect() == ConstTpl::v_space);

  ConstTpl spaceValue((AddrSpace *)0);
  ConstTpl spaceCopy(spaceValue);
  ASSERT(spaceCopy.getSelect() == ConstTpl::v_space);
}

} // End namespace ghidra
