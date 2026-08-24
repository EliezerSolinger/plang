"""`for x in await f():` — o iterável que é uma tarefa (regressão).

O `for` de dentro de um `async def` vira máquina de estados, e o iterável dele
pode carregar um `await`. A metade que LÊ o resultado de uma tarefa é expressão;
a metade que a INICIA e estaciona é feita de estados — e a segunda estava
faltando neste caminho. O C saía lendo um campo que ninguém preencheu: silencioso
na compilação, SIGSEGV na execução.

É a forma mais natural de percorrer o que uma tarefa devolveu, e é o que um
sistema de build escreve o tempo todo.
"""
import os

async def linhas(n: int) -> List<str>:
    r = await os.run(["/bin/echo", "linha" + str(n)])
    out: List<str> = []
    for line in r.output().split("\n"):
        if len(line) > 0:
            out.append(line)
    return out

async def total() -> int:
    soma = 0
    i = 0
    while i < 3:
        for x in await linhas(i):    # o iterável é uma TAREFA
            soma += len(x)
        i += 1
    return soma

async def go():
    print("soma:", await total())
    # e o mesmo com `range`, que é o outro caminho que a máquina de estados sabe
    n = 0
    for k in range(await um(), await tres()):
        n += k
    print("range com await nos dois limites:", n)

async def um() -> int:
    r = await os.run(["/bin/echo", "1"])
    return int(r.output().strip())

async def tres() -> int:
    r = await os.run(["/bin/echo", "3"])
    return int(r.output().strip())

await go()
