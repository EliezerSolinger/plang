"""`bytes + bytes` (148), pela mesma razão que `str + str`.

Sem isto, juntar dois pedaços de fio obrigava a passar por `List<u8>` e a voltar
— duas cópias e uma travessia byte a byte para fazer o que um `memcpy` faz. E
juntar bytes é a operação central de qualquer coisa que fale um protocolo: a
linha de estado mais os cabeçalhos mais o corpo, o cabeçalho de um quadro mais a
carga, o pacote do MySQL mais o seu comprimento.

O resultado é sempre um bloco NOVO e dono do que tem. Não pode ser uma janela
sobre nenhum dos dois: juntar dois pedaços de um `Mapping` não tem janela que
cubra os dois.
"""

a = b"abc"
b = b"defg"
print(len(a + b), str(a + b), (a + b) == b"abcdefg")

# os vazios, dos dois lados e dos dois ao mesmo tempo
print(str(b"" + b"x"), str(b"x" + b""), len(b"" + b""))

# encadeado, e a associatividade não muda o resultado
print(str(a + b + b"!"), (a + (b + b"!")) == ((a + b) + b"!"))

# bytes NÃO são texto: um byte que não é UTF-8 sobrevive à junção intacto
cru = b"\x7fELF" + b"\x00\xff"
print(cru.hex(), len(cru))

# uma FATIA continua a ser bytes, e junta-se como qualquer outro
print(str(b"abcdef"[0:3] + b"XYZ"))

# e o que sai de um `str` também
print(str("ola ".encode() + "mundo".encode()))

# num laço, que é como um protocolo se monta de verdade
saida: bytes = b""
for i in range(5):
    saida = saida + str(i).encode()
print(str(saida), len(saida))
