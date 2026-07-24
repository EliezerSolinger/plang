def f(p: *i64) -> i32:
    return 0
def main() -> int:
    x: i32 = 1
    return f(&x)
