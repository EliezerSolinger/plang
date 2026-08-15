# object safety: through a vtable there is no way to know what Self is
trait Scaled:
    def scale(in self, k: float) -> Self


record Vec2 implements Scaled:
    x: float

    def scale(in self, k: float) -> Vec2:
        return Vec2(self.x * k)


s: dyn Scaled = Vec2(1.0)
