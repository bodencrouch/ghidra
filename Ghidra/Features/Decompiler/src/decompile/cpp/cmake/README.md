# Standalone CMake build of the decompiler

This directory adds a CMake build for the native decompiler and SLEIGH code.
It does not change the Gradle build and it does not modify any source file.
It exists so the native code can be built, tested and linked from other
programs without a JVM, Gradle or Java on the machine.

## Relationship to existing Ghidra usage

This is an optional build path. Existing Gradle and Makefile commands, the
Java decompiler APIs, native process protocol, scripts, project formats, and
processor specifications retain their existing implementations. The standalone
console is not a replacement for the `decompile` executable used by Ghidra.

Ghidra already supports repeated decompilations through a persistent
`DecompInterface` and pools interfaces through `DecompilerCallback` and
`ParallelDecompiler`. Multiple native workers can share one JVM host. This
build does not change that scheduling or demonstrate a performance improvement.

The motivation overlaps with [the standalone SLEIGH library proposal
(#3652)](https://github.com/NationalSecurityAgency/ghidra/issues/3652) and the
existing [lifting-bits/sleigh CMake build](https://github.com/lifting-bits/sleigh):
let native consumers reuse Ghidra's engine without maintaining their own source
lists and build integration. Here the build lives beside the sources and checks
its source manifest against the Makefile. It does not introduce a stable C++
ABI across Ghidra releases; consumers must use matching headers, libraries,
specifications, and build definitions.

The existing Java reuse/pooling route is also the accepted answer to
[discussion #2903](https://github.com/NationalSecurityAgency/ghidra/discussions/2903).
[Issue #2171](https://github.com/NationalSecurityAgency/ghidra/issues/2171)
describes batch headless export, which still belongs to the application and
script layer. This patch adds neither import orchestration nor scheduling.
Standalone CMake SLEIGH builds already exist in lifting-bits/sleigh; this
integration supplies an in-tree source manifest and the decompiler archive.
These references provide motivation, not upstream endorsement.

The manifest has been checked at source base `263160cf57db` and official-master
snapshot `a462673d2f15`, both reporting 12.3 DEV. The latter adds
`metatype.cc`; the manifest recognizes this concrete addition and still
rejects other source-list drift by default. Upstream changes to public native
signatures, metatype serialization, and compiler-spec formats between these
revisions are source-version boundaries. Matching source
lists do not establish cross-version ABI or format compatibility, and unknown
future revisions remain unproven.

The CMake build produces:

- `libsla.a`: SLEIGH only (disassembly, p-code translation, emulation).
  Same members as `LIBSLA_NAMES` in the `Makefile`.
- `libdecomp_archive.a`: the decompiler with SLEIGH. Same members as
  `LIBDECOMP_NAMES` in the `Makefile`, except for the libbfd loader.
- `ghidra::decomp`: an interface target that links `libdecomp_archive.a`
  whole. The architecture and language capabilities (`xml`, `raw`,
  `c-language`, `java-language`) register themselves from static
  initializers; a normal archive link drops them.
- `sleigh_compiler`: the SLEIGH compiler (`slgh_compile.cc`).
- `decomp_console`: the interactive `consolemain.cc` front end linked to the
  standalone archive. Unlike the Makefile's `decomp_dbg`/`decomp_opt`, it does
  not include the libbfd loader or signature-analysis console commands.
- `decomp_test`: the unit and data test runner (`test.cc`).
- A sleigh home: compiled `.sla` files and their support files for the
  processors in `GHIDRA_DECOMP_SPEC_PROCESSORS`.

The JVM-facing `ghidra_process.cc` and the other `GHIDRA` sources are never
compiled here. A test checks that `libdecomp_archive.a` defines no
`GhidraCapability` or `GhidraCommand` symbol.

## Build and test

From this `cpp` directory, with `$B` naming a build directory outside
`src/decompile` (the Gradle source distribution packages that whole tree;
`Ghidra/Features/Decompiler/build` is ignored by git and removed by Gradle's
`clean` task):

```sh
B=../../../build/cmake
cmake -S . -B $B -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build $B
ctest --test-dir $B --output-on-failure
```

Requirements: CMake 3.24 or newer, a C++11 compiler, zlib development
files (or `-DGHIDRA_DECOMP_LOCAL_ZLIB=ON` to compile the bundled copy).
Ninja is recommended: the spec compilation uses a Ninja job pool so that
one `.sla` file compiles at a time. The default processor set
compiles 58 specifications; `x86-64` and `AARCH64` each take minutes and
more than 1 GB of memory. Set `GHIDRA_DECOMP_SPEC_PROCESSORS` to a smaller
list (for example `x86`) for a faster build.

The generated parsers (`xml.cc`, `grammar.cc`, `pcodeparse.cc`,
`slghparse.cc`, `slghscan.cc`) are the committed ones; bison and flex are
not run.

To build inside a container with no Java, run this from the root of the
Ghidra checkout:

```sh
podman run --rm -v "$PWD":/src:Z -w /src registry.fedoraproject.org/fedora:44 \
  bash -c 'dnf -y install gcc-c++ cmake ninja-build zlib-devel \
    && cmake -S Ghidra/Features/Decompiler/src/decompile/cpp -B /tmp/b -G Ninja \
    && cmake --build /tmp/b \
    && ctest --test-dir /tmp/b --output-on-failure'
```

## Options

| Option | Default | Effect |
| --- | --- | --- |
| `GHIDRA_DECOMP_LOCAL_ZLIB` | `OFF` | Compile `../zlib` with `NO_GZIP` and define `LOCAL_ZLIB` instead of linking the system zlib. |
| `GHIDRA_DECOMP_CONSOLE` | `ON` | Compile the console sources (`interface`, `ifacedecomp`, `ifaceterm`, ...). Needed by `decomp_console` and `decomp_test`. |
| `GHIDRA_DECOMP_TERMINAL` | `ON` on Unix with console | Define `__TERMINAL__` (line editing for the console). Exported: it changes the layout of `IfaceTerm`. |
| `GHIDRA_DECOMP_CPUI_DEBUG` | `OFF` | Define `CPUI_DEBUG`. Exported: it changes class layouts. |
| `GHIDRA_DECOMP_SANITIZE` | empty | Value for `-fsanitize=` on every target, for example `address,undefined`. |
| `GHIDRA_DECOMP_BUILD_TOOLS` | `ON` | Build `sleigh_compiler` and `decomp_console`. |
| `GHIDRA_DECOMP_BUILD_TESTS` | `ON` when top level | Build `decomp_test`, `sleigh_smoke`, `decomp_smoke` and register the tests. |
| `GHIDRA_DECOMP_SPEC_PROCESSORS` | `x86;ARM;AARCH64;Toy;PowerPC;MIPS` | Processor directories whose `.slaspec` files are compiled into the sleigh home. Empty disables spec compilation and the tests that need it. |
| `GHIDRA_DECOMP_CXX_STANDARD` | `11` | C++ standard for the sources. The Gradle build uses `-std=c++11`. |
| `GHIDRA_DECOMP_INSTALL` | `ON` when top level | Generate install and export rules. |
| `GHIDRA_DECOMP_CHECK_MANIFEST` | `ON` | Compare `cmake/GhidraDecompSources.cmake` with the `Makefile` at configure time and stop on a difference. |
| `GHIDRA_DECOMP_MASTER_MAKEFILE` | empty | Path to another checkout's decompiler `Makefile`. Adds the test `manifest_matches_makefile_master`. |
| `GHIDRA_DECOMP_SLEIGH_HOME` | `<build>/sleigh-home` | Where the compiled specs go. Must be empty or generated by an earlier configure of this build (marker file `.sleigh-home-owned-by-cmake`); files the build no longer owns are removed on reconfigure. |
| `GHIDRA_DECOMP_PROCESSORS_ROOT` | `Ghidra/Processors` of this checkout | Where the processor modules are read from. |

Compiler warnings follow `buildNatives.gradle`: `-Wall -Wno-sign-compare`.
The Windows implementation receives private `_WINDOWS`; broad platform macros
are not exported to consumers. Optimization comes from the chosen build type.
Warnings from newer compilers are left as they are.

Sanitizer instrumentation is not a claim that the inherited engine is free of
undefined behavior. At tested source base `263160cf57db`, strict Clang 22
`address,undefined` execution with the default C++11 standard reports a signed
shift in the unchanged `address.hh` `sign_extend` helper (for example,
`sign_extend(197,3)`). This build integration does not repair that engine
issue. The separately tested C++20 Toy configuration passes its selected
runtime cases, but does not qualify C++11 or the full native suite. These
sanitizer runs explicitly used `detect_leaks=0`; they establish no leak-free
teardown claim.

When this directory is added to another project with `add_subdirectory`,
`GHIDRA_DECOMP_BUILD_TESTS` and `GHIDRA_DECOMP_INSTALL` default to off and
`GHIDRA_DECOMP_SLEIGH_HOME` is visible in the parent scope.

## Source manifest

`cmake/GhidraDecompSources.cmake` lists the sources by the same sets the
`Makefile` uses (`CORE`, `DECCORE`, `SLEIGH`, `GHIDRA`, `SLACOMP`,
`SPECIAL`, and `EXTRA` as every other `*.cc`).
`cmake/CheckMakefileManifest.cmake` parses the `Makefile` and compares the
sets and the expanded `LIBSLA_NAMES`/`LIBDECOMP_NAMES` archive membership
(excluding BFD support). It runs at configure time and as the test
`manifest_matches_makefile`.
When a source is added or removed upstream, the check names it under
`only-in-Makefile` or `only-in-CMake`, and the fix is a one-line edit of the
manifest. The check can also run by hand:

```sh
cmake -DMAKEFILE=$PWD/Makefile -DSOURCE_DIR=$PWD -P cmake/CheckMakefileManifest.cmake
```

## Tests

| Test | Label | What it checks |
| --- | --- | --- |
| `manifest_matches_makefile` | manifest | The source manifest equals the `Makefile` sets. |
| `manifest_rejects_archive_drift` | manifest | Mutating only a final Makefile archive composition is rejected. |
| `bundled_zlib_symbols`, `bundled_zlib_symbol_guard` | isolation | Audit bundled archive/object globals and reject unknown or unprefixed source globals, including instrumented C-object controls. Clang ASan metadata is accepted only for its registration flag or audited private globals defined in the same object. |
| `sleigh_specs_incremental` | specs | The module-relative processor default works from an external source directory; removed specifications and support files are retired without deleting unknown output files; a fresh install contains only retained outputs; reduced processor selections do not register the full unit suite. |
| `manifest_matches_makefile_master` | manifest | Same against `GHIDRA_DECOMP_MASTER_MAKEFILE`, when set. |
| `decomp_unittests` | unit | `decomp_test unittests` (the `../unittests` cases). Registered when x86, Toy, PowerPC, MIPS and AARCH64 are selected. |
| `decomp_datatests` | data | `decomp_test datatests` over the `../datatests` files whose language the compiled processors provide. On current master, the default processors cover 87 of 89. |
| `sleigh_smoke_x86-64`, `sleigh_smoke_arm-thumb`, `sleigh_smoke_aarch64` | smoke | `sleigh_smoke` disassembles and translates fixed bytes with the built `.sla` files and compares with `cmake/smoke/expected/<case>.txt`. |
| `capability_linkage` | smoke, isolation | `decomp_smoke --check-capabilities`: `xml`, `raw`, `c-language`, and `java-language` are registered; `bfd` is absent. |
| `no_jvm_linkage` | isolation | No built program links `libjvm`, `libjava`, `libjli` or `libjawt` (`ldd`, `otool -L` or `readelf -d`). |
| `no_jvm_runtime` | isolation | `sleigh_smoke` runs under `env -i PATH=/usr/bin HOME=/nonexistent LANG=C`. With `strace` present, exactly one `execve` is recorded. This does not detect fork-only children or `execveat`. |
| `no_ghidra_process_symbols` | isolation | `nm` finds no `GhidraCapability` or `GhidraCommand` symbol in `libdecomp_archive.a`. Registered only when CMake found an `nm`. |
| `installed_consumer` | install, smoke | Installs into the build directory, builds a separate `find_package` consumer using only installed headers/targets, and checks capability registration. Enabled for native top-level builds with installation enabled. |

Run a subset with labels, for example `ctest --test-dir $B -L smoke`.
Each SLEIGH smoke test is registered only when its processor is selected.
The `no_jvm_*`, `no_jvm_guard`, and `no_ghidra_process_symbols` checks are
registered only for native Unix builds; they provide no Windows proof and are
not run while cross-compiling. `no_jvm_runtime` also requires x86. The
installed-consumer test uses a fresh test-owned installation and build
directory on every run.

`sleigh_smoke <sleigh-home> <case>` prints one block per instruction: the
address, mnemonic and operands, then one indented line per p-code op with
varnodes as `space[offset:size]`. The expected files were generated once
and reviewed by hand. Comparison retains raw unique-space offsets and sizes,
including every alias and partial overlap. Specification changes can change
temporary allocation, so review the resulting p-code before updating a golden.
Only LOAD/STORE address-space host pointers are rendered as stable space names.
Regenerate one with
`$B/sleigh_smoke $B/sleigh-home x86-64 > cmake/smoke/expected/x86-64.txt`
after a deliberate change to a spec.

## Sleigh home layout

`SleighArchitecture::scanForSleighDirectories` looks for
`Ghidra/Processors/*/data/languages` under a root. The build writes:

```
<sleigh-home>/Ghidra/Processors/<P>/data/languages/<spec>.sla
<sleigh-home>/Ghidra/Processors/<P>/data/languages/*.ldefs *.pspec *.cspec *.opinion ...
```

Only `.slaspec` files that an `.ldefs` names in a `slafile` attribute are
compiled. Per-processor compiler options come from `sleighCompileOptions` in
`Ghidra/Processors/<P>/build.gradle`, the same source the Gradle build
reads. Each spec compiles in single-file mode with an explicit output path,
so `@include` resolves against the source tree and no file is written there.
Every output depends on the processor's `.slaspec` and `.sinc` files; changing
an included source cannot leave a stale sibling `.sla` in the generated tree.

The build records its generated/copied paths in a build-directory manifest.
Support selection accepts direct `.ldefs`, `.pspec`, `.cspec`, `.opinion`,
`.dwarf`, `.gdis`, and `.register.info` files. Java `.sla.lock` files, logs,
stamps, and other files remain in their source location and are not copied or
advertised for installation. Supporting a new upstream metadata suffix requires
an explicit update to this list. Output-home symlinks followed by `..` resolve
against the physical symlink target before the ownership checks.
Only active `.ldefs` references select specifications; XML comments are ignored,
and an unterminated comment fails before the helper changes its output home.
Reconfiguration removes obsolete paths from that list, including files for
removed processors, but preserves unrecorded files in the output tree.

`decomp_test` takes this root directory with `-sleighpath`, or reads it from
`SLEIGHHOME` when passed `-usesleighenv`.

The console has different arguments: `-s` adds a language directory directly
and may be repeated. For example, to use the generated x86 specifications:

```sh
$B/decomp_console -s $B/sleigh-home/Ghidra/Processors/x86/data/languages
```

Without an explicit language directory, the console searches its discovered
Ghidra installation root, falling back to `SLEIGHHOME` only when no root is found.

## Install and use from another project

```sh
cmake --install $B --prefix /opt/ghidra-decompiler
```

installs the archives, the programs, the headers under
`include/ghidra/decompiler`, the sleigh home under
`share/ghidra-decompiler/sleigh-home`, and a package config under
`lib/cmake/GhidraDecompiler`.

Language installation uses the helper's exact owned file list. A same-prefix
reinstall, including one from a new build of this package, retires only language
files recorded by the previous successful installation and still matching its
saved SHA-256 digests. Reduced and empty selections remove retired owned files;
foreign files and historical unmanifested installs are preserved. An existing
unmanifested destination is a conflict even if its bytes match. Modified owned
files, symlinks, corrupt state, and invalid paths fail preflight before package
archive/header/data writes. Restore or move conflicting files deliberately;
there is no implicit takeover mode.

The active `--prefix` and `DESTDIR` select independent ownership state. Moving
to a new prefix leaves the old installation intact. Package paths through
symlinks or parent-traversal components are rejected. `Headers` component
installation performs preflight but does not retire language files; the
`SleighHome` component manages the language selection. A local prefix lock
serializes installs. Regular-file checks use the host `test` utility on Unix
and PowerShell on Windows. These operations support trusted local filesystems;
normal CMake partial installation on I/O failure remains possible. An incomplete
language write leaves a `.pending` record for explicit inspection, and there is
no crash-atomic replacement or hostile-concurrent-mutation guarantee.

Bundled zlib retains the unchanged installed headers and `LOCAL_ZLIB` layout
contract. Its C objects use a private project-specific linked-symbol prefix,
including internal globals; a typed private C adapter connects the unchanged
stream types to six generated compression call sites. No prefix definitions
are exported to C++ consumers. Audited source fingerprints fail configuration
when the bundled inventory changes and requires review. Legacy no-memcpy,
WinCE, ambient `Z_PREFIX`/`Z_PREFIX_SET`, and `ZLIB_DLL` configurations are
unsupported. GNU-style and MSVC-style C preinclude options are selected by the
compiler frontend; platform acceptance requires running that platform's tests.

The C++ package requires matching source revision, compiler ABI, and exported
configuration. Symbol separation does not promise compatibility between arbitrary
external C++ zlib header definitions. External zlib streams must remain with
their own implementation. The installed consumer optionally co-links an external
static gzip implementation in a C translation unit using
`GHIDRA_DECOMP_TEST_STATIC_ZLIB` and `GHIDRA_DECOMP_TEST_ZLIB_INCLUDE_DIR`.
With Toy selected, it loads only installed language files and checks actual
decompiled skip/arithmetic behavior; when Toy is excluded, that check reports
explicit nonavailability.

A consumer:

Installed `libdecomp.hh` keeps its unchanged transitive console declarations
so it can be parsed in both configurations. Console implementation APIs are
linkable only when `GhidraDecompiler_HAVE_CONSOLE` is true. Header presence
alone does not grant implementation support. JVM-facing GHIDRA, BFD loader,
BFD console, and standalone SLEIGH compiler implementation headers are excluded
from the archive API.

`CPUI_DEBUG`, `__TERMINAL__`, and `LOCAL_ZLIB` are public build requirements
because they affect class layouts or embedded stream types. Platform macros
remain private implementation settings. Consumers must not independently change
these definitions or enable `CPUI_RULECOMPILE`. The package version-selection
rule does not promise C++ ABI compatibility across Ghidra releases.

The package also installs `SleighCompileSpecs.cmake` and its
`BuildSafety.cmake` dependency beside the package configuration. Include the
helper there and provide an explicit `PROCESSORS_ROOT` when compiling another
matching source tree, with `COMPILER ghidra::sleigh_compiler` to use the
installed compiler target.

```cmake
cmake_minimum_required(VERSION 3.24)
project(consumer CXX)
find_package(GhidraDecompiler 12 REQUIRED)
add_executable(consumer main.cc)
target_link_libraries(consumer PRIVATE ghidra::decomp)
target_compile_definitions(consumer PRIVATE SLEIGH_HOME="${GhidraDecompiler_SLEIGH_HOME}")
message(STATUS "sla format ${GhidraDecompiler_SLA_FORMAT_VERSION}, specs in ${GhidraDecompiler_SLEIGH_HOME}")
```

```cpp
#include "libdecomp.hh"
int main() {
  ghidra::startDecompilerLibrary(SLEIGH_HOME);   // scans Ghidra/Processors under the root
  return ghidra::ArchitectureCapability::getCapability("xml") == nullptr;
}
```

The config file exports `GhidraDecompiler_GHIDRA_VERSION`,
`GhidraDecompiler_SLA_FORMAT_VERSION`, `GhidraDecompiler_SLEIGH_HOME`, and
`GhidraDecompiler_HAVE_BFD` (always `OFF`), `_HAVE_CONSOLE`, `_HAVE_TERMINAL`,
`_HAVE_CPUI_DEBUG`, `_HAVE_LOCAL_ZLIB`. The compile definitions that change
class layouts (`__TERMINAL__`, `CPUI_DEBUG`, `LOCAL_ZLIB`) travel with the
targets, so a consumer sees the same layouts the archives were built with.
The targets also carry native thread support and, for an instrumented build,
the sanitizer runtime link options.

Link either `ghidra::sla` or `ghidra::decomp`, not both: `ghidra::decomp`
already contains every object in `ghidra::sla`.

## Native lifetime and concurrency

`SleighArchitecture` stores translators in a static map keyed by language.
Architectures for the same language therefore share one translator, and
initializing another architecture resets that translator to the new loader and
context. Destruction only clears the architecture's pointer; `shutdown()` does
not clear the static map.

This build provides no proof that independent decompiler engines can run
concurrently in one process, nor that XML or the other parsers are reentrant.
Serialize native use or isolate engines in separate processes.
