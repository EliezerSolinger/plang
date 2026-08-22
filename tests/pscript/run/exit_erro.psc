"""`sys.exit(await f())` quando `f` falha: o programa TEM de o dizer.

Um erro pendente tinha duas portas para sair do programa, e só uma delas o
reportava. `sys.exit` avalia o argumento e depois chama; se a avaliação
levantou, o código que se ia devolver nem chegou a existir — e sair com ele era
sair com ZERO, isto é, com sucesso, sem uma linha de mensagem.

Custou uma investigação: o `ppack` morria a montar o grafo e devolvia 0, e o
arreio que só olhava o status dizia que estava tudo bem.

O que se prende aqui é o par: a mensagem sai e o status é 1. E o caminho normal
— `sys.exit` sem erro nenhum — continua a devolver o número que se pediu, que é
o que faz uma ferramenta de linha de comando ser usável num script.
"""
import sys


async def escolhe(n: int) -> int:
    if n < 0:
        raise error("um código negativo não é um status")
    return n


async def go():
    # o caminho normal: o número pedido atravessa
    print("normal:", await escolhe(3))

    # e o que falha, apanhado, também não mata nada
    try:
        await escolhe(-1)
        print("não devia chegar aqui")
    catch e:
        print("apanhado:", e.message)


await go()
sys.exit(await escolhe(0))
