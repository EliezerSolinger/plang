const A: int = 3

def foo(x: int, y: int, z: int) -> int:
    return x + y + z

def main() -> int:
    if foo(1, 2, A) != 6:
        return 1
    return foo(0, 0, 0)
