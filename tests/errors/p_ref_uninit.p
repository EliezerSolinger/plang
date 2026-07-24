def dobra(ref v: i32):
    v = v * 2
def main() -> int:
    x: i32
    dobra(ref x)
    return x
