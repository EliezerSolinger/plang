"""O cliente: conecta, PAUSA, escreve. A pausa é o teste."""

import net
import sys

port = int(sys.argv[1])
pause = float(sys.argv[2]) if len(sys.argv) > 2 else 0.4
with await net.connect("127.0.0.1", port) as c:
    await sleep(pause)
    await c.write("data that arrives late")
    await sleep(0.1)
print("sent")
