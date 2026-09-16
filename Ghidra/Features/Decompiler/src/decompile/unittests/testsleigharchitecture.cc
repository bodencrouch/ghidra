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
#include "sleigh_arch.hh"
#include "funcdata.hh"
#include "test.hh"
#include <atomic>
#include <exception>
#include <thread>

namespace ghidra {
namespace {

class TestImage : public LoadImage {
  uint1 opcode;
  uintb base;
public:
  TestImage(uint1 op,uintb addr) : LoadImage("test"), opcode(op), base(addr) {}
  virtual void loadFill(uint1 *ptr,int4 size,const Address &addr) {
    for(int4 i=0;i<size;++i)
      ptr[i] = ((addr.getOffset()+i) == base) ? opcode : 0xc3;
  }
  virtual string getArchType(void) const { return "x86:LE:64:default:gcc"; }
  virtual void adjustVma(long adjust) {}
};

class TestArchitecture : public SleighArchitecture {
  uint1 opcode;
  uintb base;
  ostringstream errors;
protected:
  virtual void buildLoader(DocumentStorage &store) {
    collectSpecFiles(*errorstream);
    loader = new TestImage(opcode,base);
  }
public:
  using AddrSpaceManager::addNoHighPtr;
  using AddrSpaceManager::setInferPtrBounds;
  using AddrSpaceManager::markNearPointers;
  using AddrSpaceManager::setReverseJustified;
  TestArchitecture(uint1 op,bool initialize=true,uintb addr=0x1000)
    : SleighArchitecture("", "x86:LE:64:default:gcc", &errors), opcode(op), base(addr) {
    if (initialize) {
      DocumentStorage store;
      init(store);
    }
  }
};

void truncateRam(AddrSpaceManager &spaces)
{
  istringstream input("<truncate_space space=\"ram\" size=\"4\"/>");
  XmlDecode decoder(&spaces);
  decoder.ingestStream(input);
  TruncationTag truncation;
  truncation.decode(decoder);
  spaces.truncateSpace(truncation);
}

class FailingArchitecture : public TestArchitecture {
protected:
  virtual void modifySpaces(Translate *trans) {
    // A failed configuration must not leave its modified translator in the cache.
    truncateRam(*trans);
    throw LowlevelError("Injected failure after translator initialization");
  }
public:
  FailingArchitecture(void) : TestArchitecture(0x90,false) {}
};

class TestAssembly : public AssemblyEmit {
public:
  string mnemonic;
  virtual void dump(const Address &addr,const string &mnem,const string &body) { mnemonic = mnem; }
};

class TestPcode : public PcodeEmit {
public:
  bool returned = false;
  virtual void dump(const Address &addr,OpCode opc,VarnodeData *outvar,VarnodeData *vars,int4 isize) {
    if (opc == CPUI_RETURN) returned = true;
  }
};

void checkInstruction(Architecture &arch,bool isReturn)
{
  Address address(arch.getDefaultCodeSpace(),0x1000);
  TestAssembly assembly;
  arch.translate->printAssembly(assembly,address);
  ASSERT_EQUALS(assembly.mnemonic,isReturn ? "RET" : "NOP");
  TestPcode pcode;
  arch.translate->oneInstruction(pcode,address);
  ASSERT_EQUALS(pcode.returned,isReturn);
}

void checkDecompilation(Architecture &arch,const string &name,uintb returnOffset,uintb entryOffset=0x1000)
{
  Address entry(arch.getDefaultCodeSpace(),entryOffset);
  Funcdata *function = arch.symboltab->getGlobalScope()->queryFunction(entry);
  if (function == (Funcdata *)0)
    function = arch.symboltab->getGlobalScope()->addFunction(entry,name)->getFunction();
  if (function->isProcStarted())
    arch.clearAnalysis(function);
  function->followFlow(entry,entry+2);
  ASSERT(function->beginOp(CPUI_RETURN) != function->endOp(CPUI_RETURN));
  ASSERT_EQUALS((*function->beginOp(CPUI_RETURN))->getAddr().getOffset(),returnOffset);
  arch.allacts.getCurrent()->reset(*function);
  ASSERT(arch.allacts.getCurrent()->perform(*function) >= 0);
  ostringstream output;
  arch.print->setOutputStream(&output);
  arch.print->docFunction(function);
  arch.print->setOutputStream(&cout);
  ASSERT(output.str().find(name) != string::npos);
}
}

TEST(sleigh_architecture_live_isolation) {
  TestArchitecture first(0x90);
  checkInstruction(first,false);
  {
    TestArchitecture second(0xc3);
    checkInstruction(second,true);
    checkInstruction(first,false);
    ASSERT(first.translate != second.translate);
  }
  checkInstruction(first,false);
}

TEST(sleigh_architecture_sequential_reuse) {
  const Translate *previous;
  {
    TestArchitecture first(0x90);
    previous = first.translate;
    checkInstruction(first,false);
  }
  TestArchitecture second(0xc3);
  ASSERT_EQUALS(previous,second.translate);
  checkInstruction(second,true);
}

TEST(sleigh_architecture_failed_initialization) {
  {
    FailingArchitecture broken;
    DocumentStorage store;
    bool failed = false;
    try {
      broken.init(store);
    }
    catch(LowlevelError &error) {
      failed = true;
    }
    ASSERT(failed);
  }
  TestArchitecture recovered(0xc3);
  ASSERT_EQUALS(recovered.getDefaultCodeSpace()->getAddrSize(),8);
  checkInstruction(recovered,true);
}

TEST(sleigh_architecture_truncated_space_reuse) {
  const Translate *previous;
  uint4 originalAddressSize,originalWordSize;
  uintb originalHighest;
  {
    TestArchitecture baseline(0x90);
    AddrSpace *space = baseline.getDefaultCodeSpace();
    previous = baseline.translate;
    originalAddressSize = space->getAddrSize();
    originalWordSize = space->getWordSize();
    originalHighest = space->getHighest();
    ASSERT_EQUALS(originalAddressSize,8);
  }
  {
    TestArchitecture truncated(0x90);
    // The 64-bit compiler specification contains ranges above 4 GB, so apply
    // program-specific truncation only after the normal configuration succeeds.
    truncateRam(truncated);
    ASSERT_EQUALS(truncated.translate,previous);
    AddrSpace *space = truncated.getDefaultCodeSpace();
    ASSERT_EQUALS(space->getAddrSize(),4);
    ASSERT_EQUALS(space->getWordSize(),1);
    ASSERT_EQUALS(space->getHighest(),(uintb)0xffffffff);
    checkInstruction(truncated,false);
  }
  TestArchitecture recovered(0xc3);
  ASSERT_EQUALS(recovered.translate,previous);
  AddrSpace *space = recovered.getDefaultCodeSpace();
  ASSERT_EQUALS(space->getAddrSize(),originalAddressSize);
  ASSERT_EQUALS(space->getWordSize(),originalWordSize);
  ASSERT_EQUALS(space->getHighest(),originalHighest);
  checkInstruction(recovered,true);
}

TEST(sleigh_architecture_context_isolation) {
  TestArchitecture first(0x40);
  TestArchitecture second(0x40);
  TestAssembly firstAssembly,secondAssembly;
  Address firstAddress(first.getDefaultCodeSpace(),0x1000);
  Address secondAddress(second.getDefaultCodeSpace(),0x1000);
  first.context->setVariable("longMode",firstAddress,1);
  second.context->setVariable("longMode",secondAddress,0);
  second.context->setVariable("opsize",secondAddress,1);
  second.context->setVariable("addrsize",secondAddress,1);
  ASSERT_EQUALS(first.translate->printAssembly(firstAssembly,firstAddress),2);
  ASSERT_EQUALS(second.translate->printAssembly(secondAssembly,secondAddress),1);
  ASSERT_EQUALS(firstAssembly.mnemonic,"RET");
  ASSERT_EQUALS(secondAssembly.mnemonic,"INC");
}

TEST(sleigh_architecture_interleaved_decompilation) {
  TestArchitecture first(0x90);
  {
    TestArchitecture second(0xc3);
    checkDecompilation(first,"first",0x1001);
    checkDecompilation(second,"second",0x1000);
    checkDecompilation(first,"first",0x1001);
  }
  checkDecompilation(first,"first",0x1001);
}

TEST(sleigh_architecture_parallel_decompilation) {
  // Construction and destruction are deliberately serialized. This exercises only
  // independent, initialized engines, not concurrent lifecycle or injection parsing.
  TestArchitecture first(0x90);
  TestArchitecture second(0xc3,true,0x2000);
  first.context->setVariable("longMode",Address(first.getDefaultCodeSpace(),0x1000),1);
  second.context->setVariable("longMode",Address(second.getDefaultCodeSpace(),0x2000),0);
  std::atomic<bool> start(false);
  std::exception_ptr failures[2];
  auto run = [&](int index) {
    while (!start.load()) std::this_thread::yield();
    try {
      for(int i=0;i<16;++i) {
        if (index == 0)
          checkDecompilation(first,"first",0x1001);
        else
          checkDecompilation(second,"second",0x2000,0x2000);
      }
    }
    catch(...) {
      failures[index] = std::current_exception();
    }
  };
  std::thread firstWorker(run,0);
  try {
    std::thread secondWorker(run,1);
    start.store(true);
    firstWorker.join();
    secondWorker.join();
  }
  catch(...) {
    start.store(true);
    if (firstWorker.joinable()) firstWorker.join();
    throw;
  }
  for(int i=0;i<2;++i)
    if (failures[i]) std::rethrow_exception(failures[i]);
}

TEST(sleigh_architecture_reuse_configuration) {
  int4 originalDelay;
  int4 originalMinimumPointerSize;
  bool originalNearPointers,originalReverseJustified;
  uintb originalLower,originalUpper;
  {
    TestArchitecture first(0x90);
    AddrSpace *space = first.getDefaultCodeSpace();
    originalDelay = space->getDeadcodeDelay();
    originalLower = space->getPointerLowerBound();
    originalUpper = space->getPointerUpperBound();
    originalMinimumPointerSize = space->getMinimumPtrSize();
    originalNearPointers = space->hasNearPointers();
    originalReverseJustified = space->isReverseJustified();
    first.setDeadcodeDelay(space,originalDelay+7);
    first.setInferPtrBounds(Range(space,0x100,0x200));
    first.addNoHighPtr(Range(space,0x1000,0x100f));
    first.markNearPointers(space,2);
    first.setReverseJustified(space);
    ASSERT(!first.translate->highPtrPossible(Address(space,0x1000),1));
  }
  TestArchitecture second(0xc3);
  AddrSpace *space = second.getDefaultCodeSpace();
  ASSERT_EQUALS(space->getDeadcodeDelay(),originalDelay);
  ASSERT_EQUALS(space->getPointerLowerBound(),originalLower);
  ASSERT_EQUALS(space->getPointerUpperBound(),originalUpper);
  ASSERT_EQUALS(space->getMinimumPtrSize(),originalMinimumPointerSize);
  ASSERT_EQUALS(space->hasNearPointers(),originalNearPointers);
  ASSERT_EQUALS(space->isReverseJustified(),originalReverseJustified);
  // Add a distinct range to expose a stale manager range even when flags were reset.
  second.addNoHighPtr(Range(space,0x2000,0x200f));
  ASSERT(second.translate->highPtrPossible(Address(space,0x1000),1));
  ASSERT(!second.translate->highPtrPossible(Address(space,0x2000),1));
}

} // End namespace ghidra
