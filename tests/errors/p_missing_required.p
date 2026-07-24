def area(w: i32, h: i32, scale: i32 = 1) -> i32:
    return w * h * scale
def main() -> int:
    return area(scale=2, w=3)
