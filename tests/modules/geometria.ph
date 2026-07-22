# interface pública do módulo (vira geometria.h com #pragma once)
struct Point:
    x: int
    y: int
    def move(self: *Point, dx: int, dy: int) -> void

def dist(a: *Point, b: *Point) -> int
