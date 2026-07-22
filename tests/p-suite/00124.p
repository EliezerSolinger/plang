def f2(c: i32, b: i32) -> i32:
    return c - b

def f1(a: i32, b: i32) -> def(i32, i32) -> i32:
    if a != b:
        return f2
    return 0

def main() -> i32:
    p: def(i32, i32) -> def(i32, i32) -> i32 = f1
    return p(0, 2)(2, 2)
