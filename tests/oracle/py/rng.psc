"""MT19937, `math` e `time` (103), contra o Python de quem foram portados.

O motivo de PORTAR o Mersenne Twister em vez de escrever qualquer gerador: com
a mesma semente a sequência tem de ser A MESMA do Python, e aí este arquivo
compara número por número em vez de "parece aleatório". Duas linhas trocadas no
`_randbelow` (contar os bits de n-1 em vez de n) passam por qualquer teste de
aleatoriedade e são pegas aqui na primeira lista de tamanho quatro.

`math` é a libm dos dois lados, então o que este arquivo mede ali é o CONTRATO:
quais funções devolvem int (floor, ceil, trunc) e quais devolvem float.
"""

import random
import math

# ---- a sequência crua: 10 doubles, todos os 53 bits ----
random.seed(42)
for i in range(10):
    print(random.random())

# ---- getrandbits em todas as larguras que importam ----
random.seed(12345)
print(random.getrandbits(1), random.getrandbits(8), random.getrandbits(16))
print(random.getrandbits(31), random.getrandbits(32), random.getrandbits(33))
print(random.getrandbits(63))

# ---- randint e randrange: o `_randbelow` por baixo, com a rejeição ----
random.seed(2024)
for i in range(8):
    print(random.randint(1, 6), random.randint(0, 1), random.randrange(100))
print(random.randrange(5, 15), random.randrange(0, 100, 7), random.randrange(10, 0, -3))

# ---- uma potência de dois em cada tamanho: onde o bit_length errado divergiria ----
random.seed(99)
for n in [2, 4, 8, 16, 32, 64]:
    print(n, random.randrange(n), random.randrange(n), random.randrange(n))

# ---- shuffle: Fisher-Yates de trás para frente, com o MESMO consumo ----
random.seed(1)
for n in [2, 3, 4, 5, 8, 13]:
    xs = [i for i in range(n)]
    random.shuffle(xs)
    print(xs)

# ---- choice: seq[_randbelow(len(seq))] ----
random.seed(7)
names = ["ana", "bruno", "carla", "davi"]
for i in range(6):
    print(random.choice(names))

# ---- uniform ----
random.seed(3)
for i in range(4):
    print(random.uniform(0.0, 1.0))
print(random.uniform(-10.0, 10.0))

# ---- semear de novo repõe a sequência exatamente ----
random.seed(555)
a = random.random()
b = random.getrandbits(20)
random.seed(555)
print(a == random.random(), b == random.getrandbits(20))

# ---- semente grande, e negativa (o Python usa o valor absoluto em palavras) ----
random.seed(1234567890123456789)
print(random.random())
random.seed(0)
print(random.random())
random.seed(-42)
print(random.random(), random.getrandbits(24))

# ---- gauss: o método polar sai aos pares, e o Python GUARDA o segundo ----
# Quem joga o segundo fora passa em qualquer teste de normalidade e divide da
# segunda chamada em diante — é o par guardado que faz a sequência ser a mesma.
random.seed(42)
for i in range(9):
    print(random.gauss(0.0, 1.0))
print(random.gauss(10.0, 2.5), random.gauss(-1.0, 0.5))

# semear no meio joga fora o par pendente
random.seed(8)
g1 = random.gauss(0.0, 1.0)
random.seed(8)
print(g1 == random.gauss(0.0, 1.0))

random.seed(11)
for i in range(5):
    print(random.expovariate(1.0), random.expovariate(2.5))

# ---- math: quem devolve int ----
print(math.floor(2.7), math.ceil(2.1), math.trunc(-2.7))
print(math.floor(-2.1), math.ceil(-2.9), math.trunc(2.9))
print(math.sqrt(2.0), math.fabs(-3.5), math.pow(2.0, 10.0))
print(math.sin(0.0), math.cos(0.0), math.atan2(1.0, 1.0))
print(math.log(math.e), math.log2(1024.0), math.log10(1000.0), math.exp(0.0))
print(math.hypot(3.0, 4.0), math.fmod(7.0, 3.0))
print(math.pi, math.e, math.tau)
