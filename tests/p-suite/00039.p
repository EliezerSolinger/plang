def main() -> int:
    p: *void
    x: int

    x = 2
    p = &x

    if *(*int)(p) != 2:
        return 1
    return 0
