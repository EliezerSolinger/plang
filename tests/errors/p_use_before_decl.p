# Same ordering problem, but the file already HAS a forward declaration — just
# below the call. The line reported must be that declaration (10), not the body
# further down: the declaration is the thing that has to move up.
def usa() -> i32:
    return proto(3)

def main() -> int:
    return usa()

def proto(x: i32) -> i32

def proto(x: i32) -> i32:
    return x * 2
