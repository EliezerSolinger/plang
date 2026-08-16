# the signature of an `implement` block has to match the trait WHOLE (72.5):
# a return type that disagrees used to slip through and surface much later
trait Shrinker:
    def shrink(self: *Shrinker, by: i64) -> i64

struct Box:
    n: i64

implement Shrinker for Box:
    def shrink(self: *Box, by: i64) -> f64:
        return 1.0

def main() -> int:
    return 0
