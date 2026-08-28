#!/bin/bash
# Copyright 2026 The Bazel Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Resolves the Xcode path placeholders Bazel's Objective-C support bakes into
# build variables, then execs the real compiler.
#
# `objc_library(sdk_includes = ["CommonCrypto"])` becomes
# `-I__BAZEL_XCODE_SDKROOT__/usr/include/CommonCrypto` in rules_cc's
# objc_common.bzl, by way of `apple_common.apple_toolchain().sdk_dir()`, and the
# framework import rules in rules_apple emit the same placeholder. The value
# reaches the toolchain through a build variable, not a copt, so no toolchain
# argument can rewrite it -- only something sitting between Bazel and clang can.
# apple_support does this inside `wrapped_clang`, which is not reusable here: it
# always runs `/usr/bin/xcrun clang` against an Xcode installation and cannot be
# pointed at a hermetic compiler.
#
# SDKROOT and DEVELOPER_DIR are put in the environment by Bazel itself:
# apple_support's `apple_env` sets XCODE_VERSION_OVERRIDE and APPLE_SDK_PLATFORM
# on every action, which is what makes Bazel's XcodeLocalEnvProvider inject
# them. A placeholder whose variable is unset is left alone, so the compiler
# complains about the placeholder rather than about a path assembled from
# nothing.

set -euo pipefail

compiler="%{compiler}"
toolchain_path_prefix="%{toolchain_path_prefix}"
dsymutil="%{dsymutil}"
strip="%{strip}"

# Header parsing runs with -fsyntax-only, which writes nothing, but Bazel
# declared an output for the action and fails it if the file is missing. The
# toolchain passes the path through the environment for exactly this reason;
# apple_support's wrapped_clang does the same.
function finish() {
  if [[ -n ${HEADER_PARSING_OUTPUT:-} ]]; then
    : >"${HEADER_PARSING_OUTPUT}"
  fi
}

# The canonical execution root, computed once and only when something asks for
# it: `pwd -P` resolves the symlinks Bazel's output base is reached through.
canonical_root=""

function resolve() {
  local value="$1"
  # The execution root, which is this process's working directory. Used by the
  # debug-prefix-map, coverage-prefix-map and -oso_prefix args, all of which
  # exist to keep absolute paths out of build outputs.
  if [[ ${value} == *__BAZEL_EXECUTION_ROOT_CANONICAL__* ]]; then
    if [[ -z ${canonical_root} ]]; then
      canonical_root="$(pwd -P)"
    fi
    value="${value//__BAZEL_EXECUTION_ROOT_CANONICAL__/${canonical_root}}"
  fi
  value="${value//__BAZEL_EXECUTION_ROOT__/${PWD}}"
  if [[ -n ${SDKROOT:-} ]]; then
    value="${value//__BAZEL_XCODE_SDKROOT__/${SDKROOT}}"
  fi
  if [[ -n ${DEVELOPER_DIR:-} ]]; then
    value="${value//__BAZEL_XCODE_DEVELOPER_DIR__/${DEVELOPER_DIR}}"
  fi
  printf "%s" "${value}"
}

cleanup_files=()
function cleanup() {
  if [[ ${#cleanup_files[@]} -gt 0 ]]; then
    rm -f "${cleanup_files[@]}"
  fi
}
trap cleanup EXIT

# Some of the toolchain's args are not compiler flags but sentinels: they
# stand for work the tool wrapping the compiler is expected to do, the way
# apple_support's `wrapped_clang` does. Each one has to be dropped from the
# command line wherever it appears -- clang would read it as an input
# filename -- including from inside a params file, which is where the linker's
# arguments actually live.
#
#   LINKED_BINARY=<path>       names the output of a link action, for the
#                              dsymutil, strip and rpath steps below.
#   DSYM_HINT_DSYM_PATH=<path> says where Bazel wants the debug bundle written.
#   STRIP_DEBUG_SYMBOLS        asks for the linked binary to be stripped of
#                              debug symbols after linking (and after dsymutil,
#                              which needs them).
linked_binary=""
dsym_path=""
strip_debug_symbols=false

function consume_sentinel() {
  case "$1" in
    LINKED_BINARY=*)
      linked_binary="${1#LINKED_BINARY=}"
      return 0
      ;;
    DSYM_HINT_DSYM_PATH=*)
      dsym_path="${1#DSYM_HINT_DSYM_PATH=}"
      return 0
      ;;
    STRIP_DEBUG_SYMBOLS)
      strip_debug_symbols=true
      return 0
      ;;
  esac
  return 1
}

# `args` is what the compiler is invoked with; `flat` is every option with the
# params files expanded, which is where `-o` actually lives on a link action.
args=()
flat=()
for arg in "$@"; do
  if [[ ${arg} == @* && -r ${arg:1} ]]; then
    # A params file. Rewrite it into a temporary copy rather than in place: the
    # original is a Bazel-owned action input.
    tmpfile="$(mktemp)"
    cleanup_files+=("${tmpfile}")
    while IFS= read -r line; do
      resolved="$(resolve "${line}")"
      if consume_sentinel "${resolved}"; then
        continue
      fi
      printf "%s\n" "${resolved}" >>"${tmpfile}"
      flat+=("${resolved}")
    done <"${arg:1}"
    args+=("@${tmpfile}")
  else
    resolved="$(resolve "${arg}")"
    if consume_sentinel "${resolved}"; then
      continue
    fi
    args+=("${resolved}")
    flat+=("${resolved}")
  fi
done

# The link output, for the dsymutil, strip and rpath steps below. LINKED_BINARY
# names it on every Bazel link action; falling back to `-o` covers a direct
# `cc_common` caller that provides no `output_execpath`, the same case
# apple_support's `wrapped_clang` tolerates.
output="${linked_binary}"
if [[ -z ${output} ]]; then
  next_is_output=false
  for arg in "${flat[@]}"; do
    if [[ ${next_is_output} == true ]]; then
      output="${arg}"
      next_is_output=false
    elif [[ ${arg} == "-o" ]]; then
      next_is_output=true
    fi
  done
fi

"${compiler}" "${args[@]}"
finish

# Debug info on macOS stays in the object files, reached through the OSO stabs
# in the linked binary; a .dSYM bundle is what collects it into one artifact.
# Bazel declares the bundle as an output of the link action, so without this it
# would be created empty and the build would still succeed -- debug info that
# silently is not there.
if [[ -n ${dsym_path} && -n ${output} && -f ${output} ]]; then
  dsymutil_args=("${output}" "-o" "${dsym_path}" "--no-swiftmodule-timestamp")
  # A path that already names a bundle gets one; anything else is asked for
  # flat, matching what apple_support's wrapped_clang does.
  if [[ ${dsym_path} != *.dSYM ]]; then
    dsymutil_args+=("--flat")
  fi
  "${dsymutil}" "${dsymutil_args[@]}"
fi

# STRIP_DEBUG_SYMBOLS is how Bazel strips at link time (fastbuild does this by
# default); wrapped_clang answers it with `strip -S` after the dSYM is made,
# since stripping first would leave dsymutil nothing to collect. llvm-strip's
# --strip-debug is the same operation, from the bundled tools.
if [[ ${strip_debug_symbols} == true && -n ${output} && -f ${output} ]]; then
  "${strip}" --strip-debug "${output}"
fi

# Sanitizer runtimes on macOS are dynamic-only: Clang links sanitized binaries
# against `@rpath/libclang_rt.<san>_osx_dynamic.dylib` and adds a
# *toolchain-relative* LC_RPATH, which only resolves while the working
# directory is the execroot -- true at link time, but not when a test runs from
# its runfiles, where the dylib is then "not loaded". Add an
# `@loader_path`-relative LC_RPATH to the toolchain's compiler-rt directory so
# `@rpath` resolves whatever the working directory is: no absolute paths (which
# break the sandbox) and no copying the dylib into runfiles. Only for the
# hermetic (relative-prefix) toolchain; a system toolchain's runtime is found
# at its absolute location.
if [[ ${toolchain_path_prefix} != /* ]] && [[ -n ${output} && -f ${output} ]]; then
  if /usr/bin/otool -L "${output}" 2>/dev/null | grep -q '@rpath/libclang_rt\.'; then
    output_dir="$(dirname "${output}")"
    # One `../` per component of the output's directory climbs from
    # `@loader_path` back to the execroot, which is also where `external/...`
    # (the toolchain) lives.
    loader_to_execroot=""
    IFS='/' read -ra output_parts <<<"${output_dir}"
    for _part in "${output_parts[@]}"; do
      loader_to_execroot="../${loader_to_execroot}"
    done
    for darwin_dir in "${toolchain_path_prefix}"lib/clang/*/lib/darwin; do
      [[ -d ${darwin_dir} ]] || continue
      /usr/bin/install_name_tool -add_rpath \
        "@loader_path/${loader_to_execroot}${darwin_dir}" "${output}" 2>/dev/null || true
    done
  fi
fi
