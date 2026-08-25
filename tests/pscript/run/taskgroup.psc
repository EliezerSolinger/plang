"""`taskgroup()` e `sched.stats()` (S3/147.3/147.4).

**O `gather` já é o `Promise.all`, e melhor** — temos `gather_settled`,
`first_ok`, um `race` que CANCELA os perdedores e um `gather_map` com limite que
o JavaScript não tem. Portanto um grupo não vem recolher resultados. Vem trazer
três garantias que nenhum deles dá, e as três são sobre TEMPO DE VIDA:

1. **criar tarefas DENTRO do âmbito** — `g.spawn` pode estar num `for`, num `if`
   ou no corpo de uma tarefa que já está no grupo; a um `gather` a correr não se
   acrescenta nada;
2. **nenhuma tarefa sobrevive ao bloco** — hoje uma tarefa criada e não aguardada
   é drenada no fim do PROGRAMA (77.3), não no fim da função, e o erro dela sai
   no stderr em vez de sair no sítio de quem chamou;
3. **a primeira FALHA mata as irmãs** — o `race` fica com o primeiro RESULTADO;
   um grupo quer o contrário.

**147.4 — um grupo não recolhe VALORES, e é de propósito.** O `gather` é
homogéneo (`List<Task<T>>`) por bons motivos, e as tarefas de um bloco não têm
razão nenhuma para devolver todas a mesma coisa. Quem quer o valor lê-o da
variável que guardou, que é o que o `race` já dizia por extenso.

**147.3 — a saída ARRASTA o escalonador, e não é um `await`.** A libertação de um
`with` é um `defer` de P, uma chamada síncrona; e a peça certa já existia — o
mesmo `ps_task_wait` que faz um `await` num `def` normal e no topo do programa.
Ele não para a thread: arrasta o laço até a tarefa acabar, e no caminho corre
toda a gente.
"""
import sched


async def trabalha(n: int) -> int:
    await sleep(0.01 * float(n))
    print("acabou", n)
    return n


async def falha(n: int) -> int:
    await sleep(0.01)
    raise error("rebentou em " + str(n))


async def demora() -> int:
    # cinco segundos. Se o grupo não cancelasse as irmãs, este portão levaria
    # cinco segundos a passar — que é a maneira de o ver falhar.
    await sleep(5.0)
    print("ISTO NAO DEVIA APARECER")
    return 0


async def bom() -> int:
    with taskgroup() as g:
        for i in range(3):
            g.spawn(trabalha(i + 1))
        print("dentro do bloco, e nenhuma acabou ainda")
    print("e a saida esperou por todas")
    return 0


async def mau() -> int:
    try:
        with taskgroup() as g:
            g.spawn(falha(7))
            g.spawn(demora())
        print("ISTO NAO DEVIA APARECER")
    catch e:
        print("a falha subiu na fronteira do bloco:", e.message)
    return 0


async def medido() -> int:
    # `sched.stats()` (S3): o item 44 da interseção, e o modelo é o `gc.stats()`
    # da 110. O número que faz falta não é quantas tarefas há — é quantas estão
    # paradas E POR QUE RAZÃO, que é o que transforma um travamento de adivinha
    # em leitura.
    t1 = trabalha(20)
    t2 = trabalha(21)
    await sleep(0.01)
    st = sched.stats()
    print("parados no relogio:", st["parked_deadline"])
    print("e o total bate:", st["parked"] == st["parked_deadline"] + st["parked_message"] + st["parked_descriptor"] + st["parked_pool"])
    print("sem workers e sem descritores:", st["workers"], st["parked_descriptor"])
    await t1
    await t2
    depois = sched.stats()
    print("depois nao ha ninguem parado:", depois["parked"])
    return 0


await bom()
await mau()
await medido()
print("taskgroup-ok")
