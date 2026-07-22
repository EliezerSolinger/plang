struct S:
    x: int
    y: int

def main() -> int:
    s: S
    s.x = 3
    s.y = 5
    return s.y - s.x - 2
