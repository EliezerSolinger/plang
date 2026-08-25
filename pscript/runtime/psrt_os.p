# psrt_os.p — CAMADA 4: a camada de SISTEMA. `os` (diretório, criar, apagar,
# renomear) e `path` (contas sobre o nome, e três perguntas ao disco).
#
# Chama a memória e os valores, como a biblioteca portada. Fica em P por decisão
# sua (108.4), e é PORTE do `pstudio/psys.p` — o editor já tinha esta camada
# escrita; o que a bateria 111 faz é mudá-la de casa e dar-lhe a forma do
# Python, para que o pforge e o pstudio usem a MESMA.
#
# A regra do `errno` do runtime vale aqui também: a mensagem vem da OPERAÇÃO e
# do caminho, nunca do `errno` — `errno` é macro, e P não vê macro.
include <dirent.h>
include <sys/mman.h>   # 137: mmap/munmap/madvise/msync/mlock
include <fcntl.h>      # ... e o open(2) que os alimenta
include <unistd.h>
include <sys/stat.h>
include <sys/types.h>
include <sys/wait.h>   # 119/F6: `waitpid` com WNOHANG, para saber se o filho
                       #   que se lançou ainda está de pé
include <signal.h>
include <sys/ioctl.h>   # F8: `struct winsize` and TIOCSWINSZ, for a terminal
                        #     that has to be told when the window changed
import "psrt_types.ph"
import "psrt_mem.ph"
import "psrt_val.ph"
import "psrt_rt.ph"    # 118: o pool e a task que `os.run` devolve
import "psrt_os.ph"

# ---------- o caminho como o sistema o quer ----------
# Uma str do pscript pode conter o byte 0 no meio; um caminho não pode. Se
# passasse assim, a chamada veria o caminho CORTADO no zero e agiria sobre outro
# arquivo — então isto levanta em vez de deixar passar.
private def os_cstr(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> const *char:
    if p == None:
        ps_raise(ctx, "a path cannot be None", PS_CAT_VALUE, file, line)
        return None
    if usize(strlen(p->data)) != usize(p->len):
        ps_raise(ctx, "this path has a NUL byte in it", PS_CAT_VALUE, file, line)
        return None
    return p->data

# a mensagem diz O QUE se estava fazendo e COM QUAL caminho
private def os_fail(ctx: *PsCtx, what: const *char, p: *PsStr, file: const *char, line: i32):
    msg: char[512]
    snprintf(msg, 512, "%s '%s'", what, p->data)
    ps_raise(ctx, msg, PS_CAT_IO, file, line)

# ---------- `os` ----------
def ps_os_listdir(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32) -> *PsList:
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, 0)
    cs: const *char = os_cstr(ctx, path, file, line)
    if cs == None:
        return out
    d: *DIR = opendir(cs)
    if d == None:
        os_fail(ctx, "cannot list the directory", path, file, line)
        return out
    while True:
        de: *dirent = readdir(d)
        if de == None:
            break
        nm: const *char = de->d_name
        if strcmp(nm, ".") == 0 or strcmp(nm, "..") == 0:
            continue
        *(**PsStr)(ps_list_push(ctx, out)) = ps_str_new(ctx, nm, strlen(nm))
    closedir(d)
    # ordena por bytes DEPOIS de alocar tudo (o `base` de uma lista muda quando
    # ela cresce). Inserção porque um diretório é pequeno, e a ordem é a mesma
    # que o `sorted()` produziria — é a mesma comparação.
    base: **PsStr = (**PsStr)(ps_list_base(out))
    n: i64 = out->len
    for i in range(1, n):
        j: i64 = i
        while j > 0 and ps_str_lt(base[j], base[j - 1]) < 0:
            t: *PsStr = base[j]
            base[j] = base[j - 1]
            base[j - 1] = t
            j -= 1
    return out

# 511 é 0777, que é o modo que o Python passa: o `umask` do processo recorta o
# que sobra, e é o mesmo resultado de um `mkdir` na linha de comando.
private def os_mkdir_one(cs: const *char) -> bool:
    return mkdir(cs, 511) == 0

private def os_is_dir(cs: const *char) -> bool:
    sb: stat
    if stat(cs, &sb) != 0:
        return False
    # S_ISDIR é macro (desaparece no ingest): a máscara POSIX estável
    return (i32(sb.st_mode) & 0xF000) == 0x4000

def ps_os_mkdir(ctx: *PsCtx, path: *PsStr, parents: bool, file: const *char, line: i32):
    cs: const *char = os_cstr(ctx, path, file, line)
    if cs == None:
        return
    if not parents:
        if not os_mkdir_one(cs):
            os_fail(ctx, "cannot create the directory", path, file, line)
        return
    # `mkdir -p`: cria cada prefixo, e um prefixo que já é diretório está certo.
    # Trabalha sobre uma CÓPIA porque escreve o '\0' no lugar da barra e o
    # devolve — mexer na str do programa seria mudar um valor por baixo dele.
    n: usize = usize(path->len)
    buf: *char = (*char)(malloc(n + 1))
    memcpy(buf, cs, n)
    buf[n] = '\0'
    i: usize = 1        # 1 e não 0: a barra da raiz não é um prefixo a criar
    while i <= n:
        if i == n or buf[i] == '/':
            if i == n and n > 0 and buf[n - 1] == '/':
                break   # "a/b/" — o prefixo já foi criado no passo anterior
            saved: char = buf[i]
            buf[i] = '\0'
            if not os_is_dir(buf) and not os_mkdir_one(buf):
                buf[i] = saved
                free(buf)
                os_fail(ctx, "cannot create the directory", path, file, line)
                return
            buf[i] = saved
        i += 1
    free(buf)

def ps_os_remove(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32):
    cs: const *char = os_cstr(ctx, path, file, line)
    if cs == None:
        return
    if remove(cs) != 0:
        os_fail(ctx, "cannot remove", path, file, line)

def ps_os_rmdir(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32):
    cs: const *char = os_cstr(ctx, path, file, line)
    if cs == None:
        return
    if rmdir(cs) != 0:
        os_fail(ctx, "cannot remove the directory", path, file, line)

def ps_os_rename(ctx: *PsCtx, src: *PsStr, dst: *PsStr, file: const *char, line: i32):
    a: const *char = os_cstr(ctx, src, file, line)
    if a == None:
        return
    b: const *char = os_cstr(ctx, dst, file, line)
    if b == None:
        return
    if rename(a, b) != 0:
        msg: char[512]
        snprintf(msg, 512, "cannot rename '%s' to '%s'", a, b)
        ps_raise(ctx, msg, PS_CAT_IO, file, line)

def ps_os_getcwd(ctx: *PsCtx, file: const *char, line: i32) -> *PsStr:
    buf: char[4096]
    if getcwd(buf, 4096) == None:
        ps_raise(ctx, "cannot read the working directory", PS_CAT_IO, file, line)
        return ps_str_new(ctx, "", 0)
    return ps_str_new(ctx, buf, strlen(buf))

# ---------- `path`: as contas sobre o NOME ----------
# `posixpath.join`: um segundo pedaço ABSOLUTO joga o primeiro fora, e é por isso
# que `join(dir, arg)` faz o que se espera quando `arg` veio da linha de comando.
def ps_os_join(ctx: *PsCtx, a: *PsStr, b: *PsStr) -> *PsStr:
    na: usize = usize(a->len)
    nb: usize = usize(b->len)
    if nb > 0 and b->data[0] == '/':
        return ps_str_new(ctx, b->data, nb)
    if na == 0:
        return ps_str_new(ctx, b->data, nb)
    sep: bool = a->data[na - 1] != '/'
    r: *char = (*char)(malloc(na + nb + 2))
    memcpy(r, a->data, na)
    k: usize = na
    if sep:
        r[k] = '/'
        k += 1
    memcpy(r + k, b->data, nb)
    s: *PsStr = ps_str_new(ctx, r, k + nb)
    free(r)
    return s

# `dirname('a')` é `''` e não `'.'` — é o Python, e é o oráculo que manda
def ps_os_dirname(ctx: *PsCtx, p: *PsStr) -> *PsStr:
    n: usize = usize(p->len)
    i: usize = 0
    k: usize = n
    while k > 0:
        if p->data[k - 1] == '/':
            i = k
            break
        k -= 1
    # o "head" é tudo até a última barra, inclusive; barras à direita saem, a
    # menos que o head seja SÓ barras (a raiz)
    if i == 0:
        return ps_str_new(ctx, "", 0)
    all_slash: bool = True
    for j in range(i):
        if p->data[j] != '/':
            all_slash = False
            break
    if all_slash:
        return ps_str_new(ctx, p->data, i)
    e: usize = i
    while e > 0 and p->data[e - 1] == '/':
        e -= 1
    return ps_str_new(ctx, p->data, e)

def ps_os_basename(ctx: *PsCtx, p: *PsStr) -> *PsStr:
    n: usize = usize(p->len)
    i: usize = 0
    k: usize = n
    while k > 0:
        if p->data[k - 1] == '/':
            i = k
            break
        k -= 1
    return ps_str_new(ctx, p->data + i, n - i)

# `posixpath.normpath`, transcrito: `..` come o componente anterior, `.` e vazio
# desaparecem, e um `..` que não tem o que comer só some se o caminho for
# ABSOLUTO (em `/..` a raiz é o próprio pai; em `../x` o `..` é informação).
#
# A pilha de componentes é a pilha de OFFSETS no buffer de saída: empilhar é
# escrever, desempilhar é truncar. Não há segundo array e não há cópia.
def ps_os_normpath(ctx: *PsCtx, p: *PsStr) -> *PsStr:
    n: usize = usize(p->len)
    if n == 0:
        return ps_str_new(ctx, ".", 1)
    src: const *char = p->data
    # `//x` é POSIX-definido (o sistema pode dar-lhe outro sentido) e o Python
    # preserva as DUAS barras; três ou mais colapsam para uma
    lead: usize = 0
    if src[0] == '/':
        lead = 1
        if n > 1 and src[1] == '/' and (n == 2 or src[2] != '/'):
            lead = 2
    out: *char = (*char)(malloc(n + 3))
    starts: *usize = (*usize)(malloc((n + 2) * sizeof(usize)))
    o: usize = 0
    ns: usize = 0
    i: usize = 0
    while i <= n:
        if i == n or src[i] == '/':
            # o componente é [st, i)
            st: usize = i
            while st > 0 and src[st - 1] != '/':
                st -= 1
            clen: usize = i - st
            if clen == 0 or (clen == 1 and src[st] == '.'):
                i += 1
                continue
            dotdot: bool = clen == 2 and src[st] == '.' and src[st + 1] == '.'
            if dotdot:
                last_dd: bool = False
                if ns > 0:
                    ll: usize = o - starts[ns - 1]
                    last_dd = ll == 2 and out[starts[ns - 1]] == '.' and out[starts[ns - 1] + 1] == '.'
                if ns > 0 and not last_dd:
                    ns -= 1
                    o = starts[ns]
                    if ns > 0:
                        o -= 1      # e a barra que o separava
                    i += 1
                    continue
                if lead > 0 and ns == 0:
                    i += 1          # `/..` é `/`
                    continue
            if ns > 0:
                out[o] = '/'
                o += 1
            starts[ns] = o
            ns += 1
            memcpy(out + o, src + st, clen)
            o += clen
        i += 1
    r: *PsStr = None
    if lead > 0:
        buf: *char = (*char)(malloc(o + lead + 1))
        for j in range(lead):
            buf[j] = '/'
        memcpy(buf + lead, out, o)
        r = ps_str_new(ctx, buf, o + lead)
        free(buf)
    elif o == 0:
        r = ps_str_new(ctx, ".", 1)
    else:
        r = ps_str_new(ctx, out, o)
    free(starts)
    free(out)
    return r

def ps_os_abspath(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> *PsStr:
    if usize(p->len) > 0 and p->data[0] == '/':
        return ps_os_normpath(ctx, p)
    cwd: *PsStr = ps_os_getcwd(ctx, file, line)
    return ps_os_normpath(ctx, ps_os_join(ctx, cwd, p))

# ---------- `path`: as três perguntas ao disco ----------
# kind: 0 existe, 1 é diretório, 2 é arquivo comum
def ps_os_exists(ctx: *PsCtx, p: *PsStr, kind: i32, file: const *char, line: i32) -> bool:
    cs: const *char = os_cstr(ctx, p, file, line)
    if cs == None:
        return False
    sb: stat
    if stat(cs, &sb) != 0:
        return False
    m: i32 = i32(sb.st_mode) & 0xF000
    if kind == 1:
        return m == 0x4000
    if kind == 2:
        return m == 0x8000
    return True

def ps_os_getsize(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> i64:
    cs: const *char = os_cstr(ctx, p, file, line)
    if cs == None:
        return 0
    sb: stat
    if stat(cs, &sb) != 0:
        os_fail(ctx, "cannot stat", p, file, line)
        return 0
    return i64(sb.st_size)

# O nome portátil do mtime é MACRO, e macro desaparece no ingest — então quem
# escolhe é o `hasfield`, em tempo de compilação, e o ramo morto nunca é
# verificado (nomear um campo que a plataforma não tem é seguro):
#   glibc  st_mtim      (struct timespec, POSIX.1-2008; pede -D_DEFAULT_SOURCE
#                        sob um -std=cNN estrito, que o build do runtime passa)
#   macOS  st_mtimespec (struct timespec, __DARWIN_UNIX03 — o padrão)
#   antigo st_mtime     (time_t direto, sem a parte de sub-segundo)
def ps_os_getmtime(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> i64:
    cs: const *char = os_cstr(ctx, p, file, line)
    if cs == None:
        return 0
    sb: stat
    if stat(cs, &sb) != 0:
        os_fail(ctx, "cannot stat", p, file, line)
        return 0
    if hasfield(sb, "st_mtim"):
        return i64(sb.st_mtim.tv_sec)
    elif hasfield(sb, "st_mtimespec"):
        return i64(sb.st_mtimespec.tv_sec)
    else:
        return i64(sb.st_mtime)

# 118: o MESMO mtime em nanossegundos. Existe separado, e não no lugar do outro,
# porque o `getmtime` do Python é segundos e o oráculo (`python3`) confere isso;
# mas um build compara mtime para decidir recompilação, e num build rápido dois
# arquivos escritos no mesmo segundo são indistinguíveis — que é exatamente o
# erro que faz um incremental "esquecer" de refazer alguma coisa. O `timespec`
# já é lido acima; o que faltava era não jogar fora a parte de baixo.
def ps_os_getmtime_ns(ctx: *PsCtx, p: *PsStr, file: const *char, line: i32) -> i64:
    cs: const *char = os_cstr(ctx, p, file, line)
    if cs == None:
        return 0
    sb: stat
    if stat(cs, &sb) != 0:
        os_fail(ctx, "cannot stat", p, file, line)
        return 0
    if hasfield(sb, "st_mtim"):
        return i64(sb.st_mtim.tv_sec) * 1000000000 + i64(sb.st_mtim.tv_nsec)
    elif hasfield(sb, "st_mtimespec"):
        return i64(sb.st_mtimespec.tv_sec) * 1000000000 + i64(sb.st_mtimespec.tv_nsec)
    else:
        return i64(sb.st_mtime) * 1000000000

# 118: quantos núcleos a máquina tem. Um build precisa disto para escolher
# quantos processos manter em voo, e perguntar ao sistema é melhor que um número
# escrito à mão num arquivo de build.
def ps_os_nproc() -> i64:
    n: i64 = i64(sysconf(_SC_NPROCESSORS_ONLN))
    return n if n >= 1 else i64(1)

# ---------- 118 / pforge 1.2: rodar um processo ----------
# A peça que faltava na camada de sistema, e a única que o pforge não tinha como
# escrever por fora. É uma TASK: quem chama espera com `await`, N delas ficam em
# voo ao mesmo tempo, e o limite de concorrência é de quem chama
# (`gather_map(..., at_most=n)`). O `waitpid` acontece numa thread do pool, que é
# onde bloquear é o trabalho — a mesma decisão que o `getaddrinfo` já tinha.
#
# NÃO passa por shell. O comando é um vetor de argumentos, e é o `execvp` que o
# recebe: não há aspas para escapar, não há `&&`, não há glob, e nada do que o
# usuário escreveu pode virar sintaxe. Quem quiser redirecionar diz `stdout=`;
# quem quiser encadear escreve duas arestas no grafo.
private def os_dup(s: const *char, n: usize) -> *char:
    q: *char = (*char)(malloc(n + 1))
    memcpy(q, s, n)
    q[n] = '\0'
    return q

# uma str que vai virar argumento, variável de ambiente ou caminho não pode ter
# byte zero no meio: o `exec` veria a coisa CORTADA ali
private def os_arg_cstr(ctx: *PsCtx, s: *PsStr, what: const *char, file: const *char, line: i32) -> *char:
    if s == None:
        ps_raise(ctx, "os.run(): a None where a string was expected", PS_CAT_VALUE, file, line)
        return None
    if usize(strlen(s->data)) != usize(s->len):
        msg: char[256]
        snprintf(msg, 256, "os.run(): this %s has a NUL byte in it", what)
        ps_raise(ctx, msg, PS_CAT_VALUE, file, line)
        return None
    return os_dup(s->data, usize(s->len))

def ps_os_run(ctx: *PsCtx, argv: *PsList, env: *PsDict, cwd: *PsStr, outfile: *PsStr, console: bool, file: const *char, line: i32) -> *PsTask:
    if argv == None or argv->len < 1:
        ps_raise(ctx, "os.run() takes the command as a non-empty list: os.run([\"cc\", \"-c\", \"a.c\"])", PS_CAT_VALUE, file, line)
        return None
    w: *PsWork = ps_work_new(PS_IO_RUN)
    w->want = PS_W_PROC
    n: i64 = argv->len
    av: **char = (**char)(malloc(usize(n + 1) * sizeof(*av)))
    memset(av, 0, usize(n + 1) * sizeof(*av))
    w->argv = av
    abase: *char = (*char)(argv->data) + sizeof(PsArr)
    for i in range(n):
        sp: *PsStr = *(**PsStr)(abase + usize(i) * usize(argv->esize))
        c: *char = os_arg_cstr(ctx, sp, "argument", file, line)
        if c == None:
            ps_work_free(w)
            return None
        av[i] = c
    # um `env` VAZIO quer dizer "herde", e não "rode sem ambiente nenhum". A
    # diferença existe no `subprocess` do Python (None vs {}) e aqui foi
    # deliberadamente colapsada: quem constrói uma aresta de build tem um dict
    # que às vezes está vazio, e fazer isso significar "sem PATH" transformaria
    # o caso comum na armadilha. Rodar com ambiente REALMENTE vazio não é
    # expressável hoje; no dia em que alguém precisar, é uma opção nova e não
    # uma mudança de significado.
    if env != None and env->n > 0:
        m: i64 = env->n
        ep: **char = (**char)(malloc(usize(m + 1) * sizeof(*ep)))
        memset(ep, 0, usize(m + 1) * sizeof(*ep))
        w->envp = ep
        k: i64 = 0
        e: i64 = 0
        while k < env->nent:
            if ps_dict_live(env, k):
                ks: *PsStr = *(**PsStr)(ps_dict_key_at(env, k))
                vs: *PsStr = *(**PsStr)(ps_dict_val_at(env, k))
                if ks == None or vs == None or usize(strlen(ks->data)) != usize(ks->len) or usize(strlen(vs->data)) != usize(vs->len):
                    ps_raise(ctx, "os.run(): an environment name or value has a NUL byte in it", PS_CAT_VALUE, file, line)
                    ps_work_free(w)
                    return None
                # "NOME=VALOR", que é o formato que o `execve` quer
                kv: *char = (*char)(malloc(usize(ks->len) + usize(vs->len) + 2))
                memcpy(kv, ks->data, usize(ks->len))
                kv[usize(ks->len)] = '='
                memcpy(kv + usize(ks->len) + 1, vs->data, usize(vs->len))
                kv[usize(ks->len) + usize(vs->len) + 1] = '\0'
                ep[e] = kv
                e += 1
            k += 1
    # caminho vazio é "não foi dado": a string vazia não nomeia diretório nenhum,
    # e um `chdir("")` falharia com um 127 que não explica nada
    if cwd != None and cwd->len > 0:
        c2: *char = os_arg_cstr(ctx, cwd, "working directory", file, line)
        if c2 == None:
            ps_work_free(w)
            return None
        w->cwd = c2
    if outfile != None and outfile->len > 0:
        c3: *char = os_arg_cstr(ctx, outfile, "stdout path", file, line)
        if c3 == None:
            ps_work_free(w)
            return None
        w->outfile = c3
    # `console=True`: o filho herda ESTE terminal. Não é uma forma de capturar
    # melhor — é a ausência de captura, e é o que separa "um programa que
    # imprime" de um programa que pinta a tela, lê o teclado, sabe o tamanho da
    # janela e recebe Ctrl-C. Um `stdout=` junto seria contraditório, e a sema
    # recusa-o antes de chegar aqui.
    if console:
        w->console = 1
    # um ponteiro é o que a task devolve; `PsStrPtr` é o alias do tamanho de
    # ponteiro que existe justamente para o `sizeof` poder nomear um TIPO aqui
    return ps_io_task(ctx, w, True, sizeof(PsStrPtr))


# ---------- `os.exec`: o programa PASSA A SER este processo ----------
#
# `os.run` cria um filho e espera; `os.exec` não volta. A diferença importa numa
# coisa só, e essa coisa é tudo: um programa lançado como filho tem a saída
# CAPTURADA, então não pinta a tela, não lê o teclado, não sabe o tamanho do
# terminal e não recebe Ctrl-C. Um lançador (`pforge run`) que use `os.run`
# consegue correr um programa que imprime, e mais nada.
#
# Depois do `execvp` não há "depois": o processo é outro programa, com o mesmo
# PID, os mesmos descritores e o mesmo terminal. Por isso isto NÃO devolve — e
# por isso o que ele tem de fazer ANTES é esvaziar o que estiver por escrever,
# que doutra forma morre no buffer.
def ps_os_exec(ctx: *PsCtx, argv: *PsList, file: const *char, line: i32):
    if argv == None or argv->len < 1:
        ps_raise(ctx, "os.exec() takes the command as a non-empty list: os.exec([\"vim\", \"a.txt\"])", PS_CAT_VALUE, file, line)
        return
    n: i64 = argv->len
    av: **char = (**char)(malloc(usize(n + 1) * sizeof(*av)))
    memset(av, 0, usize(n + 1) * sizeof(*av))
    abase: *char = (*char)(argv->data) + sizeof(PsArr)
    for i in range(n):
        sp: *PsStr = *(**PsStr)(abase + usize(i) * usize(argv->esize))
        c: *char = os_arg_cstr(ctx, sp, "argument", file, line)
        if c == None:
            free(av)
            return
        av[i] = c
    fflush(stdout)
    fflush(stderr)
    execvp(av[0], av)
    # só se chega aqui quando NÃO houve troca: o programa não existe, ou não tem
    # permissão. A mensagem diz o nome, porque "No such file or directory" sem
    # ele é a mensagem mais inútil do Unix.
    # a regra do `errno` desta camada vale aqui: a mensagem vem da OPERAÇÃO e do
    # NOME, e não do `errno` — que é macro, e P não vê macro
    msg: char[512]
    snprintf(msg, usize(512), "os.exec(): não consegui executar '%s' (não existe, ou não é executável)", av[0])
    ps_raise(ctx, msg, PS_CAT_IO, file, line)
    free(av)


# ---------- a child on a TERMINAL (F8) ----------
#
# `posix_openpt`, `grantpt`, `unlockpt` and `ptsname` are POSIX and <stdlib.h>
# hides them under the feature macros this build uses, so the prototypes are
# ours. It is the same treatment `popen`/`pclose` and `execv`/`access` already
# get in the compiler, and for the same reason — and spelled with libc's own
# types, so the declaration stays compatible wherever the system header is also
# visible (that is what broke the macOS build once, and the rule came out of it).
#
# NOT `openpty()`: that one lives in <pty.h> on glibc and <util.h> on the BSDs,
# and P has no conditional include. The four above are in one header on both.
def posix_openpt(flags: int) -> int
def grantpt(fd: int) -> int
def unlockpt(fd: int) -> int
def ptsname(fd: int) -> *char
def setsid() -> int


# ---------- um filho que NÃO se espera (F6) ----------
#
# `os.run` cria um filho e espera; `os.exec` vira o filho. Falta o terceiro caso,
# e é o do laço de desenvolvimento: LANÇAR um programa, deixá-lo correr, e mais
# tarde matá-lo para o relançar.
#
# O que volta é o PID e não um objeto, e isso é decisão: um objeto vivo num
# runtime com coletor levanta a pergunta do que acontece quando ele é recolhido
# com o filho ainda a correr, e a resposta certa para essa pergunta não é óbvia.
# Três funções sobre um número não têm essa pergunta — e o número é o que o
# sistema operativo já usa.
#
# O preço, dito: um PID é reutilizável. Depois de `os.alive` devolver False o
# número não vale mais nada, e usá-lo é apontar para outro processo. Para um
# laço que lança e mata o que ele próprio lançou, isso não acontece.
def ps_os_spawn(ctx: *PsCtx, argv: *PsList, file: const *char, line: i32) -> i64:
    if argv == None or argv->len < 1:
        ps_raise(ctx, "os.spawn() takes the command as a non-empty list", PS_CAT_VALUE, file, line)
        return -1
    n: i64 = argv->len
    av: **char = (**char)(malloc(usize(n + 1) * sizeof(*av)))
    memset(av, 0, usize(n + 1) * sizeof(*av))
    abase: *char = (*char)(argv->data) + sizeof(PsArr)
    for i in range(n):
        sp: *PsStr = *(**PsStr)(abase + usize(i) * usize(argv->esize))
        c: *char = os_arg_cstr(ctx, sp, "argument", file, line)
        if c == None:
            free(av)
            return -1
        av[i] = c
    fflush(stdout)
    fflush(stderr)
    pid: i32 = fork()
    if pid == 0:
        execvp(av[0], av)
        _exit(127)
    for i in range(n):
        free(av[i])
    free(av)
    if pid < 0:
        ps_raise(ctx, "os.spawn(): não consegui criar o processo", PS_CAT_IO, file, line)
        return -1
    return i64(pid)

def ps_os_kill(ctx: *PsCtx, pid: i64):
    """SIGTERM, que é o pedido. Um `SIGKILL` não deixa o programa fechar o que
    tinha aberto, e um laço de desenvolvimento que corrompe um arquivo a cada
    salvar é pior do que um que espera meio segundo."""
    if pid > 0:
        kill(i32(pid), SIGTERM)

# What a terminal IS, here: a descriptor with a child on the other end. It comes
# back as the same `Conn` `net.connect` returns, and that is the whole design —
# `await c.read(n)`, `await c.write(s)` and `c.close()` are already written, they
# are already polled by the scheduler instead of blocking a thread, and the
# terminal widget above needs to learn none of it.
#
# The alternative was a handle of its own with six functions around it. It would
# have duplicated the awaitable read, which is the hard part, and it would have
# been a second thing to know.
def ps_os_spawn_pty(ctx: *PsCtx, argv: *PsList, cols: i64, rows: i64, file: const *char, line: i32) -> *PsConn:
    if argv == None or argv->len < 1:
        ps_raise(ctx, "os.spawn_pty() takes the command as a non-empty list", PS_CAT_VALUE, file, line)
        return ps_conn_new(ctx, -1, 0)
    n: i64 = argv->len
    av: **char = (**char)(malloc(usize(n + 1) * sizeof(*av)))
    memset(av, 0, usize(n + 1) * sizeof(*av))
    abase: *char = (*char)(argv->data) + sizeof(PsArr)
    for i in range(n):
        sp: *PsStr = *(**PsStr)(abase + usize(i) * usize(argv->esize))
        c0: *char = os_arg_cstr(ctx, sp, "argument", file, line)
        if c0 == None:
            free(av)
            return ps_conn_new(ctx, -1, 0)
        av[i] = c0

    m: int = posix_openpt(O_RDWR | O_NOCTTY)
    if m < 0 or grantpt(m) != 0 or unlockpt(m) != 0:
        if m >= 0:
            close(m)
        for i in range(n):
            free(av[i])
        free(av)
        ps_raise(ctx, "os.spawn_pty(): could not open a pseudo-terminal", PS_CAT_IO, file, line)
        return ps_conn_new(ctx, -1, 0)
    slave: const *char = ptsname(m)
    if slave == None:
        close(m)
        for i in range(n):
            free(av[i])
        free(av)
        ps_raise(ctx, "os.spawn_pty(): the pseudo-terminal has no name", PS_CAT_IO, file, line)
        return ps_conn_new(ctx, -1, 0)
    sname: *char = strdup(slave)

    ws: winsize
    memset(&ws, 0, sizeof(ws))
    ws.ws_col = u16(cols if cols > 0 else 80)
    ws.ws_row = u16(rows if rows > 0 else 24)
    ioctl(m, u64(TIOCSWINSZ), &ws)

    fflush(stdout)
    fflush(stderr)
    pid: i32 = fork()
    if pid == 0:
        setsid()
        # POSIX: a session leader with no controlling terminal that opens one
        # WITHOUT O_NOCTTY gets it as its controlling terminal. So this open is
        # the whole job, and TIOCSCTTY — which is a compound macro on the BSDs
        # and would be one more thing to hope the C front end can evaluate —
        # never has to be named.
        sfd: int = open(sname, O_RDWR)
        if sfd < 0:
            _exit(127)
        dup2(sfd, 0)
        dup2(sfd, 1)
        dup2(sfd, 2)
        if sfd > 2:
            close(sfd)
        close(m)
        execvp(av[0], av)
        _exit(127)
    free(sname)
    for i in range(n):
        free(av[i])
    free(av)
    if pid < 0:
        close(m)
        ps_raise(ctx, "os.spawn_pty(): could not create the process", PS_CAT_IO, file, line)
        return ps_conn_new(ctx, -1, 0)
    # non-blocking, because from here on it is an ordinary polled descriptor and
    # the scheduler owns the waiting
    ps_sock_nonblock(m)
    c: *PsConn = ps_conn_new(ctx, m, 0)
    c->pid = pid
    return c


def ps_os_pty_resize(ctx: *PsCtx, c: *PsConn, cols: i64, rows: i64):
    """The window changed size, so the program inside has to be told.

    This is the one thing a terminal needs that a socket does not, and it is why
    it is a function in `os` rather than a method on a `Conn`: a socket has no
    size, and giving every socket a `resize` would be lying about what one is."""
    if c == None or c->is_open == 0:
        return
    ws: winsize
    memset(&ws, 0, sizeof(ws))
    ws.ws_col = u16(cols if cols > 0 else 80)
    ws.ws_row = u16(rows if rows > 0 else 24)
    ioctl(c->fd, u64(TIOCSWINSZ), &ws)


def ps_os_pty_pid(ctx: *PsCtx, c: *PsConn) -> i64:
    """The child's pid, for `os.kill` and `os.alive`. Zero for a plain socket."""
    return 0 if c == None else i64(c->pid)


def ps_os_alive(ctx: *PsCtx, pid: i64) -> bool:
    """Ainda a correr? E, de caminho, COLHE o que já morreu — sem isto cada
    programa lançado deixaria um zumbi, e um laço que relança de dez em dez
    segundos enche a tabela de processos numa tarde."""
    if pid <= 0:
        return False
    st: i32 = 0
    r: i32 = waitpid(i32(pid), &st, WNOHANG)
    return r == 0


# ---------- 137: o mapa de disco ----------
#
# `os.mmap(p)` — o ficheiro em memória, sem o ler. Um tipo PRÓPRIO e não um
# `bytes`, e a pergunta que o decidiu foi *"o mapa do sistema operativo dá-te
# recursos e opções; o tipo também podia?"*: `madvise`, `msync`, `mlock` e o
# `MAP_POPULATE` não cabem num valor.
#
# E FECHA-SE, o que um `bytes` não faz (136.1). Um mapa é espaço de
# endereçamento, um inode e um descritor — coisas que se esgotam muito antes do
# monte, e que o coletor não tem motivo nenhum para notar. Mil mapas são mil
# descritores e um monte minúsculo; esperar por pressão de memória é o erro pelo
# qual o `MappedByteBuffer` do Java é conhecido (JDK-4724038). O finalizador é a
# REDE, e o `with` é o plano.

private def ps_map_release(o: *void):
    m: *PsMapping = (*PsMapping)(o)
    if m->open != 0 and m->base != None:
        munmap((*void)(m->base), m->blen)
    m->base = None
    m->data = None
    m->len = usize(0)
    m->blen = usize(0)
    m->open = 0


def ps_map_open(ctx: *PsCtx, p: *PsStr, mode: *PsStr, off: i64, n: i64, has_region: bool, file: const *char, line: i32) -> *PsMapping:
    m: *PsMapping = ps_alloc(ctx, sizeof(PsMapping), PS_TY_MAPPING)
    m->data = None
    m->base = None
    m->len = usize(0)
    m->blen = usize(0)
    m->open = 0
    m->writable = 0
    wr: bool = mode != None and mode->len > u32(0) and mode->data[0] == 'w'
    fd: int = open(p->data, O_RDWR if wr else O_RDONLY)
    if fd < 0:
        msg: char[512]
        snprintf(msg, 512, "could not open for mapping: %s", p->data)
        ps_raise(ctx, msg, PS_CAT_IO, file, line)
        return m
    st: stat
    if fstat(fd, &st) != 0:
        close(fd)
        ps_raise(ctx, "could not measure the file to map it", PS_CAT_IO, file, line)
        return m
    total: i64 = i64(st.st_size)
    start: i64 = off if has_region else 0
    want: i64 = n if has_region else total
    if start < 0 or want < 0 or start + want > total:
        close(fd)
        msg2: char[512]
        snprintf(msg2, 512, "the region %lld+%lld falls outside %s, which is %lld bytes",
                 i64(start), i64(want), p->data, i64(total))
        ps_raise(ctx, msg2, PS_CAT_INDEX, file, line)
        return m
    if want == 0:
        # 137.3: an empty region is legal and maps nothing. `mmap` of zero
        # length FAILS, and answering "it worked, and it is empty" is both true
        # and what every caller wants.
        close(fd)
        m->open = 1
        m->writable = 1 if wr else 0
        return m
    # `mmap` demands a page-aligned offset, and 137.3 does not: the caller says
    # where the DATA starts and this rounds down to the page, keeping the
    # difference so `data` still points where it was asked to.
    pg: i64 = i64(sysconf(_SC_PAGESIZE))
    if pg <= 0:
        pg = 4096
    algn: i64 = start - (start % pg)
    slack: i64 = start - algn
    blen: usize = usize(want + slack)
    prot: int = (PROT_READ | PROT_WRITE) if wr else PROT_READ
    base: *void = mmap(None, blen, prot, MAP_SHARED if wr else MAP_PRIVATE, fd, algn)
    # the descriptor is NOT kept: the mapping holds the file open by itself,
    # which is what makes a thousand maps cost a thousand pages of address space
    # and not a thousand descriptors
    close(fd)
    # `MAP_FAILED` é `((void *) -1)`: uma macro que não é número, e macro que
    # não é número não atravessa a fronteira (72.4). O valor é o mesmo em todos
    # os sistemas que têm `mmap`, e compará-lo assim é o que se consegue dizer.
    if (*char)(base) == (*char)(usize(0)) - usize(1):
        ps_raise(ctx, "the mapping failed", PS_CAT_IO, file, line)
        return m
    m->base = (*char)(base)
    m->blen = blen
    m->data = m->base + usize(slack)
    m->len = usize(want)
    m->open = 1
    m->writable = 1 if wr else 0
    ps_map_live_add()
    ps_add_final(ctx, (*PsObj)(m), ps_map_release)
    return m


private def ps_map_live(ctx: *PsCtx, m: *PsMapping, what: const *char, file: const *char, line: i32) -> bool:
    if m == None or m->open == 0:
        msg: char[128]
        snprintf(msg, 128, "%s: this mapping is closed", what)
        ps_raise(ctx, msg, PS_CAT_VALUE, file, line)
        return False
    return True


def ps_map_len(m: *PsMapping) -> i64:
    return i64(m->len) if m != None else i64(0)


# 137.1: fatia-se em `bytes` SEM copiar. O bloco é do núcleo e não se move, que
# é exactamente a condição que uma janela pede — a mesma que faz a fatia de um
# `bytes` ser uma janela.
def ps_map_slice(ctx: *PsCtx, m: *PsMapping, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, file: const *char, line: i32) -> *PsBytes:
    if not ps_map_live(ctx, m, "slice", file, line):
        return ps_bytes_new(ctx, "", usize(0))
    lo: i64 = 0
    hi: i64 = 0
    if not ps_slice_bounds_pub(ctx, i64(m->len), a, b, st, has_a, has_b, out lo, out hi, file, line):
        return ps_bytes_new(ctx, "", usize(0))
    if st != 1:
        ps_raise(ctx, "a mapping slices with no step: it is a window over the file, and a step would mean copying it", PS_CAT_VALUE, file, line)
        return ps_bytes_new(ctx, "", usize(0))
    if lo >= hi:
        return ps_bytes_new(ctx, "", usize(0))
    # a `bytes` whose block is the KERNEL's and whose owner is nobody: it must
    # not be freed, so it registers no finalizer and owns nothing
    v: *PsBytes = ps_alloc(ctx, sizeof(PsBytes), PS_TY_BYTES)
    v->data = m->data + usize(lo)
    v->len = usize(hi - lo)
    v->owner = None
    v->hash = 0
    v->foreign = 1
    return v


def ps_map_advise(ctx: *PsCtx, m: *PsMapping, how: i64, file: const *char, line: i32):
    if not ps_map_live(ctx, m, "advise", file, line):
        return
    # 0/1/2 e não `MADV_*`: o programa diz a INTENÇÃO e é aqui que ela vira o
    # número do sistema. É também o que deixa a mesma intenção significar coisas
    # diferentes em sistemas diferentes sem o programa saber.
    if m->base != None:
        k: int = MADV_NORMAL
        if how == 0:
            k = MADV_SEQUENTIAL
        elif how == 1:
            k = MADV_RANDOM
        elif how == 2:
            k = MADV_WILLNEED
        madvise((*void)(m->base), m->blen, k)


def ps_map_sync(ctx: *PsCtx, m: *PsMapping, file: const *char, line: i32):
    if not ps_map_live(ctx, m, "sync", file, line):
        return
    if m->base != None and msync((*void)(m->base), m->blen, MS_SYNC) != 0:
        ps_raise(ctx, "sync: the mapping could not be written back", PS_CAT_IO, file, line)


def ps_map_lock(ctx: *PsCtx, m: *PsMapping, file: const *char, line: i32):
    if not ps_map_live(ctx, m, "lock", file, line):
        return
    if m->base != None and mlock((*void)(m->base), m->blen) != 0:
        ps_raise(ctx, "lock: the pages could not be pinned (RLIMIT_MEMLOCK?)", PS_CAT_IO, file, line)


def ps_map_close(ctx: *PsCtx, m: *PsMapping):
    if m != None and m->open != 0:
        ps_map_release((*void)(m))
        ps_map_live_sub()


# ---------- 140/F4: o que o `java.nio.file` tem e nós não ----------

def ps_os_stat(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32) -> *PsDict:
    """Tudo o que o disco sabe do nome, de UMA vez.

    Antes disto, saber se um caminho existe, se é directório, que tamanho tem e
    quando mudou eram QUATRO travessias ao sistema de ficheiros sobre o mesmo
    inode — e entre a primeira e a última o ficheiro podia mudar, o que faz de
    quatro respostas uma imagem que nunca existiu.

    Um DICT e não um record, pela mesma razão que o `gc.stats()` (110): não há
    tipo novo para a linguagem aprender, o `print` já sabe imprimi-lo, e
    acrescentar uma medida depois não quebra programa nenhum."""
    d: *PsDict = ps_dict_new(ctx, i32(sizeof(PsStrPtr)), i32(sizeof(i64)), 1, True, False)
    cs: const *char = os_cstr(ctx, path, file, line)
    if cs == None:
        return d
    sb: stat
    if stat(cs, &sb) != 0:
        os_fail(ctx, "cannot stat", path, file, line)
        return d
    NAMES: const *char[] = {"size", "mtime", "mtime_ns", "mode", "is_dir", "is_file", "links", "inode"}
    vals: i64[8]
    vals[0] = i64(sb.st_size)
    # a mesma travessia de plataforma que o `getmtime` já fazia (`st_mtim` na
    # glibc, `st_mtimespec` no macOS, `st_mtime` no que é antigo), e por isso é
    # `hasfield` — o comptime da 65.11 — e não um `#ifdef`
    msec: i64 = 0
    mns: i64 = 0
    if hasfield(sb, "st_mtim"):
        msec = i64(sb.st_mtim.tv_sec)
        mns = i64(sb.st_mtim.tv_sec) * 1000000000 + i64(sb.st_mtim.tv_nsec)
    elif hasfield(sb, "st_mtimespec"):
        msec = i64(sb.st_mtimespec.tv_sec)
        mns = i64(sb.st_mtimespec.tv_sec) * 1000000000 + i64(sb.st_mtimespec.tv_nsec)
    else:
        msec = i64(sb.st_mtime)
        mns = msec * 1000000000
    vals[1] = msec
    vals[2] = mns
    vals[3] = i64(sb.st_mode) & 0o7777
    vals[4] = 1 if (i64(sb.st_mode) & 0o170000) == 0o040000 else 0
    vals[5] = 1 if (i64(sb.st_mode) & 0o170000) == 0o100000 else 0
    vals[6] = i64(sb.st_nlink)
    vals[7] = i64(sb.st_ino)
    for i in range(8):
        k: *PsStr = ps_str_new(ctx, NAMES[i], strlen(NAMES[i]))
        kp: *PsStr = k
        slot: *char = ps_dict_put(ctx, d, (*char)(&kp))
        *(*i64)(slot) = vals[i]
    return d


# 140/F4: ler e escrever POR POSIÇÃO, sem `seek`.
#
# É a diferença que torna o acesso concorrente seguro: um `seek` seguido de um
# `read` são duas operações sobre um cursor PARTILHADO, e dois workers a
# fazê-las intercalam-se. O `pread` leva a posição no próprio pedido, portanto
# não há cursor para atropelar — que é o que faz dele a base de qualquer coisa
# que leia um ficheiro grande em paralelo.
#
# O `Buffer` é malloc'd e não se move (52.3), portanto a chamada de sistema
# escreve nele directamente e não há cópia nenhuma nos dois sentidos.
def ps_os_pread(ctx: *PsCtx, f: *PsFile, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> i64:
    if f == None or f->is_open == 0:
        ps_raise(ctx, "pread: this file is closed", PS_CAT_IO, file, line)
        return 0
    d: *char = ps_buf_window_pub(ctx, b, 0, n, "pread", file, line)
    if d == None:
        return 0
    got: i64 = i64(pread(fileno(f->fp), (*void)(d), usize(n), off))
    if got < 0:
        ps_raise(ctx, "pread failed", PS_CAT_IO, file, line)
        return 0
    return got


def ps_os_pwrite(ctx: *PsCtx, f: *PsFile, b: *PsBuffer, off: i64, n: i64, file: const *char, line: i32) -> i64:
    if f == None or f->is_open == 0:
        ps_raise(ctx, "pwrite: this file is closed", PS_CAT_IO, file, line)
        return 0
    d: *char = ps_buf_window_pub(ctx, b, 0, n, "pwrite", file, line)
    if d == None:
        return 0
    # o stdio pode ter bytes por escrever, e um `pwrite` no descritor passaria
    # por cima deles: esvaziar primeiro é o que faz as duas metades verem o
    # mesmo ficheiro
    fflush(f->fp)
    put: i64 = i64(pwrite(fileno(f->fp), (*void)(d), usize(n), off))
    if put < 0:
        ps_raise(ctx, "pwrite failed", PS_CAT_IO, file, line)
        return 0
    return put


# 135.10: o tamanho de um ficheiro JÁ ABERTO.
#
# O `path.getsize` existe, mas obriga a guardar o caminho depois de se ter o
# `File` — e a perguntar ao NOME em vez de ao descritor, o que abre uma janela
# entre a resposta e a leitura em que o ficheiro pode ser trocado por outro.
def ps_file_size(ctx: *PsCtx, f: *PsFile, file: const *char, line: i32) -> i64:
    if f == None or f->is_open == 0:
        ps_raise(ctx, "size(): this file is closed", PS_CAT_IO, file, line)
        return 0
    fflush(f->fp)
    sb: stat
    if fstat(fileno(f->fp), &sb) != 0:
        ps_raise(ctx, "size(): could not measure the file", PS_CAT_IO, file, line)
        return 0
    return i64(sb.st_size)


# 140/F4: percorrer um directório SEM construir a lista inteira primeiro.
#
# O `listdir` fica como está — devolve tudo, ordenado, e é o que o oráculo
# compara com o `os.listdir` do Python. O que ele NÃO pode fazer é ser
# preguiçoso, porque ordenar exige ter tudo em mão; e o que ele custa numa
# árvore grande é uma lista de milhares de strings para se olhar para a
# primeira.
#
# `scandir` é a outra pergunta: os nomes, um de cada vez, na ordem em que o
# sistema de ficheiros os der. Quem quer ordem chama `sorted`, e passa a ser
# visível que o pediu.
def ps_dir_open(ctx: *PsCtx, path: *PsStr, file: const *char, line: i32) -> *PsDirIter:
    it: *PsDirIter = ps_alloc(ctx, sizeof(PsDirIter), PS_TY_DIRITER)
    it->d = None
    it->done = 0
    cs: const *char = os_cstr(ctx, path, file, line)
    if cs == None:
        it->done = 1
        return it
    it->d = opendir(cs)
    if it->d == None:
        os_fail(ctx, "cannot list the directory", path, file, line)
        it->done = 1
    return it


# None quando acabou, e é o fim do laço. `.` e `..` nunca saem: são o
# directório e o pai, não coisas que estejam dentro dele.
def ps_dir_next(ctx: *PsCtx, it: *PsDirIter) -> *PsStr:
    if it == None or it->done != 0 or it->d == None:
        return None
    while True:
        de: *dirent = readdir((*DIR)(it->d))
        if de == None:
            closedir((*DIR)(it->d))
            it->d = None
            it->done = 1
            return None
        nm: const *char = de->d_name
        if strcmp(nm, ".") == 0 or strcmp(nm, "..") == 0:
            continue
        return ps_str_new(ctx, nm, strlen(nm))


# o directório fecha-se sozinho ao chegar ao fim; isto é para quem sai do laço a
# meio, e para o finalizador que é a rede
private def ps_dir_release(o: *void):
    it: *PsDirIter = (*PsDirIter)(o)
    if it->d != None:
        closedir((*DIR)(it->d))
        it->d = None
    it->done = 1
