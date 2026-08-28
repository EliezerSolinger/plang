include <stdio.h>

struct Box:
    items: i32[4]
    n: i32

    def init(out self: Box):
        self.n = 0

    def push(ref self: Box, v: i32):
        self.items[self.n] = v
        self.n += 1

    def sum_v(in self: Box) -> i32:
        t: i32 = 0
        for i in range(self.n):
            t += self.items[i]
        return t

    def copy_v(self: Box) -> i32:     # por valor: recebe uma CÓPIA
        return self.n

def main() -> int:
    c: Box
    c.init()                 # out self: inicializa c (definite assignment)
    c.push(10)
    c.push(32)
    printf("%d %d %d\n", c.sum_v(), c.copy_v(), c.n)
    return 0
