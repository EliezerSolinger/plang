"""`Mapping` (137): o ficheiro em memória, sem o ler.

**Um tipo próprio e não um `bytes`**, e a pergunta que o decidiu foi *"o mapa do
sistema operativo dá-te recursos e opções; o tipo também podia?"* — `advise`,
`sync`, `lock` não cabem num valor.

**E fecha-se**, o que um `bytes` não faz (136.1). A regra é a de 136.1 inteira:
determinístico para o que é ESCASSO, coleta para o que é MEMÓRIA. Um mapa é
espaço de endereçamento, um inode e um descritor — coisas que se esgotam muito
antes do monte, e que o coletor não tem motivo nenhum para notar. Mil mapas são
mil descritores e um monte minúsculo, e esperar por pressão de memória é o erro
pelo qual o `MappedByteBuffer` do Java é conhecido.

Fatia-se em `bytes` **sem copiar**: o bloco é do núcleo e não se move, que é
exactamente a condição que uma janela pede (135.1).
"""
import os
import path


D: str = "mapdemo"


async def write_v(p: str, text_s: str) -> int:
    f = await open(p, "w")
    n = await f.write(text_s)
    await f.close()
    return n


async def go() -> int:
    if not path.isdir(D):
        os.makedirs(D)
    target_s = path.join(D, "dados.bin")
    content = "ABCDEFGHIJKLMNOPQRSTUVWXYZ" * 8      # 208 bytes
    await write_v(target_s, content)

    # ---- 1. o ficheiro inteiro ----
    with os.mmap(target_s) as m:
        print("tamanho", m.size(), len(m))
        m.advise(os.SEQUENTIAL)
        # fatiar dá `bytes`, e a fatia é uma JANELA sobre a memória do núcleo
        print("primeiros", str(m[0:6]))
        print("ultimos", str(m[len(m) - 4:]))
        # ... e uma janela de uma janela continua a ser a mesma memória
        half = m[26:52]
        print("meio", str(half[0:6]), len(half))
        # comparar por CONTEÚDO, como tudo o resto (22.2)
        print("bate:", m[0:4] == b"ABCD", m[0:4] == b"ABCE")
    # munmap AQUI

    # ---- 2. uma REGIÃO, sem mapear o resto (137.3) ----
    with os.mmap(target_s, "r", 26, 10) as r:
        print("regiao", len(r), str(r[:]))

    # ---- 3. o que a região recusa: cair fora do ficheiro ----
    try:
        with os.mmap(target_s, "r", 200, 100) as bad:
            print("ISTO NAO DEVIA APARECER", len(bad))
    catch e:
        print("fora:", e.message)

    # ---- 4. um mapa fechado recusa tudo o que se lhe peça ----
    z = os.mmap(target_s)
    z.close()
    try:
        print(len(z[0:1]))
    catch e2:
        print("fechado:", e2.message)

    # ---- 5. o ficheiro vazio mapeia-se, e é vazio ----
    empty = path.join(D, "vazio.bin")
    await write_v(empty, "")
    with os.mmap(empty) as v:
        print("vazio", len(v), len(v[:]))

    return 0


await go()
print("mapping-ok")
