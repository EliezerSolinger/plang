enum Shade:
    DARK
    LIGHT
def f(s: Shade) -> int:
    match s:
        case DARK:
            return 1
    return 0
