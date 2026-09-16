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
#include "xml.hh"
#include "test.hh"
#include <atomic>
#include <thread>

namespace ghidra {

using std::istringstream;

class NestedXmlHandler : public TreeHandler {
public:
  explicit NestedXmlHandler(Element *root) : TreeHandler(root) {}
  virtual void startElement(const string &uri,const string &local,const string &name,
                            const Attributes &attrs) {
    istringstream inner("<inner>independent</inner>");
    DocumentStorage store;
    Document *doc = store.parseDocument(inner);
    ASSERT_EQUALS(doc->getRoot()->getContent(), "independent");
    TreeHandler::startElement(uri,local,name,attrs);
  }
};

TEST(xml_parse_nested) {
  Document outer;
  NestedXmlHandler handler(&outer);
  istringstream input("<outer><child>retained &amp; correct</child></outer>");
  ASSERT_EQUALS(xml_parse(input,&handler), 0);
  ASSERT_EQUALS(outer.getRoot()->getName(), "outer");
  ASSERT_EQUALS(outer.getRoot()->getChildren().at(0)->getContent(), "retained & correct");
}

TEST(xml_parse_parallel) {
  std::atomic<bool> start(false);
  std::atomic<int> failures(0);
  vector<std::thread> workers;
  for (int i=0;i<4;++i) {
    workers.emplace_back([i,&start,&failures]() {
      while (!start.load()) std::this_thread::yield();
      for (int j=0;j<100;++j) {
        try {
          string expected = std::to_string(i) + ":" + std::to_string(j);
          istringstream input("<root><value>" + expected + "</value></root>");
          DocumentStorage store;
          Document *doc = store.parseDocument(input);
          if (doc->getRoot()->getChildren().at(0)->getContent() != expected)
            ++failures;
        }
        catch (...) {
          ++failures;
        }
      }
    });
  }
  start.store(true);
  for (std::thread &worker : workers) worker.join();
  ASSERT_EQUALS(failures.load(), 0);
}

TEST(xml_parse_error_then_success) {
  DocumentStorage store;
  istringstream invalid("<outer><child></outer>");
  bool rejected = false;
  try { store.parseDocument(invalid); }
  catch (const DecoderError &) { rejected = true; }
  ASSERT(rejected);
  istringstream valid("<root>after error</root>");
  ASSERT_EQUALS(store.parseDocument(valid)->getRoot()->getContent(), "after error");
}

} // End namespace ghidra
