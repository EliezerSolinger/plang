def main() -> int:
    x: int
    p: *int
    x = 0
    p = &x
    return p[0]
