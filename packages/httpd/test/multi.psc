"""N workers no mesmo porto (F3/D12), para o portão contar quantos servem.

É aqui que as três peças da linguagem se juntam, e nenhuma era acessória:

  * **L1** — o handler ATRAVESSA para o worker como argumento do `spawn`. Um
    `def` de topo é um símbolo, o mesmo endereço em toda a thread do mesmo
    binário;
  * **L2** — `SO_REUSEPORT`: os N escutam o MESMO porto e o kernel reparte. Sem
    aceitador único (que seria o gargalo) e sem thundering herd;
  * **L4** — uma difusão alcança os N, para que ela chegue a um jogador esteja ele
    no worker que estiver.

Cada resposta diz QUEM a serviu, e o portão bate N vezes e conta as respostas
distintas. O que ele NÃO afirma é a proporção: é uma dispersão da quádrupla feita
pelo kernel, e prendê-la seria prender a hash de outra pessoa. Afirma que mais de
um serve, que é o que a fase é.
"""
import <httpd/httpd.psc> as httpd
import os
import sys
import topic


# O ESTADO POR WORKER, e a lição que custou um SIGSEGV para ficar clara.
#
# Uma global é do worker (42.2) — cada um tem a sua, sem lock nenhum, e é a
# demonstração mais curta do modelo. Mas o worker **não corre o topo do
# programa**, portanto o INICIALIZADOR não corre lá: um `List<int> = [0]` é
# `None` dentro do worker, e não uma lista com um zero.
#
# Um `struct` com números resolve-o, porque um struct nasce onde é construído — e
# o worker constrói o seu no princípio. Fica-se com o mesmo isolamento e sem a
# armadilha.
struct Estado:
    eu: int
    servidos: int
    recebidas: int


estado: Estado? = None


def meu() -> Estado:
    """O estado deste worker, construído à primeira pergunta. Um `T?` que se
    enche no primeiro uso é o que substitui um inicializador de topo dentro de um
    worker."""
    global estado
    e = estado
    if e != None:
        return e
    novo = Estado(0, 0, 0)
    estado = novo
    return novo


async def handle(req: httpd.Request) -> httpd.Response:
    e = meu()
    if req.path == "/quem":
        e.servidos += 1
        return httpd.text(str(e.eu))
    if req.path == "/servi":
        return httpd.text(str(e.eu) + ":" + str(e.servidos))
    if req.path == "/difunde":
        n = topic.publish("todos", b"ola de um worker")
        return httpd.text(str(n))
    if req.path == "/recebi":
        return httpd.text(str(e.eu) + ":" + str(e.recebidas))
    return httpd.status_code(404)


async def espia() -> int:
    """Cada worker assina o tópico e conta o que recebe, para o portão ver que
    uma difusão atravessa os workers."""
    topic.subscribe("todos")
    while True:
        d = await topic.recv()
        meu().recebidas += 1


# O ADAPTADOR, e a razão de ele existir: o `spawn` só aceita uma função DO
# PROGRAMA, não de um módulo importado. Portanto uma biblioteca não pode oferecer
# um `serve(porta, handle, workers=N)` que se lance a si mesma — quem lança é
# sempre o programa, com estas linhas. Fica registado nos ACHADOS.
async def trabalhador(h: def(httpd.Request) -> Task<httpd.Response>, porta: int, n: int) -> int:
    meu().eu = n
    c = httpd.config()
    c.debug = True
    srv = httpd.listen(porta, c, True)
    t = espia()
    await httpd.run(srv, h)
    return 0


quantos = int(sys.argv[2]) if len(sys.argv) > 2 else 3

# o PRIMEIRO abre o porto e diz qual é; os outros ligam-se ao MESMO
meu().eu = 1
cfg = httpd.config()
cfg.debug = True
srv0 = httpd.listen(0, cfg, True)
porto = srv0.port
f = await open(sys.argv[1], "w")
await f.write(str(porto))
f.close()

trabalhadores: List<Worker<int>> = []
for i in range(quantos - 1):
    trabalhadores.append(spawn(trabalhador, (handle, porto, i + 2)))

t0 = espia()
await httpd.run(srv0, handle)
