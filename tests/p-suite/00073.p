def main() -> int:
    arr: int[2]
    p: *int
    p = &arr[1]
    p -= 1
    *p = 123
    if arr[0] != 123:
        return 1
    return 0
