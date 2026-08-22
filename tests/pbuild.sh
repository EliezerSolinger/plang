#!/usr/bin/env bash
# tests/pbuild.sh — o MOTOR do pbuild (F2B), mecanismo por mecanismo.
#
# O motor é escrito em pscript (pbuild/ps/lib_{graph,log,build}.psc) e o que
# este arreio faz é compilá-lo e rodar a suíte que vive ao lado dele — o mesmo
# arranjo do `pui_test.psc` do editor: o teste mora com o módulo.
#
# O que a suíte prende está dito lá dentro, caso a caso, mas a ideia é uma só:
# um build só tem um defeito que importa, que é NÃO refazer o que mudou. Todo
# caso aqui é uma forma de isso acontecer.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-./plangc2}
OUT=tests/out/pbuild-bin
mkdir -p "$OUT"

if ! PLANGC="$PLANGC" bash tests/psbuild.sh pbuild/ps/engine_test.psc "$OUT/engine" 2>"$OUT/build.err"; then
    echo "  FAIL: o motor do pbuild não compila"
    head -5 "$OUT/build.err"
    exit 1
fi
rm -rf tests/out/pbuild
"$OUT/engine"
rc=$?
[ $rc = 0 ] || exit $rc

# ---- F3: o descritor deste repositório, a CLI, e a exportação ----
# Um ENSAIO (`-n`) percorre o grafo inteiro sem rodar nada: ele prova que o
# descritor monta, que o compilador responde às quatro perguntas, que o grafo
# passa na higiene (sem duplicata, sem ciclo, sem entrada órfã) e que a ordem
# fecha. Custa segundos e cobre a cadeia toda.
if ! PLANGC="$PLANGC" bash tests/psbuild.sh pbuild/ps/ppack.psc "$OUT/ppack" 2>"$OUT/ppack.err"; then
    echo "  FAIL: o ppack não compila"
    head -5 "$OUT/ppack.err"
    exit 1
fi
# quantas arestas o ensaio RODA depende do que já está no disco (é um build
# incremental como outro qualquer); o que se cobra aqui é que ele feche sem
# reclamar de nada — os erros de higiene saem no quinto evento, com "erro:" na
# frente, e qualquer um deles invalida o grafo inteiro
if ! "$OUT/ppack" build -n --query "$PLANGC" >"$OUT/ensaio.log" 2>&1; then
    echo "  FAIL: o ensaio do descritor não fecha"
    grep -v '^\[' "$OUT/ensaio.log" | head -5
    exit 1
fi
if grep -q '^erro:' "$OUT/ensaio.log"; then
    echo "  FAIL: o grafo do descritor não passa na higiene"
    grep '^erro:' "$OUT/ensaio.log" | head -5
    exit 1
fi
echo "   pbuild-descritor: o ensaio fecha e o grafo passa na higiene"

# a exportação para ninja, sobre o grafo DE VERDADE: o que se confere aqui é que
# ela sai, que sai igual duas vezes, e que todo `$` do texto está escapado — o
# aspeamento fino tem casos próprios na suíte do motor
"$OUT/ppack" ninja --query "$PLANGC" > "$OUT/build.ninja" 2>"$OUT/ninja.err" || {
    echo "  FAIL: ppack ninja"; head -3 "$OUT/ninja.err"; exit 1; }
"$OUT/ppack" ninja --query "$PLANGC" > "$OUT/build.ninja.2" 2>/dev/null
if ! cmp -s "$OUT/build.ninja" "$OUT/build.ninja.2"; then
    echo "  FAIL: ppack ninja não é determinista"; exit 1
fi
regras=$(grep -c '^rule ' "$OUT/build.ninja")
if [ "$regras" -lt 100 ]; then
    echo "  FAIL: o build.ninja saiu com $regras regras"; exit 1
fi
if grep '^  command = ' "$OUT/build.ninja" | grep -q '[^$]\$\([^$]\|$\)'; then
    echo "  FAIL: há um \$ solto num comando do build.ninja"; exit 1
fi
echo "   pbuild-ninja: $regras regras, determinista, sem \$ solto"
