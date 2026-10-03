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
// Smoke test for the sla library: disassemble and translate a few fixed
// instructions with a compiled .sla file, print one deterministic text block
// and optionally compare it with an expected file.
//
//   sleigh_smoke <sleigh-home> <case> [--expect <file> [--spec-fingerprint <sha256>]]
//   sleigh_smoke <sleigh-home> <case> --record <sha256>
//   sleigh_smoke --self-test
//
// <sleigh-home> is the root that holds Ghidra/Processors/<P>/data/languages.
// <case> is one of: x86-64, arm-thumb, aarch64.
//
// Output format, one instruction per block:
//
//   <hex address> <mnemonic> <operands>
//     [<out>] = <opcode> <in>...     one line per p-code op, where a varnode
//                                    prints as <space>[<hex offset>:<size>]
//
// With --expect, the output must equal the file exactly, or differ only in
// where temporaries are allocated: groups of overlapping unique-space
// varnodes are renamed by first use, keeping each one's offset within its
// group and its size (see canonicalTemporaries).  --self-test checks that
// this renaming accepts moved temporaries and rejects any other change.
//
// An expected file starts with "# specification sources sha256: <hash>",
// the fingerprint of the .slaspec/.sinc files it was recorded from (--record
// writes it).  When the output differs and --spec-fingerprint names other
// sources, the expectation does not apply to them: the program says so and
// exits 77, which the test registers as skipped.  When the sources are the
// same, any difference is a failure.
//
// The program mirrors sleighexample.cc: an in-memory LoadImage, a
// ContextInternal, a Sleigh translator initialized from a DocumentStorage,
// and AssemblyEmit/PcodeEmit subclasses.  It only uses the sla archive.

#include "loadimage.hh"
#include "sleigh.hh"

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iostream>
#include <map>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace {

using namespace ghidra;
using std::cerr;
using std::cout;
using std::map;
using std::pair;
using std::make_pair;
using std::sort;
using std::unique;
using std::strtoull;

struct ContextSetting {
  const char *name;
  uintm value;
};

struct SmokeCase {
  const char *name;
  const char *slafile;		// Relative to the sleigh home
  uintb base;			// Load address of the bytes
  const uint1 *bytes;
  int4 length;
  const ContextSetting *context;
  int4 numContext;
};

// push rbp; mov rbp,rsp; mov [rbp-4],edi; mov eax,[rbp-4]; add eax,1; pop rbp; ret
const uint1 x86_64_bytes[] = {
  0x55, 0x48, 0x89, 0xe5, 0x89, 0x7d, 0xfc, 0x8b, 0x45, 0xfc, 0x83, 0xc0, 0x01, 0x5d, 0xc3
};
// x86-64.pspec context_data defaults
const ContextSetting x86_64_context[] = {
  { "addrsize", 2 }, { "opsize", 1 }, { "rexprefix", 0 }, { "longMode", 1 }
};

// push {r4,r5,r6,lr}; adds r0,#1; pop {r4,r5,r6,pc}
const uint1 arm_thumb_bytes[] = { 0x70, 0xb5, 0x01, 0x30, 0x70, 0xbd };
const ContextSetting arm_thumb_context[] = { { "TMode", 1 }, { "LRset", 0 } };

// stp x29,x30,[sp,#-16]!; mov x29,sp; add x0,x0,#1; ldp x29,x30,[sp],#16; ret
const uint1 aarch64_bytes[] = {
  0xfd, 0x7b, 0xbf, 0xa9, 0xfd, 0x03, 0x00, 0x91, 0x00, 0x04, 0x00, 0x91,
  0xfd, 0x7b, 0xc1, 0xa8, 0xc0, 0x03, 0x5f, 0xd6
};

const SmokeCase cases[] = {
  { "x86-64", "Ghidra/Processors/x86/data/languages/x86-64.sla", 0x401000,
    x86_64_bytes, sizeof(x86_64_bytes), x86_64_context, 4 },
  { "arm-thumb", "Ghidra/Processors/ARM/data/languages/ARM8_le.sla", 0x8000,
    arm_thumb_bytes, sizeof(arm_thumb_bytes), arm_thumb_context, 2 },
  { "aarch64", "Ghidra/Processors/AARCH64/data/languages/AARCH64.sla", 0x400000,
    aarch64_bytes, sizeof(aarch64_bytes), (const ContextSetting *)0, 0 },
};

const int4 numCases = sizeof(cases) / sizeof(cases[0]);

/// Bytes held in memory; anything outside the window reads as zero.
class MemoryLoadImage : public LoadImage {
  uintb baseaddr;
  int4 length;
  const uint1 *data;
public:
  MemoryLoadImage(uintb ad,const uint1 *ptr,int4 sz) : LoadImage("nofile") { baseaddr = ad; data = ptr; length = sz; }
  virtual void loadFill(uint1 *ptr,int4 size,const Address &addr);
  virtual string getArchType(void) const { return "memory"; }
  virtual void adjustVma(long adjust) { }
};

void MemoryLoadImage::loadFill(uint1 *ptr,int4 size,const Address &addr)

{
  uintb start = addr.getOffset();
  uintb max = baseaddr + (length - 1);
  for(int4 i=0;i<size;++i) {
    uintb curoff = start + i;
    if ((curoff < baseaddr) || (curoff > max)) {
      ptr[i] = 0;
      continue;
    }
    ptr[i] = data[(int4)(curoff - baseaddr)];
  }
}

class AssemblyPrinter : public AssemblyEmit {
  ostream &s;
public:
  AssemblyPrinter(ostream &str) : s(str) {}
  virtual void dump(const Address &addr,const string &mnem,const string &body) {
    s << "0x" << hex << addr.getOffset() << ' ' << mnem;
    if (!body.empty())
      s << ' ' << body;
    s << '\n';
  }
};

class PcodePrinter : public PcodeEmit {
  ostream &s;
  const AddrSpace *defaultCodeSpace;
  void printVarnode(const VarnodeData &data) {
    // LOAD and STORE encode their address space as the host pointer to an
    // AddrSpace in a constant varnode.  That pointer is intentionally not
    // stable across processes, so render the semantic space name instead.
    if (data.space->getType() == IPTR_CONSTANT &&
        data.offset == reinterpret_cast<uintb>(defaultCodeSpace)) {
      s << "spaceid[" << defaultCodeSpace->getName() << ']';
      return;
    }
    s << data.space->getName() << "[0x" << hex << data.offset << ':' << dec << data.size << ']';
  }
public:
  PcodePrinter(ostream &str,const AddrSpace *codeSpace) : s(str), defaultCodeSpace(codeSpace) {}
  virtual void dump(const Address &addr,OpCode opc,VarnodeData *outvar,VarnodeData *vars,int4 isize) {
    s << "  ";
    if (outvar != (VarnodeData *)0) {
      printVarnode(*outvar);
      s << " = ";
    }
    s << get_opname(opc);
    for(int4 i=0;i<isize;++i) {
      s << ' ';
      printVarnode(vars[i]);
    }
    s << '\n';
  }
};

const SmokeCase *findCase(const string &name)

{
  for(int4 i=0;i<numCases;++i) {
    if (name == cases[i].name)
      return &cases[i];
  }
  return (const SmokeCase *)0;
}

void runCase(const string &sleighhome,const SmokeCase &sc,ostream &out)

{
  MemoryLoadImage loader(sc.base,sc.bytes,sc.length);
  ContextInternal context;
  Sleigh trans(&loader,&context);

  string path = sleighhome;
  if (path.empty() || path[path.size()-1] != '/')
    path += '/';
  path += sc.slafile;
  DocumentStorage docstorage;
#ifdef GHIDRA_DECOMP_XML_SLA
  // Before Ghidra 11.1 a .sla file is an XML document.
  Element *sleighroot = docstorage.openDocument(path)->getRoot();
#else
  // From Ghidra 11.1 on, a <sleigh> element names the compressed .sla file.
  string escaped;
  for(string::size_type i=0;i<path.size();++i) {
    switch(path[i]) {
    case '&': escaped += "&amp;"; break;
    case '<': escaped += "&lt;"; break;
    case '>': escaped += "&gt;"; break;
    default: escaped += path[i]; break;
    }
  }
  istringstream sleighdoc("<sleigh>" + escaped + "</sleigh>");
  Element *sleighroot = docstorage.parseDocument(sleighdoc)->getRoot();
#endif
  docstorage.registerTag(sleighroot);
  trans.initialize(docstorage);

  for(int4 i=0;i<sc.numContext;++i)
    context.setVariableDefault(sc.context[i].name,sc.context[i].value);

  AssemblyPrinter asmemit(out);
  PcodePrinter pcodeemit(out,trans.getDefaultCodeSpace());
  Address addr(trans.getDefaultCodeSpace(),sc.base);
  Address lastaddr(trans.getDefaultCodeSpace(),sc.base + sc.length);
  while(addr < lastaddr) {
    trans.printAssembly(asmemit,addr);
    int4 length = trans.oneInstruction(pcodeemit,addr);
    addr = addr + length;
  }
}

/// Where the temporaries (unique space) sit is an allocation detail of a
/// processor specification and changes between Ghidra releases.  Rename
/// each group of overlapping temporaries to T<n>, numbered by first use, and
/// keep each varnode's offset within its group and its size.  Identity,
/// size and every overlap relationship between temporaries are preserved;
/// only the absolute offsets are dropped.
string canonicalTemporaries(const string &text)

{
  static const string prefix = "unique[0x";
  struct Use { string::size_type begin, end; unsigned long long offset, size; string sizetext; };
  vector<Use> uses;
  string::size_type pos = 0;
  while((pos = text.find(prefix,pos)) != string::npos) {
    string::size_type colon = text.find(':',pos);
    string::size_type close = text.find(']',pos);
    if (colon == string::npos || close == string::npos || colon > close) {
      pos += prefix.size();
      continue;
    }
    Use use;
    use.begin = pos;
    use.end = close + 1;
    use.offset = strtoull(text.substr(pos + prefix.size(),colon - pos - prefix.size()).c_str(),(char **)0,16);
    use.sizetext = text.substr(colon + 1,close - colon - 1);
    string sizehex = use.sizetext;
    if (sizehex.compare(0,2,"0x") == 0)
      sizehex = sizehex.substr(2);
    use.size = strtoull(sizehex.c_str(),(char **)0,16);
    uses.push_back(use);
    pos = use.end;
  }
  // Group the distinct ranges by overlap.
  vector<pair<unsigned long long,unsigned long long> > ranges;
  for(size_t i=0;i<uses.size();++i)
    ranges.push_back(make_pair(uses[i].offset,uses[i].offset + uses[i].size));
  sort(ranges.begin(),ranges.end());
  ranges.erase(unique(ranges.begin(),ranges.end()),ranges.end());
  map<pair<unsigned long long,unsigned long long>,pair<int,unsigned long long> > group;	// range -> (group, group base)
  int numgroups = -1;
  unsigned long long base = 0, end = 0;
  for(size_t i=0;i<ranges.size();++i) {
    if (numgroups < 0 || ranges[i].first >= end) {
      numgroups += 1;
      base = ranges[i].first;
      end = ranges[i].second;
    }
    else if (ranges[i].second > end)
      end = ranges[i].second;
    group[ranges[i]] = make_pair(numgroups,base);
  }
  // Number the groups by first use and rewrite.
  map<int,int> order;
  string result;
  string::size_type copied = 0;
  for(size_t i=0;i<uses.size();++i) {
    pair<int,unsigned long long> g = group[make_pair(uses[i].offset,uses[i].offset + uses[i].size)];
    if (order.find(g.first) == order.end()) {
      int next = (int)order.size();
      order[g.first] = next;
    }
    ostringstream s;
    s << "unique[T" << dec << order[g.first] << "+0x" << hex << (uses[i].offset - g.second) << ':' << uses[i].sizetext << ']';
    result += text.substr(copied,uses[i].begin - copied);
    result += s.str();
    copied = uses[i].end;
  }
  result += text.substr(copied);
  return result;
}

int judge(const string &produced,const string &expectedtext,const string &fingerprint,
	  const string &label,bool quiet);

/// The renaming must accept a pure move of the temporaries and reject any
/// change to their identity, size or overlaps; the result must be skipped
/// only when the output differs and the specification sources differ.
int selfTest(void)

{
  struct Check { const char *name; const char *a; const char *b; bool same; };
  static const Check checks[] = {
    { "moved temporaries are accepted",
      "unique[0x100:8] = COPY r\nunique[0x104:4] = COPY unique[0x100:8]\nunique[0x400:1] = COPY unique[0x104:4]\n",
      "unique[0x9100:8] = COPY r\nunique[0x9104:4] = COPY unique[0x9100:8]\nunique[0x20:1] = COPY unique[0x9104:4]\n", true },
    { "a removed overlap is rejected",
      "unique[0x100:8] = COPY r\nunique[0x104:4] = COPY r\n",
      "unique[0x100:8] = COPY r\nunique[0x300:4] = COPY r\n", false },
    { "a new overlap is rejected",
      "unique[0x100:4] = COPY r\nunique[0x200:4] = COPY r\n",
      "unique[0x100:4] = COPY r\nunique[0x102:4] = COPY r\n", false },
    { "a moved partial overlap is rejected",
      "unique[0x100:8] = COPY r\nunique[0x104:4] = COPY r\n",
      "unique[0x100:8] = COPY r\nunique[0x102:4] = COPY r\n", false },
    { "a changed size is rejected",
      "unique[0x100:8] = COPY r\n",
      "unique[0x100:4] = COPY r\n", false },
    { "split identity is rejected",
      "unique[0x100:4] = COPY r\nr = COPY unique[0x100:4]\n",
      "unique[0x100:4] = COPY r\nr = COPY unique[0x200:4]\n", false },
    { "other spaces are compared exactly",
      "register[0x20:8] = COPY unique[0x100:8]\n",
      "register[0x28:8] = COPY unique[0x100:8]\n", false },
  };
  int failures = 0;
  for(size_t i=0;i<sizeof(checks)/sizeof(checks[0]);++i) {
    bool same = (canonicalTemporaries(checks[i].a) == canonicalTemporaries(checks[i].b));
    bool ok = (same == checks[i].same);
    cerr << (ok ? "ok: " : "FAILED: ") << checks[i].name << endl;
    if (!ok)
      failures += 1;
  }
  struct Decision { const char *name; const char *produced; const char *expected; const char *fingerprint; int result; };
  static const Decision decisions[] = {
    { "a match passes on the recorded sources", "a\n", "# specification sources sha256: AA\na\n", "AA", 0 },
    { "a match passes on other sources", "a\n", "# specification sources sha256: AA\na\n", "BB", 0 },
    { "a difference fails on the recorded sources", "b\n", "# specification sources sha256: AA\na\n", "AA", 1 },
    { "a difference is skipped on other sources", "b\n", "# specification sources sha256: AA\na\n", "BB", 77 },
    { "a difference fails without a recorded fingerprint", "b\n", "a\n", "BB", 1 },
    { "a difference fails without a given fingerprint", "b\n", "# specification sources sha256: AA\na\n", "", 1 },
  };
  for(size_t i=0;i<sizeof(decisions)/sizeof(decisions[0]);++i) {
    int result = judge(decisions[i].produced,decisions[i].expected,decisions[i].fingerprint,"self-test",true);
    bool ok = (result == decisions[i].result);
    cerr << (ok ? "ok: " : "FAILED: ") << decisions[i].name << endl;
    if (!ok)
      failures += 1;
  }
  return failures == 0 ? 0 : 1;
}

/// Print the first line where two texts differ.
void reportFirstDifference(const string &produced,const string &expected)

{
  istringstream a(produced);
  istringstream b(expected);
  string la,lb;
  int4 lineno = 0;
  while(true) {
    bool ha = static_cast<bool>(getline(a,la));
    bool hb = static_cast<bool>(getline(b,lb));
    lineno += 1;
    if (!ha && !hb) break;
    if (ha != hb || la != lb) {
      cerr << "line " << dec << lineno << ":" << endl;
      cerr << "  produced: " << (ha ? la : string("<end>")) << endl;
      cerr << "  expected: " << (hb ? lb : string("<end>")) << endl;
      break;
    }
  }
}

/// Split an expected file into its "# ..." header and the expected output.
string stripHeader(const string &text,string &recorded)

{
  static const string key = "# specification sources sha256: ";
  recorded.clear();
  string::size_type pos = 0;
  while(pos < text.size() && text[pos] == '#') {
    string::size_type eol = text.find('\n',pos);
    string line = text.substr(pos,(eol == string::npos) ? string::npos : eol - pos);
    if (line.compare(0,key.size(),key) == 0)
      recorded = line.substr(key.size());
    pos = (eol == string::npos) ? text.size() : eol + 1;
  }
  return text.substr(pos);
}

/// 0: matches, 1: differs, 77: differs and the expectation was recorded
/// from other specification sources, so it does not apply.
int judge(const string &produced,const string &expectedtext,const string &fingerprint,
	  const string &label,bool quiet)

{
  string recorded;
  string expected = stripHeader(expectedtext,recorded);
  if (expected == produced) {
    if (!quiet) cerr << label << ": output matches" << endl;
    return 0;
  }
  string canonproduced = canonicalTemporaries(produced);
  string canonexpected = canonicalTemporaries(expected);
  if (canonproduced == canonexpected) {
    if (!quiet) cerr << label << ": output matches except for where temporaries are allocated" << endl;
    return 0;
  }
  if (!recorded.empty() && !fingerprint.empty() && recorded != fingerprint) {
    if (!quiet) {
      cerr << label << ": output differs, and these specification sources (sha256 " << fingerprint
	   << ") are not the ones the expected output was recorded from (sha256 " << recorded
	   << "), so the expectation does not apply.  Review the output before recording it again." << endl;
      reportFirstDifference(canonproduced,canonexpected);
    }
    return 77;
  }
  if (!quiet) {
    cerr << label << ": output differs" << endl;
    cerr << "with temporaries renamed by overlapping group:" << endl;
    reportFirstDifference(canonproduced,canonexpected);
  }
  return 1;
}

int usage(const char *prog)

{
  cerr << "USAGE: " << prog << " <sleigh-home> <case> [--expect <file> [--spec-fingerprint <sha256>]]" << endl;
  cerr << "       " << prog << " <sleigh-home> <case> --record <sha256>" << endl;
  cerr << "       " << prog << " --self-test" << endl;
  cerr << "cases:";
  for(int4 i=0;i<numCases;++i)
    cerr << ' ' << cases[i].name;
  cerr << endl;
  return 2;
}

} // End anonymous namespace

int main(int argc,char **argv)

{
  using namespace ghidra;
  using std::cerr;
  using std::cout;

  if (argc == 2 && strcmp(argv[1],"--self-test") == 0)
    return selfTest();
  if (argc < 3 || (argc % 2) == 0)
    return usage(argv[0]);
  string sleighhome(argv[1]);
  string casename(argv[2]);
  string expectfile,fingerprint,recordfingerprint;
  for(int i=3;i+1<argc;i+=2) {
    if (strcmp(argv[i],"--expect") == 0)
      expectfile = argv[i+1];
    else if (strcmp(argv[i],"--spec-fingerprint") == 0)
      fingerprint = argv[i+1];
    else if (strcmp(argv[i],"--record") == 0)
      recordfingerprint = argv[i+1];
    else
      return usage(argv[0]);
  }
  const SmokeCase *sc = findCase(casename);
  if (sc == (const SmokeCase *)0) {
    cerr << "unknown case: " << casename << endl;
    return usage(argv[0]);
  }

  AttributeId::initialize();
  ElementId::initialize();

  ostringstream out;
  try {
    runCase(sleighhome,*sc,out);
  } catch(LowlevelError &err) {
    cerr << "error: " << err.explain << endl;
    return 1;
  }
  string produced = out.str();
  if (!recordfingerprint.empty())
    cout << "# specification sources sha256: " << recordfingerprint << '\n';
  cout << produced;
  cout.flush();

  if (expectfile.empty())
    return 0;

  ifstream in(expectfile.c_str());
  if (!in) {
    cerr << "cannot open expected file: " << expectfile << endl;
    return 1;
  }
  ostringstream expected;
  expected << in.rdbuf();
  return judge(produced,expected.str(),fingerprint,casename + " vs " + expectfile,false);
}
