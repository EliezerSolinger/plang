# o elemento faz parte do limite: uma lista de `str` não é uma Sequence<int>
def f(xs: Sequence<int>) -> int:
    return len(xs)


print(f(["a", "b"]))
