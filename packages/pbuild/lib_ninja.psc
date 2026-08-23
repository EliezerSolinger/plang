"""`--emit-ninja`: a aresta gorda descida para texto ninja.

Isto NÃO é um segundo motor: é uma EXPORTAÇÃO, e ela existe por dois motivos
concretos, nenhum dos dois sendo "e se o pbuild não servir".

  * **o bootstrap numa máquina limpa.** Quem clona este repositório sem ter o
    `plangc` nem o `ppack` construídos consegue `cc bootstrap/selfhost/*.c` e
    `ninja`, e sai com o compilador inteiro. O `build.ninja` comitado na raiz é
    a primeira construção, e depois dela o `ppack` toma conta.
  * **o compdb.** `ninja -t compdb` dá o `compile_commands.json` que todo
    servidor de linguagem e todo `clang-tidy` do mundo espera. Escrever o nosso
    seria reescrever um formato que já existe.

O que a exportação NÃO promete é fidelidade total, e o lugar honesto de dizer
isso é aqui:

  * o ninja não tem ambiente por aresta. O nosso `env=` SUBSTITUI o ambiente, e
    isso desce para um `env -i K=V ... comando` explícito no texto do comando —
    o que funciona, mas passa a depender de um `env` no PATH;
  * o ninja não tem diretório por aresta. O `cwd=` desce para um `sh -c 'cd D &&
    exec ...'`, com o mesmo tipo de dependência;
  * o `restat` do ninja compara MTIME e o nosso compara CONTEÚDO (ver
    `lib_log.psc`), então a poda exportada poda MENOS que a nossa. Recompila a
    mais, nunca a menos: o erro fica do lado seguro;
  * o hash de comando do ninja não cobre o ambiente; o nosso cobre. Trocar de
    compilador por variável de ambiente é reaproveitamento silencioso lá, e não
    é aqui.

Uma REGRA POR ARESTA, e isto é uma consequência do modelo, não uma preguiça: a
aresta gorda não tem "regra" separada do comando — o comando dela É o comando
dela, montado por uma função pscript que já sabia tudo. Um `build.ninja` com
mil regras é maior que um com dez, e é exatamente igual de rápido: o ninja lê o
arquivo uma vez e o `build.ninja` deste repositório tem dezenas de kB.

O ASPEAMENTO é gerado, e é por isso que ele está certo. A pergunta "e se o
caminho tiver um espaço" é a pergunta que derruba todo sistema de build que
monta linha de comando por concatenação de texto; aqui nós sabemos onde cada
argumento começa e acaba, porque nunca houve uma linha — houve um vetor.
"""
import lib_graph as G

# ---------- as duas gramáticas ----------
# (o aspeamento de SHELL mora em `lib_graph`, porque a exportação não é a única
# que precisa dele — ver `G.sh_quote`)
# O ninja e o shell escapam coisas DIFERENTES, e confundi-las é o defeito
# clássico. `ninja_path` protege o que o ninja lê (o `$` dele, o `:` que separa
# saídas de regra, o espaço que separa caminhos); `sh_quote` protege o que o
# shell lê DEPOIS, dentro do valor de `command =`.
def ninja_path(s: str) -> str:
    out = ""
    for ch in s:
        if ch == "$":
            out += "$$"
        elif ch == " ":
            out += "$ "
        elif ch == ":":
            out += "$:"
        elif ch == "\n":
            out += "$\n"
        else:
            out += ch
    return out

def esc_command(s: str) -> str:
    """O texto do comando ainda passa pelo leitor do ninja, que come `$`. Uma
    linha de comando não pode ter quebra de linha, e nenhuma das nossas tem."""
    out = ""
    for ch in s:
        if ch == "$":
            out += "$$"
        elif ch == "\n":
            out += " "
        else:
            out += ch
    return out

# ---------- uma aresta ----------
def cmdline(e: G.Edge) -> str:
    """O vetor de argumentos vira UMA linha de shell — com `env -i` na frente se
    a aresta trouxe ambiente, com um `cd` se ela trouxe diretório, e com um
    redirecionamento se ela mandava a saída para arquivo."""
    partes: list<str> = []
    for a in e.argv:
        partes.append(G.sh_quote(a))
    linha = " ".join(partes)
    if len(e.stdout_to) > 0:
        linha += " > " + G.sh_quote(e.stdout_to)
    if len(e.env) > 0:
        # a MESMA semântica do nosso `os.run`: substitui, não mescla. `env -i`
        # é o que diz isso em shell, e as chaves vão em ordem para que dois
        # `--emit-ninja` do mesmo grafo deem o mesmo arquivo
        ks: list<str> = []
        for k in e.env:
            ks.append(k)
        ks = sorted(ks)
        pre: list<str> = ["env", "-i"]
        for k2 in ks:
            pre.append(G.sh_quote(k2 + "=" + e.env[k2]))
        linha = " ".join(pre) + " " + linha
    if len(e.cwd) > 0:
        linha = "cd " + G.sh_quote(e.cwd) + " && " + linha
    if len(e.cwd) > 0 or len(e.env) > 0:
        linha = "sh -c " + G.sh_quote(linha)
    return esc_command(linha)

private def paths(g: G.Graph, ids: list<int>) -> str:
    out: list<str> = []
    for i in ids:
        out.append(ninja_path(g.nodes[i].p))
    return " ".join(out)

# ---------- o arquivo ----------
def emit(g: G.Graph) -> str:
    out = "# gerado por `ppack ninja` — NÃO editar à mão.\n"
    out += "#\n"
    out += "# Este arquivo é o BOOTSTRAP: numa máquina sem `ppack` construído,\n"
    out += "#   cc -O2 -o plangc bootstrap/selfhost/*.c && ninja\n"
    out += "# constrói tudo. Depois disso o `ppack` é quem manda, e ele lê o\n"
    out += "# descritor em pscript, não este arquivo.\n"
    out += "#\n"
    out += "# A exportação é FIEL no que constrói e CONSERVADORA no que poda: o\n"
    out += "# `restat` daqui compara data e o nosso compara conteúdo, então este\n"
    out += "# arquivo recompila a mais, nunca a menos.\n"
    out += "\n"
    out += "ninja_required_version = 1.5\n"
    out += "\n"
    tem_console = False
    for e0 in g.edges:
        if e0.pool == "console":
            tem_console = True
    if tem_console:
        out += "# o `pool console` do ninja já existe e tem exatamente o sentido\n"
        out += "# que o nosso tem: uma aresta por vez, falando com o terminal.\n"
        out += "\n"
    for e in g.edges:
        nome = "e" + str(e.id)
        out += "rule " + nome + "\n"
        out += "  command = " + cmdline(e) + "\n"
        if len(e.desc) > 0:
            out += "  description = " + esc_command(e.desc) + "\n"
        if len(e.depfile) > 0:
            out += "  depfile = " + ninja_path(e.depfile) + "\n"
            out += "  deps = gcc\n"
        if e.restat:
            out += "  restat = 1\n"
        if e.generator:
            out += "  generator = 1\n"
        if e.pool == "console":
            out += "  pool = console\n"
        out += "\n"
        linha = "build " + paths(g, e.outs)
        if len(e.out_implicit) > 0:
            linha += " | " + paths(g, e.out_implicit)
        linha += ": " + nome
        if len(e.ins) > 0:
            linha += " " + paths(g, e.ins)
        if len(e.implicit) > 0:
            linha += " | " + paths(g, e.implicit)
        if len(e.order) > 0:
            linha += " || " + paths(g, e.order)
        out += linha + "\n\n"
    if len(g.default_targets) > 0:
        ds: list<str> = []
        for d in g.default_targets:
            ds.append(ninja_path(d))
        out += "default " + " ".join(ds) + "\n"
    return out
