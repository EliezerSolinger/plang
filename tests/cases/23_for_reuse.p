# iterador de `for` é REAPROVEITÁVEL: declaração explícita posterior do mesmo
# tipo vira atribuição; um for seguinte reusa a variável
include <stdio.h>

def main() -> i32:
    s: i32 = 0
    for i in range(3):
        s += i32(i)
    i: usize = 100
    s += i32(i)
    for i in range(2):
        s += i32(i)
    printf("%d\n", s)
    return 0
