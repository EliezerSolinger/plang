# 98.4: a tupla que guarda referência É valor e compila; o que não compila é o
# `==` dela, que precisaria de uma comparação que ande dentro
def named() -> (str, int):
    return ("answer", 42)


a = named()
b = named()
print(str(a == b))
