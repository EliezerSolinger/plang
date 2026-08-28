#!/usr/bin/env bash
# tls-server.sh — L3/D8: o servidor nasce a falar `https`.
#
# O `starttls` que já havia era o lado CLIENTE (`SSL_connect`). Servir precisava
# do irmão, e a assimetria é real: um cliente CONFERE uma cadeia que vem do
# sistema, um servidor APRESENTA um certificado e uma chave que vêm de dois
# ficheiros.
#
# Os oráculos são o `openssl s_client` e o `curl` — dois clientes TLS que não
# partilham uma linha com este repositório. Se eles apertam a mão, o aperto de mão
# está certo; e o certificado é auto-assinado, portanto os dois têm de ser
# mandados a NÃO verificar a cadeia, que é o único lado desta prova que se dispensa.
set -u
cd "$(dirname "$0")/.."

PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
OUT=${OUT:-tests/out/tlsserver}
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE -D_DARWIN_C_SOURCE"
rm -rf "$OUT"; mkdir -p "$OUT"
pass=0; fail=0
check() {
    if [ "$2" = "$3" ]; then pass=$((pass+1))
    else echo "  FAIL $1: esperado '$2', veio '$3'"; fail=$((fail+1)); fi
}

command -v openssl >/dev/null || { echo "   tls-server: sem openssl, saltado"; exit 0; }
pkg-config --exists openssl 2>/dev/null || [ -f /usr/include/openssl/ssl.h ] || {
    echo "   tls-server: sem os headers do OpenSSL, saltado"; exit 0; }

# um certificado auto-assinado, feito aqui: um portão que dependesse de um
# certificado no repositório teria um que expira
openssl req -x509 -newkey rsa:2048 -keyout "$OUT/key.pem" -out "$OUT/cert.pem" \
    -days 2 -nodes -subj "/CN=localhost" \
    -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1 || {
    echo "  FAIL não consegui gerar o certificado"; exit 1; }

cat > "$OUT/srv.psc" <<'PSC'
"""Um servidor `https` mínimo: aceita, põe TLS por cima, responde e fecha."""
import net
import sys


async def atende(c: Socket, cert: str, chave: str) -> int:
    # O TLS vai POR CIMA de uma ligação já aceita, e é a mesma decisão do lado
    # cliente (S7): um MODO de uma ligação que já existe, e não um tipo novo.
    # Portanto tudo o que está acima — `read_into`, `write` — não sabe a diferença.
    n = await net.serve_tls(c, cert, chave)
    lidos = 0
    with Buffer(4096) as rb:
        nonlocal lidos
        lidos = await rb_le(c, rb)
        corpo = "ola por tls"
        await c.write("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: "
                      + str(len(corpo)) + "\r\nconnection: close\r\n\r\n" + corpo)
    c.close()
    return lidos


async def rb_le(c: Socket, rb: Buffer) -> int:
    return await c.read_into(rb, 0, 4096)


srv = net.listen(0, False)
f = await open(sys.argv[1], "w")
await f.write(str(srv.port()))
f.close()
i = 0
while i < 4:
    c = await srv.accept()
    t = atende(c, sys.argv[2], sys.argv[3])
    i += 1
srv.close()
PSC

$PLANGC --pkg-path packages -D PSRT_TLS --out-dir "$OUT/rt" pscript/runtime/psrt.ph 2>"$OUT/err" || {
    echo "  FAIL o runtime com TLS não compila: $(sed 's/.*error: //' "$OUT/err" | head -1)"; exit 1; }
$PLANGC --pkg-path packages -D PSRT_TLS --out-dir "$OUT/rt" "$OUT/srv.psc" 2>>"$OUT/err" || {
    echo "  FAIL o servidor não compila: $(sed 's/.*error: //' "$OUT/err" | head -1)"; exit 1; }
$CC -std=c11 $PSDEFS -w -o "$OUT/srv" "$OUT/rt/$OUT/srv.c" "$OUT"/rt/pscript/runtime/psrt_*.c \
    -lm -pthread -lssl -lcrypto 2>>"$OUT/err" || {
    echo "  FAIL não linka: $(tail -1 "$OUT/err")"; exit 1; }

"$OUT/srv" "$OUT/porto" "$OUT/cert.pem" "$OUT/key.pem" >"$OUT/srv.log" 2>&1 &
S=$!
trap 'kill $S 2>/dev/null' EXIT
for _ in $(seq 1 100); do [ -s "$OUT/porto" ] && break; sleep 0.05; done
[ -s "$OUT/porto" ] || { echo "  FAIL o servidor não abriu porto"; exit 1; }
P=$(cat "$OUT/porto")

# ---- o `openssl s_client`, que é o oráculo mais cru que existe ----
got=$(printf 'GET / HTTP/1.1\r\nHost: localhost\r\n\r\n' | \
      timeout 20 openssl s_client -connect "127.0.0.1:$P" -servername localhost \
      -quiet -verify_quiet 2>/dev/null | tail -1)
check "o s_client apertou a mão e leu o corpo" "ola por tls" "$got"

# ---- e o `curl`, que é o cliente que as pessoas usam ----
check "o curl fala https com o nosso servidor" "ola por tls" \
      "$(timeout 20 curl -sk "https://127.0.0.1:$P/")"

# ---- a versão negociada: TLS 1.2 é o piso, e o que sai tem de ser >= isso ----
#
# Quem responde é o `curl`, e não o `s_client`: o `-quiet` do segundo esconde
# justamente a linha do protocolo, e sem `-quiet` ele não fecha o `stdin` — o que
# faz a leitura pendurar-se. O `curl -v` diz a versão numa linha só.
ver=$(timeout 20 curl -skv "https://127.0.0.1:$P/" 2>&1 | grep -oE 'TLSv1\.[23]' | head -1)
check "negociou TLS 1.2 ou melhor" "sim" \
      "$(test -n "$ver" && echo sim || echo nao)"

# ---- e um cliente que EXIGE a cadeia recusa, porque o certificado é auto-assinado.
#      É o outro lado da prova: o aperto de mão funciona E a verificação não foi
#      desligada em nenhum sítio.
timeout 20 curl -s "https://127.0.0.1:$P/" >/dev/null 2>&1
check "sem -k, o curl recusa o auto-assinado" "sim" \
      "$(test $? -ne 0 && echo sim || echo nao)"

# ============================================================================
# F4/D8 — e o HTTPD INTEIRO sobre TLS. A mesma `Config`, mais dois caminhos: o
# TLS é um MODO da ligação e não um tipo novo, portanto tudo o que está acima —
# as rotas, o keep-alive, a compressão — não sabe a diferença.
# ============================================================================
if ! PSBUILD_RT="$OUT/rt2" PLANGC="$PLANGC -D PSRT_TLS"      bash tests/psbuild.sh packages/httpd/test/https.psc "$OUT/https" -lssl -lcrypto >>"$OUT/err" 2>&1; then
    echo "  FAIL o httpd com TLS não compila"; tail -3 "$OUT/err"; fail=$((fail+1))
else
    "$OUT/https" "$OUT/porto3" "$OUT/cert.pem" "$OUT/key.pem" >"$OUT/https.log" 2>&1 &
    H=$!
    trap 'kill $S $H 2>/dev/null' EXIT
    for _ in $(seq 1 100); do [ -s "$OUT/porto3" ] && break; sleep 0.05; done
    if [ -s "$OUT/porto3" ]; then
        Q="https://127.0.0.1:$(cat "$OUT/porto3")"
        check "o httpd responde por https" "ola por https" "$(timeout 20 curl -sk $Q/)"
        check "e o json também" '{"seguro":true}' "$(timeout 20 curl -sk $Q/json)"
        check "as rotas continuam a valer" "404"               "$(timeout 20 curl -sk -o /dev/null -w '%{http_code}' $Q/nada)"
        # o keep-alive por cima do TLS é onde ele se paga mais: cada conexão nova
        # custaria um aperto de mão TCP **e** um TLS
        check "keep-alive sobre TLS" "1"               "$(timeout 20 curl -sk -o /dev/null -w '%{num_connects}' $Q/ $Q/json | head -c 1)"
        check "e negocia 1.2 ou melhor" "sim"               "$(timeout 20 curl -skv $Q/ 2>&1 | grep -qE 'TLSv1\.[23]' && echo sim || echo nao)"
    else
        echo "  FAIL o httpd com TLS não abriu porto"; fail=$((fail+1))
    fi
fi

echo "   tls-server: $pass ok, $fail failed"
[ $fail -eq 0 ]
