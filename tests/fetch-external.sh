#!/usr/bin/env bash
# Downloads the EXTERNAL test corpora into tests/external/ (gitignored).
# These are NOT distributed with this repository.
#
# For the C front end — must-not-compile corpora:
#   - gcc.dg/noncompile  (GCC testsuite, GPL)
#   - clang test/Sema + test/Parser (Apache-2.0 WITH LLVM-exception) —
#     diagnostic edge-case corpus (expected-error annotated)
#
# For pscript — CONFORMANCE corpora, the ones that measure whether the runtime
# agrees with the world instead of with itself (tests/conformance/):
#   - nst/JSONTestSuite (MIT) — 318 files, the name carries the verdict
#   - nodejs/llhttp (MIT) — 155 HTTP fixtures, input plus expected events
#   - web-platform-tests url/resources (BSD-3) — 891 URL cases
#   - http2jp/hpack-test-case (MIT) — 47 142 HPACK vectors from 14 encoders
#   - tc39/test262 built-ins/Promise (BSD-3) — read, not run: the source of the
#     ordering cases hand-ported into tests/conformance/promise/
#
# The vendored MIT corpus (tests/wacct/) ships with the repo; this script only
# fetches the reference corpora used for local scoreboards and conformance.
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

# ---------- pscript conformance corpora ----------

# nst/JSONTestSuite (MIT): the file NAME is the verdict — y_ must be accepted,
# n_ must be refused, i_ is the implementation's call but has to be recorded.
if [ ! -d external/jsontestsuite ] || [ -z "$(ls external/jsontestsuite 2>/dev/null)" ]; then
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/nst/JSONTestSuite.git "$tmp"
    mkdir -p external/jsontestsuite
    cp -r "$tmp"/test_parsing external/jsontestsuite/
    cp "$tmp"/LICENSE external/jsontestsuite/ 2>/dev/null || true
    git -C "$tmp" rev-parse HEAD > external/jsontestsuite/.commit
    rm -rf "$tmp"
fi

# nodejs/llhttp (MIT): markdown fixtures — an ```http block in, an ```log block
# of expected events out. The corpus behind the C parser Node itself runs.
if [ ! -d external/llhttp ] || [ -z "$(ls external/llhttp 2>/dev/null)" ]; then
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/nodejs/llhttp.git "$tmp"
    mkdir -p external/llhttp
    cp -r "$tmp"/test/request "$tmp"/test/response external/llhttp/
    cp "$tmp"/test/url.md external/llhttp/ 2>/dev/null || true
    cp "$tmp"/LICENSE-MIT external/llhttp/ 2>/dev/null || cp "$tmp"/LICENSE external/llhttp/ 2>/dev/null || true
    git -C "$tmp" rev-parse HEAD > external/llhttp/.commit
    rm -rf "$tmp"
fi

# web-platform-tests (BSD-3): the URL corpus every browser is measured against.
# http2jp/hpack-test-case (MIT): 47 142 vectors, `story_NN.json` per encoder.
# The cases of one story share a dynamic table, which is what makes it measure
# eviction instead of only the happy path.
if [ ! -d external/hpack ] || [ -z "$(ls external/hpack 2>/dev/null)" ]; then
    tmp=$(mktemp -d)
    git clone --depth 1 https://github.com/http2jp/hpack-test-case.git "$tmp"
    mkdir -p external/hpack
    for d in "$tmp"/*/; do
        [ -f "$d/story_00.json" ] || continue
        cp -r "$d" external/hpack/
    done
    cp "$tmp"/LICENSE external/hpack/ 2>/dev/null || true
    git -C "$tmp" rev-parse HEAD > external/hpack/.commit
    rm -rf "$tmp"
fi
if [ ! -d external/wpt-url ] || [ -z "$(ls external/wpt-url 2>/dev/null)" ]; then
    tmp=$(mktemp -d)
    git clone --depth 1 --filter=blob:none --sparse https://github.com/web-platform-tests/wpt.git "$tmp"
    git -C "$tmp" sparse-checkout set --no-cone /url
    mkdir -p external/wpt-url
    cp "$tmp"/url/resources/urltestdata.json external/wpt-url/
    cp "$tmp"/url/resources/setters_tests.json external/wpt-url/ 2>/dev/null || true
    cp "$tmp"/LICENSE.md external/wpt-url/ 2>/dev/null || true
    git -C "$tmp" rev-parse HEAD > external/wpt-url/.commit
    rm -rf "$tmp"
fi

# tc39/test262 (BSD-3): fetched to be READ, not run. Of 732 Promise tests only
# 115 avoid the JS object model entirely, and those are `.then` callbacks — so
# what lives in tests/conformance/promise/ is a hand port of the ORDERING cases,
# and this checkout is what lets anyone check the port against the original.
if [ ! -d external/test262-promise ] || [ -z "$(ls external/test262-promise 2>/dev/null)" ]; then
    tmp=$(mktemp -d)
    git clone --depth 1 --filter=blob:none --sparse https://github.com/tc39/test262.git "$tmp"
    git -C "$tmp" sparse-checkout set --no-cone /test/built-ins/Promise
    mkdir -p external/test262-promise
    cp -r "$tmp"/test/built-ins/Promise/* external/test262-promise/
    cp "$tmp"/LICENSE external/test262-promise/ 2>/dev/null || true
    git -C "$tmp" rev-parse HEAD > external/test262-promise/.commit
    rm -rf "$tmp"
fi

echo "external corpora ready: $(ls external)"
