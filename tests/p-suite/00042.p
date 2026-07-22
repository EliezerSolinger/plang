union U:
    a: int
    b: int

def main() -> int:
    u: U
    u.a = 1
    u.b = 3

    if u.a != 3 or u.b != 3:
        return 1
    return 0
