# um nome NU desconhecido num `const if` de topo continua sendo erro: é o que
# pega `__PLANG_LINUXX__` escrito errado (110)
const if __PLANG_LINUXX__:
    const X = 1
else:
    const X = 2

def main() -> int:
    return X
