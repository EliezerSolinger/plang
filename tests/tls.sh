#!/bin/sh
# tls.sh — o TLS (S7), contra um servidor LOCAL com certificado auto-assinado.
#
# **Hermético de propósito.** Um portão de TLS que fosse à Internet mediria a
# rede tanto quanto o código, e falharia numa máquina sem saída. Aqui o servidor
# é o `openssl s_server` a correr ao lado, com um certificado gerado na hora — e
# um certificado auto-assinado é exactamente o que separa os dois caminhos:
#
#   * `net.starttls` TEM de o recusar (a cadeia não bate);
#   * `net.starttls_insecure` TEM de o aceitar — e é para isso que ele tem esse
#     nome, que aparece num `grep` (141.4).
#
# Salta com uma frase quando não há OpenSSL, em vez de falhar: a dependência é de
# SISTEMA e a sua ausência não é um defeito nosso.
set -u
cd "$(dirname "$0")/.."
# o directório fica DENTRO da árvore, e não em /tmp: sob `--out-dir` o programa
# e o runtime têm de ser nomeados da mesma maneira (os dois relativos), porque o
# `#include` do C gerado é a relação entre eles
T=tests/out/tls-$$
PLANGC=${PLANGC:-build/bin/plangc_s2}
CC=${CC:-cc}
PSDEFS="-D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE"

if ! echo '#include <openssl/ssl.h>' | $CC -fsyntax-only -xc - 2>/dev/null; then
    echo "   SKIP tls: sem os cabeçalhos do OpenSSL (libssl-dev)"
    exit 0
fi
if ! command -v openssl >/dev/null 2>&1; then
    echo "   SKIP tls: sem o comando openssl para levantar o servidor"
    exit 0
fi

mkdir -p "$T"
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT

# o certificado auto-assinado, gerado na hora: nada é comitado, e a validade de
# um dia deixa claro que ele não é para mais nada
openssl req -x509 -newkey rsa:2048 -keyout "$T/k.pem" -out "$T/c.pem" \
    -days 1 -nodes -subj "/CN=localhost" >/dev/null 2>&1 || {
    echo "   FAIL tls: não consegui gerar o certificado"; exit 1; }

PORT=$((20000 + $$ % 20000))
openssl s_server -quiet -accept "$PORT" -cert "$T/c.pem" -key "$T/k.pem" \
    -naccept 4 </dev/null >/dev/null 2>&1 &
SRV=$!
# espera que ele atenda, sem dormir um número mágico
for _ in $(seq 1 50); do
    if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then break; fi
    sleep 0.1
done

cat > "$T/prog.psc" <<'PSC'
import net
import sys


async def tenta(port: int, seguro: bool) -> str:
    c = await net.connect("127.0.0.1", port)
    ok: bool = False
    try:
        if seguro:
            ok = await net.starttls(c, "localhost")
        else:
            ok = await net.starttls_insecure(c, "localhost")
    catch e:
        c.close()
        return "recusou"
    c.close()
    return "aceitou" if ok else "recusou"


async def go(port: int) -> int:
    print("disponivel:", net.tls_available())
    # um certificado AUTO-ASSINADO: a cadeia nao bate, e a verificacao TEM de o
    # recusar. E o que separa os dois caminhos.
    print("com verificacao:", await tenta(port, True))
    print("sem verificacao:", await tenta(port, False))
    return 0


await go(int(sys.argv[1]))
print("tls-ok")
PSC
printf 'disponivel: True\ncom verificacao: recusou\nsem verificacao: aceitou\ntls-ok\n' > "$T/want"

$PLANGC --pkg-path packages -D PSRT_TLS --out-dir "$T/rt" pscript/runtime/psrt.ph 2>"$T/err" || {
    echo "   FAIL tls (runtime): $(sed 's/.*error: //' "$T/err" | head -1)"; exit 1; }
$PLANGC --pkg-path packages -D PSRT_TLS --out-dir "$T/rt" "$T/prog.psc" 2>>"$T/err" || {
    echo "   FAIL tls (programa): $(sed 's/.*error: //' "$T/err" | head -1)"; exit 1; }
$CC -std=c11 $PSDEFS -w -o "$T/prog" "$T/rt/$T/prog.c" "$T"/rt/pscript/runtime/psrt_*.c \
    -lm -pthread -lssl -lcrypto 2>>"$T/err" || {
    echo "   FAIL tls (link): $(tail -1 "$T/err")"; exit 1; }

"$T/prog" "$PORT" > "$T/got" 2>&1
if diff -q "$T/want" "$T/got" >/dev/null 2>&1; then
    echo "   OK tls 3 ok (auto-assinado recusado, e aceite pelo caminho que diz 'insecure')"
    exit 0
fi
echo "   FAIL tls: a saída difere"
diff "$T/want" "$T/got" | head -10
exit 1
