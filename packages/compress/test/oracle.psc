"""O compressor a serio, para o oraculo o ler.

Escreve ficheiros `.gz` num directorio, e quem os confere e o `zlib` do CPython
mais o `gunzip` da linha de comando -- dois leitores independentes que nao
compartilham codigo com ninguem aqui. E a unica prova que interessa: um
compressor que so o nosso `inflate` lesse teria os dois com o mesmo defeito.
"""
import <compress/compress.psc> as comp
import sys


f0 = await open(sys.argv[1], "r")
big = await f0.read_all()
f0.close()

cases: List<bytes> = [
    b"",
    b"a",
    b"ab",
    b"abc",
    # o caso que o LZ77 tem de apanhar: repeticao pura
    ("x" * 300).encode(),
    ("linha repetida\n" * 400).encode(),
    # e o que ele NAO pode piorar muito: bytes sem padrao
    b"\x00\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0a\x0b\x0c\x0d\x0e\x0f",
    # um casamento que se sobrepoe a si mesmo, que e o caso classico de erro:
    # distancia 1 e comprimento 200
    ("z" + "z" * 200).encode(),
    big,
]

i = 0
for c in cases:
    z = comp.gzip_compress(c)
    v = comp.gzip_decompress(z)
    print(str(len(c)) + " -> " + str(len(z)) + " roundtrip=" + str(v == c))
    g = await open(sys.argv[2] + "/caso" + str(i) + ".gz", "w")
    await g.write(z)
    g.close()
    o = await open(sys.argv[2] + "/caso" + str(i) + ".raw", "w")
    await o.write(c)
    o.close()
    i += 1
