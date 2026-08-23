"""O PISO de um placar, como aresta do grafo.

Uma suíte que mede em vez de passar/falhar — a `c-suite` (220 programas de C de
terceiros) e o corpus `wacct` (1 630) — não tem veredicto próprio: ela imprime um
número. O que faz esse número ser um portão é o PISO: cair abaixo dele é
regressão, e subi-lo quando o número melhora é a forma de nunca voltar atrás.

Isso vivia no `verify-all.sh`, em duas variáveis de shell no topo do arquivo. O
lugar certo é aqui, junto da suíte que ele mede: quem lê o descritor vê o que se
exige, e quem sobe o piso sobe-o onde o número é produzido.

    piso <log> <prefixo> <mínimo> <carimbo>

O `prefixo` é o texto que vem imediatamente antes do número na linha do
relatório (`score: `, `wacct-valid: `). Procura-se a ÚLTIMA ocorrência, porque um
relatório pode citar o mesmo prefixo antes de o dizer a sério — e o que vale é o
que ele disse no fim.
"""
import os
import path
import sys


private def numero_depois(txt: str, prefixo: str) -> int:
    """O último número que vem logo depois de `prefixo`, ou -1 se não houver.

    Sem expressão regular de propósito: é uma busca de texto e uma leitura de
    dígitos, e as duas cabem em quinze linhas que se leem de uma vez."""
    achado = -1
    i = 0
    while True:
        k = txt.find(prefixo, i)
        if k < 0:
            break
        j = k + len(prefixo)
        v = 0
        n = 0
        while j < len(txt) and txt[j] >= "0" and txt[j] <= "9":
            v = v * 10 + (ord(txt[j]) - ord("0"))
            n += 1
            j += 1
        if n > 0:
            achado = v
        i = k + len(prefixo)
    return achado


async def main() -> int:
    args = sys.argv[1:]
    if len(args) != 4:
        print("uso: piso <log> <prefixo> <mínimo> <carimbo>")
        return 2
    log = args[0]
    prefixo = args[1]
    minimo = int(args[2])
    carimbo = args[3]
    if not path.isfile(log):
        print("piso: não achei o relatório " + log)
        return 1
    f = await open(log, "r")
    txt = await f.text()
    await f.close()
    v = numero_depois(txt, prefixo)
    if v < 0:
        print("piso: o relatório " + log + " não tem uma linha com '" + prefixo + "<número>'")
        return 1
    if v < minimo:
        print("REGRESSÃO: " + prefixo + str(v) + ", e o piso é " + str(minimo))
        print("   o relatório inteiro está em " + log)
        return 1
    d = path.dirname(carimbo)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    g = await open(carimbo, "w")
    await g.write(prefixo + str(v) + " (piso " + str(minimo) + ")\n")
    await g.close()
    print(prefixo + str(v) + " >= " + str(minimo))
    return 0


sys.exit(await main())
