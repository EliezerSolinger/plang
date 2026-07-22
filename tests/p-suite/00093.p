a: int[] = {1, 2, 3, 4}

def main() -> int:
    if sizeof(a) != 4 * sizeof(int):
        return 1
    return 0
