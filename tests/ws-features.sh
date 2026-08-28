#!/usr/bin/env bash
# ws-features.sh — as quatro peças que faltavam ao WebSocket, cada uma contra algo
# de fora.
#
# O que se prova aqui, e com quem:
#
#   1. A GRAMÁTICA de um cabeçalho de lista-com-parâmetros e a negociação do
#      permessage-deflate. São funções puras, e o portão delas não tem rede:
#      `packages/ws/test/negotiate.psc` contra um `.expected`. O caso que
#      interessa é `x; a="permessage-deflate"` — uma busca de subcadeia acerta nele
#      e conclui o contrário do que ele diz.
#
#   2. Os LIMITES DE JANELA, contra um descodificador de DEFLATE independente
#      (`tests/ws-window.py`). E não contra o `zlib`: um
#      `decompressobj(wbits=-8)` aceita um fluxo com casamentos a 400 bytes lido
#      com uma janela de 256, portanto passaria o código errado. A promessa de
#      `server_max_window_bits=N` é sobre as DISTÂNCIAS, e só quem lê os símbolos
#      a pode conferir.
#
#   3. O SUBPROTOCOLO, a FRAGMENTAÇÃO e o KEEPALIVE, contra um cliente de socket
#      cru (`tests/ws-raw.py`) — porque uma biblioteca correcta esconde
#      exactamente o que aqui se quer ver: a `websockets` remonta uma mensagem
#      fragmentada antes de a entregar (e assim 300 bytes num quadro e 300 em
#      cinco são indistinguíveis) e responde aos pings sozinha (e assim não há
#      como testar um cliente que NÃO responde).
#
#   4. E a REMONTAGEM, essa contra a `websockets`: os nossos cinco quadros
#      comprimidos têm de voltar a ser os 300 bytes originais na mão de uma
#      implementação que não é a nossa.
set -u
cd "$(dirname "$0")/.."

OUT=${OUT:-tests/out/ws-features}
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1:"; diff <(echo "$2") <(echo "$3") | head -14; fail=$((fail+1)); fi
}

# ---------- 1. a gramática e a negociação, sem rede ----------

for m in negotiate window; do
    if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/ws/test/$m.psc "$OUT/$m" >>"$OUT/build.log" 2>&1; then
        echo "  FAIL packages/ws/test/$m.psc não compila"; tail -5 "$OUT/build.log"; exit 1
    fi
done
check "a gramática de lista-com-parâmetros e a negociação" \
      "$(cat packages/ws/test/negotiate.expected)" "$("$OUT/negotiate")"

# ---------- 2. os limites de janela, contra um leitor de DEFLATE independente ----------

"$OUT/window" > "$OUT/janelas.txt"
if python3 tests/ws-window.py < "$OUT/janelas.txt" > "$OUT/dist.txt" 2>&1; then
    pass=$((pass+1))
else
    echo "  FAIL um casamento passou a janela anunciada:"; cat "$OUT/dist.txt"; fail=$((fail+1))
fi
# e o portão TEM de saber falhar: o fluxo de 15 bits rotulado como 8 tem de ser acusado
if sed 's/^15 /8 /' "$OUT/janelas.txt" | python3 tests/ws-window.py >/dev/null 2>&1; then
    echo "  FAIL o leitor de distâncias não acusa um fluxo que passa a janela"; fail=$((fail+1))
else
    pass=$((pass+1))
fi
# uma janela pequena tem de mudar o que sai — se não mudar, não está a ser honrada
d8=$(awk '/^bits=8 /{print $3}' "$OUT/dist.txt")
d15=$(awk '/^bits=15 /{print $3}' "$OUT/dist.txt")
check "a janela apertada suprime o casamento distante" "maior_distancia=0 maior_distancia=400" "$d8 $d15"

# ---------- 3. o servidor, para as três que precisam de fio ----------

if ! PSBUILD_RT="$OUT/rt" bash tests/psbuild.sh packages/httpd/test/wsfeatures.psc "$OUT/srv" >>"$OUT/build.log" 2>&1; then
    echo "  FAIL packages/httpd/test/wsfeatures.psc não compila"; tail -5 "$OUT/build.log"; exit 1
fi

arranca() {   # $1 = fragment_size, $2 = ping_interval, $3 = ping_timeout
    rm -f "$OUT/porto"
    "$OUT/srv" "$OUT/porto" "$1" "$2" "$3" >>"$OUT/srv.log" 2>&1 &
    SRV=$!
    for _ in $(seq 1 200); do [ -s "$OUT/porto" ] && break; sleep 0.05; done
    [ -s "$OUT/porto" ] || { echo "  FAIL o servidor não abriu porto"; exit 1; }
    P=$(cat "$OUT/porto")
}
para() { kill $SRV 2>/dev/null; wait $SRV 2>/dev/null; }

# --- o subprotocolo: a preferência do SERVIDOR é que manda ---
arranca 64 0.5 0.5
trap 'kill $SRV 2>/dev/null' EXIT

check "o servidor escolhe pela SUA ordem, não pela do cliente" \
      "v2" \
      "$(python3 tests/ws-raw.py handshake 127.0.0.1 $P /ws --subprotocols=v1,v2 | awk '/^sec-websocket-protocol/{print $3}')"
check "um cliente que só sabe v1 recebe v1" \
      "v1" \
      "$(python3 tests/ws-raw.py handshake 127.0.0.1 $P /ws --subprotocols=v1 | awk '/^sec-websocket-protocol/{print $3}')"
# sem nada em comum o cabeçalho é OMITIDO, e isso é uma resposta válida: o §4.1
# deixa o cliente decidir se consegue seguir sem subprotocolo
check "sem nada em comum, o cabeçalho não vai" \
      "<ausente>" \
      "$(python3 tests/ws-raw.py handshake 127.0.0.1 $P /ws --subprotocols=v9 | awk '/^sec-websocket-protocol/{print $3}')"

# --- os parâmetros do deflate ---
ext() { python3 tests/ws-raw.py handshake 127.0.0.1 $P /ws --extensions="$1" | sed -n 's/^sec-websocket-extensions = //p'; }
check "server_max_window_bits=10 é HONRADO e ecoado" \
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover; server_max_window_bits=10" \
      "$(ext 'permessage-deflate; server_max_window_bits=10')"
check "client_max_window_bits=12 é ecoado" \
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover; client_max_window_bits=12" \
      "$(ext 'permessage-deflate; client_max_window_bits=12')"
# §7.1.2.1: sem valor é "escolhe tu", e não se aperta o cliente por nada
check "client_max_window_bits sem valor não vira exigência" \
      "permessage-deflate; server_no_context_takeover; client_no_context_takeover" \
      "$(ext 'permessage-deflate; client_max_window_bits')"
# §7: um parâmetro desconhecido invalida a oferta — responder a uma oferta que não
# se entendeu inteira é prometer um comportamento que ninguém definiu
check "um parâmetro desconhecido faz recusar a oferta" \
      "<ausente>" \
      "$(python3 tests/ws-raw.py handshake 127.0.0.1 $P /ws --extensions='permessage-deflate; parametro_novo' | awk '/^sec-websocket-extensions/{print $3}')"
check "server_max_window_bits SEM valor é uma oferta torcida" \
      "<ausente>" \
      "$(python3 tests/ws-raw.py handshake 127.0.0.1 $P /ws --extensions='permessage-deflate; server_max_window_bits' | awk '/^sec-websocket-extensions/{print $3}')"
# o caso que dá nome a tudo isto: um VALOR que contém o nome da extensão
check 'x; a="permessage-deflate" não é uma oferta de permessage-deflate' \
      "<ausente>" \
      "$(python3 tests/ws-raw.py handshake 127.0.0.1 $P /ws --extensions='x; a="permessage-deflate"' | awk '/^sec-websocket-extensions/{print $3}')"

# --- a fragmentação: 300 bytes em pedaços de 64 ---
check "uma mensagem grande sai FRAGMENTADA, e remonta" \
      "$(printf 'TEXT fin=0 rsv1=0 len=64\nCONT fin=0 rsv1=0 len=64\nCONT fin=0 rsv1=0 len=64\nCONT fin=0 rsv1=0 len=64\nCONT fin=1 rsv1=0 len=44\nmontado 300 bytes\nconteudo-ok True')" \
      "$(python3 tests/ws-raw.py frames 127.0.0.1 $P /big --n=5)"

# --- o keepalive: quem não responde ao ping é mandado embora com 1001 ---
check "um cliente calado é fechado com 1001" \
      "$(printf 'sequencia PING CLOSE\nfechou com 1001')" \
      "$(python3 tests/ws-raw.py keepalive 127.0.0.1 $P /quiet 8)"
# e o contrário, que é o que impede o portão de passar por acidente: quem responde
# sobrevive a mais de um ciclo
check "um cliente que responde ao ping SOBREVIVE" \
      "$(printf 'pings respondidos 2\nainda aberta True')" \
      "$(python3 tests/ws-raw.py pong 127.0.0.1 $P /quiet 8)"
para

# --- o RSV1 vai SÓ no primeiro quadro de uma mensagem fragmentada (§6.1) ---
arranca 8 20.0 10.0
check "o RSV1 é da MENSAGEM e não do quadro" \
      "$(printf 'TEXT fin=0 rsv1=1 len=8\nCONT fin=1 rsv1=0 len=8')" \
      "$(python3 tests/ws-raw.py frames 127.0.0.1 $P /big --n=2 --extensions='permessage-deflate' | head -2)"
para

# ---------- 4. e a remontagem, contra a `websockets` ----------

python3 -c "import websockets" 2>/dev/null || { echo "   ws-features: sem a lib websockets, a remontagem é saltada"; SEM=1; }
SEM=${SEM:-0}
if [ "$SEM" = 0 ]; then
    arranca 8 20.0 10.0
    got=$(python3 - "$P" <<'PY'
import asyncio, sys
import websockets
from websockets.extensions.permessage_deflate import ClientPerMessageDeflateFactory

async def main(port):
    for rotulo, ext in (("com deflate", [ClientPerMessageDeflateFactory(
                             client_no_context_takeover=True,
                             server_no_context_takeover=True)]),
                        ("sem deflate", [])):
        async with websockets.connect(f"ws://127.0.0.1:{port}/big", extensions=ext,
                                      subprotocols=["v1", "v2"]) as ws:
            msg = await ws.recv()
            print(f"{rotulo}: {len(msg)} igual={msg == '0123456789' * 30} proto={ws.subprotocol}")

asyncio.run(main(int(sys.argv[1])))
PY
)
    check "a lib remonta (e descomprime) os nossos fragmentos" \
          "$(printf 'com deflate: 300 igual=True proto=v2\nsem deflate: 300 igual=True proto=v2')" "$got"
    para
fi

echo "   ws-features: $pass ok, $fail failed"
[ "$fail" = 0 ]
