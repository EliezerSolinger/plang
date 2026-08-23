"""The ROOT module of the `color` package — what `import <color>` brings in."""

def lighten(v: int) -> int:
    """One step lighter."""
    return v + 16


def name() -> str:
    return "color"
