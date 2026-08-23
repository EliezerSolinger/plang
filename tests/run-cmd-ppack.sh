#!/usr/bin/env bash
# tests/run-cmd-ppack.sh — `ppack run`, e o cache atrás dele (F7).
#
# É o `tests/run-cmd.sh` medido do outro lado: os MESMOS comportamentos, agora
# que a decisão saiu do compilador. O que se prende não é uma saída, é um
# conjunto de comportamentos — e cada um foi decidido numa bateria:
#
#   * ele corre, e os argumentos do programa chegam (6.3);
#   * a segunda corrida não chama o `cc` nem o compilador — MEDIDO, não suposto;
#   * editar o fonte invalida;
#   * editar um módulo IMPORTADO invalida também, que é o único modo de falhar
#     de um cache de build que interessa de verdade;
#   * editar o COMPILADOR invalida, porque o C que ele gera é outro;
#   * o status de saída é o do PROCESSO, porque `run` faz `exec` — e é isso que
#     faz um programa que lê do teclado ou pinta a tela funcionar;
#   * e um programa em P corre pelo mesmo caminho.
#
# A diferença que fica dita: o binário sai em `build/run/` — dentro do PROJETO,
# que `make clean` alcança — e não num `~/.cache` que ninguém sabe que existe.
set -u
cd "$(dirname "$0")/.."

PPACK=${PPACK:-build/bin/ppack}
case $PPACK in /*) ;; *) PPACK=$PWD/$PPACK;; esac
OUT=tests/out/runppack
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0
ok=0

check() { if [ "$2" = "$3" ]; then ok=$((ok+1)); else echo "  FAIL $1: esperava '$2', veio '$3'"; fail=$((fail+1)); fi; }

cat > "$OUT/lib.psc" <<'EOF'
def valor() -> int:
    return 7
EOF
cat > "$OUT/prog.psc" <<'EOF'
import sys
import lib
print("valor", lib.valor(), sys.argv[1] if len(sys.argv) > 1 else "-")
sys.exit(len(sys.argv))
EOF

# 1. corre, e os argumentos chegam
saiu=$("$PPACK" run "$OUT/prog.psc" abc 2>/dev/null | tail -1)
check "corre e recebe os argumentos" "valor 7 abc" "$saiu"

# 2. o status de saída é o do PROGRAMA (2 = o próprio + um argumento)
"$PPACK" run "$OUT/prog.psc" abc >/dev/null 2>&1
check "o status é o do programa" "2" "$?"

# 3. a segunda corrida não constrói NADA: nem `cc`, nem compilador. A prova é
#    que ela não imprime linha de progresso nenhuma.
linhas=$("$PPACK" run "$OUT/prog.psc" abc 2>/dev/null | grep -c '^\[' || true)
check "a segunda corrida nao constroi" "0" "$linhas"

# 4. editar o FONTE invalida
sleep 0.01
cat > "$OUT/prog.psc" <<'EOF'
import sys
import lib
print("outro", lib.valor())
EOF
saiu2=$("$PPACK" run "$OUT/prog.psc" 2>/dev/null | tail -1)
check "editar o fonte invalida" "outro 7" "$saiu2"

# 5. editar um MÓDULO IMPORTADO invalida
sleep 0.01
cat > "$OUT/lib.psc" <<'EOF'
def valor() -> int:
    return 99
EOF
saiu3=$("$PPACK" run "$OUT/prog.psc" 2>/dev/null | tail -1)
check "editar o modulo importado invalida" "outro 99" "$saiu3"

# 6. editar o COMPILADOR invalida
sleep 0.01
touch build/bin/plangc_s2
linhas2=$("$PPACK" run "$OUT/prog.psc" 2>/dev/null | grep -c '^\[' || true)
if [ "$linhas2" -gt 0 ]; then ok=$((ok+1)); else echo "  FAIL mexer no compilador devia reconstruir"; fail=$((fail+1)); fi

# 7. um programa em P pelo mesmo caminho
cat > "$OUT/emp.p" <<'EOF'
include <stdio.h>

def main() -> int:
    printf("em P\n")
    return 0
EOF
saiu4=$("$PPACK" run "$OUT/emp.p" 2>/dev/null | tail -1)
check "um programa em P corre igual" "em P" "$saiu4"

# 8. o binário vive no PROJETO
if ls build/run/bin/prog >/dev/null 2>&1; then ok=$((ok+1)); else echo "  FAIL o binario devia estar em build/run/bin"; fail=$((fail+1)); fi

# 9. um arquivo que não existe é uma mensagem, não um estouro
"$PPACK" run "$OUT/naoexiste.psc" >/dev/null 2>&1 && { echo "  FAIL um arquivo que nao existe devia falhar"; fail=$((fail+1)); } || ok=$((ok+1))

echo "   run-ppack: $ok ok, $fail failed"
[ $fail = 0 ]
