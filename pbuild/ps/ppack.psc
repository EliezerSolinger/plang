"""`ppack` — o comando de cima.

Ele é a FRENTE da biblioteca: o motor relata quatro eventos e quem imprime é
aqui. A IDE (F6) é a outra frente, e pinta os mesmos eventos — é essa separação
que faz o motor ser reutilizável em vez de ser um script com `print` no meio.

    ppack build [alvo...]     constrói (o padrão é o alvo padrão do grafo)
    ppack test                roda a suíte do pscript, caso a caso
    ppack verify              a verificação inteira (o `verify-all`, como grafo)
    ppack run <alvo> [args]   constrói o alvo e roda-o
    ppack explain <saída>     por que ESTA saída está suja
    ppack graph               o grafo em JSON, para inspecionar ou versionar
    ppack ninja [arquivo]     escreve o `build.ninja` do bootstrap (padrão: -)
    ppack doc <alvo> [nome]   a interface de um módulo (ou de um pacote), com a
                              documentação — `alvo` é um arquivo ou o nome de um
                              pacote do workspace
    ppack tree                os pacotes do workspace, e o que cada um puxa
    ppack why <pacote>        quem puxou este pacote
    ppack clean               apaga o que o build produziu
    ppack help

Opções: `-j N` (processos em voo; o padrão é o número de núcleos), `-k N`
(continuar depois de N falhas; o padrão é parar na primeira), `-n`/`--dry-run`,
`--query <plangc>` (o compilador que responde as perguntas do protocolo).
"""
import os
import path
import sys
import lib_graph as G
import lib_build as B
import lib_targets as T
import lib_ninja as N
import lib_api as A
import lib_manifest as MF
import lib_pkg as PK
import build_plang as BP
import lib_repo as R
import lib_lock as LK

const LOG: str = "build/log/build.log"

feitas: int = 0
total_arestas: int = 0
falhou: bool = False

def on_plan(total: int):
    global total_arestas
    total_arestas = total
    if saida_json:
        print('{"event": "plan", "total": ' + str(total) + '}')
        return
    if total == 0:
        print("nada a fazer")

# `--json`: os MESMOS dados dos eventos e das consultas, em JSON. Um objeto por
# LINHA no fluxo de eventos (quem lê quer reagir enquanto o build corre, e um
# documento único só se pode ler no fim); um documento só nas consultas, que são
# uma resposta e não um fluxo.
saida_json: bool = False

rotulos: dict<int, str> = {}

# o PLACAR: quantas arestas de cada suíte passaram, e quais falharam. A chave é o
# que vem antes do primeiro `: ` na descrição — que é como a biblioteca de alvos
# escreve o rótulo de um caso (`pscript: nome_do_caso`). Um build comum não tem
# suíte nenhuma e o placar não aparece.
placar_ok: dict<str, int> = {}
placar_mal: dict<str, list<str>> = {}

private def suite_de(rot: str) -> str:
    k = rot.find(": ")
    return rot[0:k] if k > 0 else ""

private def contar(rot: str, ok: bool):
    global placar_ok
    global placar_mal
    su = suite_de(rot)
    if len(su) == 0:
        return
    if su not in placar_ok:
        placar_ok[su] = 0
        placar_mal[su] = []
    if ok:
        placar_ok[su] = placar_ok[su] + 1
    else:
        placar_mal[su].append(rot[len(su) + 2:])

def on_start(id: int, what: str):
    global rotulos
    rotulos[id] = what

def on_end(id: int, st: int, out: str, ms: int):
    global feitas
    global falhou
    feitas += 1
    contar(rotulos[id] if id in rotulos else "", st == 0)
    if saida_json:
        print('{"event": "end", "id": ' + str(id) + ', "status": ' + str(st)
              + ', "ms": ' + str(ms) + ', "what": ' + G.jstr(rotulos[id] if id in rotulos else "")
              + ', "output": ' + G.jstr(out) + '}')
        if st != 0:
            falhou = True
        return
    marca = "[" + str(feitas) + "/" + str(total_arestas) + "]"
    if st == 0:
        print(marca, "ok")
        if len(out) > 0:
            print(out.rstrip())
    else:
        falhou = True
        # QUAL aresta falhou. Sem isto o relatório diz que algo deu errado e não
        # diz o quê — e num build de seiscentas arestas isso não é relatório.
        quem = rotulos[id] if id in rotulos else "?"
        print(marca, "FALHOU (status " + str(st) + "):", quem)
        if len(out) > 0:
            print(out.rstrip())

def on_erro(msg: str):
    """Um problema do GRAFO — não de uma aresta. Ele sai ANTES de qualquer
    comando rodar, porque é o tipo de coisa que invalida o build inteiro."""
    global falhou
    falhou = True
    if saida_json:
        print('{"event": "error", "message": ' + G.jstr(msg) + '}')
        return
    print("erro:", msg)

def on_done(ok: bool, fails: int):
    if saida_json:
        partes: list<str> = []
        ks0: list<str> = []
        for k0 in placar_ok:
            ks0.append(k0)
        for k1 in sorted(ks0):
            maus0: list<str> = []
            for nm in placar_mal[k1]:
                maus0.append(G.jstr(nm))
            partes.append(G.jstr(k1) + ': {"ok": ' + str(placar_ok[k1])
                          + ', "failed": [' + ", ".join(maus0) + ']}')
        print('{"event": "done", "ok": ' + ("true" if ok else "false")
              + ', "failed": ' + str(fails) + ', "suites": {' + ", ".join(partes) + '}}')
        return
    # o PLACAR, quando houve suíte. Ele existe porque "587 arestas ok" não é o
    # que quem roda testes quer saber: o que se quer é quantos casos passaram,
    # e QUAIS falharam — e um build de seiscentas arestas esconde as duas coisas.
    ks: list<str> = []
    for k in placar_ok:
        ks.append(k)
    for k2 in sorted(ks):
        maus = placar_mal[k2]
        # "RODARAM", e não "existem": um caso cujo binário e cujo esperado não
        # mudaram não roda, e dizer "1 ok" quando cento e catorze estão em dia
        # seria um placar que mente. Quem quer o total roda com a árvore limpa.
        total = placar_ok[k2] + len(maus)
        print("   " + k2 + ": " + str(total) + " rodaram — " + str(placar_ok[k2])
              + " ok, " + str(len(maus)) + " falharam")
        n = 0
        for nome in maus:
            if n >= 10:
                print("       (e mais " + str(len(maus) - 10) + ")")
                break
            print("       " + nome)
            n += 1
    if not ok:
        print("build falhou:", fails, "problema(s)")

# o relator imprime a DESCRIÇÃO no começo de cada aresta; o `on_start` acima fica
# vazio porque a linha só faz sentido junto do resultado quando N rodam ao mesmo
# tempo — com paralelismo, "começou" e "terminou" se intercalam
def on_start_verbose(id: int, what: str):
    global rotulos
    rotulos[id] = what
    print("  ->", what)

async def cmd_build(alvos: list<str>, jobs: int, keep: int, dry: bool, query: str, verbose: bool) -> int:
    g = await BP.montar(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_erro)
    ok = await B.build(g, LOG, alvos, B.Opts(jobs, keep, dry, False), rep)
    return 0 if ok else 1

async def cmd_run(alvos: list<str>, jobs: int, query: str, verbose: bool) -> int:
    """Constrói e roda. Duas coisas que ele aceita, e a segunda é a que fecha a
    F7:

      * um ALVO do grafo (`ppack run build/bin/pstudio`);
      * um ARQUIVO de fonte (`ppack run x.psc`, `ppack run x.p`) — que não está
        no descritor nenhum, e é construído aqui, em `build/run/`.

    O segundo caso é o que o `plangc run` fazia, e é a única decisão de POLÍTICA
    que ainda vivia dentro do compilador: onde guardar o binário, quando é que
    ele está velho, e o que fazer com os argumentos. Nada disso é sobre traduzir
    uma linguagem.

    E o programa **passa a ser este processo** (`os.exec`). Antes ele corria como
    filho com a saída capturada, o que serve para um programa que imprime e para
    mais nada: sem teclado, sem tela, sem tamanho de terminal, sem Ctrl-C. Por
    isso o status de saída também deixa de precisar de conversa — ele É o do
    programa, porque é o mesmo processo.

    Um build que falha sai com 101 (a convenção do cargo), para que um script
    saiba distinguir "o programa recusou" de "o programa nem chegou a existir"."""
    if len(alvos) == 0:
        print("uso: ppack run <alvo|arquivo.psc> [args...]")
        return 2
    alvo = alvos[0]
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_erro)
    solto: bool = (alvo.endswith(".psc") or alvo.endswith(".p")) and path.isfile(alvo)
    if solto:
        # O CAMINHO CURTO, e é ele que faz `ppack run` valer como lançador de
        # scripts: se o manifesto da última corrida ainda bate — o mesmo
        # compilador, os mesmos arquivos, as mesmas datas —, não há nada a
        # perguntar nem a construir, e o processo vira o programa em
        # milissegundos. Sem isto, cada corrida paga duas invocações do
        # compilador (meio segundo) para descobrir que não havia nada a fazer.
        pronto = await BP.run_manifesto_ok(alvo)
        if len(pronto) > 0:
            argv0: list<str> = [pronto if pronto.startswith("/") else path.join(os.getcwd(), pronto)]
            i0 = 1
            while i0 < len(alvos):
                argv0.append(alvos[i0])
                i0 += 1
            os.exec(argv0)
            return 127
    g = G.new_graph()
    if solto and path.isfile(BP.PLANGC_S2):
        # O GRAFO MÍNIMO, e é isto que faz o `run` ser rápido: montar o
        # descritor inteiro custa centenas de perguntas ao compilador (doze
        # segundos aqui), e nenhuma delas é sobre este arquivo. Quando o
        # compilador já existe, o que se constrói é só o programa.
        alvo = await BP.programa_solto(g, query, alvo)
    else:
        g = await BP.montar(query)
        if alvo not in g.by_path and solto:
            alvo = await BP.programa_solto(g, query, alvo)
        elif alvo not in g.by_path:
            print("não achei '" + alvo + "' — nem alvo do descritor, nem arquivo")
            return 1
    if not await B.build(g, LOG, [alvo], B.Opts(jobs, 1, False, False), rep):
        return 101
    if solto:
        await BP.run_manifesto_grava(alvos[0], alvo, g)
    argv: list<str> = [alvo if alvo.startswith("/") else path.join(os.getcwd(), alvo)]
    i = 1
    while i < len(alvos):
        argv.append(alvos[i])
        i += 1
    # daqui não se volta: o processo é o programa
    os.exec(argv)
    return 127

async def cmd_dev(alvos: list<str>, jobs: int, query: str, verbose: bool) -> int:
    """`ppack dev [alvo]` — constrói, espera que alguma coisa mude, e constrói
    outra vez. Até alguém carregar em Ctrl-C.

    **A lista do que se vigia não é adivinhada**: é o GRAFO, que a recebeu do
    compilador (resposta 1). Um `dev` que vigiasse um diretório inteiro veria
    salvar de editor, arquivos temporários e o próprio `build/`; este vê
    exatamente os arquivos que a construção lê, e nada mais.

    **E não usa inotify nem kqueue**, o que é uma decisão e não uma falta. Os
    dois existem, são diferentes um do outro, e obrigariam a uma primitiva nova
    no runtime — para vigiar algumas centenas de arquivos cujas datas se leem em
    menos de um milissegundo. O laço pergunta a cada 200 ms; o custo não aparece
    num perfil e o código funciona em todo o lado igual. No dia em que a árvore
    for grande ao ponto de isto doer, a primitiva entra por baixo e este comando
    não muda.

    O que ele NÃO faz, e é a outra metade: reiniciar o programa. Matar e
    relançar um filho precisa de controlo de processo que o `os.run` não dá —
    ele espera. É uma primitiva a mais (`os.spawn` + `kill`), anotada e não
    feita."""
    g = await BP.montar(query)
    alvo = alvos[0] if len(alvos) > 0 else ""
    tl: list<str> = [alvo] if len(alvo) > 0 else []
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_erro)
    await B.build(g, LOG, tl, B.Opts(jobs, 1000000, False, False), rep)
    # o que vigiar: as ENTRADAS de todas as arestas, que é o que o compilador
    # disse que lê. Um arquivo que ainda não existe entra na mesma — passar a
    # existir é uma mudança como outra qualquer.
    vistos: dict<str, int> = {}
    alvos_v: list<str> = []
    for e in g.edges:
        for iid in e.ins:
            p = g.nodes[iid].p
            # o que a construção PRODUZ não se vigia. Um `.c` gerado é entrada
            # da compilação seguinte, então vigiá-lo faria a construção
            # disparar-se a si mesma para sempre — e foi exatamente o que ele
            # fez na primeira vez que correu.
            if p.startswith(BP.BUILD + "/") or p in vistos:
                continue
            vistos[p] = 1
            alvos_v.append(p)
    datas: dict<str, int> = {}
    for p2 in alvos_v:
        datas[p2] = path.getmtime_ns(p2) if path.isfile(p2) else 0
    print(f"dev: {len(alvos_v)} arquivo(s) vigiados. Ctrl-C para sair.")

    while True:
        await sleep(0.2)
        mudou: list<str> = []
        for p3 in alvos_v:
            agora = path.getmtime_ns(p3) if path.isfile(p3) else 0
            if agora != datas.get(p3, 0):
                datas[p3] = agora
                mudou.append(p3)
        if len(mudou) == 0:
            continue
        # um `salvar` de editor escreve o arquivo em dois tempos (temporário +
        # rename), e há editores que tocam vários de seguida. Esperar um pouco
        # depois da primeira mudança junta tudo numa construção só.
        await sleep(0.15)
        for p4 in alvos_v:
            agora2 = path.getmtime_ns(p4) if path.isfile(p4) else 0
            if agora2 != datas.get(p4, 0):
                datas[p4] = agora2
                if p4 not in mudou:
                    mudou.append(p4)
        print("")
        print("dev: mudou " + ", ".join(mudou[0:3]) + ("..." if len(mudou) > 3 else ""))
        g2 = await BP.montar(query)
        await B.build(g2, LOG, tl, B.Opts(jobs, 1000000, False, False), rep)
    return 0


async def cmd_verify(jobs: int, query: str, verbose: bool) -> int:
    """O `verify-all.sh` inteiro, como GRAFO. Os oito passos dele são
    sequenciais e levam o que levam os oito somados; aqui o que não depende um
    do outro roda junto, e o que não mudou não roda."""
    g = await BP.montar(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_erro)
    ok = await B.build(g, LOG, [BP.VERIFY], B.Opts(jobs, 1000000, False, False), rep)
    return 0 if ok else 1

async def cmd_test(jobs: int, query: str, verbose: bool) -> int:
    """As suítes. Duas diferenças de `build`, e as duas são deliberadas:

      * `-k` alto por padrão — quem roda teste quer o PLACAR inteiro, não a
        primeira falha. Um build para na primeira porque o resto ia falhar
        junto; uma suíte não;
      * o alvo é o carimbo da suíte, e ele não é o alvo padrão: construir não é
        testar, e um `ppack build` que rodasse trezentos casos seria um `build`
        que ninguém usaria."""
    g = await BP.montar(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_erro)
    ok = await B.build(g, LOG, [BP.TESTE], B.Opts(jobs, 1000000, False, False), rep)
    return 0 if ok else 1

async def cmd_explain(alvos: list<str>, query: str) -> int:
    g = await BP.montar(query)
    w = await B.why_dirty(g, LOG, alvos)
    if len(w) == 0:
        if saida_json:
            print('{"dirty": {}}')
        else:
            print("nada está sujo")
        return 0
    ks: list<str> = []
    for k in w:
        ks.append(k)
    ks = sorted(ks)
    if saida_json:
        partes: list<str> = []
        for k3 in ks:
            partes.append(G.jstr(k3) + ": " + G.jstr(w[k3]))
        print('{"dirty": {' + ", ".join(partes) + '}}')
        return 0
    for k2 in ks:
        print(k2 + ": " + w[k2])
    return 0

async def cmd_graph(query: str) -> int:
    g = await BP.montar(query)
    print(G.to_json(g).rstrip())
    return 0

# ---------- os pacotes ----------
private async def mundo() -> PK.Mundo:
    return await PK.ler_mundo(await BP.membros_do_workspace("pack.json"))

async def cmd_check(query: str) -> int:
    """`ppack check` — as invariantes que o build não confere porque não é
    trabalho dele.

    Duas, e as duas são sobre a mesma promessa: **P é livre de runtime, e
    continua a sê-lo através dos pacotes**.

      1. um pacote `lang: p` não depende de um pacote `pscript` (lido dos
         manifestos, de graça);
      2. e nenhum `.psc` aparece no FECHO do módulo-raiz de um pacote `p` —
         que é a mesma coisa dita onde ela realmente acontece, porque um
         `import` alcança mais longe do que um manifesto.

    O que NÃO é problema, e por isso não é conferido: um pacote P com testes em
    pscript. O `sha2` tem um, de propósito — é como se prova que a fronteira da
    45.5 funciona. Ele não está no fecho da raiz, e é por isso que a pergunta é
    sobre o FECHO e não sobre o diretório."""
    m = await mundo()
    problemas = PK.conferir_linguagens(m)
    raizes = await BP.raizes_do_workspace("pack.json")
    dcheck = path.join(BP.BUILD, "check")
    if not path.isdir(dcheck):
        os.makedirs(dcheck)
    for p in m.pacotes:
        if p.lang != "p":
            continue
        man = await MF.ler(path.join(p.dir, "pack.json"))
        if len(man.raiz) == 0:
            continue
        argv: list<str> = [query]
        for r in raizes:
            argv.append("--pkg-path")
            argv.append(r)
        argv.append("--deps")
        argv.append("--out-dir")
        argv.append(dcheck)
        argv.append(path.join(p.dir, man.raiz))
        res = await os.run(argv, stdout=path.join(dcheck, "deps.txt"))
        if res.status() != 0:
            # o compilador é o PRIMEIRO portão desta invariante: um `.ph` que
            # importe um módulo pscript ele já recusa. Quando isso acontece o
            # que interessa é o que ELE disse, não a nossa paráfrase.
            problemas.append(p.nome + ": o fecho de " + man.raiz + " não se deixou ler:\n       "
                             + res.output().strip().replace("\n", "\n       "))
            continue
        f = await open(path.join(dcheck, "deps.txt"), "r")
        txt = await f.text()
        await f.close()
        for ln in txt.split("\n"):
            if ln.endswith(".psc"):
                problemas.append(p.nome + " é `lang: p` e o fecho de " + man.raiz
                                 + " passa por " + ln + ", que é pscript")
    if saida_json:
        js: list<str> = []
        for pr in problemas:
            js.append(G.jstr(pr))
        print("[" + ", ".join(js) + "]")
        return 1 if len(problemas) > 0 else 0
    if len(problemas) == 0:
        print(f"check: {len(m.pacotes)} pacote(s), nenhum problema")
        return 0
    for pr in problemas:
        print("erro: " + pr)
    return 1


async def cmd_tree() -> int:
    """`ppack tree` — o que este projeto usa, e por dentro de quê."""
    m = await mundo()
    if len(m.pacotes) == 0:
        print("nenhum pacote: este projeto não tem `pack.json` de workspace, ou ele não lista membros")
        return 1
    if saida_json:
        partes: list<str> = []
        for p in m.pacotes:
            ds: list<str> = []
            i = 0
            while i < len(p.deps):
                ds.append('{"name": ' + G.jstr(p.deps[i]) + ', "range": ' + G.jstr(p.faixas[i]) + '}')
                i += 1
            partes.append('{"name": ' + G.jstr(p.nome) + ', "version": ' + G.jstr(p.versao)
                          + ', "lang": ' + G.jstr(p.lang) + ', "dir": ' + G.jstr(p.dir)
                          + ', "deps": [' + ", ".join(ds) + ']}')
        print('{"packages": [' + ", ".join(partes) + ']}')
        return 0
    print(PK.arvore(m).rstrip())
    if len(m.faltando) > 0:
        print("")
        for f in m.faltando:
            print("   FALTA: " + f)
        return 1
    return 0

async def cmd_why(alvos: list<str>) -> int:
    """`ppack why <pacote>` — quem o puxou.

    É a pergunta que todo lock grande acaba por provocar, e a resposta tem de
    dizer o CAMINHO e não só o nome: saber que `hash` está lá porque `map` o
    pediu, e `map` porque o compilador o pediu, é o que permite decidir o que
    fazer."""
    if len(alvos) == 0:
        print("uso: ppack why <pacote>")
        return 2
    alvo = alvos[0]
    m = await mundo()
    if m.acha(alvo) < 0:
        print("'" + alvo + "' não é um pacote deste workspace")
        return 1
    quem = m.quem_puxa(alvo)
    if saida_json:
        ns: list<str> = []
        for q in quem:
            ns.append(G.jstr(q))
        print('{"package": ' + G.jstr(alvo) + ', "pulled_by": [' + ", ".join(ns) + ']}')
        return 0
    p = m.pacotes[m.acha(alvo)]
    print(p.nome + " " + p.versao + "  (" + p.lang + ", em " + p.dir + ")")
    if len(quem) == 0:
        print("   ninguém o puxa: ele é um membro do workspace por si")
        return 0
    for q in quem:
        i = m.acha(q)
        faixa = ""
        j = 0
        while j < len(m.pacotes[i].deps):
            if m.pacotes[i].deps[j] == alvo:
                faixa = m.pacotes[i].faixas[j]
            j += 1
        print("   <- " + q + " pede " + faixa)
    return 0

# ---------- doc ----------
private async def modulo_do_pacote(alvo: str) -> str:
    """O módulo RAIZ de um pacote do workspace, se `alvo` for um nome de pacote.

    É para isto que o campo `root` do manifesto existe: a interface do pacote é
    UM módulo, e quem quer a documentação dele não tem de saber em que arquivo
    ela mora."""
    raizes = await BP.raizes_do_workspace("pack.json")
    for r in raizes:
        man = path.join(r, alvo, "pack.json")
        if path.isfile(man):
            m = await MF.ler(man)
            if len(m.raiz) == 0:
                return ""       # pacote sem raiz: quem chama LISTA os módulos
            return path.join(r, alvo, m.raiz)
    return ""


private async def lista_do_pacote(alvo: str) -> int:
    """Um pacote SEM raiz é um conjunto de módulos, e o que se mostra dele é a
    lista. O `stl` é assim: dez headers independentes, e eleger um como "a
    interface" seria arbitrário."""
    raizes = await BP.raizes_do_workspace("pack.json")
    for r in raizes:
        dir = path.join(r, alvo)
        if not path.isfile(path.join(dir, "pack.json")):
            continue
        m = await MF.ler(path.join(dir, "pack.json"))
        print("== " + alvo + " " + m.versao + "  (" + m.lang + ")")
        if len(m.descricao) > 0:
            print("   " + m.descricao)
        print("")
        for nome in sorted(os.listdir(dir)):
            if nome.endswith(".ph") or nome.endswith(".psc"):
                print("   " + alvo + "/" + nome)
        print("")
        print("   ppack doc " + alvo + "/<módulo> para a interface de um deles")
        return 0
    return 1

private def parede(t: str) -> str:
    """A docstring, indentada. Sem isto, uma docstring de várias linhas
    encosta na margem e some no meio da lista."""
    out = ""
    for l in t.split("\n"):
        out += "    " + l.rstrip() + "\n"
    return out.rstrip()

# ---------- o repositório ----------

private async def api_do_pacote(dir: str, m: MF.Manifesto, query: str,
                                api: dict<str, list<str>>, hashes: dict<str, str>):
    """A lista canónica de símbolos de cada módulo do pacote, no índice.

    Ela não é enfeite: é o que faz `ppack search draw_rect` procurar POR SÍMBOLO
    sem baixar nada, e o que torna a honestidade de semver verificável a partir
    do índice — a interface de 0.1.0 e a de 0.1.1 estão as duas lá, e comparar é
    uma subtração. E sai de graça, porque o compilador já a produz (resposta 5)."""
    mods: list<str> = []
    if len(m.raiz) > 0:
        mods.append(path.join(dir, m.raiz))
    else:
        # um pacote SEM raiz é um conjunto de módulos independentes (o `stl` é
        # assim): todos entram
        for nome in sorted(os.listdir(dir)):
            if nome.endswith(".ph") or nome.endswith(".psc"):
                mods.append(path.join(dir, nome))
    raizes = await BP.raizes_do_workspace("pack.json")
    for mod in mods:
        argv: list<str> = [query]
        for r in raizes:
            argv.append("--pkg-path")
            argv.append(r)
        argv.append("--api")
        argv.append(mod)
        res = await os.run(argv)
        if res.status() != 0:
            raise error("o compilador não conseguiu ler a interface de " + mod + ":\n" + res.output())
        for a in A.parse(res.output()):
            # SÓ os módulos DESTE pacote. A resposta 5 traz o fecho inteiro —
            # o `sha2` importa `stl/cstr.ph` e a interface do `stl` vinha junto —
            # e um índice que declarasse a interface dos outros diria que o
            # `sha2` oferece `CStr.slice`, que não é dele.
            if not a.caminho.startswith(dir + "/"):
                continue
            rel = a.caminho[len(dir) + 1:len(a.caminho)]
            simb: list<str> = []
            for sb in a.simbolos:
                simb.append(sb.linha)
            api[rel] = simb
            hashes[rel] = a.hash


async def cmd_keygen(alvos: list<str>) -> int:
    """`ppack keygen <arquivo>` — uma chave nova.

    Escreve a PRIVADA em `<arquivo>` (32 bytes em hexadecimal, e mais nada) e a
    PÚBLICA em `<arquivo>.pub`. A privada não vai para `build/`, não vai para o
    repositório e não é comitada: é a única coisa em todo este sistema que não se
    partilha. A pública é para pôr no índice e no lock, onde ela é vista por
    quem revisa."""
    if len(alvos) == 0:
        print("uso: ppack keygen <arquivo>")
        return 2
    alvo = alvos[0]
    if path.isfile(alvo):
        print(alvo + " já existe. Uma chave que se sobrescreve é uma chave perdida — apague-a à mão se é isso que quer.")
        return 1
    semente = await R.semente_nova()
    hexa = ""
    for b in semente:
        hexa += "0123456789abcdef"[int(b) >> 4] + "0123456789abcdef"[int(b) & 15]
    pub = R.chave_publica(semente)
    await R.escrever_bytes(alvo, R.bytes_de_texto(hexa + "\n"))
    await R.escrever_bytes(alvo + ".pub", R.bytes_de_texto(pub + "\n"))
    print("privada: " + alvo + "   (NÃO comitar, NÃO partilhar)")
    print("pública: " + alvo + ".pub")
    print("   " + pub)
    return 0


private async def repos_do_projeto() -> list<R.Repo>:
    """Os repositórios deste projeto, na ordem de busca."""
    out: list<R.Repo> = []
    if not path.isfile("pack.json"):
        return out
    m = await MF.ler("pack.json")
    i = 0
    while i < len(m.repos):
        out.append(R.repo(m.repos[i], m.repos_unsafe[i]))
        i += 1
    return out


private async def indice_guardado(r: R.Repo) -> R.Indice:
    alvo = path.join(R.dir_indices(), r.id + ".json")
    if not path.isfile(alvo):
        raise error("sem índice de " + r.url + " — rode `ppack update` primeiro", IO)
    f = await open(alvo, "r")
    raw = await f.text()
    await f.close()
    return R.ler_indice(raw, alvo)


async def cmd_update() -> int:
    """`ppack update` — baixa os índices e guarda-os. É a ÚNICA operação que
    toca a rede sem alguém a pedir um pacote, e é de propósito: um build que
    resolve versões pela rede é um build que muda de resultado sem que nada no
    projeto tenha mudado."""
    repos = await repos_do_projeto()
    if len(repos) == 0:
        print("nenhum repositório: acrescente \"repos\": [...] ao pack.json do workspace")
        return 1
    lk = await LK.ler("pack.lock")
    n = 0
    for r in repos:
        bs = await R.buscar(r, "index.json")
        sig = await R.assinatura_de(r, "index.json")
        i = lk.repo_conhecido(r.url)
        conhecida = lk.repos[i].chave if i >= 0 else ""
        # ---- a assinatura do REPOSITÓRIO, e o TOFU ----
        if len(conhecida) > 0:
            # já se conhece a chave: daqui para a frente ela NÃO muda em silêncio
            if not R.conferir(conhecida, bs, sig):
                print(f"{r.url}: o índice NÃO confere com a chave que este projeto aceitou.")
                print(f"   a chave está no pack.lock ({conhecida[0:16]}…) e passou por revisão de código quando lá entrou.")
                print("   ou o índice foi trocado, ou o repositório mudou de chave — nos dois casos isto para aqui.")
                return 1
        elif len(sig) > 0:
            # TOFU: primeira vez que se vê. A chave que assinou entra no LOCK, que
            # é COMITADO — é assim que a confiança fica versionada e uma troca
            # futura aparece num diff em vez de num aviso no terminal de uma
            # pessoa só. Não se sabe de quem é a chave; sabe-se que a partir de
            # agora tem de ser a mesma.
            achou = ""
            for nome in R.indice_chaves(R.ler_indice(str(bs), "índice")):
                if R.conferir(nome, bs, sig):
                    achou = nome
            if len(achou) == 0:
                print(f"{r.url}: o índice vem assinado, e a assinatura não bate com nenhuma chave que ele declara.")
                print("   isto não é uma chave desconhecida: é uma assinatura errada.")
                return 1
            if i >= 0:
                lk.repos[i].chave = achou
            else:
                lk.repos.append(LK.RepoConhecido(r.url, achou, R.agora_iso()[0:10]))
            print(f"   chave do repositório aceite agora (TOFU) e gravada no pack.lock: {achou[0:16]}…")
        else:
            if not r.inseguro:
                print(f"{r.url}: o índice NÃO vem assinado.")
                print("   um repositório sem assinatura tem de o dizer: {\"url\": ..., \"unsafe\": true} no pack.json.")
                return 1
            if i < 0:
                lk.repos.append(LK.RepoConhecido(r.url, "", R.agora_iso()[0:10]))
                print(f"   novo repositório, aceite agora (TOFU) e gravado no pack.lock: {r.url}")
            print("   UNSAFE: este repositório não assina o índice. O hash de cada pacote continua a ser conferido.")
        alvo = path.join(R.dir_indices(), r.id + ".json")
        await R.escrever_bytes(alvo, bs)
        ix = R.ler_indice(str(bs), alvo)
        quantos = 0
        for nome2 in ix.nomes():
            quantos += len(ix.versoes(nome2))
        print(f"{ix.nome if len(ix.nome) > 0 else r.url}: {len(ix.pacotes)} pacote(s), {quantos} versão(ões)")
        n += 1
    await LK.gravar(lk, "pack.lock")
    return 0 if n > 0 else 1


async def cmd_search(alvos: list<str>) -> int:
    """`ppack search <termo>` — OFFLINE, no índice guardado, e por SÍMBOLO
    também.

    Procurar por símbolo sem baixar nada é coisa que nenhum gerenciador faz, e
    aqui sai de graça: a lista canónica já está no índice porque o compilador já
    a produz. Cada linha diz de onde veio o acerto, que é o que permite entender
    por que um pacote apareceu."""
    if len(alvos) == 0:
        print("uso: ppack search <termo>")
        return 2
    termo = alvos[0].lower()
    repos = await repos_do_projeto()
    achou = 0
    jl: list<str> = []
    for r in repos:
        ix = await indice_guardado(r)
        for nome in ix.nomes():
            for versao in ix.versoes(nome):
                u = ix.pega(nome, versao)
                linhas: list<str> = []
                if termo in nome.lower():
                    linhas.append("[nome]     " + (u.descricao if len(u.descricao) > 0 else "—"))
                if termo in u.descricao.lower():
                    linhas.append("[descrição] " + u.descricao)
                mods: list<str> = []
                for mk in u.api:
                    mods.append(mk)
                for mod in sorted(mods):
                    for sb in u.api[mod]:
                        if termo in sb.lower():
                            linhas.append("[símbolo]  " + sb)
                for ln in linhas:
                    achou += 1
                    if saida_json:
                        k = ln.find("]")
                        jl.append('{"name": ' + G.jstr(nome) + ', "version": ' + G.jstr(versao)
                                  + ', "where": ' + G.jstr(ln[1:k]) + ', "text": ' + G.jstr(ln[k + 1:].strip())
                                  + ', "repo": ' + G.jstr(r.url) + '}')
                    else:
                        print(f"{nome} {versao}   {ln}")
    if saida_json:
        print("[" + ", ".join(jl) + "]")
        return 0 if achou > 0 else 1
    if achou == 0:
        print("nada encontrado para '" + alvos[0] + "'")
        return 1
    return 0


private def parte_em_arroba(spec: str) -> list<str>:
    i = spec.find("@")
    if i < 0:
        return [spec, ""]
    return [spec[0:i], spec[i + 1:len(spec)]]


async def cmd_add(alvos: list<str>, inseguro: bool) -> int:
    """`ppack add <nome>@<versão>` — escreve no manifesto e no lock.

    `add` e `build` são comandos diferentes DE PROPÓSITO: um mexe no manifesto e
    no lock, o outro compila. O diff do commit fica legível — duas linhas, uma em
    cada arquivo — em vez de "o build mudou o mundo e agora há vinte arquivos
    novos".

    As dependências do que se pede vêm JUNTO, e isto não é resolver versões: o
    índice traz a versão EXATA de cada uma, e o que se faz é segui-la. Quando
    duas exigências discordam, o resultado é uma mensagem — não uma busca."""
    if len(alvos) == 0:
        print("uso: ppack add <nome>@<versão> [--unsafe]")
        return 2
    pedido = parte_em_arroba(alvos[0])
    nome = pedido[0]
    versao = pedido[1]
    if len(versao) == 0:
        print("a v1 não tem resolvedor: a versão é EXATA — `ppack add " + nome + "@0.1.0`")
        return 2
    repos = await repos_do_projeto()
    lk = await LK.ler("pack.lock")
    fila: list<str> = [nome + "@" + versao]
    porque: dict<str, str> = {}
    postos: list<str> = []
    while len(fila) > 0:
        atual = parte_em_arroba(fila[0])
        fila = fila[1:len(fila)]
        n = atual[0]
        v = atual[1]
        ja = lk.acha(n)
        if ja >= 0 and lk.pacotes[ja].versao == v:
            continue
        if ja >= 0 and n == nome:
            # o pacote PEDIDO na linha de comando pode trocar de versão: é
            # exatamente isso que `ppack add x@0.2.0` e `ppack up` querem dizer.
            # O que continua a ser conflito é uma DEPENDÊNCIA discordar do que já
            # está travado — aí ninguém escolheu, e escolher por conta própria
            # seria a decisão que a v1 não toma.
            novo: list<LK.Travado> = []
            for t9 in lk.pacotes:
                if t9.nome != n:
                    novo.append(t9)
            lk.pacotes = novo
        elif ja >= 0:
            quem = porque[n] if n in porque else "pedido na linha de comando"
            print(f"conflito em {n}: o lock tem {lk.pacotes[ja].versao} e {quem} pede {v}.")
            print("a v1 não busca uma versão que sirva às duas — resolva à mão, subindo uma das pontas")
            return 1
        achou = False
        for r in repos:
            ix = await indice_guardado(r)
            if not ix.tem(n, v):
                continue
            u = ix.pega(n, v)
            bs = await R.buscar(r, u.arquivo)
            sha = R.hash_de(bs)
            if sha != u.sha256:
                print(f"o hash NÃO bate para {n}@{v}:")
                print(f"   o índice diz {u.sha256}")
                print(f"   o que chegou {sha}")
                return 1
            # a assinatura do AUTOR, que é a que impede o próprio repositório de
            # servir um tarball que o autor não fez. O HASH já foi conferido
            # acima e é conferido SEMPRE — "unsafe" quer dizer que ninguém
            # assinou, e não que o conteúdo não é olhado.
            sem_assinatura = len(u.autor) == 0
            if not sem_assinatura:
                asg = await R.assinatura_de(r, u.arquivo)
                if not R.conferir(u.autor, bs, asg):
                    print(f"{n}@{v}: o índice diz que isto foi assinado por {u.autor[0:16]}…, e a assinatura não confere.")
                    return 1
            elif not (inseguro or r.inseguro):
                print(f"{n}@{v} não vem assinado.")
                print("   ou `--unsafe` neste comando, ou o repositório declarado `unsafe` no pack.json —")
                print("   as duas formas gravam `\"unsafe\": true` no lock, para quem revisa o PR ver.")
                return 1
            await R.escrever_bytes(path.join(R.dir_paks(), sha), bs)
            lk.pacotes.append(LK.Travado(n, v, sha, r.url, u.arquivo,
                                         sem_assinatura, u.toolchain))
            if lk.repo_conhecido(r.url) < 0:
                lk.repos.append(LK.RepoConhecido(r.url, "", R.agora_iso()[0:10]))
            postos.append(n + " " + v + "  sha256 " + sha[0:16] + "…")
            for d in u.deps:
                porque[d.nome] = n + "@" + v
                fila.append(d.nome + "@" + d.faixa)
            achou = True
            break
        if not achou:
            print(f"não achei {n}@{v} em nenhum índice guardado — `ppack update` primeiro?")
            if n != nome:
                print(f"   (é dependência de {porque[n] if n in porque else nome})")
            return 1
    await LK.gravar(lk, "pack.lock")
    await escrever_dep_no_manifesto(nome, versao)
    if saida_json:
        jadd: list<str> = []
        for t2 in lk.pacotes:
            jadd.append('{"name": ' + G.jstr(t2.nome) + ', "version": ' + G.jstr(t2.versao)
                      + ', "sha256": ' + G.jstr(t2.sha256) + ', "repo": ' + G.jstr(t2.repo)
                      + ', "unsafe": ' + ("true" if t2.inseguro else "false") + '}')
        print('{"asked": ' + G.jstr(nome + "@" + versao) + ', "locked": [' + ", ".join(jadd) + ']}')
        return 0
    for linha in postos:
        print(linha)
    if len(postos) > 1:
        print(f"   {len(postos) - 1} vieram como dependência; `ppack why <nome>` diz de quem")
    print("   `ppack install` para os materializar")
    return 0


private async def escrever_dep_no_manifesto(nome: str, versao: str):
    """A dependência entra no `pack.json` do workspace, à mão e preservando o
    resto do arquivo. Reescrever o JSON inteiro a partir da estrutura perderia
    a formatação de quem o escreveu e reordenaria tudo — um gerenciador que
    estraga o arquivo de quem o usa é um gerenciador de que se desconfia.

    Um nome que já lá está é SUBSTITUÍDO e não repetido: `{"tar": "0.1.0",
    "tar": "0.2.0"}` é um objeto com a mesma chave duas vezes, que cada leitor
    de JSON resolve à sua maneira."""
    f = await open("pack.json", "r")
    raw = await f.text()
    await f.close()
    linha = "    " + G.jstr(nome) + ": " + G.jstr(versao)
    alvo = G.jstr(nome) + ":"
    if "\"deps\"" in raw:
        i = raw.find("\"deps\"")
        j = raw.find("{", i)
        if j < 0:
            raise error("pack.json: `deps` tem de ser um objeto", VALUE)
        k = raw.find("}", j)
        dentro = raw[j + 1:k]
        # o nome já está lá? troca-se a linha dele, e mais nada
        p0 = dentro.find(alvo)
        if p0 >= 0:
            ini = 0
            for z in range(p0):
                if dentro[z] == "\n":
                    ini = z + 1
            fim = dentro.find("\n", p0)
            if fim < 0:
                fim = len(dentro)
            virg = "," if dentro[ini:fim].rstrip().endswith(",") else ""
            raw = raw[0:j + 1] + dentro[0:ini] + linha + virg + dentro[fim:] + raw[k:]
        elif len(dentro.strip()) == 0:
            raw = raw[0:j] + "{\n" + linha + "\n  }" + raw[k + 1:len(raw)]
        else:
            raw = raw[0:j] + "{" + dentro.rstrip() + ",\n" + linha + "\n  }" + raw[k + 1:len(raw)]
    else:
        i2 = raw.rfind("}")
        antes = raw[0:i2].rstrip()
        if antes.endswith(","):
            antes = antes[0:len(antes) - 1]
        raw = antes + ",\n  \"deps\": {\n" + linha + "\n  }\n}\n"
    await R.escrever_bytes("pack.json", R.bytes_de_texto(raw))


async def cmd_up(alvos: list<str>, inseguro: bool) -> int:
    """`ppack up [<nome>]` — sobe para a versão mais alta que o índice conhece.

    Sem resolvedor não há "a versão que serve a todos": há a mais alta que
    existe, e a decisão de a tomar é de quem escreve o comando. Por isso `up` é
    um comando e não um efeito de `install` — subir de versão é uma escolha, e
    uma escolha que acontece sozinha é uma escolha que ninguém reviu.

    Ele mexe no manifesto e no lock, como o `add`, e não constrói nada."""
    if not path.isfile("pack.json"):
        print("não há pack.json aqui")
        return 1
    m = await MF.ler("pack.json")
    if not m.eh_workspace or len(m.deps) == 0:
        print("o pack.json deste projeto não pede dependência nenhuma")
        return 1
    repos = await repos_do_projeto()
    quais: list<str> = []
    for d in m.deps:
        if len(alvos) == 0 or d.nome in alvos:
            quais.append(d.nome)
    if len(quais) == 0:
        print("'" + alvos[0] + "' não é uma dependência deste projeto")
        return 1
    for nome in quais:
        atual = ""
        for d2 in m.deps:
            if d2.nome == nome:
                atual = d2.faixa
        melhor = ""
        for r in repos:
            ix = await indice_guardado(r)
            for v in ix.versoes(nome):
                if len(melhor) == 0 or MF.versao_maior(v, melhor):
                    melhor = v
        if len(melhor) == 0:
            print(nome + ": não está em nenhum índice guardado — `ppack update` primeiro?")
            continue
        if melhor == atual:
            print(nome + " " + atual + " já é a mais alta que o índice tem")
            continue
        print(nome + ": " + atual + " -> " + melhor)
        rc = await cmd_add([nome + "@" + melhor], inseguro)
        if rc != 0:
            return rc
    return 0


private async def lock_vs_manifesto(lk: LK.Lock) -> list<str>:
    """O que o `pack.json` pede e o `pack.lock` tem — e a diferença entre os
    dois, dita em linhas.

    Um lock que não corresponde ao manifesto é a fonte de "na minha máquina
    funciona": alguém acrescentou uma dependência, esqueceu-se de comitar o
    lock, e o build do outro instala outra coisa. Aqui isso é uma LISTA, que o
    `install` imprime e o `--frozen` recusa."""
    out: list<str> = []
    if not path.isfile("pack.json"):
        return out
    m = await MF.ler("pack.json")
    if not m.eh_workspace:
        return out
    for d in m.deps:
        i = lk.acha(d.nome)
        if i < 0:
            out.append("+ " + d.nome + "@" + d.faixa + " (o manifesto pede, o lock não tem)")
        elif lk.pacotes[i].versao != d.faixa:
            out.append("~ " + d.nome + ": o lock tem " + lk.pacotes[i].versao + ", o manifesto pede " + d.faixa)
    return out


async def cmd_install(frozen: bool) -> int:
    """`ppack install` — materializa o que o lock diz.

    O que ele NÃO faz é decidir: as versões já estão decididas, no lock. Ele
    baixa o que falta, confere o hash SEMPRE, e abre a árvore em
    `build/pkg/<nome>-<versão>-<hash>/`. O hash no nome é o que torna "a mesma
    versão com conteúdo diferente" impossível de confundir."""
    lk = await LK.ler("pack.lock")
    # o lock e o manifesto têm de contar a mesma história. Um `install` que
    # instalasse o lock velho em silêncio é a fonte do "na minha máquina
    # funciona": alguém acrescentou uma dependência e não comitou o lock.
    difs = await lock_vs_manifesto(lk)
    if len(difs) > 0:
        if frozen:
            print("o lock não corresponde ao pack.json, e `--frozen` não deixa arrumá-lo:")
            for dd in difs:
                print("   " + dd)
            print("rode `ppack add <nome>@<versão>` e comite o pack.lock")
            return 1
        print("o lock não corresponde ao pack.json:")
        for dd2 in difs:
            print("   " + dd2)
        print("   (`ppack add <nome>@<versão>` acerta-o; `--frozen` recusa em vez de avisar)")
    if len(lk.pacotes) == 0:
        # também aqui: quem pediu JSON recebe JSON. Uma frase em português no
        # meio de um fluxo de objetos é o que faz um consumidor estourar longe
        # do sítio onde o problema está.
        if saida_json:
            print("[]")
            return 0
        print("o lock não tem pacotes: `ppack add <nome>@<versão>` primeiro")
        return 0
    repos = await repos_do_projeto()
    n = 0
    ji: list<str> = []
    for t in lk.pacotes:
        destino = R.dir_do_pacote(t.nome, t.versao, t.sha256)
        if path.isdir(path.join(destino, t.nome)):
            continue
        pak = path.join(R.dir_paks(), t.sha256)
        bs: list<u8> = []
        if path.isfile(pak):
            bs = await R.ler_bytes(pak)
        else:
            achou = False
            for r in repos:
                if r.url != t.repo:
                    continue
                bs = await R.buscar(r, t.arquivo)
                achou = True
            if not achou:
                print(f"{t.nome}: o lock diz que veio de {t.repo}, e esse repositório não está no pack.json")
                return 1
            await R.escrever_bytes(pak, bs)
        sha = R.hash_de(bs)
        if sha != t.sha256:
            print(f"o hash NÃO bate para {t.nome}@{t.versao}: o lock diz {t.sha256}, o que há diz {sha}")
            return 1
        quantos = await R.extrair_pacote(bs, destino, t.nome)
        if saida_json:
            ji.append('{"name": ' + G.jstr(t.nome) + ', "version": ' + G.jstr(t.versao)
                      + ', "dir": ' + G.jstr(destino) + ', "files": ' + str(quantos)
                      + ', "unsafe": ' + ("true" if t.inseguro else "false") + '}')
        else:
            print(f"{t.nome} {t.versao}  {quantos} arquivo(s) em {destino}")
            if t.inseguro:
                print("   (unsafe: sem assinatura — o hash bateu)")
        n += 1
    if saida_json:
        print("[" + ", ".join(ji) + "]")
        return 0
    if n == 0:
        print("nada a instalar: tudo o que o lock diz já está aberto")
    return 0


async def cmd_publish(alvos: list<str>, para: str, chave: str, query: str) -> int:
    """`ppack publish <pacote> --to <dir>` — o `.tar`, o hash e a entrada no
    índice, no repositório local do autor.

    Ele NÃO ENVIA NADA, e isso é a consequência direta de um repositório ser um
    formato: enviar é `rsync`, `scp` ou `git push`, e nenhuma dessas é coisa que
    um gerenciador de pacotes tenha de reimplementar mal.

    O que ele confere antes de escrever:

      * o manifesto é válido (nome, versão, campos);
      * a versão AINDA NÃO EXISTE no índice — uma versão publicada é imutável, e
        essa é a regra que faz um lock com hash valer alguma coisa;
      * a interface bate com o que vai declarar (é o compilador que a dá).

    O que ele NÃO faz é rodar os testes: publicar e testar são decisões
    diferentes, e juntá-las faria `publish` falhar por razões que não são sobre
    publicar."""
    if len(alvos) == 0:
        print("uso: ppack publish <pacote> [--to <dir>]")
        return 2
    if len(para) == 0:
        print("ppack publish precisa de um repositório de destino: --to <dir>")
        return 2
    alvo = alvos[0]
    dir = ""
    for r in await BP.raizes_do_workspace("pack.json"):
        cand = path.join(r, alvo)
        if path.isfile(path.join(cand, "pack.json")):
            dir = cand
            break
    if len(dir) == 0 and path.isfile(path.join(alvo, "pack.json")):
        dir = alvo
    if len(dir) == 0:
        print("não achei o pacote '" + alvo + "' (nem no workspace, nem como diretório)")
        return 1
    m = await MF.ler(path.join(dir, "pack.json"))
    if m.eh_workspace:
        print(dir + "/pack.json é um workspace, não um pacote")
        return 1
    if len(m.nome) == 0 or len(m.versao) == 0:
        print(dir + "/pack.json: um pacote publicado precisa de `name` e `version`")
        return 1

    ixp = path.join(para, "index.json")
    ix = R.indice_novo(path.basename(para))
    if path.isfile(ixp):
        f = await open(ixp, "r")
        ix = R.ler_indice(await f.text(), ixp)
        await f.close()
    if ix.tem(m.nome, m.versao):
        print(f"{m.nome}@{m.versao} já está publicado em {para} — uma versão publicada é IMUTÁVEL.")
        print("suba a versão no pack.json, ou apague a entrada do índice se ela nunca saiu daqui")
        return 1

    bs = await R.empacotar(dir, m.nome + "-" + m.versao)
    sha = R.hash_de(bs)
    rel = "pkg/" + m.nome + "/" + m.nome + "-" + m.versao + ".tar"
    await R.escrever_bytes(path.join(para, rel), bs)

    u = R.vazia()
    u.nome = m.nome
    u.versao = m.versao
    u.arquivo = rel
    u.tamanho = len(bs)
    u.sha256 = sha
    u.autor = ""
    u.lang = m.lang
    u.raiz = m.raiz
    u.deps = m.deps
    u.toolchain = m.toolchain
    u.descricao = m.descricao
    await api_do_pacote(dir, m, query, u.api, u.api_hash)
    if m.nome not in ix.pacotes:
        vazio: dict<str, R.Versao> = {}
        ix.pacotes[m.nome] = vazio
    assinado = False
    if len(chave) > 0:
        # a assinatura do AUTOR vai ao lado do tarball, e a chave que a fez vai
        # no índice: quem confere não precisa de a ir buscar a lado nenhum
        semente = await R.ler_semente(chave)
        u.autor = R.chave_publica(semente)
        await R.escrever_bytes(path.join(para, rel + ".sig"),
                               R.bytes_de_texto(R.assinar(semente, bs) + "\n"))
        assinado = True
    ix.pacotes[m.nome][m.versao] = u
    ix.atualizado = R.agora_iso()
    texto_ix = R.escrever_indice(ix)
    await R.escrever_bytes(ixp, R.bytes_de_texto(texto_ix))
    if len(chave) > 0:
        # ... e a do REPOSITÓRIO cobre o índice inteiro, que é o que impede uma
        # lista velha de ser servida como se fosse a de agora
        semente2 = await R.ler_semente(chave)
        await R.escrever_bytes(ixp + ".sig",
                               R.bytes_de_texto(R.assinar(semente2, R.bytes_de_texto(texto_ix)) + "\n"))

    if saida_json:
        print('{"name": ' + G.jstr(m.nome) + ', "version": ' + G.jstr(m.versao)
              + ', "file": ' + G.jstr(path.join(para, rel)) + ', "sha256": ' + G.jstr(sha)
              + ', "size": ' + str(len(bs)) + '}')
        return 0
    print(f"{m.nome} {m.versao} -> {path.join(para, rel)}")
    print(f"   sha256 {sha}")
    print(f"   {len(bs)} bytes, {len(u.api)} módulo(s) de interface no índice")
    if assinado:
        print("   assinado por " + u.autor[0:16] + "… (o tarball e o índice)")
    else:
        print("   SEM ASSINATURA: isto só serve para um repositório declarado `unsafe`.")
        print("   `ppack keygen <arquivo>` e depois `--key <arquivo>` para assinar.")
    return 0


async def cmd_doc(alvos: list<str>, query: str) -> int:
    """`ppack doc` — a documentação no TERMINAL, do que já existe.

    Nada é construído e nada é gerado: a fonte é a resposta 5 do compilador
    (`--api`), que já traz a interface canónica e as docstrings. É o que o
    `go doc` acertou — offline, sem site, sem serviço — e aqui sai de graça
    porque o formato já estava lá."""
    if len(alvos) == 0:
        print("uso: ppack doc <arquivo|pacote> [símbolo]")
        return 2
    alvo = alvos[0]
    if not path.isfile(alvo):
        p2 = await modulo_do_pacote(alvo)
        if len(p2) == 0:
            # pode ser um pacote SEM raiz (um conjunto de módulos), e aí o que
            # se mostra é a lista deles
            if len(alvos) == 1 and await lista_do_pacote(alvo) == 0:
                return 0
            print("não achei '" + alvo + "': nem arquivo, nem pacote do workspace")
            return 1
        alvo = p2
    r = await os.run([query, "--api", alvo])
    if r.status() != 0:
        print(r.output().rstrip())
        return 1
    mods = A.parse(r.output())
    if len(mods) == 0:
        print("o compilador não devolveu interface nenhuma para '" + alvo + "'")
        return 1
    m = mods[0]
    if len(alvos) > 1:
        i = m.acha(alvos[1])
        if i < 0:
            print("'" + alvos[1] + "' não está na interface de " + m.caminho)
            return 1
        s = m.simbolos[i]
        if saida_json:
            print('{"path": ' + G.jstr(m.caminho) + ', "name": ' + G.jstr(s.nome)
                  + ', "decl": ' + G.jstr(s.linha) + ', "doc": ' + G.jstr(s.doc) + '}')
            return 0
        if len(s.linha) > 0:
            print(s.linha)
        else:
            print(s.nome)
        if len(s.doc) > 0:
            print(parede(s.doc))
        return 0
    if saida_json:
        simbs: list<str> = []
        for s3 in m.simbolos:
            simbs.append('{"decl": ' + G.jstr(s3.linha) + ', "name": ' + G.jstr(s3.nome)
                         + ', "doc": ' + G.jstr(s3.doc) + '}')
        print('{"path": ' + G.jstr(m.caminho) + ', "hash": ' + G.jstr(m.hash)
              + ', "doc": ' + G.jstr(m.doc) + ', "symbols": [' + ", ".join(simbs) + ']}')
        return 0
    print("== " + m.caminho + "  [" + m.hash + "]")
    if len(m.doc) > 0:
        print(parede(m.doc))
        print("")
    for s2 in m.simbolos:
        if len(s2.linha) == 0:
            continue
        print(s2.linha)
        if len(s2.doc) > 0:
            print(parede(s2.doc))
    return 0

async def cmd_ninja(alvos: list<str>, query: str) -> int:
    """A exportação para ninja (ver `lib_ninja.psc`): o bootstrap numa máquina
    que ainda não tem `ppack`, e o `compile_commands.json` de graça
    (`ninja -t compdb`). Sem argumento sai na saída padrão, para se poder
    conferir antes de escrever."""
    g = await BP.montar(query)
    txt = N.emit(g)
    if len(alvos) == 0 or alvos[0] == "-":
        print(txt.rstrip())
        return 0
    f = await open(alvos[0], "w")
    await f.write(txt)
    await f.close()
    print("escrito:", alvos[0], "(" + str(len(g.edges)), "arestas)")
    return 0

async def cmd_clean() -> int:
    """A vassoura: apaga o que o build PRODUZIU e mantém o que ele BAIXOU.

    A linha é a origem: `build/pkg` (os índices, os tarballs e as árvores
    abertas) veio de fora, e voltar a baixá-lo custa rede e tempo para nada — e
    risco nenhum, porque o `pack.lock` tem o hash de tudo. Para apagar isso
    também há `make clean-all`, que é o que se faz para provar que um checkout
    limpo constrói."""
    n = 0
    if path.isdir("build"):
        for nome in sorted(os.listdir("build")):
            if nome == "pkg":
                continue          # o que veio de fora fica; ver a docstring
            d = path.join("build", nome)
            if path.isdir(d):
                n += rmtree(d)
            else:
                os.remove(d)
                n += 1
    print("apagados:", n, "arquivo(s)")
    return 0

def rmtree(d: str) -> int:
    n = 0
    for name in os.listdir(d):
        p = path.join(d, name)
        if path.isdir(p):
            n += rmtree(p)
        else:
            os.remove(p)
            n += 1
    os.rmdir(d)
    return n

def uso():
    print("uso: ppack <build|test|verify|run|doc|tree|why|explain|graph|ninja|clean|help> [alvo...] [-j N] [-k N] [-n] [--query <plangc>]")
    print("     ppack check                          as invariantes que o build não confere")
    print("     ppack dev [alvo]                     constrói quando alguma coisa muda, até ao Ctrl-C")
    print("     ppack keygen <arquivo>               uma chave nova (privada + .pub)")
    print("     ppack publish <pacote> --to <dir> [--key <arquivo>]")
    print("                                          o .tar, o hash, o índice e as duas assinaturas")
    print("     ppack update                         baixa os índices dos repositórios do projeto")
    print("     ppack search <termo>                 procura nome, descrição e SÍMBOLO, offline")
    print("     ppack add <nome>@<versão> [--unsafe] escreve no manifesto e no lock")
    print("     ppack up [<nome>]                    sobe para a versão mais alta que o índice tem")
    print("     ppack install [--frozen]             materializa o que o lock diz (--frozen: CI, recusa se ele estiver velho)")

async def main() -> int:
    args = sys.argv[1:]
    if len(args) == 0:
        uso()
        return 2
    global saida_json
    cmd = args[0]
    alvos: list<str> = []
    jobs = os.nproc()
    keep = 1
    dry = False
    verbose = False
    # o compilador que responde ao protocolo. O padrão não é um nome fixo: é o
    # melhor que existir na árvore, do mais adiantado para o mais atrasado. Um
    # padrão apontando para um caminho que o build já não produz é uma armadilha
    # que só aparece muito depois, com uma mensagem que não fala do problema.
    para = ""
    chave = ""
    inseguro = False
    frozen = False
    query = ""
    for cand in ["build/bin/plangc_s2", "build/bin/plangc_s1", "build/bin/plangc_seed", "./plangc"]:
        if path.isfile(cand):
            query = cand
            break
    if query == "":
        query = "build/bin/plangc_seed"
    i = 1
    # tudo depois de `--` é do PROGRAMA, não nosso. Sem isto, `ppack run p
    # --version` engoliria o `--version` como opção do ppack — e um `run` que
    # não sabe passar argumentos não serve para nada.
    resto: list<str> = []
    j = 1
    while j < len(args):
        if args[j] == "--":
            k = j + 1
            while k < len(args):
                resto.append(args[k])
                k += 1
            novos: list<str> = []
            m = 0
            while m < j:
                novos.append(args[m])
                m += 1
            args = novos
            break
        j += 1
    while i < len(args):
        a = args[i]
        if a == "-j" and i + 1 < len(args):
            i += 1
            jobs = int(args[i])
        elif a == "-k" and i + 1 < len(args):
            i += 1
            keep = int(args[i])
        elif a == "-n" or a == "--dry-run":
            dry = True
        elif a == "-v":
            verbose = True
        elif a == "--json":
            saida_json = True
        elif a == "--query" and i + 1 < len(args):
            i += 1
            query = args[i]
        elif a == "--unsafe":
            inseguro = True
        elif a == "--frozen":
            frozen = True
        elif a == "--to" and i + 1 < len(args):
            i += 1
            para = args[i]
        elif a == "--key" and i + 1 < len(args):
            i += 1
            chave = args[i]
        elif a.startswith("-"):
            print("opção desconhecida:", a)
            return 2
        else:
            alvos.append(a)
        i += 1
    if cmd == "build":
        return await cmd_build(alvos, jobs, keep, dry, query, verbose)
    if cmd == "test":
        return await cmd_test(jobs, query, verbose)
    if cmd == "verify":
        return await cmd_verify(jobs, query, verbose)
    if cmd == "dev":
        return await cmd_dev(alvos, jobs, query, verbose)
    if cmd == "run":
        for x in resto:
            alvos.append(x)
        return await cmd_run(alvos, jobs, query, verbose)
    if cmd == "explain":
        return await cmd_explain(alvos, query)
    if cmd == "graph":
        return await cmd_graph(query)
    if cmd == "ninja":
        return await cmd_ninja(alvos, query)
    if cmd == "doc":
        return await cmd_doc(alvos, query)
    if cmd == "publish":
        return await cmd_publish(alvos, para, chave, query)
    if cmd == "keygen":
        return await cmd_keygen(alvos)
    if cmd == "update":
        return await cmd_update()
    if cmd == "search":
        return await cmd_search(alvos)
    if cmd == "add":
        return await cmd_add(alvos, inseguro)
    if cmd == "install":
        return await cmd_install(frozen)
    if cmd == "up":
        return await cmd_up(alvos, inseguro)
    if cmd == "tree":
        return await cmd_tree()
    if cmd == "check":
        return await cmd_check(query)
    if cmd == "why":
        return await cmd_why(alvos)
    if cmd == "clean":
        return await cmd_clean()
    if cmd == "help":
        uso()
        return 0
    print("comando desconhecido:", cmd)
    uso()
    return 2

sys.exit(await main())
