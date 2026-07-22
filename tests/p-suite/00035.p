def main() -> int:
    x: int

    x = 4
    if (not x) != 0:
        return 1
    if (not not x) != 1:
        return 1
    if -x != 0 - 4:
        return 1
    return 0
