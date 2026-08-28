# Copyright 2026 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""A darwin cc toolchain built on apple_support's `cc_toolchain` macro.

The darwin counterpart to `cc_toolchain_config.bzl`, which builds every
toolchain on `unix_cc_toolchain_config`. That configuration does not declare the
Objective-C compile actions, so `objc_library` refuses to build against it
("Compiling objc_library targets requires the Apple CC toolchain"), and adding
them means patching rules_cc -- which every downstream user would then have to
patch too.

apple_support's macro is the toolchain building code Apple platform builds
use today, with the Apple defaults already assembled in the right order, and
it is parameterized by `tool_map` and `sysroot_feature`, so it takes the
hermetic LLVM and macOS SDK this toolchain already resolves. In the rules_cc
toolchain API it is built on, Objective-C is already a first-class action:
`cc_tool_map` synthesizes the `objc-compile` / `objc++-compile` action configs
from the tools mapped here, `objc_arc_flags` supplies `-fobjc-arc` /
`-fno-objc-arc` for `srcs` vs `non_arc_srcs`, and apple_support supplies the
prefix-header and framework-search-path args. Nothing has to be patched.

The compiler wrapper speaks wrapped_clang's argument protocol (the `__BAZEL_*`
placeholders and the LINKED_BINARY=/DSYM_HINT_DSYM_PATH=/STRIP_DEBUG_SYMBOLS
sentinels), so apple_support's Apple-side args work unchanged; a handful of
macro parameters keep the C++ standard and the coverage format from being
decided elsewhere.
"""

load("@apple_support//toolchain:cc_toolchain.bzl", _apple_cc_toolchain = "cc_toolchain")
load("@helly25_bzl//bzl/paths:paths.bzl", "paths")
load("@rules_cc//cc/toolchains:args.bzl", "cc_args")
load("@rules_cc//cc/toolchains:feature.bzl", "cc_feature")
load("@rules_cc//cc/toolchains:feature_set.bzl", "cc_feature_set")
load("@rules_cc//cc/toolchains:tool.bzl", "cc_tool")
load("@rules_cc//cc/toolchains:tool_map.bzl", "cc_tool_map")

_COMPILE = "@rules_cc//cc/toolchains/actions:compile_actions"
_CPP_COMPILE = "@rules_cc//cc/toolchains/actions:cpp_compile_actions"
_LINK = "@rules_cc//cc/toolchains/actions:link_actions"
_AR = "@rules_cc//cc/toolchains/actions:ar_actions"

def _fmt_flags(flags, toolchain_path_prefix):
    return [f.format(toolchain_path_prefix = toolchain_path_prefix) for f in flags]

def _args(name, actions, flags, **kwargs):
    """A `cc_args` unless `flags` is empty, in which case no target at all."""
    if not flags:
        return []
    cc_args(name = name, actions = actions, args = flags, **kwargs)
    return [":" + name]

def apple_cc_toolchain(
        name,
        target_system_name,
        toolchain_path_prefix,
        target_toolchain_path_prefix,
        tools_path_prefix,
        wrapper_bin_prefix,
        compiler_configuration,
        compiler_files,
        builtin_include_directory,
        module_map,
        xcode_sysroot,
        sanitizer_runtime_lib,
        extra_known_features,
        extra_enabled_features,
        llvm_version):
    """Declares a darwin `cc_toolchain` from the hermetic LLVM distribution.

    Args:
        name: Name of the generated `cc_toolchain` target.
        target_system_name: The target triple.
        toolchain_path_prefix: Path prefix of the exec LLVM distribution.
        target_toolchain_path_prefix: Path prefix of the target LLVM distribution.
        tools_path_prefix: Path prefix the toolchain binaries live under.
        wrapper_bin_prefix: Path prefix the generated wrappers live under.
        compiler_configuration: The same dict `cc_toolchain_config` takes.
        compiler_files: Label of the filegroup holding the compiler and the
            headers, sysroot and extra files it needs as action inputs.
        builtin_include_directory: Label of the `directory` target for Clang's
            builtin headers, which have to be allowlisted as an include
            directory or Bazel rejects every compile that reaches one.
        module_map: Label of the toolchain's system module map, which
            `layering_check` needs to describe the toolchain and sysroot
            headers.
        xcode_sysroot: Whether `sysroot_path` is the Xcode SDK the repo rule
            detected rather than one the user supplied.
        sanitizer_runtime_lib: Label of the sanitizer runtime dylib to ship
            with sanitized binaries, or None.
        extra_known_features: Extra `cc_feature` labels to make known.
        extra_enabled_features: Extra `cc_feature` labels to enable.
        llvm_version: LLVM version of the distribution, for the resource dir.
    """
    toolchain_path_prefix = paths.ensure_trailing_slash(toolchain_path_prefix)
    target_toolchain_path_prefix = paths.ensure_trailing_slash(target_toolchain_path_prefix)
    tools_path_prefix = paths.ensure_trailing_slash(tools_path_prefix)
    wrapper_bin_prefix = paths.ensure_trailing_slash(wrapper_bin_prefix)

    sysroot_path = compiler_configuration["sysroot_path"]
    if sysroot_path:
        sysroot_path = paths.ensure_trailing_slash(sysroot_path)

    # An Xcode SDK is referred to by placeholder rather than by the path the
    # repo rule found. Bazel sets SDKROOT on every action from its own Xcode
    # configuration -- that is what `apple_env` below asks for -- and the
    # compiler wrapper substitutes it, so the SDK is resolved per action
    # instead of being captured once when the repository was fetched. The
    # difference matters: nothing invalidates this repository when Xcode is
    # upgraded, so a baked path goes stale and every darwin build then fails on
    # a sysroot that is no longer there. A user-supplied sysroot is a real
    # path and is used as-is.
    sysroot_ref = "__BAZEL_XCODE_SDKROOT__/" if xcode_sysroot else sysroot_path

    major_llvm_version = int(llvm_version.split(".")[0])
    resource_dir_version = llvm_version if major_llvm_version < 16 else major_llvm_version
    resource_dir = paths.join(target_toolchain_path_prefix, "lib/clang", str(resource_dir_version))

    # Tools. The compilers are reached through a wrapper that resolves the
    # `__BAZEL_XCODE_*` placeholders; see the wrapper template for why that
    # cannot be a toolchain arg.
    cc_tool(
        name = name + "_clang",
        src = wrapper_bin_prefix + "xcode_clang_wrapper.sh",
        data = [compiler_files],
    )
    cc_tool(
        name = name + "_clang++",
        src = wrapper_bin_prefix + "xcode_clang++_wrapper.sh",
        data = [compiler_files],
    )
    for tool, binary in [
        ("libtool", "libtool"),
        ("cov", "llvm-cov"),
        ("profdata", "llvm-profdata"),
        ("objcopy", "llvm-objcopy"),
        ("strip", "llvm-strip"),
        ("dwp", "llvm-dwp"),
    ]:
        cc_tool(name = name + "_" + tool, src = tools_path_prefix + binary)

    cc_tool_map(
        name = name + "_tools",
        tools = {
            # llvm-libtool-darwin rather than llvm-ar, matching the existing
            # darwin toolchain. `objc-fully-link` is in `ar_actions`, so it is
            # driven by libtool too, which is what it expects.
            _AR: ":" + name + "_libtool",
            "@rules_cc//cc/toolchains/actions:assembly_actions": ":" + name + "_clang",
            "@rules_cc//cc/toolchains/actions:c_compile_actions": ":" + name + "_clang",
            # Covers `cpp_header_parsing` too, which runs the compiler with
            # -fsyntax-only and so writes no output file; the wrapper creates
            # the one Bazel declared.
            _CPP_COMPILE: ":" + name + "_clang++",
            _LINK: ":" + name + "_clang++",
            "@rules_cc//cc/toolchains/actions:llvm_cov": ":" + name + "_cov",
            "@rules_cc//cc/toolchains/actions:llvm_profdata": ":" + name + "_profdata",
            # Objective-C compiles with the same driver and the same flags as
            # C/C++; the language comes from the source extension. Mapping the
            # action here is the whole of "declaring" it -- `objc++-compile` is
            # already inside `cpp_compile_actions` above.
            "@rules_cc//cc/toolchains/actions:objc_compile": ":" + name + "_clang",
            "@rules_cc//cc/toolchains/actions:objcopy_embed_data": ":" + name + "_objcopy",
            "@rules_cc//cc/toolchains/actions:strip": ":" + name + "_strip",
            "@rules_cc//cc/toolchains/actions:dwp": ":" + name + "_dwp",
        },
    )

    # Flags, in the same groups cc_toolchain_config.bzl builds them, minus the
    # ones apple_support already contributes.
    #
    # `-fstack-protector`, `-fno-omit-frame-pointer`, `-fcolor-diagnostics`,
    # `-Wall`, `-Wthread-safety` and `-Wself-assign` are deliberately absent:
    # they are `cc_toolchain_config.bzl`'s default `compile_flags`, and they
    # are also exactly apple_support's `always_compile_flags`, so passing them
    # here only spelled each one twice.
    # The target triple and deployment target are deliberately absent:
    # apple_support's `default_required_flags` passes `-target
    # <arch>-apple-macosx<min-os>` on every compile and link, derived from the
    # target platform and honoring --macos_minimum_os.
    # _FORTIFY_SOURCE is deliberately not touched either: apple_support
    # passes -D_FORTIFY_SOURCE=1 except under asan, where fortify and the
    # sanitizer interfere (https://github.com/google/sanitizers/issues/247) --
    # a better shape than the legacy toolchain's off-everywhere-but-opt.
    compile_flags = [
        "-B" + paths.ensure_trailing_slash(paths.join(toolchain_path_prefix, "bin")),
        "-resource-dir",
        resource_dir,
    ]

    # `-Xclang -fno-cxx-modules`, which layering_check needs under
    # -std=c++20, comes from apple_support, gated on `use_module_maps`.
    cxx_flags = ["-std=" + compiler_configuration["cxx_standard"]]

    # The C++ standard library, following cc_toolchain_config.bzl's `stdlib`
    # handling for a darwin exec and target.
    stdlib = compiler_configuration["stdlib"]
    stdlib_link_flags = []
    stdlib_link_libs = []
    cpp_system_includes = []

    if stdlib in ("builtin-libc++", "libc++"):
        # Use the SDK's libc++ entirely, headers and all. Clang's driver would
        # otherwise auto-include the toolchain's bundled libc++ headers -- the
        # LLVM version we shipped -- against the SDK's libc++.tbd that the
        # sysroot supplies, and the two ABIs do not match. -nostdinc++ turns
        # that auto-detection off so the -cxx-isystem below is the only libc++
        # header path. -stdlib=libc++ is deliberately not passed: it only
        # steers the header search, which -nostdinc++ has already settled, so
        # it would just warn once per object file.
        cpp_system_includes = [paths.join(sysroot_ref, "usr/include/c++/v1")]

        # Several macOS system libraries link libc++ and libc++abi
        # dynamically, so these have to come from the sysroot rather than be
        # statically linked out of the toolchain. The toolchain's own lib
        # directory is deliberately not on the search path: under
        # --spawn_strategy=local ld64 would find dylibs like
        # libunwind.1.dylib there and bake in @rpath install names that do not
        # resolve at run time.
        stdlib_link_flags = [
            "-L" + paths.join(sysroot_ref, "usr/lib"),
            "-Bdynamic",
        ]
        stdlib_link_libs = ["-lc++abi"]
    elif stdlib.startswith("stdc++"):
        stdlib_link_flags = [
            "-L" + paths.join(target_toolchain_path_prefix, "lib"),
            "-L" + paths.join(target_toolchain_path_prefix, "lib", target_system_name),
        ]
        if stdlib.startswith("dynamic-stdc++"):
            stdlib_link_libs = ["-l:libstdc++.so"]
        else:
            stdlib_link_libs = ["-l:libstdc++.a"]
        if stdlib == "stdc++":
            cxx_flags.append("-stdlib=libstdc++")
    elif stdlib == "libc":
        pass
    elif stdlib == "none":
        cxx_flags = ["-nostdlib"]
    else:
        fail("Unknown value passed for stdlib: {}".format(stdlib))

    # A single -nostdinc++ disables Clang's automatic libc++ header detection
    # so the explicit -cxx-isystem entries are the only ones.
    if cpp_system_includes:
        cxx_flags.append("-nostdinc++")
        for include in cpp_system_includes:
            cxx_flags.extend(["-cxx-isystem", include])

    # Clang's builtin headers, searched after the C++ standard library's.
    #
    # `unix_cc_toolchain_config` takes these as `cxx_builtin_include_directories`
    # strings; the rule-based API wants a directory target, so that the same
    # "is this include declared?" check Bazel runs against every translation
    # unit has something to resolve. Without it every compile that reaches
    # stddef.h fails with "undeclared inclusion(s)".
    conly_and_cxx_flags = [
        "-idirafter",
        paths.join(resource_dir, "include"),
    ]

    # `-no-canonical-prefixes`, `-headerpad_max_install_names`,
    # `-fobjc-link-runtime` and `-lc++` are deliberately absent: apple_support's
    # feature list already contributes each of them, earlier in the command
    # line, and repeating them only makes the link line harder to read.
    link_flags = [
        "-fuse-ld=lld",
        "-resource-dir",
        resource_dir,
        # The hermetic linker, rather than whatever clang would find. The path
        # is relative to the execroot, which is the action's working directory
        # -- unlike `tools_path_prefix`, which is relative to this package
        # because `cc_tool` resolves it as a label.
        "--ld-path=" + paths.join(toolchain_path_prefix, "bin", "ld64.lld"),
    ] + (["-lm"] if stdlib != "none" else ["-nostdlib"]) + stdlib_link_flags

    link_libs = list(stdlib_link_libs)

    # llvm-libtool-darwin needs -static spelled out; the preinstalled macOS
    # libtool defaults to it.
    archive_flags = ["-static"]

    # Empty by default: `-no-canonical-prefixes` is in apple_support's
    # `default_required_flags`, and the date-macro redaction is its
    # `unfiltered_compile_flags`, which is the same list
    # `cc_toolchain_config.bzl` defaults to. Kept as a knob for the
    # `unfiltered_compile_flags` / `extra_unfiltered_compile_flags` attributes.
    unfiltered_compile_flags = []

    # `-g` is apple_support's `dbg_compile_flags`, along with `-O0 -DDEBUG`.
    dbg_compile_flags = ["-fstandalone-debug"]
    fastbuild_compile_flags = []

    # `-Wl,--gc-sections` is a GNU ld / lld-ELF flag; ld64 has no equivalent
    # spelling, and cc_toolchain_config.bzl only passes it for linux.
    opt_link_flags = []

    # LLVM instrumentation, which is what cc_toolchain_config.bzl passes and
    # what the toolchain's `gcov` (llvm-profdata) can read. Applied whenever
    # the `coverage` feature is on, rather than only when Bazel happens to pick
    # `llvm_coverage_map_format`: left to apple_support alone, a plain
    # `--collect_code_coverage` selects the *gcc* format and instruments with
    # -fprofile-arcs/-ftest-coverage instead.
    coverage_compile_flags = ["-fprofile-instr-generate", "-fcoverage-mapping"]
    coverage_link_flags = ["-fprofile-instr-generate"]

    # `-g0 -O2 -DNDEBUG` are apple_support's `opt_compile_flags`. The
    # remainder of this repo's documented default is dropped rather than kept:
    # the fortify level is apple_support's business now (see compile_flags),
    # and `-ffunction-sections -fdata-sections` pair with `-Wl,--gc-sections`
    # on ELF and do nothing for `ld64`, whose equivalent is the `-dead_strip`
    # apple_support already passes in opt.
    opt_compile_flags = []

    # User overrides and additions, exactly as cc_toolchain_config.bzl applies
    # them: a non-None `<key>` in the configuration replaces the default list,
    # `extra_<key>` appends to it.
    flags = {
        "archive_flags": archive_flags,
        "compile_flags": compile_flags,
        "conly_flags": [],
        "coverage_compile_flags": coverage_compile_flags,
        "coverage_link_flags": coverage_link_flags,
        "cxx_flags": cxx_flags,
        "dbg_compile_flags": dbg_compile_flags,
        "fastbuild_compile_flags": fastbuild_compile_flags,
        "link_flags": link_flags,
        "link_libs": link_libs,
        "opt_compile_flags": opt_compile_flags,
        "opt_link_flags": opt_link_flags,
        "unfiltered_compile_flags": unfiltered_compile_flags,
    }
    for key in flags.keys():
        override = compiler_configuration.get(key)
        if override != None:
            flags[key] = _fmt_flags(override, toolchain_path_prefix)
        extra = compiler_configuration.get("extra_" + key)
        if extra != None:
            flags[key] = flags[key] + _fmt_flags(extra, toolchain_path_prefix)

    # The sysroot feature apple_support's macro takes. It has to be a feature
    # named "sysroot" so it lands where the macro places it in the arg order.
    # An Xcode SDK needs no allowlist entry here: apple_support's
    # `include_directories_from_xcode` already allowlists the directories Xcode
    # and the command line tools are installed in, and unlike a path pinned to
    # today's SDK version it keeps matching when Xcode is upgraded.
    sysroot_args = _args(
        name + "_sysroot_args",
        [_COMPILE, _LINK],
        ["-isysroot", sysroot_ref.rstrip("/")] if sysroot_ref else [],
        allowlist_absolute_include_directories = (
            [] if xcode_sysroot else [sysroot_path.rstrip("/")] if sysroot_path.startswith("/") else []
        ),
    )
    cc_feature(
        name = name + "_sysroot",
        args = sysroot_args,
        feature_name = "sysroot",
    )

    # Everything else, in one always-on feature injected through the macro's
    # extra_enabled_features. Ordering within the feature is the list order.
    args = []
    args += _args(name + "_compile_args", [_COMPILE], flags["compile_flags"])
    args += _args(name + "_conly_args", ["@rules_cc//cc/toolchains/actions:c_compile"], flags["conly_flags"])
    args += _args(name + "_cxx_args", [_CPP_COMPILE], flags["cxx_flags"])
    args += _args(
        name + "_builtin_include_args",
        [_COMPILE],
        conly_and_cxx_flags,
        allowlist_include_directories = [builtin_include_directory],
    )
    args += _args(name + "_link_args", [_LINK], flags["link_flags"])
    args += _args(name + "_archive_args", [_AR], flags["archive_flags"])
    args += _args(name + "_unfiltered_args", [_COMPILE], flags["unfiltered_compile_flags"])

    # Compilation-mode flags. `dbg`/`opt`/`fastbuild` are the standard feature
    # names, and the args are gated on them rather than select()ed so that they
    # compose with --compilation_mode the way the legacy toolchain's did.
    args += _args(
        name + "_dbg_args",
        [_COMPILE],
        flags["dbg_compile_flags"],
        requires_any_of = ["@apple_support//toolchain:dbg"],
    )
    args += _args(
        name + "_fastbuild_args",
        [_COMPILE],
        flags["fastbuild_compile_flags"],
        requires_any_of = ["@apple_support//toolchain:fastbuild"],
    )
    args += _args(
        name + "_opt_args",
        [_COMPILE],
        flags["opt_compile_flags"],
        requires_any_of = ["@apple_support//toolchain:opt"],
    )
    args += _args(
        name + "_opt_link_args",
        [_LINK],
        flags["opt_link_flags"],
        requires_any_of = ["@apple_support//toolchain:opt"],
    )

    # Sanitizers. apple_support already declares `asan`, `tsan` and `ubsan` and
    # contributes the bare `-fsanitize=` flag for each, so what is left is the
    # augmentation cc_toolchain_config.bzl applies on top:
    #
    #   -fsanitize-link-c++-runtime  a plain `-fsanitize=` does not pull in
    #                                Clang's C++ sanitizer runtime, so C++
    #                                programs fail to link (ubsan's vptr
    #                                handlers, __ubsan_*_type_cache, ...).
    #   -fsanitize=bounds,           checks that are not in ubsan's default
    #   -fsanitize=nullability       `undefined` group.
    #
    # Gated on the same //toolchain/config settings the legacy toolchain uses,
    # which match `--features`, so the exec configuration resets them along
    # with the sanitizer features themselves and build tools stay
    # uninstrumented. Each select() keys on exactly one setting: sanitizers
    # combine, so a select() keyed on several would be an ambiguous match as
    # soon as two are enabled together (#777).
    cc_args(
        name = name + "_sanitizer_link_args",
        actions = [_LINK],
        args = select({
            str(Label("//toolchain/config:use_common_sanitizer")): ["-fsanitize-link-c++-runtime"],
            "//conditions:default": [],
        }) + select({
            str(Label("//toolchain/config:use_ubsan")): [
                "-fsanitize=bounds",
                "-fsanitize=nullability",
            ],
            "//conditions:default": [],
        }),
    )
    cc_args(
        name = name + "_sanitizer_compile_args",
        actions = [_COMPILE],
        args = select({
            str(Label("//toolchain/config:use_ubsan")): [
                "-fsanitize=bounds",
                "-fsanitize=nullability",
            ],
            "//conditions:default": [],
        }),
    )
    args += [":" + name + "_sanitizer_compile_args", ":" + name + "_sanitizer_link_args"]

    # LeakSanitizer, which apple_support does not declare. Standalone LSan is
    # not supported on darwin, but the feature has to exist for `--features=lsan`
    # to mean anything, and `unix_cc_toolchain_config` declares it on every
    # platform.
    cc_args(
        name = name + "_lsan_args",
        actions = [_COMPILE, _LINK],
        args = ["-fsanitize=leak"],
    )
    cc_feature(
        name = name + "_lsan",
        args = [":" + name + "_lsan_args"],
        feature_name = "lsan",
    )

    # Coverage, gated on the same `coverage` feature `--collect_code_coverage`
    # turns on.
    args += _args(
        name + "_coverage_compile_args",
        [_COMPILE],
        flags["coverage_compile_flags"],
        requires_any_of = ["@apple_support//toolchain/coverage:coverage"],
    )
    args += _args(
        name + "_coverage_link_args",
        [_LINK],
        flags["coverage_link_flags"],
        requires_any_of = ["@apple_support//toolchain/coverage:coverage"],
    )

    # Link libs come last so unused symbols are not stripped before the
    # archives that need them are seen.
    args += _args(name + "_link_libs", [_LINK], flags["link_libs"])

    cc_feature(
        name = name + "_toolchain_feature",
        args = args,
        feature_name = name + "_toolchain_flags",
    )

    # On macOS the sanitizer runtimes are dynamic-only: Clang links sanitized
    # binaries against `@rpath/libclang_rt.<san>_osx_dynamic.dylib`, which has
    # to be findable when the binary runs from its runfiles. The dylib is
    # exposed through `dynamic_runtime_lib`, which Bazel only consults when
    # `static_link_cpp_runtimes` is enabled -- so enable it transitively, and
    # only when a sanitizer is on, so ordinary builds are unaffected.
    runtime_features = []
    if sanitizer_runtime_lib:
        # `static_link_cpp_runtimes` is only *declared* by rules_cc, as a
        # feature something else is expected to define; `unix_cc_toolchain_config`
        # is what defined it for the legacy toolchains, and nothing in this one
        # does. Define it here so it can be implied.
        cc_feature(
            name = name + "_static_link_cpp_runtimes",
            overrides = "@rules_cc//cc/toolchains/features:static_link_cpp_runtimes",
        )
        cc_feature(
            name = name + "_sanitizer_runtime_runfiles",
            feature_name = name + "_sanitizer_runtime_runfiles",
            implies = [":" + name + "_static_link_cpp_runtimes"],
        )

        # Bazel insists on a static_runtime_lib once static_link_cpp_runtimes
        # is known; there is no static C++ runtime to ship on macOS.
        native.filegroup(name = name + "_empty_runtime_lib", srcs = [])
        runtime_features = select({
            str(Label("//toolchain/config:use_common_sanitizer")): [
                ":" + name + "_sanitizer_runtime_runfiles",
            ],
            "//conditions:default": [],
        })

    cc_feature_set(
        name = name + "_enabled_features",
        all_of = [":" + name + "_toolchain_feature"] + extra_enabled_features + runtime_features,
    )
    cc_feature_set(
        name = name + "_known_features",
        all_of = ([
            ":" + name + "_static_link_cpp_runtimes",
        ] if sanitizer_runtime_lib else []) + [
            ":" + name + "_lsan",
        ] + extra_known_features,
    )

    _apple_cc_toolchain(
        name = name,
        # The toolchain sets its own C++ standard; the target triple and
        # deployment target come from apple_support, derived from the target
        # platform. Its compiler wrapper speaks wrapped_clang's
        # argument protocol -- the `__BAZEL_*` placeholders and the
        # LINKED_BINARY=/DSYM_HINT_DSYM_PATH=/STRIP_DEBUG_SYMBOLS sentinels --
        # so the Apple-side args go through unchanged.
        extra_enabled_features = ":" + name + "_enabled_features",
        extra_known_features = ":" + name + "_known_features",
        # Drops the link flags the bundled `ld64.lld` predates -- verified
        # against 17.0.6, 18.1.8 and 19.1.7.
        llvm_version = llvm_version,
        # The coverage instrumentation comes from `coverage_compile_flags`
        # above; apple_support would otherwise contribute a second, gcc-format
        # set alongside it.
        coverage_instrumentation = False,
        dynamic_runtime_lib = sanitizer_runtime_lib,
        static_runtime_lib = (":" + name + "_empty_runtime_lib") if sanitizer_runtime_lib else None,
        flags_from_env = False,
        module_map = module_map,
        supports_header_parsing = True,
        sysroot_feature = ":" + name + "_sysroot",
        target = target_system_name,
        tool_map = ":" + name + "_tools",
    )
