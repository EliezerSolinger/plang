#!/usr/bin/env bash
# print-atomic.sh — `print` de vários workers ao mesmo tempo sai em LINHAS.
#
# Por que isto é um teste de shell e não um `.expected`: a ORDEM das linhas de
# oito workers é indeterminada por natureza, então não há saída esperada para
# comparar. O que se verifica é a forma de cada linha — e é justamente isso que
# quebrava. `print` fazia duas chamadas de stdio (o texto e depois o `\n`), cada
# uma trancando o FILE por si, e stdout é o MESMO arquivo de todos os workers:
# cada um tem heap, coletor e laço próprios (18.1), mas não uma saída própria.
# O resultado eram linhas costuradas — `worker-0-linha-38worker-1-linha-14` — e
# linhas vazias no meio. Medido antes do conserto: 66 linhas malformadas em 1801.
#
#   bash tests/print-atomic.sh
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
OUT=tests/out/printatomic
NW=8         # workers
NL=200       # linhas por worker

rm -rf "$OUT"
mkdir -p "$OUT"

cat > "$OUT/storm.psc" <<'EOF'
def berra(id: int, quantas: int) -> int:
    for i in range(quantas):
        print(f"w{id}-{i}")
    return id

ws: list<Worker<int>> = []
for k in range(8):
    ws.append(spawn(berra, (k, 200)))
for i in range(200):
    print(f"m-{i}")
EOF

if ! PLANGC="$PLANGC" PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh "$OUT/storm.psc" "$OUT/storm" \
        > "$OUT/build.log" 2>&1; then
    echo "  FAIL print-atomic (build) — veja $OUT/build.log"
    exit 1
fi

if ! ( cd "$OUT" && timeout -s KILL 60 ./storm > storm.out 2>&1 ); then
    echo "  FAIL print-atomic: o programa não terminou bem"
    exit 1
fi

want=$(( NW * NL + NL ))
got=$(wc -l < "$OUT/storm.out" | tr -d ' ')
bad=$(grep -cvE '^(w[0-7]-[0-9]+|m-[0-9]+)$' "$OUT/storm.out" || true)

if [ "$bad" != 0 ]; then
    echo "  FAIL print-atomic: $bad linha(s) costurada(s) ou vazia(s), de $got"
    grep -nvE '^(w[0-7]-[0-9]+|m-[0-9]+)$' "$OUT/storm.out" | head -5 | sed 's/^/      /'
    exit 1
fi
if [ "$got" != "$want" ]; then
    echo "  FAIL print-atomic: $got linhas, esperadas $want"
    exit 1
fi
# e cada linha aparece exactamente uma vez
dups=$(sort "$OUT/storm.out" | uniq -d | wc -l | tr -d ' ')
if [ "$dups" != 0 ]; then
    echo "  FAIL print-atomic: $dups linha(s) repetida(s)"
    exit 1
fi
echo "   print-atomic: $got linhas de $((NW + 1)) threads, nenhuma costurada"
