def main() -> int:
    x: int
    x = 1
    x = 10
    while x:
        x = x - 1
    if x:
        return 1
    x = 10
    while x:
        x = x - 1
    return x
