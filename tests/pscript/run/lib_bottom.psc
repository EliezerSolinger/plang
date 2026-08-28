"""Um MÓDULO pscript que importa um módulo P (1.5d).

O `import "pmod_fundo.ph"` está aqui, e não no programa. É essa a diferença que
o teste ao lado prende.
"""
import "pmod_fundo.ph"


def dobro(v: int) -> int:
    return fundo_dobro(v)


def impar(v: int) -> bool:
    return fundo_impar(v)
