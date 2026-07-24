# self por valor (leitura) e por ponteiro (mutação); receptor ponteiro deref
include <stdio.h>

struct Point:
    x: i32
    y: i32
    def norm2(self: Point) -> i32:
        return self.x * self.x + self.y * self.y
    def scale(self: *Point, k: i32):
        self.x = self.x * k
        self.y = self.y * k

def main() -> int:
    p: Point = {3, 4}
    pp: *Point = &p
    printf("%d %d\n", p.norm2(), pp.norm2())
    p.scale(2)
    printf("%d %d %d\n", p.x, p.y, p.norm2())
    return 0
