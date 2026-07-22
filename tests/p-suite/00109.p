def main() -> int:
    x: int = 0
    y: int = 1
    if 1 if x else 0:
        return 1
    if 0 if y else 1:
        return 2
    return 0
