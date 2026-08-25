"""`log` — registo estruturado, e o punho é explícito porque tem de ser.

**A §4.1 do `STDLIB.md` decidiu que isto seria GLOBAL** — `log.info("...")` sem
passar nada — apoiada na 42.2: uma global mutável no pscript é privada do worker,
portanto cada worker teria o seu logger sem contenção e sem cadeado.

**Não dá, e a razão é do sistema de módulos:** um módulo IMPORTADO não pode ter
estado no topo. Só um programa pode, porque só ele tem uma ordem de execução
definida. Um pacote é um conjunto de definições.

Havia duas saídas, e a escolhida diz mais do que a outra:

* pôr o `log` no RUNTIME, ao lado do `gc` e do `sched`, e ganhar a global. Isso
  seria meter uma escolha de POLÍTICA — para onde vão os registos, a partir de
  que nível — dentro da linguagem, e a linguagem é o sítio errado para política;
* **um punho que o programa cria e guarda**, que é o que o `slog` do Go e o
  `tracing` do Rust fazem, e é o que está aqui.

O que se perde é uma palavra por chamada. O que se ganha é que **a história dos
workers deixa de ser magia**: um worker que precise de outro nível recebe o punho
dele na entrada, à vista, em vez de alguém descobrir mais tarde que o `set_level`
do principal não chegou lá.

**E não há cadeado nenhum**, que era a metade boa da decisão original e essa
mantém-se: uma linha inteira sai atómica porque o `print` já garante isso (107.2,
`tests/print-atomic.sh`), e um logger que escreva por linhas herda a garantia em
vez de a reconstruir. O `logging` do Python tem um cadeado; este não tem nada.

    lg = log.logger()
    log.info(lg, "server started", "port", 8080)
    # ts=1756... level=info msg="server started" port=8080
"""
import time
import json


const DEBUG = 10
const INFO = 20
const WARN = 30
const ERROR = 40


struct Logger:
    """O que decide o que sai e como. Um por programa, ou um por worker."""
    level: int
    as_json: bool
    with_time: bool


def logger(level: int = INFO) -> Logger:
    return Logger(level, False, True)


def json_logger(level: int = INFO) -> Logger:
    """O mesmo, em JSON por linha — para quando é uma máquina a ler."""
    return Logger(level, True, True)


def name_of(n: int) -> str:
    if n <= DEBUG:
        return "debug"
    if n <= INFO:
        return "info"
    if n <= WARN:
        return "warn"
    return "error"


def jquote(s: str) -> str:
    out: List<str> = ["\""]
    for c in s:
        if c == "\"" or c == "\\":
            out.append("\\")
            out.append(c)
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        else:
            out.append(c)
    out.append("\"")
    return "".join(out)


def quote(s: str) -> str:
    """Aspas só quando fazem falta, que é o que torna o `logfmt` legível.

    Um valor sem espaços, sem aspas e sem `=` sai cru; o resto vai entre aspas
    com as escapadas do costume. Aspar tudo daria um registo correcto e ilegível.
    """
    need = len(s) == 0
    for c in s:
        if c == " " or c == "\"" or c == "=" or c == "\n" or c == "\\" or c == "\t":
            need = True
    if not need:
        return s
    return jquote(s)


def stamp() -> str:
    """Segundos desde a epoch com milissegundos.

    **Não formata a data aqui** — isso é o `datetime`, e este pacote não vai
    depender daquele para escrever uma linha. Quem quiser ISO aplica-lhe o
    `datetime` do outro lado, sobre o número que está aqui.
    """
    t = time.time()
    s = int(t)
    ms = int((t - float(s)) * 1000.0)
    d = str(ms)
    while len(d) < 3:
        d = "0" + d
    return str(s) + "." + d


# ---------- as funções ----------
#
# **Funções livres e não métodos**, e há duas razões. A da linguagem: os
# argumentos variádicos (`*kv`) valem numa função e não num método. E a do
# desenho, que é a mesma que a §5 do `STDLIB.md` já tinha tomado para os
# streams — *"tudo o resto são funções livres"* —, portanto isto não é uma
# excepção: é a regra da casa.

def enabled(lg: Logger, n: int) -> bool:
    return n >= lg.level


def emit(lg: Logger, n: int, msg: str, kv: List<any>):
    # a PARIDADE confere-se ANTES do nível, e é de propósito: um par mal escrito
    # é um erro de programa, e um erro de programa que só aparece quando alguém
    # baixa o nível em produção é o pior sítio para ele aparecer
    if len(kv) % 2 != 0:
        raise error("log: the extra arguments are key/value PAIRS — there are "
                    + str(len(kv)) + " of them, so one key has no value", VALUE)
    if n < lg.level:
        return
    parts: List<str> = []
    if lg.as_json:
        parts.append("{")
        if lg.with_time:
            parts.append("\"ts\":" + jquote(stamp()) + ",")
        parts.append("\"level\":" + jquote(name_of(n)) + ",\"msg\":" + jquote(msg))
        i = 0
        while i < len(kv):
            # o VALOR vai como JSON e não como texto: um número sai número e um
            # bool sai bool, que é a razão inteira de haver saída em JSON. É o
            # `json.stringify` da linguagem, sobre um `any` — que só pode conter
            # exactamente as formas que o JSON tem (39.2)
            parts.append("," + jquote(str(kv[i])) + ":" + json.stringify(kv[i + 1]))
            i += 2
        parts.append("}")
    else:
        if lg.with_time:
            parts.append("ts=" + stamp() + " ")
        parts.append("level=" + name_of(n) + " msg=" + quote(msg))
        i = 0
        while i < len(kv):
            parts.append(" " + str(kv[i]) + "=" + quote(str(kv[i + 1])))
            i += 2
    # UMA chamada ao `print`, e é aí que a atomicidade mora (107.2). Escrever
    # aos pedaços entrelaçaria as linhas de doze workers.
    print("".join(parts))


# **Pares alternados, e é a forma do `slog` do Go**: `log.info(lg, "started",
# "port", 8080)`. A alternativa que a §4.1 escreveu — `key=value` no sítio da
# chamada — não pode ser: os argumentos nomeados do pscript são de tempo de
# compilação e quem os recebe tem de os DECLARAR, portanto uma chave arbitrária
# não cabe lá.
def debug(lg: Logger, msg: str, *kv: List<any>):
    emit(lg, DEBUG, msg, kv)


def info(lg: Logger, msg: str, *kv: List<any>):
    emit(lg, INFO, msg, kv)


def warn(lg: Logger, msg: str, *kv: List<any>):
    emit(lg, WARN, msg, kv)


def error_(lg: Logger, msg: str, *kv: List<any>):
    """`error` é o construtor de excepções da linguagem, portanto este chama-se
    `error_` — e o sublinhado é preferível a inventar um sinónimo, porque quem lê
    `log.error_` sabe imediatamente o que aconteceu ao nome."""
    emit(lg, ERROR, msg, kv)
