"""O servidor do teste de `tests/net-late.sh`: aceita UMA conexão e lê.

O cliente é outro PROCESSO, e é isso que faz o teste morder: ele pausa antes de
escrever, então o dado chega enquanto este laço está dentro do `poll` — que é
exatamente o instante em que o defeito acontecia. Com o cliente na mesma thread
não há como reproduzir: qualquer coisa que ele faça acontece ENTRE dois polls, e
aí o `read` acerta de primeira e nunca estaciona.
"""

import net
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
srv = net.listen(port)
# a porta vai para o STDERR de propósito: o stdout é bufferizado por bloco quando
# é um arquivo, e quem espera a porta precisa dela ANTES de o programa terminar
await sys.err.write(f"port {srv.port()}\n")
with await srv.accept() as c:
    got = await c.read(4096)
    print(f"got {len(got)} {str(got)}")
    rest = await c.read(4096)
    print(f"then {len(rest)}")
srv.close()
