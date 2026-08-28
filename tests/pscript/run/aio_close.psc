"""`await f.close()` FECHA — e é isso que põe os bytes no disco (118 / pforge).

Este arquivo existe por causa de um defeito, e o defeito merece ser contado
porque a forma dele volta a aparecer sempre que um objeto novo do runtime nasce.

`ps_alloc` NÃO zera a memória que entrega: quem constrói um objeto tem de
escrever TODOS os campos dele. O `PsFile` que uma abertura assíncrona devolvia
escrevia dois de três — o `is_std` (o campo que diz "isto é o stdout, fechar não
faz nada") ficava com o lixo do bloco reciclado por uma coleta. Quando o lixo
era != 0, `close` saía cedo sem fechar coisa alguma: a escrita dizia ter gravado
144 bytes, o arquivo tinha 0, e os dados só apareciam quando o processo saía e a
libc esvaziava o que tinha sobrado.

Nada disso dava erro. É o pior tipo de defeito — o programa está certo, o
relatório está certo, e o resultado no disco está errado.

O que se prende aqui, então:

  * depois de `close`, o tamanho no disco é o que a escrita disse ter gravado —
    medido AGORA, dentro do processo, e não no `exit`;
  * outro descritor, aberto em seguida, lê o conteúdo inteiro;
  * escrever num arquivo já fechado é erro, não silêncio.

Este programa é do corpo que `tests/gc-stress.sh` roda com o coletor a cada
ponto seguro, que é onde o defeito vivia.
"""
import path
import os

PATH: str = "aio_close_demo.txt"


async def store(p: str, n: int) -> int:
    # a string cresce alocando: cada volta é uma chance de coleta, e é depois
    # dela que o bloco do `PsFile` vem reciclado
    text = "cabecalho\n"
    for i in range(n):
        text += "linha " + str(i) + "\n"
    f = await open(p, "w")
    written = await f.write(text)
    await f.close()
    # a medida que importa: o tamanho AGORA, com o processo ainda vivo
    return written - path.getsize(p)


async def go():
    for n in [1, 20, 50, 100]:
        d = await store(PATH, n)
        print("n =", n, "-> escrito - no disco =", d)

    f = await open(PATH, "r")
    todo = await f.text()
    await f.close()
    print("relido:", len(todo), "bytes,", len(todo.split("\n")) - 1, "linhas")

    # e um arquivo fechado recusa a escrita em vez de aceitá-la em silêncio
    g = await open(PATH, "w")
    await g.close()
    try:
        await g.write("depois do fim")
        print("nao devia chegar aqui")
    catch e:
        print("fechado:", e.message)

    os.remove(PATH)
    print("limpo:", path.exists(PATH))


await go()
