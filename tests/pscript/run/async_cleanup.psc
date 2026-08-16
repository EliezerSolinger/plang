"""Limpeza dentro de `async def`: `defer`, `with` e `finally` (50.1/80.2).

Uma função `async` vira máquina de estados, e o passo dela RETORNA toda vez que
a task suspende. Por isso ela não pode usar o `defer` do P: o P roda o corpo do
defer em cada `return`, e a limpeza dispararia numa suspensão — que é
exatamente quando ela não pode rodar. (Era o que acontecia: medido, o corpo do
defer aparecia antes do `return` do estacionamento.)

A saída é armar um BIT no frame para cada limpeza e rodar as armadas, em ordem
inversa, em toda saída DE VERDADE — `return`, falha, e o fim do corpo. Uma
suspensão não roda nada.

O `with` fecha ao sair do bloco (e desarma o bit), então uma saída posterior
não fecha de novo; se a saída for por erro ou por `return` de dentro do bloco,
quem fecha é o caminho da saída. E o fechamento é o BLOQUEANTE mesmo agora que
`await f.close()` existe (80.2): limpeza também roda com exceção pendente, e
esperar no meio de um desenrolar faria a própria limpeza virar estado.
"""

ordem: list<str> = []

CAMINHO: str = "async_cleanup_demo.txt"


async def prepara() -> int:
    f = await open(CAMINHO, "w")
    n = await f.write("uma linha\n")
    await f.close()
    return n


async def dois_defers(n: int) -> int:
    defer:
        ordem.append("defer externo")
    await sleep(0.001)
    defer:
        ordem.append("defer interno")
    await sleep(0.001)
    return n * 2


async def le_com_with() -> int:
    with await open(CAMINHO, "r") as f:
        t = await f.text()
        ordem.append("dentro do with")
        # sair por `return` de dentro do bloco: quem fecha é a saída
        return len(t)


async def with_que_falha() -> int:
    try:
        with await open(CAMINHO, "r") as f:
            await f.text()
            raise error("no meio do with", VALUE)
    catch e:
        ordem.append("peguei: " + e.message)
    return -1


async def com_finally(quebra: bool) -> int:
    try:
        await sleep(0.001)
        if quebra:
            raise error("quebrou", VALUE)
        ordem.append("corpo ok")
    catch e:
        ordem.append("catch: " + e.message)
    finally:
        ordem.append("finally")
    return 1


print("escrevi", await prepara())
print("defers", await dois_defers(21))
print("with", await le_com_with())
print("erro", await with_que_falha())
print("finally ok", await com_finally(False))
print("finally erro", await com_finally(True))
for s in ordem:
    print("  ", s)
