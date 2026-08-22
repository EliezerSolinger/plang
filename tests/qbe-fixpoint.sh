#!/usr/bin/env bash
# qbe-fixpoint.sh — o compilador construído pelo QBE gera o MESMO que o
# construído pelo C.
#
# É o ponto fixo do OUTRO back end, e ele mede uma coisa que a suíte não mede: um
# back end pode passar em todos os casos e ainda assim gerar um compilador que
# diverge do outro num canto que nenhum caso toca. Aqui o compilador é gerado
# duas vezes — pelo C e pelo QBE — e o que se compara é o que ELES geram.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
QBE=${QBE:-./qbe/qbe}
OUT=${OUT:-tests/out/qbefp}
PKGP="--pkg-path packages"

[ -x "$QBE" ] || { echo "   qbe-fixpoint: sem qbe/ — pulado"; exit 0; }
rm -rf "$OUT"; mkdir -p "$OUT/a" "$OUT/b"

for f in selfhost/*.p; do
    b=$(basename "${f%.p}")
    $PLANGC $PKGP --backend qbe "$f" -o "$OUT/a/$b.ssa" 2>/dev/null || { echo "  FAIL gerar $b.ssa"; exit 1; }
    "$QBE" "$OUT/a/$b.ssa" -o "$OUT/a/$b.s" 2>/dev/null || { echo "  FAIL montar $b.s"; exit 1; }
done
$CC "$OUT"/a/*.s -o "$OUT/plangc_qbe" 2>"$OUT/link.err" || { echo "  FAIL linkar o compilador QBE"; head -3 "$OUT/link.err"; exit 1; }

n=0
for f in selfhost/*.p; do
    b=$(basename "${f%.p}")
    "$OUT/plangc_qbe" $PKGP --backend qbe "$f" -o "$OUT/b/$b.ssa" 2>/dev/null || { echo "  FAIL o compilador QBE não gera $b"; exit 1; }
    cmp -s "$OUT/a/$b.ssa" "$OUT/b/$b.ssa" || { echo "  FAIL diverge: $b.ssa"; exit 1; }
    n=$((n+1))
done
echo "   qbe-fixpoint: $n módulos, o compilador QBE reproduz o do C"
