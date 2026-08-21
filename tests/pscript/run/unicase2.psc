"""Os predicados e os mapeamentos de caixa (105) num programa de verdade.

O par de oráculo varre o Unicode inteiro comparando com o Python; o que fica
aqui é o uso — validar entrada, normalizar um nome, contar dígitos — e o
tamanho da tabela em bytes, que é uma decisão registrada e não um acidente.
"""

def valida_nome(s: str) -> str:
    limpo = s.strip()
    if len(limpo) == 0:
        return "vazio"
    if not limpo.replace(" ", "").isalpha():
        return "tem o que não é letra"
    return limpo.title()

nomes = ["  ana maria  ", "josé da silva", "x9", "", "   ", "ÁGUEDA"]
for n in nomes:
    print(f"[{n}] -> [{valida_nome(n)}]")

def so_digitos(s: str) -> bool:
    return len(s) > 0 and s.isdecimal()

for c in ["42", "007", "4a", "", " 4", "١٢٣"]:
    print(f"[{c}] {so_digitos(c)}")

# contar por categoria, que é o uso que a tabela existe para servir
texto = "Olá, Mundo 123! ①②③ 三"
letras = 0
digitos = 0
espacos = 0
outros = 0
for ch in texto:
    if ch.isalpha():
        letras += 1
    elif ch.isdigit():
        digitos += 1
    elif ch.isspace():
        espacos += 1
    else:
        outros += 1
print(f"letras {letras} digitos {digitos} espacos {espacos} outros {outros}")

# e as bordas: a string vazia é False em todos, e o de TÍTULO não é nem
# maiúsculo nem minúsculo
print("".isalpha(), "".isdigit(), "".isspace(), "".isupper(), "".istitle())
print("ǅ".isupper(), "ǅ".islower(), "ǅ".istitle(), "ǅ".title(), "ǅ".upper(), "ǅ".lower())
print("straße".upper(), "straße".title(), "STRASSE".lower())
print("hello world".title(), "hello-world".title(), "o'neill".title())
