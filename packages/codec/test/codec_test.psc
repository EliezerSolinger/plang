"""`codec` (S2): base64 e hex, nos dois sentidos.

**Base64 tem quatro variantes, e é a vida que as cobra.** O alfabeto padrão acaba
em `+` e `/`, que são os dois caracteres que um URL não pode levar; por isso a
RFC 4648 §5 define um segundo alfabeto. E o enchimento `=` é obrigatório para uns
leitores e proibido para outros (um JWT não tem nenhum). Duas perguntas, dois
booleanos, quatro respostas — e oferecer só uma delas é o que faz cada projecto
escrever as outras três à mão.

**Descodificar ACEITA o que codificar não produziria**, e é de propósito: leva
qualquer dos alfabetos, com ou sem enchimento. É a regra de Postel aplicada onde
é segura — a entrada vem de outra pessoa, e há exactamente uma cadeia de bytes
que ela pode querer dizer.

**O que não é aquela codificação devolve None** (4.2), e não levanta: entrada de
fora que não analisa é um caso previsto, não um acidente.
"""
import <codec/codec.psc> as codec


def rt(name: str, b: bytes):
    s = codec.base64_encode(b)
    back = codec.base64_decode(s)
    if back == None:
        print(name, "NAO DESCODIFICOU", s)
        return
    if back != b:
        print(name, "IDA E VOLTA FALHOU", s)


def main():
    # ---- 1. os vectores da RFC 4648 §10 ----
    print(codec.base64_encode(b""))
    print(codec.base64_encode(b"f"), codec.base64_encode(b"fo"), codec.base64_encode(b"foo"))
    print(codec.base64_encode(b"foob"), codec.base64_encode(b"fooba"), codec.base64_encode(b"foobar"))

    # ---- 2. as quatro variantes do mesmo valor ----
    #
    # 0xFB 0xFF 0xBF dá `+/+/` no padrão e `-_-_` no URL-safe: são exactamente
    # os dois caracteres que separam os alfabetos, no mesmo valor.
    v = b"\xfb\xff\xbf"
    print("std  ", codec.base64_encode(v))
    print("url  ", codec.base64_encode(v, True))
    print("nopad", codec.base64_encode(b"fo", False, False))
    print("both ", codec.base64_encode(b"\xfb\xff", True, False))

    # ---- 3. descodificar aceita as quatro ----
    for s in ["Zm8=", "Zm8", "-_-_", "+/+_"]:
        d = codec.base64_decode(s)
        if d != None:
            print("aceita", s, "->", len(d), "bytes")

    # ---- 4. e recusa o que nao e base64 ----
    print("caractere de fora:", codec.base64_decode("Zm8*") == None)
    print("um caractere so:", codec.base64_decode("Z") == None)
    # 'Zn' seriam 6 bits de 'Z' + 6 de 'n' = um byte e dois bits a SOBRAR nao
    # nulos. Aceitar isso faria duas entradas dar o mesmo resultado, que e como
    # se forja uma assinatura em base64.
    print("bits a mais:", codec.base64_decode("Zn") == None)
    print("e sem bits a mais passa:", codec.base64_decode("Zg") != None)

    # ---- 5. ida e volta sobre todos os bytes ----
    todos: List<u8> = []
    for i in range(256):
        todos.append(u8(i))
    rt("todos os bytes", bytes(todos))
    for n in range(20):
        pedaco: List<u8> = []
        for i in range(n):
            pedaco.append(u8((i * 37 + 11) % 256))
        rt("comprimento " + str(n), bytes(pedaco))
    print("ida e volta: sem queixas acima")

    # ---- 6. hex ----
    print(codec.hex_encode(b"\x00\x0f\xa5\xff"), codec.hex_encode(b"\xa5", True))
    h = codec.hex_decode("000FA5ff")
    if h != None:
        print("hex nos dois casos:", codec.hex_encode(h))
    print("impar:", codec.hex_decode("abc") == None)
    print("nao e hex:", codec.hex_decode("zz") == None)
    z = codec.hex_decode("")
    if z != None:
        print("vazio:", codec.hex_encode(b""), len(z))

    print("codec-ok")


main()
