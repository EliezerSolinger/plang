include <stdio.h>

# Inferência de tipo estilo Python: `nome = valor` na primeira vez DECLARA a
# variável com o tipo inferido do valor; depois vira atribuição normal.
#   3    -> int      2.4  -> double   2.4f -> float
#   "x"  -> *char    'c'  -> char     f()  -> tipo de retorno

def dobro(x: i32) -> i32:
    return x * 2

def main() -> i32:
    a = 3
    b = 2.4
    c = 2.4f
    s = "hello"
    ch = 'Z'
    n = dobro(10)
    a = a + n        # atribuição normal (a já existe)
    printf("a=%d b=%.1f c=%.1f s=%s ch=%c n=%d\n", a, b, c, s, ch, n)
    printf("sizeof: c=%zu b=%zu a=%zu\n", sizeof(c), sizeof(b), sizeof(a))
    return 0
