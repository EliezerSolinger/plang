include <stdio.h>

struct Par<T>:
    a: T
    b: T

    def init(out self: Par<T>, x: T, y: T):
        self.a = x
        self.b = y

    def sum_v(in self: Par<T>) -> T:
        return self.a + self.b

def max<T>(a: T, b: T) -> T:
    return a if a > b else b

inline Par<int>
inline max<int>

def main() -> int:
    p: Par<int>
    p.init(40, 2)
    printf("%d %d\n", p.sum_v(), max(3, 7))
    return 0
