"""O DESCRITOR deste repositório: o build do plang, como programa.

Este é o arquivo que o `pbuild/DESIGN.md` chama de "a metade que ninguém pode
copiar de fora" — a que sabe a escada, as listas de módulos e os arreios. O
motor é genérico; isto é específico, e é por isso que ele existe.

**Começa pela ESCADA, e não por ela ser o mais bonito: por ser o mais difícil.**
Se a aresta gorda não expressar "a saída de uma etapa é a FERRAMENTA da
seguinte", o desenho está errado — e é melhor descobrir isso na primeira semana
do que na última. A escada é:

    bootstrap/*.c  --cc-->  plangc_seed
    fontes         --seed-->  s1/*.c  --cc-->  plangc_s1
    fontes         --s1-->    s2/*.c  --cc-->  plangc_s2
    fontes         --s2-->    s3/*.c
    s2/*.c == s3/*.c  (PONTO FIXO: o compilador reproduz a si mesmo)

O que faz isso funcionar no grafo é uma linha só: o compilador de cada etapa
entra como ENTRADA implícita das arestas que o usam. A partir daí o motor sabe,
sem que ninguém lhe conte, que mexer no compilador refaz tudo que ele gera.
"""
import os
import path
import lib_graph as G
import lib_targets as T
import lib_manifest as M
import lib_repo as R
import lib_api as A
import lib_doctest as DT

const BUILD: str = "build"

# o compilador do ponto fixo: o que a escada produz no segundo degrau, e o que
# todo o resto do repositório usa. É o mesmo que o `verify-all` usa para rodar
# as suítes, e por um motivo: é o primeiro binário da escada que já foi
# CONFERIDO contra si mesmo.
const PLANGC_S2: str = "build/bin/plangc_s2"

async def escada(c: T.Ctx) -> str:
    """A escada de bootstrap com ponto fixo. Devolve o carimbo do ponto fixo."""
    # 1) o seed: o C comitado, compilado pelo `cc` e mais nada. É a única coisa
    #    aqui que não depende de nós — é assim que o compilador nasce numa
    #    máquina que ainda não o tem.
    seed_srcs = T.glob("bootstrap/selfhost", ".c")
    seed = T.cc_program(c, path.join(BUILD, "bin/plangc_seed"), seed_srcs, [], [], [])

    # 2) as fontes do compilador, na ordem que o `--out-dir` espelha
    fontes: list<str> = []
    # o `stl` NÃO é nomeado: ele é um pacote (`packages/stl`), os fontes o
    # importam por `<stl/vec.ph>`, e o fecho da 1.5(a) traz os headers dele.
    # Era a maior das listas que este descritor carregava.
    for f2 in T.glob("selfhost", ".ph"):
        fontes.append(f2)
    for f3 in T.glob("selfhost", ".p"):
        fontes.append(f3)

    # 3) os três degraus. Cada um usa o compilador do anterior, e é ISSO que a
    #    entrada implícita expressa.
    c1 = T.derivar(c, BUILD, seed)
    s1all = await T.p_modules(c1, fontes, path.join(BUILD, "s1"), [])
    s1c = T.only(s1all, ".c")
    p1 = T.cc_program(c1, path.join(BUILD, "bin/plangc_s1"), s1c, T.only(s1all, ".h"), [], [])

    c2 = T.derivar(c, BUILD, p1)
    s2all = await T.p_modules(c2, fontes, path.join(BUILD, "s2"), [])
    s2c = T.only(s2all, ".c")
    p2 = T.cc_program(c2, path.join(BUILD, "bin/plangc_s2"), s2c, T.only(s2all, ".h"), [], [])

    c3 = T.derivar(c, BUILD, p2)
    s3all = await T.p_modules(c3, fontes, path.join(BUILD, "s3"), [])

    # 4) o PONTO FIXO: o que o s1 gerou e o que o s2 gerou têm de ser o mesmo
    #    texto. É o teste que diz que o compilador reproduz a si mesmo — e a
    #    razão de a escada ter três degraus e não dois.
    todos: list<str> = []
    for x in s2all:
        todos.append(x)
    for y in s3all:
        todos.append(y)
    stamp = path.join(BUILD, "stamp/fixpoint")
    T.compare_dirs(c, path.join(BUILD, "s2"), path.join(BUILD, "s3"), stamp, todos,
                   "ponto fixo: s2 == s3")

    # 5) o portão do typedef de libc. O `sema` canonicaliza no TAG de propósito
    #    (é assim que os back ends aprendem o layout), e quem tem de imprimir o
    #    typedef é o back end C. Em glibc a build passa dos dois jeitos, então o
    #    único teste possível é sobre o TEXTO do C gerado — e ele é pela
    #    negativa: estas quatro palavras não podem aparecer.
    tag = T.nao_acha(c, "_IO_FILE\\|__sFILE\\|_G_config\\|__gnuc_va_list", s2all,
                     path.join(BUILD, "stamp/sem-tag-libc"),
                     "sem tag interna de libc no C gerado")
    return T.junta(c, path.join(BUILD, "stamp/compilador"), [stamp, tag],
                   "o compilador confere a si mesmo")

# ---------- o que é escrito em pscript ----------
# O compilador é P; tudo o que está por cima dele é pscript, e todo programa em
# pscript deste repositório é construído da mesma forma: runtime a objeto uma
# vez, o programa a objeto, e um link. A lista mora aqui porque é o descritor
# que sabe o que existe — e é justamente a lista que hoje está espalhada por
# cinco arreios em shell.
struct Programa:
    nome: str
    fonte: str
    libs: list<str>

def programas() -> list<Programa>:
    return [
        # o próprio sistema de build, construído pelo sistema de build. Não é
        # exibicionismo: é o teste mais duro que existe para ele, porque uma
        # aresta errada aqui aparece na corrida seguinte.
        Programa("ppack", "pbuild/ps/ppack.psc", []),
        # o veredicto das suítes (ver `verdict.psc`)
        Programa("verdict", "pbuild/ps/verdict.psc", []),
        # a suíte do próprio motor
        Programa("pbuild-engine", "pbuild/ps/engine_test.psc", []),
    ]


async def pscript_tudo(c: T.Ctx) -> dict<str, str>:
    """Os programas em pscript, e o caminho de cada binário por nome."""
    out: dict<str, str> = {}
    for p in programas():
        out[p.nome] = await T.psc_program(c, p.fonte, path.join(BUILD, "bin", p.nome),
                                          path.join(BUILD, "obj"), [], p.libs)
    return out


# ---------- o editor ----------
# O `pstudio` é o único programa do repositório que mistura as três linguagens
# num binário só, e por isso é o que melhor prova a biblioteca de alvos: a
# lógica é pscript, a mão que toca o SDL2 e a que chama o lexer do compilador
# são P, e o SDL2 é C de fora, achado por `pkg-config`.
#
# A lista abaixo é a do `Makefile`, e é a última cópia dela: quando a troca
# acontecer (parte D), o alvo `pstudio` do Makefile vira uma chamada a `ppack`.
def pstudio_p() -> list<str>:
    """O que o FECHAMENTO de imports não alcança.

    Desde a 1.5(d) o compilador puxa o módulo P de qualquer `import "x.ph"` do
    fechamento, e não só do arquivo de cima: `lib_hl.psc` importa `"hl.ph"`, e
    `hl.c` — e o `lexer.c` que ele usa — vêm sozinhos. A lista, que tinha
    dezanove entradas copiadas do `Makefile`, ficou com duas.

    E as duas que sobram não sobram por falta do compilador: `plang.ph` DECLARA
    `fatal_at` e quem o implementa é `util.p`, um arquivo com outro nome. Não há
    aresta de import ligando os dois, e nenhuma regra de fechamento acharia isso
    — é conhecimento deste repositório, e conhecimento deste repositório é
    exatamente o que um descritor existe para carregar."""
    return ["selfhost/util.p", "selfhost/utf8.p"]


async def pstudio(c: T.Ctx) -> str:
    """Devolve o caminho do binário, ou "" se a máquina não tem SDL2 — e não ter
    não é erro: é uma máquina sem o que o editor precisa, e o resto do build não
    tem nada com isso."""
    if not await T.tem_pkg("sdl2"):
        return ""
    cf = await T.pkg_config(c, "sdl2", "--cflags")
    lb = await T.pkg_config(c, "sdl2", "--libs")
    # o compilador precisa PRE-PROCESSAR o header do SDL para ingerir
    # `include <SDL2/SDL.h>` (45.5), e é a mesma resposta do `pkg-config` que
    # diz onde ele está. `--cpp` em vez da variável de ambiente: o `env=` de uma
    # aresta SUBSTITUI o ambiente, e um comando sem `PATH` não acha o `cc`.
    cpp = "cc"
    for x in cf:
        cpp += " " + x
    return await T.psc_program_com(c, "pstudio/ps/app.psc", path.join(BUILD, "bin/pstudio"),
                                   path.join(BUILD, "obj"), pstudio_p(),
                                   ["--cpp", cpp], cf, lb)


# ---------- a suíte do pscript ----------
# Cento e tantos programas que compilam, rodam, e cuja saída inteira é comparada
# com um `.expected`. No `tests/run.sh` isso é um laço em shell que refaz tudo a
# cada corrida; aqui cada caso é uma aresta, e um caso cujo binário e cujo
# esperado não mudaram não roda.
const CORPUS: str = "tests/pscript/run"

# o carimbo da suíte, que é como se PEDE "roda a suíte" a um grafo que só sabe
# falar de arquivos (`ppack test`, ou `ppack build <este caminho>`)
const SUITE_PSCRIPT: str = "build/t/stamp/pscript.suite"

async def suite_pscript(c: T.Ctx, verdict: str) -> str:
    casos: list<T.Caso> = []
    for src in T.glob(CORPUS, ".psc"):
        base = path.basename(src)
        nome = base[0:len(base) - 4]
        # `lib_*.psc` são peças de import, não programas
        if nome.startswith("lib_"):
            continue
        esperado = path.join(CORPUS, nome + ".expected")
        if not path.isfile(esperado):
            continue
        status = 0
        arq_status = path.join(CORPUS, nome + ".exit")
        if path.isfile(arq_status):
            status = int((await ler(arq_status)).strip())
        # um caso pode pedir FLAGS de compilação (`<nome>.flags`), que é como uma
        # opção que muda o que se emite ganha portão nenhum: `-O` tira o
        # `assert` (46.4), e a única forma de ver isso é construir o mesmo
        # programa com ela
        flags: list<str> = []
        arq_flags = path.join(CORPUS, nome + ".flags")
        if path.isfile(arq_flags):
            for w in (await ler(arq_flags)).strip().split(" "):
                if len(w) > 0:
                    flags.append(w)
        binario = await T.psc_program(c, src, path.join(BUILD, "t/bin", nome),
                                      path.join(BUILD, "t/obj"), flags, [])
        # cada caso roda no diretório DELE. O `tests/run.sh` roda os cento e
        # tantos no mesmo, um de cada vez; aqui eles rodam em paralelo, e dois
        # casos que criassem um arquivo com o mesmo nome se atropelariam.
        casos.append(T.Caso(nome, binario, esperado, status, path.join(BUILD, "t/run", nome)))
    return T.suite(c, "pscript", casos, verdict, path.join(BUILD, "t/stamp"))


private async def ler(p: str) -> str:
    f = await open(p, "r")
    t = await f.text()
    await f.close()
    return t


# ---------- a verificação inteira ----------
# O `verify-all.sh` roda oito passos em sequência e leva o que levam os oito
# somados. Aqui eles são ARESTAS: o que não depende um do outro roda junto, e o
# que não mudou não roda. O que cada uma faz continua sendo o arreio de sempre —
# não há nada reescrito, e é assim que se quer: eles funcionam, e são lidos por
# gente que não vai ler pscript.
#
# Cada arreio ganha o diretório de trabalho DELE (`OUT=`), porque duas corridas
# do `tests/run.sh` no mesmo lugar se atropelam — e o relatório das duas fica
# ilegível. Isto já custou uma investigação.
const VERIFY: str = "build/t/stamp/verify"
# o alvo de `ppack test`: a suíte do pscript caso a caso MAIS a leitura em C do
# corpus (cases, modules, stl, p-suite, errors, pstudio, roundtrip). É o que o
# `make test` sempre significou, e por isso é o que ele continua a significar.
const TESTE: str = "build/t/stamp/test"

def suites_de_fora() -> list<str>:
    # a MESMA lista do `verify-all.sh`, e por isso `pstudio` e `roundtrip` estão
    # aqui: uma verificação que roda menos que a de antes não é a mesma
    return ["cases", "modules", "stl", "p-suite", "errors", "pstudio", "roundtrip", "pscript"]

async def verificacao(c: T.Ctx, plangc: str, suite: str, spkg: str, sdoc: str, fixo: str, editor: str) -> str:
    logs: list<str> = []
    logdir = path.join(BUILD, "t/log")
    gating = suites_de_fora()

    # as três leituras do mesmo corpus: o C, o QBE e o C89. São a mesma suíte
    # com o mesmo compilador, e é justamente por isso que valem — o que elas
    # comparam é o BACK END.
    for modo in [["c", ""], ["qbe", "qbe"], ["c89", ""]]:
        vars: dict<str, str> = {"PLANGC": plangc, "OUT": path.join(BUILD, "t/h", modo[0])}
        if len(modo[1]) > 0:
            vars["BACKEND"] = modo[1]
        if modo[0] == "c89":
            vars["STD"] = "c89"
        argv: list<str> = ["bash", "tests/run.sh"]
        for x in gating:
            argv.append(x)
        logs.append(T.harness(c, "suite-" + modo[0], argv, vars, [plangc], logdir,
                              "suíte " + modo[0]))

    # o coletor a cada ponto seguro, e o protocolo que o descritor consome
    logs.append(T.harness(c, "gc-stress", ["bash", "tests/gc-stress.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "gc-stress"))
    logs.append(T.harness(c, "protocol", ["bash", "tests/protocol.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "protocolo"))
    logs.append(T.harness(c, "knobs", ["bash", "tests/knobs.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "knobs"))
    logs.append(T.harness(c, "net-late", ["bash", "tests/net-late.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "net-late"))
    logs.append(T.harness(c, "print-atomic", ["bash", "tests/print-atomic.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "print atômico"))
    logs.append(T.harness(c, "run-cmd", ["bash", "tests/run-cmd.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "run-cmd"))
    # os três arreios que medem o pscript contra ALGO QUE NÃO SOMOS NÓS: corpora
    # que outros escreveram, e os nossos programas rodados também no intérprete
    # de referência. Não são placar: são portão.
    logs.append(T.harness(c, "conformance", ["bash", "tests/conformance/run.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "conformidade"))
    logs.append(T.harness(c, "oracle", ["bash", "tests/oracle/run.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "oráculos"))
    # e o ponto fixo do OUTRO back end: um back end pode passar em todos os
    # casos e ainda gerar um compilador que diverge num canto que nenhum caso
    # toca
    logs.append(T.harness(c, "qbe-fixpoint", ["bash", "tests/qbe-fixpoint.sh"],
                          {"PLANGC": plangc, "OUT": path.join(BUILD, "t/h/qbefp")},
                          [plangc], logdir, "ponto fixo do QBE"))
    logs.append(T.harness(c, "packages", ["bash", "tests/packages.sh"],
                          {"PLANGC": plangc, "OUT": path.join(BUILD, "t/h/packages")},
                          [plangc], logdir, "pacotes (import <>)"))

    # `ppack test` é a leitura em C do corpus mais a suíte caso a caso: as duas
    # medem a mesma coisa por caminhos diferentes, e juntas são o que `make
    # test` sempre quis dizer. O resto (QBE, C89, oráculos, coletor) é `verify`.
    T.junta(c, TESTE, [logs[0], suite, spkg, sdoc],
            "test: o corpus em C, a suíte caso a caso, os testes dos pacotes e os DOCTESTS")

    # a suíte do pscript como GRAFO entra junto: ela é a mesma coisa que a
    # `suite-c` mede, por outro caminho e caso a caso — e é a que roda rápido
    tudo: list<str> = []
    for l in logs:
        tudo.append(l)
    tudo.append(suite)
    tudo.append(spkg)
    tudo.append(sdoc)
    # o PONTO FIXO (o compilador reproduz a si mesmo) e o editor: os passos 2, 3
    # e 7 do `verify-all`, que já são arestas deste grafo
    tudo.append(fixo)
    if len(editor) > 0:
        tudo.append(editor)
    return T.junta(c, VERIFY, tudo, "verify: " + str(len(tudo)) + " partes")


# ---------- o workspace ----------
# Um `pack.json` na RAIZ do projeto, com os membros. É o que faz este
# repositório ser, para o `ppack`, um projeto como qualquer outro — e é assim
# que o ecossistema é testado por quem o escreve, contra o caso mais difícil que
# existe.
#
# Dele sai uma coisa só para o compilador: as RAÍZES de busca. O diretório que
# CONTÉM os membros é uma raiz, porque é assim que `import <pui/widget.ph>`
# resolve — o nome do pacote é o primeiro pedaço do caminho.
async def raizes_do_workspace(manifesto: str) -> list<str>:
    out: list<str> = []
    if not path.isfile(manifesto):
        return out
    m = await M.ler(manifesto)
    if not m.eh_workspace:
        return out
    base = path.dirname(manifesto)
    for membro in m.membros:
        r = path.dirname(path.join(base, membro))
        if len(r) == 0:
            r = "."
        ja = False
        for x in out:
            if x == r:
                ja = True
        if not ja:
            out.append(r)
    return out


# ---------- o teste que viaja COM o pacote ----------
# `packages/<nome>/test/` é do PACOTE, não do projeto. Três consequências, e as
# três são o ponto:
#
#   * um pacote publicado carrega a prova de que funciona, e quem o instala pode
#     rodá-la na própria máquina;
#   * o teste não precisa de ser citado à mão em nenhum arreio — ele é achado
#     porque está onde tem de estar;
#   * e o `ppack test` do projeto roda os testes dos pacotes do workspace, que é
#     o que faz mover um pacote para cá não perder cobertura.
async def membros_do_workspace(manifesto: str) -> list<str>:
    out: list<str> = []
    if not path.isfile(manifesto):
        return out
    m = await M.ler(manifesto)
    if not m.eh_workspace:
        return out
    base = path.dirname(manifesto)
    for membro in m.membros:
        out.append(path.join(base, membro))
    return out


async def suite_doctests(c: T.Ctx, verdict: str) -> str:
    """Os exemplos das docstrings, a correr.

    Um exemplo numa docstring envelhece em silêncio: parece certo, ninguém o
    corre, e um dia alguém copia uma linha que já não funciona. Aqui ele é uma
    aresta do build como qualquer outra.

    O programa de cada módulo é GERADO no plano, a partir da resposta 5 do
    compilador — a mesma lista canónica que o `ppack doc` mostra. Gerar no plano
    é o que garante que ele está sempre em dia: a docstring mudou, o programa
    muda, a aresta suja."""
    casos: list<T.Caso> = []
    for dir in await membros_do_workspace("pack.json"):
        pkg = path.basename(dir)
        mods: list<str> = []
        for f in sorted(os.listdir(dir)):
            if f.endswith(".psc") or f.endswith(".ph"):
                mods.append(f)
        for mod in mods:
            alvo_mod = path.join(dir, mod)
            resp = await T.ask(c, T.com_raizes(c, [c.query, "--api", alvo_mod]))
            apis = A.parse("\n".join(resp))
            if len(apis) == 0:
                continue
            api = apis[0]
            base = mod[0:len(mod) - 4] if mod.endswith(".psc") else mod[0:len(mod) - 3]
            # um `.ph` entra INTEIRO (`import <pkg/mod.ph>`): o que dele
            # atravessa é decidido pela 45.5 e não por uma lista de nomes, e os
            # nomes ficam visíveis sem qualificador. Um `.psc` traz os nomes
            # públicos pelo `from ... import`.
            importa = "<" + pkg + "/" + mod + ">"
            prog = DT.gerar(api, importa) if mod.endswith(".psc") else DT.gerar_ph(api, importa)
            if prog.quantos == 0:
                continue
            rot = pkg + "/" + base
            src = path.join(BUILD, "t/doc", pkg + "-" + base + ".psc")
            esp = path.join(BUILD, "t/doc", pkg + "-" + base + ".expected")
            await T.escrever(src, prog.fonte)
            await T.escrever(esp, prog.esperado)
            binario = await T.psc_program(c, src, path.join(BUILD, "t/doc/bin", pkg + "-" + base),
                                          path.join(BUILD, "t/obj"), [], [])
            casos.append(T.Caso(rot, binario, esp, 0,
                                path.join(BUILD, "t/run", "doc-" + pkg + "-" + base)))
    return T.suite(c, "doctest", casos, verdict, path.join(BUILD, "t/stamp"))


async def suite_pacotes(c: T.Ctx, verdict: str) -> str:
    casos: list<T.Caso> = []
    for dir in await membros_do_workspace("pack.json"):
        tdir = path.join(dir, "test")
        if not path.isdir(tdir):
            continue
        nome = path.basename(dir)
        # um teste de pacote pode estar em qualquer das duas linguagens: o `pui`
        # é pscript e o `sha2` é P. A diferença é só como se constrói.
        fontes: list<str> = []
        for a in T.glob(tdir, ".psc"):
            fontes.append(a)
        for b in T.glob(tdir, ".p"):
            fontes.append(b)
        for src in sorted(fontes):
            base = path.basename(src)
            corte = 4 if src.endswith(".psc") else 2
            n = base[0:len(base) - corte]
            esperado = path.join(tdir, n + ".expected")
            if not path.isfile(esperado):
                continue
            rot = nome + "/" + n
            alvo = path.join(BUILD, "t/pkg", nome + "-" + n)
            # objetos SEPARADOS por linguagem, e não é arrumação: o mesmo `.c`
            # gerado de um módulo P é compilado com os `-D` do runtime quando
            # serve um programa pscript e sem eles quando serve um programa P.
            # Dois comandos diferentes para o mesmo `.o` é o grafo que o motor
            # recusa — com razão, porque qual dos dois define o conteúdo
            # dependeria da ordem.
            odir = path.join(BUILD, "t/obj" if src.endswith(".psc") else "t/objp")
            binario = ""
            if src.endswith(".psc"):
                binario = await T.psc_program(c, src, alvo, odir, [], [])
            else:
                binario = await T.p_program(c, src, alvo, odir, [], [])
            casos.append(T.Caso(rot, binario, esperado, 0,
                                path.join(BUILD, "t/run", nome + "-" + n)))
    return T.suite(c, "pacotes", casos, verdict, path.join(BUILD, "t/stamp"))


async def montar(query: str) -> G.Graph:
    """`query` é o compilador que RESPONDE as perguntas do protocolo enquanto o
    grafo é montado — normalmente o que já está na máquina. Quem RODA em cada
    degrau é o artefato daquele degrau, e a diferença é o que faz a escada ser
    expressável."""
    g = G.new_graph()
    raizes = await raizes_do_workspace("pack.json")
    # ... e as que o `ppack install` materializou, DEPOIS das do workspace: o que
    # está na árvore ganha de o que veio de fora, que é o que permite trabalhar
    # numa cópia local de uma dependência sem mexer no lock.
    for ri in R.raizes_instaladas():
        raizes.append(ri)
    c = T.new_ctx(g, BUILD, query)
    c.pkgroots = raizes
    stamp = await escada(c)

    # tudo o que vem por cima roda com o compilador do PONTO FIXO — o mesmo que
    # o `verify-all` usa, e pela mesma razão
    # UM contexto para tudo o que é pscript: o runtime é gerado e compilado uma
    # vez só, e todos os programas o compartilham. Dois contextos gerariam o
    # mesmo `.c` em dois lugares — trabalho dobrado por nada.
    cps = T.derivar(c, path.join(BUILD, "psc"), PLANGC_S2)
    bins = await pscript_tudo(cps)
    editor = await pstudio(cps)
    suite = await suite_pscript(cps, bins["verdict"])
    spkg = await suite_pacotes(cps, bins["verdict"])
    sdoc = await suite_doctests(cps, bins["verdict"])
    await verificacao(cps, PLANGC_S2, suite, spkg, sdoc, stamp, editor)

    # o alvo padrão é o que "está construído" quer dizer: o compilador confere a
    # si mesmo, e as ferramentas de cima existem. As suítes são um alvo que se
    # PEDE (`ppack build <carimbo>`), não o padrão — construir não é testar.
    g.default_targets.append(stamp)
    g.default_targets.append(bins["ppack"])
    if len(editor) > 0:
        g.default_targets.append(editor)
    return g
