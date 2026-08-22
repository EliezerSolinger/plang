# um processo terminado tem status() e output(), e nada mais: o que ele deixou
# para trás são essas duas coisas.
import os

async def go():
    r = await os.run(["/bin/echo", "oi"])
    print(r.pid())

await go()
