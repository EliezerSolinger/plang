def f1(p: *char) -> int:
    return *p + 1

def main() -> int:
    s: char = 1
    v: int[1000]
    if f1(&s) != 2:
        return 1
    return 0
