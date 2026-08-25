"""Os ficheiros temporários (S2/148.4) — e o `csprng`, que não recua.

**As três CRIAM ou dizem onde.** Nenhuma devolve um nome que ainda não existe,
que é a corrida clássica do `mktemp`: entre a resposta e o `open` de quem chamou,
qualquer um põe ali um link simbólico apontado ao ficheiro dele. Aqui o `O_EXCL`
já reservou o nome quando a função volta, e o directório nasce com 0700 — porque
o que se escreve num temporário é justamente o que ainda não está pronto para ser
lido.

**Os nomes não são os do Python de propósito.** O `mkstemp` de lá devolve um
descritor E um nome; este devolve só o nome. Dar o mesmo nome a duas coisas
diferentes é como se aprende o errado.

E o `csprng`: **falha em vez de recuar.** A tentação óbvia é ir buscar o Mersenne
Twister que o `random` já tem, e seria a pior coisa que este ficheiro podia
fazer — um gerador previsível a usar a palavra "seguro" é pior do que não haver
gerador nenhum, porque o programa que o usa parece correcto.
"""
import os
import path
import <csprng/csprng.psc> as csprng


async def go() -> int:
    # ---- 1. onde ----
    d = os.tempdir()
    print("existe e e directorio:", path.isdir(d), "sem barra no fim:", not d.endswith("/"))

    # ---- 2. um ficheiro: ja EXISTE quando a funcao volta ----
    f1 = os.tempfile("plang-", ".txt")
    print("ja existe:", path.isfile(f1))
    print("esta na raiz dos temporarios:", path.dirname(f1) == d)
    print("prefixo e sufixo:", path.basename(f1).startswith("plang-"), f1.endswith(".txt"))
    print("nasce vazio:", path.getsize(f1) == 0)

    # ---- 3. e duas chamadas nunca dao o mesmo nome ----
    f2 = os.tempfile("plang-", ".txt")
    print("dois nomes diferentes:", f1 != f2)

    # ... e escreve-se nele como em qualquer outro
    w = await open(f1, "w")
    await w.write("ola")
    await w.close()
    print("escreveu:", path.getsize(f1))

    # ---- 4. sem prefixo nem sufixo tambem serve ----
    f3 = os.tempfile()
    print("sem nada:", path.isfile(f3), path.dirname(f3) == d)

    # ---- 5. um directorio, que e NOSSO ----
    dd = os.tempdir_new("plang-")
    print("directorio:", path.isdir(dd), path.basename(dd).startswith("plang-"))
    dentro = path.join(dd, "a.txt")
    g = await open(dentro, "w")
    await g.write("x")
    await g.close()
    print("da para escrever la dentro:", path.isfile(dentro))

    # ---- 6. o csprng: bytes, e nunca os mesmos ----
    a = await csprng.random_bytes(32)
    b = await csprng.random_bytes(32)
    print("trinta e dois bytes:", len(a), len(b))
    print("e nunca os mesmos:", a != b)
    print("zero e zero:", len(await csprng.random_bytes(0)))
    t = await csprng.token_hex(16)
    print("token:", len(t), t != await csprng.token_hex(16))
    try:
        _ = await csprng.random_bytes(-1)
        print("ISTO NAO DEVIA APARECER")
    catch e:
        print("negativo:", e.message)

    # ---- limpar ----
    os.remove(dentro)
    os.rmdir(dd)
    os.remove(f1)
    os.remove(f2)
    os.remove(f3)
    return 0


await go()
print("tempfile-ok")
