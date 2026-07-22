def main() -> int:
    x: int
    p: *int
    pp: **int
    x = 0
    p = &x
    pp = &p
    return **pp
