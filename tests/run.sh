#!/usr/bin/env bash
# tests/run.sh — the single test driver for plang.
#
#   bash tests/run.sh [suite ...]        default: all suites
#
# suites:
#   cases     end-to-end P programs (tests/cases/*.p; stdout vs .expected)
#   modules   multi-module build (.ph header + two TUs linked together)
#   stl       the header-only STL exercised end to end
#   p-suite   c-testsuite ported to P, 1:1 (exit 0 + stdout == .expected)
#   c-suite   the vendored c-testsuite through the C frontend (scoreboard;
#             informational — it measures C-frontend coverage, doesn't gate)
#
# env:
#   PLANGC=./plangc   compiler under test        CC=cc      target C compiler
#   BACKEND=c|qbe     codegen path (default c)   STD=c89    strict-C89 mode (C backend)
#
# All artifacts land in tests/out/ (gitignored). Exit status is non-zero if
# any gating suite fails.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-./plangc}
CC=${CC:-cc}
BACKEND=${BACKEND:-c}
STD=${STD:-}
OUT=tests/out
QBE=qbe/qbe

# ---------- setup ----------
[ -x "$PLANGC" ] || { echo "building compiler ($PLANGC missing)..."; make >/dev/null || exit 1; }
if [ "$BACKEND" = qbe ] && [ ! -x "$QBE" ]; then
    echo "building vendored qbe..."
    make -C qbe >/dev/null 2>&1 || { echo "error: could not build qbe/"; exit 1; }
fi

PFLAGS=""; CSTD="-std=c11"
if [ "$STD" = c89 ]; then
    [ "$BACKEND" = c ] || { echo "error: STD=c89 only applies to BACKEND=c"; exit 1; }
    PFLAGS="--std=c89 --i64-longlong"   # long long: the one extension the suite needs
    CSTD="-std=gnu89"
fi

rm -rf "$OUT"
mkdir -p "$OUT"/cases "$OUT"/mod "$OUT"/psuite "$OUT"/csuite

total_fail=0

# compile one P (or preprocessed C) source to a binary via the chosen backend.
# usage: build_bin <src> <bin> <errfile> [extra cc flags...]
build_bin() {
    local src=$1 bin=$2 err=$3; shift 3
    if [ "$BACKEND" = qbe ]; then
        $PLANGC --backend qbe "$src" -o "$bin.ssa" 2>"$err" &&
        $QBE "$bin.ssa" -o "$bin.s" 2>>"$err" &&
        $CC "$bin.s" -o "$bin" "$@" -lm 2>>"$err"
    else
        $PLANGC $PFLAGS "$src" -o "$bin.c" 2>"$err" &&
        $CC $CSTD -w "$bin.c" -o "$bin" "$@" -lm 2>>"$err"
    fi
}

# run a compiled test: exit 0 and stdout == expected file (when it exists).
# The binary runs with cwd INSIDE tests/out (its own dir), so tests that do
# file I/O (the c-testsuite writes e.g. fred.txt) never litter the repo root.
# usage: check_run <bin> <expected> <name>  -> 0 ok / 1 fail (message printed)
ROOT=$PWD
check_run() {
    local bin=$1 exp=$2 name=$3
    ( cd "$(dirname "$bin")" && "$ROOT/$bin" >"$ROOT/$bin.out" 2>/dev/null )
    local rc=$?
    if [ $rc -ne 0 ]; then echo "  FAIL $name (exit $rc)"; return 1; fi
    if [ -f "$exp" ] && ! diff -q "$exp" "$bin.out" >/dev/null; then
        echo "  FAIL $name (output differs; see $bin.out)"; return 1
    fi
    return 0
}

# ---------- suites ----------
suite_cases() {
    echo "== cases (end-to-end P) =="
    local pass=0 fail=0 src name bin
    for src in tests/cases/*.p; do
        name=$(basename "$src" .p); bin=$OUT/cases/$name
        if build_bin "$src" "$bin" "$bin.err" && check_run "$bin" "tests/cases/$name.expected" "$name"; then
            pass=$((pass+1))
        else
            [ -s "$bin.err" ] && sed 's/^/       /' "$bin.err" | head -3
            fail=$((fail+1))
        fi
    done
    echo "   cases: $pass ok, $fail failed"
    total_fail=$((total_fail+fail))
}

suite_modules() {
    echo "== modules (multi-TU) =="
    local d=$OUT/mod err=$OUT/mod/err
    if [ "$BACKEND" = qbe ]; then
        $PLANGC tests/modules/geometria.ph -o "$d/geometria.h" 2>"$err" &&
        $PLANGC --backend qbe tests/modules/geometria.p -o "$d/geometria.ssa" 2>>"$err" &&
        $PLANGC --backend qbe tests/modules/main.p -o "$d/main.ssa" 2>>"$err" &&
        $QBE "$d/geometria.ssa" -o "$d/geometria.s" 2>>"$err" &&
        $QBE "$d/main.ssa" -o "$d/main.s" 2>>"$err" &&
        $CC "$d/main.s" "$d/geometria.s" -o "$d/main" 2>>"$err"
    else
        $PLANGC $PFLAGS tests/modules/geometria.ph -o "$d/geometria.h" 2>"$err" &&
        $PLANGC $PFLAGS tests/modules/geometria.p -o "$d/geometria.c" 2>>"$err" &&
        $PLANGC $PFLAGS tests/modules/main.p -o "$d/main.c" 2>>"$err" &&
        $CC $CSTD -w -I"$d" "$d/main.c" "$d/geometria.c" -o "$d/main" 2>>"$err"
    fi
    if [ -x "$d/main" ] && check_run "$d/main" tests/modules/main.expected modules; then
        echo "   modules: ok"
    else
        [ -s "$err" ] && sed 's/^/       /' "$err" | head -3
        echo "   modules: FAILED"; total_fail=$((total_fail+1))
    fi
}

suite_stl() {
    echo "== stl (header-only library) =="
    local err=$OUT/stl_main.err ok=1 f
    for f in stl/*.ph; do
        # same mode as the test TU: mixing c99 headers with c89 TUs would
        # conflict (uint64_t vs unsigned long long)
        $PLANGC $PFLAGS "$f" -o "stl/$(basename "$f" .ph).h" 2>"$err" || ok=0
    done
    # output sits at tests/out/ so the emitted #include "../../stl/*.h" resolves
    if [ $ok = 1 ] && build_bin tests/stl/main.p "$OUT/stl_main" "$err" \
       && check_run "$OUT/stl_main" tests/stl/main.expected stl; then
        echo "   stl: ok"
    else
        [ -s "$err" ] && sed 's/^/       /' "$err" | head -3
        echo "   stl: FAILED"; total_fail=$((total_fail+1))
    fi
    # leave the repo's stl/*.h in default (c99) mode, whatever mode we tested in
    if [ -n "$PFLAGS" ]; then
        for f in stl/*.ph; do $PLANGC "$f" -o "stl/$(basename "$f" .ph).h" 2>/dev/null; done
    fi
}

suite_psuite() {
    echo "== p-suite (c-testsuite ported to P) =="
    local pass=0 fail=0 src name bin
    for src in tests/p-suite/*.p; do
        name=$(basename "$src" .p); bin=$OUT/psuite/$name
        if build_bin "$src" "$bin" "$bin.err" && check_run "$bin" "tests/p-suite/$name.expected" "$name"; then
            pass=$((pass+1))
        else
            [ -s "$bin.err" ] && sed 's/^/       /' "$bin.err" | head -2
            fail=$((fail+1))
        fi
    done
    echo "   p-suite: $pass ok, $fail failed (of $((pass+fail)))"
    total_fail=$((total_fail+fail))
}

suite_csuite() {
    echo "== c-suite (C frontend scoreboard — informational) =="
    local pass=0 fail=0 src name bin
    for src in tests/c-testsuite/tests/single-exec/*.c; do
        name=$(basename "$src" .c); bin=$OUT/csuite/$name
        # the C frontend takes preprocessed input; use the system cpp. The
        # subshell keeps a compiler crash on one test from spamming the log.
        if ! $CC -E -P "$src" -o "$bin.i" 2>/dev/null; then fail=$((fail+1)); continue; fi
        if ( build_bin "$bin.i" "$bin" "$bin.err" -lm ) 2>/dev/null &&
           check_run "$bin" "$src.expected" "$name" >/dev/null; then
            pass=$((pass+1))
        else
            fail=$((fail+1))
        fi
    done
    echo "   c-suite score: $pass/$((pass+fail)) (doesn't gate; artifacts in $OUT/csuite)"
}

# ---------- main ----------
suites=${*:-"cases modules stl p-suite c-suite"}
echo "plangc test run — PLANGC=$PLANGC BACKEND=$BACKEND${STD:+ STD=$STD}"
for s in $suites; do
    case $s in
        cases)    suite_cases ;;
        modules)  suite_modules ;;
        stl)      suite_stl ;;
        p-suite)  suite_psuite ;;
        c-suite)  suite_csuite ;;
        all)      suite_cases; suite_modules; suite_stl; suite_psuite; suite_csuite ;;
        *) echo "unknown suite '$s' (cases|modules|stl|p-suite|c-suite|all)"; exit 2 ;;
    esac
done
echo
if [ $total_fail -eq 0 ]; then
    echo "ALL GATING SUITES PASSED"
    rm -rf "$OUT"          # no garbage left behind on success
else
    echo "$total_fail FAILURE(S) — artifacts kept in $OUT for inspection"
    exit 1
fi
