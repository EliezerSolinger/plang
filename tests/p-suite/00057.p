def main() -> int:
    a: char[16]
    b: char[16]

    if sizeof(a) != sizeof(b):
        return 1
    return 0
