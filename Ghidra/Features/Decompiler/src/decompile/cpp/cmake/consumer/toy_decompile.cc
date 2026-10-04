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
/* Installed-header consumer: one architecture in one process. */
#include "libdecomp.hh"
#include "funcdata.hh"
#include "printlanguage.hh"
#include <memory>
#include <sstream>
#include <iostream>
#include <string>
#ifdef GHIDRA_TEST_GZIP
extern "C" int external_gzip_roundtrip(const char *path);
#endif

int main(int argc, char **argv) {
  using namespace ghidra;
  if (argc != 3) return 2;
  const char *toy = "Toy:BE:32:builder.align2:default";
  std::ostringstream diagnostics;
  try {
#ifdef GHIDRA_TEST_GZIP
    if (external_gzip_roundtrip("external-roundtrip.gz") != 0)
      throw std::runtime_error("external static gzip roundtrip failed");
#endif
    startDecompilerLibrary(argv[1]);
    auto *cap = ArchitectureCapability::getCapability("xml");
    if (!cap) throw std::runtime_error("xml capability missing");
    DocumentStorage docs;
    std::unique_ptr<Architecture> arch(cap->buildArchitecture(argv[2], toy, &diagnostics));
    arch->init(docs);
    arch->readLoaderSymbols();
    auto *fd = arch->symboltab->getGlobalScope()->queryFunction("skipinst");
    if (!fd || fd->hasNoCode() || fd->getAddress().getOffset() != 0x10)
      throw std::runtime_error("Toy fixture function not loaded");
    auto *action = arch->allacts.getCurrent();
    if (!action) throw std::runtime_error("no decompiler root action");
    action->reset(*fd);
    if (action->perform(*fd) < 0 || !fd->isProcComplete())
      throw std::runtime_error("decompilation did not finish");
    std::ostringstream c;
    arch->print->setOutputStream(&c);
    arch->print->docFunction(fd);
    const std::string output = c.str();
    if (output.find("if (param_1 != 5)") == std::string::npos ||
        output.find("iVar1 = param_2 + 10;") == std::string::npos)
      throw std::runtime_error("Toy C output lacks skip/arithmetic behavior: " + output);
    std::cout << output;
    arch.reset();
    shutdownDecompilerLibrary();
    return 0;
  } catch (const DecoderError &error) {
    diagnostics << error.explain;
  } catch (const LowlevelError &error) {
    diagnostics << error.explain;
  } catch (const std::exception &error) {
    diagnostics << error.what();
  }
  std::cerr << "Installed Toy decompilation failed: " << argv[1] << " " << toy
            << " " << argv[2] << "\n" << diagnostics.str() << std::endl;
  return 1;
}
