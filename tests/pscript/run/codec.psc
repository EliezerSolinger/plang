"""base64 e hex (155): **escrever é um método dos BYTES, ler é um método do TEXTO.**

Isto foi um pacote durante um dia. Saiu de lá por uma razão de custo — 116 linhas
de aritmética sobre seis bits, com um `pack.json`, uma versão para subir, um
directório de testes e uma entrada num metapacote à volta delas: *a moldura era
maior do que o quadro*, e o quadro não vai mudar, porque a RFC 4648 é de 2006 e
está fechada.

E há um argumento melhor do que o do custo: **o `json` já estava no runtime.**
base64 e hex são a mesma espécie de coisa — uma codificação de fio com
especificação congelada e sem política — e são menores. Ter um dentro e o outro
fora não é uma distinção que se consiga explicar a ninguém.

**Métodos e não módulo**, que é a segunda metade da decisão: não há `import`
nenhum para lembrar, e `d.hex()` é literalmente o que se escreveria em Python. O
sentido está no tipo — de bytes para texto sai dos bytes; de texto para bytes sai
do texto.

**A linha que impede o resto de entrar está na 155.2**, e o critério não é o
tamanho: entra uma codificação com especificação CONGELADA e sem POLÍTICA. O
`csv` tem dialectos, o `datetime` tem um modelo, o `compress` tem três formatos —
e por isso os três continuam pacotes.
"""


def main():
    # ---- 1. os vectores da RFC 4648 §10 ----
    print("[" + b"".base64() + "]", b"f".base64(), b"fo".base64(), b"foo".base64())
    print(b"foob".base64(), b"fooba".base64(), b"foobar".base64())

    # ---- 2. as QUATRO variantes, e é a vida que as cobra ----
    #
    # 0xFB 0xFF 0xBF dá `+/+/` no padrão e `-_-_` no URL-safe: são exactamente os
    # dois caracteres que separam os alfabetos, no mesmo valor. E o enchimento é
    # obrigatório para uns leitores e proibido para outros — um JWT não tem
    # nenhum. Duas perguntas, dois booleanos, quatro respostas.
    v = b"\xfb\xff\xbf"
    print("std  ", v.base64())
    print("url  ", v.base64(True))
    print("nopad", b"fo".base64(False, False))
    print("both ", b"\xfb\xff".base64(True, False))

    # ---- 3. descodificar ACEITA os dois alfabetos, com ou sem enchimento ----
    #
    # É a regra de Postel aplicada onde é segura: a entrada vem de outra pessoa,
    # e há exactamente uma cadeia de bytes que ela pode querer dizer.
    for t in ["Zm8=", "Zm8", "-_-_", "+/+_"]:
        d = t.from_base64()
        if d != None:
            print("aceita", t, "->", len(d), "bytes")

    # ---- 4. e recusa, devolvendo None em vez de levantar (4.2) ----
    print("caractere de fora:", "Zm8*".from_base64() == None)
    print("um caractere so:", "Z".from_base64() == None)
    # `Zn` seriam 6 bits de `Z` mais 6 de `n` = um byte e dois bits A SOBRAR não
    # nulos. Aceitar isso faria duas entradas diferentes dar o mesmo resultado,
    # que é como se forjam assinaturas em base64.
    print("bits a mais:", "Zn".from_base64() == None)
    print("e sem bits a mais passa:", "Zg".from_base64() != None)

    # ---- 5. hex, nos dois sentidos e nas duas caixas ----
    print(b"\x00\x0f\xa5\xff".hex(), b"\xa5".hex(True))
    h = "000FA5ff".from_hex()
    if h != None:
        print("le as duas caixas:", h.hex())
    print("impar:", "abc".from_hex() == None)
    print("nao e hex:", "zz".from_hex() == None)
    z = "".from_hex()
    if z != None:
        print("vazio:", "[" + b"".hex() + "]", len(z))

    # ---- 6. ida e volta sobre TODOS os bytes, e sobre cada comprimento ----
    todos: List<u8> = []
    for i in range(256):
        todos.append(u8(i))
    b = bytes(todos)
    v1 = b.base64().from_base64()
    v2 = b.hex().from_hex()
    if v1 != None:
        if v2 != None:
            print("todos os bytes:", v1 == b, v2 == b)
    mau = 0
    for n in range(20):
        pedaco: List<u8> = []
        for i in range(n):
            pedaco.append(u8((i * 37 + 11) % 256))
        p = bytes(pedaco)
        back = p.base64().from_base64()
        if back == None:
            mau += 1
            continue
        if back != p:
            mau += 1
    print("cada comprimento ate 20:", mau == 0)

    print("codec-ok")


main()
