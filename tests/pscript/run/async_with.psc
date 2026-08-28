"""`with await ...` dentro de um `async def` (148).

A forma é a normal de abrir um ficheiro numa função assíncrona, e não compilava:

    async def ler(p: str) -> int:
        with await open(p, "r") as f:
            ...

O erro que saía falava de um campo do frame que não existe, num sítio sem relação
nenhuma com o `await` — porque a causa estava noutra passada.

A máquina de estados de um `async def` guarda no frame uma MARCA por limpeza
armada, para saber, a cada saída do bloco, o que já foi libertado. Quem a escreve
arma-a SEMPRE; quem monta o frame só a declarava quando o CORPO do `with`
suspendia. Um `with await open(...)` suspende no CABEÇALHO, não no corpo — e
então uma escrevia numa marca que a outra não tinha declarado.

As duas condições passam a ser a mesma. É a mesma família de defeito que o
`for` com cursor já tinha resolvido do jeito certo: os dois lados calculam o nome
a partir da POSIÇÃO, e por isso não podem divergir — o que faltava era a
condição, não o nome.
"""
import os
import path


async def tamanho(caminho: str) -> int:
    # o CABEÇALHO suspende e o corpo não: era exactamente este o caso
    with await open(caminho, "r") as f:
        return f.size()


async def primeiros(caminho: str, n: int) -> str:
    # ... e agora com um segundo `with` lá dentro, que era a forma que o
    # `packages/httpd/files.psc` precisava para servir um `Range`
    with await open(caminho, "r") as f:
        with Buffer(4096) as buf:
            k = os.pread(f, buf, 0, n)
            return str(bytes(buf[0:k]))


async def apanha(caminho: str) -> str:
    # e a saída pelo ERRO também liberta: o `with` baixa para um `defer`, e o
    # `defer` corre em toda a saída do bloco
    try:
        with await open(caminho, "r") as f:
            raise error("rebentei com o ficheiro aberto")
    catch e:
        return e.message
    return "nao chegou aqui"


alvo = path.join(os.tempdir(), "psrt-async-with.txt")
g = await open(alvo, "w")
await g.write("ola mundo asincrono")
g.close()

print("tamanho:", await tamanho(alvo))
print("primeiros:", await primeiros(alvo, 3))
print("erro:", await apanha(alvo))
os.remove(alvo)
