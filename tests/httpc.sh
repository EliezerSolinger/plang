#!/usr/bin/env bash
# httpc.sh — o CLIENTE, contra o nosso próprio servidor.
#
# É o portão mais valioso destes dois pacotes, e a razão é o parser: o servidor e
# o cliente têm uma máquina de estados só — a do `packages/http`, conferida contra
# o corpus do llhttp. Portanto quando o círculo fecha, ele fecha nos dois
# sentidos; e se algum dos dois divergir do RFC, divergem juntos e são os oráculos
# de FORA que os apanham — o `curl` no servidor (tests/httpd.sh) e a biblioteca
# `websockets` do Python no ws (tests/ws.sh).
#
# Este portão prova a outra metade: que o nosso lado, sozinho, fala consigo.
set -u
cd "$(dirname "$0")/.."

OUT=${OUT:-tests/out/httpc}
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1:"; diff <(echo "$2") <(echo "$3") | head -14; fail=$((fail+1)); fi
}

for m in packages/httpd/test/server.psc packages/httpd/test/wsserver.psc packages/httpc/test/client.psc; do
    n=$(basename "$m" .psc)
    if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh "$m" "$OUT/$n" >>"$OUT/build.log" 2>&1; then
        echo "  FAIL $m não compila"; tail -5 "$OUT/build.log"; exit 1
    fi
done

"$OUT/server"     "$OUT/pa" >"$OUT/srv.log" 2>&1 &
A=$!
"$OUT/wsserver" "$OUT/pb" >"$OUT/ws.log" 2>&1 &
B=$!
trap 'kill $A $B 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$OUT/pa" ] && [ -s "$OUT/pb" ] && break; sleep 0.05; done
[ -s "$OUT/pa" ] && [ -s "$OUT/pb" ] || { echo "  FAIL os servidores não abriram porto"; exit 1; }

got=$(timeout 120 "$OUT/client" "$(cat "$OUT/pa")" "$(cat "$OUT/pb")" 2>&1)
check "o cliente fala com o nosso servidor" "$(cat tests/httpc.expected)" "$got"

echo "   httpc: $pass ok, $fail failed"
[ $fail -eq 0 ]
