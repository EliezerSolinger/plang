"""A tupla (98), terminada — a parte que não precisa do coletor.

O que existia: o TIPO `(int, int)`, o literal `(1, 2)`, e o desempacotamento com
parênteses. O que faltava, e entra aqui:

  * `t[0]`, com índice LITERAL. Tem de ser literal e não por preguiça: cada slot
    tem o seu próprio tipo, então `t[i]` com `i` de runtime não teria tipo
    nenhum. É a diferença entre tupla e lista, e é por isso que uma se escreve
    com `(` e a outra com `[`;
  * `len(t)`, que é constante — quantos slots faz parte do TIPO;
  * tupla como CHAVE de dict (24.3), que era o caso `d[(linha, coluna)]` que a
    decisão citava. Funciona porque uma tupla de bytes puros É um record (58.2):
    o dict copia a chave e compara por conteúdo com a máquina que já tinha;
  * a IMUTABILIDADE da 38.2 recusada de verdade — `t[0] = x` é o que faria o
    hash de uma chave-tupla envelhecer;
  * e `a, b = 1, 2`, a grafia do Python. O lado esquerdo já funcionava (uma
    lista de vírgulas é uma tupla para o parser); o que faltava era o lado
    DIREITO, que terminava na primeira vírgula.

Falta o que precisa do coletor: uma tupla que guarda `str`, `list` ou `struct`.
Ver o fim do AUDIT.
"""

t = (1, 2.5)
print(f"slots {len(t)}: {t[0]} {t[1]}")


def divide(a: int, b: int) -> (int, int):
    return (a // b, a % b)


q, r = divide(17, 5)
print(f"divide {q} rest {r}")

# a grafia com parênteses continua valendo, e é a mesma coisa
(q2, r2) = divide(9, 4)
print(f"parens {q2} {r2}")

# o lado direito também pode ser uma tupla nua, com três ou mais slots
x, y = 10, 20
p, s, u = 1, 2, 3
print(f"bare {x} {y} / {p}{s}{u}")

# tupla dentro de tupla, e o índice composto
nested = ((1, 2), 3)
print(f"nested {nested[0][1]} {nested[1]}")

# ---- chave de dict (24.3) ----
board: dict<(int, int), str> = {}
board[(0, 0)] = "origin"
board[(2, 3)] = "far"
print(f"board {len(board)}: {board[(0, 0)]} {board[(2, 3)]}")
print(f"in {(2, 3) in board} {(9, 9) in board}")
board.remove((0, 0))
print(f"after remove {len(board)}")

# a chave é COPIADA e comparada por conteúdo: duas tuplas iguais são a mesma
k1 = (5, 6)
k2 = (5, 6)
board[k1] = "by content"
print(f"same key {board[k2]}")

# ---- comparação por conteúdo (22.2) ----
print(f"eq {(1, 2) == (1, 2)} {(1, 2) == (1, 3)}")
