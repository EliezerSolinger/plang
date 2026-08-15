# a bound the type does not satisfy
trait Sized:
    def size(self: *Sized) -> i32
struct Box:
    w: i32
def area<T: Sized>(v: *T) -> i32:
    return v->size()
declare area<Box>
implement area<Box>
def main() -> int:
    b: Box = {1}
    return area(&b)
