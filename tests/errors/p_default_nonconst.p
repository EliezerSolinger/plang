g: i32 = 4
def f() -> i32:
    return g
def area(w: i32, h: i32 = f()) -> i32:
    return w * h
def main() -> int:
    return area(2)
