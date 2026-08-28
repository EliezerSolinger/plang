#!/usr/bin/env bash
# tests/oracle/run.sh — the reference implementations as ORACLES.
#
#   bash tests/oracle/run.sh          # both
#   bash tests/oracle/run.sh py       # just python3
#
# The corpora in tests/conformance/ are files somebody else wrote. This is the
# other half of the same idea and it measures what no downloadable corpus can:
# our own programs, run twice — once here and once by the implementation whose
# behaviour we said we would copy — with the outputs diffed.
#
#   py/  python3 is the oracle for the LANGUAGE. The design says "as Python
#        does" in dozens of places (-7//2 = -4, -7%3 = 2, repr of a float, the
#        slice, the order of a dict, a stable sort, the str methods). Until now
#        every one of those was checked BY HAND, once, by the person who wrote
#        the rule. Here they are checked by Python, every run.
#
#   js/  node is the oracle for the RUNTIME MODEL. `await` yields even when the
#        task is already finished (78.4), `gather` answers in the order the
#        tasks were given, `race` cancels the losers, a timer of 0 still goes
#        after the microtasks. Those are promises about ORDER, and the only way
#        to check a promise about order against JS is to ask JS.
#
# A pair is `<name>.psc` next to `<name>.py` (or `<name>.mjs`), written to print
# exactly the same lines. Where the two languages genuinely differ, the program
# says so in a comment and prints the difference on purpose — a silent skip is
# how a divergence becomes a feature nobody chose.
set -u
cd "$(dirname "$0")/../.."

OUT=tests/out/oracle
FAIL=0
mkdir -p "$OUT"

have() { command -v "$1" >/dev/null 2>&1; }

# node paints numbers in `console.log` when it decides the output is a terminal,
# and whether it decides that depends on how this script was invoked — so the
# same pair agreed by hand and differed under `verify-all`. Turned off here
# rather than filtered afterwards: a colour code in the middle of a diff is a
# difference nobody meant to test.
export NO_COLOR=1 FORCE_COLOR=0

# 148: A VERSÃO DO UNICODE dos dois lados.
#
# Os casos `unicat` e `unicase` perguntam a mesma coisa a duas bases de dados: a
# nossa, gerada e comitada (o cabeçalho de `unicat.bin` diz qual), e a do python3
# desta máquina. Quando as versões diferem, um desacordo não diz nada sobre o
# nosso código — diz que uma delas conhece caracteres que a outra não tem. O
# Unicode 15.1 acrescentou a extensão I do CJK, e é exactamente aí que eles
# divergem numa máquina com Python 3.13.
#
# Portanto: SALTA, com as duas versões nomeadas. Um salto silencioso seria pior do
# que a falha; uma falha por causa da versão seria ruído que ninguém consegue
# corrigir sem decidir primeiro qual Unicode a linguagem segue.
unicode_nosso() {
    head -c 10 pscript/runtime/unicat.bin 2>/dev/null | tr -d '\0' | sed 's/^PSCA//'
}
unicode_deles() {
    python3 -c 'import unicodedata; print(unicodedata.unidata_version)' 2>/dev/null
}

run_side() { # run_side <dir> <ext> <cmd...>
    local dir=$1 ext=$2; shift 2
    local pass=0 fail=0 src name ref
    local nosso deles
    nosso=$(unicode_nosso); deles=$(unicode_deles)
    for src in tests/oracle/$dir/*.psc; do
        [ -f "$src" ] || continue
        name=$(basename "$src" .psc)
        case $name in
            unicat|unicase)
                if [ -n "$nosso" ] && [ -n "$deles" ] && [ "$nosso" != "$deles" ]; then
                    echo "  SKIP $name — a nossa tabela é Unicode $nosso e o python3 é $deles: são duas bases diferentes, e o desacordo seria sobre os caracteres que uma tem e a outra não"
                    continue
                fi ;;
        esac
        ref="tests/oracle/$dir/$name.$ext"
        [ -f "$ref" ] || { echo "  FAIL $name: no $ext reference next to it"; fail=$((fail+1)); continue; }
        if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh "$src" "$OUT/$name" >"$OUT/$name.build" 2>&1; then
            echo "  FAIL $name (build) — see $OUT/$name.build"; fail=$((fail+1)); continue
        fi
        ( cd "$OUT" && "./$name" >"$name.ours" 2>&1 )
        "$@" "$ref" > "$OUT/$name.theirs" 2>&1
        if diff -u "$OUT/$name.theirs" "$OUT/$name.ours" > "$OUT/$name.diff"; then
            pass=$((pass+1))
        else
            echo "  FAIL $name — $(grep -c '^[+-][^+-]' "$OUT/$name.diff") lines differ:"
            sed -n '4,14p' "$OUT/$name.diff" | sed 's/^/      /'
            fail=$((fail+1))
        fi
    done
    echo "   $dir: $pass agree, $fail differ"
    [ $fail = 0 ] || FAIL=1
}

for s in ${*:-py js}; do
    case $s in
        py) printf '\n\033[1m== python3 as the oracle for the language ==\033[0m\n'
            # 148: `PYTHONSAFEPATH` — o directório do script NÃO entra no
            # `sys.path`. Sem isto, um dos ficheiros deste corpus tapa um módulo
            # da biblioteca padrão para todos os outros: há um `collections.psc`
            # (e portanto um `collections.py`), e o `import subprocess` do
            # `proc.py` acaba a importar ESSE — o que executa a saída dele no
            # meio da do `proc` e depois falha no `namedtuple`.
            #
            # Só apareceu com o Python 3.13, porque foi nele que o `subprocess`
            # passou a puxar o `functools` no arranque. O nome do ficheiro é
            # certo (o teste é sobre `collections`), e é o caminho que estava
            # errado.
            have python3 && PYTHONSAFEPATH=1 run_side py py python3 || echo "   -- no python3" ;;
        js) printf '\n\033[1m== node as the oracle for the runtime model ==\033[0m\n'
            have node && run_side js mjs node || echo "   -- no node" ;;
        *) echo "unknown oracle '$s' (py|js)"; exit 2 ;;
    esac
done

echo
[ $FAIL = 0 ] && printf '\033[1;32m✔ oracles agree\033[0m\n' || printf '\033[1;31m✘ an oracle disagrees\033[0m\n'
exit $FAIL
