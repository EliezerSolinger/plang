def main() -> int:
    x: i32 = 1
    p: *i32 = &x
    if p == 3:
        return 1
    return 0
