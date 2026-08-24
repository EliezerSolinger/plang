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

PLANGC=${PLANGC:-build/bin/plangc_s2}
# the runtime speaks POSIX (socket, getaddrinfo, poll, pipe, pthread) and glibc
# hides those under a strict `-std=`; asking for them explicitly is what every
# project that uses them does
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE"
CC=${CC:-cc}
BACKEND=${BACKEND:-c}
STD=${STD:-}
# o diretório de trabalho é sobreponível para que DUAS corridas possam existir
# ao mesmo tempo (a suíte C e a QBE, por exemplo). Duas corridas no mesmo `OUT`
# se atropelam e o relatório das duas fica ilegível — aconteceu.
OUT=${OUT:-tests/out}
# o `stl` é um PACOTE (`packages/stl`), e um `import <stl/vec.ph>` procura nas
# raízes que o compilador recebe. Toda invocação do arreio passa a raiz do
# workspace, que é onde os pacotes deste repositório moram.
PKGP="--pkg-path packages"
QBE=qbe/qbe

# ---------- setup ----------
[ -x "$PLANGC" ] || { echo "building compiler ($PLANGC missing)..."; make >/dev/null || exit 1; }
if [ "$BACKEND" = qbe ] && [ ! -x "$QBE" ]; then
    # o QBE é um SUBMÓDULO, e um `git clone` sem `--recurse-submodules` deixa o
    # diretório vazio. Sem esta mensagem o que se vê é "could not build qbe/",
    # que manda procurar um erro de compilação que não existe.
    if [ ! -f qbe/Makefile ]; then
        echo "error: qbe/ está vazio — ele é um SUBMÓDULO deste repositório."
        echo "       git submodule update --init"
        exit 1
    fi
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

# The cc that plangc uses to preprocess `include <h>` / `include "h"`. Set ONCE
# here, for the whole run, because it has to satisfy every suite:
#   - SDL2's include dir: outside Linux (Homebrew) it is not a default search
#     path, and SDL_cpuinfo.h drags in the compiler's SIMD-intrinsics headers,
#     which nothing here uses (see the Makefile's SDL2_NOSIMD).
#   - the test directories: a test may include a header sitting next to it, and
#     the roundtrip suite reprints the P into tests/out, from where a source
#     relative include would no longer resolve.
# Deliberately not set inside a suite function: `export` there leaks into every
# suite that runs after it, which is how the roundtrip suite ended up being run
# with a cpp configured for pstudio.
CPPX="$CC"
if pkg-config --exists sdl2 >/dev/null 2>&1; then
    CPPX="$CPPX $(pkg-config --cflags sdl2) -DSDL_DISABLE_IMMINTRIN_H \
-DSDL_DISABLE_MMINTRIN_H -DSDL_DISABLE_XMMINTRIN_H -DSDL_DISABLE_EMMINTRIN_H \
-DSDL_DISABLE_PMMINTRIN_H -DSDL_DISABLE_ARM_NEON_H -DSDL_DISABLE_MM3DNOW_H \
-DSDL_DISABLE_LSX_H -DSDL_DISABLE_LASX_H"
fi
for d in tests/cases tests/p-suite tests/modules tests/stl tests/pstudio; do
    [ -d "$d" ] && CPPX="$CPPX -I$d"
done
export PLANGC_CPP="$CPPX"

total_fail=0

# compile one P (or preprocessed C) source to a binary via the chosen backend.
# usage: build_bin <src> <bin> <errfile> [extra cc flags...]
build_bin() {
    local src=$1 bin=$2 err=$3; shift 3
    # optional per-test compiler flags in <src-sans-ext>.flags
    local xf="" base="${src%.*}"
    [ -f "$base.flags" ] && xf=$(cat "$base.flags")
    # a test may `include "local.h"`, and the emitted `#include "local.h"` is
    # relative to the SOURCE — but the generated .c lands in tests/out. (The real
    # builds do not need this: --out-dir mirrors the tree, so relative includes
    # resolve in the mirror.)
    local sdir="-I$(dirname "$src")"
    if [ "$BACKEND" = qbe ]; then
        $PLANGC $PKGP $xf --backend qbe "$src" -o "$bin.ssa" 2>"$err" &&
        $QBE "$bin.ssa" -o "$bin.s" 2>>"$err" &&
        $CC "$bin.s" -o "$bin" "$@" -lm 2>>"$err"
    else
        $PLANGC $PFLAGS $PKGP $xf "$src" -o "$bin.c" 2>"$err" &&
        $CC $CSTD -w $sdir "$bin.c" -o "$bin" "$@" -lm 2>>"$err"
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
    # *.c too: C input that must be ACCEPTED. tests/errors covers the must-REJECT
    # side and c-suite is a vendored scoreboard that does not gate, so there was
    # nowhere to pin a header shape the front end has to swallow (the macOS SDK's
    # nullability and availability attributes, for one).
    for src in tests/cases/*.p tests/cases/*.c; do
        [ -f "$src" ] || continue
        name=$(basename "$src"); name=${name%.*}; bin=$OUT/cases/$name
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
    # o repo NUNCA é tocado: os headers da stl vão para o espelho e a TU de
    # teste para $OUT/stlrun/tu — o #include "../../packages/stl/x.h" emitido
    # resolve dentro do workdir (o `stl` é um PACOTE desde a migração)
    # --out-dir espelha a raiz dentro do workdir ($OUT/mirror): a TU sai em
    # mirror/tests/stl/main.c e o include resolve em mirror/packages/stl
    local err=$OUT/stl_main.err ok=1 M=$OUT/mirror
    $PLANGC $PFLAGS $PKGP --out-dir "$M" tests/stl/main.p 2>"$err" || ok=0
    if [ "$BACKEND" = qbe ]; then
        ok=1
        $PLANGC $PKGP --out-dir "$M" packages/stl/*.ph 2>"$err" || ok=0
        $PLANGC $PKGP --backend qbe tests/stl/main.p -o "$M/stl_main.ssa" 2>>"$err" &&
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
        if $PLANGC $PFLAGS $PKGP $xflags "$src" -o /dev/null 2>"$err"; then
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
        timeout 5 $PLANGC $PKGP -Werror -pedantic-errors "$f" -o /dev/null 2>/dev/null
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
            timeout 5 $PLANGC $PKGP -Werror -pedantic-errors "$f" -o /dev/null 2>/dev/null; rc=$?
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
    echo "== pstudio (o editor em pscript, e o driver gráfico em P) =="
    # 116: o editor virou pscript e o editor em P foi aposentado. O que roda
    # aqui: os dois testes do DRIVER (rasterizador e janela, que continuam em P
    # porque são pixel e ponteiro) e os quatro do editor em pscript — buffer,
    # toolkit, widget de edição e o app inteiro, todos headless.
    # SDL2 é dependência com skip gracioso: sem libsdl2-dev o teste do
    # rasterizador roda mesmo assim.
    local M=$OUT/mirror pass=0 fail=0 name src bin err deps d ok cobjs ldext
    local sdl=0; pkg-config --exists sdl2 >/dev/null 2>&1 && sdl=1
    mkdir -p "$OUT"/pstudio
    export SDL_VIDEODRIVER=dummy
    # PLANGC_CPP (with SDL2's flags) is set once at the top of this script
    for src in tests/pstudio/*.p; do
        name=$(basename "$src" .p)
        deps=""
        # 116: o editor em P foi aposentado; o que sobrou em P é o DRIVER
        # gráfico, e é o que estes dois testes medem
        case $name in
            pgfx_raster) deps="pstudio/pgfx_raster pstudio/font_atlas pstudio/icons" ;;
            pgfx_*)      deps="pstudio/pgfx pstudio/pgfx_raster pstudio/font_atlas pstudio/icons" ;;
        esac
        if [ $sdl = 0 ] && case " $deps " in *" pgfx "*) true;; *) false;; esac; then
            echo "  skip $name (sem SDL2)"; continue
        fi
        bin=$OUT/pstudio/$name; err=$bin.err; : >"$err"
        ok=1; cobjs=""; ldext=""
        # os mesmos -DSDL_DISABLE_* do PLANGC_CPP, para o cc ver as mesmas
        # declarações que o plangc viu (ver SDL2_NOSIMD no Makefile)
        case " $deps " in *"/pgfx "*) ldext="-DSDL_DISABLE_IMMINTRIN_H -DSDL_DISABLE_MMINTRIN_H -DSDL_DISABLE_XMMINTRIN_H -DSDL_DISABLE_EMMINTRIN_H -DSDL_DISABLE_PMMINTRIN_H -DSDL_DISABLE_ARM_NEON_H -DSDL_DISABLE_MM3DNOW_H -DSDL_DISABLE_LSX_H -DSDL_DISABLE_LASX_H $(pkg-config --cflags --libs sdl2)" ;; esac
        if [ "$BACKEND" = qbe ]; then
            for d in $deps; do
                dn=$(echo "$d" | tr '/' '_')
                $PLANGC $PKGP --backend qbe $d.p -o "$bin.$dn.ssa" 2>>"$err" &&
                $QBE "$bin.$dn.ssa" -o "$bin.$dn.s" 2>>"$err" || { ok=0; break; }
                cobjs="$cobjs $bin.$dn.s"
            done
            [ $ok = 1 ] && { $PLANGC $PKGP --backend qbe "$src" -o "$bin.ssa" 2>>"$err" &&
                             $QBE "$bin.ssa" -o "$bin.s" 2>>"$err" || ok=0; }
            [ $ok = 1 ] && { $CC "$bin.s" $cobjs -o "$bin" $ldext -lm 2>>"$err" || ok=0; }
        else
            # headers: o driver inteiro + as interfaces que ele reusa
            # o `stl` já não é nomeado: ele é um pacote, e o fecho da 1.5(a)
            # traz os headers dele
            for d in pstudio/*.ph selfhost/plang.ph selfhost/ast.ph selfhost/lexer.ph; do
                $PLANGC $PFLAGS $PKGP --out-dir "$M" "$d" 2>>"$err" || ok=0
            done
            for d in $deps; do
                $PLANGC $PFLAGS $PKGP --out-dir "$M" $d.p 2>>"$err" || ok=0
                cobjs="$cobjs $M/$d.c"
            done
            [ $ok = 1 ] && { $PLANGC $PFLAGS $PKGP --out-dir "$M" "$src" 2>>"$err" || ok=0; }
            # -D_DEFAULT_SOURCE: o POSIX que o -std=c11 estrito da suíte esconde
            # (o ingest do plangc vê modo GNU)
            [ $ok = 1 ] && { $CC $CSTD -D_DEFAULT_SOURCE -w "$M/tests/pstudio/$name.c" $cobjs -o "$bin" $ldext -lm 2>>"$err" || ok=0; }
        fi
        if [ $ok = 1 ] && check_run "$bin" "tests/pstudio/$name.expected" "$name"; then
            pass=$((pass+1))
        else
            [ -s "$err" ] && sed 's/^/       /' "$err" | head -3
            fail=$((fail+1))
        fi
    done

    # o editor em pscript, headless: sem janela e sem SDL — buffer, toolkit,
    # widget de edição e o app inteiro
    local C=$OUT/pstudio_pscore errc=$OUT/pstudio_pscore.err
    rm -rf "$C"; mkdir -p "$C"; : >"$errc"
    ok=1
    $PLANGC $PFLAGS $PKGP --out-dir "$C" pscript/runtime/psrt.ph 2>>"$errc" || ok=0
    # 112: o `pui` portado entra aqui do mesmo jeito — headless, sem driver,
    # porque a métrica da fonte é PARÂMETRO do toolkit em pscript. As oito
    # linhas de retângulo dele foram conferidas contra o teste do pui em P
    # quando ele existia (bateria 112); o editor em P saiu na 116, e o que
    # ficou é este número, que não pode mudar.
    # 113: o `codeview` portado precisa do ADAPTADOR do lexer (pstudio/hl.p)
    # e, com ele, do lexer do compilador — que é o ponto: o editor em pscript
    # realça com o mesmo lexer que o compilador usa, e não com um segundo.
    local HLC=""
    if $PLANGC $PFLAGS $PKGP --out-dir "$C" selfhost/plang.ph selfhost/ast.ph selfhost/lexer.ph selfhost/cfront.ph selfhost/vecs.ph pstudio/hl.ph 2>>"$errc" &&
       $PLANGC $PFLAGS $PKGP --out-dir "$C" selfhost/lexer.p selfhost/util.p selfhost/utf8.p selfhost/cfront.p selfhost/vecs.p pstudio/hl.p 2>>"$errc"; then
        HLC="$C/pstudio/hl.c $C/selfhost/lexer.c $C/selfhost/util.c $C/selfhost/utf8.c $C/selfhost/cfront.c $C/selfhost/vecs.c"
    fi
    # o `pui_test` saiu daqui: o toolkit virou o pacote `packages/pui`, e o teste
    # dele viaja COM o pacote (`packages/pui/test/`). Quem o roda é a suíte de
    # pacotes do `pforge` — um pacote publicado carrega a prova de que funciona.
    for psprog in core_test:ps_core.expected:"the ported buffer" codeview_test:ps_codeview.expected:"the ported editing widget" shell_test:ps_shell.expected:"the editor (what pcode is)" ide_test:ps_ide.expected:"the IDE, with a driver of make-believe" perf_test:ps_perf.expected:"the ceilings on a big file" config_test:ps_config.expected:"the project's remembered state"; do
        pname=${psprog%%:*}; prest=${psprog#*:}; pexp=${prest%%:*}; pwhat=${prest#*:}
        ok=1
        [ $ok = 1 ] && { $PLANGC $PFLAGS $PKGP --out-dir "$C" pstudio/$pname.psc 2>>"$errc" || ok=0; }
        local extraobj=""
        case $pname in codeview_test|shell_test|ide_test|perf_test) extraobj="$HLC"; [ -z "$HLC" ] && ok=0 ;; esac
        # the perf gate is built the way the editor SHIPS. Measuring speed on an
        # unoptimised build measures the wrong binary: the compiler's lexer alone
        # is 15ms over 11 000 lines at -O0 and 9ms at -O2, and the editor is -O2.
        local optflag=""
        case $pname in perf_test) optflag="-O2" ;; esac
        [ $ok = 1 ] && { $CC $CSTD $optflag -w -o "$C/$pname" "$C/pstudio/$pname.c" \
                             "$C/pscript/runtime/psrt_mem.c" "$C/pscript/runtime/psrt_val.c" "$C/pscript/runtime/psrt_rt.c" "$C/pscript/runtime/psrt_std.c" "$C/pscript/runtime/psrt_os.c" "$C/pscript/runtime/psrt_top.c" $extraobj $PSDEFS -lm -pthread 2>>"$errc" || ok=0; }
        if [ $ok = 1 ] && check_run "$C/$pname" tests/pstudio/$pexp "pstudio-ps-${pname%_test}"; then
            pass=$((pass+1))
        else
            echo "  FAIL pstudio-ps-${pname%_test} ($pwhat)"
            [ -s "$errc" ] && sed 's/^/       /' "$errc" | head -3
            fail=$((fail+1))
        fi
    done

    # the pscript PORT of the editor: the logic in pscript, the driver in P.
    # It is built the way a user would build one — the runtime and the shim
    # compiled alongside — and then run headless through its own self-test,
    # which drives the real code paths (open, type, select, undo, DRAW, save).
    if [ $sdl = 1 ] && [ "$BACKEND" != qbe ]; then
        local P=$OUT/pstudio_ps err2=$OUT/pstudio_ps.err
        rm -rf "$P"; mkdir -p "$P"; : >"$err2"
        local sdlflags="-DSDL_DISABLE_IMMINTRIN_H -DSDL_DISABLE_MMINTRIN_H -DSDL_DISABLE_XMMINTRIN_H -DSDL_DISABLE_EMMINTRIN_H -DSDL_DISABLE_PMMINTRIN_H -DSDL_DISABLE_ARM_NEON_H -DSDL_DISABLE_MM3DNOW_H -DSDL_DISABLE_LSX_H -DSDL_DISABLE_LASX_H $(pkg-config --cflags --libs sdl2)"
        ok=1
        # 114: o driver em P é SDL + o lexer do compilador. O `psys` saiu: a
        # camada de sistema é a da stdlib do pscript desde a 111.
        for d in pstudio/*.ph pstudio/shim.ph pstudio/hl.ph selfhost/plang.ph selfhost/ast.ph selfhost/lexer.ph selfhost/cfront.ph selfhost/vecs.ph; do
            $PLANGC $PFLAGS $PKGP --out-dir "$P" "$d" 2>>"$err2" || ok=0
        done
        for d in pstudio/pgfx pstudio/pgfx_raster pstudio/font_atlas pstudio/icons pstudio/shim pstudio/hl selfhost/lexer selfhost/util selfhost/utf8 selfhost/cfront selfhost/vecs; do
            [ $ok = 1 ] && { $PLANGC $PFLAGS $PKGP --out-dir "$P" $d.p 2>>"$err2" || ok=0; }
        done
        [ $ok = 1 ] && { $PLANGC $PFLAGS $PKGP --out-dir "$P" pscript/runtime/psrt.ph 2>>"$err2" || ok=0; }
        # BOTH binaries, from the same layers: `pcode` is the editor and
        # `pstudio` is the editor plus the IDE. Building the two here is half the
        # proof of the split — the other half is `tests/decouple.sh`, which asks
        # the compiler which files each one reads.
        printf 'line one\nline two\nline three\n' > "$P/sample.txt"
        for bin in pcode pstudio; do
            local bok=$ok
            [ $bok = 1 ] && { $PLANGC $PFLAGS $PKGP --out-dir "$P" pstudio/$bin.psc 2>>"$err2" || bok=0; }
            [ $bok = 1 ] && { $CC $CSTD $PSDEFS -w -o "$P/run_$bin"               "$P/pstudio/$bin.c" "$P/pscript/runtime/psrt_mem.c" "$P/pscript/runtime/psrt_val.c" "$P/pscript/runtime/psrt_rt.c" "$P/pscript/runtime/psrt_std.c" "$P/pscript/runtime/psrt_os.c" "$P/pscript/runtime/psrt_top.c" "$P/pstudio/shim.c" "$P/pstudio/hl.c"               "$P/pstudio/pgfx.c" "$P/pstudio/pgfx_raster.c" "$P/pstudio/font_atlas.c" "$P/pstudio/icons.c" "$P/selfhost/lexer.c" "$P/selfhost/util.c" "$P/selfhost/utf8.c" "$P/selfhost/cfront.c" "$P/selfhost/vecs.c"               $sdlflags -lm -pthread 2>>"$err2" || bok=0; }
            local exp=tests/pstudio/ps_selftest.expected
            [ "$bin" = pcode ] && exp=tests/pstudio/pcode_selftest.expected
            if [ $bok = 1 ] && ( cd "$P" && timeout 30 ./run_$bin --selftest sample.txt >out.$bin 2>&1 ) &&
               diff -q "$P/out.$bin" "$exp" >/dev/null 2>&1; then
                pass=$((pass+1))
            else
                echo "  FAIL $bin (the binary's own self-test)"
                [ -s "$err2" ] && sed 's/^/       /' "$err2" | head -3
                [ -f "$P/out.$bin" ] && diff "$P/out.$bin" "$exp" | head -4 | sed 's/^/       /'
                fail=$((fail+1))
            fi
        done
    fi
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

# The P backend is a ROUND TRIP: print the AST back as P, re-parse it, and the C
# must come out identical. That proves the AST holds the whole surface language —
# nothing the parser reads is lost, and nothing the printer writes is invented.
#
# `__with_<line>_<col>` bakes the source POSITION into a generated name (on
# purpose: it makes the C traceable), and a reprint drops comments, so those
# names shift. They are normalized before the comparison; everything else must
# match byte for byte.
suite_roundtrip() {
    echo "== roundtrip (AST -> P -> AST: the C must be identical) =="
    local pass=0 fail=0 src name d=$OUT/roundtrip
    rm -rf "$d"; mkdir -p "$d/a" "$d/b"
    for src in tests/cases/*.p tests/p-suite/*.p; do
        name=$(echo "${src%.p}" | tr '/' '_')
        # __LINE__/__FILE__/__TIME__ resolve against the file being compiled, so
        # a reprint at another path with other line numbers CANNOT match — that
        # is the feature working, not a round-trip failure
        # embed() resolves its path against the file that spells it, so the
        # reprint — which lives in another directory — cannot see the data
        # files. Same class as the predefined macros above: the feature working.
        case $src in *feat-predefined*|*_embed*) continue ;; esac
        if ! $PLANGC "$src" -o "$d/a/$name.c" 2>/dev/null; then continue; fi   # already covered elsewhere
        if ! $PLANGC --backend p "$src" -o "$d/$name.p" 2>"$d/$name.e1"; then
            echo "  FAIL $src (cannot print): $(sed 's/.*error: //' "$d/$name.e1" | head -1)"
            fail=$((fail+1)); continue
        fi
        if ! $PLANGC "$d/$name.p" -o "$d/b/$name.c" 2>"$d/$name.e2"; then
            echo "  FAIL $src (printed P does not re-parse): $(sed 's/.*error: //' "$d/$name.e2" | head -1)"
            fail=$((fail+1)); continue
        fi
        if diff -q <(sed -E 's/__with_[0-9]+_[0-9]+/__with_N/g' "$d/a/$name.c") \
                   <(sed -E 's/__with_[0-9]+_[0-9]+/__with_N/g' "$d/b/$name.c") >/dev/null; then
            pass=$((pass+1))
        else
            echo "  FAIL $src (C differs after the round trip)"; fail=$((fail+1))
        fi
    done
    echo "   roundtrip: $pass ok, $fail failed"
    total_fail=$((total_fail+fail))
}

# ---------- main ----------
suites=${*:-"cases modules stl p-suite errors pstudio c-suite"}
echo "plangc test run — PLANGC=$PLANGC BACKEND=$BACKEND${STD:+ STD=$STD}"
suite_pscript() {
    echo "== pscript (front end + runtime: parse, reject, and RUN) =="
    local pass=0 fail=0 src name err d=$OUT/psc
    mkdir -p "$d"
    # 1. sources the front end must accept. The whole language parses; only a
    #    subset reaches the back end so far, so these are checked with
    #    --parse-only and the run corpus below is what proves the rest.
    for src in tests/pscript/ok/*.psc pscript/examples/*.psc; do
        [ -f "$src" ] || continue
        name=$(basename "$src"); err=$OUT/pscript_${name%.psc}.err
        if $PLANGC $PKGP --parse-only "$src" 2>"$err"; then
            pass=$((pass+1))
        else
            echo "  FAIL $src: $(sed 's/.*error: //' "$err" | head -1)"; fail=$((fail+1))
        fi
    done
    # 2. programs that COMPILE AND RUN: pscript -> P -> C/QBE -> a binary, with
    #    the runtime (16.4: P source compiled alongside) linked in. Combined
    #    stdout+stderr and the exit status are both compared, because a raised
    #    exception is part of what a program does.
    local rt="$d/rt"
    rm -rf "$rt"; mkdir -p "$rt"
    if ! $PLANGC $PFLAGS $PKGP --out-dir "$rt" pscript/runtime/psrt.ph 2>"$d/rt.err"; then
        echo "  FAIL runtime: $(sed 's/.*error: //' "$d/rt.err" | head -1)"; fail=$((fail+1))
    else
      for src in tests/pscript/run/*.psc pscript/examples/vec3.psc pscript/examples/smallpt_core.psc pscript/examples/smallpt_workers.psc pscript/examples/smallpt_full.psc; do
        [ -f "$src" ] || continue
        name=$(basename "$src"); name=${name%.psc}; err=$d/$name.err
        case $name in lib_*) continue ;; esac   # import fixtures, not programs
        local want_exit=0
        [ -f "tests/pscript/run/$name.exit" ] && want_exit=$(cat "tests/pscript/run/$name.exit")
        # a program may ask for extra COMPILER flags (`<name>.flags`) — which is
        # how a flag that changes what is emitted gets a gate at all: `-O`
        # strips `assert` (46.4), and the only way to see that is to build the
        # same program with it
        local xflags=""
        [ -f "tests/pscript/run/$name.flags" ] && xflags=$(cat "tests/pscript/run/$name.flags")
        local expfile="tests/pscript/run/$name.expected"
        local ok=1
        # `import "x.ph"` (75.3) makes the compiler emit the P module too, in
        # the same mirrored tree — those are the pmod_*.c linked in alongside
        if [ "$BACKEND" = qbe ]; then
            rm -f "$d"/pmod_*.ssa "$d"/pmod_*.s
            # 108/111: as seis camadas numa invocação — o QBE aceita a lista desde
            # que o merge de tipos não arraste `static` de outro `.p` (era o
            # defeito que a divisão desenterrou)
            # o QBE não emite headers, então o guarda-chuva `psrt.ph` não pode
            # ser nomeado aqui — mas o fecho da 1.5(a) continua a valer, e dois
            # `.p` bastam para trazer as seis camadas (o `os` é o único que
            # ninguém importa de dentro)
            $PLANGC $PKGP --backend qbe --out-dir "$rt" pscript/runtime/psrt_top.p pscript/runtime/psrt_os.p 2>"$err" &&
            $PLANGC $PKGP --backend qbe $xflags "$src" -o "$d/$name.ssa" 2>>"$err" &&
            $QBE "$d/$name.ssa" -o "$d/$name.s" 2>>"$err" &&
            for m in mem val rt std os top; do $QBE "$rt/pscript/runtime/psrt_$m.ssa" -o "$d/psrt_$m.s" 2>>"$err" || ok=0; done
            local qextra=""
            for pm in "$d"/pmod_*.ssa; do
                [ -f "$pm" ] || continue
                $QBE "$pm" -o "${pm%.ssa}.s" 2>>"$err" || ok=0
                qextra="$qextra ${pm%.ssa}.s"
            done
            [ $ok = 1 ] && { $CC $PSDEFS "$d/$name.s" "$d/psrt_mem.s" "$d/psrt_val.s" "$d/psrt_rt.s" "$d/psrt_std.s" "$d/psrt_os.s" "$d/psrt_top.s" $qextra -o "$d/$name" -lm -pthread 2>>"$err" || ok=0; }
        else
            $PLANGC $PFLAGS $PKGP $xflags --out-dir "$rt" "$src" 2>"$err" || ok=0
            local cextra=""
            for pm in "$rt/$(dirname "$src")"/pmod_*.c; do
                [ -f "$pm" ] || continue
                cextra="$cextra $pm"
            done
            [ $ok = 1 ] && { $CC $CSTD $PSDEFS -w "$rt/${src%.psc}.c" "$rt/pscript/runtime/psrt_mem.c" "$rt/pscript/runtime/psrt_val.c" "$rt/pscript/runtime/psrt_rt.c" "$rt/pscript/runtime/psrt_std.c" "$rt/pscript/runtime/psrt_os.c" "$rt/pscript/runtime/psrt_top.c" $cextra -o "$d/$name" -lm -pthread 2>>"$err" || ok=0; }
        fi
        if [ $ok = 0 ]; then
            echo "  FAIL $name (build): $(sed 's/.*error: //' "$err" | head -1)"; fail=$((fail+1)); continue
        fi
        ( cd "$d" && "./$name" >"$name.out" 2>&1 ); local rc=$?
        if [ "$rc" != "$want_exit" ]; then
            echo "  FAIL $name (exit $rc, expected $want_exit)"; fail=$((fail+1))
        elif ! diff -q "$expfile" "$d/$name.out" >/dev/null; then
            echo "  FAIL $name (output differs; see $d/$name.out)"; fail=$((fail+1))
        else
            pass=$((pass+1))
        fi
      done
    fi
    for src in tests/pscript/bad/*.psc; do
        [ -f "$src" ] || continue
        name=$(basename "$src"); name=${name%.psc}
        case $name in lib_*) continue ;; esac   # import fixtures, not tests
        err=$OUT/pscript_bad_$name.err
        if $PLANGC "$src" -o /dev/null 2>"$err"; then
            echo "  FAIL $name (parsed; expected an error)"; fail=$((fail+1))
        elif ! grep -qF "$(cat "tests/pscript/bad/$name.expected")" "$err"; then
            echo "  FAIL $name (wrong message): $(sed 's/.*error: //' "$err" | head -1)"; fail=$((fail+1))
        else
            pass=$((pass+1))
        fi
    done
    echo "   pscript: $pass ok, $fail failed"
    total_fail=$((total_fail+fail))
}

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
        roundtrip) suite_roundtrip ;;
        pscript)  suite_pscript ;;
        c-suite)  suite_csuite ;;
        all)      suite_cases; suite_modules; suite_stl; suite_psuite; suite_errors; suite_pstudio; suite_roundtrip; suite_pscript; suite_csuite ;;
        *) echo "unknown suite '$s' (cases|modules|stl|p-suite|errors|pstudio|roundtrip|pscript|c-suite|all)"; exit 2 ;;
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
