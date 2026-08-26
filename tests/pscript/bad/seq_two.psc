# os parâmetros `Sequence` partilham UM parâmetro de tipo, logo o elemento também
def f(a: Sequence<int>, b: Sequence<str>) -> int:
    return len(a) + len(b)
