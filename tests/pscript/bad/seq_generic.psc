# um parâmetro `Sequence` JÁ É o parâmetro de tipo
def f<T: Printable>(a: Sequence<int>, b: T) -> int:
    return len(a)
