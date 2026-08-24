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

E a tupla que guarda REFERÊNCIA (`(str, int)`) também entra, e sem virar objeto:
imutável e sem identidade, copiar é indistinguível de compartilhar, então o que o
coletor precisa não é um cabeçalho — é saber ONDE, dentro daqueles bytes, estão
as referências. Isso é dado de tipo: o frame registra um slot por referência
dentro do valor (`&t._0`), e uma variável de módulo ganha uma raiz por
referência. E o que anda DENTRO do elemento de um contêiner também entrou: o contêiner leva
um ponteiro de percurso que o compilador escreveu, então `List<(str, int)>` — e
com ele `d.items()` como VALOR — funciona com a tupla ainda sendo valor. Falta só
o `==` dela, que usa o mesmo percurso, e a chave de dict, que continua pura.
"""

MODULE_TUPLE = ("declared at the top", 99)

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
board: Dict<(int, int), str> = {}
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


# ---- tupla que guarda referência (98.4), ainda como VALOR ----
def described(i: int) -> (str, int):
    return (f"item{i}", i * 10)


label, value = described(3)
print(f"ref-tuple {label} {value}")

held = ("kept across a collection", 1)
# alocar com a tupla viva é o teste de verdade: se o frame não registrasse o
# campo, o coletor moveria a string e o que sobrasse apontaria para o passado
i = 0
noise = ""
while i < 50:
    noise = f"n{i}"
    i += 1
print(f"still {held[0]} {held[1]} {len(noise)}")

# o slot também é registrado quando a tupla mora numa variável de MÓDULO, que é
# outro lugar (uma raiz, não um slot de frame) e a mesma ideia
print(f"module-level {MODULE_TUPLE[0]} {MODULE_TUPLE[1]}")


# ---- dentro de um contêiner, com o coletor andando DENTRO do elemento ----
rows: List<(str, int)> = []
i = 0
while i < 4:
    rows.append((f"row{i}", i * i))
    i += 1
print(f"rows {len(rows)} {rows[0][0]} {rows[3][1]}")
acc = ""
for r in rows:
    acc += r[0]
print(f"walked {acc}")

# e como o Python imprime
print(rows)
print((1, "two", 3.5))
