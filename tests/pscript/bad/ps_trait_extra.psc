trait Printable:
    def show(in self) -> str


record Vec2:
    x: float


implement Printable for Vec2:
    def show(in self) -> str:
        return "v"

    def other(in self) -> int:
        return 1
