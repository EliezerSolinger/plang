"""`from <pkg/mod.psc> import x` — a mesma importação, escrita da outra forma.

Faltava, e era uma assimetria sem razão: `import <pkg/mod.psc>` já existia, e um
pacote cujos nomes só se alcançam por um lado obriga a qualificar tudo. A grafia
do caminho é a mesma dos outros `<>`; o que muda é o que se liga no fim.
"""

from <tar/tar.psc> import octal, bytes_de, nome_seguro
from <tar/tar.psc> import escrever as empacotar

print(octal(493, 8))
print(len(bytes_de("olá")))
print(nome_seguro("a/b.txt") == "")
print(nome_seguro("/etc/passwd") != "")
b = empacotar([])
print(len(b))
