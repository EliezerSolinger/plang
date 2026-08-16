"""Indexar uma string em O(1) (80.1b).

A decisão pedia a largura adaptativa do PEP 393 — latin-1/UCS-2/UCS-4 por
string. Implementá-la ao pé da letra sairia caro de um jeito que só ficou
visível depois de o resto existir: TUDO neste sistema quer os bytes UTF-8 —
o socket, o arquivo, a mensagem entre heaps, a fronteira com o P (84.1), o
`print`. Com o texto guardado em UCS-4, cada travessia teria de materializar o
UTF-8, e é por isso que o próprio PEP 393 guarda as DUAS formas. O preço real
seria duas cópias de toda string que atravessa qualquer coisa.

O que está implementado alcança a mesma propriedade observável com uma cópia
só:

  * ASCII — a esmagadora maioria, e todo texto de protocolo — não precisa de
    nada: `nchars == len` já É a prova de que cada byte é um caractere. Essa
    prova estava no cabeçalho desde sempre;
  * o resto ganha um ÍNDICE DE DESLOCAMENTOS construído na primeira vez que
    alguém indexa AQUELA string, guardado nela e coletado com ela. O(n) uma
    vez, O(1) daí em diante, e nada para quem nunca indexa.

Uma `str` é imutável (31.3), então o índice nunca se invalida.
"""

import sys

ascii: str = "abcdefghij"
misto: str = "áéíóúçãõ ñ"

print("ascii:", ascii[0], ascii[4], ascii[-1])
print("misto:", misto[0], misto[4], misto[-1])
print("fatias:", ascii[2:5], misto[2:5])
print("tamanhos em CARACTERES:", len(ascii), len(misto))

# o `for ch in s` anda pela mesma máquina
juntos = ""
for ch in misto:
    juntos += ch
print("remontado igual:", juntos == misto)

# muitos acessos na mesma string não-ASCII: o índice é construído uma vez
grande = ""
for i in range(300):
    grande += "áb"
soma = 0
for i in range(len(grande)):
    soma += ord(grande[i])
print("caracteres:", len(grande), "soma:", soma)

# uma coleta no meio não perde o índice: ele é um objeto coletado como outro
lixo: list<str> = []
for i in range(2000):
    lixo.append("x" + str(i))
print("depois da coleta:", grande[599], len(grande))
