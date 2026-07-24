# `is` / `is not`: identidade de ponteiro, indiferente ao tipo
include <stdio.h>

struct Node:
    v: i32

def main() -> int:
    a: Node = {1}
    b: Node = {1}
    p: *Node = &a
    q: *Node = &a
    r: *Node = &b
    n: *Node = None
    printf("%d %d %d %d\n", p is q, p is r, n is None, p is not None)
    v: *void = (*void)(p)
    printf("%d\n", v is p)
    if n is None:
        printf("null ok\n")
    return 0
