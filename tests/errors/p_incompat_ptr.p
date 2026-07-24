def main() -> int:
    x: i32 = 1
    p: *i32 = &x
    q: *i64 = p
    return 0
