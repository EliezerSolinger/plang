"""O MOTOR do pbuild, mecanismo por mecanismo (F2B).

Cada caso aqui existe porque, sem ele, um build mente de um jeito diferente — e
mentir é o único defeito que importa num sistema de build: recompilar demais
custa tempo, mas não recompilar o que mudou custa uma tarde de investigação.

Os grafos são sintéticos e minúsculos de propósito: o que se mede é a DECISÃO
(rodar ou não rodar, em que ordem, e o que dizer quando o grafo mente), não a
compilação de nada.
"""
import os
import path
import sys
import <pbuild/lib_graph.psc> as G
import <pbuild/lib_build.psc> as B
import <pbuild/lib_ninja.psc> as N
import <pbuild/lib_targets.psc> as T
import <pbuild/lib_manifest.psc> as M
import <pbuild/lib_api.psc> as A
import <pbuild/lib_pkg.psc> as PK
import build_plang as BP

const DIR: str = "tests/out/pbuild"

ok_count: int = 0
fail_count: int = 0

def check(what: str, want: str, got: str):
    global ok_count
    global fail_count
    if want == got:
        ok_count += 1
    else:
        fail_count += 1
        print("  FAIL " + what + ": esperava '" + want + "', veio '" + got + "'")

# ---------- um relator que só CONTA ----------
ran: list<str> = []
order: list<str> = []
# quantas arestas estão EM VOO agora, e quantas chegaram a estar: é como se
# observa o `-j` de fora, sem olhar para dentro do motor
em_voo: int = 0
pico: int = 0

def r_plan(total: int):
    pass

# o RÓTULO de cada aresta e o que o evento trouxe dela: é assim que um caso
# confere a SAÍDA de uma aresta específica, e não só o placar
rot: dict<int, str> = {}
saidas: dict<str, str> = {}

def r_start(id: int, what: str):
    global order
    global em_voo
    global pico
    global rot
    rot[id] = what
    order.append(what)
    em_voo += 1
    if em_voo > pico:
        pico = em_voo

def r_end(id: int, st: int, out: str, ms: int):
    global ran
    global em_voo
    global saidas
    em_voo -= 1
    saidas[rot[id] if id in rot else str(id)] = out
    ran.append(str(st))

def r_done(ok: bool, fails: int):
    pass

# o quinto evento: os problemas do GRAFO, guardados para os casos de higiene
# poderem conferir a MENSAGEM e não só a contagem
erros: list<str> = []

def r_erro(msg: str):
    global erros
    erros.append(msg)

def rep() -> B.Rep:
    return B.Rep(r_plan, r_start, r_end, r_done, r_erro)

def reset():
    global ran
    global order
    global erros
    novo: list<str> = []
    novo2: list<str> = []
    novo3: list<str> = []
    global em_voo
    global pico
    global rot
    global saidas
    novo4: dict<int, str> = {}
    novo5: dict<str, str> = {}
    ran = novo
    order = novo2
    erros = novo3
    rot = novo4
    saidas = novo5
    em_voo = 0
    pico = 0

private def opts(jobs: int) -> B.Opts:
    return B.Opts(jobs, 1, False, False)

private async def write_file(p: str, txt: str):
    f = await open(p, "w")
    await f.write(txt)
    await f.close()

private async def write_newer(p: str, txt: str, que: str):
    """Escreve `p` e garante que ele fique com mtime MAIOR que `que`.

    Sem isto o teste é sensível ao sistema de arquivos: o motor compara mtime com
    "menor que" (é o que o ninja faz), então dois arquivos escritos no mesmo
    instante não se distinguem. No ext4 os mtimes são de nanossegundo e a
    primeira escrita já basta; num sistema de granularidade grosseira — o HFS+ do
    macOS tem UM SEGUNDO — a espera é real, e é ela que faz o teste medir o que
    diz medir em vez de passar por sorte.
    """
    n = 0
    while n < 400:
        await write_file(p, txt)
        if path.getmtime_ns(p) > path.getmtime_ns(que):
            return
        n += 1
    # depois de 400 tentativas o problema não é granularidade: deixa passar e o
    # caso falha dizendo o que falhou, que é melhor que travar aqui

private def touch_cmd(p: str, txt: str) -> list<str>:
    return ["/bin/sh", "-c", "printf '%s' " + txt + " > " + p]

# ---------- os casos ----------
async def caso_incremental():
    """Constrói uma vez, não constrói a segunda, e volta a construir quando a
    entrada muda. É o build inteiro em três linhas."""
    reset()
    await write_file(DIR + "/a.in", "1")
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/a.in > " + DIR + "/a.out"])
    e.ins.append(g.node(DIR + "/a.in").id)
    e.outs.append(g.node(DIR + "/a.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/a.out")
    lg = DIR + "/log1"
    await B.build(g, lg, [], opts(1), rep())
    check("incremental: primeira corrida roda", "1", str(len(ran)))
    reset()
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/a.in > " + DIR + "/a.out"])
    e2.ins.append(g2.node(DIR + "/a.in").id)
    e2.outs.append(g2.node(DIR + "/a.out").id)
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/a.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("incremental: segunda corrida NAO roda", "0", str(len(ran)))
    reset()
    await write_newer(DIR + "/a.in", "2", DIR + "/a.out")
    g3 = G.new_graph()
    e3 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/a.in > " + DIR + "/a.out"])
    e3.ins.append(g3.node(DIR + "/a.in").id)
    e3.outs.append(g3.node(DIR + "/a.out").id)
    g3.add_edge(e3)
    g3.default_targets.append(DIR + "/a.out")
    await B.build(g3, lg, [], opts(1), rep())
    check("incremental: entrada mudou, roda", "1", str(len(ran)))

async def caso_comando_mudou():
    """O ninja pega isto e nenhuma comparação de datas pegaria: a entrada é a
    mesma, a saída é a mesma, e o COMANDO mudou."""
    reset()
    await write_file(DIR + "/b.in", "x")
    lg = DIR + "/log2"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo um > " + DIR + "/b.out"])
    e.ins.append(g.node(DIR + "/b.in").id)
    e.outs.append(g.node(DIR + "/b.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/b.out")
    await B.build(g, lg, [], opts(1), rep())
    reset()
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "echo DOIS > " + DIR + "/b.out"])
    e2.ins.append(g2.node(DIR + "/b.in").id)
    e2.outs.append(g2.node(DIR + "/b.out").id)
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/b.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("o comando mudou: roda", "1", str(len(ran)))

async def caso_ambiente_mudou():
    """A extensão sobre o ninja: o hash cobre o AMBIENTE efetivo. Trocar
    `CC=clang` por `CC=gcc` sem isto reaproveita artefato em silêncio."""
    reset()
    lg = DIR + "/log3"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo $Q > " + DIR + "/c.out"])
    e.env["Q"] = "um"
    e.outs.append(g.node(DIR + "/c.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/c.out")
    await B.build(g, lg, [], opts(1), rep())
    reset()
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "echo $Q > " + DIR + "/c.out"])
    e2.env["Q"] = "dois"
    e2.outs.append(g2.node(DIR + "/c.out").id)
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/c.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("o ambiente mudou: roda", "1", str(len(ran)))

async def caso_restat():
    """`restat`: a aresta rodou, a saída saiu IDÊNTICA, e quem depende dela NÃO
    roda. É o que transforma "regenerei C igual" em "não recompilei os 18 s"."""
    reset()
    lg = DIR + "/log4"
    await write_file(DIR + "/d.in", "1")
    g = G.new_graph()
    gen = G.new_edge(["/bin/sh", "-c", "echo constante > " + DIR + "/d.mid"])
    gen.ins.append(g.node(DIR + "/d.in").id)
    gen.outs.append(g.node(DIR + "/d.mid").id)
    gen.restat = True
    gen.desc = "gera d.mid"
    g.add_edge(gen)
    use = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/d.mid > " + DIR + "/d.out"])
    use.ins.append(g.node(DIR + "/d.mid").id)
    use.outs.append(g.node(DIR + "/d.out").id)
    use.desc = "usa d.mid"
    g.add_edge(use)
    g.default_targets.append(DIR + "/d.out")
    await B.build(g, lg, [], opts(1), rep())
    check("restat: a primeira vez roda as duas", "2", str(len(ran)))
    # a entrada muda; o gerador roda de novo e produz o MESMO conteúdo
    reset()
    await write_newer(DIR + "/d.in", "2", DIR + "/d.mid")
    g2 = G.new_graph()
    gen2 = G.new_edge(["/bin/sh", "-c", "echo constante > " + DIR + "/d.mid"])
    gen2.ins.append(g2.node(DIR + "/d.in").id)
    gen2.outs.append(g2.node(DIR + "/d.mid").id)
    gen2.restat = True
    gen2.desc = "gera d.mid"
    g2.add_edge(gen2)
    use2 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/d.mid > " + DIR + "/d.out"])
    use2.ins.append(g2.node(DIR + "/d.mid").id)
    use2.outs.append(g2.node(DIR + "/d.out").id)
    use2.desc = "usa d.mid"
    g2.add_edge(use2)
    g2.default_targets.append(DIR + "/d.out")
    await B.build(g2, lg, [], opts(1), rep())
    # o gerador roda (a entrada mudou) e produz bytes IDÊNTICOS; o consumidor é
    # podado. Com o `restat` por mtime do ninja isto não aconteceria — o `echo`
    # reescreve o arquivo e o mtime muda —, e é por isso que aqui ele compara
    # conteúdo.
    check("restat: so o gerador roda de novo", "1", str(len(ran)))

    # E A CORRIDA SEGUINTE NÃO RODA NADA. Este é o teste que separa "não
    # recompilei desta vez" de "não recompilo mais": o gerador reescreveu
    # `d.mid` (data nova no disco, mesmo conteúdo), e a entrada dele ficou mais
    # nova que a data que o log tinha guardado. Sem os dois consertos — a data
    # da ENTRADA MAIS NOVA no log, e a data do LOG valendo para uma saída cujo
    # conteúdo não mudou — o gerador rodava em toda corrida, para sempre, e o
    # `ppack verify` refazia 296 arestas por nada. Foi assim que apareceu.
    reset()
    g3 = G.new_graph()
    gen3 = G.new_edge(["/bin/sh", "-c", "echo constante > " + DIR + "/d.mid"])
    gen3.ins.append(g3.node(DIR + "/d.in").id)
    gen3.outs.append(g3.node(DIR + "/d.mid").id)
    gen3.restat = True
    gen3.desc = "gera d.mid"
    g3.add_edge(gen3)
    use3 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/d.mid > " + DIR + "/d.out"])
    use3.ins.append(g3.node(DIR + "/d.mid").id)
    use3.outs.append(g3.node(DIR + "/d.out").id)
    use3.desc = "usa d.mid"
    g3.add_edge(use3)
    g3.default_targets.append(DIR + "/d.out")
    await B.build(g3, lg, [], opts(1), rep())
    check("restat: a corrida seguinte nao roda nada", "0", str(len(ran)))

async def caso_paralelo_e_ordem():
    """Oito arestas independentes com quatro braços, e a mais CARA primeiro. O
    peso vem da duração da última vez (o ninja grava e não usa)."""
    reset()
    lg = DIR + "/log5"
    g = G.new_graph()
    i = 0
    while i < 8:
        e = G.new_edge(["/bin/sh", "-c", "echo " + str(i) + " > " + DIR + "/p" + str(i) + ".out"])
        e.outs.append(g.node(DIR + "/p" + str(i) + ".out").id)
        e.desc = "p" + str(i)
        e.dur_ms = (i + 1) * 10    # a de índice 7 é a mais cara; zero quer dizer
                                   # "nunca rodou", e aí o motor chuta um segundo
        g.add_edge(e)
        g.default_targets.append(DIR + "/p" + str(i) + ".out")
        i += 1
    await B.build(g, lg, [], opts(4), rep())
    check("paralelo: oito rodaram", "8", str(len(ran)))
    check("ordem: a mais cara comecou primeiro", "p7", order[0])

async def caso_pool_console():
    """`pool = console`: a aresta que fala com o TERMINAL, e sozinha.

    Ela é a única do grafo que não tem a saída capturada — o filho herda os
    descritores deste processo. É por isso que ela tem de correr sozinha: a
    captura existe no resto do build para impedir que dois trabalhos costurem as
    linhas um do outro, e sem captura a única forma de manter essa propriedade é
    não haver dois ao mesmo tempo.

    As duas coisas ficam presas aqui, e as duas são observáveis de fora:

      * com quatro braços e três arestas de console prontas, o PICO em voo é 1;
      * a aresta comum traz o que imprimiu no evento (foi capturada) e a de
        console traz a saída VAZIA — o que ela imprimiu foi para o terminal, e
        aparece no meio deste relatório, que é a prova que se pode ler."""
    reset()
    lg = DIR + "/log_console"
    g = G.new_graph()
    i = 0
    while i < 3:
        c = G.new_edge(["/bin/sh", "-c", "echo '-- console " + str(i)
                        + " (esta linha foi para o terminal) --'; printf x > "
                        + DIR + "/con" + str(i) + ".out"])
        c.outs.append(g.node(DIR + "/con" + str(i) + ".out").id)
        c.desc = "console" + str(i)
        c.pool = "console"
        g.add_edge(c)
        g.default_targets.append(DIR + "/con" + str(i) + ".out")
        i += 1
    await B.build(g, lg, [], opts(4), rep())
    check("console: as tres rodaram", "3", str(len(ran)))
    check("console: nunca duas ao mesmo tempo", "1", str(pico))
    check("console: o evento nao traz saida nenhuma", "", saidas["console0"])

    # e agora com companhia: a comum é capturada, a de console não
    reset()
    g2 = G.new_graph()
    cm = G.new_edge(["/bin/sh", "-c", "echo capturado; printf y > " + DIR + "/cap.out"])
    cm.outs.append(g2.node(DIR + "/cap.out").id)
    cm.desc = "comum"
    g2.add_edge(cm)
    g2.default_targets.append(DIR + "/cap.out")
    cn = G.new_edge(["/bin/sh", "-c", "printf z > " + DIR + "/con9.out"])
    cn.outs.append(g2.node(DIR + "/con9.out").id)
    cn.desc = "console9"
    cn.pool = "console"
    g2.add_edge(cn)
    g2.default_targets.append(DIR + "/con9.out")
    await B.build(g2, DIR + "/log_console2", [], opts(4), rep())
    check("console: a comum foi capturada", "capturado", saidas["comum"].strip())
    check("console: a de console nao", "", saidas["console9"])

async def caso_falha_para():
    """Uma falha para o build (o padrão do ninja e do samurai): a primeira
    mensagem é quase sempre a causa, e as seguintes são consequência."""
    reset()
    lg = DIR + "/log6"
    g = G.new_graph()
    bad = G.new_edge(["/bin/sh", "-c", "exit 3"])
    bad.outs.append(g.node(DIR + "/never.out").id)
    bad.desc = "a que falha"
    g.add_edge(bad)
    dep = G.new_edge(["/bin/sh", "-c", "echo tarde > " + DIR + "/after.out"])
    dep.ins.append(g.node(DIR + "/never.out").id)
    dep.outs.append(g.node(DIR + "/after.out").id)
    dep.desc = "a que depende"
    g.add_edge(dep)
    g.default_targets.append(DIR + "/after.out")
    okv = await B.build(g, lg, [], opts(2), rep())
    check("falha: o build falha", "False", str(okv))
    check("falha: a que depende NAO rodou", "1", str(len(ran)))

async def caso_saida_nao_produzida():
    """A aresta prometeu um arquivo e não o criou. É ERRO e não aviso: uma saída
    que não existe envenena todo build seguinte."""
    reset()
    lg = DIR + "/log7"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "true"])
    e.outs.append(g.node(DIR + "/promised.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/promised.out")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("saida nao produzida: falha", "False", str(okv))

async def caso_entrada_orfa():
    """Uma entrada que não existe e que ninguém produz: o grafo mente sobre o
    que sabe, e dizer isso ANTES de rodar qualquer coisa é o ponto."""
    reset()
    lg = DIR + "/log8"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "true"])
    e.ins.append(g.node(DIR + "/nao_existe.in").id)
    e.outs.append(g.node(DIR + "/x.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/x.out")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("entrada orfa: falha antes de rodar", "False", str(okv))
    check("entrada orfa: nada rodou", "0", str(len(ran)))

async def caso_ciclo():
    """Um ciclo é o único jeito de o motor girar para sempre."""
    reset()
    lg = DIR + "/log9"
    g = G.new_graph()
    e1 = G.new_edge(["/bin/sh", "-c", "true"])
    e1.ins.append(g.node(DIR + "/ciclo_a").id)
    e1.outs.append(g.node(DIR + "/ciclo_b").id)
    g.add_edge(e1)
    e2 = G.new_edge(["/bin/sh", "-c", "true"])
    e2.ins.append(g.node(DIR + "/ciclo_b").id)
    e2.outs.append(g.node(DIR + "/ciclo_a").id)
    g.add_edge(e2)
    g.default_targets.append(DIR + "/ciclo_b")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("ciclo: detectado", "False", str(okv))

async def caso_dry_run():
    """`--dry-run`: diz o que faria e não faz."""
    reset()
    lg = DIR + "/log10"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo nao devia existir > " + DIR + "/dry.out"])
    e.outs.append(g.node(DIR + "/dry.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/dry.out")
    await B.build(g, lg, [], B.Opts(1, 1, True, False), rep())
    check("dry-run: relatou", "1", str(len(ran)))
    check("dry-run: nao criou nada", "False", str(path.exists(DIR + "/dry.out")))

async def caso_depfile():
    """O `cc -MD` deixa um `.d` dizendo o que ele LEU. Sem ler esse arquivo, um
    header editado não recompila nada — o modo de falhar mais clássico que existe
    num build de C."""
    reset()
    lg = DIR + "/log11"
    await write_file(DIR + "/dep.in", "1")
    await write_file(DIR + "/dep.h", "a")
    await write_file(DIR + "/dep.d", DIR + "/dep.out: " + DIR + "/dep.in " + DIR + "/dep.h\n")
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/dep.in > " + DIR + "/dep.out"])
    e.ins.append(g.node(DIR + "/dep.in").id)
    e.outs.append(g.node(DIR + "/dep.out").id)
    e.depfile = DIR + "/dep.d"
    g.add_edge(e)
    g.default_targets.append(DIR + "/dep.out")
    await B.build(g, lg, [], opts(1), rep())
    check("depfile: a primeira vez roda", "1", str(len(ran)))
    # mexer no HEADER, que não está nas entradas declaradas, tem de recompilar
    reset()
    await write_newer(DIR + "/dep.h", "b", DIR + "/dep.out")
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/dep.in > " + DIR + "/dep.out"])
    e2.ins.append(g2.node(DIR + "/dep.in").id)
    e2.outs.append(g2.node(DIR + "/dep.out").id)
    e2.depfile = DIR + "/dep.d"
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/dep.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("depfile: o header mudou, roda", "1", str(len(ran)))

async def caso_dois_produtores():
    """Duas arestas produzindo o mesmo arquivo: qual delas define o conteúdo
    depende da ordem em que rodarem, e o incremental passa a depender de sorte."""
    reset()
    lg = DIR + "/log12"
    g = G.new_graph()
    a = G.new_edge(["/bin/sh", "-c", "echo a > " + DIR + "/dois.out"])
    a.outs.append(g.node(DIR + "/dois.out").id)
    g.add_edge(a)
    b2 = G.new_edge(["/bin/sh", "-c", "echo b > " + DIR + "/dois.out"])
    b2.outs.append(g.node(DIR + "/dois.out").id)
    g.add_edge(b2)
    g.default_targets.append(DIR + "/dois.out")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("dois produtores: recusado", "False", str(okv))
    check("dois produtores: nada rodou", "0", str(len(ran)))

async def caso_keep_going():
    """`-k N`: continuar depois de uma falha, para ver TODAS. O padrão é parar na
    primeira (a primeira mensagem é quase sempre a causa), e isto é o oposto
    disso, para quando se quer o placar completo."""
    reset()
    lg = DIR + "/log13"
    g = G.new_graph()
    i = 0
    while i < 3:
        e = G.new_edge(["/bin/sh", "-c", "exit " + str(i + 1)])
        e.outs.append(g.node(DIR + "/k" + str(i) + ".out").id)
        e.desc = "k" + str(i)
        g.add_edge(e)
        g.default_targets.append(DIR + "/k" + str(i) + ".out")
        i += 1
    okv = await B.build(g, lg, [], B.Opts(1, 9, False, False), rep())
    check("keep-going: falhou", "False", str(okv))
    check("keep-going: as tres rodaram", "3", str(len(ran)))

async def caso_explain():
    """A consulta que diz POR QUE algo está sujo."""
    reset()
    lg = DIR + "/log14"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo x > " + DIR + "/ex.out"])
    e.outs.append(g.node(DIR + "/ex.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/ex.out")
    w = await B.why_dirty(g, lg, [])
    check("explain: diz que nao existe", "não existe", w[DIR + "/ex.out"])

async def caso_grafo_reusado():
    """O MESMO grafo em memória, construído duas vezes — que é o que a IDE faz:
    constrói, o programador edita, constrói de novo. O estado do plano vive na
    aresta, e se ele não for zerado a segunda vez enxerga o plano da primeira e
    conclui que não há nada a fazer. Silenciosamente."""
    reset()
    lg = DIR + "/log15"
    await write_file(DIR + "/re.in", "1")
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/re.in > " + DIR + "/re.out"])
    e.ins.append(g.node(DIR + "/re.in").id)
    e.outs.append(g.node(DIR + "/re.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/re.out")
    await B.build(g, lg, [], opts(1), rep())
    check("reuso: a primeira vez roda", "1", str(len(ran)))
    reset()
    await B.build(g, lg, [], opts(1), rep())
    check("reuso: nada mudou, nao roda", "0", str(len(ran)))
    reset()
    await write_newer(DIR + "/re.in", "2", DIR + "/re.out")
    await B.build(g, lg, [], opts(1), rep())
    check("reuso: a entrada mudou, roda", "1", str(len(ran)))

async def caso_json():
    """O grafo vai e volta por JSON sem perder nada — a exportação da 1.3."""
    g = G.new_graph()
    e = G.new_edge(["cc", "-c", "a.c", "-o", "a.o"])
    e.ins.append(g.node("a.c").id)
    e.implicit.append(g.node("a.h").id)
    e.order.append(g.node("build").id)
    e.outs.append(g.node("a.o").id)
    e.env["CC"] = "cc"
    e.restat = True
    e.desc = "compilando a.c"
    g.add_edge(e)
    j = G.to_json(g)
    g2 = G.from_json(j)
    check("json: mesmas arestas", "1", str(len(g2.edges)))
    check("json: mesmo hash", str(e.hash), str(g2.edges[0].compute_hash()))
    check("json: as tres faixas", "1 1 1", str(len(g2.edges[0].ins)) + " " + str(len(g2.edges[0].implicit)) + " " + str(len(g2.edges[0].order)))
    check("json: restat sobreviveu", "True", str(g2.edges[0].restat))

async def caso_ninja():
    """A exportação para ninja (F3): o ASPEAMENTO, que é onde todo sistema de
    build que monta linha de comando por concatenação se quebra.

    O caso é montado de propósito com tudo o que morde: um caminho com espaço,
    um argumento com `$` (que o ninja come e o shell expandiria), um com aspa
    simples (a única fuga que o aspeamento por aspas simples tem), ambiente,
    diretório e redirecionamento. E não basta o texto parecer certo: o comando
    exportado é RODADO por um shell, e o que ele escreve no disco tem de ser o
    que a aresta prometia."""
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "printf '%s' \"$UM\" > \"$1\"", "sh", DIR + "/com espaco.txt"])
    e.env["UM"] = "valor com 'aspa'"
    e.ins.append(g.node(DIR + "/n.in").id)
    e.implicit.append(g.node(DIR + "/n.h").id)
    e.order.append(g.node(DIR).id)
    e.outs.append(g.node(DIR + "/com espaco.txt").id)
    e.out_implicit.append(g.node(DIR + "/n.extra").id)
    e.depfile = DIR + "/n.d"
    e.restat = True
    e.generator = True
    e.pool = "console"
    e.desc = "gerando com $ no meio"
    g.add_edge(e)
    g.default_targets.append(DIR + "/com espaco.txt")
    txt = N.emit(g)

    # o que o ninja LÊ: espaço e `$` escapados no caminho, as três faixas nos
    # três separadores, e as quatro chaves da regra
    check("ninja: espaco no caminho vira '$ '", "True", str(txt.find("com$ espaco.txt") >= 0))
    check("ninja: as tres faixas", "True", str(txt.find(": e0 ") >= 0 and txt.find(" | ") >= 0 and txt.find(" || ") >= 0))
    check("ninja: restat", "True", str(txt.find("\n  restat = 1\n") >= 0))
    check("ninja: generator", "True", str(txt.find("\n  generator = 1\n") >= 0))
    check("ninja: pool", "True", str(txt.find("\n  pool = console\n") >= 0))
    check("ninja: depfile e deps", "True", str(txt.find("\n  depfile = ") >= 0 and txt.find("\n  deps = gcc\n") >= 0))
    check("ninja: default", "True", str(txt.find("\ndefault ") >= 0))
    check("ninja: env -i (substitui, nao mescla)", "True", str(txt.find("env -i") >= 0))
    # todo `$` do comando vem em PAR: um `$` solto é uma variável do ninja, e o
    # `$UM` do nosso argumento viraria vazio antes de o shell o ver
    linha_cmd = ""
    for l in txt.split("\n"):
        if l.startswith("  command = "):
            linha_cmd = l
    pares = True
    ci = 0
    while ci < len(linha_cmd):
        if linha_cmd[ci] == "$":
            if ci + 1 >= len(linha_cmd) or linha_cmd[ci + 1] != "$":
                pares = False
                break
            ci += 1
        ci += 1
    check("ninja: todo $ do comando vem em par", "True", str(pares))
    check("ninja: e o nosso $UM sobreviveu escapado", "True", str(linha_cmd.find("$$UM") >= 0))

    # ... e o que o SHELL lê: o comando exportado, rodado de verdade
    cmd = N.cmdline(e).replace("$$", "$")
    r = await os.run(["/bin/sh", "-c", cmd])
    check("ninja: o comando exportado roda", "0", str(r.status()))
    f = await open(DIR + "/com espaco.txt", "r")
    conteudo = await f.text()
    await f.close()
    check("ninja: e escreveu o que a aresta prometia", "valor com 'aspa'", conteudo)
    os.remove(DIR + "/com espaco.txt")

    # duas exportações do mesmo grafo dão o MESMO arquivo: um `build.ninja`
    # comitado que muda de ordem a cada corrida é um diff por nada
    check("ninja: determinista", "True", str(N.emit(g) == txt))

async def caso_pacotes():
    """O grafo de PACOTES: a árvore e o "quem puxou" (F4).

    São as duas perguntas que todo lock grande acaba por provocar, e a fixture
    tem exactamente a forma que as torna interessantes: `txt` depende de `geo`,
    e `cor` de ninguém."""
    reset()
    membros: list<str> = ["tests/pkg/geo", "tests/pkg/txt", "tests/pkg/cor"]
    m = await PK.ler_mundo(membros)
    check("pacotes: os três", "3", str(len(m.pacotes)))
    check("pacotes: nada falta", "0", str(len(m.faltando)))
    check("pacotes: quem puxa o geo", "txt", " ".join(m.quem_puxa("geo")))
    check("pacotes: ninguém puxa o txt", "", " ".join(m.quem_puxa("txt")))

    # a ÁRVORE: as raízes primeiro, e o que elas puxam por baixo
    t = PK.arvore(m)
    check("árvore: o txt é raiz", "True", str(t.find("txt 0.2.0") >= 0))
    check("árvore: e o geo pendura nele", "True", str(t.find("└─ geo 0.1.0") >= 0))
    check("árvore: o cor também é raiz", "True", str(t.find("cor 0.1.0") >= 0))

    # uma dependência que ninguém oferece é dita UMA vez, com o nome de quem
    # pediu — e não em silêncio, que é como um build começa a mentir
    m2 = await PK.ler_mundo(["tests/pkg/txt"])
    check("pacotes: o que falta é dito", "1", str(len(m2.faltando)))
    check("pacotes: e diz quem pediu", "True", str(m2.faltando[0].find("geo") >= 0 and m2.faltando[0].find("txt") >= 0))

async def caso_pacote_com_c():
    """2.13: um pacote que traz C ESCRITO À MÃO, construído de ponta a ponta.

    A fixture `tests/pkg/crc` é o caso inteiro numa página: um `.p` que só
    declara, um `.c` que faz a conta, um header que só se acha por um `-I`
    relativo ao pacote, e um `-D` sem o qual o C se recusa a compilar (`#error`).
    Se o programa correr e der o CRC certo, então as quatro coisas aconteceram —
    o C foi achado, as flags do manifesto chegaram nele, o `-I` foi reescrito
    contra o diretório do pacote, e o objeto entrou no link.

    E o pacote que NINGUÉM importa não entra: é o que faz `deps` no manifesto
    não custar tamanho de binário."""
    reset()
    dir = DIR + "/pkgc"
    if not path.isdir(dir):
        os.makedirs(dir)
    prog = dir + "/usa_crc.p"
    f = await open(prog, "w")
    await f.write("include <stdio.h>\nimport <crc/crc.ph>\n\n"
                  + "def main() -> int:\n"
                  + "    printf(\"%u\\n\", crc32_de(\"123456789\"))\n"
                  + "    return 0\n")
    await f.close()
    g = G.new_graph()
    c = T.new_ctx(g, dir + "/o", BP.PLANGC_S2)
    c.pkgroots = ["tests/pkg"]
    await T.carregar_pacotes(c)
    bin = await T.p_program(c, prog, dir + "/usa_crc", dir + "/obj", [], [])
    g.default_targets.append(bin)
    okb = await B.build(g, dir + "/log", [], opts(4), rep())
    check("pacote com C: constrói", "True", str(okb))
    if not okb:
        for e in erros:
            print("      " + e)
        for k in saidas:
            if len(saidas[k]) > 0:
                print("      " + k + ": " + saidas[k].strip())
        return
    r = await os.run([path.join(os.getcwd(), bin)])
    # o CRC-32 de "123456789" é 0xCBF43926 — o vetor de conferência que todo
    # texto sobre CRC cita, e que um erro de polinómio ou de ordem de bits erra
    check("pacote com C: e a conta é a certa", "3421780262", r.output().strip())

async def caso_api():
    """A resposta 5 lida de volta (`lib_api.psc`): é o que faz o `ppack doc`
    existir sem um segundo leitor da linguagem — e um segundo leitor divergiria,
    que é o pior resultado possível."""
    reset()
    dump = ("== geom.ph\n"
            + "include <stdio.h>\n"
            + "struct Ponto {x: i32, y: i32}\n"
            + "def area(i32, i32) -> i64\n"
            + "const MAX: i32 = 64\n"
            + "#hash 0123456789abcdef\n"
            + "#doc . O módulo.\\nCom segunda linha.\n"
            + "#doc area A área.\n"
            + "#doc Ponto.soma A soma.\n"
            + "== outro.p\n"
            + "def f() -> void\n"
            + "#hash fedcba9876543210\n")
    ms = A.parse(dump)
    check("api: dois módulos", "2", str(len(ms)))
    check("api: o caminho e o hash", "geom.ph 0123456789abcdef", ms[0].caminho + " " + ms[0].hash)
    check("api: a doc do módulo, desescapada", "O módulo.\nCom segunda linha.", ms[0].doc)
    check("api: acha um símbolo", "True", str(ms[0].acha("area") >= 0))
    check("api: e a doc dele", "A área.", ms[0].simbolos[ms[0].acha("area")].doc)
    check("api: o método entra mesmo sem linha própria", "A soma.",
          ms[0].simbolos[ms[0].acha("Ponto.soma")].doc)
    check("api: o segundo módulo", "outro.p", ms[1].caminho)

    # o NOME de cada forma de declaração
    check("api: nome de def", "area", A.nome_da("def area(i32, i32) -> i64"))
    check("api: nome de struct", "Ponto", A.nome_da("struct Ponto {x: i32}"))
    check("api: nome de enum", "Forma", A.nome_da("enum Forma {A, B}"))
    check("api: nome de const", "MAX", A.nome_da("const MAX: i32 = 64"))
    check("api: import não é símbolo", "", A.nome_da("import \"x.ph\""))

    # a indentação do CÓDIGO sai da docstring (o `cleandoc` do Python)
    check("api: cleandoc", "Primeira.\n\nSegunda.",
          A.limpa("Primeira.\n\n    Segunda.\n    "))

async def caso_manifesto():
    """O `pack.json`: pacote, workspace, e o erro COM POSIÇÃO (F4).

    O manifesto é dado e nunca programa — é o arquivo que o painel da IDE edita
    —, e por isso o erro dele tem de ser clicável pelo mesmo caminho que um erro
    de compilação: `arquivo:linha:coluna: error: ...`. Sem isso, configurar um
    pacote pela IDE seria adivinhar."""
    reset()
    g1 = await M.ler("tests/pkg/geo/pack.json")
    check("manifesto: nome e versão", "geo 0.1.0", g1.nome + " " + g1.versao)
    check("manifesto: lang e raiz", "p geo.ph", g1.lang + " " + g1.raiz)
    check("manifesto: sem dependência", "0", str(len(g1.deps)))

    t1 = await M.ler("tests/pkg/txt/pack.json")
    check("manifesto: a dependência veio", "geo >= 0.1.0",
          t1.deps[0].nome + " " + t1.deps[0].faixa)

    w = await M.ler("tests/pkg/pack.json")
    check("manifesto: workspace se conhece", "True", str(w.eh_workspace))
    check("manifesto: os membros", "geo txt cor crc", " ".join(w.membros))

    # a RAIZ de busca sai do workspace: é o diretório que CONTÉM os membros,
    # porque é assim que `import <geo/geo.ph>` resolve
    rs = await BP.raizes_do_workspace("tests/pkg/pack.json")
    check("workspace: uma raiz, a que contém os membros", "tests/pkg", " ".join(rs))

    # e o do REPOSITÓRIO: `packages` é a raiz, porque é lá que o `stl` mora
    rp = await BP.raizes_do_workspace("pack.json")
    check("workspace: a raiz deste repositório", "packages", " ".join(rp))

    # um pacote sem `root` é legítimo: o `stl` são dez headers independentes e
    # nenhum deles é "a interface"
    st = await M.ler("packages/stl/pack.json")
    check("manifesto: pacote sem raiz", "stl 0.1.0 p ", st.nome + " " + st.versao + " " + st.lang + " " + st.raiz)

    # e o erro tem linha e coluna
    nonlocal msg
    msg = ""
    try:
        await M.ler("tests/pkg/ruim/pack.json")
        msg = "não levantou"
    catch e:
        msg = e.message
    check("manifesto: o erro tem posição", "True",
          str(msg.find("tests/pkg/ruim/pack.json:2:3: error:") == 0))
    check("manifesto: e diz o que estava errado", "True", str(msg.find("minúsculas") > 0))

async def caso_limite_de_bracos():
    """O `-j N` limita MESMO: nunca há mais de N arestas em voo.

    O contador de braços era incrementado quando o braço COMEÇAVA a rodar, e
    criar uma tarefa não a põe a correr — então o laço que multiplica braços via
    sempre `alive == 1` e criava um braço por aresta pronta. Num build limpo
    isso são centenas de processos ao mesmo tempo, mais canos do que o `poll` do
    runtime acompanha, e o build terminava em deadlock. O `-j` não limitava
    nada, e ninguém percebia porque o build TERMINAVA — só que rápido demais e,
    de vez em quando, nunca.

    Aqui se observa de fora: o relator conta quem começou e quem terminou."""
    reset()
    g = G.new_graph()
    for i in range(10):
        e = G.new_edge(["/bin/sh", "-c", "sleep 0.05; echo " + str(i) + " > " + DIR + "/j" + str(i) + ".out"])
        e.outs.append(g.node(DIR + "/j" + str(i) + ".out").id)
        e.desc = "j" + str(i)
        g.add_edge(e)
        g.default_targets.append(DIR + "/j" + str(i) + ".out")
    ok = await B.build(g, DIR + "/log12", [], opts(3), rep())
    check("limite: as dez rodaram", "10 True", str(len(ran)) + " " + str(ok))
    check("limite: nunca mais de 3 em voo", "True", str(pico <= 3))
    check("limite: e chegou a usar o limite", "True", str(pico >= 2))

async def caso_portao_negativo():
    """Um portão pela NEGATIVA: passa quando o padrão NÃO aparece (F3).

    É o formato do gate que guarda a regressão do typedef de libc, e ele é o
    único lugar do descritor onde há um shell — porque o que se quer é o INVERSO
    do status de um comando, e inverter status é o que o `!` faz. O que se prende
    aqui é que ele inverte MESMO: verde quando não acha, vermelho quando acha."""
    reset()
    await write_file(DIR + "/limpo.h", "typedef struct Fila Fila;\n")
    await write_file(DIR + "/sujo.h", "typedef struct _IO_FILE FILE;\n")

    g = G.new_graph()
    T.nao_acha(T.new_ctx(g, DIR, "plangc"), "_IO_FILE", [DIR + "/limpo.h"],
               DIR + "/limpo.ok", "sem tag no arquivo limpo")
    g.default_targets.append(DIR + "/limpo.ok")
    ok1 = await B.build(g, DIR + "/log9", [], opts(1), rep())
    check("portão negativo: verde quando não acha", "True", str(ok1))

    g2 = G.new_graph()
    T.nao_acha(T.new_ctx(g2, DIR, "plangc"), "_IO_FILE", [DIR + "/sujo.h"],
               DIR + "/sujo.ok", "tag no arquivo sujo")
    g2.default_targets.append(DIR + "/sujo.ok")
    ok2 = await B.build(g2, DIR + "/log10", [], opts(1), rep())
    check("portão negativo: vermelho quando acha", "False", str(ok2))

    # e o aspeamento: um padrão com aspa simples atravessa inteiro
    await write_file(DIR + "/aspa.h", "nada aqui\n")
    g3 = G.new_graph()
    T.nao_acha(T.new_ctx(g3, DIR, "plangc"), "o'brien", [DIR + "/aspa.h"],
               DIR + "/aspa.ok", "aspa simples no padrão")
    g3.default_targets.append(DIR + "/aspa.ok")
    ok3 = await B.build(g3, DIR + "/log11", [], opts(1), rep())
    check("portão negativo: aspa simples no padrão", "True", str(ok3))

async def go():
    os.makedirs(DIR)
    await caso_incremental()
    await caso_comando_mudou()
    await caso_ambiente_mudou()
    await caso_restat()
    await caso_paralelo_e_ordem()
    await caso_pool_console()
    await caso_falha_para()
    await caso_saida_nao_produzida()
    await caso_entrada_orfa()
    await caso_ciclo()
    await caso_dry_run()
    await caso_keep_going()
    await caso_explain()
    await caso_depfile()
    await caso_dois_produtores()
    await caso_grafo_reusado()
    await caso_json()
    await caso_ninja()
    await caso_pacotes()
    await caso_pacote_com_c()
    await caso_api()
    await caso_manifesto()
    await caso_limite_de_bracos()
    await caso_portao_negativo()
    print("   pbuild-engine: " + str(ok_count) + " ok, " + str(fail_count) + " failed")
    if fail_count > 0:
        sys.exit(1)

await go()
