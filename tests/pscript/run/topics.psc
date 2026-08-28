"""148/L4/D6: os TÓPICOS — pub/sub entre contextos, sobre os canos que já havia.

**O que atravessa é o ACORDAR, e não o objecto.** Quem se inscreve num tópico é um
CONTEXTO — um worker, ou o topo do programa —, e publicar é pôr os mesmos bytes na
caixa de cada contexto inscrito e bater-lhe à porta uma vez. Os bytes tornam-se um
`bytes` no heap de QUEM RECEBE, que é a razão de eles terem viajado como bytes: um
objecto coletado não atravessa heaps (18.1), e a tabela de inscrições é `malloc`'d
pela mesma razão que o bloco de controlo de um worker já era — outra thread lê-a, e
um coletor que move não pode mover o que outra thread está a ler.

**O runtime não sabe o que é uma conexão** (D7). Ele acorda o worker; quem sabe
quais conexões daquele worker assinam o tópico é a biblioteca. A alternativa — o
runtime a escrever nos sockets, à uWebSockets — poupa um salto e borra a fronteira
entre protocolo e runtime, e não vale.

**A publicação não volta para quem publicou.** Não é capricho: quem publica tem o
valor na mão, e devolvê-lo por um cano seria uma cópia e um acordar para nada. É
também o que faz a camada de cima encaixar sem dizer nada — a `httpd` entrega às
conexões locais sem serializar, e o runtime trata das dos outros workers.

E não há tipo novo: um `Topic` como objecto seria coletado, e um objecto coletado
não atravessa. O que atravessa é o NOME.
"""
import topic


async def ouvinte(quantas: int) -> int:
    topic.subscribe("mundo")
    # o que o SEGUNDO worker assina e o primeiro não: prova que a entrega é POR
    # TÓPICO, e é por isso que ele espera QUATRO mensagens e o outro três
    if quantas == 4:
        topic.subscribe("so-meu")
    parent.send(-1)                     # "estou inscrito" — o encontro
    total = 0
    for i in range(quantas):
        d = await topic.recv()
        total += len(d)
    parent.send(total)
    return total


a = spawn(ouvinte, (3,))
b = spawn(ouvinte, (4,))

# o ENCONTRO: só se publica depois de os dois estarem inscritos. Sem isto o teste
# seria uma corrida — publicar antes de alguém assinar não chega a ninguém, e
# passaria ou falharia conforme a máquina.
print("prontos:", await a.recv(), await b.recv())

for i in range(3):
    n = topic.publish("mundo", ("tick-" + str(i)).encode())
    print("mundo alcancou", n, "contextos")

# ... e um tópico que só um deles assina
print("so-meu alcancou", topic.publish("so-meu", b"xyz"), "contexto")

# 6 bytes por "tick-N", três vezes = 18; o `b` leva mais 3 do "xyz" = 21
print("a somou:", await a.recv())
print("b somou:", await b.recv())

# um tópico que ninguém assina alcança zero, e não é um erro
print("ninguem assina:", topic.publish("vazio", b"nada"))

# o topo do programa também pode assinar — e publicar para si mesmo alcança
# ZERO, porque quem publica já tem o valor na mão. É a regra dita em números.
topic.subscribe("de-volta")
print("para mim mesmo:", topic.publish("de-volta", b"eco"))
