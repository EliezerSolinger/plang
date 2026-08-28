"""Os predicados e os mapeamentos de caixa (105) num programa de verdade.

O par de oráculo varre o Unicode inteiro comparando com o Python; o que fica
aqui é o uso — validar entrada, normalizar um nome, contar dígitos — e o
tamanho da tabela em bytes, que é uma decisão registrada e não um acidente.
"""

def valid_name(s: str) -> str:
    clean = s.strip()
    if len(clean) == 0:
        return "vazio"
    if not clean.replace(" ", "").isalpha():
        return "tem o que não é letra"
    return clean.title()

names = ["  ana maria  ", "josé da silva", "x9", "", "   ", "ÁGUEDA"]
for n in names:
    print(f"[{n}] -> [{valid_name(n)}]")

def only_digits(s: str) -> bool:
    return len(s) > 0 and s.isdecimal()

for c in ["42", "007", "4a", "", " 4", "١٢٣"]:
    print(f"[{c}] {only_digits(c)}")

# contar por categoria, que é o uso que a tabela existe para servir
text_s = "Olá, Mundo 123! ①②③ 三"
letters = 0
digits = 0
spaces = 0
others = 0
for ch in text_s:
    if ch.isalpha():
        letters += 1
    elif ch.isdigit():
        digits += 1
    elif ch.isspace():
        spaces += 1
    else:
        others += 1
print(f"letras {letters} digitos {digits} espacos {spaces} outros {others}")

# e as bordas: a string vazia é False em todos, e o de TÍTULO não é nem
# maiúsculo nem minúsculo
print("".isalpha(), "".isdigit(), "".isspace(), "".isupper(), "".istitle())
print("ǅ".isupper(), "ǅ".islower(), "ǅ".istitle(), "ǅ".title(), "ǅ".upper(), "ǅ".lower())
print("straße".upper(), "straße".title(), "STRASSE".lower())
print("hello world".title(), "hello-world".title(), "o'neill".title())
