"""A ponte para o oráculo: lê `nome op fin corpo-hex quadro-hex` do stdin e faz
as duas coisas — PARSEIA o quadro que a biblioteca do Python produziu, e
SERIALIZA o mesmo quadro a partir das peças. As duas saídas vão comparadas contra
ela, porque um oráculo só num sentido prova metade: um parser e um serializador
que errassem da mesma maneira concordariam entre si e com mais ninguém.
"""
import <ws/ws.psc> as ws
import sys


def from_hex(h: str) -> bytes:
    # `from_hex` devolve `bytes?`, porque hex inválido não é bytes nenhuns — e
    # aqui a entrada vem do oráculo, portanto um `None` é um defeito do arreio
    if h == "-":
        return b""
    v = h.from_hex()
    if v == None:
        raise error("hex invalido no vector: " + h)
    return v


# os vectores vêm de um FICHEIRO e não do stdin: o `sys` do pscript não lê o
# stdin, e um ficheiro é de qualquer maneira o que um portão quer — pode ser
# olhado depois de a comparação falhar.
modo = sys.argv[1]
f0 = await open(sys.argv[2], "r")
linhas = await f0.readlines()
f0.close()
for linha0 in linhas:
    linha = linha0.rstrip()
    if len(linha) == 0:
        continue
    campos = linha.split(" ")
    nome = campos[0]
    op = int(campos[1])
    fin = campos[2] == "1"
    corpo = from_hex(campos[3])
    quadro = from_hex(campos[4])

    if modo == "parse":
        p = ws.parser(len(quadro) > 1 and (int(quadro[1]) & 0x80) != 0)
        p.feed(quadro)
        f = p.next()
        if f == None:
            print(nome + " ERRO " + (p.problem if p.failed() else "incompleto"))
        else:
            print(nome + " " + str(f.op) + " " + ("1" if f.fin else "0")
                  + " " + (f.payload.hex() if len(f.payload) > 0 else "-"))
    else:
        saida = ws.serialize(ws.Frame(fin, False, False, False, op, corpo), b"")
        print(nome + " " + saida.hex())
