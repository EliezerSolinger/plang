# a recursão sem fim tem o seu próprio limite, antes do orçamento
const def f(n: int) -> int:
    return f(n + 1)


print(f(1))
