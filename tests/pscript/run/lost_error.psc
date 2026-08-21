"""O erro que ninguém foi buscar (107), e os casos em que ele NÃO é perdido.

Uma task captura o erro dela e o guarda para o `await`. Se ninguém aguarda, o
programa terminava calado — o mesmo desaparecimento que a 37.4 já tinha resolvido
para o worker. Agora sai uma linha no stderr, com posição, e a linha some quando
alguém realmente colhe o erro: por `await`, por `gather_settled` ou por
`first_ok`. Uma task CANCELADA também não conta: o erro dela é a resposta ao
pedido de parar.

O teste compara stdout E stderr, então as duas metades estão aqui.
"""


async def quebra(marca: str) -> int:
    await sleep(0.0)
    raise error("caiu: " + marca)


async def vai(n: int) -> int:
    await sleep(0.0)
    return n


# ---- 1. colhido por `await`: nada é reportado ----
t1 = quebra("await")
try:
    print(await t1)
catch e:
    print(f"peguei {e.message}")

# ---- 2. colhido por gather_settled ----
ts = [quebra("settled"), vai(1)]
es = await gather_settled(ts)
for i in range(len(es)):
    x = es[i]
    if x != None:
        print(f"settled viu {x.message}")

# ---- 3. `first_ok`: as que falham foram olhadas ----
ok = await first_ok([quebra("first"), vai(9)])
print(f"first_ok {ok}")

# ---- 4. cancelada: o erro é a resposta ao pedido ----
c = vai(5)
c.cancel()
try:
    print(await c)
catch e2:
    print(f"cancelada {e2.message}")

# ---- 5. NINGUÉM aguarda: é este que sai no stderr ----
solto = quebra("orfa")
print("fim")
