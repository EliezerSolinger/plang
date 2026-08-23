"""`os.spawn`, `os.kill` e `os.alive` — o terceiro caso de correr um programa.

`os.run` cria um filho e ESPERA; `os.exec` VIRA o filho. Faltava o do laço de
desenvolvimento: LANÇAR, deixar correr, e mais tarde matar para relançar.

O que volta é o PID e não um objeto, e isso é decisão: um objeto vivo num
runtime com coletor levanta a pergunta do que acontece quando ele é recolhido
com o filho ainda a correr, e a resposta certa para essa pergunta não é óbvia.
Três funções sobre um número não têm essa pergunta — e o número é o que o
sistema operativo já usa.

O preço, dito: um PID é reutilizável. Depois de `os.alive` devolver False o
número não vale mais nada.
"""

import os

# um programa que dorme: dá tempo de o ver vivo
pid = os.spawn(["sleep", "5"])
print("lançou", pid > 0)
print("vivo", os.alive(pid))
os.kill(pid)
# o SIGTERM é um pedido; esperar por ele é olhar até ele acontecer
n = 0
while os.alive(pid) and n < 50:
    await sleep(0.05)
    n += 1
print("morreu", not os.alive(pid))

# um que acaba sozinho: `alive` COLHE o zumbi, senão cada programa lançado
# deixava um, e um laço que relança de dez em dez segundos enche a tabela
pid2 = os.spawn(["true"])
n2 = 0
while os.alive(pid2) and n2 < 50:
    await sleep(0.05)
    n2 += 1
print("colhido", not os.alive(pid2))

# um pid que não existe não é um estouro
print("pid zero", os.alive(0))
os.kill(0)
print("fim")
