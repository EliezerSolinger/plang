"""Guardar num CAMPO um valor que ALOCA (118).

Dentro de um `async def` todo local mora no quadro, e o quadro é um objeto do
heap que o coletor MOVE. Então `x = f()` não é uma atribuição a uma variável do
C: é `__fr->x = f(...)`. E aí mora uma armadilha que o C não avisa.

Em `__fr->x = f(...)` a ordem entre CALCULAR o endereço da esquerda e CHAMAR a
direita não está definida pela linguagem. O gcc carrega `__fr` num registrador,
`f` aloca, a coleta acontece lá dentro, o quadro é copiado para o outro lado e a
pilha de sombra é consertada — e a escrita, que já tinha o endereço na mão, vai
para o quadro VELHO. O valor não chega. Não há erro, não há aviso: a função
devolve zero, ou a string fica pela metade, e o programa segue.

Foi assim que o `restat` do sistema de build passou a comparar 0 com 0 e a
recompilar tudo: `content_hash` devolvia zero de dentro de um `await`.

O conserto é calcular o valor numa temporária ANTES da escrita — o mesmo
`value_first` que a DECLARAÇÃO de um local já usava, agora também na atribuição,
no `+=`, no `:=` e no `return`. As quatro formas estão aqui, e cada uma chama
algo que aloca de verdade (concatenação, uma volta por `str`, uma lista).

Este programa é do corpo que `tests/gc-stress.sh` roda com o coletor a cada
ponto seguro, que é onde a armadilha vive: sem coleta no meio, tudo passa.
"""

const OFF: u64 = 0xcbf29ce484222325
const PRIME: u64 = 0x100000001b3


def fnv(seed: u64, s: str) -> u64:
    """Aloca a cada volta: `ch` é uma string de um caractere."""
    h = seed
    for ch in s:
        h = (h ^ u64(ord(ch))) %* PRIME
    return h


def junta(n: int) -> str:
    out = ""
    for i in range(n):
        out += "<" + str(i) + ">"
    return out


async def devolve_hash(s: str) -> u64:
    # `return <chamada que aloca>` — o campo `__ret` do quadro
    await sleep(0.0)
    return fnv(OFF, s)


async def acumula(n: int) -> str:
    # `x = ...` e `x += ...` num campo do quadro
    texto = ""
    i = 0
    while i < n:
        texto = texto + junta(1)
        texto += "|"
        i += 1
    await sleep(0.0)
    return texto


async def morsa(n: int) -> int:
    # `:=` num campo do quadro
    await sleep(0.0)
    if (t := junta(n)) != "":
        return len(t)
    return -1


async def numa_lista(n: int) -> int:
    # o mesmo, guardando num objeto que NÃO é o quadro: uma lista
    xs: List<str> = []
    for i in range(n):
        xs.append(junta(i))
    await sleep(0.0)
    total = 0
    for x in xs:
        total += len(x)
    return total


async def go():
    esperado = fnv(OFF, "constante\n")
    print("hash de fora:", str(esperado))
    print("hash de dentro bate:", await devolve_hash("constante\n") == esperado)

    a = await acumula(4)
    print("acumulado:", a, len(a))

    print("morsa:", await morsa(3))
    print("na lista:", await numa_lista(5))


await go()
