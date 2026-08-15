"""An import fixture: a trait and a type that belong to ANOTHER module, which is
what the separate `implement` block exists for (66.1)."""

trait Area:
    def area(in self) -> float


record Square:
    side: float
