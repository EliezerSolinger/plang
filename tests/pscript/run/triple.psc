"""As aspas triplas, e o que vive DENTRO delas.

O lexema de uma string tripla carrega as seis aspas, e quem o decodifica
aplicava a regra do C — literais adjacentes concatenam-se, e toda aspa é
fronteira. Numa string tripla isso CORTAVA o corpo em cada aspa interna:
`\"\"\"a "b" c\"\"\"` saía como `a  c`. Aqui isso fica preso.
"""

s: str = """a "b c" d"""
print(s)
print(len(s))

# uma aspa colada à abertura: `"""` seguido de `"x`, e o fecho separado por um
# espaço — colar quatro aspas no fim seria o mesmo erro que em Python, uma
# quinta aspa a abrir um literal que ninguém fecha
t: str = """"x" """
print(t)

# a barra invertida continua a valer dentro das triplas
u: str = """linha\tcom\ttabulação"""
print(u)

# e a aspa simples não é fronteira de nada aqui
v: str = """it's "quoted" twice"""
print(v)
print(len(v))

# uma tripla vazia continua vazia
w: str = """"""
print(len(w))
