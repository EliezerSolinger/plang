#!/usr/bin/env bash
# tests/net-late.sh — dado que chega DEPOIS que o leitor estacionou (18.4/77.1).
#
# Este arreio existe por um defeito que a suíte inteira escondia. O laço de
# eventos esperava com `poll` e, ao acordar, DRENAVA todo descritor que tivesse
# disparado — certo para o cano de uma fila (o byte lá é só uma batida na porta),
# destrutivo para um SOCKET, onde o que está dentro é o dado que o programa
# pediu. O servidor perdia a mensagem e via só o fim da conexão.
#
# Ninguém via porque todo cliente dos testes escreve logo depois de conectar: o
# dado já está lá quando o `read` é emitido, o syscall acerta de primeira, e o
# laço nunca estaciona naquele descritor. E não dá para reproduzir com cliente na
# MESMA thread: o que ele faz acontece entre dois polls.
#
# Então são dois PROCESSOS, os dois em pscript, e o cliente pausa antes de
# escrever. É o único jeito de o dado chegar enquanto o servidor está dentro do
# `poll` — que é o instante do defeito.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-./plangc2}
OUT=tests/out/netlate
rm -rf "$OUT"; mkdir -p "$OUT"
fail=0

build() { # build <src> <out>
    PSBUILD_RT="$OUT/rt" PLANGC="$PLANGC" bash tests/psbuild.sh "$1" "$2" >"$2.build" 2>&1
}

if ! build tests/net/late_server.psc "$OUT/server"; then
    echo "  FAIL server (build) — see $OUT/server.build"; exit 1
fi
if ! build tests/net/late_client.psc "$OUT/client"; then
    echo "  FAIL client (build) — see $OUT/client.build"; exit 1
fi

# a fixed port would collide with whatever else runs here; the server prints the
# one the system gave it and the client is told
# a porta sai no stderr (stdout é bufferizado por bloco quando é arquivo)
"$OUT/server" 0 > "$OUT/server.out" 2> "$OUT/server.port" &
srv=$!
port=""
for _ in $(seq 1 100); do
    port=$(sed -n 's/^port \([0-9]*\)$/\1/p' "$OUT/server.port" 2>/dev/null | head -1)
    [ -n "$port" ] && break
    sleep 0.05
done
if [ -z "$port" ]; then
    echo "  FAIL the server never said which port it took"; kill $srv 2>/dev/null; exit 1
fi

timeout 20 "$OUT/client" "$port" 0.4 > "$OUT/client.out" 2>&1 || { echo "  FAIL client (exit $?)"; fail=1; }
wait $srv 2>/dev/null

want="got 22 data that arrives late
then 0"
got=$(cat "$OUT/server.out")
if [ "$want" = "$got" ]; then
    echo "   net-late: 1 ok, 0 failed"
else
    echo "  FAIL the late data did not arrive whole:"
    diff <(echo "$want") <(echo "$got") | sed 's/^/      /'
    fail=1
fi
exit $fail
