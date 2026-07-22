def main() -> int:
    x: int
    p: *int
    x = 4
    p = &x
    *p = 0
    return *p
