"""Os ALVOS: o que se escreve num arquivo de build, e o que vira aresta.

O motor conhece uma coisa só — rodar aresta. Tudo que é *conhecimento de
ferramenta* mora aqui, e essa fronteira é deliberada: é exatamente onde o muon
acumulou 1 679 linhas de catálogo de toolchain e onde o CMake se perdeu. Aqui o
catálogo tem duas entradas (`plangc` e `cc`), e uma delas é nossa.

A peça central é o `Ctx`: ele carrega o grafo em construção, para onde vão os
artefatos, e QUAL COMPILADOR usar — e esse último ponto é o que faz a escada de
bootstrap ser expressável. Quando o compilador é um arquivo que outra aresta
produziu, ele entra como ENTRADA das arestas que o usam, e o grafo passa a saber
que refazer o compilador refaz tudo que ele gerou. É a diferença entre um build
que sabe o que faz e um script que roda comandos na ordem certa por sorte.
"""
import os
import path
import lib_graph as G

struct Target:
    """O que muda entre `linux-amd64`, `linux-amd64-musl` e `macos-arm64`. O nome
    é NOSSO e curto; a tradução para o mundo (o `-t` do QBE, o triplo do `cc`)
    mora aqui, nesta camada, e não no motor.

    `struct` e não `record` porque carrega `str`, e um record é bytes puros
    (58.2)."""
    name: str
    cc: str
    qbe: str

def host_target() -> Target:
    return Target("host", "cc", "amd64_sysv")

struct Ctx:
    g: G.Graph
    outdir: str        # onde os artefatos vão parar (build/obj, build/s1, ...)
    plangc: str        # o compilador que RODA nas arestas — pode ser um artefato
    plangc_is_built: bool   # ... e se for, ele entra como entrada das arestas
    query: str         # o compilador que RESPONDE as perguntas do protocolo
    target: Target
    cflags: list<str>
    # o runtime do pscript, gerado UMA vez por contexto (ver `psrt`): vinte
    # programas em pscript não são vinte compilações do runtime, e duas arestas
    # produzindo o mesmo `.c` seriam um grafo que o motor recusa
    rt_c: list<str>
    rt_h: list<str>
    rt_o: list<str>
    rt_pronto: bool

def new_ctx(g: G.Graph, outdir: str, plangc: str) -> Ctx:
    # quem RESPONDE e quem RODA podem ser compiladores diferentes, e na escada de
    # bootstrap eles SÃO: as arestas rodam o compilador de cada degrau — que
    # ainda não existe quando o grafo é montado —, enquanto as perguntas ("o que
    # este arquivo lê?", "o que ele vai emitir?") são sobre o FONTE e podem ser
    # feitas a qualquer compilador que entenda a linguagem. É a mesma suposição
    # que o bootstrap já faz: o seed compila os fontes de hoje.
    return Ctx(g, outdir, plangc, False, plangc, host_target(), ["-O2", "-std=c11", "-w"], [], [], [], False)

# ---------- perguntar ao compilador ----------
# As respostas 1 e 3 do protocolo, usadas onde elas existem para ser usadas: o
# descritor não reimplementa a resolução de `import` — ele PERGUNTA. Uma segunda
# implementação que divergisse da verdadeira daria build velho depois de editar,
# que é o único modo de falhar que importa.
private async def ask(c: Ctx, argv: list<str>) -> list<str>:
    """A RESPOSTA vem por arquivo, e não pelo cano.

    O `os.run` junta a saída de erro com a de saída de propósito — é o que faz um
    relatório de erro se ler na ordem em que aconteceu. Mas uma RESPOSTA não é um
    relatório: o compilador pode avisar (`-Wshadow-prelude`, por exemplo) no meio
    de responder, e o aviso, misturado, viraria uma linha da resposta. Foi
    exatamente o que aconteceu: três avisos do corpus viraram três "entradas que
    ninguém produz", e o grafo inteiro foi recusado.

    Com `stdout=` a resposta vai para o arquivo e o `output()` fica só com o que
    o compilador tinha a dizer — que é o que se mostra quando ele recusa."""
    # o nome do arquivo vem da PERGUNTA: duas perguntas diferentes nunca
    # escrevem no mesmo lugar, e um módulo importado não pode ter variável de
    # topo (é um conjunto de definições, não um programa) — um contador global
    # não caberia aqui.
    resp = path.join(c.outdir, ".ppack-resposta." + str(G.hash_str(G.FNV_OFF, " ".join(argv))))
    d = path.dirname(resp)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    r = await os.run(argv, stdout=resp)
    if r.status() != 0:
        # NUNCA em silêncio: uma pergunta que falha e devolve lista vazia produz
        # um grafo que não menciona nada, e um grafo que não menciona nada
        # "constrói" tudo com sucesso sem fazer nada. É o modo de falhar mais
        # perigoso que existe aqui, e custou uma investigação para aparecer.
        raise error("a pergunta ao compilador falhou: " + " ".join(argv) + "\n" + r.output())
    f = await open(resp, "r")
    txt = await f.text()
    await f.close()
    os.remove(resp)
    out: list<str> = []
    for line in txt.split("\n"):
        if len(line) > 0:
            out.append(line)
    return out

async def deps_of(c: Ctx, src: str) -> list<str>:
    return await ask(c, [c.query, "--deps", src])

async def outputs_of(c: Ctx, src: str, outdir: str) -> list<str>:
    return await ask(c, [c.query, "--outputs", "--out-dir", outdir, src])

# ---------- P e pscript -> C ----------
async def p_module(c: Ctx, src: str, outdir: str, flags: list<str>) -> list<str>:
    """Uma aresta: `plangc [flags] --out-dir <dir> <fonte>`.

    As `flags` são as do COMPILADOR, e elas mudam o que ele emite: `-O` tira o
    `assert` (46.4), `-g` põe o rastro de pilha. Elas entram no `argv`, logo
    entram no hash da aresta — trocar de flag refaz, que é o mínimo que se
    espera e o que um Makefile com variável de ambiente não garante.

    As entradas são o que o COMPILADOR diz que leu (o fonte e os `.ph` que ele
    importa, transitivamente) mais o próprio compilador quando ele é construído
    aqui. As saídas são o que ele diz que vai emitir. Nada disto é adivinhado.
    """
    ins = await deps_of(c, src)
    outs = await outputs_of(c, src, outdir)
    argv: list<str> = [c.plangc]
    for fl in flags:
        argv.append(fl)
    argv.append("--out-dir")
    argv.append(outdir)
    argv.append(src)
    # ESTA ARESTA JÁ EXISTE? Acontece o tempo todo e não é erro: `import "x.ph"`
    # (75.3) faz o compilador emitir o módulo P junto com quem o importa, e dois
    # programas que importam o mesmo módulo pedem a mesma emissão. Um arquivo
    # tem UM produtor, então a segunda vez não cria aresta nenhuma.
    #
    # O que não se pode é aceitar isso quando o comando é OUTRO — aí são duas
    # emissões diferentes disputando o mesmo arquivo, e é justamente o que a
    # higiene do motor recusa. Por isso a comparação é do `argv` inteiro.
    if ja_emitido(c, outs, c.plangc, outdir):
        return outs
    e = G.new_edge(argv)
    for i in ins:
        e.ins.append(c.g.node(i).id)
    if c.plangc_is_built:
        # a ESCADA: quando o compilador é um artefato, mexer nele refaz tudo que
        # ele gera. Entra como entrada implícita porque não é "o que se compila",
        # é "com o que se compila"
        e.implicit.append(c.g.node(c.plangc).id)
    for o in outs:
        n = c.g.node(o)
        if n.gen >= 0 and mesmo_emissor(c, n.gen, c.plangc, outdir):
            # ESTE arquivo já tem produtor, e é o mesmo compilador escrevendo o
            # mesmo espelho. Acontece quando dois programas leem o mesmo `.ph`:
            # cada emissão escreve o header, e o conteúdo é o mesmo. Um arquivo
            # tem UM produtor, então aqui ele vira ENTRADA — o que também põe a
            # ordem certa entre os dois.
            e.implicit.append(n.id)
            continue
        e.outs.append(n.id)
    # o C regenerado sai byte a byte igual em quase toda edição, e é isto que
    # transforma "reescrevi o .c" em "não recompilei o .o"
    e.restat = True
    e.desc = "gerando " + path.basename(src)
    e.target = c.target.name
    c.g.add_edge(e)
    return outs

private def valor_de(argv: list<str>, opcao: str) -> str:
    i = 0
    while i + 1 < len(argv):
        if argv[i] == opcao:
            return argv[i + 1]
        i += 1
    return ""

private def mesmo_emissor(c: Ctx, eid: int, plangc: str, outdir: str) -> bool:
    velho = c.g.edges[eid]
    if len(velho.argv) == 0 or velho.argv[0] != plangc:
        return False
    return valor_de(velho.argv, "--out-dir") == outdir

private def ja_emitido(c: Ctx, outs: list<str>, plangc: str, outdir: str) -> bool:
    """Estas saídas já são emitidas — pelo MESMO compilador, na MESMA árvore?

    Acontece o tempo todo e não é erro: `plangc --out-dir D x` emite o header de
    todo `.ph` que ele leu, então compilar `app.psc` já escreve `stl/cstr.h`, e
    pedir `stl/cstr.ph` depois pediria o mesmo arquivo outra vez. O conteúdo é o
    mesmo — é o mesmo compilador escrevendo o mesmo espelho a partir do mesmo
    fonte —, e o que não pode haver é DOIS produtores.

    O que continua sendo recusado (e a higiene do motor o pega) é outro
    compilador, outra árvore, ou outra ferramenta escrevendo por cima."""
    if len(outs) == 0:
        return False
    for o in outs:
        n = c.g.node(o)
        if n.gen < 0:
            return False
        if not mesmo_emissor(c, n.gen, plangc, outdir):
            return False
    return True

async def p_modules(c: Ctx, srcs: list<str>, outdir: str, flags: list<str>) -> list<str>:
    """O mesmo, para uma lista. Devolve TUDO que foi gerado — `.c` e `.h`.

    Os dois importam, e por razões diferentes: o `.c` vai para a linha de comando
    do `cc`, e o `.h` é ENTRADA dele (o C gerado inclui os headers gerados). Um
    grafo que devolvesse só os `.c` não saberia que o header precisa existir
    antes, e o build falharia na primeira compilação — ou pior, usaria um header
    velho que sobrou."""
    out: list<str> = []
    for s in srcs:
        for o in await p_module(c, s, outdir, flags):
            out.append(o)
    return out

def only(files: list<str>, suffix: str) -> list<str>:
    out: list<str> = []
    for f in files:
        if f.endswith(suffix):
            out.append(f)
    return out

# ---------- C -> objeto ----------
def c_object(c: Ctx, src: str, obj: str, flags: list<str>, extra_ins: list<str>) -> str:
    """`cc -c`, com `-MD` para o compilador dizer que headers leu. O `.d` fica no
    disco e é lido no plano da corrida seguinte — do lado do C não há protocolo,
    e este é o preço.

    O `depfile` só existe DEPOIS da primeira compilação, e é por isso que os
    headers GERADOS entram como entrada implícita já na primeira: sem eles, a
    primeira corrida de um build limpo pode compilar um `.c` antes de o `.h` que
    ele inclui ter sido escrito. Depois da primeira, o `.d` cobre o resto —
    inclusive os headers do sistema."""
    argv: list<str> = [c.target.cc]
    for f in c.cflags:
        argv.append(f)
    for f2 in flags:
        argv.append(f2)
    argv.append("-MD")
    argv.append("-MF")
    argv.append(obj + ".d")
    argv.append("-c")
    argv.append(src)
    argv.append("-o")
    argv.append(obj)
    e = G.new_edge(argv)
    e.ins.append(c.g.node(src).id)
    for x in extra_ins:
        e.implicit.append(c.g.node(x).id)
    e.outs.append(c.g.node(obj).id)
    e.depfile = obj + ".d"
    e.desc = "compilando " + path.basename(src)
    e.target = c.target.name
    c.g.add_edge(e)
    return obj

def obj_for(objdir: str, src: str) -> str:
    """O objeto de um fonte ESPELHA o caminho dele, e não o nome dele. Dois
    `app.c` de pastas diferentes com o mesmo `basename` seriam duas arestas
    produzindo o mesmo `.o` — que é exatamente o grafo que o motor recusa, e com
    razão: qual das duas define o conteúdo dependeria da ordem."""
    return path.join(objdir, src + ".o")

def c_objects(c: Ctx, srcs: list<str>, objdir: str, flags: list<str>, extra_ins: list<str>) -> list<str>:
    objs: list<str> = []
    for s in srcs:
        objs.append(c_object(c, s, obj_for(objdir, s), flags, extra_ins))
    return objs

# ---------- objetos -> binário ----------
def executable(c: Ctx, out: str, objs: list<str>, libs: list<str>) -> str:
    argv: list<str> = [c.target.cc]
    for f in c.cflags:
        argv.append(f)
    argv.append("-o")
    argv.append(out)
    for o in objs:
        argv.append(o)
    for l in libs:
        argv.append(l)
    e = G.new_edge(argv)
    for o2 in objs:
        e.ins.append(c.g.node(o2).id)
    e.outs.append(c.g.node(out).id)
    e.desc = "linkando " + path.basename(out)
    e.target = c.target.name
    c.g.add_edge(e)
    return out

def cc_program(c: Ctx, out: str, srcs: list<str>, extra_ins: list<str>, flags: list<str>, libs: list<str>) -> str:
    """Um binário direto dos fontes C, sem objetos intermediários — que é o que
    o seed do compilador é: um `cc` sobre o C comitado."""
    argv: list<str> = [c.target.cc]
    for f in c.cflags:
        argv.append(f)
    for f2 in flags:
        argv.append(f2)
    argv.append("-o")
    argv.append(out)
    for s in srcs:
        argv.append(s)
    for l in libs:
        argv.append(l)
    e = G.new_edge(argv)
    for s2 in srcs:
        e.ins.append(c.g.node(s2).id)
    # o que entra sem estar na linha de comando: os headers gerados, que o C
    # gerado inclui. São entradas IMPLÍCITAS — a mesma faixa que o `depfile` usa
    for x in extra_ins:
        e.implicit.append(c.g.node(x).id)
    e.outs.append(c.g.node(out).id)
    e.desc = "construindo " + path.basename(out)
    e.target = c.target.name
    c.g.add_edge(e)
    return out

# ---------- pscript -> binário ----------
# A lista dos módulos do runtime vivia em SEIS lugares (dois blocos do run.sh, o
# psbuild.sh, o Makefile, o verify-all e o `RT_SRCS` do compilador). Aqui é o
# lugar dela: o descritor é quem sabe o que compõe um programa em pscript, e as
# outras cinco cópias somem quando os arreios passarem a chamar o `ppack`.
#
# A ordem importa e não é alfabética: são CAMADAS (memória, valores, o que roda,
# a biblioteca, o sistema, o epílogo), e o compilador as vê nesta ordem.
const RT_MODULOS: list<str> = ["psrt.ph", "psrt_types.ph", "psrt_mem.ph", "psrt_val.ph",
                               "psrt_rt.ph", "psrt_std.ph", "psrt_os.ph", "psrt_top.ph",
                               "psrt_mem.p", "psrt_val.p", "psrt_rt.p", "psrt_std.p",
                               "psrt_os.p", "psrt_top.p"]

# glibc esconde socket/getaddrinfo/poll/pipe debaixo de um `-std=` estrito, e o
# runtime fala POSIX do começo ao fim
const PSDEFS: list<str> = ["-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE"]


async def psrt(c: Ctx) -> list<str>:
    """O runtime do pscript, compilado UMA vez por contexto. Devolve tudo o que
    ele gerou — `.c` e `.h`."""
    if c.rt_pronto:
        out: list<str> = []
        for x in c.rt_c:
            out.append(x)
        for y in c.rt_h:
            out.append(y)
        return out
    srcs: list<str> = []
    for m in RT_MODULOS:
        srcs.append(path.join("pscript/runtime", m))
    todos = await p_modules(c, srcs, c.outdir, [])
    c.rt_c = only(todos, ".c")
    c.rt_h = only(todos, ".h")
    c.rt_pronto = True
    return todos


private async def rt_objetos(c: Ctx, objdir: str) -> list<str>:
    """O runtime compilado a OBJETO, uma vez só para o contexto inteiro.

    Aqui está a diferença que mais se sente: o `psbuild.sh` relinka os seis
    módulos do runtime a partir do C em CADA programa, e a suíte do pscript tem
    mais de cem programas — são seiscentas compilações do mesmo texto. Com
    objeto, são seis."""
    if len(c.rt_o) > 0:
        return c.rt_o
    todos = await psrt(c)
    c.rt_o = c_objects(c, only(todos, ".c"), objdir, PSDEFS, only(todos, ".h"))
    return c.rt_o


async def psc_program_com(c: Ctx, src: str, out: str, objdir: str, p_srcs: list<str>,
                          flags: list<str>, cflags: list<str>, libs: list<str>) -> str:
    """O mesmo, mais MÓDULOS EM P compilados junto.

    É o caso do editor: a lógica é pscript, mas a mão que toca o SDL2 e a que
    chama o lexer do compilador são P — pixel e ponteiro do começo ao fim, que a
    45.5 não deixa atravessar. Do ponto de vista do grafo não há novidade
    nenhuma: são mais fontes, mais arestas de geração, mais objetos."""
    rtos = await rt_objetos(c, objdir)
    # a árvore é COMPARTILHADA, e tem de ser: o C gerado inclui os headers do
    # runtime por caminho relativo dentro do espelho (`../../pscript/runtime/
    # psrt.h`), então um programa numa árvore só dele não acharia o runtime que
    # está na outra. Quem cuida de dois programas que emitem o mesmo header é o
    # `p_module` — ver a nota lá.
    #
    # o PROGRAMA primeiro, porque a resposta 3 já inclui os módulos P que ele
    # importa com `import "x.ph"` (75.3) — o compilador os emite junto. Só o que
    # sobra depois disso é que precisa de aresta própria: um `.ph` que outro
    # módulo importa mais fundo, e o `.p` dele.
    prog = await p_module(c, src, c.outdir, flags)
    extras = await p_modules(c, p_srcs, c.outdir, flags)
    cab: list<str> = []
    for h in c.rt_h:
        cab.append(h)
    for h2 in only(extras, ".h"):
        cab.append(h2)
    for h3 in only(prog, ".h"):
        cab.append(h3)
    todas_cflags: list<str> = []
    for d in PSDEFS:
        todas_cflags.append(d)
    for x in cflags:
        todas_cflags.append(x)
    objs: list<str> = []
    for o in rtos:
        objs.append(o)
    for cf in only(extras, ".c"):
        objs.append(c_object(c, cf, obj_for(objdir, cf), todas_cflags, cab))
    for cf2 in only(prog, ".c"):
        objs.append(c_object(c, cf2, obj_for(objdir, cf2), todas_cflags, cab))
    todas_libs: list<str> = []
    for l in libs:
        todas_libs.append(l)
    todas_libs.append("-lm")
    todas_libs.append("-pthread")
    return executable(c, out, objs, todas_libs)


async def psc_program(c: Ctx, src: str, out: str, objdir: str, flags: list<str>, libs: list<str>) -> str:
    """Um programa em pscript: o runtime ao lado (16.4 — ele é FONTE compilado
    junto, não uma biblioteca que o compilador linka), o fechamento de imports
    do próprio programa, e um link que junta tudo.

    É o que o `tests/psbuild.sh` faz hoje em trinta linhas de shell, com duas
    diferenças que não são de estilo: as entradas de cada aresta vêm da resposta
    1 do compilador (editar um `.ph` importado refaz o que precisa, e o shell —
    que não pergunta nada — refazia tudo ou nada), e o runtime vira objeto uma
    vez em vez de ser recompilado por programa."""
    rtos = await rt_objetos(c, objdir)
    prog = await p_module(c, src, c.outdir, flags)
    cabecalhos: list<str> = []
    for h in c.rt_h:
        cabecalhos.append(h)
    for h2 in only(prog, ".h"):
        cabecalhos.append(h2)
    objs: list<str> = []
    for o in rtos:
        objs.append(o)
    # `import "x.ph"` (75.3) faz o compilador emitir o módulo P junto, no mesmo
    # espelho — e a resposta 3 já o lista, então não há glob nenhum aqui
    for cf in only(prog, ".c"):
        objs.append(c_object(c, cf, obj_for(objdir, cf), PSDEFS, cabecalhos))
    todas_libs: list<str> = []
    for l in libs:
        todas_libs.append(l)
    todas_libs.append("-lm")
    todas_libs.append("-pthread")
    return executable(c, out, objs, todas_libs)


# ---------- dependência do SISTEMA ----------
# `pkg-config` é o que existe, e ele é perguntado AQUI, na montagem do grafo, e
# não dentro de uma aresta. A diferença importa: o que ele responde entra no
# `argv`, logo entra no hash — trocar de versão do SDL2 na máquina refaz o que
# depende dele. Uma aresta que chamasse `pkg-config` por dentro teria sempre o
# mesmo comando e o mesmo hash, e o build reaproveitaria artefato de outra
# biblioteca em silêncio.
async def pkg_config(c: Ctx, lib: str, que: str) -> list<str>:
    linhas = await ask(c, ["pkg-config", que, lib])
    out: list<str> = []
    for l in linhas:
        for w in l.split(" "):
            if len(w) > 0:
                out.append(w)
    return out


async def tem_pkg(lib: str) -> bool:
    r = await os.run(["pkg-config", "--exists", lib])
    return r.status() == 0


# ---------- suítes ----------
struct Caso:
    """Um caso de teste: o que rodar, o que se espera dele, e onde ele roda.

    `struct` e não `record` porque carrega `str` (58.2)."""
    nome: str
    binario: str
    esperado: str
    status: int
    cwd: str


def suite(c: Ctx, nome: str, casos: list<Caso>, verdict: str, stampdir: str) -> str:
    """Uma suíte: uma aresta POR CASO, e um carimbo que junta todos.

    Uma aresta por caso é o ponto inteiro, e ele tem duas consequências que um
    arreio em shell não tem: os casos rodam em PARALELO com o resto do build (a
    fila é a mesma, o limite é o mesmo), e um caso cujo binário e cujo
    `.expected` não mudaram NÃO roda de novo. Uma suíte de trezentos casos passa
    a custar o que custam os casos que mudaram.

    O que roda não é o caso: é o `verdict` (ver `verdict.psc`), porque o status
    de saída de um caso é dado e não veredicto."""
    stamps: list<str> = []
    for k in casos:
        st = path.join(stampdir, nome + "." + k.nome + ".ok")
        e = G.new_edge([verdict, k.binario, k.esperado, str(k.status), k.cwd, st])
        e.ins.append(c.g.node(k.binario).id)
        e.ins.append(c.g.node(k.esperado).id)
        e.implicit.append(c.g.node(verdict).id)
        e.outs.append(c.g.node(st).id)
        e.desc = nome + ": " + k.nome
        e.target = c.target.name
        c.g.add_edge(e)
        stamps.append(st)
    return junta(c, path.join(stampdir, nome + ".suite"), stamps, nome + ": " + str(len(casos)) + " casos")


def junta(c: Ctx, stamp: str, ins: list<str>, desc: str) -> str:
    """Um nó que existe só para ser PEDIDO: depende de tudo, produz um carimbo.
    É como se pede "a suíte inteira" a um grafo que só sabe falar de arquivos."""
    e = G.new_edge(["/bin/sh", "-c", "exit 0"])
    for i in ins:
        e.ins.append(c.g.node(i).id)
    e.outs.append(c.g.node(stamp).id)
    e.stdout_to = stamp
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return stamp


# ---------- comandos e verificações ----------
def command(c: Ctx, argv: list<str>, ins: list<str>, outs: list<str>, desc: str) -> G.Edge:
    """A aresta crua, sempre disponível. Quem precisa de algo que a biblioteca
    não prevê desce um nível sem sair da linguagem."""
    e = G.new_edge(argv)
    for i in ins:
        e.ins.append(c.g.node(i).id)
    for o in outs:
        e.outs.append(c.g.node(o).id)
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return e

def compare_dirs(c: Ctx, a: str, b: str, stamp: str, ins: list<str>, desc: str) -> G.Edge:
    """Duas árvores têm de ser IDÊNTICAS, e a saída do `diff` vira o carimbo.

    Sem shell não há `&&` nem `>`, e não é preciso: a saída padrão da aresta vai
    para o arquivo (é um campo da aresta), e quem decide se passou é o STATUS do
    processo. O carimbo existe para o grafo ter o que datar.
    """
    e = G.new_edge(["diff", "-rq", a, b])
    for i in ins:
        e.ins.append(c.g.node(i).id)
    e.outs.append(c.g.node(stamp).id)
    e.stdout_to = stamp
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return e

def compare_files(c: Ctx, a: str, b: str, stamp: str, desc: str) -> G.Edge:
    e = G.new_edge(["cmp", a, b])
    e.ins.append(c.g.node(a).id)
    e.ins.append(c.g.node(b).id)
    e.outs.append(c.g.node(stamp).id)
    e.stdout_to = stamp
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return e

# ---------- utilidades de arquivo ----------
def glob(dir: str, suffix: str) -> list<str>:
    """Os arquivos de um diretório com um sufixo, ORDENADOS. O glob vive no
    DESCRITOR e nunca na aresta (1.6d): um padrão dentro da aresta faria o hash
    do comando mentir — duas execuções com arquivos diferentes no disco seriam
    builds diferentes com o mesmo grafo. E `os.listdir` ordena de propósito
    (111), então o grafo sai igual em toda máquina."""
    out: list<str> = []
    for n in os.listdir(dir):
        if n.endswith(suffix):
            out.append(path.join(dir, n))
    return out
