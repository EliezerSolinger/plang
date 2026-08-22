"""O par do `exit_erro.psc`: quando o erro CHEGA ao `sys.exit`.

Aqui o argumento levanta, e o que se cobra é o par inteiro — a mensagem no
`stderr`, com a pilha em que o erro nasceu, e o status 1. Antes deste conserto o
programa saía com 0 e sem dizer nada, que é o pior resultado possível: um script
que o chamasse concluiria que correu bem.
"""
import sys


async def escolhe(n: int) -> int:
    if n < 0:
        raise error("um código negativo não é um status")
    return n


sys.exit(await escolhe(-1))
