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
    # optional per-test compiler flags in <src-sans-ext>.flags
    local xf="" base="${src%.*}"
    [ -f "$base.flags" ] && xf=$(cat "$base.flags")
    if [ "$BACKEND" = qbe ]; then
        $PLANGC $xf --backend qbe "$src" -o "$bin.ssa" 2>"$err" &&
        $QBE "$bin.ssa" -o "$bin.s" 2>>"$err" &&
        $CC "$bin.s" -o "$bin" "$@" -lm 2>>"$err"
    else
        $PLANGC $PFLAGS $xf "$src" -o "$bin.c" 2>"$err" &&
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
    # o repo NUNCA é tocado: os headers da stl vão para $OUT/stl e a TU de
    # teste para $OUT/stlrun/tu — o #include "../../stl/x.h" emitido resolve
    # para $OUT/stl (espelho do layout dos fontes dentro do workdir)
    # --out-dir espelha a raiz dentro do workdir ($OUT/mirror): a TU sai em
    # mirror/tests/stl/main.c e o include "../../stl/x.h" resolve em mirror/stl
    local err=$OUT/stl_main.err ok=1 M=$OUT/mirror
    $PLANGC $PFLAGS --out-dir "$M" stl/*.ph tests/stl/main.p 2>"$err" || ok=0
    if [ "$BACKEND" = qbe ]; then
        ok=1
        $PLANGC --out-dir "$M" stl/*.ph 2>"$err" || ok=0
        $PLANGC --backend qbe tests/stl/main.p -o "$M/stl_main.ssa" 2>>"$err" &&
        $QBE "$M/stl_main.ssa" -o "$M/stl_main.s" 2>>"$err" &&
        $CC "$M/stl_main.s" -o "$OUT/stl_main" -lm 2>>"$err" || ok=0
    else
        [ $ok = 1 ] && { $CC $CSTD -w "$M/tests/stl/main.c" -o "$OUT/stl_main" -lm 2>>"$err" || ok=0; }
    fi
    if [ $ok = 1 ] \
       && check_run "$OUT/stl_main" tests/stl/main.expected stl; then
        echo "   stl: ok"
    else
        [ -s "$err" ] && sed 's/^/       /' "$err" | head -3
        echo "   stl: FAILED"; total_fail=$((total_fail+1))
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

suite_errors() {
    echo "== errors (diagnostics: compilation MUST fail with the message) =="
    local pass=0 fail=0 src name err
    for src in tests/errors/*.p tests/errors/*.c; do
        [ -f "$src" ] || continue
        name=$(basename "$src"); name=${name%.*}; err=$OUT/errors_$name.err
        # optional per-test extra flags (e.g. --pedantic) in <name>.flags
        xflags=""; [ -f "tests/errors/$name.flags" ] && xflags=$(cat "tests/errors/$name.flags")
        if $PLANGC $PFLAGS $xflags "$src" -o /dev/null 2>"$err"; then
            echo "  FAIL $name (compiled; expected an error)"; fail=$((fail+1))
        elif ! grep -qF "$(cat "tests/errors/$name.expected")" "$err"; then
            echo "  FAIL $name (wrong message):"; sed 's/^/       /' "$err" | head -2
            fail=$((fail+1))
        else
            pass=$((pass+1))
        fi
    done
    echo "   errors: $pass ok, $fail failed"
    total_fail=$((total_fail+fail))
}

# must-NOT-compile corpora: the compiler is expected to REJECT each file
# (nonzero exit, no crash). Informational scoreboard — measures diagnostic
# coverage of the C front end. Sources: tests/wacct (vendored, MIT) and, when
# fetched via tests/fetch-external.sh, gcc.dg/noncompile + clang Sema/Parser.
run_reject_dir() {
    local label=$1 dir=$2 rej=0 acc=0 crash=0 f
    [ -d "$dir" ] || return 0
    while IFS= read -r f; do
        # must-reject corpora model a MAX-CONFORMANCE compiler: promote all
        # warnings and GNU extensions to errors (like clang -Werror -pedantic-errors)
        timeout 5 $PLANGC -Werror -pedantic-errors "$f" -o /dev/null 2>/dev/null
        local rc=$?
        if [ $rc -eq 139 ] || [ $rc -eq 134 ]; then crash=$((crash+1))
        elif [ $rc -ne 0 ]; then rej=$((rej+1))
        else acc=$((acc+1)); fi
    done < <(find "$dir" -name "*.c" | sort)
    local tot=$((rej+acc+crash))
    [ $tot -gt 0 ] && echo "   $label: rejected $rej/$tot (accepted $acc, crashed $crash)"
}

# wacct valid corpus: 600+ single-file C programs with expected exit codes
# (tests/wacct/expected_results.json). Gating: any wrong compile/run fails.
suite_wvalid() {
    echo "== wacct-valid (C programs, expected exit codes) =="
    local exp=$OUT/wvalid.tsv
    mkdir -p "$OUT"/wvalid
    python3 - > "$exp" <<'PYEOF'
import json, os
d = json.load(open("tests/wacct/expected_results.json"))
p = json.load(open("tests/wacct/test_properties.json"))
libs = p.get("libs", {}); alibs = p.get("assembly_libs", {})
for k, v in d.items():
    out = v.get("stdout", "").replace("\\", "\\\\").replace("\n", "\\n").replace("\t", "\\t")
    # companion sources: helper .c libs + platform assembly libs (_linux.s)
    deps = list(libs.get(k, []))
    for a in alibs.get(k, []):
        deps.append(a + "_linux.s")
    print(f"{k}\t{v.get('return_code', 0)}\t{';'.join(deps)}\t{out}")
PYEOF
    local pass=0 fail=0 skip=0 rel src bin want deps wanto got goto_ dep extras
    while IFS=$'\t' read -r rel want deps wanto; do
        src=tests/wacct/tests/$rel
        [ -f "$src" ] || { skip=$((skip+1)); continue; }
        case "$rel" in */libraries/*) skip=$((skip+1)); continue ;; esac
        # framework-driver test: the harness injects its own main() and inspects
        # the generated code (chapter-20 register allocation). If neither the
        # test nor any companion lib defines main, it isn't runnable standalone.
        local has_main=0
        grep -q "main *(" "$src" && has_main=1
        for dep in ${deps//;/ }; do
            case "$dep" in *.c) grep -q "main *(" "tests/wacct/tests/$dep" 2>/dev/null && has_main=1 ;; esac
        done
        [ $has_main = 0 ] && { skip=$((skip+1)); continue; }
        bin=$OUT/wvalid/$(echo "$rel" | tr '/' '_' | sed 's/\.c$//')
        # companion libs: .c goes through the compiler too; .s straight to cc
        extras=""
        if [ -n "$deps" ]; then
            local miss=0
            for dep in ${deps//;/ }; do
                local dsrc=tests/wacct/tests/$dep
                [ -f "$dsrc" ] || { miss=1; break; }
                case "$dep" in
                    *.s) extras="$extras $dsrc" ;;
                    *.c)
                        local dout=$OUT/wvalid/$(echo "$dep" | tr '/' '_').lib.c
                        $PLANGC $PFLAGS "$dsrc" -o "$dout" 2>/dev/null || { miss=1; break; }
                        extras="$extras $dout" ;;
                esac
            done
            [ $miss = 1 ] && { skip=$((skip+1)); continue; }
        fi
        if ! build_bin "$src" "$bin" "$bin.err" $extras; then
            echo "  FAIL $rel (build)"; sed 's/^/       /' "$bin.err" | head -2; fail=$((fail+1)); continue
        fi
        ( cd "$OUT"/wvalid && timeout 10 "$ROOT/$bin" >"$ROOT/$bin.out" 2>/dev/null )
        got=$?
        goto_=$(sed -e 's/\\/\\\\/g' -e 's/\t/\\t/g' "$bin.out" | awk 'BEGIN{ORS="\\n"}{print}' | sed 's/\\n$//')
        if [ "$got" != "$want" ]; then
            echo "  FAIL $rel (exit $got, expected $want)"; fail=$((fail+1))
        elif [ -n "$wanto" ] && [ "$goto_" != "$wanto" ]; then
            echo "  FAIL $rel (stdout differs)"; fail=$((fail+1))
        else
            pass=$((pass+1))
        fi
    done < "$exp"
    echo "   wacct-valid: $pass ok, $fail failed ($skip skipped: multi-file/absent)"
    total_fail=$((total_fail+fail))
}

suite_cinvalid() {
    echo "== c-invalid (must-reject scoreboards — informational) =="
    local d rej=0 tot=0
    # wacct: per-category tally (lex/parse/semantics/types/...)
    for cat in invalid_lex invalid_parse invalid_semantics invalid_types invalid_declarations invalid_labels invalid_struct_tags; do
        local files
        files=$(find tests/wacct/tests -type d -name "$cat" 2>/dev/null)
        [ -n "$files" ] || continue
        local r=0 a=0 c=0 f rc
        while IFS= read -r f; do
            # max-conformance mode, like clang -Werror -pedantic-errors: the
            # wacct reference compiler rejects all of these
            timeout 5 $PLANGC -Werror -pedantic-errors "$f" -o /dev/null 2>/dev/null; rc=$?
            if [ $rc -eq 139 ] || [ $rc -eq 134 ]; then c=$((c+1))
            elif [ $rc -ne 0 ]; then r=$((r+1)); else a=$((a+1)); fi
        done < <(find $files -name "*.c" | sort)
        echo "   wacct/$cat: rejected $r/$((r+a+c)) (accepted $a, crashed $c)"
    done
    run_reject_dir "gcc.dg/noncompile" tests/external/gcc-noncompile
    run_reject_dir "clang/Parser"      tests/external/clang-parser
    run_reject_dir "clang/Sema"        tests/external/clang-sema
}

suite_pstudio() {
    echo "== pstudio (editor em P: headless sempre; SDL com driver dummy) =="
    # maior consumidor de P depois do compilador: compilar TUDO é gating.
    # SDL2 é dependência com skip gracioso (DESIGN.md): sem libsdl2-dev os
    # testes headless (psys, raster) rodam mesmo assim.
    local M=$OUT/mirror pass=0 fail=0 name src bin err deps d ok cobjs ldext
    local sdl=0; pkg-config --exists sdl2 >/dev/null 2>&1 && sdl=1
    mkdir -p "$OUT"/pstudio
    export SDL_VIDEODRIVER=dummy
    for src in tests/pstudio/*.p; do
        name=$(basename "$src" .p)
        deps=""
        case $name in
            psys_vfs)    deps="pstudio/psys" ;;
            pgfx_raster) deps="pstudio/pgfx_raster pstudio/font_atlas" ;;
            pgfx_*)      deps="pstudio/pgfx pstudio/pgfx_raster pstudio/font_atlas" ;;
            pui_*)       deps="pstudio/pui pstudio/pgfx_raster pstudio/font_atlas" ;;
            core_complete) deps="pstudio/complete pstudio/core pstudio/psys selfhost/lexer selfhost/utf8 selfhost/util" ;;
            cv_*)        deps="pstudio/codeview pstudio/complete pstudio/core pstudio/pui pstudio/pgfx pstudio/pgfx_raster pstudio/font_atlas pstudio/psys selfhost/lexer selfhost/utf8 selfhost/util" ;;
            core_*)      deps="pstudio/core selfhost/lexer selfhost/utf8 selfhost/util" ;;
            app_*)       deps="pstudio/app pstudio/codeview pstudio/complete pstudio/pui pstudio/pgfx pstudio/pgfx_raster pstudio/font_atlas pstudio/psys pstudio/core selfhost/lexer selfhost/utf8 selfhost/util" ;;
        esac
        if [ $sdl = 0 ] && case " $deps " in *" pgfx "*) true;; *) false;; esac; then
            echo "  skip $name (sem SDL2)"; continue
        fi
        bin=$OUT/pstudio/$name; err=$bin.err; : >"$err"
        ok=1; cobjs=""; ldext=""
        case " $deps " in *"/pgfx "*) ldext=$(pkg-config --cflags --libs sdl2) ;; esac
        if [ "$BACKEND" = qbe ]; then
            for d in $deps; do
                dn=$(echo "$d" | tr '/' '_')
                $PLANGC --backend qbe $d.p -o "$bin.$dn.ssa" 2>>"$err" &&
                $QBE "$bin.$dn.ssa" -o "$bin.$dn.s" 2>>"$err" || { ok=0; break; }
                cobjs="$cobjs $bin.$dn.s"
            done
            [ $ok = 1 ] && { $PLANGC --backend qbe "$src" -o "$bin.ssa" 2>>"$err" &&
                             $QBE "$bin.ssa" -o "$bin.s" 2>>"$err" || ok=0; }
            [ $ok = 1 ] && { $CC "$bin.s" $cobjs -o "$bin" $ldext -lm 2>>"$err" || ok=0; }
        else
            # headers: pstudio inteiro + interfaces que o core reusa do compilador
            for d in pstudio/*.ph selfhost/plang.ph selfhost/ast.ph selfhost/lexer.ph stl/*.ph; do
                $PLANGC $PFLAGS --out-dir "$M" "$d" 2>>"$err" || ok=0
            done
            for d in $deps; do
                $PLANGC $PFLAGS --out-dir "$M" $d.p 2>>"$err" || ok=0
                cobjs="$cobjs $M/$d.c"
            done
            [ $ok = 1 ] && { $PLANGC $PFLAGS --out-dir "$M" "$src" 2>>"$err" || ok=0; }
            # psys é POSIX: -D_DEFAULT_SOURCE reexpõe st_mtim & cia. quando o
            # -std=c11 estrito da suíte esconde (o ingest do plangc vê modo GNU)
            [ $ok = 1 ] && { $CC $CSTD -D_DEFAULT_SOURCE -w "$M/tests/pstudio/$name.c" $cobjs -o "$bin" $ldext -lm 2>>"$err" || ok=0; }
        fi
        if [ $ok = 1 ] && check_run "$bin" "tests/pstudio/$name.expected" "$name"; then
            pass=$((pass+1))
        else
            [ -s "$err" ] && sed 's/^/       /' "$err" | head -3
            fail=$((fail+1))
        fi
    done
    unset SDL_VIDEODRIVER
    echo "   pstudio: $pass ok, $fail failed"
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
suites=${*:-"cases modules stl p-suite errors pstudio c-suite"}
echo "plangc test run — PLANGC=$PLANGC BACKEND=$BACKEND${STD:+ STD=$STD}"
for s in $suites; do
    case $s in
        cases)    suite_cases ;;
        modules)  suite_modules ;;
        stl)      suite_stl ;;
        p-suite)  suite_psuite ;;
        errors)   suite_errors ;;
        c-invalid) suite_cinvalid ;;
        wacct-valid) suite_wvalid ;;
        pstudio)  suite_pstudio ;;
        c-suite)  suite_csuite ;;
        all)      suite_cases; suite_modules; suite_stl; suite_psuite; suite_errors; suite_pstudio; suite_csuite ;;
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
