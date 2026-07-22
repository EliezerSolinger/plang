def main() -> int:
    x: int
    p: *int
    x = 1
    p = &x
    p[0] = 0
    return x
