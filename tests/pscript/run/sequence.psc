"""`Sequence<T>` como PARÂMETRO (60.3/62.1), e o que ele realmente é.

> *"interfaces definidas pelo sistema (Iterável, Sequência etc.) — tipos nativos
> já as implementariam quase sem custo"*

`def total(xs: Sequence<float>)` não é um tipo que o coletor ou o backend alguma
vez vejam. É uma **função genérica sobre o seu contentor**, escrita sem a
cerimónia — e passa a ser exactamente isso na sema:

    def total<__seq: Sequence<float>>(xs: __seq)

A partir daí a maquinaria é a que já existia desde a 66.3: o parâmetro é
inferido do argumento, o limite é conferido onde o tipo concreto está, e o corpo
é monomorfizado. **Zero vtable e zero cópia** — que é o que a 60.3 prometeu e o
que um parâmetro `List<float>` não conseguia dar, porque obrigava quem tem um
`float[8]` a construir uma lista para poder chamar.

**O limite é NATIVO e não nominal**, e é essa a diferença para uma trait que
alguém escreve: ninguém declara `implement Sequence for List<T>`, porque `List`
não é um tipo em que se possa abrir um bloco `implement`. O que o compilador
confere é que o contentor é um que a linguagem sabe percorrer e que o elemento é
o pedido.
"""


def total(xs: Sequence<float>) -> float:
    t = 0.0
    for x in xs:
        t += x
    return t


def biggest(xs: Sequence<int>) -> int:
    best = xs[0]
    for i in range(len(xs)):
        if xs[i] > best:
            best = xs[i]
    return best


# ... e o MESMO corpo sobre bytes, que é uma sequência de `u8` e não de `int`.
# O elemento faz parte do limite: `Sequence<int>` não aceita um `View<u8>`, e é
# bom que não aceite — a promessa é sobre o que sai do `for`.
def biggest8(xs: Sequence<u8>) -> int:
    best = 0
    for x in xs:
        if int(x) > best:
            best = int(x)
    return best


# os quatro contentores, e o mesmo corpo a servir os quatro
lista: List<float> = [1.5, 2.5, 3.0]
print("List:", total(lista))

fixo: float[4] = [1.0, 2.0, 3.0, 4.0]
print("T[N]:", total(fixo))

with Buffer(16) as b:
    v = b.view_u8()
    v[0] = u8(9)
    v[1] = u8(4)
    v[2] = u8(7)
    print("View:", biggest8(v))

print("bytes:", biggest8(b"\x03\x11\x07"))

print("e o corpo é UM:", biggest([5, 40, 3]))
