include <stdio.h>

def classify(c: char) -> i32:
    if c in "aeiou":
        return 1
    if c in {'0', '1', '2'}:
        return 2
    return 0

def main() -> int:
    # char em string literal
    printf("%d %d %d\n", classify('e'), classify('1'), classify('z'))
    # int em lista
    n: i32 = 5
    ok: bool = n in {1, 3, 5, 7}
    printf("%d\n", ok)
    # string em lista de strings (strcmp, nunca ponteiro!)
    name: const *char = "double"
    if name in {"float", "double", "long double"}:
        printf("float-family\n")
    # not in
    if 4 not in {1, 3, 5, 7}:
        printf("even\n")
    # elemento em array fixo
    primes: i32[4] = {2, 3, 5, 7}
    q: i32 = 5
    printf("%d %d\n", q in primes, 6 in primes)
    return 0
