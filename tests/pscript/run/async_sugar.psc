"""O bloco `async:`, a lambda assíncrona, os combinadores que faltavam e o
console assíncrono (78.2/78.3/79.4).

`async:` faz uma task ali mesmo, sem precisar batizar uma função para isso —
e o que ele usa de fora, ele CAPTURA POR VALOR, exatamente como um lambda
(19.2). Por baixo vira um `async def` cujos parâmetros são o que foi
capturado, então daí para a frente é uma task como qualquer outra.

`gather` já era o `Promise.all` (resultados na ordem DADA, não na de chegada).
Faltavam os irmãos: `gather_settled` espera TODAS e devolve o erro de cada uma
— None onde deu certo —, e a primeira falha não derruba o conjunto;
`first_ok` devolve o índice da primeira que deu CERTO e cancela o resto.

E `print` continua síncrono, porque é o canal de diagnóstico da linguagem e um
`await` em cada linha envenenaria todo programa; quem precisa que a escrita
espere usa `aprint`, ou `sys.out`/`sys.err`, que são arquivos comuns.
"""

import sys

feito: list<str> = []


async def espera(ms: int, nome: str) -> int:
    await sleep(float(ms) / 1000.0)
    feito.append(nome)
    return ms


async def falha(nome: str) -> int:
    await sleep(0.001)
    raise error("caiu: " + nome, VALUE)
    return 0


# ---- o bloco, com captura ----
def dispara(rotulo: str) -> int:
    t = async:
        await espera(2, "bloco de " + rotulo)
    return 0


dispara("um")

# no topo também, e sem guardar a task: a drenagem do fim (77.3) termina esta
async:
    await espera(1, "solta")

# ---- os combinadores ----
ts = [espera(3, "a"), falha("b"), espera(1, "c")]
erros = await gather_settled(ts)
print("quantas", len(erros))
for i in range(len(erros)):
    e = erros[i]
    if e != None:
        print(i, "falhou:", e.message)
    else:
        print(i, "deu", await ts[i])

quais = [falha("x"), espera(2, "vencedora"), falha("y")]
print("primeira que deu certo:", await first_ok(quais))

# ---- a lambda assíncrona ----
# ela é DUAS coisas que já funcionavam: um `async def` para o corpo (a máquina
# de estados) e um lambda comum que o chama (o ambiente de captura). Compor as
# duas seria novo; empilhar uma sobre a outra não é.
fator = 100
dobra: def(int) -> Task<int> = async lambda x: await espera(1, "lambda " + str(x)) + fator
print("lambda:", await dobra(5))

# ---- o console ----
n = await aprint("escrito pelo pool", 42)
print("aprint devolveu", n, "bytes")
await sys.out.write("direto no stdout\n")
sys.out.close()
print("stdout continua vivo, porque ele é do processo")
