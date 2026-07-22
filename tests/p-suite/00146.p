arr: int[3] = {0, 1, 2}

def main() -> int:
    if arr[0] != 0:
        return 1
    if arr[1] != 1:
        return 2
    if arr[2] != 2:
        return 3
    return 0
