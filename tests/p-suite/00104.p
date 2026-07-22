def main() -> int:
    x: i32
    l: i64
    x = 0
    l = 0
    x = ~x
    if x != 0xffffffff:
        return 1
    l = ~l
    if x != 0xffffffffffffffff:
        return 2
    return 0
