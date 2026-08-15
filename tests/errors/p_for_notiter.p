# `for v in x` needs a sized array or an Iterable implementer — and the bound
# is nominal (68.1): having the methods without declaring is refused.
struct Rows:
    at: i64

    def has_next(self: *Rows) -> bool:
        return self->at > 0

    def next(self: *Rows) -> i64:
        self->at -= 1
        return self->at

def main() -> int:
    r: Rows = {3}
    total: i64 = 0
    for v in r:
        total += v
    return int(total)
