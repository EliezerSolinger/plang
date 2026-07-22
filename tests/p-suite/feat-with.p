include <stdio.h>

# `with alvo:` abre um subcontexto onde `.campo` se refere ao alvo (struct ou
# *struct). O alvo é avaliado uma única vez; `.campo` serve p/ ler, atribuir e
# chamar métodos. Blocos aninhados: `.campo` refere-se ao `with` mais interno.

struct Point:
    x: i32
    y: i32
    label: *char

def Point_scale(self: *Point, k: i32):
    self->x *= k
    self->y *= k

def main() -> i32:
    p: Point                 # alvo VALOR (a sema usa &p)
    with p:
        .x = 3
        .y = 4
        .label = "origin"
        if .x < .y:          # leitura de campos
            .label = "ybig"
    printf("p=(%d,%d) %s\n", p.x, p.y, p.label)

    q: *Point = &p           # alvo PONTEIRO (usado direto)
    with q:
        .x += 10
        .y += 20
        .scale(2)            # método via receptor implícito
    printf("q=(%d,%d)\n", q->x, q->y)

    a: Point
    b: Point
    with a:                  # aninhado: `.x` interno é de b
        .x = 1
        with b:
            .x = 100
            .y = .x + 1
        .y = 2
    printf("a=(%d,%d) b=(%d,%d)\n", a.x, a.y, b.x, b.y)
    return 0
