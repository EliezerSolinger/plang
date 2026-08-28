"""Os knobs do motor (110): `-D` para o que dimensiona, chamada para o que se ajusta.

O que vira constante de compilação e o que vira chamada não é gosto: o que
dimensiona um ARRAY (os frames do rastro, os descritores de um poll, o teto do
pool) tem de ser conhecido ao compilar; o que depende da CARGA (o orçamento do
coletor, quantas threads subir) o programa ajusta em runtime, porque só ele sabe
o que vai fazer.

E o ajuste vale para o CONTEXTO de quem chama: cada worker tem heap e coletor
próprios (18.1), então afinar num não afina no outro — o que é a resposta certa,
não uma limitação.
"""

import gc
import sys


def spend(n: int) -> int:
    junk: List<str> = []
    for i in range(n):
        junk.append(f"n{i}")
    return len(junk)


async def worker_tuned(n: int) -> int:
    # o worker afina o SEU coletor, e o do pai não muda
    gc.tune(bytes=1 << 20, objects=1000)
    st = gc.stats()
    parent.send(st["budget"] * 1000000 + st["budget_objects"])
    return 0


# ---- 1. o padrão, e o que o programa muda ----
before = gc.stats()
print(f"orcamento padrao {before['budget']} contagem {before['budget_objects']}")

gc.tune(bytes=4 << 20)
print(f"depois de tune(bytes) {gc.stats()['budget']} contagem intacta {gc.stats()['budget_objects']}")

gc.tune(objects=50000)
print(f"depois de tune(objects) {gc.stats()['budget_objects']} orcamento intacto {gc.stats()['budget']}")

# posicional também, na mesma ordem
gc.tune(2 << 20, 12345)
print(f"posicional {gc.stats()['budget']} {gc.stats()['budget_objects']}")

# ---- 2. coletar na hora, e as contas subindo ----
n0 = gc.stats()["collections"]
spend(3000)
gc.collect()
n1 = gc.stats()["collections"]
print(f"coletou mais {n1 > n0} e o vivo é maior que zero: {gc.stats()['live'] > 0}")

# ---- 3. as seis medidas existem e são inteiros ----
st = gc.stats()
keys_l = [k for k in st]
keys_l.sort()
print(f"medidas {keys_l}")

# ---- 4. o pool: antes da primeira operação de I/O ----
sys.pool(2)
print("pool pedido")

# ---- 5. o worker afina o dele, e o nosso fica como estava ----
meu = gc.stats()["budget"]
w = spawn(worker_tuned, (0,))
resp = await w.recv()
print(f"worker afinou para {resp // 1000000}/{resp % 1000000}, e o meu continua {gc.stats()['budget'] == meu}")

# ---- 6. as recusas ----
try:
    gc.tune(bytes=-1)
catch e:
    print(f"negativo: {e.message}")
try:
    sys.pool(0)
catch e2:
    print(f"zero: {e2.message}")
