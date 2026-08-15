trait Scaled:
    def scale(in self, k: float) -> Self


record Vec2 implements Scaled:
    x: float

    def scale(in self, k: int) -> Vec2:
        return self
