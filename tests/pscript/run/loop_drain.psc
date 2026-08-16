"""O laço drena no fim, e `await` cede sempre (77.3/78.4).

Duas regras do JS que faltavam, e que passam a valer aqui:

  * uma task que NINGUÉM espera terminava pela metade — o programa saía e ela
    ficava para trás. Agora, ao chegar ao fim, o escalonador roda até não haver
    mais nada pronto, nem prazo, nem I/O em voo. É o que faz um `spawn` solto
    funcionar como todo mundo espera;
  * `await` de um valor JÁ PRONTO cedia a vez a ninguém e seguia direto. Agora
    a task vai para o fim da fila antes de continuar — sem isso, um laço de
    awaits que sempre acha resposta pronta nunca deixaria outra rodar, que é
    exatamente o que acontece num servidor com um cliente rápido.
"""

async def orfa() -> int:
    print("orfa: comecei")
    await sleep(0.01)
    print("orfa: terminei")
    return 1


async def pronta(tag: str) -> int:
    print(tag)
    return 7


async def contador(n: int) -> int:
    # nenhum destes awaits espera de verdade: todos acham a resposta pronta.
    # Como cada um cede, a outra task intercala em vez de ficar de fora.
    total = 0
    for i in range(n):
        total += await pronta("conta " + str(i))
    return total


async def intruso() -> int:
    for i in range(3):
        print("intruso " + str(i))
        await pronta("(pronta do intruso)")
    return 0


solta = orfa()
a = contador(3)
b = intruso()
print("somei", await a)
print("intruso deu", await b)
print("fim do main — o que vier depois disto é a drenagem")
