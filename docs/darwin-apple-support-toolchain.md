# The darwin toolchain, built on apple_support

Darwin toolchains are built on [apple_support's `cc_toolchain` macro][macro]
rather than on `unix_cc_toolchain_config`, which every other target still
uses. See `toolchain/apple_cc_toolchain.bzl`. Nothing else is affected,
including cross-compiling to Linux from a Mac.

[macro]: https://github.com/bazelbuild/apple_support/blob/main/toolchain/cc_toolchain.bzl

## Why

`objc_library` refuses to build against a toolchain that does not declare the
`objc-compile` action ("Compiling objc_library targets requires the Apple CC
toolchain"), and `unix_cc_toolchain_config` does not declare it
(bazel-contrib/toolchains_llvm#662). Declaring it there means patching
rules_cc with a `single_version_override` -- one every downstream user would
have to carry too, pinned to a matching rules_cc version.

apple_support's macro is the toolchain building code Apple platform builds
already use, with the Apple defaults assembled in the right order, and it is
parameterized by `tool_map` and `sysroot_feature` -- so it takes the hermetic
LLVM and macOS SDK this repo already resolves. It is also where darwin
toolchains are headed anyway: apple_support's maintainer is working to remove
the legacy toolchain configuration from rules_cc, which is what
`unix_cc_toolchain_config`-based toolchains like this repo's are built on. In the rules_cc toolchain API
it is built on, declaring the action is one line:

```starlark
"@rules_cc//cc/toolchains/actions:objc_compile": ":clang",
```

The rest arrives with it: the action type sets fold Objective-C into
`compile_actions`, `cpp_compile_actions`, `link_executable_actions` and
`ar_actions`, `-fobjc-arc` / `-fno-objc-arc` come from rules_cc's
`objc_arc_flags`, and prefix headers and framework search paths from
apple_support.

## What it covers

Everything the darwin toolchain did before, plus Objective-C:

- The Objective-C tests in `tests/objc`: ARC and non-ARC sources, `pch`,
  `sdk_includes`, framework search paths, and a binary linking Objective-C,
  Objective-C++ and C++ together.
- `stdlib` selection, the compilation modes, and every user-facing flag
  attribute.
- Sanitizers: `asan`, `tsan` and `ubsan` from apple_support, plus
  `-fsanitize-link-c++-runtime` and ubsan's `-fsanitize=bounds` /
  `-fsanitize=nullability` as before; `lsan` is declared here. The runtime
  dylib reaches a test's runfiles through `dynamic_runtime_lib` and an
  `@loader_path` rpath the compiler wrapper adds.
- Coverage, instrumented with `-fprofile-instr-generate -fcoverage-mapping`,
  which is what the toolchain's `llvm-profdata` reads.
- Debug info without absolute paths (`DW_AT_comp_dir` is `"."`, the OSO
  entries in a linked binary are execroot-relative), and
  `--apple_generate_dsym` produces a populated `.dSYM`, built by the
  distribution's `dsymutil`.
- `layering_check` and `parse_headers`. The feature comes with apple_support,
  so it also covers the Objective-C compile actions. A framework imported
  without a module map is invisible to it -- rules_apple's import rules
  provide one, as does the test's stand-in -- and can opt out with
  `features = ["-layering_check"]`.

The macOS SDK is referred to as `__BAZEL_XCODE_SDKROOT__` and resolved per
action from the `SDKROOT` Bazel injects: nothing invalidates this repository
when Xcode is upgraded, so an absolute path captured at fetch time goes stale
-- and is machine-specific besides. A sysroot the user supplied is a real
path and is used as-is.

Verified against LLVM 17.0.6, 18.1.8 and 19.1.7. Cross-compiling from a Mac
to Linux keeps using `unix_cc_toolchain_config` and produces binaries
identical to before this change.

## Known gaps

- **MemorySanitizer** is Linux-only and not wired up here, as before.
- **Running** an asan binary hangs on recent macOS with LLVM 19's runtime.
  This reproduces with a plain `clang -fsanitize=address` outside Bazel, so
  it is not something this toolchain introduces; the sanitizer tests are
  `target_compatible_with` Linux.

## What is shared with apple_support, and what is not

Most of what `cc_toolchain_config.bzl` passes on darwin is already in
apple_support's feature list, byte for byte, so the toolchain does not pass
it again:

| Flags | Where they come from |
| ----- | -------------------- |
| `-fstack-protector -fcolor-diagnostics -Wall -Wthread-safety -Wself-assign -fno-omit-frame-pointer` | `always_compile_flags`. Identical to this repo's default `compile_flags`. |
| `-Wno-builtin-macro-redefined -D__DATE__/__TIMESTAMP__/__TIME__="redacted"` | `unfiltered_compile_flags`. Identical to this repo's default. |
| `-no-canonical-prefixes`, `-target <arch>-apple-macosx<min-os>` | `default_required_flags`, with the triple derived from the target platform and honoring `--macos_minimum_os` |
| `-g` (dbg), `-g0 -O2 -DNDEBUG` (opt) | `dbg_compile_flags` / `opt_compile_flags` |
| `-headerpad_max_install_names -fobjc-link-runtime -lc++ -framework Foundation` | `default_link_flags`, `link_libc++`, `apply_implicit_frameworks` |
| `-Wl,-oso_prefix`, `-fdebug-prefix-map`, `-fcoverage-prefix-map` | the prefix-map args |
| `-fsanitize=address/thread/undefined` | `//toolchain/sanitizers` |
| `-D_FORTIFY_SOURCE=1`, except under asan (google/sanitizers#247) | `no_asan_compile_flags` |
| `-Xclang -fno-cxx-modules -Wno-module-import-in-extern-c`, which `layering_check` needs under `-std=c++20` | `no_cxx_modules_flags`, gated on `use_module_maps` |
| `-fobjc-arc` / `-fno-objc-arc`, `-include <pch>`, `-F<framework>` | rules_cc's `objc_arc_flags`, apple_support's `pch` and `//toolchain/objc` |

What remains is either specific to a hermetic LLVM, or a deliberate
difference:

| Flags | Why they are here |
| ----- | ----------------- |
| `-B<llvm>/bin/`, `-resource-dir <llvm>/lib/clang/<v>`, `-idirafter <resource>/include` | Paths into the downloaded LLVM distribution. |
| `-fuse-ld=lld --ld-path=<llvm>/bin/ld64.lld` | The bundled linker. |
| `-std=<standard>` | The `cxx_standard` attribute; apple_support reads `BAZEL_CXXOPTS` instead, which cannot differ between two toolchains in one workspace. |
| `-nostdinc++ -cxx-isystem ...`, `-L.../usr/lib -lc++abi -Bdynamic` | The `stdlib` attribute. |
| `-fstandalone-debug` (dbg) | Not in apple_support's `dbg_compile_flags`. |

Two darwin attribute defaults change on purpose: `compile_flags` drops
`-U_FORTIFY_SOURCE` in favor of apple_support's asan-gated fortify above, and
`opt_compile_flags` drops `-D_FORTIFY_SOURCE=1 -ffunction-sections
-fdata-sections` (the section-splitting pair only feeds `-Wl,--gc-sections`,
which is a GNU ld / lld-ELF flag).

## The apple_support API it uses

Most of what looks Apple-specific in the macro needed no API at all: the `__BAZEL_*`
placeholders and the `LINKED_BINARY=` / `DSYM_HINT_DSYM_PATH=` /
`STRIP_DEBUG_SYMBOLS` sentinels are `wrapped_clang`'s argument protocol,
which the compiler wrapper speaks (below), and `layering_check` works as-is
since a plain clang ignores `APPLE_SUPPORT_MODULEMAP`. The changes that did
need one, each defaulting to current behavior:

1. **`//toolchain:dynamic_toolchain_info` made public.** The macro references
   it inside the Apple branch of a `select()`, so an Apple-targeting consumer
   fails analysis without it.
2. **`flags_from_env = False`** drops the `BAZEL_*OPTS` features: their
   `-std=c++17` default would override `cxx_standard`, and the environment
   cannot differ between two toolchains in one workspace.
3. **`extra_enabled_features` / `extra_known_features` /
   `extra_include_directories` as attributes.** The `label_flag`s are global,
   and this repo stamps out more than one toolchain per workspace.
4. **`dynamic_runtime_lib` / `static_runtime_lib` passthrough**, which is how
   a sanitizer runtime dylib reaches a test's runfiles.
5. **`coverage_instrumentation = False`** leaves the coverage-map-format
   features out: Bazel picks the gcc format by default, and whether that
   feature is *known* at all decides which flags a plain `bazel coverage`
   gets -- the one thing the wrapper protocol cannot replace.
6. **`llvm_version`** tells the macro the tools come from an LLVM
   distribution rather than Xcode, so it drops `-no_warn_duplicate_libraries`
   and `-reproducible` for the versions whose `ld64.lld` predates them
   (before LLVM 19).

## The compiler wrapper

Bazel spells Xcode-relative paths as `__BAZEL_XCODE_SDKROOT__` inside *build
variables* -- `objc_library(sdk_includes = ["CommonCrypto"])` becomes
`-I__BAZEL_XCODE_SDKROOT__/usr/include/CommonCrypto` in rules_cc's
`objc_common.bzl` -- so no toolchain argument can rewrite them; only
something between Bazel and clang can. apple_support's `wrapped_clang` is not
reusable for that (it always runs `/usr/bin/xcrun clang` against an Xcode
installation), and neither is `osx_cc_wrapper.sh` (it rewrites `argv[0]` to
`bin/clang` unconditionally, so it can never drive `clang++`). So the
toolchain generates `bin/xcode_clang_wrapper.sh` and
`bin/xcode_clang++_wrapper.sh` from
`toolchain/xcode_placeholder_wrapper.sh.tpl`, which speak `wrapped_clang`'s
argument protocol, in argv and inside params files:

- **`__BAZEL_*` placeholders** are substituted: `__BAZEL_EXECUTION_ROOT__`,
  `__BAZEL_EXECUTION_ROOT_CANONICAL__`, `__BAZEL_XCODE_SDKROOT__`,
  `__BAZEL_XCODE_DEVELOPER_DIR__` -- what keeps absolute paths out of debug
  info.
- **`LINKED_BINARY=<path>`** names the link output and is dropped.
- **`DSYM_HINT_DSYM_PATH=<path>`** runs the distribution's `dsymutil`, so
  `--apple_generate_dsym` hands back a populated bundle.
- **`STRIP_DEBUG_SYMBOLS`** runs `llvm-strip --strip-debug` -- after
  `dsymutil`, which needs the symbols -- the same order `wrapped_clang` runs
  `strip -S` in. This is what strips fastbuild links.

`SDKROOT` itself is not set by the toolchain: apple_support's `apple_env`
makes Bazel's `XcodeLocalEnvProvider` inject `SDKROOT` and `DEVELOPER_DIR`,
and setting it from the toolchain as well crashes Bazel with a duplicate-key
error rather than overriding.
