def f() -> i32:
    return 3
def main() -> int:
    if f() in {1, 2, 3}:
        return 1
    return 0
