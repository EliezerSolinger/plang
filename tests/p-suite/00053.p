struct T1:
    x: int

struct T2:
    y: int

def main() -> int:
    s1: T1
    s1.x = 1
    s2: T2
    s2.y = 1
    if s1.x - s2.y != 0:
        return 1
    return 0
