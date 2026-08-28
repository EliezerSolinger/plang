#!/usr/bin/env bash
# compress.sh — o compressor DEFLATE, contra DOIS leitores que não são nossos.
#
# A prova que interessa não é o nosso `inflate` ler o nosso `deflate`: os dois
# podiam ter o mesmo defeito e concordar. Quem confere são o `zlib` do CPython e
# o `gunzip` da linha de comando — dois leitores independentes que não partilham
# uma linha com este repositório.
set -u
cd "$(dirname "$0")/.."

OUT=${OUT:-tests/out/compress}
rm -rf "$OUT"; mkdir -p "$OUT/gz"
pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1: esperado '$2', veio '$3'"; fail=$((fail+1)); fi
}

if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/compress/test/oracle.psc "$OUT/oraculo" >"$OUT/build.log" 2>&1; then
    echo "  FAIL o oráculo do compress não compila"; tail -5 "$OUT/build.log"; exit 1
fi
"$OUT/oraculo" SPECS.MD "$OUT/gz" > "$OUT/nosso.txt" 2>&1

# o nosso próprio round-trip, em todos os casos
check "o nosso inflate lê o nosso deflate" "0" \
      "$(grep -c 'roundtrip=False' "$OUT/nosso.txt")"

got=$(python3 tests/compress-oracle.py "$OUT/gz" 2>&1)
check "o zlib do CPython abriu todos" "o zlib abriu e bate: 9 de 9" \
      "$(echo "$got" | grep '^o zlib')"
check "o gunzip aceita todos" "o gunzip -t aceita todos: True" \
      "$(echo "$got" | grep '^o gunzip')"

# E QUE ELE COMPRIME DE VERDADE, que é a diferença entre isto e o que havia
# antes: um DEFLATE de blocos literais é válido e cresce. 6000 bytes de texto
# repetido têm de caber em muito menos de mil.
z=$(grep '^6000 ->' "$OUT/nosso.txt" | awk '{print $3}')
if [ "${z:-99999}" -lt 1000 ]; then pass=$((pass+1))
else echo "  FAIL não comprimiu: 6000 bytes deram $z"; fail=$((fail+1)); fi

echo "   compress: $pass ok, $fail failed"
[ $fail -eq 0 ]
