# um `const def` que não acaba é um compilador que não responde
const def f(n: int) -> int:
    while n > 0:
        n += 1
    return n


print(f(1))
