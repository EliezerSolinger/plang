import "geometria.ph"

def dist(a: *Point, b: *Point) -> int:
    dx: int = a->x - b->x
    dy: int = a->y - b->y
    return dx*dx + dy*dy

# forma livre com nome já manglado (spec §9.2, forma 2)
def Point_move(self: *Point, dx: int, dy: int) -> void:
    self->x += dx
    self->y += dy
