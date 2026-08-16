"""Arquivo assíncrono: o pool de threads (76.1/76.2/76.3).

Um socket tem modo não-bloqueante de verdade e vive no `poll` que a 74.1 já
construiu. Um ARQUIVO não tem — `read(2)` bloqueia, sempre — e é por isso que
ele precisa de thread. A divisão é a da libuv, e não é gosto: é o que o sistema
operacional oferece.

Então toda operação de arquivo virou uma TASK: a chamada descreve o trabalho,
entrega ao pool e devolve na hora; a espera acontece no escalonador, ao lado do
relógio e das filas de mensagem. Uma thread do pool nunca toca o heap de
ninguém — ela trabalha em bytes malloc'ados e devolve bytes malloc'ados, e quem
constrói o valor no heap coletado é o escalonador do contexto que pediu.

Três coisas que este teste prende:

  * o I/O SOBREPÕE com o resto — o arquivo e o relógio andam juntos;
  * `read(n)` dá até n bytes e o vazio é o fim (79.2), enquanto `text()` dá
    tudo decodificado e `read_all()` tudo cru (79.1);
  * `try`/`catch` funciona DENTRO de um `async def`, inclusive pegando um erro
    que nasce depois de uma suspensão — o que exige que o guarda de exceção
    salte para o estado do catch em vez de encerrar a task.
"""

import sys

CAMINHO: str = "aio_files_demo.txt"


struct Arquivo:
    nome: str
    lidos: int

    # um método TAMBÉM pode ser `async def` (50.1): é uma função com receptor, e
    # `self` vive no frame como qualquer outro parâmetro
    async def escreve(self, linhas: int) -> int:
        f = await open(self.nome, "w")
        total = 0
        for i in range(linhas):
            total += await f.write("linha " + str(i) + "\n")
        await f.close()
        return total

    async def le_tudo(self) -> str:
        f = await open(self.nome, "r")
        t = await f.text()
        await f.close()
        self.lidos += len(t)
        return t

    async def le_ou_vazio(self, nome: str) -> str:
        try:
            f = await open(nome, "r")
            t = await f.text()
            await f.close()
            return t
        catch e:
            return "<" + e.message + ">"


async def relogio(n: int) -> int:
    k = 0
    for i in range(n):
        await sleep(0.002)
        k += 1
    return k


a = Arquivo(CAMINHO, 0)

# o arquivo e o relógio andam JUNTOS: se o I/O bloqueasse a thread, os dois
# tempos se somariam em vez de se sobreporem
t0 = sys.time()
escrita = a.escreve(4)
tic = relogio(5)
print("escrevi", await escrita, "bytes")
print("ticks", await tic)
print("sobrepos", sys.time() - t0 < 0.05)

print("li", len(await a.le_tudo()), "bytes")
print("acumulado", a.lidos)

# o que falta não explode: o catch está dentro do `async def`
print("faltando", await a.le_ou_vazio("nao/existe/isto.txt"))

# bytes: até n, e o vazio é o fim
f = await open(CAMINHO, "r")
primeiros = await f.read(6)
resto = await f.read_all()
fim = await f.read(8)
print("bytes", len(primeiros), primeiros[0], len(resto), len(fim))
await f.close()

linhas = await (await open(CAMINHO, "r")).readlines()
print("linhas", len(linhas), linhas[0])
