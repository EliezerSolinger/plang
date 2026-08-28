"""O oráculo do WebSocket: a biblioteca `websockets` do Python, nos DOIS sentidos.

`gerar` põe na saída quadros serializados por ela, para o nosso parser os ler.
`conferir` lê os quadros que o NOSSO serializador produziu e diz o que ela vê
neles. Um oráculo só num sentido prova metade: um parser e um serializador que
errassem da mesma maneira concordariam entre si e com mais ninguém.
"""
import sys
from websockets.frames import Frame, Opcode

CASOS = [
    ("texto-curto",    Opcode.TEXT,   b"Hello", True),
    ("binario",        Opcode.BINARY, b"\x00\x01\xfe\xff", True),
    ("vazio",          Opcode.TEXT,   b"", True),
    ("125",            Opcode.BINARY, b"y" * 125, True),
    ("126",            Opcode.BINARY, b"y" * 126, True),
    ("65535",          Opcode.BINARY, b"y" * 65535, True),
    ("65536",          Opcode.BINARY, b"y" * 65536, True),
    ("ping-com-corpo", Opcode.PING,   b"pong-me", True),
    ("pong-vazio",     Opcode.PONG,   b"", True),
    ("utf8",           Opcode.TEXT,   "olá mundo 日本語 \U0001f3ae".encode(), True),
    ("frag-inicio",    Opcode.TEXT,   b"parte1", False),
    ("frag-fim",       Opcode.CONT,   b"parte2", True),
    ("close-1000",     Opcode.CLOSE,  b"\x03\xe8adeus", True),
]


def gerar(mask):
    for nome, op, data, fin in CASOS:
        f = Frame(op, data, fin=fin)
        print("%s %d %d %s %s" % (nome, int(op), 1 if fin else 0,
                                  data.hex() or "-", f.serialize(mask=mask).hex()))


def conferir():
    """Cada linha da entrada é `nome hex`; a saída é o que a biblioteca leu."""
    for linha in sys.stdin:
        linha = linha.strip()
        if not linha:
            continue
        nome, hx = linha.split()
        raw = bytes.fromhex(hx)
        pos = [0]

        def read_exact(n):
            b = raw[pos[0]:pos[0] + n]
            pos[0] += n
            if len(b) != n:
                raise EOFError("faltam bytes")
            return b
            yield  # pragma: no cover — torna-a um gerador

        def driver(n):
            return read_exact(n)

        gen = Frame.parse(driver, mask=(len(raw) > 1 and (raw[1] & 0x80) != 0))
        try:
            while True:
                next(gen)
        except StopIteration as stop:
            f = stop.value
        print("%s %d %d %s" % (nome, int(f.opcode), 1 if f.fin else 0, f.data.hex() or "-"))


if __name__ == "__main__":
    if sys.argv[1] == "gerar":
        gerar(sys.argv[2] == "mask")
    else:
        conferir()
