"""A ponte para o oráculo: lê `name_s op fin body_b-hex frame_b-hex` do stdin e faz
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
mode = sys.argv[1]
f0 = await open(sys.argv[2], "r")
lines = await f0.readlines()
f0.close()
for line0 in lines:
    line = line0.rstrip()
    if len(line) == 0:
        continue
    fields = line.split(" ")
    name_s = fields[0]
    op = int(fields[1])
    fin = fields[2] == "1"
    body_b = from_hex(fields[3])
    frame_b = from_hex(fields[4])

    if mode == "parse":
        p = ws.parser(len(frame_b) > 1 and (int(frame_b[1]) & 0x80) != 0)
        p.feed(frame_b)
        f = p.next()
        if f == None:
            print(name_s + " ERRO " + (p.problem if p.failed() else "incompleto"))
        else:
            print(name_s + " " + str(f.op) + " " + ("1" if f.fin else "0")
                  + " " + (f.payload.hex() if len(f.payload) > 0 else "-"))
    else:
        out_s = ws.serialize(ws.Frame(fin, False, False, False, op, body_b), b"")
        print(name_s + " " + out_s.hex())
