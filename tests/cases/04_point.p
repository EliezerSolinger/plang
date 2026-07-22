# métodos em struct: açúcar p.m() / q->m() -> Point_m(&p) / Point_m(q)
include <stdio.h>

struct Point:
    x: int
    y: int

    def move(self: *Point, dx: int, dy: int) -> void:
        self->x += dx
        self->y += dy

    def dist2(self: *Point) -> int:
        return self->x * self->x + self->y * self->y

def main() -> int:
    p: Point
    p.x = 1
    p.y = 2
    p.move(3, 4)
    printf("%d %d %d\n", p.x, p.y, p.dist2())
    q: *Point = &p
    q->move(1, 1)
    printf("%d\n", q->dist2())
    Point_move(&p, 1, 0)
    printf("%d\n", p.x)
    return 0
