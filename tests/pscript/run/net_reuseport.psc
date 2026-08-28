"""148/D2: **N escutas no MESMO porto, repartidas pelo kernel.**

Um servidor com um só descritor a escutar tem duas saídas más quando se quer usar
mais de um núcleo. Ou há um ACEITADOR único que aceita e distribui o descritor aos
outros — e então esse é o gargalo, e passar descritores é trabalho que não produz
nada. Ou todos esperam no mesmo descritor, e o kernel acorda-os todos para um só
ganhar: o *thundering herd*.

O `SO_REUSEPORT` é a terceira saída: N descritores escutam o mesmo porto, e o
kernel escolhe UM por conexão, por uma dispersão da quádrupla. Cada worker aceita
no seu, sem se saberem uns aos outros.

**Não é o `SO_REUSEADDR`**, que já lá estava sempre e é sobre outra coisa: esse
deixa RELIGAR um porto que ficou em TIME_WAIT — é sobre o passado. Este deixa
dois escutarem ao mesmo tempo — é sobre o presente. As duas primeiras partes do
ficheiro são exactamente essa diferença: com o pedido, dois ligam-se; sem ele, o
segundo recusa.

**O QUE ESTE PORTÃO NÃO AFIRMA**, e vale a pena dizer porquê: qual dos dois recebe
uma dada conexão. Isso é uma dispersão feita pelo kernel, e um teste que exigisse
"um para cada" estaria a prender a hash de outra pessoa — com duas conexões,
mandar as duas ao mesmo descritor é uma resposta correcta, e o teste ficaria
pendurado no `accept` do outro para sempre. Chegou a estar escrito assim e foi
isso que aconteceu. A repartição sob carga é matéria do banco de ensaio da F12.

E o `net.unix` no fim, que existe desde a F7 e nunca teve um portão: o mesmo
`Socket` sobre um CAMINHO em vez de um porto.
"""
import net
import os
import path


async def serve_um(srv: Socket) -> str:
    with await srv.accept() as c:
        with Buffer(256) as rb:
            n = await c.read_into(rb, 0, 256)
            text_s: str = str(bytes(rb[0:n]))
            await c.write("eco:" + text_s)
            return text_s


# ---- 1. dois descritores no mesmo porto, porque foi pedido ----
a = net.listen(0, True)
port_n = a.port()
b = net.listen(port_n, True)
print("dois no mesmo porto:", port_n > 0, b.port() == port_n)

# e o porto partilhado SERVE. O segundo fecha-se antes de alguém bater à porta,
# para que quem aceita seja sabido — ver a nota acima.
b.close()
ta = serve_um(a)
with await net.connect("127.0.0.1", port_n) as c:
    await c.write("bate")
    with Buffer(256) as rb:
        n = await c.read_into(rb, 0, 256)
        print("resposta:", str(bytes(rb[0:n])))
print("o porto partilhado serve:", await ta)
a.close()

# ---- 2. e SEM o pedido, o segundo tem de falhar ----
c1 = net.listen(0)
q = c1.port()
try:
    c2 = net.listen(q)
    print("ERRO: ligou duas vezes sem reuseport")
catch e:
    print("sem reuseport, o segundo recusa:", "bind" in e.message)
c1.close()

# ---- 3. o mesmo Socket sobre um CAMINHO ----
path_s = path.join(os.tempdir(), "psrt-unix-portao.sock")
if path.exists(path_s):
    os.remove(path_s)
srv = net.unix_listen(path_s)
tu = serve_um(srv)
with net.unix(path_s) as cu:
    await cu.write("ola unix")
    with Buffer(256) as rb:
        n = await cu.read_into(rb, 0, 256)
        print("unix:", str(bytes(rb[0:n])))
print("o servidor unix viu:", await tu)
srv.close()
os.remove(path_s)
