"""A prova de não-nulo, nas quatro formas que um programa de verdade escreve
(114). A 43.1 dava uma: `if x != None:` e dentro do ramo `x` é `T`. O porte do
editor cobrou as outras quatro no mesmo dia — cada uma apareceu escrevendo código
comum, não procurando buraco.
"""

record P2:
    x: int
    y: int


def get(n: int) -> P2?:
    return P2(n, n * 2) if n > 0 else None


# 1. a GUARDA: o caso ausente sai primeiro, e o resto da função já sabe
def guard(n: int) -> int:
    p = get(n)
    if p == None:
        return -1
    return p.x + p.y


# 2. o ELSE de um `== None`
def in_else(n: int) -> int:
    p = get(n)
    if p == None:
        return -1
    else:
        return p.x * 10


# 3. o `and`: a prova do lado esquerdo vale no direito, e no corpo
def in_and(n: int) -> int:
    p = get(n)
    if p != None and p.x > 1:
        return p.y
    return 0


# 4. a guarda com `or`: se ela saiu, nenhum dos lados valia
def guard_or(n: int, limit: int) -> int:
    p = get(n)
    if p == None or p.x > limit:
        return -1
    return p.y


# 5. o ELIF: cada ramo é provado pela SUA condição
def in_elif(a: int, b: int) -> int:
    p = get(a)
    q = get(b)
    if p != None:
        return p.x
    elif q != None:
        return q.y
    return 0


# e um `if` ANINHADO dentro do ramo não desfaz a prova de fora
def nested(n: int) -> int:
    p = get(n)
    if p != None:
        if p.x > 100:
            return 100
        return p.x + p.y
    return -1


print(str(guard(3)) + " " + str(guard(0)))
print(str(in_else(2)) + " " + str(in_else(-1)))
print(str(in_and(5)) + " " + str(in_and(1)) + " " + str(in_and(0)))
print(str(guard_or(4, 10)) + " " + str(guard_or(4, 2)) + " " + str(guard_or(0, 10)))
print(str(in_elif(7, 0)) + " " + str(in_elif(0, 5)) + " " + str(in_elif(0, 0)))
print(str(nested(9)) + " " + str(nested(200)) + " " + str(nested(0)))

# um opcional de FUNÇÃO (o campo de sinal do toolkit) passa pelas mesmas provas.
# O parêntese é obrigatório: sem ele o `?` cai no tipo de RETORNO.
f: (def(int) -> int)? = None
print("sem função: " + str(f == None))
f = lambda v: v * 3
if f != None:
    print("com função: " + str(f(4)))
