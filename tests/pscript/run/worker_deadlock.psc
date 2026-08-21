"""Os dois travamentos do modelo de worker, e o que o programa vê (107).

Um `await recv()` que ninguém vai responder é a armadilha central do canal: o
programa não termina, e antes ele ficava pendurado no `poll` para sempre, sem
dizer nada. São dois casos e eles têm respostas diferentes:

  * o PAI acaba sem mandar nada — então não há mais mensagem possível, o canal
    de descida FECHA e o `recv` do worker termina (é o desligamento cooperativo
    da 36.4 chegando por si);
  * os dois esperam UM AO OUTRO com as duas filas vazias — aí ninguém pode
    ceder, e o runtime diz isso em vez de ficar pendurado. Só é declarado quando
    TODA espera do contexto está presa: com outro worker vivo, um socket ou um
    relógio, alguém ainda pode acordar.
"""


async def espera_o_pai(n: int) -> int:
    v = await parent.recv()
    print(f"worker recebeu {v}")
    return v


async def eco(n: int) -> int:
    v = await parent.recv()
    parent.send(v)
    return v


async def demora(n: int) -> int:
    await sleep(0.1)
    parent.send(n * 7)
    return n


# ---- 1. um terceiro vivo não é travamento: o pai espera quem vai responder ----
a = spawn(eco, (0,))
b = spawn(demora, (6,))
print(f"b={await b.recv()}")
print(a.send(5))
print(f"a={await a.recv()}")

# ---- 2. o pai acaba sem mandar: o canal fecha e o worker sai ----
z = spawn(espera_o_pai, (0,))
print("fim do main")
