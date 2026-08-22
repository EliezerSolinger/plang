"""O GRAFO: nós, arestas gordas, e como um grafo entra (memória ou JSON).

A decisão 1.3 do `pbuild/DESIGN.md`: **a aresta é gorda e autônoma**. Ela carrega
tudo — o `argv`, as entradas nas três faixas, as saídas, o ambiente, o diretório,
para onde vai a saída padrão, e as marcas (`restat`, `generator`, `pool`). Não há
"regra" com variáveis a expandir, e é isso que tira do motor as 921 linhas que o
samurai gasta com escopo de variável.

Quem fatora repetição é o DESCRITOR, que é um programa — uma função pscript
fatora melhor que qualquer mecanismo de variável, e não precisa de regra de
escopo nenhuma. E há um ganho que só se vê depois: **dois grafos se comparam
linha a linha**. No modelo de regras, mudar uma regra altera mil arestas
invisivelmente, e é por isso que o ninja precisa do hash do comando no log para
perceber.

As três faixas de entrada, que vêm do ninja e cada uma existe por um motivo:

  * `ins`      — o que a ferramenta LÊ e o que decide se a saída está velha;
  * `implicit` — o mesmo, mas descoberto (o `depfile` do `cc -MD`), e por isso
                 não aparece no `argv`;
  * `order`    — "tem de existir ANTES", e não suja nada: é o diretório de saída,
                 que muda de mtime a cada arquivo criado ali dentro e
                 recompilaria o mundo se contasse como entrada de verdade.
"""
import json
import path

# ---------- o hash ----------
# FNV-1a de 64 bits. É hash de SUJEIRA — decide se uma aresta precisa rodar de
# novo —, não defesa contra adversário: o SHA-256 que os pacotes usam (F4) é
# outra função e outro problema. Escrito aqui porque o runtime tem o dele
# (`ps_hash_bytes`) e não o expõe à linguagem, e porque dez linhas legíveis
# valem mais que uma dependência a mais.
const FNV_OFF: u64 = 0xcbf29ce484222325
const FNV_PRIME: u64 = 0x100000001b3

def hash_str(seed: u64, s: str) -> u64:
    h = seed
    for ch in s:
        h = (h ^ u64(ord(ch))) %* FNV_PRIME
    return h

def sh_quote(s: str) -> str:
    """Aspas SIMPLES em volta de tudo, e a única fuga é a própria aspa simples —
    que se fecha, se escapa e se reabre. Dentro de aspas simples o shell não
    expande nada: nem `$`, nem `` ` ``, nem `*`, nem `~`. É a única forma de
    aspeamento de shell que não tem exceção."""
    if len(s) == 0:
        return "''"
    seguro = True
    for ch in s:
        c = ord(ch)
        ok = (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
        if not ok and ch != "/" and ch != "." and ch != "_" and ch != "-" and ch != "=" and ch != "+" and ch != ",":
            seguro = False
            break
    if seguro:
        return s
    out = "'"
    for ch2 in s:
        if ch2 == "'":
            out += "'\\''"
        else:
            out += ch2
    return out + "'"

# ---------- o nó: um arquivo ----------
const MTIME_UNKNOWN: int = -1
const MTIME_MISSING: int = -2

struct Node:
    """Um arquivo do grafo. O `mtime` é em NANOSSEGUNDOS, e isso não é preciosismo:
    num build rápido dois arquivos escritos no mesmo segundo são indistinguíveis
    em segundos, e é assim que um incremental esquece de refazer alguma coisa.
    """
    id: int
    p: str
    mtime: int          # ns; MTIME_UNKNOWN / MTIME_MISSING
    logmtime: int       # o que o log diz que ele tinha quando foi produzido
    loghash: u64        # ... e o hash do comando que o produziu
    gen: int            # a aresta que o produz; -1 = é fonte
    used: list<int>     # as arestas que o consomem
    dirty: bool

    def stat_now(self):
        """Pergunta ao disco UMA vez. Depois disso o valor fica: um build que
        perguntasse duas vezes poderia ver duas respostas diferentes e decidir
        com meia informação."""
        if self.mtime != MTIME_UNKNOWN:
            return
        if path.exists(self.p):
            self.mtime = path.getmtime_ns(self.p)
        else:
            self.mtime = MTIME_MISSING

# ---------- a aresta: um comando ----------
struct Edge:
    """Um comando com o que ele lê e o que ele escreve. Tudo o que muda o
    resultado entra no `hash` — `argv`, ambiente, diretório, para onde vai a
    saída, e o ALVO — porque a chave de sujeira tem de responder "isto foi
    produzido exatamente assim?" e não "por um comando parecido".
    """
    id: int
    argv: list<str>
    env: dict<str, str>       # vazio = herda o ambiente de quem chama
    cwd: str                  # "" = o diretório de quem chama
    stdout_to: str            # "" = a saída volta capturada
    ins: list<int>
    implicit: list<int>
    order: list<int>
    outs: list<int>
    out_implicit: list<int>
    restat: bool
    generator: bool
    pool: str                 # "" = nenhum; "console" = fala com o terminal
    depfile: str              # "" = nenhum
    desc: str                 # o que se imprime; "" = o próprio comando
    target: str               # o alvo de compilação (entra no hash)
    # estado durante um build
    hash: u64
    nblock: int               # entradas que faltam para esta poder rodar
    nprune: int               # ... e para as saídas poderem ser podadas
    want: bool                # está no build pedido
    dirty_in: bool
    dirty_out: bool
    dur_ms: int               # quanto levou da última vez (do log)
    cpw: int                  # peso do caminho crítico

    def label(self) -> str:
        if len(self.desc) > 0:
            return self.desc
        return " ".join(self.argv)

    def compute_hash(self) -> u64:
        """A chave de sujeira desta aresta. Cobre o ambiente EFETIVO porque o
        ninja não cobre, e é um furo real dele: trocar `CC=clang` por `CC=gcc`
        pode reaproveitar artefato em silêncio quando o compilador chega por
        variável. E cobre o ALVO porque artefato de `linux-amd64` não é artefato
        de `macos-arm64`.
        """
        h = FNV_OFF
        for a in self.argv:
            h = hash_str(h, a)
            h = hash_str(h, "\n")
        # o ambiente em ordem de CHAVE: um dict guarda ordem de inserção, e duas
        # montagens do mesmo ambiente não têm de inserir na mesma ordem
        ks: list<str> = []
        for k in self.env:
            ks.append(k)
        ks = sorted(ks)
        for k2 in ks:
            h = hash_str(h, k2)
            h = hash_str(h, "=")
            h = hash_str(h, self.env[k2])
            h = hash_str(h, "\n")
        h = hash_str(h, self.cwd)
        h = hash_str(h, self.stdout_to)
        h = hash_str(h, self.target)
        return h

# ---------- o grafo ----------
struct Graph:
    nodes: list<Node>
    edges: list<Edge>
    by_path: dict<str, int>
    default_targets: list<str>
    dupes: list<str>          # saídas com DOIS produtores (ver `add_edge`)

    def node(self, p: str) -> Node:
        """O nó de um caminho, criando-o se for a primeira vez. O caminho é
        NORMALIZADO na entrada: `a/../b/c.o` e `b/c.o` são o mesmo arquivo, e um
        grafo que os visse como dois nós recompilaria por nada."""
        np = path.normpath(p)
        if np in self.by_path:
            return self.nodes[self.by_path[np]]
        n = Node(len(self.nodes), np, MTIME_UNKNOWN, MTIME_MISSING, u64(0), -1, [], False)
        self.nodes.append(n)
        self.by_path[np] = n.id
        return n

    def add_edge(self, e: Edge) -> Edge:
        e.id = len(self.edges)
        self.edges.append(e)
        for o in e.outs:
            # duas arestas produzindo o MESMO arquivo é um grafo que não tem
            # resposta: qual das duas define o conteúdo depende da ordem em que
            # rodarem, e o incremental passa a depender de sorte. Anota-se aqui,
            # onde se sabe, e o motor recusa o build.
            if self.nodes[o].gen >= 0:
                self.dupes.append(self.nodes[o].p)
            self.nodes[o].gen = e.id
        for oi in e.out_implicit:
            if self.nodes[oi].gen >= 0:
                self.dupes.append(self.nodes[oi].p)
            self.nodes[oi].gen = e.id
        for i in e.ins:
            self.nodes[i].used.append(e.id)
        for im in e.implicit:
            self.nodes[im].used.append(e.id)
        for od in e.order:
            self.nodes[od].used.append(e.id)
        e.hash = e.compute_hash()
        return e

def new_graph() -> Graph:
    return Graph([], [], {}, [], [])

def new_edge(argv: list<str>) -> Edge:
    """Uma aresta com tudo no padrão. Existe porque uma aresta tem dezoito campos
    e construí-la por posição seria ilegível — e porque o padrão de cada campo é
    uma decisão que merece um lugar só."""
    return Edge(-1, argv, {}, "", "", [], [], [], [], [], False, False, "", "", "", "",
                u64(0), 0, 0, False, False, False, 0, 0)

# ---------- de JSON para grafo ----------
# A verdade do grafo é a ESTRUTURA (1.8: memória quando é a mesma execução). Ler
# JSON é apenas um dos construtores dela — o que serve quando quem descreve e
# quem executa não são o mesmo processo, e o que deixa a porta aberta para a
# linguagem do ninja entrar depois sem o motor saber a diferença.
private def getl(d: dict<str, any>, k: str) -> list<str>:
    out: list<str> = []
    if k in d:
        for x in d[k] as list<any>:
            out.append(x as str)
    return out

private def ss(d: dict<str, any>, k: str, dflt: str) -> str:
    if k in d:
        return d[k] as str
    return dflt

private def sb(d: dict<str, any>, k: str) -> bool:
    if k in d:
        return d[k] as bool
    return False

def from_json(text: str) -> Graph:
    root = json.parse(text) as dict<str, any>
    g = new_graph()
    g.default_targets = getl(root, "default")
    for ev in root["edges"] as list<any>:
        d = ev as dict<str, any>
        e = new_edge(getl(d, "argv"))
        e.cwd = ss(d, "cwd", "")
        e.stdout_to = ss(d, "stdout", "")
        e.pool = ss(d, "pool", "")
        e.depfile = ss(d, "depfile", "")
        e.desc = ss(d, "desc", "")
        e.target = ss(d, "target", "")
        e.restat = sb(d, "restat")
        e.generator = sb(d, "generator")
        if "env" in d:
            ed = d["env"] as dict<str, any>
            for k in ed:
                e.env[k] = ed[k] as str
        for p in getl(d, "in"):
            e.ins.append(g.node(p).id)
        for p2 in getl(d, "implicit"):
            e.implicit.append(g.node(p2).id)
        for p3 in getl(d, "order"):
            e.order.append(g.node(p3).id)
        for p4 in getl(d, "out"):
            e.outs.append(g.node(p4).id)
        for p5 in getl(d, "out_implicit"):
            e.out_implicit.append(g.node(p5).id)
        g.add_edge(e)
    return g

# ---------- de grafo para JSON ----------
# A exportação existe para três coisas: inspecionar (`--emit-graph`), versionar
# um grafo gerado, e alimentar quem não é este processo. Escrita à mão e não por
# reflexão porque a reflexão genérica é decisão de outra fase (F5) — e porque
# aqui se sabe exatamente o que cada campo significa.
# público: o `ppack --json` fala o mesmo JSON que a exportação do grafo, e um
# segundo escapador seria um segundo lugar para errar
def jstr(s: str) -> str:
    out = '"'
    for ch in s:
        if ch == '"':
            out += '\\"'
        elif ch == '\\':
            out += '\\\\'
        elif ch == '\n':
            out += '\\n'
        elif ch == '\t':
            out += '\\t'
        else:
            out += ch
    return out + '"'

private def jlist(g: Graph, ids: list<int>) -> str:
    parts: list<str> = []
    for i in ids:
        parts.append(jstr(g.nodes[i].p))
    return "[" + ", ".join(parts) + "]"

def to_json(g: Graph) -> str:
    out = '{\n  "version": 1,\n  "edges": [\n'
    first = True
    for e in g.edges:
        if not first:
            out += ',\n'
        first = False
        args: list<str> = []
        for a in e.argv:
            args.append(jstr(a))
        out += '    {"argv": [' + ", ".join(args) + ']'
        out += ', "in": ' + jlist(g, e.ins)
        if len(e.implicit) > 0:
            out += ', "implicit": ' + jlist(g, e.implicit)
        if len(e.order) > 0:
            out += ', "order": ' + jlist(g, e.order)
        out += ', "out": ' + jlist(g, e.outs)
        if len(e.out_implicit) > 0:
            out += ', "out_implicit": ' + jlist(g, e.out_implicit)
        if len(e.env) > 0:
            ks: list<str> = []
            for k in e.env:
                ks.append(k)
            ks = sorted(ks)
            evs: list<str> = []
            for k2 in ks:
                evs.append(jstr(k2) + ': ' + jstr(e.env[k2]))
            out += ', "env": {' + ", ".join(evs) + '}'
        if len(e.cwd) > 0:
            out += ', "cwd": ' + jstr(e.cwd)
        if len(e.stdout_to) > 0:
            out += ', "stdout": ' + jstr(e.stdout_to)
        if len(e.pool) > 0:
            out += ', "pool": ' + jstr(e.pool)
        if len(e.depfile) > 0:
            out += ', "depfile": ' + jstr(e.depfile)
        if len(e.desc) > 0:
            out += ', "desc": ' + jstr(e.desc)
        if len(e.target) > 0:
            out += ', "target": ' + jstr(e.target)
        if e.restat:
            out += ', "restat": true'
        if e.generator:
            out += ', "generator": true'
        out += '}'
    out += '\n  ]'
    if len(g.default_targets) > 0:
        ds: list<str> = []
        for t in g.default_targets:
            ds.append(jstr(t))
        out += ',\n  "default": [' + ", ".join(ds) + ']'
    return out + '\n}\n'
