"""O ficheiro que o `java.nio.file` tem e nós não tínhamos (140/F4).

Três coisas, e cada uma resolve um problema que se sente:

* **`os.stat(p)`** — tudo o que o disco sabe do nome, de UMA vez. Antes disto,
  saber se existe, se é directório, que tamanho tem e quando mudou eram quatro
  travessias ao mesmo inode, e entre a primeira e a última o ficheiro podia
  mudar — o que faz de quatro respostas uma imagem que nunca existiu.

* **`os.pread` / `os.pwrite`** — por POSIÇÃO, sem `seek`. É a diferença que
  torna o acesso concorrente seguro: `seek` seguido de `read` são duas
  operações sobre um cursor partilhado, e dois workers intercalam-se nelas.

* **`f.size()`** (135.10) — o tamanho de um ficheiro já aberto, perguntado ao
  DESCRITOR. O `path.getsize` obriga a guardar o caminho depois de se ter o
  `File`, e a perguntar ao NOME abre uma janela em que o ficheiro pode ser
  trocado por outro entre a resposta e a leitura.
"""
import os
import path


D: str = "posdemo"


async def go() -> int:
    if not path.isdir(D):
        os.makedirs(D)
    alvo = path.join(D, "campo.bin")

    f = await open(alvo, "w")
    await f.write("0123456789abcdefghij")       # 20 bytes
    print("tamanho com o ficheiro ainda aberto:", f.size())
    await f.close()

    # ---- os.stat: uma travessia, oito respostas ----
    st = os.stat(alvo)
    print("stat", st["size"], st["is_file"], st["is_dir"], st["links"] >= 1)
    d = os.stat(D)
    print("do directorio", d["is_dir"], d["is_file"])
    print("mtime coerente:", st["mtime_ns"] // 1000000000 == st["mtime"])

    # ---- pread: ler o MEIO sem tocar em cursor nenhum ----
    r = await open(alvo, "r")
    with Buffer(8) as buf:
        n1 = os.pread(r, buf, 10, 6)
        print("pread(10,6):", str(bytes(buf[0:n1])))
        # ... e outra vez, do princípio: sem cursor, a ordem não importa
        n2 = os.pread(r, buf, 0, 4)
        print("pread(0,4):", str(bytes(buf[0:n2])))
        # ler para lá do fim devolve o que houver
        n3 = os.pread(r, buf, 18, 8)
        print("pread(18,8):", n3, str(bytes(buf[0:n3])))
    await r.close()

    # ---- pwrite: escrever no meio sem reescrever o resto ----
    w = await open(alvo, "r+")
    with Buffer(4) as wb:
        v = wb.view_u8()
        v[0] = u8(ord("X"))
        v[1] = u8(ord("Y"))
        print("pwrite:", os.pwrite(w, wb, 5, 2))
        print("e o tamanho nao mudou:", w.size())
    await w.close()

    q = await open(alvo, "r")
    print("ficou", str(await q.read_all()))
    await q.close()

    # ---- o que a janela recusa ----
    z = await open(alvo, "r")
    with Buffer(4) as zb:
        try:
            os.pread(z, zb, 0, 100)
            print("ISTO NAO DEVIA APARECER")
        catch e:
            print("janela:", e.message)
    await z.close()

    # ---- 140/F4: percorrer o directorio sem materializar a lista ----
    #
    # `listdir` fica como esta: devolve tudo, ordenado, e e o que o oraculo
    # compara com o do Python. O que ele NAO pode ser e preguicoso, porque
    # ordenar exige ter tudo em mao — e num directorio grande e uma lista de
    # milhares de strings para se olhar para a primeira.
    for extra in range(3):
        g = await open(path.join(D, "f" + str(extra) + ".txt"), "w")
        await g.write("x")
        await g.close()
    vistos: List<str> = []
    for nome in os.scandir(D):
        vistos.append(nome)
    print("scandir viu", len(vistos), "iguais ao listdir:", sorted(vistos) == sorted(os.listdir(D)))
    # sair a meio nao deixa o directorio aberto: o finalizador e a rede (136.1)
    conta = 0
    for nome2 in os.scandir(D):
        conta += 1
        if conta == 2:
            break
    print("saiu a meio depois de", conta)

    # 22.2: e `==` numa lista compara CONTEUDO. Estava a comparar PONTEIROS, e
    # foi a linha acima que o desenterrou — `sorted(a) == sorted(b)` respondia
    # False para duas listas iguais.
    x1: List<int> = [1, 2, 3]
    x2: List<int> = [1, 2, 3]
    print("conteudo:", x1 == x2, x1 == [1, 2, 4], x1 != x2)

    return 0


await go()
print("filepos-ok")
