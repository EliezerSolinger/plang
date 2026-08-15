trait Printable:
    def show(in self) -> str


record Vec2:
    x: float


implement Printable for Vec2:
    def show(in self) -> str:
        return "a"


implement Printable for Vec2:
    def show(in self) -> str:
        return "b"
