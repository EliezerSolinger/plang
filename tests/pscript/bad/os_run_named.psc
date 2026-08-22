# o que vem depois do comando é dado POR NOME: `env=`, `cwd=`, `stdout=`. Um
# segundo argumento posicional não tem significado nenhum, e adivinhá-lo seria
# pior que recusá-lo.
import os

async def go():
    r = await os.run(["/bin/echo", "oi"], "/tmp")
    print(r.status())

await go()
