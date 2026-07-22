x: int = 5
y: long = 6
p: *int = &x

def main() -> int:
    if x != 5:
        return 1
    if y != 6:
        return 2
    if *p != 5:
        return 3
    return 0
