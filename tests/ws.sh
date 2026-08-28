#!/usr/bin/env bash
# ws.sh — o WebSocket, contra a biblioteca `websockets` do Python e contra o RFC.
#
# Duas metades, e a segunda é a que interessa.
#
# A PRIMEIRA é o oráculo, nos DOIS sentidos: os quadros que ela serializa são
# lidos por nós, e os que nós serializamos são lidos por ela. Um oráculo só num
# sentido prova metade — um parser e um serializador que errassem da mesma
# maneira concordariam entre si e com mais ninguém.
#
# A SEGUNDA são as RECUSAS, e essas não têm oráculo possível: uma biblioteca
# correcta não produz um quadro mal formado, que é justamente o ponto. Os
# vectores são montados à mão a partir do RFC 6455, e o que se compara é o CÓDIGO
# DE FECHO com que cada um é recusado — porque recusar pelo motivo errado é meio
# defeito, e a suíte Autobahn conta-o como falha.
set -u
cd "$(dirname "$0")/.."

OUT=${OUT:-tests/out/ws}
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1:"; diff <(echo "$2") <(echo "$3") | head -12; fail=$((fail+1)); fi
}

python3 -c "import websockets" 2>/dev/null || { echo "   ws: sem a lib websockets, o oráculo é saltado"; SEM_ORACULO=1; }
SEM_ORACULO=${SEM_ORACULO:-0}

for m in eco recusas; do
    if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/ws/test/$m.psc "$OUT/$m" >"$OUT/build.log" 2>&1; then
        echo "  FAIL packages/ws/test/$m.psc não compila"; tail -5 "$OUT/build.log"; exit 1
    fi
done

if [ "$SEM_ORACULO" = 0 ]; then
    for modo in nomask mask; do
        python3 tests/ws-oracle.py gerar $modo > "$OUT/v_$modo.txt"
        awk '{print $1, $2, $3, $4}' "$OUT/v_$modo.txt" > "$OUT/esp_$modo.txt"
        "$OUT/eco" parse "$OUT/v_$modo.txt" > "$OUT/lido_$modo.txt"
        check "o nosso parser lê o que a lib escreveu ($modo)" \
              "$(cat "$OUT/esp_$modo.txt")" "$(cat "$OUT/lido_$modo.txt")"
    done

    # e o inverso: os NOSSOS bytes, lidos por ela — e byte a byte iguais aos dela
    "$OUT/eco" serialize "$OUT/v_nomask.txt" > "$OUT/nosso.txt"
    python3 tests/ws-oracle.py conferir < "$OUT/nosso.txt" > "$OUT/ela_leu.txt"
    check "a lib lê o que nós escrevemos" \
          "$(cat "$OUT/esp_nomask.txt")" "$(cat "$OUT/ela_leu.txt")"
    awk '{print $1, $5}' "$OUT/v_nomask.txt" > "$OUT/dela.txt"
    check "e os bytes são os mesmos que ela produziria" \
          "$(cat "$OUT/dela.txt")" "$(cat "$OUT/nosso.txt")"
fi

# as recusas do RFC, com o código de fecho de cada uma
"$OUT/recusas" packages/ws/test/recusas.txt > "$OUT/recusas.txt"
check "as recusas do RFC 6455" \
      "$(cat packages/ws/test/recusas.expected)" "$(cat "$OUT/recusas.txt")"

echo "   ws: $pass ok, $fail failed"
[ $fail -eq 0 ]
