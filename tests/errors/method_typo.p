struct Point:
    x: i32
    def norm2(self: *Point) -> i32:
        return self.x
def main() -> int:
    p: Point = {1}
    return p.nrm2()
