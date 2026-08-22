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
import lib_graph as G
import lib_build as B
import lib_ninja as N

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

def r_plan(total: int):
    pass

def r_start(id: int, what: str):
    global order
    order.append(what)

def r_end(id: int, st: int, out: str, ms: int):
    global ran
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
    ran = novo
    order = novo2
    erros = novo3

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

async def go():
    os.makedirs(DIR)
    await caso_incremental()
    await caso_comando_mudou()
    await caso_ambiente_mudou()
    await caso_restat()
    await caso_paralelo_e_ordem()
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
    print("   pbuild-engine: " + str(ok_count) + " ok, " + str(fail_count) + " failed")
    if fail_count > 0:
        sys.exit(1)

await go()
