def main() -> int:
    x: int[2]
    p: *int

    x[1] = 7
    p = &x[0]
    p = p + 1

    if *p != 7:
        return 1
    if &x[1] - &x[0] != 1:
        return 1

    return 0
