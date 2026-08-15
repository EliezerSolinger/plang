# nominal (66.2): declaring the trait obliges every method of it
trait Printable:
    def show(in self) -> str


record Vec2 implements Printable:
    x: float
