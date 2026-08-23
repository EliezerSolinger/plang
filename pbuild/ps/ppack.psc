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
import <pbuild/lib_graph.psc> as G
import <pbuild/lib_build.psc> as B
import <pbuild/lib_targets.psc> as T
import <pbuild/lib_ninja.psc> as N
import <pbuild/lib_api.psc> as A
import <pbuild/lib_manifest.psc> as MF
import <pbuild/lib_pkg.psc> as PK
import build_plang as BP
import <pbuild/lib_repo.psc> as R
import <pbuild/lib_lock.psc> as LK

const LOG: str = "build/log/build.log"

feitas: int = 0
total_arestas: int = 0
falhou: bool = False

def on_plan(total: int):
    """Um plano novo é uma construção nova, e o relatório recomeça com ele.

    Isto não é higiene: o `ppack dev` e o `--repro` constroem duas ou vinte
    vezes no MESMO processo, e um contador que não recomeçasse diria `[64/61]`
    na segunda — um número maior que o total, que é a forma mais rápida de
    fazer alguém desconfiar de um relatório inteiro."""
    global total_arestas
    global feitas
    global falhou
    global rotulos
    global placar_ok
    global placar_mal
    total_arestas = total
    feitas = 0
    falhou = False
    # um literal vazio precisa de tipo, e é bom que precise: `= {}` calado num
    # global já tipado seria a mesma forma para duas intenções diferentes
    rot0: dict<int, str> = {}
    ok0: dict<str, int> = {}
    mal0: dict<str, list<str>> = {}
    rotulos = rot0
    placar_ok = ok0
    placar_mal = mal0
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

# o compilador que RESPONDE, guardado aqui porque os comandos do repositório
# precisam dele para uma pergunta só (a versão da linguagem, contra a faixa de
# toolchain) e passá-lo por seis assinaturas para isso seria pior
query_atual: str = ""


def query_global() -> str:
    return query_atual

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

async def cmd_build(alvos: list<str>, jobs: int, keep: int, dry: bool, query: str,
                    verbose: bool, repro: bool) -> int:
    g = await BP.montar(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_erro)
    ok = await B.build(g, LOG, alvos, B.Opts(jobs, keep, dry, False), rep)
    if not ok or dry or not repro:
        return 0 if ok else 1
    return await confere_repro(g, alvos, jobs, keep, query, rep)


const REPRO: str = "build/repro"

private async def confere_repro(g: G.Graph, alvos: list<str>, jobs: int, keep: int,
                                query: str, rep: B.Rep) -> int:
    """`--repro`: constrói duas vezes e compara byte a byte.

    O `verify-all` já fazia isto à mão para o compilador (`diff -rq out2 out3`,
    e o ponto fixo do QBE); aqui vira comando, e passa a valer para qualquer
    projeto e qualquer alvo.

    A segunda construção começa do ZERO — as saídas e o log do build saem da
    frente —, porque uma segunda corrida incremental não prova nada: ela não
    roda aresta nenhuma. O que se compara é o conteúdo, nunca a data: um build
    reprodutível pode muito bem escrever o mesmo byte num segundo diferente.

    O que a primeira construção fez é **movido** para `build/repro/`, e não
    copiado. A diferença importa por duas razões, e a segunda custou uma árvore
    a descobrir: mover preserva o arquivo como ele é (a permissão de execução
    inclusive, que uma cópia byte a byte pela linguagem perderia), e permite
    **pôr tudo de volta** quando a segunda construção falha — que é justamente
    quando não há artefato novo nenhum para ficar no lugar.

    O grafo da segunda construção monta-se antes de mover o que quer que seja:
    montá-lo é PERGUNTAR ao compilador, e o compilador é uma das saídas.

    O limite honesto disto está medido e escrito: o P e o pscript que geramos
    não têm data nem caminho absoluto no que emitem, então são reprodutíveis por
    construção; um pacote em C que use `__DATE__`/`__TIME__` não é, e a resposta
    do mundo para isso (`SOURCE_DATE_EPOCH`) é a que se adota no dia em que
    aparecer."""
    saidas: list<str> = []
    for e in g.edges:
        if not e.want:
            continue
        for oid in e.outs:
            pth = g.nodes[oid].p
            if path.isfile(pth):
                saidas.append(pth)
    if len(saidas) == 0:
        print("--repro: a construção não produziu arquivo nenhum para comparar")
        return 0
    if path.isdir(REPRO):
        rmtree(REPRO)
    g2 = await BP.montar(query)
    for p1 in saidas:
        guarda = path.join(REPRO, p1)
        d = path.dirname(guarda)
        if len(d) > 0 and not path.isdir(d):
            os.makedirs(d)
        os.rename(p1, guarda)
    if path.isfile(LOG):
        os.remove(LOG)
    print("--repro: " + str(len(saidas)) + " saída(s) de lado; construindo outra vez do zero")
    if not await B.build(g2, LOG, alvos, B.Opts(jobs, keep, False, False), rep):
        for p9 in saidas:
            if not path.isfile(p9):
                d9 = path.dirname(p9)
                if len(d9) > 0 and not path.isdir(d9):
                    os.makedirs(d9)
                os.rename(path.join(REPRO, p9), p9)
        rmtree(REPRO)
        print("--repro: a segunda construção FALHOU — e uma construção que só")
        print("         funciona na primeira vez é o defeito mais caro que existe.")
        print("         o que a primeira tinha produzido está de volta no lugar.")
        return 1
    difs: list<str> = []
    for p3 in saidas:
        if not path.isfile(p3):
            difs.append(p3 + "  (a segunda construção não o produziu)")
            continue
        h1 = R.hash_de(await R.ler_bytes(path.join(REPRO, p3)))
        h2 = R.hash_de(await R.ler_bytes(p3))
        if h1 != h2:
            difs.append(p3 + "  " + h1[0:16] + "… -> " + h2[0:16] + "…")
    if saida_json:
        jd: list<str> = []
        for d0 in difs:
            jd.append(G.jstr(d0))
        print('{"outputs": ' + str(len(saidas)) + ', "reproducible": '
              + ("true" if len(difs) == 0 else "false") + ', "differ": [' + ", ".join(jd) + ']}')
    if len(difs) == 0:
        rmtree(REPRO)
        if not saida_json:
            print("--repro: as duas construções deram os MESMOS bytes em " + str(len(saidas)) + " arquivo(s)")
        return 0
    if not saida_json:
        print("--repro: " + str(len(difs)) + " de " + str(len(saidas)) + " arquivo(s) NÃO saíram iguais:")
        for d2 in difs:
            print("   " + d2)
        print("   a primeira construção está guardada em " + REPRO + "/, para comparar")
    return 1


async def cmd_run(alvos: list<str>, jobs: int, query: str, verbose: bool, builddir: str) -> int:
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
        raiz = BP.raiz_de_script(alvo, builddir)
        pronto = await BP.run_manifesto_ok(alvo, raiz)
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
        alvo = await BP.programa_solto(g, query, alvo, BP.raiz_de_script(alvo, builddir))
    else:
        g = await BP.montar(query)
        if alvo not in g.by_path and solto:
            alvo = await BP.programa_solto(g, query, alvo, BP.raiz_de_script(alvo, builddir))
        elif alvo not in g.by_path:
            print("não achei '" + alvo + "' — nem alvo do descritor, nem arquivo")
            return 1
    if not await B.build(g, LOG, [alvo], B.Opts(jobs, 1, False, False), rep):
        return 101
    if solto:
        await BP.run_manifesto_grava(alvos[0], alvo, g, BP.raiz_de_script(alvos[0], builddir))
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
    # o programa, quando o alvo é um: lançado agora e relançado a cada mudança
    pid = 0
    if len(alvo) > 0 and path.isfile(alvo):
        pid = os.spawn([alvo if alvo.startswith("/") else path.join(os.getcwd(), alvo)])
        print("dev: lancei " + alvo + " (pid " + str(pid) + ")")
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
        # o programa antigo sai ANTES de o novo ser construído: ele está a usar
        # o binário que a construção vai reescrever
        if pid > 0:
            os.kill(pid)
            esperas = 0
            while os.alive(pid) and esperas < 100:
                await sleep(0.05)
                esperas += 1
            pid = 0
        g2 = await BP.montar(query)
        ok2 = await B.build(g2, LOG, tl, B.Opts(jobs, 1000000, False, False), rep)
        if ok2 and len(alvo) > 0 and path.isfile(alvo):
            pid = os.spawn([alvo if alvo.startswith("/") else path.join(os.getcwd(), alvo)])
            print("dev: relancei (pid " + str(pid) + ")")
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
    # 2.7: a dependência de SISTEMA é DECLARAÇÃO no manifesto, e o `pkg-config`
    # é um dos resolvedores dela. Quem o chama somos nós, nunca o pacote — a
    # lista de programas que estas ferramentas invocam é FIXA (`plangc`, `cc`,
    # `pkg-config`) e não é extensível por um pacote de terceiro. Aqui a
    # declaração passa a valer alguma coisa antes de o build começar: se a
    # biblioteca não está nesta máquina, diz-se agora e com o nome dela.
    for p2 in m.pacotes:
        man2 = await MF.ler(path.join(p2.dir, "pack.json"))
        for sd in man2.system:
            r2 = await os.run(["pkg-config", "--exists", sd.nome])
            if r2.status() != 0:
                problemas.append(p2.nome + " declara a biblioteca de sistema `" + sd.nome
                                 + "` e o `pkg-config` não a acha nesta máquina")
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


private async def versao_do_compilador(query: str) -> str:
    """A versão da LINGUAGEM que este compilador aceita — `plangc 0.1.0 (hash)`.

    É a pergunta 4 do protocolo, e é a única coisa que a faixa de toolchain de
    um manifesto tem contra o que comparar.

    Num projeto que CONSOME pacotes não há `build/bin/plangc_s2`: o compilador
    dele está instalado, no PATH. Por isso a segunda tentativa é `plangc` sem
    caminho — e se nem isso houver, devolve-se vazio e quem chama DIZ que não
    conferiu. Um portão que se desliga em silêncio é pior do que não existir."""
    for cand in [query, "plangc"]:
        if len(cand) == 0:
            continue
        r = await os.run([cand, "--version"])
        if r.status() == 0:
            partes = r.output().strip().split(" ")
            if len(partes) > 1:
                return partes[1]
    return ""


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


private async def travar(lk: LK.Lock, pedidos: list<str>, trocaveis: list<str>,
                        inseguro: bool, postos: list<str>) -> int:
    """A resolução, que é a mesma para `add` e para `lock`: seguir a fila de
    pedidos, buscar cada um no índice guardado, conferir hash e assinatura,
    guardar o tarball no armazém e travar a linha no lock.

    Ela NÃO escreve o lock nem o manifesto — quem chama decide isso. Devolve 0,
    ou o código de saída do problema que a fez parar; `postos` recebe uma linha
    por pacote que entrou.

    `trocaveis` são os nomes que PODEM mudar de versão: o que se pediu na linha
    de comando. Uma DEPENDÊNCIA que discorda do que já está travado continua a
    ser conflito — aí ninguém escolheu, e escolher por conta própria seria a
    decisão que a v1 não toma."""
    repos = await repos_do_projeto()
    vcomp = await versao_do_compilador(query_global())
    if len(vcomp) == 0:
        print("aviso: não achei um `plangc` para perguntar a versão — a faixa de toolchain não foi conferida")
        print("       (`--query <caminho>`, ou ponha o `plangc` no PATH)")
    fila: list<str> = []
    for pd in pedidos:
        fila.append(pd)
    porque: dict<str, str> = {}
    while len(fila) > 0:
        atual = parte_em_arroba(fila[0])
        fila = fila[1:len(fila)]
        n = atual[0]
        v = atual[1]
        ja = lk.acha(n)
        if ja >= 0 and lk.pacotes[ja].versao == v:
            continue
        if ja >= 0 and n in trocaveis:
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
            # a FAIXA DE TOOLCHAIN, conferida antes de gastar um segundo a
            # compilar. A mensagem que sai daqui — "o pacote foo exige plangc
            # >= X, o seu é Y" — é a melhor que existe para este problema; a
            # alternativa é um erro de sintaxe a meio de um módulo que usa uma
            # coisa que ainda não existe.
            if len(vcomp) > 0:
                mau = MF.toolchain_ok(u.toolchain, vcomp)
                if len(mau) > 0:
                    print(n + "@" + v + " " + mau)
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
            if n in porque:
                print(f"   (é dependência de {porque[n]})")
            return 1
    return 0


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
    lk = await LK.ler("pack.lock")
    postos: list<str> = []
    rc = await travar(lk, [nome + "@" + versao], [nome], inseguro, postos)
    if rc != 0:
        return rc
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


async def cmd_lock(frozen: bool, inseguro: bool) -> int:
    """`ppack lock` — põe o `pack.lock` de acordo com o `pack.json`, e mais nada.

    É o comando que faltava entre `add` (que muda o que se pede) e `install`
    (que materializa o que já está decidido): aqui não se pede nada de novo nem
    se abre árvore nenhuma — refaz-se o lock a partir do manifesto.

    Ele **recomeça** em vez de remendar, e isso é o que o torna exato: o lock
    passa a ser o fecho do que o `pack.json` pede, e o que já ninguém puxa sai
    dele sozinho. O que sobrevive é a secção dos repositórios — as chaves
    aceites por TOFU não são um resultado da resolução, são a confiança que este
    projeto já reviu, e recomeçar isso seria aceitar de novo o que já foi aceite
    uma vez.

    Nada disto toca a rede: o tarball de cada versão já está no armazém, com o
    hash conferido, e o índice é o que o último `ppack update` guardou.

    Com `--frozen` ele não escreve: diz o que mudaria e sai com 1, que é o que
    um CI quer — "o lock que está comitado não é o que este manifesto pede"."""
    if not path.isfile("pack.json"):
        print("não há pack.json aqui")
        return 1
    m = await MF.ler("pack.json")
    velho = await LK.ler("pack.lock")
    difs = await lock_vs_manifesto(velho)
    if frozen:
        if len(difs) == 0:
            if saida_json:
                print('{"changed": false}')
            else:
                print("o pack.lock corresponde ao pack.json")
            return 0
        print("o lock não corresponde ao pack.json, e `--frozen` não deixa arrumá-lo:")
        for d0 in difs:
            print("   " + d0)
        print("rode `ppack lock` e comite o pack.lock")
        return 1
    novo = await LK.ler("pack.lock")
    novo.pacotes = []
    pedidos: list<str> = []
    trocaveis: list<str> = []
    for d in m.deps:
        pedidos.append(d.nome + "@" + d.faixa)
        trocaveis.append(d.nome)
    postos: list<str> = []
    rc = await travar(novo, pedidos, trocaveis, inseguro, postos)
    if rc != 0:
        return rc
    if len(novo.pacotes) == 0 and not path.isfile("pack.lock"):
        # um projeto sem dependência de fora não precisa de lock, e criar um
        # arquivo vazio só para o comando ter feito alguma coisa é ruído num
        # diretório que alguém vai comitar
        if saida_json:
            print('{"changed": false, "locked": []}')
        else:
            print("este projeto não pede dependência nenhuma: não há o que travar")
        return 0
    await LK.gravar(novo, "pack.lock")
    linhas: list<str> = []
    for t in novo.pacotes:
        i = velho.acha(t.nome)
        if i < 0:
            linhas.append("+ " + t.nome + " " + t.versao)
        elif velho.pacotes[i].versao != t.versao:
            linhas.append("~ " + t.nome + " " + velho.pacotes[i].versao + " -> " + t.versao)
        elif velho.pacotes[i].sha256 != t.sha256:
            linhas.append("~ " + t.nome + " " + t.versao + " (outro conteúdo)")
    for t2 in velho.pacotes:
        if novo.acha(t2.nome) < 0:
            linhas.append("- " + t2.nome + " " + t2.versao + " (ninguém o pede)")
    if saida_json:
        jl: list<str> = []
        for t3 in novo.pacotes:
            jl.append('{"name": ' + G.jstr(t3.nome) + ', "version": ' + G.jstr(t3.versao)
                      + ', "sha256": ' + G.jstr(t3.sha256) + '}')
        print('{"changed": ' + ("true" if len(linhas) > 0 else "false")
              + ', "locked": [' + ", ".join(jl) + ']}')
        return 0
    if len(linhas) == 0:
        print("o pack.lock já correspondia ao pack.json (" + str(len(novo.pacotes)) + " pacote(s))")
        return 0
    for l2 in linhas:
        print(l2)
    print("   `ppack install` para os materializar")
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
    vcomp = await versao_do_compilador(query_global())
    if len(vcomp) == 0 and not saida_json:
        print("aviso: não achei um `plangc` para perguntar a versão — a faixa de toolchain não foi conferida")
    n = 0
    ji: list<str> = []
    for t in lk.pacotes:
        if len(vcomp) > 0:
            mau = MF.toolchain_ok(t.toolchain, vcomp)
            if len(mau) > 0:
                print(t.nome + "@" + t.versao + " " + mau)
                return 1
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


private def partes_da_versao(v: str) -> list<int>:
    ps = v.split(".")
    out: list<int> = []
    for i in range(3):
        out.append(int(ps[i]) if i < len(ps) else 0)
    return out


private def psc_fora_do_teste(dir: str, rel: str, achados: list<str>):
    """Um `.psc` dentro de um pacote declarado `p`, sem contar o que está em
    `test/`.

    A exceção do teste não é conveniência: um pacote em P pode muito bem ser
    exercitado a partir do pscript — é assim que o `sha2` prova que atravessa a
    fronteira dos 45.5 — e o teste não faz parte da interface que alguém importa.
    O que não pode é um MÓDULO do pacote ser pscript quando o manifesto diz que
    ele é P: quem o importar como P recebe um erro que não fala do problema."""
    for nome in sorted(os.listdir(dir)):
        cheio = path.join(dir, nome)
        se_rel = nome if len(rel) == 0 else rel + "/" + nome
        if path.isdir(cheio):
            if nome == "test" and len(rel) == 0:
                continue
            psc_fora_do_teste(cheio, se_rel, achados)
        elif nome.endswith(".psc"):
            achados.append(se_rel)


private async def recusas_de_publish(ix: R.Indice, m: MF.Manifesto, dir: str,
                                     u: R.Versao) -> list<str>:
    """Os três casos em que publicar seria publicar uma coisa que não serve.

    Nenhum deles precisa de mecanismo novo — é essa a razão de existirem: o
    índice já traz as dependências, o manifesto já diz a linguagem, e a lista
    canónica da API já está calculada para entrar no índice. Conferir é
    comparar.

      1. **uma dependência que o destino não resolve.** Publica-se um tarball
         que só se constrói na máquina do autor, onde a dependência é membro do
         workspace. Quem o instalar depois recebe "não achei foo@0.1.0" — longe
         daqui, e sem saber que foi aqui que se decidiu.

      2. **um `.psc` num pacote declarado `p`** (fora de `test/`).

      3. **a versão subiu e a interface não bate com o que a subida promete.**
         Um `patch` diz "nada mudou na interface" e um `minor` diz "só
         acrescentei" — as duas coisas são verificáveis a partir do índice, e é
         por isso que a lista canónica da API está lá."""
    maus: list<str> = []
    for d in m.deps:
        if ix.tem(d.nome, d.faixa):
            continue
        maus.append("a dependência " + d.nome + "@" + d.faixa
                    + " não está neste repositório — publique-a primeiro")
    if m.lang == "p":
        achados: list<str> = []
        psc_fora_do_teste(dir, "", achados)
        for a in achados:
            maus.append(a + " é pscript, e o manifesto declara `\"lang\": \"p\"`")
    anterior = ""
    for v in ix.versoes(m.nome):
        if len(anterior) == 0 or MF.versao_maior(v, anterior):
            anterior = v
    if len(anterior) == 0:
        return maus
    va = partes_da_versao(anterior)
    vn = partes_da_versao(m.versao)
    if vn[0] != va[0]:
        return maus                      # major: pode mudar o que quiser
    ant = ix.pega(m.nome, anterior)
    if vn[1] == va[1]:
        # patch: a interface tem de ser a MESMA, módulo a módulo
        for mod in sorted_keys(u.api_hash):
            if mod not in ant.api_hash:
                maus.append("o módulo " + mod + " é novo, e " + m.versao
                            + " só sobe o `patch` de " + anterior)
            elif ant.api_hash[mod] != u.api_hash[mod]:
                maus.append("a interface de " + mod + " mudou, e " + m.versao
                            + " só sobe o `patch` de " + anterior)
        for mod2 in sorted_keys(ant.api_hash):
            if mod2 not in u.api_hash:
                maus.append("o módulo " + mod2 + " saiu, e " + m.versao
                            + " só sobe o `patch` de " + anterior)
        return maus
    # minor: pode ACRESCENTAR, e mais nada
    mods_ant: list<str> = []
    for k3 in ant.api:
        mods_ant.append(k3)
    for mod3 in sorted(mods_ant):
        if mod3 not in u.api:
            maus.append("o módulo " + mod3 + " saiu, e " + m.versao
                        + " sobe o `minor` de " + anterior + " (minor acrescenta, não tira)")
            continue
        agora: list<str> = u.api[mod3]
        for linha in ant.api[mod3]:
            if linha not in agora:
                maus.append("`" + linha + "` saiu de " + mod3 + ", e " + m.versao
                            + " sobe o `minor` de " + anterior + " (minor acrescenta, não tira)")
    return maus


private def sorted_keys(d: dict<str, str>) -> list<str>:
    ks: list<str> = []
    for k in d:
        ks.append(k)
    return sorted(ks)


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

    u = R.vazia()
    u.nome = m.nome
    u.versao = m.versao
    u.autor = ""
    u.lang = m.lang
    u.raiz = m.raiz
    u.deps = m.deps
    u.toolchain = m.toolchain
    u.descricao = m.descricao
    await api_do_pacote(dir, m, query, u.api, u.api_hash)
    # a RECUSA acontece antes de um byte ser escrito. Um repositório com um
    # tarball a mais e nenhuma entrada no índice é um repositório que ninguém
    # sabe consertar.
    maus = await recusas_de_publish(ix, m, dir, u)
    if len(maus) > 0:
        print(dir + "/pack.json: error: isto não pode ser publicado assim:")
        for mm in maus:
            print("   " + mm)
        return 1
    bs = await R.empacotar(dir, m.nome + "-" + m.versao)
    sha = R.hash_de(bs)
    rel = "pkg/" + m.nome + "/" + m.nome + "-" + m.versao + ".tar"
    await R.escrever_bytes(path.join(para, rel), bs)
    u.arquivo = rel
    u.tamanho = len(bs)
    u.sha256 = sha
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


private def esc_html(t: str) -> str:
    out = ""
    for c in t:
        if c == "&":
            out += "&amp;"
        elif c == "<":
            out += "&lt;"
        elif c == ">":
            out += "&gt;"
        elif c == "\"":
            out += "&quot;"
        else:
            out += c
    return out


const CSS: str = """
:root { --fg:#1b1b1b; --bg:#fdfdfc; --dim:#6a6a68; --acc:#7a3b12; --line:#e3e0da;
        --code:#f4f2ee; }
@media (prefers-color-scheme: dark) {
  :root { --fg:#e6e4df; --bg:#1a1a19; --dim:#9a9894; --acc:#e0a06a; --line:#33322f;
          --code:#232322; }
}
* { box-sizing: border-box; }
body { margin:0; padding:2rem 1.25rem 4rem; background:var(--bg); color:var(--fg);
       font: 15px/1.65 -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
       max-width: 52rem; margin-inline: auto; }
a { color: var(--acc); text-decoration: none; }
a:hover { text-decoration: underline; }
h1 { font-size: 1.45rem; margin: 0 0 .2rem; }
h2 { font-size: 1.05rem; margin: 2rem 0 .5rem; padding-bottom:.3rem;
     border-bottom: 1px solid var(--line); }
.sub { color: var(--dim); margin: 0 0 1.6rem; }
.hash { font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
        font-size: .8rem; color: var(--dim); }
pre, code { font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace; }
.decl { background: var(--code); border-left: 3px solid var(--acc);
        padding: .45rem .7rem; margin: 1.1rem 0 .35rem; overflow-x: auto;
        white-space: pre; font-size: .88rem; }
.doc { margin: 0 0 .2rem .75rem; white-space: pre-wrap; color: var(--fg); }
ul.mods { list-style: none; padding: 0; }
ul.mods li { padding: .25rem 0; border-bottom: 1px solid var(--line); }
ul.mods li span { color: var(--dim); float: right; font-size: .85rem; }
footer { margin-top: 3rem; color: var(--dim); font-size: .82rem;
         border-top: 1px solid var(--line); padding-top: .8rem; }
"""


private def pagina(titulo: str, corpo: str, subida: str) -> str:
    """A moldura de uma página. Uma folha de estilo INLINE, e não um arquivo ao
    lado: uma pasta de documentação que se copia para outro lado e continua a
    ver-se bem vale mais que uma que economiza dois quilobytes."""
    return ("<!doctype html>\n<html lang=\"pt\">\n<meta charset=\"utf-8\">\n"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            + "<title>" + esc_html(titulo) + "</title>\n<style>" + CSS + "</style>\n"
            + corpo
            + "\n<footer>gerado por <code>ppack doc --html</code>"
            + (" · <a href=\"" + subida + "\">índice</a>" if len(subida) > 0 else "")
            + "</footer>\n</html>\n")


private async def argv_api(caminho: str, query: str) -> list<str>:
    """`--api` com as RAÍZES DE PACOTE, que é o que faz a pergunta funcionar num
    módulo que importa `<pkg/mod.ph>`.

    Sem elas o compilador responde "não achei `<stl/cstr.ph>`" e a documentação
    de meio workspace fica de fora — em silêncio, porque um módulo que não
    responde parece um módulo sem interface."""
    argv: list<str> = [query, "--api"]
    raizes = await BP.raizes_do_workspace("pack.json")
    for ri in R.raizes_instaladas():
        raizes.append(ri)
    for r in raizes:
        argv.append("--pkg-path")
        argv.append(r)
    argv.append(caminho)
    return argv


private async def api_de(caminho: str, query: str) -> list<A.Api>:
    r = await os.run(await argv_api(caminho, query))
    if r.status() != 0:
        return []
    return A.parse(r.output())


private def nome_de_arquivo(rel: str) -> str:
    out = ""
    for c in rel:
        out += "-" if (c == "/" or c == "\\") else c
    return out + ".html"


async def cmd_doc_html(alvos: list<str>, destino: str, query: str) -> int:
    """`ppack doc --html <pasta>` — o mesmo conteúdo do terminal, como site.

    A fonte é a MESMA resposta 5 do compilador que o `ppack doc` já lê; o que
    muda é para onde ela é escrita. É a razão de isto sair barato e de não poder
    divergir: não há um segundo leitor da linguagem, há um segundo renderizador
    da mesma lista canónica.

    Sem alvo, documenta o workspace inteiro — cada pacote e cada módulo dele. O
    resultado é uma pasta de arquivos estáticos: sem serviço, sem rede, sem
    JavaScript. Abre-se com dois cliques e copia-se para qualquer lado."""
    mods: list<str> = []
    rotulo: dict<str, str> = {}
    if len(alvos) > 0:
        for a in alvos:
            if path.isfile(a):
                mods.append(a)
                rotulo[a] = a
                continue
            raiz = await modulo_do_pacote(a)
            if len(raiz) > 0:
                mods.append(raiz)
                rotulo[raiz] = a
                continue
            achou = False
            for r0 in await BP.raizes_do_workspace("pack.json"):
                d0 = path.join(r0, a)
                if not path.isfile(path.join(d0, "pack.json")):
                    continue
                achou = True
                for nm in sorted(os.listdir(d0)):
                    if nm.endswith(".ph") or nm.endswith(".psc"):
                        mods.append(path.join(d0, nm))
                        rotulo[path.join(d0, nm)] = a + "/" + nm
            if not achou:
                print("não achei '" + a + "': nem arquivo, nem pacote do workspace")
                return 1
    else:
        for membro in await BP.membros_do_workspace("pack.json"):
            man = path.join(membro, "pack.json")
            if not path.isfile(man):
                continue
            m = await MF.ler(man)
            if len(m.raiz) > 0:
                mods.append(path.join(membro, m.raiz))
                rotulo[path.join(membro, m.raiz)] = m.nome
                continue
            for nm2 in sorted(os.listdir(membro)):
                if nm2.endswith(".ph") or nm2.endswith(".psc"):
                    mods.append(path.join(membro, nm2))
                    rotulo[path.join(membro, nm2)] = m.nome + "/" + nm2
    if len(mods) == 0:
        print("não há módulo nenhum para documentar")
        return 1
    if not path.isdir(destino):
        os.makedirs(destino)
    linhas: list<str> = []
    escritos = 0
    simbolos = 0
    for md in mods:
        apis = await api_de(md, query)
        if len(apis) == 0:
            print("aviso: o compilador não devolveu interface para " + md)
            continue
        api = apis[0]
        rot = rotulo[md] if md in rotulo else md
        arq = nome_de_arquivo(rot)
        corpo = "<h1>" + esc_html(rot) + "</h1>\n<p class=\"sub\">" + esc_html(api.caminho)
        corpo += " · <span class=\"hash\">" + esc_html(api.hash) + "</span></p>\n"
        if len(api.doc) > 0:
            corpo += "<p class=\"doc\">" + esc_html(api.doc) + "</p>\n"
        n = 0
        for sb in api.simbolos:
            if len(sb.linha) == 0:
                continue
            n += 1
            corpo += "<div class=\"decl\">" + esc_html(sb.linha) + "</div>\n"
            if len(sb.doc) > 0:
                corpo += "<p class=\"doc\">" + esc_html(sb.doc) + "</p>\n"
        if n == 0:
            corpo += "<p class=\"sub\">este módulo não declara nada público</p>\n"
        await R.escrever_bytes(path.join(destino, arq),
                               R.bytes_de_texto(pagina(rot, corpo, "index.html")))
        linhas.append("<li><a href=\"" + esc_html(arq) + "\">" + esc_html(rot)
                      + "</a> <span>" + str(n) + " símbolo(s)</span></li>")
        escritos += 1
        simbolos += n
    idx = "<h1>documentação</h1>\n<p class=\"sub\">" + str(escritos) + " módulo(s), "
    idx += str(simbolos) + " símbolo(s)</p>\n<ul class=\"mods\">\n"
    idx += "\n".join(linhas) + "\n</ul>\n"
    await R.escrever_bytes(path.join(destino, "index.html"),
                           R.bytes_de_texto(pagina("documentação", idx, "")))
    if saida_json:
        print('{"dir": ' + G.jstr(destino) + ', "modules": ' + str(escritos)
              + ', "symbols": ' + str(simbolos) + '}')
        return 0
    print(str(escritos) + " módulo(s), " + str(simbolos) + " símbolo(s) -> "
          + path.join(destino, "index.html"))
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
    r = await os.run(await argv_api(alvo, query))
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
    print("     --build-dir <dir>                    onde o build de um script SOLTO sai")
    print("                                          (padrão: ao lado do script)")
    print("     ppack check                          as invariantes que o build não confere")
    print("     ppack dev [alvo]                     constrói quando alguma coisa muda, até ao Ctrl-C")
    print("     ppack keygen <arquivo>               uma chave nova (privada + .pub)")
    print("     ppack publish <pacote> --to <dir> [--key <arquivo>]")
    print("                                          o .tar, o hash, o índice e as duas assinaturas")
    print("     ppack update                         baixa os índices dos repositórios do projeto")
    print("     ppack search <termo>                 procura nome, descrição e SÍMBOLO, offline")
    print("     ppack add <nome>@<versão> [--unsafe] escreve no manifesto e no lock")
    print("     ppack up [<nome>]                    sobe para a versão mais alta que o índice tem")
    print("     ppack doc --html <pasta> [alvo...]    o mesmo conteúdo como site estático")
    print("     ppack build --repro [alvo]           constrói duas vezes, do zero, e compara byte a byte")
    print("     ppack lock [--frozen]                refaz o pack.lock a partir do pack.json, sem construir")
    print("     ppack install [--frozen]             materializa o que o lock diz (--frozen: CI, recusa se ele estiver velho)")

async def main() -> int:
    args = sys.argv[1:]
    if len(args) == 0:
        uso()
        return 2
    global saida_json
    global query_atual
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
    repro = False
    html = ""
    builddir = ""
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
        elif a == "--repro":
            repro = True
        elif a == "--html" and i + 1 < len(args):
            i += 1
            html = args[i]
        elif a == "--build-dir" and i + 1 < len(args):
            i += 1
            builddir = args[i]
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
    query_atual = query
    if cmd == "build":
        return await cmd_build(alvos, jobs, keep, dry, query, verbose, repro)
    if cmd == "test":
        return await cmd_test(jobs, query, verbose)
    if cmd == "verify":
        return await cmd_verify(jobs, query, verbose)
    if cmd == "dev":
        return await cmd_dev(alvos, jobs, query, verbose)
    if cmd == "run":
        for x in resto:
            alvos.append(x)
        return await cmd_run(alvos, jobs, query, verbose, builddir)
    if cmd == "explain":
        return await cmd_explain(alvos, query)
    if cmd == "graph":
        return await cmd_graph(query)
    if cmd == "ninja":
        return await cmd_ninja(alvos, query)
    if cmd == "doc":
        if len(html) > 0:
            return await cmd_doc_html(alvos, html, query)
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
    if cmd == "lock":
        return await cmd_lock(frozen, inseguro)
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
