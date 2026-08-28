"""`os.watch` (140/F5): o vigia, e as quatro perguntas que a 146 respondeu.

    with os.watch("src", True) as w:
        while await w.ready():
            while w.pending() > 0:
                caminho, especie, cookie = w.take()

**Aguardável sem maquinaria nova.** O descritor do `inotify` é um STREAM, e por
isso entra no mesmo `poll` que um socket: o vigia não é uma segunda maneira de
esperar, é mais um stream a usar a única que existe.

**146.4 — `ready()` e `pending()` são duas perguntas.** `ready()` espera;
`pending()` diz quantos estão à espera AGORA. Uma construção que toca em
oitocentos ficheiros é um laço sobre `pending`, e não oitocentas esperas — e não
custa oitocentas voltas ao escalonador porque uma tarefa já pronta não estaciona.

**146.3 — coalesce, e a unidade é o par (caminho, espécie) CONSECUTIVO.** Gravar
um ficheiro produz três ou quatro eventos, e entregá-los crus faz com que cada
consumidor escreva o mesmo anti-ressalto. Mas coalescer demais mentiria: um
`CREATED` seguido de um `DELETED` não é nada.

**146.2 — no macOS isto LEVANTA**, e diz que o FSEvents é o caminho. Não se
escreve meio vigia.
"""
import os
import path


D: str = "watchdemo"


async def write_v(p: str, text_s: str):
    f = await open(p, "w")
    await f.write(text_s)
    await f.close()


def kind_name(k: Change) -> str:
    if k == CREATED:
        return "criado"
    if k == MODIFIED:
        return "mudado"
    if k == DELETED:
        return "apagado"
    if k == MOVED_FROM:
        return "saiu"
    if k == MOVED_TO:
        return "entrou"
    return "relê-tudo"


async def go() -> int:
    if path.isdir(D):
        for n in os.listdir(D):
            target_s = path.join(D, n)
            if path.isdir(target_s):
                for n2 in os.listdir(target_s):
                    os.remove(path.join(target_s, n2))
                os.rmdir(target_s)
            else:
                os.remove(target_s)
    else:
        os.makedirs(D)

    with os.watch(D, True) as w:
        # o que JÁ lá estava quando se mandou vigiar não é uma mudança
        print("comeca vazio:", w.pending())

        await write_v(path.join(D, "a.txt"), "um")
        await sleep(0.05)
        seen: List<str> = []
        while w.pending() > 0:
            path_s, kind, cookie = w.take()
            seen.append(path.basename(path_s) + ":" + kind_name(kind))
        print("depois de criar:", len(seen) > 0, seen[0])

        # 146.3: escrever tres vezes seguidas nao da tres MODIFIED seguidos
        for i in range(3):
            f = await open(path.join(D, "a.txt"), "w")
            await f.write("x" * (i + 1))
            await f.close()
        await sleep(0.05)
        mods = 0
        while w.pending() > 0:
            c2, k2, ck2 = w.take()
            if k2 == MODIFIED:
                mods += 1
        print("tres gravacoes deram", mods, "eventos de mudanca (coalescidos)")

        # 146.1: um directorio NOVO ganha o seu vigia, e a varredura fecha a
        # corrida com o que ja la esta
        sub = path.join(D, "novo")
        os.makedirs(sub)
        await write_v(path.join(sub, "dentro.txt"), "ola")
        await sleep(0.1)
        found_inside = False
        while w.pending() > 0:
            c3, k3, ck3 = w.take()
            if path.basename(c3) == "dentro.txt":
                found_inside = True
        print("viu dentro do directorio novo:", found_inside)

        # `ready()` sobre uma fila que ja tem alguma coisa nao espera
        await write_v(path.join(D, "b.txt"), "dois")
        await sleep(0.05)
        print("ready com fila cheia:", await w.ready(), w.pending() > 0)

    return 0


await go()
print("watcher-ok")
