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
#include "analyzesigs.hh"
#include <iostream>
#include <sstream>
#include <stdexcept>

// An installed consumer uses the actual singleton registry and command parser.
class SignatureConsole : public ghidra::IfaceStatus {
  std::string next;
  void readLine(std::string &line) override { line = next; }
public:
  explicit SignatureConsole(std::ostream &output) : IfaceStatus("", output) {}
  bool isStreamFinished(void) const override { return false; }
  bool hasCommand(const std::string &name) const {
    for (const auto *command : comlist) {
      std::string words;
      command->commandString(words);
      if (words == name) return true;
    }
    return false;
  }
  bool run(const std::string &line) { next = line; return runCommand(); }
};

int main() {
  try {
    ghidra::AttributeId::initialize();
    ghidra::ElementId::initialize();
    ghidra::CapabilityPoint::initializeAll();
    std::ostringstream output;
    SignatureConsole console(output);
    ghidra::IfaceCapability::registerAllCommands(&console);
    for (const char *command : {"signature settings", "print signatures",
        "save signatures", "saveall signatures", "produce signatures"}) {
      if (!console.hasCommand(command))
        throw std::runtime_error(std::string("missing signature command: ") + command);
    }
    if (console.hasCommand("codedata init"))
      throw std::runtime_error("unexpected BFD-dependent codedata command");
    if (!console.run("signature settings 1") || ghidra::SigManager::getSettings() != 1 ||
        output.str().find("Signature settings set to 1") == std::string::npos)
      throw std::runtime_error("registered signature settings command did not execute");
    // Direct construction also requires the signature implementation's vtable.
    ghidra::IfcSignatureSettings direct;
    direct.setData(&console, console.getData("decompile"));
    std::istringstream settings("2");
    direct.execute(settings);
    if (ghidra::SigManager::getSettings() != 2)
      throw std::runtime_error("direct signature API did not execute");
    std::cout << "installed signature registry and API: ok\n";
    return 0;
  } catch (const std::exception &error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
