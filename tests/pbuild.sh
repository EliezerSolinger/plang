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
