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
import build_plang as BP

const LOG: str = "build/log/build.log"

feitas: int = 0
total_arestas: int = 0
falhou: bool = False

def on_plan(total: int):
    global total_arestas
    total_arestas = total
    if total == 0:
        print("nada a fazer")

rotulos: dict<int, str> = {}

def on_start(id: int, what: str):
    global rotulos
    rotulos[id] = what

def on_end(id: int, st: int, out: str, ms: int):
    global feitas
    global falhou
    feitas += 1
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
    print("erro:", msg)

def on_done(ok: bool, fails: int):
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
    """Constrói o alvo e roda-o. O status de saída é o DELE; um build que falha
    sai com 101 (a convenção do cargo), para que um script saiba distinguir "o
    programa recusou" de "o programa nem chegou a existir".

    **Limite conhecido, dito de frente:** o programa roda como FILHO e a saída
    dele volta capturada, em vez de ele SUBSTITUIR este processo (`exec`). Para
    um programa que só imprime dá no mesmo; para um que lê do teclado ou pinta a
    tela, não dá. O `exec` depende de uma função nova na camada de sistema do
    pscript (`os.exec`), que é decisão de linguagem e está anotada no plano."""
    if len(alvos) == 0:
        print("uso: ppack run <alvo> [args...]")
        return 2
    alvo = alvos[0]
    g = await BP.montar(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_erro)
    if not await B.build(g, LOG, [alvo], B.Opts(jobs, 1, False, False), rep):
        return 101
    argv: list<str> = [alvo if alvo.startswith("/") else path.join(os.getcwd(), alvo)]
    i = 1
    while i < len(alvos):
        argv.append(alvos[i])
        i += 1
    r = await os.run(argv)
    saida = r.output()
    if len(saida) > 0:
        print(saida.rstrip())
    return r.status()

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
    ok = await B.build(g, LOG, [BP.SUITE_PSCRIPT], B.Opts(jobs, 1000000, False, False), rep)
    return 0 if ok else 1

async def cmd_explain(alvos: list<str>, query: str) -> int:
    g = await BP.montar(query)
    w = await B.why_dirty(g, LOG, alvos)
    if len(w) == 0:
        print("nada está sujo")
        return 0
    ks: list<str> = []
    for k in w:
        ks.append(k)
    for k2 in sorted(ks):
        print(k2 + ": " + w[k2])
    return 0

async def cmd_graph(query: str) -> int:
    g = await BP.montar(query)
    print(G.to_json(g).rstrip())
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
    """A vassoura: apaga o que o build produziu e MANTÉM o que ele baixou
    (`build/pkg`), porque baixar de novo custa rede para nada."""
    n = 0
    for d in ["build/obj", "build/bin", "build/log", "build/s1", "build/s2", "build/s3", "build/stamp"]:
        if path.isdir(d):
            n += rmtree(d)
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
    print("uso: ppack <build|test|verify|run|explain|graph|ninja|clean|help> [alvo...] [-j N] [-k N] [-n] [--query <plangc>]")

async def main() -> int:
    args = sys.argv[1:]
    if len(args) == 0:
        uso()
        return 2
    cmd = args[0]
    alvos: list<str> = []
    jobs = os.nproc()
    keep = 1
    dry = False
    verbose = False
    query = "./plangc"
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
        elif a == "--query" and i + 1 < len(args):
            i += 1
            query = args[i]
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
    if cmd == "clean":
        return await cmd_clean()
    if cmd == "help":
        uso()
        return 0
    print("comando desconhecido:", cmd)
    uso()
    return 2

sys.exit(await main())
