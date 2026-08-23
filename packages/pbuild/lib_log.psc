"""O LOG do build, e o `depfile` que o `cc` deixa para trás.

O log é o que faz um build INCREMENTAL ser possível, e ele guarda por saída
cinco coisas, cada uma respondendo a uma pergunta que o disco sozinho não
responde:

  * o **mtime** de quando o CONTEÚDO dela mudou pela última vez — porque o mtime
    de agora pode ser o de um `touch`, e porque uma corrida que morreu no meio
    deixa um arquivo novo com conteúdo velho;
  * o **vtime**, a data da entrada mais nova quando a aresta foi conferida — que
    é uma pergunta DIFERENTE da anterior, e a nota logo abaixo diz por quê;
  * o **hash do comando** que a produziu — é o que pega "mudei uma flag", que
    nenhuma comparação de datas pega;
  * o **hash do CONTEÚDO** da saída — que o ninja NÃO guarda, e que é o que faz
    o `restat` funcionar aqui: o `restat` dele compara mtime, e uma ferramenta
    que reescreve o arquivo toda vez (o nosso `plangc` reescreve) muda o mtime
    mesmo produzindo bytes idênticos. Sem o conteúdo, a poda nunca aconteceria —
    e a poda é justamente o que transforma "regenerei C igual" em "não
    recompilei os 18 s";
  * a **duração** — que o ninja grava e não usa, e que aqui decide a ORDEM da
    fila: com o caminho crítico pesado por tempo, a aresta mais cara começa
    primeiro. Neste repositório isso vale ~4 s de 5 (um TU de 4,96 s num build
    de 5,0 s), e sem ela a aresta cara pode ir por último.

O formato é texto, uma linha por saída, porque um log de build é a primeira coisa
que alguém abre quando o incremental faz algo inesperado.
"""
import os
import path

const LOG_HEADER: str = "# pbuild log v2"

record LogEnt:
    mtime: int     # quando o CONTEÚDO desta saída mudou pela última vez
    vtime: int     # ... e a data da entrada mais nova quando ela foi CONFERIDA
    dur_ms: int
    hash: u64      # o hash do COMANDO que produziu esta saída
    chash: u64     # ... e o hash do CONTEÚDO dela, para o `restat`

# Por que DUAS datas, que é a pergunta que este arquivo tem de responder.
#
# Numa aresta `restat` as duas divergem, e é justamente aí que o incremental se
# ganha ou se perde. O gerador rodou (a entrada mudou), a saída saiu IDÊNTICA:
#
#   * quem LÊ a saída não precisa rodar — para ele, ela não mudou, e a data que
#     vale é a de quando o conteúdo mudou pela última vez. É o `mtime`.
#   * a ARESTA que a produziu, essa está em dia com as entradas de agora, e não
#     pode rodar de novo na corrida seguinte. É o `vtime`.
#
# Uma data só não consegue dizer as duas coisas. Guardar a antiga fazia a aresta
# rodar para sempre; guardar a nova fazia quem lê recompilar por nada. As duas
# formas estiveram no código, cada uma com o seu defeito, e é por isso que a
# explicação está aqui.

# ---------- hexadecimal, à mão ----------
# O hash é u64 e não cabe num `int` com sinal, então ele não pode ir ao log em
# decimal e voltar por `int(s)`. Dezasseis dígitos hexa resolvem, e a conversão
# nos dois sentidos é curta o bastante para não valer uma dependência.
const HEXD: str = "0123456789abcdef"

def to_hex16(v: u64) -> str:
    out = ""
    i = 0
    while i < 16:
        sh = u64((15 - i) * 4)
        d = int((v >> sh) & u64(15))
        out += HEXD[d]
        i += 1
    return out

def from_hex(s: str) -> u64:
    v = u64(0)
    for ch in s:
        c = ord(ch)
        d = 0
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        else:
            return v
        v = (v %* u64(16)) %+ u64(d)
    return v

# ---------- o log ----------
struct Log:
    p: str
    ents: dict<str, LogEnt>
    dirty: bool

    def get(self, key: str) -> LogEnt:
        """A entrada de uma saída, ou uma vazia — `mtime` ausente, hash zero — que
        é o que "nunca foi construída" quer dizer para quem decide sujeira."""
        if key in self.ents:
            return self.ents[key]
        return LogEnt(-2, -2, 0, u64(0), u64(0))

    def has(self, key: str) -> bool:
        return key in self.ents

    def put(self, key: str, mtime: int, vtime: int, dur_ms: int, h: u64, ch: u64):
        self.ents[key] = LogEnt(mtime, vtime, dur_ms, h, ch)
        self.dirty = True

async def load(p: str) -> Log:
    lg = Log(p, {}, False)
    if not path.exists(p):
        return lg
    f = await open(p, "r")
    txt = await f.text()
    await f.close()
    first = True
    for line in txt.split("\n"):
        if first:
            first = False
            continue          # o cabeçalho, que diz a versão do formato
        if len(line) == 0:
            continue
        parts = line.split("\t")
        if len(parts) != 6:
            # uma linha estragada não invalida o log inteiro: ela vira "essa
            # saída nunca foi construída", que é o pior caso seguro
            continue
        lg.ents[parts[5]] = LogEnt(int(parts[0]), int(parts[1]), int(parts[2]),
                                   from_hex(parts[3]), from_hex(parts[4]))
    return lg

async def save(lg: Log):
    """Reescreve o log inteiro. O ninja acrescenta linha a linha e compacta
    quando incha; aqui o arquivo tem uma linha por saída do projeto (milhares, não
    milhões) e reescrever é mais simples e não deixa lixo para trás."""
    if not lg.dirty:
        return
    d = path.dirname(lg.p)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    out = LOG_HEADER + "\n"
    ks: list<str> = []
    for k in lg.ents:
        ks.append(k)
    ks = sorted(ks)     # ordenado: dois builds iguais dão logs iguais
    for k2 in ks:
        e = lg.ents[k2]
        out += (str(e.mtime) + "\t" + str(e.vtime) + "\t" + str(e.dur_ms) + "\t"
                + to_hex16(e.hash) + "\t" + to_hex16(e.chash) + "\t" + k2 + "\n")
    f = await open(lg.p, "w")
    await f.write(out)
    await f.close()
    lg.dirty = False

# ---------- o depfile ----------
# O `cc -MD` deixa um arquivo no formato do Makefile: `alvo: dep1 dep2 \` com
# continuação de linha. O lado C continua sendo estranho para nós (é o `cc` que
# sabe quais headers leu), e este é o preço — trinta linhas de parser. Do NOSSO
# lado o compilador responde a pergunta 1 do protocolo e nada disto é preciso.
def parse_depfile(txt: str) -> list<str>:
    out: list<str> = []
    # junta as continuações e troca o que separa por espaço
    flat = ""
    i = 0
    n = len(txt)
    while i < n:
        ch = txt[i]
        if ch == "\\" and i + 1 < n and txt[i + 1] == "\n":
            flat += " "
            i += 2
            continue
        if ch == "\\" and i + 1 < n and txt[i + 1] == " ":
            flat += "\x01"      # espaço ESCAPADO: parte do nome, não separador
            i += 2
            continue
        if ch == "\n" or ch == "\t":
            flat += " "
            i += 1
            continue
        flat += ch
        i += 1
    # tudo antes do primeiro `:` é o alvo, e o alvo já está no grafo
    ci = flat.find(":")
    if ci < 0:
        return out
    for piece in flat[ci + 1:].split(" "):
        if len(piece) == 0:
            continue
        out.append(piece.replace("\x01", " "))
    return out
