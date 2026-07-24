def f(n: const *char) -> i32:
    match n:
        case "a":
            return 1
        case "b", "a":
            return 2
    return 0
def main() -> int:
    return f("x")
