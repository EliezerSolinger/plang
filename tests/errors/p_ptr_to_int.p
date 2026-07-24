def main() -> int:
    x: i32 = 7
    p: *i32 = &x
    n: i32 = p
    return n
