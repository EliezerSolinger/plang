"""Um MÓDULO pscript que importa um módulo P (1.5d).

O `import "pmod_bottom.ph"` está aqui, e não no programa. É essa a diferença que
o teste ao lado prende.
"""
import "pmod_bottom.ph"


def double_v(v: int) -> int:
    return bottom_double(v)


def odd(v: int) -> bool:
    return bottom_odd(v)
