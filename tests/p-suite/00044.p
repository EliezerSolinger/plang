struct T:
    x: int

def main() -> int:
    v: T
    v.x = 2
    if v.x != 2:
        return 1
    return 0
