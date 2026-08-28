#!/usr/bin/env bash
# httpd.sh — o servidor HTTP/1.1 do `packages/httpd`, batido POR FORA.
#
# Um `.expected` não serve para isto. O que se quer provar não é o que uma função
# devolve — é o que sai NO FIO quando um cliente de verdade bate à porta, e as
# perguntas interessantes são justamente as que só um cliente faz: reusa ele a
# conexão? o 204 vem sem `content-length`? um pedido sem `Host` é recusado? o
# servidor sobrevive a um handler que rebenta?
#
# O cliente é o `curl`, e é de propósito: ele é o oráculo. Se o `curl` diz que
# houve UMA conexão para três pedidos, houve — é ele que conta, não nós.
#
# O PORTO vem do sistema (`listen(0)`) e o servidor escreve-o num ficheiro. Não
# se imprime: o `stdout` de quem escreve para um cano é tamponado por blocos, e a
# linha ficaria retida até o tampão encher — quem lesse ficaria à espera de um
# servidor que já está de pé. Um ficheiro só aparece depois de fechado, o que faz
# dele um sinal em vez de uma adivinha.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
OUT=${OUT:-tests/out/httpd}
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1: esperado '$2', veio '$3'"; fail=$((fail+1)); fi
}

command -v curl >/dev/null || { echo "   httpd: sem curl, saltado"; exit 0; }

if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/test/servidor.psc "$OUT/srv" >"$OUT/build.log" 2>&1; then
    echo "  FAIL o servidor de teste não compila"; tail -5 "$OUT/build.log"; exit 1
fi

PORTFILE="$OUT/porto"
"$OUT/srv" "$PORTFILE" >"$OUT/srv.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$PORTFILE" ] && break; sleep 0.05; done
[ -s "$PORTFILE" ] || { echo "  FAIL o servidor não abriu porto nenhum"; exit 1; }
B="http://127.0.0.1:$(cat "$PORTFILE")"

# ---- o caso de todos os dias ----
check "hello"        "ola do pscript" "$(curl -s $B/)"
check "404"          "404"            "$(curl -s -o /dev/null -w '%{http_code}' $B/nao-existe)"
check "POST e corpo" "0123456789"     "$(curl -s -X POST --data-binary '0123456789' $B/eco)"
check "json"         '{"quem":"pscript","quantos":3}' "$(curl -s $B/json)"
check "tipo do html" "text/html; charset=utf-8" "$(curl -s -o /dev/null -w '%{content_type}' $B/html)"
check "redirect"     "302"            "$(curl -s -o /dev/null -w '%{http_code}' $B/parati)"

# ---- D3c: nomes repetidos continuam separados, que é o que um Dict perderia ----
check "cabecalhos repetidos" "um|dois" \
      "$(curl -s -H 'x-nota: um' -H 'x-nota: dois' $B/cabecalhos)"

# ---- RFC 9110 §8.6: um 204 não leva `content-length`, nem sequer zero ----
check "204 sem content-length" "0" \
      "$(curl -s -i $B/vazio | tr -d '\r' | grep -c '^content-length')"

# ---- D3e: o handler rebenta, o cliente leva 500, e o SERVIDOR CONTINUA ----
check "500 do handler" "500" "$(curl -s -o /dev/null -w '%{http_code}' $B/rebenta)"
check "e continua vivo" "ola do pscript" "$(curl -s $B/)"

# ---- D3d: keep-alive. Quem conta é o curl. ----
check "uma conexao para tres pedidos" "1" \
      "$(curl -s -o /dev/null -w '%{num_connects}' $B/ $B/json $B/html | head -c 1)"

# ---- D41: sem `Host` num HTTP/1.1 é 400, como o RFC manda ----
if command -v nc >/dev/null; then
    got=$(printf 'GET / HTTP/1.1\r\n\r\n' | timeout 5 nc 127.0.0.1 "$(cat "$PORTFILE")" | head -1 | tr -d '\r')
    check "sem Host da 400" "HTTP/1.1 400 Bad Request" "$got"
fi

# ---- D3f: o tecto do corpo é um número, e acima dele é 413 ----
check "corpo acima do tecto da 413" "413" \
      "$(head -c 2000000 /dev/zero | tr '\0' 'x' | curl -s -o /dev/null -w '%{http_code}' -X POST --data-binary @- $B/eco)"

# ---- D42: o `Date` está lá, e o `Server` só porque este servidor o pediu ----
check "tem Date" "1" "$(curl -s -i $B/ | tr -d '\r' | grep -c '^date: ')"

echo "   httpd: $pass ok, $fail failed"
[ $fail -eq 0 ]
