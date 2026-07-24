#!/usr/bin/env bash
# Downloads the EXTERNAL error-test corpora into tests/external/ (gitignored).
# These are NOT distributed with this repository:
#   - gcc.dg/noncompile  (GCC testsuite, GPL) — must-not-compile C corpus
#   - clang test/Sema + test/Parser (Apache-2.0 WITH LLVM-exception) —
#     diagnostic edge-case corpus (expected-error annotated)
# The vendored MIT corpus (tests/wacct/) ships with the repo; this script only
# fetches the reference corpora used for local scoreboards.
set -eu
cd "$(dirname "$0")"
mkdir -p external
if [ ! -d external/gcc-noncompile ] || [ -z "$(ls external/gcc-noncompile 2>/dev/null)" ]; then
    tmp=$(mktemp -d)
    git clone --depth 1 --filter=blob:none --sparse https://github.com/gcc-mirror/gcc.git "$tmp"
    git -C "$tmp" sparse-checkout set --no-cone /gcc/testsuite/gcc.dg/noncompile
    mkdir -p external/gcc-noncompile
    cp "$tmp"/gcc/testsuite/gcc.dg/noncompile/* external/gcc-noncompile/
    git -C "$tmp" rev-parse HEAD > external/gcc-noncompile/.commit
    rm -rf "$tmp"
fi
if [ ! -d external/clang-sema ] || [ -z "$(ls external/clang-sema 2>/dev/null)" ]; then
    tmp=$(mktemp -d)
    git clone --depth 1 --filter=blob:none --sparse https://github.com/llvm/llvm-project.git "$tmp"
    git -C "$tmp" sparse-checkout set --no-cone /clang/test/Sema /clang/test/Parser
    mkdir -p external/clang-sema external/clang-parser
    cp "$tmp"/clang/test/Sema/*.c external/clang-sema/ 2>/dev/null || true
    cp "$tmp"/clang/test/Parser/*.c external/clang-parser/ 2>/dev/null || true
    git -C "$tmp" rev-parse HEAD > external/clang-sema/.commit
    rm -rf "$tmp"
fi
echo "external corpora ready: $(ls external)"
