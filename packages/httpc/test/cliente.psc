"""O cliente contra o NOSSO servidor: um portão que fecha o círculo.

É o teste mais valioso destes dois pacotes, e a razão é o parser: o servidor e o
cliente têm uma máquina de estados só. Portanto se o círculo fecha, ele fecha nos
dois sentidos — e se algum deles divergir do RFC, divergem juntos e o oráculo de
fora (o `curl` no servidor, o `websockets` do Python no ws) apanha-o.
"""
import <httpc/httpc.psc> as hc
import <ws/ws.psc> as ws
import sys


base = "http://127.0.0.1:" + sys.argv[1]

r1 = await hc.get(base + "/")
print("get:", r1.status, r1.texto())

r2 = await hc.get(base + "/nao-existe")
print("404:", r2.status)

r3 = await hc.post(base + "/eco", b"0123456789")
print("post:", r3.status, r3.texto())

r4 = await hc.get(base + "/json")
print("json:", r4.texto())

# o gzip, pedido e desfeito sem que quem chama saiba
r5 = await hc.get(base + "/grande")
print("gzip:", r5.status, len(r5.body), r5.header("content-encoding"))

# um redirect, seguido e contado
r6 = await hc.get(base + "/parati")
print("redirect:", r6.status, r6.redirects, r6.url_final.endswith("/"))

# ... e NÃO seguido, quando o tecto é zero
p7 = hc.pedido("GET", base + "/parati")
p7.max_redirects = 0
try:
    r7 = await hc.fetch(p7)
    print("com tecto zero: NAO devia chegar aqui")
catch e:
    print("com tecto zero:", e.message[:22])

# HEAD: os cabeçalhos e nada de corpo
r8 = await hc.head(base + "/")
print("head:", r8.status, len(r8.body))

# o desmontar de URLs, que é onde os enganos vivem
for s in ["http://a.b/c", "https://a.b", "http://a.b:8080/x?y=1",
          "http://[::1]:99/z", "ftp://a.b/", "http://user:pw@a.b/", "nao-e-url"]:
    a = hc.parse_alvo(s)
    if a.ok:
        print("url:", s, "->", a.esquema, a.host, a.porta, a.caminho)
    else:
        print("url:", s, "-> recusado")

# ---- e o WEBSOCKET, contra o nosso próprio servidor ----
if len(sys.argv) > 2:
    w = await hc.ws_connect("ws://127.0.0.1:" + sys.argv[2] + "/ws")
    # o estreitamento de um `T?` prova-se num LOCAL (43.1), portanto cada
    # mensagem passa por um
    e1 = await w.recv()
    if e1 != None:
        # o número da conexão está na mensagem e depende de quantas já houve —
        # afirmar o texto inteiro tornaria o portão sensível à ordem dos testes
        print("ws boas-vindas:", e1.text().startswith("bem-vindo"))
    ok = await w.send_text("ola do nosso cliente")
    e2 = await w.recv()
    if e2 != None:
        print("ws eco:", e2.text())
    ok2 = await w.send_bytes(b"\x00\x01\xfe\xff")
    e3 = await w.recv()
    if e3 != None:
        print("ws binario:", e3.data.hex())
    # uma mensagem grande, que obriga o comprimento de 16 bits do quadro
    ok3 = await w.send_text("x" * 70000)
    e4 = await w.recv()
    if e4 != None:
        print("ws 70k:", len(e4.data))
    ok4 = await w.close(1000, "acabei")
    print("ws fechou:", ok4)
