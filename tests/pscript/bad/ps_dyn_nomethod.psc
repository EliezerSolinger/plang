trait Shape:
    def area(in self) -> float


record Circle implements Shape:
    r: float

    def area(in self) -> float:
        return self.r

    def extra(in self) -> int:
        return 1


s: dyn Shape = Circle(1.0)
print(f"{s.extra()}")
