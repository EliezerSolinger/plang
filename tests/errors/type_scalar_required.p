struct Box:
    v: i32

def main() -> int:
    b: Box
    b.v = 1
    if b:
        return 1
    return 0
