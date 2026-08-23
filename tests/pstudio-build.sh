#!/usr/bin/env bash
# pstudio-build.sh — o MOTOR DE BUILD dentro do editor (F6).
#
# A F6 promete que o editor não fala com um processo de build: ele importa o
# motor (`packages/pbuild`) e corre-o no mesmo escalonador que trata o teclado.
# Isso é uma afirmação que, sem este arreio, só se poderia conferir olhando para
# uma janela — e é justamente o tipo de coisa que apodrece sem ser vista.
#
# O descritor é do PROJETO e o editor não o conhece (nem devia: ele abre
# qualquer árvore). Quem o conhece é o `ppack` dessa árvore, então o editor
# pergunta-lhe o GRAFO e corre-o. A serialização é o preço de o editor servir
# mais do que um projeto.
set -u
cd "$(dirname "$0")/.."

PSTUDIO=${PSTUDIO:-build/bin/pstudio}
ok=0; fail=0
check() { if [ "$2" = "$3" ]; then ok=$((ok+1)); else echo "  FAIL $1: esperava '$2', veio '$3'"; fail=$((fail+1)); fi; }

[ -x "$PSTUDIO" ] || { echo "   pstudio-build: sem editor construído — pulado"; exit 0; }

# 1. um alvo pequeno: ele constrói, e diz quantas arestas
saiu=$("$PSTUDIO" --build build/bin/verdict 2>&1 | head -1)
case $saiu in
    "build ok"*|"nada a fazer") ok=$((ok+1)) ;;
    *) echo "  FAIL um alvo simples: veio '$saiu'"; fail=$((fail+1)) ;;
esac

# 2. o grafo veio inteiro (o editor pergunta-o ao ppack e corre-o com o motor)
n=$("$PSTUDIO" --build build/bin/verdict 2>&1 | grep -oE 'alvos no grafo: [0-9]+' | grep -oE '[0-9]+')
if [ "${n:-0}" -gt 100 ]; then ok=$((ok+1)); else echo "  FAIL o grafo devia ter centenas de alvos, veio ${n:-0}"; fail=$((fail+1)); fi

# 3. um alvo que não existe é uma mensagem, e o status diz que falhou
"$PSTUDIO" --build naoexisteisto >/dev/null 2>&1 && { echo "  FAIL um alvo inexistente devia falhar"; fail=$((fail+1)); } || ok=$((ok+1))
msg=$("$PSTUDIO" --build naoexisteisto 2>&1 | head -1)
case $msg in
    *"alvo desconhecido"*) ok=$((ok+1)) ;;
    *) echo "  FAIL a mensagem não disse que o alvo é desconhecido: '$msg'"; fail=$((fail+1)) ;;
esac

echo "   pstudio-build: $ok ok, $fail failed"
[ $fail = 0 ]
