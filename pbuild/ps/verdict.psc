"""O VEREDICTO de um caso de teste, como programa.

Um caso de teste não é uma aresta comum, e a diferença é uma só: o STATUS de
saída dele é DADO, não é veredicto. Um programa que tem de sair com 1 sai com 1,
e a aresta que o roda não pode chamar isso de falha — enquanto um programa que
sai com 0 e imprime a coisa errada falhou, e a aresta tem de dizer.

Então o que a aresta roda não é o caso: é isto. Ele roda o caso, junta a saída
de erro com a de saída (é a mesma decisão do `os.run`, e é assim que o
`tests/run.sh` sempre comparou), confere o status contra o esperado, confere o
texto contra o `.expected`, e só então decide. Quem passa deixa um CARIMBO, que
é o que o grafo data; quem falha imprime as primeiras linhas da diferença e sai
com status != 0, que é o que o motor entende.

    verdict <binario> <esperado> <status-esperado> <cwd> <carimbo>

O `cwd` existe porque um caso pode escrever arquivos, e ele tem de escrevê-los
no diretório de saída do build e não na raiz do repositório.
"""
import os
import sys
import path

const CONTEXTO: int = 12


private def primeiras_diferencas(esperado: str, veio: str) -> str:
    """A primeira linha que difere, com o que se esperava e o que veio. Um diff
    inteiro num relatório de build é ruído; a primeira divergência é quase sempre
    a única que importa, e as outras vêm dela."""
    a = esperado.split("\n")
    b = veio.split("\n")
    n = len(a) if len(a) < len(b) else len(b)
    i = 0
    while i < n:
        if a[i] != b[i]:
            return ("linha " + str(i + 1) + ":\n  esperado: " + a[i] + "\n  veio:     " + b[i])
        i += 1
    if len(a) != len(b):
        return ("o texto tem " + str(len(b)) + " linha(s) e o esperado tem " + str(len(a)))
    return "?"


async def main() -> int:
    args = sys.argv[1:]
    if len(args) != 5:
        print("uso: verdict <binario> <esperado> <status-esperado> <cwd> <carimbo>")
        return 2
    binario = args[0]
    esperado = args[1]
    quer = int(args[2])
    cwd = args[3]
    carimbo = args[4]

    # o caminho do binário é relativo à RAIZ; o processo roda no `cwd` do caso,
    # então ele tem de virar absoluto antes
    abs_bin = binario if binario.startswith("/") else path.join(os.getcwd(), binario)
    # cada caso tem o diretório DELE, e ele é criado aqui: um caso que escreve
    # arquivos não pode escrevê-los na raiz do repositório, e dois casos em
    # paralelo não podem escrever no mesmo lugar
    if not path.isdir(cwd):
        os.makedirs(cwd)
    r = await os.run([abs_bin], cwd=cwd)

    f = await open(esperado, "r")
    quer_txt = await f.text()
    await f.close()
    veio = r.output()

    problemas: list<str> = []
    if r.status() != quer:
        problemas.append("status " + str(r.status()) + ", esperado " + str(quer))
    if veio != quer_txt:
        problemas.append(primeiras_diferencas(quer_txt, veio))

    if len(problemas) > 0:
        print(path.basename(binario) + ": FALHOU")
        for p in problemas:
            print("  " + p)
        return 1

    d = path.dirname(carimbo)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    g = await open(carimbo, "w")
    await g.write("ok\n")
    await g.close()
    return 0


sys.exit(await main())
