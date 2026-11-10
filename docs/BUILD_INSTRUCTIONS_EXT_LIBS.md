# Building Mochi's External Libraries

The current GVM compiler links against three C libraries:

| Library | Purpose |
|---|---|
| [Sorbet](https://github.com/yampug/sorbet) | Sorbet typechecking through its LSP C API |
| [Tree-sitter](https://github.com/yampug/tree-sitter) | Ruby parser runtime |
| [Tree-sitter Ruby](https://github.com/yampug/tree-sitter-ruby) | Ruby grammar |

Place every built artifact in `fragments/libs/`. The `build` and `specs` tasks
set the platform library path automatically.

QuickJS and WarthogDB are legacy dependencies. Their bindings remain in old
source, but the current GVM compiler does not use them and they are not needed
to build or test Mochi.

## Prerequisites

* [Task](https://taskfile.dev)
* [Clang](https://clang.org) or [GCC](https://www.gnu.org/software/gcc/)
* [Bazel](https://bazel.build) 6.5+ for the Sorbet fork on macOS
* Docker only when building the Linux Sorbet library from macOS
* `make` and `sed` when building Tree-sitter

## libsorbet

The Sorbet fork exposes Sorbet's LSP through a C API.

### Shared library

`task specs` and non-static compiler builds use `libsorbet.dylib` on macOS or
`libsorbet.so` on Linux.

Build and install it with the helper script:

```bash
# Uses ../sorbet by default. Set SORBET_ROOT to point elsewhere.
./scripts/sorbet_lib_build.bash --platform macos
# or
./scripts/sorbet_lib_build.bash --platform linux
```

The script builds the shared library and copies it into `fragments/libs/`.
It does not produce the static archive used by `task build`.

To build the shared library manually:

```bash
gh repo clone yampug/sorbet
cd sorbet/lib
task build:macos   # or task build:linux
```

The output is written under `sorbet/dist/macos/` or `sorbet/dist/linux/`.
Copy `libsorbet.dylib` or `libsorbet.so` into `fragments/libs/`.

The Sorbet fork notes that native `task build:macos` may fail on macOS Sequoia
15 and newer. If that happens, reuse an existing `libsorbet.dylib` or build the
Linux library and use it in the Linux build environment.

### Static archive

The default `task build` compiles with `-Dstatic_sorbet` and force-loads:

```text
fragments/libs/libsorbet.a
```

That archive is not checked in (`.gitignore` ignores `fragments/libs/lib*.a`).
Place a macOS or Linux `libsorbet.a` there before running `task build`. The
shared library above is still required by `task specs`.

## libtree-sitter

```bash
gh repo clone yampug/tree-sitter
cd tree-sitter
task build-shared
```

The build produces `libtree-sitter.dylib` on macOS or `libtree-sitter.so` on
Linux. Copy it into `fragments/libs/`.

On Linux, keep the versioned symlink:

```bash
ln -sf libtree-sitter.so fragments/libs/libtree-sitter.so.0.27
```

On macOS, the library records `/usr/local/lib/libtree-sitter.0.27.dylib` as its
install name. `task build` rewrites the compiler binary to use
`fragments/libs/libtree-sitter.dylib` instead. `task specs` creates a temporary
`fragments/libs/libtree-sitter.0.27.dylib` symlink and removes it afterwards.
Do not commit that temporary symlink.

## libtree-sitter-ruby

```bash
gh repo clone yampug/tree-sitter-ruby
cd tree-sitter-ruby
task shared
```

The current task emits `libtree-sitter-ruby.so`. Copy it into `fragments/libs/`
as `libtree-sitter-ruby.so` on Linux. When it is built on macOS, name the
Mach-O shared library `libtree-sitter-ruby.dylib` so Crystal's `-l` lookup
finds it.

## Verifying the setup

From the Mochi repository root:

```bash
task build   # static libsorbet
task specs   # shared libsorbet and tree-sitter
task run     # build compiler and compile compiler/motestproj
```
