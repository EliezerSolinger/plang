# exemplo completo da spec (§11): lista ligada + match + ternário
include <stdio.h>
include <stdlib.h>

const N: int = 5

struct Node:
    val: int
    next: *Node

def push(head: *Node, v: int) -> *Node:
    n: *Node = malloc(sizeof(Node))
    n.val = v
    n.next = head
    return n

def classifica(x: int) -> *char:
    match x:
        case 0:
            return "zero"
        case 1, 2, 3:
            return "pequeno"
        case _:
            return "grande"

def main() -> int:
    lista: *Node = None
    i: int
    for i in range(1, N + 1):
        lista = push(lista, i)

    p: *Node = lista
    while p != None:
        rotulo: *char = classifica(p.val)
        sinal: *char = "par" if p.val % 2 == 0 else "impar"
        printf("%d -> %s (%s)\n", p.val, rotulo, sinal)
        p = p.next
    return 0
