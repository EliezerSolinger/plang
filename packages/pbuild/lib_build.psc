"""O MOTOR: o que está velho, em que ordem, e quem roda.

É o análogo das 1 546 linhas do samurai, com as decisões deste projeto. A leitura
que o originou está em `pbuild/DESIGN.md`; o que segue é o resumo do que cada
peça faz e por quê, porque um motor de build é feito de escolhas que parecem
arbitrárias até alguém explicar a alternativa.

**Um limite conhecido, dito antes que alguém o descubra:** a comparação de datas
é "a saída é MAIS VELHA que a entrada", com menor estrito — como no ninja. Dois
arquivos escritos no mesmo instante não se distinguem, e num sistema de arquivos
de granularidade grosseira (o HFS+ do macOS tem um segundo) isso é um furo real:
editar e reconstruir dentro do mesmo segundo pode não recompilar. O `mtime` daqui
é de NANOSSEGUNDOS justamente para encolher a janela onde há resolução, e a saída
definitiva — comparar o CONTEÚDO das entradas, como já se faz com as saídas no
`restat` — está anotada e não feita: ela custa ler a árvore inteira a cada build.

**A biblioteca NÃO imprime.** Ela relata cinco eventos e quem decide o que
fazer com eles é a frente: a linha de comando imprime, a IDE pinta. É o que
separa um motor reutilizável de um script com `print` no meio — e é fácil errar
na primeira linha, então está dito aqui.
"""
import os
import path
import time
import lib_graph as G
import lib_log as L

# ---------- os cinco eventos ----------
# Contrato pequeno é contrato que dá para mudar. O motivo da sujeira e o grafo
# quem quiser pede (`explain`), em vez de viajarem em todo evento.
struct Rep:
    on_plan: def(int)                    # quantas arestas vão rodar
    on_start: def(int, str)              # id, o que se está fazendo
    on_end: def(int, int, str, int)      # id, status, saída INTEIRA, ms
    on_done: def(bool, int)              # deu certo?, quantas falharam
    # o quinto evento: um problema do GRAFO, não de uma aresta — duas arestas
    # produzindo o mesmo arquivo, uma entrada que ninguém produz, um ciclo, uma
    # saída prometida e não criada. Ele existe porque a primeira versão só
    # contava os problemas, e "build falhou: 3 problema(s)" sem dizer QUAIS é
    # exatamente o relatório que não serve para nada.
    on_error: def(str)

private def nop_erro(msg: str):
    pass

private def nop_plan(total: int):
    pass

private def nop_start(id: int, what: str):
    pass

private def nop_end(id: int, st: int, out: str, ms: int):
    pass

private def nop_done(ok: bool, fails: int):
    pass

def quiet() -> Rep:
    """Um relator que não faz nada — para quem só quer o resultado."""
    return Rep(nop_plan, nop_start, nop_end, nop_done, nop_erro)

record Opts:
    jobs: int          # quantos processos em voo
    keep_going: int    # -k N: quantas falhas antes de parar (1 = para na primeira)
    dry_run: bool
    explain: bool

def default_opts() -> Opts:
    # o padrão é o número de núcleos. A medição deste repositório diz que ele
    # satura em ~4 (o caminho crítico é UM arquivo de 4,96 s num build de 5,0 s),
    # mas o ótimo é do projeto e núcleos é o chute honesto.
    return Opts(os.nproc(), 1, False, False)

struct Build:
    g: G.Graph
    lg: L.Log
    op: Opts
    rep: Rep
    ready: list<int>       # arestas prontas, a mais cara na frente
    rodando: int           # quantas arestas estão EM VOO agora
    fails: int
    total: int             # quantas arestas o plano vai rodar
    errs: list<str>        # higiene: o que impede o build de ser confiável
    why: dict<str, str>    # explain: por que cada saída está suja

# ---------- higiene ----------
# Três coisas são ERRO, e não aviso, porque cada uma quebra a corretude do
# incremental: uma aresta que promete `x.o` e não o cria envenena todo build
# seguinte; um ciclo nunca termina; e uma entrada que ninguém produz e não existe
# é um grafo que mente sobre o que sabe.
private def err(b: Build, msg: str):
    b.errs.append(msg)
    b.rep.on_error(msg)

private def explain(b: Build, node: str, msg: str):
    if b.op.explain:
        b.why[node] = msg

# ---------- a sujeira ----------
# Os SEIS testes do ninja, lidos na fonte (`graph.cc:222`) e na ordem em que ele
# os faz. A ordem importa: o `restat` tem de trocar o mtime ANTES da comparação,
# senão uma saída "limpa" numa corrida anterior suja o mundo.
private def out_dirty(b: Build, e: G.Edge, n: G.Node, newest: int) -> bool:
    n.stat_now()
    if n.mtime == G.MTIME_MISSING:
        explain(b, n.p, "não existe")
        return True
    ent = b.lg.get(n.p)
    used_restat = False
    if e.restat and b.lg.has(n.p):
        # 2: numa aresta `restat`, o que vale é o mtime GRAVADO, não o do disco —
        # é assim que uma saída que não mudou de verdade não suja quem a lê
        used_restat = True
    if not used_restat and newest >= 0 and n.mtime < newest:
        explain(b, n.p, "mais velha que a entrada mais nova")
        return True
    if b.lg.has(n.p):
        if not e.generator and ent.hash != e.hash:
            explain(b, n.p, "o comando mudou")
            return True
        if newest >= 0 and ent.vtime < newest:
            # 5: o mtime do disco pode ser novo e o conteúdo velho — uma corrida
            # que escreveu a saída e morreu no meio deixa exatamente isso. O que
            # se compara é o `vtime` (quando esta aresta foi CONFERIDA contra as
            # entradas dela), e não o `mtime` (quando o conteúdo da saída mudou):
            # numa aresta `restat` os dois divergem, e usar o errado faz a aresta
            # rodar para sempre. Ver a nota das duas datas em `lib_log.psc`.
            explain(b, n.p, "a conferência gravada é mais velha que a entrada mais nova")
            return True
    elif not e.generator:
        explain(b, n.p, "não há registro no log")
        return True
    return False

# ---------- o grafo é reusável ----------
# O estado do PLANO (o que está sujo, quantas entradas faltam, o peso) vive na
# aresta, e um grafo pode ser planejado mais de uma vez: a IDE constrói, o
# programador edita um arquivo, e o mesmo grafo em memória é construído de novo
# (F6). Sem zerar isto, a segunda vez enxerga o plano da primeira e conclui que
# não há nada a fazer — que é o pior erro possível, porque é silencioso.
private def reset_plan(g: G.Graph):
    for e in g.edges:
        e.want = False
        e.dirty_in = False
        e.dirty_out = False
        e.nblock = 0
        e.nprune = 0
        e.cpw = 0
    for n in g.nodes:
        n.mtime = G.MTIME_UNKNOWN
        n.dirty = False

# ---------- o que a ferramenta LEU e nós não sabíamos ----------
# O `cc -MD` deixa um `.d` ao lado do `.o`, e ele fica no disco: é lido no PLANO
# da corrida seguinte, que é o que um Makefile faz com `-include`. O ninja copia
# esses arquivos para um log binário próprio por VELOCIDADE (ele mede projetos
# com centenas de milhares de arestas); aqui são milhares, e um log a mais para
# manter coerente custaria mais do que economiza.
#
# Do NOSSO lado nada disto é preciso: o `plangc` responde a pergunta 1 do
# protocolo e diz o que leu, sem passar por arquivo nenhum.
private async def load_depfiles(b: Build):
    for e in b.g.edges:
        if len(e.depfile) == 0 or not path.isfile(e.depfile):
            continue
        f = await open(e.depfile, "r")
        txt = await f.text()
        await f.close()
        for d in L.parse_depfile(txt):
            nid = b.g.node(d).id
            ja = False
            for x in e.ins:
                if x == nid:
                    ja = True
            for y in e.implicit:
                if y == nid:
                    ja = True
            if ja:
                continue
            e.implicit.append(nid)
            b.g.nodes[nid].used.append(e.id)

# ---------- a data que VALE ----------
# Uma ferramenta reescreve a saída mesmo quando ela sai igual — o nosso `plangc`
# faz isso, e quase toda ferramenta faz. A data no disco muda, o conteúdo não, e
# um build que olhasse só a data recompilaria o mundo por nada.
#
# É o que o `restat` já resolve DENTRO de uma corrida (a poda). O que faltava era
# ATRAVESSAR corridas: na corrida seguinte a data do disco é nova de novo, e
# quem lê o arquivo se acha desatualizado. Aqui isso se fecha: para toda saída de
# aresta `restat` que tem hash de conteúdo no log, se o conteúdo AINDA é aquele,
# a data que vale é a do log — não a do disco.
#
# O custo é ler esses arquivos uma vez por plano. São as saídas do compilador
# (dezenas neste repositório, centenas na suíte), e é por isso que este motor
# pode fazer o que o ninja não faz: o ninja mede projetos com centenas de
# milhares de arestas, e para ele ler tudo seria proibitivo.
private async def carimbar(b: Build):
    for e in b.g.edges:
        if not e.restat:
            continue
        for oid in e.outs:
            n = b.g.nodes[oid]
            ent = b.lg.get(n.p)
            if ent.chash == u64(0):
                continue
            n.stat_now()
            if n.mtime == G.MTIME_MISSING or n.mtime == ent.mtime:
                continue
            if await content_hash(n.p) == ent.chash:
                n.mtime = ent.mtime

# ---------- o plano ----------
private def want_node(b: Build, nid: int, stack: list<int>) -> bool:
    """Marca o que precisa ser construído para `nid` existir e estar em dia.
    Devolve se o nó ficou sujo. É recursivo e guarda a pilha, porque um ciclo
    aqui é o único jeito de o motor girar para sempre."""
    n = b.g.nodes[nid]
    if n.gen < 0:
        n.stat_now()
        if n.mtime == G.MTIME_MISSING:
            err(b, "entrada que não existe e ninguém produz: " + n.p)
        n.dirty = False
        return False
    e = b.g.edges[n.gen]
    for s in stack:
        if s == n.gen:
            err(b, "ciclo no grafo, passando por: " + n.p)
            return False
    if e.want:
        return n.dirty
    e.want = True
    stack.append(n.gen)
    e.nblock = 0
    newest = -1
    ndirty = False
    i = 0
    while i < len(e.ins) + len(e.implicit) + len(e.order):
        # as três faixas, em ordem: normais, implícitas, e as de ORDEM (que só
        # precisam existir antes, e não sujam nada)
        isorder = i >= len(e.ins) + len(e.implicit)
        iid = 0
        if i < len(e.ins):
            iid = e.ins[i]
        elif i < len(e.ins) + len(e.implicit):
            iid = e.implicit[i - len(e.ins)]
        else:
            iid = e.order[i - len(e.ins) - len(e.implicit)]
        i += 1
        d = want_node(b, iid, stack)
        inn = b.g.nodes[iid]
        if not isorder:
            if d:
                e.dirty_in = True
            if inn.mtime != G.MTIME_MISSING and inn.mtime > newest:
                newest = inn.mtime
        if d or (inn.gen >= 0 and b.g.edges[inn.gen].nblock > 0):
            e.nblock += 1
    for oid in e.outs:
        if out_dirty(b, e, b.g.nodes[oid], newest):
            e.dirty_out = True
    for oid2 in e.out_implicit:
        if out_dirty(b, e, b.g.nodes[oid2], newest):
            e.dirty_out = True
    # o contador da PODA: quantas entradas bloqueantes precisam ser podadas para
    # que as saídas desta aresta também possam ser. Vale sempre que a saída não
    # está suja por si mesma — inclusive quando a aresta vai rodar por causa de
    # uma entrada, que é o caso em que a poda tem algo a podar.
    if not e.dirty_out:
        e.nprune = e.nblock
    if e.dirty_in or e.dirty_out:
        for od in e.outs:
            b.g.nodes[od].dirty = True
        for od2 in e.out_implicit:
            b.g.nodes[od2].dirty = True
        b.total += 1
        ndirty = True
    # o topo TEM de ser esta aresta: a pilha é o caminho da recursão, e é ela
    # que detecta o ciclo. Conferir custa nada e o valor do `pop` não se perde —
    # descartá-lo seria uma expressão sem uso, que o compilador (com razão) avisa
    topo = stack.pop()
    if topo != n.gen:
        err(b, "a pilha do plano saiu de ordem: isto é um defeito do motor")
    return ndirty

# ---------- o caminho crítico ----------
# O ninja ordena por caminho crítico em NÚMERO de arestas (peso 1 por aresta,
# `build.cc:473`) e ignora a duração que ele mesmo grava. Num grafo raso como o
# deste repositório isso dá empate em tudo: os 19 TUs do compilador têm o mesmo
# comprimento até o binário, e a aresta de 4,96 s pode ir por último num build de
# 5,0 s. Aqui o peso é a DURAÇÃO da última vez.
private def cost(e: G.Edge) -> int:
    if e.dur_ms > 0:
        return e.dur_ms
    return 1000     # nunca rodou: um segundo de chute, para não ficar por último

private def critical_path(b: Build):
    order: list<int> = []
    seen: list<bool> = []
    for _e in b.g.edges:
        seen.append(False)
    # ordem topológica: um produtor aparece ANTES de quem o consome
    for e in b.g.edges:
        if e.want:
            visit_topo(b, e.id, seen, order)
    for e2 in b.g.edges:
        e2.cpw = cost(e2)
    i = len(order) - 1
    while i >= 0:
        e3 = b.g.edges[order[i]]
        for iid in e3.ins:
            pn = b.g.nodes[iid]
            if pn.gen >= 0:
                pe = b.g.edges[pn.gen]
                cand = e3.cpw + cost(pe)
                if cand > pe.cpw:
                    pe.cpw = cand
        for iid2 in e3.implicit:
            pn2 = b.g.nodes[iid2]
            if pn2.gen >= 0:
                pe2 = b.g.edges[pn2.gen]
                cand2 = e3.cpw + cost(pe2)
                if cand2 > pe2.cpw:
                    pe2.cpw = cand2
        i -= 1

private def visit_topo(b: Build, eid: int, seen: list<bool>, order: list<int>):
    if seen[eid]:
        return
    seen[eid] = True
    e = b.g.edges[eid]
    for iid in e.ins:
        n = b.g.nodes[iid]
        if n.gen >= 0:
            visit_topo(b, n.gen, seen, order)
    for iid2 in e.implicit:
        n2 = b.g.nodes[iid2]
        if n2.gen >= 0:
            visit_topo(b, n2.gen, seen, order)
    order.append(eid)

# ---------- a fila ----------
private def enqueue(b: Build, eid: int):
    """A mais cara na frente. Inserção ordenada e não `sorted` a cada vez: a fila
    muda uma aresta por vez, e uma varredura de N é mais barata que uma ordenação
    de N log N repetida."""
    e = b.g.edges[eid]
    i = 0
    while i < len(b.ready):
        if b.g.edges[b.ready[i]].cpw < e.cpw:
            break
        i += 1
    b.ready.insert(i, eid)

private def take_ready(b: Build) -> int:
    if len(b.ready) == 0:
        return -1
    v = b.ready[0]
    b.ready = b.ready[1:len(b.ready)]
    return v

# ---------- o conteúdo de uma saída ----------
# O `restat` do ninja compara MTIME, e isso só poda quando a ferramenta se
# recusa a reescrever um arquivo igual. O nosso `plangc` reescreve sempre — como
# quase toda ferramenta —, então aqui o `restat` compara CONTEÚDO. É a diferença
# entre a poda funcionar e não funcionar, e é ela que vale os 18 s deste
# repositório: o C regenerado sai byte a byte igual em quase toda edição.
private async def content_hash(p: str) -> u64:
    if not path.isfile(p):
        return u64(0)
    f = await open(p, "r")
    txt = await f.text()
    await f.close()
    return G.hash_str(G.FNV_OFF, txt)

# ---------- terminar uma aresta ----------
private def newest_de(b: Build, e: G.Edge) -> int:
    """A data da entrada mais nova desta aresta — a mesma conta que o plano faz,
    e pelo mesmo motivo (as de ORDEM não contam: elas só precisam existir)."""
    novo = -1
    for i in e.ins:
        n = b.g.nodes[i]
        if n.mtime != G.MTIME_MISSING and n.mtime > novo:
            novo = n.mtime
    for j in e.implicit:
        n2 = b.g.nodes[j]
        if n2.mtime != G.MTIME_MISSING and n2.mtime > novo:
            novo = n2.mtime
    return novo

private def node_done(b: Build, nid: int, prune: bool):
    """Uma saída ficou pronta. Duas coisas podem acontecer com quem depende dela,
    e a diferença entre as duas é o mecanismo inteiro da poda:

      * se esta saída não MUDOU (`prune`), quem dependia dela só por causa dela
        não precisa rodar — e as saídas DELE também não mudaram, então a poda
        segue em frente, transitivamente;
      * senão, quem dependia dela tem uma entrada a menos faltando, e quando não
        faltar nenhuma ele entra na fila.

    É a lógica do `nodedone` do samurai, com os dois contadores (`nblock` e
    `nprune`) que ela usa."""
    n = b.g.nodes[nid]
    for eid in n.used:
        e = b.g.edges[eid]
        if not e.want:
            continue
        # OS DOIS CONTADORES ANDAM SEPARADOS, e cada entrada que termina mexe
        # nos dois: `nblock` é "quantas entradas ainda faltam" e `nprune` é
        # "quantas ainda podem vir sem mudança". Uma entrada que MUDOU baixa só
        # o primeiro; uma que veio igual baixa os dois.
        #
        # A versão anterior escolhia UM dos contadores por entrada, e por isso
        # uma aresta com entradas MISTURADAS — uma que mudou e outra que não —
        # ficava com os dois em 1 e nunca mais saía: nem rodava nem era podada.
        # O braço que a esperava via a fila vazia, ninguém em voo, e ia embora.
        # O build terminava com sucesso e o trabalho por fazer, e só a corrida
        # seguinte é que continuava. Foi assim que uma edição no lexer levou
        # cinco `make` a chegar ao compilador.
        podavel = not e.dirty_out
        if prune and podavel:
            e.nprune -= 1
        e.nblock -= 1
        if podavel and e.nprune == 0:
            # TUDO o que a bloqueava veio sem mudança: esta aresta não precisa
            # rodar, e as saídas dela também não mudaram — a poda segue em frente
            for oid in e.outs:
                node_done(b, oid, True)
            if e.dirty_in or e.dirty_out:
                b.total -= 1
        elif e.nblock == 0 and (e.dirty_in or e.dirty_out):
            enqueue(b, eid)

private async def finish(b: Build, e: G.Edge, ok: bool, dur_ms: int):
    if not ok:
        return
    if b.op.dry_run:
        # num ensaio nada foi criado, então não há saída para datar nem para
        # cobrar. O que ainda vale é DESTRANCAR quem esperava: é o que faz o
        # ensaio percorrer o grafo inteiro em vez de parar na primeira aresta.
        for oid0 in e.outs:
            node_done(b, oid0, False)
        for oid1 in e.out_implicit:
            node_done(b, oid1, False)
        return
    # o `depfile`: o que a ferramenta LEU e nós não sabíamos. Fica no disco e é
    # lido no PLANO da próxima vez (é o que um Makefile faz com `-include`); o
    # ninja o copia para um log binário por velocidade, e aqui isso ainda não se
    # paga — são milhares de arquivos, não milhões.
    for oid in e.outs:
        n = b.g.nodes[oid]
        antes = b.lg.get(n.p)
        n.mtime = G.MTIME_UNKNOWN
        n.stat_now()
        if n.mtime == G.MTIME_MISSING:
            err(b, "a aresta prometeu '" + n.p + "' e não o criou")
            continue
        podar = False
        ch = u64(0)
        if e.restat:
            ch = await content_hash(n.p)
            if antes.chash != u64(0) and ch == antes.chash:
                # saiu IDÊNTICA: quem a lê não precisa rodar, e o nó guarda a
                # data ANTIGA para que a poda atravesse esta corrida.
                podar = True
                n.mtime = antes.mtime
                # No log vão as DUAS datas: a antiga (o conteúdo não mudou) e a
                # da entrada mais nova (esta aresta está conferida contra ela).
                # A primeira é o que impede quem lê de recompilar; a segunda é o
                # que impede ESTA aresta de rodar de novo para sempre. Ver a
                # nota das duas datas em `lib_log.psc`.
                b.lg.put(n.p, antes.mtime, newest_de(b, e), dur_ms, e.hash, ch)
        if not podar:
            b.lg.put(n.p, n.mtime, newest_de(b, e), dur_ms, e.hash, ch)
        node_done(b, oid, podar)
    for oid2 in e.out_implicit:
        n2 = b.g.nodes[oid2]
        n2.mtime = G.MTIME_UNKNOWN
        n2.stat_now()
        node_done(b, oid2, False)

# ---------- o executor ----------
# Cada braço pega a aresta mais cara que está pronta, roda, e volta para pegar
# outra. Quando termina uma e mais de uma fica pronta, ele acorda braços novos
# até o limite — é o que impede o paralelismo de desabar para um quando uma
# aresta longa destranca várias.
private async def pump(b: Build) -> int:
    while True:
        if b.fails >= b.op.keep_going:
            break
        eid = take_ready(b)
        if eid < 0:
            # Nada PRONTO agora. Duas coisas diferentes se parecem com isto: o
            # build acabou, ou alguém ainda está a correr e vai destrancar mais
            # arestas quando terminar. Só a primeira é motivo para sair.
            if b.rodando == 0:
                break
            await sleep(0.001)
            continue
        e = b.g.edges[eid]
        # o diretório de uma saída tem de existir ANTES de a ferramenta rodar.
        # Ninguém declara isso num arquivo de build — nem o ninja obriga —, e o
        # motor o faz porque a alternativa é toda aresta carregar um `mkdir -p`
        # que não tem nada a ver com o que ela faz.
        if not b.op.dry_run:
            for oid in e.outs:
                d = path.dirname(b.g.nodes[oid].p)
                if len(d) > 0 and not path.isdir(d):
                    os.makedirs(d)
            if len(e.stdout_to) > 0:
                d2 = path.dirname(e.stdout_to)
                if len(d2) > 0 and not path.isdir(d2):
                    os.makedirs(d2)
        b.rep.on_start(e.id, e.label())
        # `rodando` é quantas arestas estão EM VOO. Um braço que não acha
        # trabalho olha para ele para saber se espera ou se vai embora.
        b.rodando += 1
        if b.op.dry_run:
            b.rep.on_end(e.id, 0, "", 0)
            await finish(b, e, True, 0)
        else:
            t0 = time_ms()
            r = await os.run(e.argv, env=e.env, cwd=e.cwd, stdout=e.stdout_to)
            ms = time_ms() - t0
            b.rep.on_end(e.id, r.status(), r.output(), ms)
            if r.status() != 0:
                b.fails += 1
            await finish(b, e, r.status() == 0, ms)
        b.rodando -= 1
    return 0

private def time_ms() -> int:
    # o relógio MONOTÔNICO: medir duração com o relógio de parede daria número
    # negativo no dia em que o sistema acerta a hora no meio de um build
    return int(time.monotonic() * 1000.0)

# ---------- a fachada ----------
async def build(g: G.Graph, logpath: str, targets: list<str>, op: Opts, rep: Rep) -> bool:
    """Constrói `targets` (ou o padrão do grafo). Devolve se deu certo.

    As fases estão aqui na ordem em que o desenho as nomeia: PLANEJAR (o que está
    velho), DECIDIR (em que ordem), EXECUTAR (rodar), GRAVAR (o log).
    """
    b = Build(g, await L.load(logpath), op, rep, [], 0, 0, 0, [], {})
    reset_plan(g)
    # o log entra ANTES do plano: é ele que sabe o hash do comando e a duração
    for e0 in g.edges:
        for oid in e0.outs:
            ent = b.lg.get(g.nodes[oid].p)
            if ent.dur_ms > e0.dur_ms:
                e0.dur_ms = ent.dur_ms
    for dup in g.dupes:
        err(b, "duas arestas produzem o mesmo arquivo: " + dup)
    await load_depfiles(b)
    await carimbar(b)
    tl = targets
    if len(tl) == 0:
        tl = g.default_targets
    if len(tl) == 0:
        # sem alvo dito, tudo que ninguém consome é alvo — que é o que "construa
        # o projeto" quer dizer
        for n in g.nodes:
            if n.gen >= 0 and len(n.used) == 0:
                tl.append(n.p)
    stack: list<int> = []
    for t in tl:
        if t not in g.by_path:
            err(b, "alvo desconhecido: " + t)
            continue
        want_node(b, g.by_path[t], stack)
    if len(b.errs) > 0:
        rep.on_done(False, len(b.errs))
        return False
    critical_path(b)
    for e in g.edges:
        if e.want and e.nblock == 0 and (e.dirty_in or e.dirty_out):
            enqueue(b, e.id)
    rep.on_plan(b.total)
    # quem decide se há trabalho é a FILA, e não o contador: o contador é
    # relatório (e a poda o diminui enquanto o build corre)
    if len(b.ready) > 0:
        # OS BRAÇOS SÃO CRIADOS DE UMA VEZ, e não uns pelos outros.
        #
        # A primeira forma tinha cada braço a multiplicar-se e depois a esperar
        # pelos filhos, o que fazia uma CADEIA de esperas aninhadas — treze
        # `pump` na pilha com `-j 8`. Além de não limitar nada, ela travava: no
        # fundo da cadeia alguém esperava por quem já tinha terminado, e o
        # programa morria com "deadlock: awaiting a task that nothing can
        # finish" depois de imprimir tudo como verde.
        #
        # Um POOL PLANO não tem cadeia: N braços iguais, cada um a tirar da fila
        # até não haver mais nada em voo. Quem não acha trabalho e vê alguém a
        # correr espera um milissegundo e olha de novo — é o preço de não ter
        # sinalização, e ele só se paga quando um braço está OCIOSO.
        bracos: list<Task<int>> = []
        n = b.op.jobs if b.op.jobs > 0 else 1
        for i in range(n):
            bracos.append(pump(b))
        await gather(bracos)
    await L.save(b.lg)
    ok = b.fails == 0 and len(b.errs) == 0
    rep.on_done(ok, b.fails + len(b.errs))
    return ok

async def why_dirty(g: G.Graph, logpath: str, targets: list<str>) -> dict<str, str>:
    """`--explain`, e ele é CONSULTA e não evento: roda só o PLANO e devolve, por
    saída, a razão de ela estar suja. Fica de fora do fluxo de eventos de
    propósito — o motivo quase nunca é lido, e carregá-lo em todo evento
    engordaria o contrato que a IDE vai consumir.

    É a pergunta que salva a tarde em que o build reconstrói o que não devia."""
    b = Build(g, await L.load(logpath), Opts(1, 1, True, True), quiet(), [], 0, 0, 0, [], {})
    reset_plan(g)
    await load_depfiles(b)
    await carimbar(b)
    tl = targets
    if len(tl) == 0:
        tl = g.default_targets
    stack: list<int> = []
    for t in tl:
        if t in g.by_path:
            want_node(b, g.by_path[t], stack)
    return b.why

def errors(b: Build) -> list<str>:
    return b.errs
