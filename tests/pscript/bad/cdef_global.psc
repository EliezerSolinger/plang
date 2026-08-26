# uma global mutável não é conhecida em compilação; um `const` seria
x = 3


const def f(n: int) -> int:
    return n + x


print(f(1))
