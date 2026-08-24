"""`os.run` contra o `subprocess` do python3 (118 / pforge 1.2).

O par deste arquivo é `proc.py`, e os dois têm de imprimir as MESMAS linhas.
Vale a pena dizer o que este oráculo mede, porque não é a sintaxe: é o
COMPORTAMENTO de um processo — que o status de quem saiu bem é 0, que o de quem
recusou é o número que ele escolheu, que um sinal vira 128+sinal, que o
argumento com espaço não se parte em dois porque não há shell no meio, e que o
ambiente que se dá SUBSTITUI em vez de mesclar.

São exatamente as promessas de que um sistema de build depende — e nenhuma delas
é conferível por leitura: só rodando, dos dois lados.
"""
import os

async def go():
    r = await os.run(["/bin/echo", "ola"])
    print(r.status(), r.output())

    q = await os.run(["/bin/echo", "a b", "c"])
    print(q.status(), q.output())

    bad = await os.run(["/bin/sh", "-c", "exit 7"])
    print(bad.status(), bad.output())

    err = await os.run(["/bin/sh", "-c", "echo um; echo dois >&2"])
    print(err.status(), err.output())

    sig = await os.run(["/bin/sh", "-c", "kill -9 $$"])
    print(sig.status(), sig.output())

    e = await os.run(["/bin/sh", "-c", "echo [$ORACULO][$HOME]"], env={"ORACULO": "1"})
    print(e.status(), e.output())

    c = await os.run(["/bin/pwd"], cwd="/tmp")
    print(c.status(), c.output())

await go()
