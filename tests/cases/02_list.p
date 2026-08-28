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

def classify(x: int) -> *char:
    match x:
        case 0:
            return "zero"
        case 1, 2, 3:
            return "pequeno"
        case _:
            return "grande"

def main() -> int:
    list_v: *Node = None
    i: int
    for i in range(1, N + 1):
        list_v = push(list_v, i)

    p: *Node = list_v
    while p != None:
        label: *char = classify(p.val)
        sign: *char = "par" if p.val % 2 == 0 else "impar"
        printf("%d -> %s (%s)\n", p.val, label, sign)
        p = p.next
    return 0
