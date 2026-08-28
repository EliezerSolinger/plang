"""O `timeout()` tem de LEVAR O RELÓGIO consigo quando a tarefa ganha.

Ele planta um temporizador para que o escalonador nunca durma para além do prazo.
Se o temporizador não for retirado quando a tarefa ganha, ele fica parado até à
hora dele — e a partir daí qualquer sítio que precise de esgotar o contexto espera
por ele. O programa dá a resposta certa e só termina `seconds` depois.

**A afirmação é o `sched.stats()` e não o relógio de parede**, e isso é de
propósito: medir "acabou depressa" numa máquina partilhada é medir a máquina. O
número que não mente é quantas tarefas ficaram paradas no relógio, e a seguir a um
`timeout` que a tarefa ganhou esse número tem de ser zero.

Foi um `idle_timeout` de trinta segundos num servidor HTTP que encontrou isto:
cada pedido deixava trinta segundos de relógio atrás de si.
"""
import sched


async def quick() -> int:
    await sleep(0.01)
    return 7


async def slow() -> int:
    await sleep(30.0)
    return 9


print("nada parado no princípio:", sched.stats()["parked_deadline"])

# 1. A TAREFA GANHA: o relógio do `timeout` tem de sair com ela
t1 = quick()
won = await timeout(t1, 30.0)
v1 = await t1
print("ganhou a tarefa:", won, "valor:", v1)
print("e o relógio saiu:", sched.stats()["parked_deadline"])

# 2. O RELÓGIO GANHA: a tarefa é cancelada, e o relógio também não fica
t2 = slow()
won2 = await timeout(t2, 0.05)
print("ganhou o relógio:", not won2)
print("e não ficou nada parado:", sched.stats()["parked_deadline"])

# 3. e em SÉRIE, que é a forma de um servidor: cada volta tem de sair limpa
i = 0
while i < 5:
    t = quick()
    ok = await timeout(t, 30.0)
    ignored = await t
    i += 1
print("cinco voltas, e o relógio continua vazio:", sched.stats()["parked_deadline"])
print("timeout_clock-ok")
