"""O descodificador INCREMENTAL (140/F6): o que o `CharsetDecoder` do NIO é.

`str(b)` descodifica tudo de uma vez e LEVANTA se os bytes não forem texto
(79.1) — a resposta certa para um ficheiro inteiro e a errada para um fluxo. Um
codepoint pode chegar partido em duas leituras, e isso não é um erro: é o que
acontece quando se lê 4096 bytes de cada vez.

**A política de erro é SUBSTITUIR por U+FFFD**, e não levantar. Um terminal que
morresse ao receber um byte solto de um ficheiro binário seria inútil, e U+FFFD é
o que todo o descodificador incremental do mundo põe ali. Quem quer a regra
estrita continua a ter `str(b)` — são duas perguntas, e há duas respostas.

Foi a peça que faltou de verdade: o widget de terminal do pstudio teve de
escrever esta máquina de estados à mão porque não havia outra. Agora não tem.
"""


def main():
    # ---- 1. o caso inteiro, de uma vez ----
    d = Decoder()
    print(d.feed("olá, mundo".encode()), d.pending())

    # ---- 2. o mesmo codepoint, partido em dois pedaços ----
    #
    # `é` é 0xC3 0xA9. Vem um byte numa leitura e o outro na seguinte, que é o
    # que um socket faz o tempo todo.
    d2 = Decoder()
    print("[" + d2.feed(b"\xc3") + "]", d2.pending())
    print("[" + d2.feed(b"\xa9!") + "]", d2.pending())

    # ---- 3. partido em TRÊS, e um de quatro bytes ----
    #
    # 😀 é 0xF0 0x9F 0x98 0x80
    d3 = Decoder()
    print("[" + d3.feed(b"\xf0\x9f") + "]", d3.pending())
    print("[" + d3.feed(b"\x98") + "]", d3.pending())
    print("[" + d3.feed(b"\x80fim") + "]", d3.pending())

    # ---- 4. o que NÃO é texto vira U+FFFD e o fluxo continua ----
    d4 = Decoder()
    # 0xFF nunca é o começo de nada
    r = d4.feed(b"a\xffb")
    print("solto:", len(r), r == "a�b")
    # uma continuação sem começo
    print("orfa:", d4.feed(b"\x80") == "�")
    # um começo cuja continuação nunca chega, e depois um byte que não serve:
    # cai um U+FFFD pelo que se perdeu e o byte que partiu é lido outra vez
    print("partida:", d4.feed(b"\xc3z") == "�z")

    # ---- 5. codificação demasiado longa, substituto e acima do último plano ----
    d5 = Decoder()
    print("longa:", d5.feed(b"\xe0\x80\x80") == "�")       # ASCII em 3 bytes
    print("substituto:", d5.feed(b"\xed\xa0\x80") == "�")  # U+D800
    print("alem:", d5.feed(b"\xf4\x90\x80\x80") == "�")    # > U+10FFFF

    # ---- 6. o fim do fluxo com uma sequência a meio ----
    d6 = Decoder()
    print("meio:", d6.feed(b"ok\xe2\x82") == "ok", d6.pending())
    print("fecho:", d6.finish() == "�", d6.pending())
    # e depois de fechar, um decodificador continua a servir
    print("segue:", d6.feed(b"!") == "!")

    print("decoder-ok")


main()
