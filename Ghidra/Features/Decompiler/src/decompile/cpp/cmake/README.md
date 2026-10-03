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
lists and build integration. Here the build lives beside the sources and reads
its source lists from the Makefile. It does not introduce a stable C++
ABI across Ghidra releases; consumers must use matching headers, libraries,
specifications, and build definitions.

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
- `ghidra::sla`, `ghidra::decomp_archive`, `ghidra::decomp`,
  `ghidra::sleigh_compiler`, `ghidra::decomp_console`: the targets to use from
  another CMake project. The real target names start with `ghidra_`
  (`ghidra_sla`, `ghidra_decomp`, ...) so that a project including this
  directory cannot collide with them; file names and exported names are the
  short ones above.
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
files (or `-DGHIDRA_DECOMP_LOCAL_ZLIB=ON` to compile the bundled copy; Ghidra
releases before 11.1 do not use zlib at all).
Ninja is recommended: the spec compilation uses a Ninja job pool so that
at most two `.sla` files compile at once. The default processor set
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
| `GHIDRA_DECOMP_CHECK_MANIFEST` | `ON` | Check at configure time that the two archives have the members of the `Makefile`'s `LIBSLA_NAMES` and `LIBDECOMP_NAMES`, and stop on a difference. |
| `GHIDRA_DECOMP_MASTER_MAKEFILE` | empty | Path to another checkout's decompiler `Makefile`. Adds the test `manifest_matches_makefile_master`. |
| `GHIDRA_DECOMP_SLEIGH_HOME` | `<build>/sleigh-home` | Where the compiled specs go. Must be empty or generated by an earlier configure of this build (marker file `.sleigh-home-owned-by-cmake`); files the build no longer owns are removed on reconfigure. |
| `GHIDRA_DECOMP_PROCESSORS_ROOT` | `Ghidra/Processors` of this checkout | Where the processor modules are read from. |
| `GHIDRA_DECOMP_SLEIGH_COMPILER` | empty | A `sleigh_compiler` that runs on the build host, used for the specifications instead of the one built here. See cross-compiling below. |

Compiler flags follow `buildNatives.gradle`: `-Wall -Wno-sign-compare`,
`LINUX` and `_LINUX` defined on Linux, `WINDOWS` and `_WINDOWS` on Windows.
Optimization comes from `CMAKE_BUILD_TYPE`: `Release` uses `-O3 -DNDEBUG`
where Gradle uses `-O2`. The sources contain no `assert` or `NDEBUG` checks,
so `NDEBUG` does not change behavior; set `CMAKE_CXX_FLAGS_RELEASE=-O2` to
match Gradle exactly. For MSVC, Gradle also defines `_SECURE_SCL=0` and
`_HAS_ITERATOR_DEBUGGING=0` for its own `decompile.exe`; this build keeps the
MSVC defaults, so that consumers linking the archives use matching iterator
settings. Warnings from newer compilers are left as they are.

When this directory is added to another project with `add_subdirectory` or
`FetchContent`, `GHIDRA_DECOMP_BUILD_TESTS` and `GHIDRA_DECOMP_INSTALL`
default to off and `GHIDRA_DECOMP_SLEIGH_HOME` is visible in the parent scope.

## Source lists

The `Makefile` names the sources of each part of the native code (`CORE`,
`DECCORE`, `SLEIGH`, `GHIDRA`, `SLACOMP`, `SPECIAL`, and `EXTRA` as every
other `*.cc`). `cmake/GhidraDecompSources.cmake` reads those variables at
configure time, so a source added to or removed from the `Makefile` needs no
second edit here. The only knowledge kept in the CMake files is which `EXTRA`
units belong to the console and which need `<bfd.h>`; any other `EXTRA` unit
is part of the decompiler library. Local `coreext_*`, `ghidraext_*` and
`consoleext_*` sources (ignored by git) are not compiled.

`cmake/CheckMakefileManifest.cmake` checks that the two archives have exactly
the members of the `Makefile`'s `LIBSLA_NAMES` and `LIBDECOMP_NAMES` (without
the BFD loader). It runs at configure time and as the test
`manifest_matches_makefile`. With `-DGRADLE=`, it also compares the sources
that `buildNatives.gradle` compiles into `decompile` and `sleigh` with the
`Makefile`'s `GHIDRA_NAMES` and `SLEIGH_NAMES`; `grammar.cc`, which Gradle
keeps commented out, counts as a deliberate omission. Both checks can run by
hand:

```sh
cmake -DMAKEFILE=$PWD/Makefile -P cmake/CheckMakefileManifest.cmake
cmake -DMAKEFILE=$PWD/Makefile -DGRADLE=$PWD/../../../buildNatives.gradle -DGRADLE_STRICT=ON \
  -P cmake/CheckMakefileManifest.cmake
```

## Ghidra versions

The same CMake files configure, build and test on every Ghidra release from
10.3 to the current master: the `Makefile` layout they read has not changed
in that range. Releases before 11.1 have no `slaformat.cc`, no compressed
`.sla` files and no bundled zlib; there the build needs no zlib and exports
an empty `GhidraDecompiler_SLA_FORMAT_VERSION`. The SLEIGH smoke expectations
under `cmake/smoke/expected` were recorded from this tree's specifications.
Where another release's specifications produce different p-code, those tests
report themselves as skipped and name both fingerprints (see Tests).

## Cross-compiling

The processor specifications are compiled at build time by running
`sleigh_compiler`. When cross-compiling, either set
`CMAKE_CROSSCOMPILING_EMULATOR` (for example `qemu-aarch64`), which CMake
uses to run the `sleigh_compiler` built for the target, or set
`GHIDRA_DECOMP_SLEIGH_COMPILER` to a `sleigh_compiler` built for the host, or
set `GHIDRA_DECOMP_SPEC_PROCESSORS` to an empty string. Configuration stops
with a message when none of these is set. The output does not depend on the
host: a `.sla` file is the same whichever machine compiles it.

## Tests

| Test | Label | What it checks |
| --- | --- | --- |
| `manifest_matches_makefile` | manifest | The archives have the members of `LIBSLA_NAMES` and `LIBDECOMP_NAMES`. |
| `manifest_matches_gradle` | manifest | `buildNatives.gradle` compiles the `Makefile`'s `GHIDRA_NAMES` and `SLEIGH_NAMES`. |
| `manifest_rejects_archive_drift` | manifest | On copies of the `Makefile`: a unit added to a group is built, an unlisted source joins the library, a local extension does not, a missing source is named, and an archive member outside every group is rejected. |
| `sleigh_specs_incremental` | specs | The module-relative processor default works from an external source directory; removed specifications and support files are retired without deleting unknown output files; a fresh install contains only retained outputs; reduced processor selections do not register the full unit suite. |
| `manifest_matches_makefile_master` | manifest | Same against `GHIDRA_DECOMP_MASTER_MAKEFILE`, when set. |
| `decomp_unittests` | unit | `decomp_test unittests` (the `../unittests` cases). Registered when the processors that declare every language the unit tests name are selected; on current master those are x86, Toy, PowerPC, MIPS and AARCH64. |
| `decomp_datatests` | data | `decomp_test datatests` over the `../datatests` files whose language the compiled processors provide. On current master, the default processors cover 87 of 89. |
| `sleigh_smoke_x86-64`, `sleigh_smoke_arm-thumb`, `sleigh_smoke_aarch64` | smoke | `sleigh_smoke` disassembles and translates fixed bytes with the built `.sla` files and compares with `cmake/smoke/expected/<case>.txt`. Skipped, not passed, when the output differs and the specification sources are not the recorded ones. |
| `sleigh_smoke_self_test` | smoke | The temporary renaming used by the SLEIGH smoke comparison accepts moved temporaries and rejects changed overlaps, sizes and identities; a difference is skipped only when the specification sources differ. |
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
and reviewed by hand. Each starts with the SHA-256 fingerprint of the
processor's `.slaspec` and `.sinc` files it was recorded from. The output
must equal the expected file, or differ only in where temporaries are
allocated, which changes between Ghidra releases:
groups of overlapping `unique` varnodes are renamed by first use, keeping each
varnode's offset within its group and its size, so identity, size and every
alias and partial overlap are still compared. Everything else, including all
other address spaces, is compared exactly. The test `sleigh_smoke_self_test`
checks that the renaming accepts moved temporaries and rejects changed
overlaps, sizes and identities. Any other difference fails the test when the
specification sources have the recorded fingerprint. When they do not (another
Ghidra release, or an edited specification), the test is reported as skipped
with both fingerprints and the first differing line: the expectation does not
describe those sources. Only LOAD/STORE address-space host pointers are
rendered as stable space names.
After a deliberate change to a specification, review the new output, then
record it with the fingerprint of the current sources:

```sh
$B/sleigh_smoke $B/sleigh-home x86-64 --record "$(cat $B/smoke-fingerprints/x86-64.txt)" \
  > cmake/smoke/expected/x86-64.txt
```

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
`lib/cmake/GhidraDecompiler`. A consumer:

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
`GhidraDecompiler_HAVE_CONSOLE`, `_HAVE_TERMINAL`,
`_HAVE_CPUI_DEBUG`, `_HAVE_LOCAL_ZLIB`, `_NEEDS_ZLIB`. A request such as
`find_package(GhidraDecompiler 12)` accepts any 12.x package; the C++
interface is not stable between releases, so build consumers against the
package of the Ghidra version they use. The compile definitions that change
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
