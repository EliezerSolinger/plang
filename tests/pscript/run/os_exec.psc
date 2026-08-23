"""`os.exec` — o programa PASSA A SER este processo (F7).

`os.run` cria um filho e espera; `os.exec` não volta. A diferença importa numa
coisa só, e essa coisa é tudo: um filho tem a saída CAPTURADA, então não pinta a
tela, não lê o teclado, não sabe o tamanho do terminal e não recebe Ctrl-C. Um
lançador que só tenha `os.run` consegue correr um programa que imprime, e nada
mais — que era exatamente o limite do `ppack run` até agora.

Depois da troca não há "depois": o processo é outro programa, com o mesmo PID,
os mesmos descritores e o mesmo terminal. Por isso o que estiver por escrever é
esvaziado ANTES — doutra forma morre no buffer.
"""

import os

# o que não existe LEVANTA, com o nome lá dentro: "No such file or directory"
# sem dizer o quê é a mensagem mais inútil do Unix
try:
    os.exec(["/nao/existe/isto"])
    print("nao devia chegar aqui")
catch e:
    print("recusou:", e.message)

print("antes da troca")
os.exec(["printf", "a troca aconteceu\n"])
print("ISTO NAO PODE APARECER")
