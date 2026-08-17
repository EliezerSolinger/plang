#!/usr/bin/env bash
# tests/conformance/run.sh — the corpora the rest of the world wrote.
#
#   bash tests/conformance/run.sh            # everything
#   bash tests/conformance/run.sh json url   # just those
#
# The other suites in this repo measure pscript against ITSELF: a program, an
# expected output, and whoever wrote both was the same person. These measure it
# against corpora written by people who never heard of this language, for
# implementations that had to interoperate. That is a different kind of
# evidence, and it is the only kind that catches a whole family of "we were
# consistently wrong".
#
#   json  — nst/JSONTestSuite (MIT), 318 documents. The file NAME is the
#           verdict: y_ must be accepted, n_ must be refused, i_ is left open by
#           RFC 8259 and is pinned here so a change of mind shows up as a diff.
#   http  — nodejs/llhttp (MIT), the fixtures behind the parser node itself
#           runs. Untrusted bytes off a socket: the most exposed code we have.
#   url   — web-platform-tests (BSD-3), 891 cases, the corpus every browser is
#           measured on. 267 of them exist to be REFUSED.
#
# GATING, like tests/clang-compare.sh: a single unexplained disagreement fails.
# What we knowingly do not do lives in `<corpus>.skips`, one line each with the
# reason — counted and printed, never folded into the score.
set -u
cd "$(dirname "$0")/../.."

EXT=tests/external
OUT=tests/out/conformance
CONF=tests/conformance
FAIL=0
mkdir -p "$OUT"

have() { [ -d "$EXT/$1" ] && [ -n "$(ls "$EXT/$1" 2>/dev/null)" ]; }
bad()  { printf '   \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
skip() { printf '   \033[33m--\033[0m %s\n' "$1"; }

build() {
    if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh "$CONF/$1.psc" "$OUT/$1" >"$OUT/$1.build" 2>&1; then
        bad "$1: did not build — see $OUT/$1.build"
        return 1
    fi
}

run_json() {
    printf '\n\033[1m== json — nst/JSONTestSuite ==\033[0m\n'
    have jsontestsuite || { skip "no corpus (bash tests/fetch-external.sh)"; return; }
    build json_conform || return
    ls "$EXT"/jsontestsuite/test_parsing/*.json | sort > "$OUT/json.manifest"
    if ! "$OUT/json_conform" "$OUT/json.manifest" > "$OUT/json.raw" 2>&1; then
        bad "json: the driver died — a corpus file must never crash the parser"
        return
    fi
    sed "s|$EXT/jsontestsuite/test_parsing/||" "$OUT/json.raw" | sort -k2 > "$OUT/json.got"
    if diff -u "$CONF/json.expected" "$OUT/json.got" > "$OUT/json.diff"; then
        printf '   \033[32mOK\033[0m %s documents, every verdict as recorded\n' "$(wc -l < "$OUT/json.got" | tr -d ' ')"
    else
        bad "json: $(grep -c '^[+-][^+-]' "$OUT/json.diff") verdicts differ — see $OUT/json.diff"
    fi
}

run_http() {
    printf '\n\033[1m== http — nodejs/llhttp ==\033[0m\n'
    have llhttp || { skip "no corpus (bash tests/fetch-external.sh)"; return; }
    python3 "$CONF/llhttp_digest.py" "$EXT/llhttp" > "$OUT/http.want" 2> "$OUT/http.digest" || {
        bad "http: could not read the fixtures — see $OUT/http.digest"; return; }
    build http_conform || return
    if ! "$OUT/http_conform" "$OUT/http.want" > "$OUT/http.got" 2>&1; then
        bad "http: the driver died"
        return
    fi
    python3 "$CONF/compare.py" http "$OUT/http.want" "$OUT/http.got" "$CONF/http.skips" || FAIL=1
}

run_url() {
    printf '\n\033[1m== url — web-platform-tests ==\033[0m\n'
    have wpt-url || { skip "no corpus (bash tests/fetch-external.sh)"; return; }
    python3 "$CONF/wpt_url_digest.py" "$EXT/wpt-url/urltestdata.json" > "$OUT/url.want" 2> "$OUT/url.digest" || {
        bad "url: could not read the corpus — see $OUT/url.digest"; return; }
    build url_conform || return
    if ! "$OUT/url_conform" "$OUT/url.want" > "$OUT/url.got" 2>&1; then
        bad "url: the driver died"
        return
    fi
    python3 "$CONF/compare.py" url "$OUT/url.want" "$OUT/url.got" "$CONF/url.skips" || FAIL=1
}

for s in ${*:-json http url}; do
    case $s in
        json) run_json ;;
        http) run_http ;;
        url)  run_url ;;
        *) echo "unknown corpus '$s' (json|http|url)"; exit 2 ;;
    esac
done

echo
[ $FAIL = 0 ] && printf '\033[1;32m✔ conformance passed\033[0m\n' || printf '\033[1;31m✘ conformance failed\033[0m\n'
exit $FAIL
