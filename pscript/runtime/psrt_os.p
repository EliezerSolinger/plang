# psrt_os.p — CAMADA 4: a camada de SISTEMA. `os` (diretório, criar, apagar,
# renomear) e `path` (contas sobre o nome, e três perguntas ao disco).
#
# Chama a memória e os valores, como a biblioteca portada. Fica em P por decisão
# sua (108.4), e é PORTE do `pstudio/psys.p` — o editor já tinha esta camada
# escrita; o que a bateria 111 faz é mudá-la de casa e dar-lhe a forma do
# Python, para que o pbuild e o pstudio usem a MESMA.
#
# A regra do `errno` do runtime vale aqui também: a mensagem vem da OPERAÇÃO e
# do caminho, nunca do `errno` — `errno` é macro, e P não vê macro.
include <dirent.h>
include <sys/stat.h>
include <sys/types.h>
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

# ---------- 118 / pbuild 1.2: rodar um processo ----------
# A peça que faltava na camada de sistema, e a única que o pbuild não tinha como
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

def ps_os_run(ctx: *PsCtx, argv: *PsList, env: *PsDict, cwd: *PsStr, outfile: *PsStr, file: const *char, line: i32) -> *PsTask:
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
    if env != None:
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
    if cwd != None:
        c2: *char = os_arg_cstr(ctx, cwd, "working directory", file, line)
        if c2 == None:
            ps_work_free(w)
            return None
        w->cwd = c2
    if outfile != None:
        c3: *char = os_arg_cstr(ctx, outfile, "stdout path", file, line)
        if c3 == None:
            ps_work_free(w)
            return None
        w->outfile = c3
    # um ponteiro é o que a task devolve; `PsStrPtr` é o alias do tamanho de
    # ponteiro que existe justamente para o `sizeof` poder nomear um TIPO aqui
    return ps_io_task(ctx, w, True, sizeof(PsStrPtr))
