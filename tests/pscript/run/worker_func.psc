"""148/D3b: uma FUNÇÃO atravessa para um worker.

Parece violar a 18.1 e não viola, e a distinção é o que faz esta fase existir.

O que a 18.1 isola são HEAPS: nenhum worker vê um objeto coletado de outro,
porque o coletor de lá mexe-o e o ponteiro de cá deixaria de valer. Mas dois
workers são threads do MESMO processo, e partilham o espaço de endereços do
BINÁRIO — o código, as constantes, os descritores estáticos. **Um `def` de topo é
um símbolo**: o mesmo endereço em toda a thread, e nada dele mora no heap.
Atravessar é copiar um número.

O que resta é o AMBIENTE de uma lambda, e esse mora no heap. Copia-se como
qualquer mensagem, desde que não tenha lá dentro nada que o coletor siga — e essa
pergunta já tinha resposta pronta antes de alguém a fazer: **o compilador só
escreve um `trace` no descritor quando há uma referência para seguir.** Portanto
`env->desc->trace == None` É a prova de "capturas todas POD" (19.2), sem uma
marca nova e sem o compilador ter de dizer nada.

A recusa é por isso **a correr e não a compilar**, e tinha de ser: o tipo
`def(int) -> int` não distingue o símbolo da lambda, e qual dos dois está à frente
só se sabe quando há um valor. A mensagem diz as duas saídas.

Vale no `spawn` e no `send` — uma regra sem excepção ensina-se, uma com excepção
decora-se.

E há um guarda que este ficheiro é o único a cobrar: os argumentos de um `spawn`
são preenchidos ANTES da chamada, e a verificação da exceção só chega no fim da
instrução. Sem o guarda no `ps_worker_new`, a recusa saía certa e logo a seguir
partia uma thread com um argumento por preencher — um SIGSEGV noutra thread, que
é o pior de dois mundos.
"""

def double_v(x: int) -> int:
    return x * 2

def apply_v(f: def(int) -> int, n: int) -> int:
    total: int = 0
    for i in range(n):
        total += f(i)
    parent.send(total)
    return total


# ---- 1. um `def` de topo, que é o caso que o servidor precisa ----
w1 = spawn(apply_v, (double_v, 5))
print("def de topo:", await w1.recv())


async def with_capture():
    # ---- 2. uma lambda cujas capturas são todas POD ----
    #
    # `k` é LOCAL de propósito: um nome de topo é uma global, e uma global é do
    # worker (42.2) — não seria captura nenhuma, e o teste passaria por engano.
    k: int = 100
    g: def(int) -> int = lambda a: a * 2 + k
    w2 = spawn(apply_v, (g, 5))
    print("lambda POD:", await w2.recv())

    # ---- 3. e a que captura algo do coletor, que é recusada ----
    s: str = "abcdefgh"
    h: def(int) -> int = lambda a: a + len(s)
    try:
        w3 = spawn(apply_v, (h, 5))
        print("NÃO devia chegar aqui:", await w3.recv())
    catch e:
        print("recusada:", e.message[:52])

    # o contexto continua são depois da recusa: o worker que voltou já vinha
    # terminado, e nada partiu
    w4 = spawn(apply_v, (double_v, 3))
    print("depois da recusa:", await w4.recv())


# ---- 4. e a outra metade da regra: por MENSAGEM, a um worker já a correr ----
#
# Aqui a função atravessa pela FORMA (`PS_SH_FUNC`) e não pelo bloco do `spawn`,
# que é outro caminho no runtime. Um worker é UM cano nos dois sentidos (36.1),
# portanto o tipo da mensagem é um só — e neste é a própria função.
def triple(x: int) -> int:
    return x * 3

async def servo(n: int) -> def(int) -> int:
    # DUAS mensagens, contadas — e não `while parent.open()`.
    #
    # O predicado responde "ainda pode chegar mensagem", e entre a resposta e o
    # `recv` a fila pode esvaziar (107.8): o laço já entrou e lê um vazio. Isso
    # levanta desde a 148 em vez de dar um ponteiro nulo, o que é muito melhor —
    # mas continua a ser uma corrida, e uma corrida não é um portão. Aqui o
    # número é sabido, então conta-se.
    total: int = 0
    for i in range(2):
        f: def(int) -> int = await parent.recv()
        total += f(n)
    print("o worker somou:", total)
    # a resposta é ela própria uma função, e volta pela subida
    parent.send(double_v)
    return double_v

async def by_message():
    w = spawn(servo, (7,))
    s: str = "abcd"
    h: def(int) -> int = lambda a: a + len(s)
    try:
        print("NÃO devia aceitar:", w.send(h))
    catch e:
        print("recusada no send:", e.message[:52])
    # a recusa é de QUEM ESCREVE, e o worker do outro lado nem soube dela
    print("aceites:", w.send(double_v), w.send(triple))
    # a resposta do worker é ela própria uma função: chama-se aqui, deste lado
    back: def(int) -> int = await w.recv()
    print("a resposta do worker, chamada aqui:", back(21))
    w.close()

# ---- 5. e o VAZIO, que este trabalho desenterrou ----
#
# A 107.8 escolheu "mensagem vazia quando não há mais nada", e isso estava certo
# quando uma mensagem era bytes: o vazio de um número é um zero, e um zero é um
# valor. A escada da 34.3 depois deixou passar `str`, listas, dicionários,
# `struct` — e agora funções. Para esses o vazio era o PONTEIRO NULO, que não é
# valor nenhum, e o primeiro uso dele era um SIGSEGV numa thread sem pilha para
# ler. Agora levanta.
async def quiet(n: int) -> str:
    return "isto nunca é enviado — `return` não é `send`"

async def empty():
    w = spawn(quiet, (1,))
    try:
        s: str = await w.recv()
        print("NÃO devia chegar aqui:", len(s))
    catch e:
        print("vazio:", e.message[:40])

await with_capture()
await by_message()
await empty()
