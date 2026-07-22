struct S:
    x: int
    y: int

v: S

def main() -> int:
    v.x = 1
    v.y = 2
    return 3 - v.x - v.y
