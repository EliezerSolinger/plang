# 50.1: um `await` dentro de uma limpeza é recusado — e a recusa mora no sítio
# por onde os TRÊS passam (`defer`, `with`, `finally`), porque o `finally`
# tinha-se esquecido dela e o que ele emitia era a metade de trás de um `await`:
# a leitura do resultado de uma tarefa que nunca chegou a existir. Dava SIGSEGV.
async def escreve(p: str) -> int:
    f = await open(p, "w")
    try:
        await f.write("x")
        return 1
    finally:
        await f.close()


print(await escreve("x.txt"))
