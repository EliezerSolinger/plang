"""Um `Channel(1)` como TRINCO, que é o que uma conexão precisa e a linguagem não
tem como tipo próprio.

**Porque é que faz falta.** Uma escrita de socket que não caiba no tampão do
kernel é PARCIAL: o runtime escreve o que cabe, guarda o deslocamento e volta a
dormir no `POLLOUT` (`psrt_rt.p`: *"partial: wait for room and send the rest"*).
Enquanto ela dorme, outra tarefa que escreva no mesmo descritor mete os bytes
dela no meio — e num protocolo com moldura, como o WebSocket, isso não é uma
mensagem trocada: é o fluxo inteiro desalinhado a partir dali.

Não há `Lock` nem `Mutex`, e um `Channel(1)` faz o trabalho. **A inversão é de
propósito**: o canal começa VAZIO e o que ele guarda é "alguém está a escrever".
Assim não há nada a inicializar — a primeira tarefa a `send` entra, a segunda
dorme no canal cheio até a primeira `recv`. Com o sentido contrário (o canal
começa com um testemunho dentro) alguém tem de o pôr lá, e pôr-lo é um `await`
num construtor que é síncrono.

O que este teste afirma é a única propriedade que interessa: **nunca há dois
dentro ao mesmo tempo**, mesmo com as tarefas a ceder o controlo a meio — que é
justamente o que uma escrita parcial faz.
"""
lock: Channel<int> = Channel(1)
order: List<str> = []


async def writer(name: str, rounds: int) -> int:
    for i in range(rounds):
        await lock.send(1)
        order.append(name + "-in")
        # cede o controlo A MEIO da "escrita": é o que uma escrita parcial faz, e
        # sem isto o teste passaria mesmo sem trinco nenhum
        await sleep(0.01)
        order.append(name + "-out")
        ignored = await lock.recv()
    return 0


a = writer("A", 3)
b = writer("B", 3)
await a
await b
print(" ".join(order))

inside = 0
overlaps = 0
for e in order:
    if e.endswith("-in"):
        inside += 1
        if inside > 1:
            overlaps += 1
    else:
        inside -= 1
print("sobreposicoes:", overlaps)
print("chan_lock-ok")
