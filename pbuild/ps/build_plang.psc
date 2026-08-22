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
    for f in T.glob("stl", ".ph"):
        fontes.append(f)
    for f2 in T.glob("selfhost", ".ph"):
        fontes.append(f2)
    for f3 in T.glob("selfhost", ".p"):
        fontes.append(f3)

    # 3) os três degraus. Cada um usa o compilador do anterior, e é ISSO que a
    #    entrada implícita expressa.
    c1 = T.new_ctx(c.g, BUILD, seed)
    c1.plangc_is_built = True
    c1.query = c.query
    s1all = await T.p_modules(c1, fontes, path.join(BUILD, "s1"), [])
    s1c = T.only(s1all, ".c")
    p1 = T.cc_program(c1, path.join(BUILD, "bin/plangc_s1"), s1c, T.only(s1all, ".h"), [], [])

    c2 = T.new_ctx(c.g, BUILD, p1)
    c2.plangc_is_built = True
    c2.query = c.query
    s2all = await T.p_modules(c2, fontes, path.join(BUILD, "s2"), [])
    s2c = T.only(s2all, ".c")
    p2 = T.cc_program(c2, path.join(BUILD, "bin/plangc_s2"), s2c, T.only(s2all, ".h"), [], [])

    c3 = T.new_ctx(c.g, BUILD, p2)
    c3.plangc_is_built = True
    c3.query = c.query
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
    return stamp

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
    """O que o compilador NÃO emite junto com o `app.psc`.

    `import "shim.ph"` no arquivo de cima faz o compilador emitir `shim.c` (e,
    por ele, `pgfx`, `pgfx_raster` e `font_atlas`) — a resposta 3 já os lista, e
    quem os pede é o `psc_program_com`. O que sobra é o realce: `lib_hl.psc`
    importa `"hl.ph"` de dentro de um MÓDULO, e um `import` a essa profundidade
    não puxa o `.p` para a emissão. É a mesma lista que o `Makefile` carrega, e
    a assimetria está anotada em `pbuild/PLAN.md` — quando ela se resolver, esta
    função encolhe para nada."""
    fontes: list<str> = []
    for f in T.glob("stl", ".ph"):
        fontes.append(f)
    for h in ["selfhost/plang.ph", "selfhost/ast.ph", "selfhost/lexer.ph",
              "pstudio/ps/hl.ph"]:
        fontes.append(h)
    for d in ["pstudio/ps/hl.p", "selfhost/lexer.p", "selfhost/utf8.p", "selfhost/util.p"]:
        fontes.append(d)
    return fontes


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


async def montar(query: str) -> G.Graph:
    """`query` é o compilador que RESPONDE as perguntas do protocolo enquanto o
    grafo é montado — normalmente o que já está na máquina. Quem RODA em cada
    degrau é o artefato daquele degrau, e a diferença é o que faz a escada ser
    expressável."""
    g = G.new_graph()
    c = T.new_ctx(g, BUILD, query)
    stamp = await escada(c)

    # tudo o que vem por cima roda com o compilador do PONTO FIXO — o mesmo que
    # o `verify-all` usa, e pela mesma razão
    # UM contexto para tudo o que é pscript: o runtime é gerado e compilado uma
    # vez só, e todos os programas o compartilham. Dois contextos gerariam o
    # mesmo `.c` em dois lugares — trabalho dobrado por nada.
    cps = T.new_ctx(g, path.join(BUILD, "psc"), PLANGC_S2)
    cps.plangc_is_built = True
    cps.query = query
    bins = await pscript_tudo(cps)
    editor = await pstudio(cps)
    await suite_pscript(cps, bins["verdict"])

    # o alvo padrão é o que "está construído" quer dizer: o compilador confere a
    # si mesmo, e as ferramentas de cima existem. As suítes são um alvo que se
    # PEDE (`ppack build <carimbo>`), não o padrão — construir não é testar.
    g.default_targets.append(stamp)
    g.default_targets.append(bins["ppack"])
    if len(editor) > 0:
        g.default_targets.append(editor)
    return g
