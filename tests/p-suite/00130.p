def main() -> int:
    arr: char[2][4]
    p: *(char[4])
    q: *char
    v: int[4]
    p = arr
    q = &arr[1][3]
    arr[1][3] = 2
    v[0] = 2
    if arr[1][3] != 2:
        return 1
    if p[1][3] != 2:
        return 1
    if *q != 2:
        return 1
    if *v != 2:
        return 1
    return 0
