# ... e o dual: um `and` com `==` também não prova.
#
# `if a == None and b == None:` só entra quando as DUAS são nulas, portanto o que
# ele prova é o contrário do que se quer — e depois dele, no `else` implícito,
# basta uma delas não ser nula para o ramo ser tomado.
def f(a: int?, b: int?) -> int:
    if a == None and b == None:
        return 0
    return a + 1


print(f(1, 2))
