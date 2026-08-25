# 114/43.1: um `or` com `!=` NÃO prova nada, e é a metade que interessa.
#
# O ramo pode ter sido tomado porque o OUTRO lado valia — portanto dentro dele
# não se sabe nada sobre este. Que a prova passe agora por uma LISTA em vez de um
# índice não muda isto: muda quantas provas cabem, não o que conta como prova.
def f(a: int?, b: int?) -> int:
    if a != None or b != None:
        return a + 1
    return 0


print(f(1, 2))
