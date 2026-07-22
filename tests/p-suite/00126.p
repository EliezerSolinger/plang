def main() -> int:
    x: int
    x = 3
    x = not x
    x = not x
    x = ~x
    x = -x
    if x != 2:
        return 1
    return 0
