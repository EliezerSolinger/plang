def main() -> int:
    arr: int[2]
    p: *int
    p = &arr[1]
    *p = 0
    return arr[1]
