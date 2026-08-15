# nominal (66.2), and it holds for `dyn` too: a type that never declared the
# trait cannot be boxed behind it
trait Shape:
    def area(in self) -> float


record Circle:
    r: float

    def area(in self) -> float:
        return self.r


s: dyn Shape = Circle(1.0)
