#!/usr/bin/env bash
# ninja.sh — o `build.ninja` comitado ainda descreve este grafo?
#
# Ele é o BOOTSTRAP: numa máquina sem `ppack`, `cc -O2 -o plangc
# bootstrap/selfhost/*.c && ninja` constrói tudo. E um arquivo gerado que fica
# comitado tem exatamente um modo de falhar — envelhecer em silêncio —, então
# este portão regenera-o e compara. Se divergir, a mensagem diz o comando.
#
# O que ele NÃO faz é rodar o ninja: isso é o `verify` inteiro por outro
# caminho, e o que está em causa aqui é a FIDELIDADE da exportação.
set -u
cd "$(dirname "$0")/.."

PPACK=${PPACK:-build/bin/ppack}
case $PPACK in /*) ;; *) PPACK=$PWD/$PPACK;; esac
OUT=${OUT:-tests/out/ninja}
rm -rf "$OUT"; mkdir -p "$OUT"

"$PPACK" ninja "$OUT/build.ninja" >/dev/null 2>&1 || { echo "   ninja: o emissor falhou"; exit 1; }
if cmp -s "$OUT/build.ninja" build.ninja; then
    echo "   ninja: o build.ninja comitado está em dia ($(grep -c '^build ' build.ninja) arestas)"
    exit 0
fi
echo "   ninja: o build.ninja comitado NÃO descreve mais este grafo."
echo "          ppack ninja build.ninja"
diff "$OUT/build.ninja" build.ninja | head -6
exit 1
