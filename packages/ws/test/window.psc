"""Emite fluxos DEFLATE comprimidos com janelas DIFERENTES, para o
`tests/ws-window.py` conferir as distancias que eles usam.

Quando se responde `server_max_window_bits=N` a uma oferta de permessage-deflate,
promete-se que nenhum casamento do nosso LZ77 passa 2^N bytes de distancia -- e
essa promessa nao se confere com um `zlib.decompressobj(wbits=-8)`: o CPython
aceita alegremente um fluxo com casamentos a 400 bytes de distancia lido com uma
janela de 256, portanto passaria tanto o codigo certo como o errado. Quem confere
e um descodificador que olha para os SIMBOLOS.

Os dados sao feitos para discriminar: enchimento sem periodo curto (um LCG), e
depois a repeticao dos primeiros 40 bytes. O unico casamento util esta a ~400
bytes -- uma janela de 8 bits nao o alcanca, uma de 15 alcanca. Se os dois
tamanhos derem o mesmo, o teste nao esta a testar nada, e foi o que aconteceu a
primeira versao deste ficheiro: o enchimento tinha periodo 74 e havia casamentos
perto que dispensavam o longe.
"""
import <ws/ws.psc> as ws
import sys


def build() -> bytes:
    o: List<u8> = []
    x = 12345
    i = 0
    while i < 400:
        nocheck:
            x = (x %* 1103515245 %+ 12345) & 0x7FFFFFFF
        o.append(u8((x >> 16) & 0xFF))
        i += 1
    j = 0
    while j < 40:
        o.append(o[j])
        j += 1
    return bytes(o)


src = build()
for bits in [8, 10, 15]:
    z = ws.compress_payload(src, bits)
    ignored = sys.out.write(str(bits) + " " + z.hex() + "\n")
