import lib_shape


trait Printable:
    def show(in self) -> str

trait Scaled:
    def scale(in self, k: float) -> Self


record Vec2 implements Printable:
    x: float
    y: float

    def show(in self) -> str:
        return f"Vec2({self.x}, {self.y})"


record Money:
    cents: int


implement Printable for Money:
    def show(in self) -> str:
        return f"${self.cents / 100.0}"


implement Scaled for Vec2:
    def scale(in self, k: float) -> Vec2:
        return Vec2(self.x * k, self.y * k)


v = Vec2(1.5, 2.0)
print(v.show())
print(v.scale(2.0).show())
print(Money(1250).show())


# 66.1's whole point: the block form reaches across modules, and 67.3 keeps it
# honest — each of these owns one half of the pair.
implement lib_shape.Area for Vec2:
    def area(in self) -> float:
        return self.x * self.y


implement Printable for lib_shape.Square:
    def show(in self) -> str:
        return f"Square({self.side})"


print(f"{v.area()}")
print(lib_shape.Square(3.0).show())
