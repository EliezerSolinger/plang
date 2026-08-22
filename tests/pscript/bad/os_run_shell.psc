# `os.run` NÃO passa por shell: o comando é um vetor, não uma linha para alguém
# quebrar em pedaços. Uma string aqui seria o começo de todo bug de aspas que
# existe, então ela é recusada com a forma certa no lugar.
import os

async def go():
    r = await os.run("cc -c a.c")
    print(r.status())

await go()
