"""O portão que interessa: o `tar` do sistema abre o nosso.

Um envelope que só a nossa ferramenta lê não é um envelope, é um formato
particular com extensão emprestada. Este teste escreve um tarball, pede ao
`tar` do sistema para o listar e para o EXTRAIR, e confere os bytes que saíram.

Se não houver `tar` na máquina, o teste diz que não houve e passa — recusar-se a
construir por falta de uma ferramenta que não é dependência seria pior do que o
que ele protege.
"""

import os
import sys
import path
import <tar/tar.psc> as tar

e: list<int> = [0, 0]
DIR = "build/t/tarsys"


def conf(nome: str, cond: bool):
    if cond:
        e[0] += 1
    else:
        e[1] += 1
        print("  FALHOU: " + nome)


async def main() -> int:
    r0 = await os.run(["tar", "--version"])
    if r0.status() != 0:
        print("tar: sem `tar` no sistema — 0 ok, 0 failed")
        return 0

    if not path.isdir(DIR):
        os.makedirs(DIR)
    alvo = path.join(DIR, "p.tar")
    conteudo = "linha um\nlinha dois\n"
    bs = tar.escrever([
        tar.diretorio("caixa", 0o755, 1700000000),
        tar.arquivo("caixa/a.txt", tar.bytes_de(conteudo), 0o644, 1700000001),
        tar.arquivo("caixa/b.bin", tar.bytes_de("x" * 1000), 0o600, 1700000002),
    ])
    f = await open(alvo, "w")
    await f.write(bs)
    await f.close()

    # 1) ele LISTA o que pusemos lá
    r = await os.run(["tar", "tf", alvo])
    conf("tar tf devolve 0", r.status() == 0)
    nomes: list<str> = []
    for ln in r.output().split("\n"):
        if len(ln) > 0:
            nomes.append(ln)
    conf("tar tf lista os três membros", len(nomes) == 3)
    conf("o diretório aparece", "caixa/" in nomes)
    conf("o arquivo aparece", "caixa/a.txt" in nomes)

    # 2) ele EXTRAI, e o que sai é o que entrou
    r2 = await os.run(["tar", "xf", alvo, "-C", DIR])
    conf("tar xf devolve 0", r2.status() == 0)
    g = await open(path.join(DIR, "caixa/a.txt"), "r")
    saiu = await g.text()
    await g.close()
    conf("o conteúdo sobreviveu à ida e à volta", saiu == conteudo)

    # 3) e o modo que declarámos é o modo que ficou no disco
    r3 = await os.run(["stat", "-c", "%a", path.join(DIR, "caixa/b.bin")])
    conf("o modo 600 chegou ao disco", r3.status() != 0 or r3.output().strip() == "600")

    print(f"tar/sistema: {e[0]} ok, {e[1]} failed")
    return 1 if e[1] > 0 else 0

sys.exit(await main())
