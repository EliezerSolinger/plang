# psrt_val.p — CAMADA 2: os valores da linguagem. Erro, aritmética, `str`,
# `list`, `dict`/`set`, tupla, `repr`, ordenação, as tabelas Unicode, formatação,
# `any`, buffer, `pack`.
#
# Chama a camada da memória (alocar, o safe point, a pilha-sombra) e mais nada:
# não sabe que existem tasks, workers ou sockets.
import "psrt_types.ph"
import "psrt_mem.ph"
import "psrt_val.ph"
import <stl/utf8.ph>

# ---------- the crash that says where it was (12.4) ----------
# 12.4 decided that failure in C is a CRASH and failure in pscript is an
# exception, and added: "crash and debuggable are not opposites — a handler for
# SIGSEGV/SIGBUS/SIGFPE reads the shadow stack and prints the pscript stack
# before dying. It does not catch; it says where."
#
# That is what this is. It costs nothing until the process is already dying, and
# what it prints is what the shadow stack knew — a function with nothing
# collected in it has no frame (49.4), so it cannot be named unless the program
# was built with `--trace`.
#
# Only the MAIN thread's stack is printed, and only when the crash is on it: a
# worker has its own context and printing the main one's frames would name a
# stack that has nothing to do with the crash.
private PS_CRASH_CTX: *PsCtx = None
private PS_CRASH_TID: pthread_t
private PS_CRASH_HAVE: i32 = 0

def ps_maps_live() -> i64

private def ps_crash_name(sig: int) -> const *char:
    if sig == SIGSEGV:
        return "SIGSEGV (invalid memory access)"
    if sig == SIGBUS:
        # 137.2: com um mapa aberto, esta é a causa quase certa — e dizê-la é a
        # diferença entre depurar e adivinhar
        if ps_maps_live() > 0:
            return "SIGBUS: a page of a mapping went away — the file was very likely truncated by somebody else while it was mapped (137.2)"
        return "SIGBUS (misaligned or unmapped access)"
    if sig == SIGFPE:
        return "SIGFPE (arithmetic fault)"
    if sig == SIGILL:
        return "SIGILL (illegal instruction)"
    return "a fatal signal"

private def ps_crash_handler(sig: int):
    fflush(stdout)
    fprintf(stderr, "pscript: %s\n", ps_crash_name(sig))
    if PS_CRASH_HAVE != 0 and PS_CRASH_CTX != None and pthread_equal(pthread_self(), PS_CRASH_TID) != 0:
        f: *PsFrame = PS_CRASH_CTX->frames
        n: i32 = 0
        # the same carry `ps_trace_capture` does: the line is on the innermost
        # frame, which is a block's as often as a function's
        ln: i32 = 0
        while f != None and n < 64:
            if f->line != 0 and ln == 0:
                ln = f->line
            if f->fn != None:
                if ln != 0:
                    fprintf(stderr, "  in %s (%s:%d)\n", f->fn, f->file if f->file != None else "?", ln)
                else:
                    fprintf(stderr, "  in %s (%s)\n", f->fn, f->file if f->file != None else "?")
                n += 1
                ln = 0
            f = f->prev
        if n == 0:
            fprintf(stderr, "  (no pscript frame held anything collected; build with --trace to name them all)\n")
    else:
        fprintf(stderr, "  (not the main thread: no stack to read here)\n")
    fflush(stderr)
    # back to the default and die properly, so the exit status and the core file
    # are what they would have been. `None` IS `SIG_DFL` — the macro is a null
    # function pointer, and a macro that is not a number does not cross the
    # header boundary (72.4), so the null goes over instead of the name.
    signal(sig, None)
    raise(sig)
    _exit(128 + i32(sig))

# WHAT THIS CANNOT DO, said out loud: a crash that ran out of STACK — infinite
# recursion — is not reported. The handler would run on the stack that just
# overflowed and fault again; reporting it needs an alternate stack, which needs
# `sigaction` with SA_ONSTACK, and the member that holds the handler there is a
# MACRO over a union whose name differs between glibc and macOS
# (`__sigaction_handler` against `__sigaction_u`). A macro that is not a number
# does not cross the header boundary (72.4), and hard-coding either spelling
# would be a platform `#ifdef` in the middle of the runtime.
#
# So `signal` it is, and what it covers is every crash that still has stack: a
# wild pointer from the unsafe side, a misaligned access, an illegal
# instruction. Which is what 12.4 was about — the C side failing.
# ---------- 137.2: o SIGBUS, e o que este guarda consegue ser ----------
#
# Se outro processo TRUNCAR o ficheiro por baixo de um mapa, tocar na página que
# desapareceu manda SIGBUS e mata o processo. É por isso que o Rust marca a
# criação de um `mmap` como `unsafe`, e é o que a JVM, o V8 e o Postgres apanham.
#
# **O que a 137.2 desenhou, e o que é preciso para o fazer:** o manipulador
# confirma que o endereço da falha caiu num mapa NOSSO, desenrola até à
# profundidade da pilha-sombra que o `with` gravou, e levanta. Isso exige duas
# coisas, e as duas esbarram na mesma fronteira que o manipulador de crash em
# cima já documentou (72.4):
#
#   1. **o ENDEREÇO da falha** (`siginfo_t.si_addr`), que só chega por
#      `sigaction` com `SA_SIGINFO`. O membro que guarda o manipulador é uma
#      MACRO sobre uma união cujo nome difere entre a glibc e o macOS, e o
#      offset de `sa_flags` difere com ela. E o próprio `si_addr` está em
#      offsets diferentes nas duas.
#   2. **um `setjmp` no frame que vai ser retomado.** Um `setjmp` chamado por
#      uma função do runtime deixa de valer no instante em que ela retorna, e o
#      bloco `with` está no frame de quem o escreveu — portanto o salto teria de
#      ser EMITIDO pelo lowering para dentro da função do utilizador.
#
# **O que fica feito, e é estritamente melhor do que nada:** enquanto houver um
# mapa aberto, um SIGBUS deixa de morrer mudo e passa a dizer o que quase de
# certeza aconteceu, com o número de mapas abertos e a pilha do pscript. Um
# programa que trunca um ficheiro debaixo de um mapa lê a causa em vez de ler
# "SIGBUS" e adivinhar.
#
# O desenho que fecharia isto está registado na bateria 145: o corpo do `with`
# passa a ser uma CLOSURE que o runtime chama, e então o `setjmp` vive no frame
# do runtime — que é o dono dele — durante todo o bloco.
private PS_MAPS_LIVE: i64 = 0
private PS_WATCH_LIVE: i64 = 0

def ps_watch_live_add():
    PS_WATCH_LIVE += 1

def ps_watch_live_sub():
    if PS_WATCH_LIVE > 0:
        PS_WATCH_LIVE -= 1

def ps_watches_live() -> i64:
    return PS_WATCH_LIVE

def ps_map_live_add():
    PS_MAPS_LIVE += 1

def ps_map_live_sub():
    if PS_MAPS_LIVE > 0:
        PS_MAPS_LIVE -= 1

def ps_maps_live() -> i64:
    return PS_MAPS_LIVE


def ps_install_crash_handler(ctx: *PsCtx):
    PS_CRASH_CTX = ctx
    PS_CRASH_TID = pthread_self()
    PS_CRASH_HAVE = 1
    signal(SIGSEGV, ps_crash_handler)
    signal(SIGBUS, ps_crash_handler)
    signal(SIGFPE, ps_crash_handler)
    signal(SIGILL, ps_crash_handler)










# `xs[a:b]` — a COPY (17.3). Python's clamping, not an error: a slice past the
# end trims, which is what makes `xs[1:]` on an empty list an empty list instead
# of a stopped program.
# THE SLICE BOUNDS, Python's rules, with a step. Kept in one place because the
# list and the string have to answer identically and the rules are fiddly:
#
#   * a negative index counts from the end;
#   * the bounds CLAMP rather than raise — `xs[:99]` is the whole thing;
#   * a NEGATIVE step walks backwards, and then the defaults flip: the missing
#     start is the last element and the missing stop is before the first;
#   * a zero step is an error, because there is no answer.
#
# `out i` and `out j` come back already resolved, and `st` is the step.
private def ps_slice_bounds(ctx: *PsCtx, n: i64, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, out i: i64, out j: i64, file: const *char, line: i32) -> bool

# 137.1: the os layer slices a mapping, and the bounds have to be the SAME
# ones a list, a string and a `bytes` use — one rule, one implementation.
def ps_slice_bounds_pub(ctx: *PsCtx, n: i64, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, out i: i64, out j: i64, file: const *char, line: i32) -> bool:
    return ps_slice_bounds(ctx, n, a, b, st, has_a, has_b, out i, out j, file, line)


private def ps_slice_bounds(ctx: *PsCtx, n: i64, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, out i: i64, out j: i64, file: const *char, line: i32) -> bool:
    if st == 0:
        ps_raise(ctx, "a slice step may not be zero", PS_CAT_VALUE, file, line)
        i = 0
        j = 0
        return False
    if st > 0:
        i = a if has_a else 0
        j = b if has_b else n
        if i < 0:
            i += n
        if j < 0:
            j += n
        if i < 0:
            i = 0
        if i > n:
            i = n
        if j > n:
            j = n
        if j < i:
            j = i
        return True
    # backwards: the ends are inclusive-of-start, exclusive-of-stop, counting down
    i = a if has_a else n - 1
    j = b if has_b else -1
    if has_a and i < 0:
        i += n
    if has_b and j < 0:
        j += n
    if i > n - 1:
        i = n - 1
    if not has_b and j < -1:
        j = -1
    if has_b and j < -1:
        j = -1
    return True
def ps_list_slice(ctx: *PsCtx, l: *PsList, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, file: const *char, line: i32) -> *PsList:
    i: i64 = 0
    j: i64 = 0
    if not ps_slice_bounds(ctx, l->len, a, b, st, has_a, has_b, out i, out j, file, line):
        return ps_list_new(ctx, l->esize, l->eref, 0)
    out: *PsList = ps_list_new(ctx, l->esize, l->eref, 0)
    k: i64 = i
    while (st > 0 and k < j) or (st < 0 and k > j):
        # `ps_list_base` and NOT `l->data`: a VIEW (18.3) has no storage of its
        # own — its elements are the buffer's, and `raw` is where they are.
        # Reading `l->data` there is reading NULL plus an offset, which is what
        # `View.copy()` found the first time anybody sliced a window.
        #
        # It matters that `ps_list_push` can COLLECT: the base is therefore
        # taken fresh on every turn, because a collection moves the storage of
        # an ordinary list out from under a pointer taken before it.
        src: *char = ps_list_base(l) + usize(k) * usize(l->esize)
        dst: *char = ps_list_push(ctx, out)
        memcpy(dst, src, usize(l->esize))
        k += st
    return out
# ---------- 104: o resto dos métodos de lista ----------
#
# `index`, `count` e `remove` procuram por CONTEÚDO, com a mesma regra do `in`
# (55.4) e do dict: texto compara texto, o resto compara bytes. Procurar por
# ponteiro daria "não achei" para duas strings iguais escritas em lugares
# diferentes, que é o erro que a 55.4 já tinha proibido.
private def ps_list_find(l: *PsList, needle: const *void, kind: i32) -> i64:
    if l == None:
        return -1
    base: *char = ps_list_base(l)
    i: i64 = 0
    while i < l->len:
        p: *char = base + usize(i) * usize(l->esize)
        if kind == PS_K_STR:
            if ps_str_eq(*(**PsStr)(p), *(**PsStr)(needle)):
                return i
        elif memcmp(p, needle, usize(l->esize)) == 0:
            return i
        i += 1
    return -1

def ps_list_index(ctx: *PsCtx, l: *PsList, needle: const *void, kind: i32, file: const *char, line: i32) -> i64:
    i: i64 = ps_list_find(l, needle, kind)
    if i < 0:
        ps_raise(ctx, "index(): the value is not in the list", PS_CAT_VALUE, file, line)
        return 0
    return i

def ps_list_count(l: *PsList, needle: const *void, kind: i32) -> i64:
    if l == None:
        return 0
    base: *char = ps_list_base(l)
    n: i64 = 0
    i: i64 = 0
    while i < l->len:
        p: *char = base + usize(i) * usize(l->esize)
        if kind == PS_K_STR:
            if ps_str_eq(*(**PsStr)(p), *(**PsStr)(needle)):
                n += 1
        elif memcmp(p, needle, usize(l->esize)) == 0:
            n += 1
        i += 1
    return n

def ps_list_remove(ctx: *PsCtx, l: *PsList, needle: const *void, kind: i32, file: const *char, line: i32):
    i: i64 = ps_list_find(l, needle, kind)
    if i < 0:
        ps_raise(ctx, "remove(): the value is not in the list", PS_CAT_VALUE, file, line)
        return
    ps_list_remove_at(ctx, l, i, file, line)

def ps_list_clear(l: *PsList):
    if l != None:
        l->len = 0

# `pop` devolve o elemento E o tira, então a ORDEM importa: o índice é
# normalizado aqui (é onde a lista vazia levanta), o valor é lido no chamador
# com esse índice, e só depois o buraco é fechado. Fazer o contrário lê o
# elemento que veio depois — ou, no último, memória de ninguém.
def ps_list_pop_at(ctx: *PsCtx, l: *PsList, i: i64, has_i: bool, file: const *char, line: i32) -> i64:
    if l == None or l->len == 0:
        ps_raise(ctx, "pop() from an empty list", PS_CAT_INDEX, file, line)
        return 0
    if not has_i:
        return l->len - 1
    k: i64 = i + l->len if i < 0 else i
    if k < 0 or k >= l->len:
        ps_raise(ctx, "pop index out of range", PS_CAT_INDEX, file, line)
        return 0
    return k

# `a + b` e `a * n` (a lista, como o Python): uma lista NOVA, com os mesmos
# bytes de elemento — o que copia é a lista, não os objetos dentro dela
def ps_list_concat(ctx: *PsCtx, a: *PsList, b: *PsList) -> *PsList:
    out: *PsList = ps_list_slice(ctx, a, 0, 0, 1, False, False, "<concat>", 0)
    if b != None and b->len > 0:
        i: i64 = 0
        base: *char = ps_list_base(b)
        while i < b->len:
            memcpy(ps_list_push(ctx, out), base + usize(i) * usize(b->esize), usize(b->esize))
            # `ps_list_push` pode COLETAR, e coletar move `b`: a base tem de ser
            # relida a cada volta em vez de guardada antes do laço
            base = ps_list_base(b)
            i += 1
    return out

def ps_list_repeat(ctx: *PsCtx, l: *PsList, n: i64) -> *PsList:
    out: *PsList = ps_list_slice(ctx, l, 0, 0, 1, False, False, "<repeat>", 0)
    if n <= 0:
        out->len = 0
        return out
    k: i64 = 1
    while k < n:
        i: i64 = 0
        while i < l->len:
            memcpy(ps_list_push(ctx, out), ps_list_base(l) + usize(i) * usize(l->esize), usize(l->esize))
            i += 1
        k += 1
    return out

def ps_list_extend(ctx: *PsCtx, l: *PsList, b: *PsList):
    if l == None or b == None or b->len == 0:
        return
    if l == b:
        # `xs.extend(xs)` no Python duplica a lista, e o laço ingênuo não para:
        # cada push aumenta o limite que ele está testando
        n: i64 = b->len
        i: i64 = 0
        while i < n:
            memcpy(ps_list_push(ctx, l), ps_list_base(l) + usize(i) * usize(l->esize), usize(l->esize))
            i += 1
        return
    i2: i64 = 0
    while i2 < b->len:
        memcpy(ps_list_push(ctx, l), ps_list_base(b) + usize(i2) * usize(b->esize), usize(b->esize))
        i2 += 1

def ps_list_insert(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> *char:
    k: i64 = i + l->len if i < 0 else i
    if k < 0 or k > l->len:
        ps_raise(ctx, "insert position out of range", PS_CAT_INDEX, file, line)
        return ps_list_push(ctx, l)
    ps_list_push(ctx, l)          # grows by one; the slot moves below
    base: *char = (*char)(l->data) + sizeof(PsArr)
    es: usize = usize(l->esize)
    m: i64 = l->len - 1
    while m > k:
        memcpy(base + usize(m) * es, base + usize(m - 1) * es, es)
        m -= 1
    return base + usize(k) * es

def ps_list_remove_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32):
    k: i64 = i + l->len if i < 0 else i
    if k < 0 or k >= l->len:
        ps_raise(ctx, "list index out of range", PS_CAT_INDEX, file, line)
        return
    base: *char = (*char)(l->data) + sizeof(PsArr)
    es: usize = usize(l->esize)
    m: i64 = k
    while m + 1 < l->len:
        memcpy(base + usize(m) * es, base + usize(m + 1) * es, es)
        m += 1
    l->len -= 1

def ps_list_reverse(l: *PsList):
    base: *char = (*char)(l->data) + sizeof(PsArr)
    es: usize = usize(l->esize)
    tmp: char[64]
    i: i64 = 0
    j: i64 = l->len - 1
    while i < j and es <= 64:
        memcpy(tmp, base + usize(i) * es, es)
        memcpy(base + usize(i) * es, base + usize(j) * es, es)
        memcpy(base + usize(j) * es, tmp, es)
        i += 1
        j -= 1

# `sorted(xs)` (28.4): a COPY, in natural order. Sorting IN PLACE would be the
# other half of the pair and is not what the name says — Python has both, and
# this is the one whose meaning is unambiguous.
def ps_cmp_int(a: const *void, b: const *void) -> int:
    x: i64 = *(*i64)(a)
    y: i64 = *(*i64)(b)
    return -1 if x < y else (1 if x > y else 0)

def ps_cmp_float(a: const *void, b: const *void) -> int:
    x: f64 = *(*f64)(a)
    y: f64 = *(*f64)(b)
    return -1 if x < y else (1 if x > y else 0)

def ps_cmp_str(a: const *void, b: const *void) -> int:
    x: *PsStr = *(**PsStr)(a)
    y: *PsStr = *(**PsStr)(b)
    return strcmp(x->data, y->data)

# Merge sort ESTÁVEL sobre os próprios valores, com detecção de corridas (106).
#
# Por que não `qsort`: a estabilidade dele não é especificada. O da glibc é um
# merge sort e sai estável por acidente; o do macOS é um introsort e não sai. O
# que se vê disso é pequeno mas é real — `sorted([0.0, -0.0])` imprime
# `[0.0, -0.0]` aqui e podia imprimir o contrário lá, e duas strings de mesmo
# conteúdo trocariam de identidade. Uma ordem que depende de qual libc compilou
# é uma resposta diferente por plataforma, e é isso que isto remove. Os
# caminhos com `key=` e `cmp=` já eram estáveis (ordenam ÍNDICES); este é o que
# faltava.
#
# A detecção de corridas é a metade do Timsort que paga por si: uma lista já
# ordenada (ou já ordenada ao contrário) sai numa passada, que é o caso comum de
# quem chama `sorted` sobre algo que veio de um `sorted`. A outra metade dele —
# o merge galopante — fica de fora: ela muda o CUSTO em padrões específicos e
# não muda a ordem, que é o que se observa.
private def ps_run_end(base: *char, n: i64, es: usize, i: i64, cmp: def(a: const *void, b: const *void) -> int) -> i64:
    # quanto do vetor, a partir de `i`, já está em ordem — e se estiver em ordem
    # DECRESCENTE ESTRITA, inverte no lugar e devolve o fim (inverter só o
    # estrito é o que mantém a estabilidade: com iguais no meio, a inversão
    # trocaria a ordem original deles)
    if i + 1 >= n:
        return n
    j: i64 = i + 1
    if cmp((*void)(base + usize(j) * es), (*void)(base + usize(i) * es)) < 0:
        while j + 1 < n and cmp((*void)(base + usize(j + 1) * es), (*void)(base + usize(j) * es)) < 0:
            j += 1
        a: i64 = i
        b: i64 = j
        tmp: char[64]
        while a < b:
            if es <= sizeof(tmp):
                memcpy(&tmp[0], base + usize(a) * es, es)
                memcpy(base + usize(a) * es, base + usize(b) * es, es)
                memcpy(base + usize(b) * es, &tmp[0], es)
            a += 1
            b -= 1
        return j + 1
    while j + 1 < n and cmp((*void)(base + usize(j + 1) * es), (*void)(base + usize(j) * es)) >= 0:
        j += 1
    return j + 1

private def ps_msort_vals(base: *char, n: i64, es: usize, cmp: def(a: const *void, b: const *void) -> int) -> bool:
    if n < 2:
        return True
    # uma passada de corridas: se a primeira cobre tudo, não há nada a fazer
    first: i64 = ps_run_end(base, n, es, 0, cmp)
    if first == n:
        return True
    tmp: *char = (*char)(malloc(usize(n) * es))
    if tmp == None:
        return False
    # insertion sort binário nas corridas curtas, para que o merge tenha blocos
    # de tamanho decente — é o `minrun` do Timsort, com um valor fixo
    MINRUN: const i64 = 32
    i: i64 = 0
    while i < n:
        e: i64 = ps_run_end(base, n, es, i, cmp)
        stop: i64 = i + MINRUN
        if stop > n:
            stop = n
        # estende a corrida até MINRUN inserindo um por um, para trás
        k: i64 = e
        while k < stop:
            memcpy(tmp, base + usize(k) * es, es)
            j2: i64 = k
            while j2 > i and cmp((*void)(tmp), (*void)(base + usize(j2 - 1) * es)) < 0:
                memcpy(base + usize(j2) * es, base + usize(j2 - 1) * es, es)
                j2 -= 1
            memcpy(base + usize(j2) * es, tmp, es)
            k += 1
        i = stop if stop > e else e
    width: i64 = MINRUN
    while width < n:
        p: i64 = 0
        while p < n:
            mid: i64 = p + width
            if mid >= n:
                break
            hi: i64 = p + 2 * width
            if hi > n:
                hi = n
            # já em ordem entre os dois blocos: nada a fundir
            if cmp((*void)(base + usize(mid) * es), (*void)(base + usize(mid - 1) * es)) >= 0:
                p = hi
                continue
            memcpy(tmp, base + usize(p) * es, usize(hi - p) * es)
            a2: i64 = 0
            b2: i64 = mid - p
            o: i64 = p
            lena: i64 = mid - p
            lenb: i64 = hi - p
            while a2 < lena and b2 < lenb:
                # `< 0` e não `<= 0`: no empate vai o da ESQUERDA, que é a
                # definição de estável
                if cmp((*void)(tmp + usize(b2) * es), (*void)(tmp + usize(a2) * es)) < 0:
                    memcpy(base + usize(o) * es, tmp + usize(b2) * es, es)
                    b2 += 1
                else:
                    memcpy(base + usize(o) * es, tmp + usize(a2) * es, es)
                    a2 += 1
                o += 1
            while a2 < lena:
                memcpy(base + usize(o) * es, tmp + usize(a2) * es, es)
                a2 += 1
                o += 1
            while b2 < lenb:
                memcpy(base + usize(o) * es, tmp + usize(b2) * es, es)
                b2 += 1
                o += 1
            p = hi
        width *= 2
    free(tmp)
    return True

def ps_list_sorted(ctx: *PsCtx, l: *PsList, kind: i32) -> *PsList:
    out: *PsList = ps_list_slice(ctx, l, 0, 0, 1, False, False, "<copy>", 0)
    if out->len < 2:
        return out
    base: *char = (*char)(out->data) + sizeof(PsArr)
    es: usize = usize(out->esize)
    cmp: def(a: const *void, b: const *void) -> int = ps_cmp_int
    if kind == 1:
        cmp = ps_cmp_float
    elif kind == 2:
        cmp = ps_cmp_str
    if not ps_msort_vals(base, out->len, es, cmp):
        # sem memória para o temporário: ordena no lugar, sem prometer
        # estabilidade, em vez de devolver a lista fora de ordem
        qsort((*void)(base), usize(out->len), es, cmp)
    return out

# ---------- 104: `sum`, `any`, `all`, `round`, e min/max de uma lista ----------
#
# Todos percorrem a lista aqui e não numa comprehension gerada: o percurso é o
# mesmo, e o que se ganha é o COMPORTAMENTO do Python nas bordas — `sum([])` é
# 0, `all([])` é True (não há contraexemplo), `any([])` é False, e `min([])`
# levanta em vez de devolver um zero que parece resposta.
def ps_sum_int(ctx: *PsCtx, l: *PsList, start: i64, file: const *char, line: i32) -> i64:
    t: i64 = start
    if l == None:
        return t
    b: *i64 = (*i64)(ps_list_base(l))
    for i in range(l->len):
        t = ps_add(ctx, t, b[i], file, line)
    return t

def ps_sum_float(ctx: *PsCtx, l: *PsList, start: f64) -> f64:
    t: f64 = start
    if l == None:
        return t
    b: *f64 = (*f64)(ps_list_base(l))
    for i in range(l->len):
        t += b[i]
    return t

def ps_any(l: *PsList) -> bool:
    if l == None:
        return False
    b: *bool = (*bool)(ps_list_base(l))
    for i in range(l->len):
        if b[i]:
            return True
    return False

def ps_all(l: *PsList) -> bool:
    if l == None:
        return True
    b: *bool = (*bool)(ps_list_base(l))
    for i in range(l->len):
        if not b[i]:
            return False
    return True

# `round` do Python é MEIO PARA O PAR: round(2.5) é 2 e round(3.5) é 4. É o modo
# de arredondamento padrão do IEEE, então `rint` faz exatamente isso — escrever
# `floor(x + 0.5)` daria 3 em round(2.5) e divergiria em todo meio exato.
def ps_round(x: f64) -> i64:
    # NAO E' MAIS CHAMADA pela baixada: `round(x)` passou a emitir `rint` da libm
    # envolvido em `ps_f_to_i`, para que a conversao seja checada como qualquer
    # outra. Fica porque o SEED em C commitado ainda a chama com esta assinatura,
    # e mudar a assinatura de uma funcao do runtime obriga a re-semear. Sai na
    # proxima semeadura.
    return i64(rint(x))

# Com casas decimais o Python devolve FLOAT, e arredonda o valor DECIMAL — o que
# não é a mesma coisa que escalar por 10^n e arredondar em binário. O caso que
# mostra a diferença é `round(2.675, 2)`: o double mais próximo de 2.675 é
# 2.674999999999999822..., logo a resposta certa é 2.67, mas `2.675 * 100` dá
# exatamente 267.5 (os erros se cancelam) e o arredondamento binário devolve
# 2.68. É o caminho que o CPython usa quando não tem o dtoa de David Gay:
# imprimir com n casas — a libc arredonda corretamente, pelo valor exato — e ler
# de volta. Custa um snprintf e acerta todos os meios.
def ps_round_n(x: f64, n: i64) -> f64:
    if n < 0:
        # casas NEGATIVAS arredondam para a dezena/centena: aí não há texto com
        # n casas para pedir, e escalar é exato porque 10^k é exato até 10^22
        p2: f64 = pow(10.0, f64(-n))
        return rint(x / p2) * p2
    if n > 100 or x != x or x - x != 0.0:
        # mais casas do que um double distingue, ou nan/inf: o valor é ele mesmo
        return x
    buf: char[512]
    snprintf(buf, sizeof(buf), "%.*f", int(n), x)
    return strtod(buf, None)

def ps_list_min_int(ctx: *PsCtx, l: *PsList, want_max: bool, file: const *char, line: i32) -> i64:
    if l == None or l->len == 0:
        ps_raise(ctx, "min() or max() of an empty list", PS_CAT_VALUE, file, line)
        return 0
    b: *i64 = (*i64)(ps_list_base(l))
    v: i64 = b[0]
    for i in range(1, l->len):
        if (b[i] > v) if want_max else (b[i] < v):
            v = b[i]
    return v

def ps_list_min_float(ctx: *PsCtx, l: *PsList, want_max: bool, file: const *char, line: i32) -> f64:
    if l == None or l->len == 0:
        ps_raise(ctx, "min() or max() of an empty list", PS_CAT_VALUE, file, line)
        return 0.0
    b: *f64 = (*f64)(ps_list_base(l))
    v: f64 = b[0]
    for i in range(1, l->len):
        if (b[i] > v) if want_max else (b[i] < v):
            v = b[i]
    return v

def ps_list_min_str(ctx: *PsCtx, l: *PsList, want_max: bool, file: const *char, line: i32) -> *PsStr:
    if l == None or l->len == 0:
        ps_raise(ctx, "min() or max() of an empty list", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    b: **PsStr = (**PsStr)(ps_list_base(l))
    v: *PsStr = b[0]
    for i in range(1, l->len):
        # `ps_str_lt` devolve -1/0/1 e compara BYTES, que em UTF-8 é a mesma
        # ordem dos pontos de código — é o que o Python compara
        c: i32 = ps_str_lt(b[i], v)
        if (c > 0) if want_max else (c < 0):
            v = b[i]
    return v

# ---------- `bytes` (135.1/135.3/135.5/135.7) ----------
#
# The release hook, and it is all a finalizer is allowed to be (136.2): one
# `free`, no allocation, no raising, no user code.
private def ps_bytes_release(o: *void):
    b: *PsBytes = (*PsBytes)(o)
    if b->data != None:
        free(b->data)
        b->data = None
    b->len = usize(0)


# A `bytes` that OWNS its block. The block is malloc'd — outside every heap,
# never moving — which is what lets a slice of it be a view instead of a copy
# (135.1) and what lets it cross to P without pinning (141.3).
def ps_bytes_new(ctx: *PsCtx, src: const *char, len: usize) -> *PsBytes:
    b: *PsBytes = ps_alloc(ctx, sizeof(PsBytes), PS_TY_BYTES)
    b->data = None
    b->len = usize(0)
    b->owner = None
    b->foreign = 0
    b->hash = 0
    if len > usize(0):
        d: *char = (*char)(malloc(len))
        if d == None:
            ps_raise(ctx, "out of memory for bytes", PS_CAT_VALUE, "<bytes>", 0)
            return b
        if src != None:
            memcpy(d, src, len)
        b->data = d
        b->len = len
    # only an OWNER registers: a slice shares this block and would double-free
    # it. One entry per block, not one per slice.
    ps_add_final(ctx, (*PsObj)(b), ps_bytes_release)
    return b


# The ROOT owner of a block. A slice of a slice points at the same place the
# first slice does — otherwise a chain of them would keep every intermediate
# header alive, and one byte of a file would hold the file.
private def ps_bytes_root(b: *PsBytes) -> *PsBytes:
    return b->owner if b->owner != None else b


# A window over somebody else's block: no copy, no allocation of bytes, and no
# finalizer. This is `b[a:b]` (135.1).
def ps_bytes_view(ctx: *PsCtx, src: *PsBytes, off: usize, len: usize) -> *PsBytes:
    v: *PsBytes = ps_alloc(ctx, sizeof(PsBytes), PS_TY_BYTES)
    v->data = (src->data + off) if src->data != None else None
    v->len = len
    v->owner = ps_bytes_root(src)
    # a window over a FOREIGN block is foreign too, and it keeps no owner: the
    # lifetime is the Mapping's, and the Mapping is what `with` closes
    v->foreign = src->foreign
    if src->foreign != 0:
        v->owner = None
    v->hash = 0
    return v


def ps_bytes_len(b: *PsBytes) -> i64:
    return i64(b->len) if b != None else i64(0)


def ps_bytes_get(ctx: *PsCtx, b: *PsBytes, i: i64, file: const *char, line: i32) -> i64:
    n: i64 = i64(b->len) if b != None else i64(0)
    k: i64 = i + n if i < 0 else i          # 31.4: a negative index counts back
    if k < 0 or k >= n:
        ps_raise(ctx, "index out of range", PS_CAT_INDEX, file, line)
        return 0
    return i64(u8(b->data[usize(k)]))


# Python's slicing rules, and the SAME bounds the list and the string use —
# past the end trims instead of raising (17.3), which is the one place slicing
# and indexing disagree on purpose.
def ps_bytes_slice(ctx: *PsCtx, b: *PsBytes, a: i64, e: i64, st: i64, has_a: bool, has_b: bool, file: const *char, line: i32) -> *PsBytes:
    n: i64 = i64(b->len) if b != None else i64(0)
    lo: i64 = 0
    hi: i64 = 0
    if not ps_slice_bounds(ctx, n, a, e, st, has_a, has_b, out lo, out hi, file, line):
        return ps_bytes_new(ctx, "", usize(0))
    if st == 1:
        # the whole point: contiguous, so it is a VIEW and costs nothing
        if lo >= hi:
            return ps_bytes_new(ctx, "", usize(0))
        return ps_bytes_view(ctx, b, usize(lo), usize(hi - lo))
    # a STEP is not contiguous, so there is nothing to be a window over: it
    # copies, and says so by being the only branch that allocates a block
    cnt: i64 = 0
    q: i64 = lo
    while (st > 0 and q < hi) or (st < 0 and q > hi):
        cnt += 1
        q += st
    r: *PsBytes = ps_bytes_new(ctx, None, usize(cnt) if cnt > 0 else usize(0))
    k: usize = usize(0)
    q = lo
    while (st > 0 and q < hi) or (st < 0 and q > hi):
        r->data[k] = b->data[usize(q)]
        k += usize(1)
        q += st
    return r


# By CONTENT, like every other `==` in this language (22.2)
def ps_bytes_eq(a: *PsBytes, b: *PsBytes) -> bool:
    if a == None or b == None:
        return a == b
    if a->len != b->len:
        return False
    if a->len == usize(0):
        return True
    return memcmp(a->data, b->data, a->len) == 0


# ---- the four places a `bytes` is born (135.7) ----

# from a `List<u8>`: an explicit COPY, and explicit in both directions because
# each one copies and a copy that happens by itself is a copy nobody sees
def ps_bytes_from_list(ctx: *PsCtx, l: *PsList) -> *PsBytes:
    n: usize = usize(l->len) if l != None else usize(0)
    return ps_bytes_new(ctx, ps_list_base(l) if n > usize(0) else "", n)


# and back
def ps_list_from_bytes(ctx: *PsCtx, b: *PsBytes) -> *PsList:
    n: i64 = i64(b->len) if b != None else i64(0)
    l: *PsList = ps_list_new(ctx, 1, False, n)
    if n > 0:
        memcpy(ps_list_base(l), b->data, usize(n))
        l->len = n
    return l


# `s.encode()`: the UTF-8 a `str` already stores, handed over as bytes
def ps_bytes_from_str(ctx: *PsCtx, s: *PsStr) -> *PsBytes:
    if s == None:
        return ps_bytes_new(ctx, "", usize(0))
    return ps_bytes_new(ctx, s->data, usize(s->len))


# `str(b)`: and it CHECKS, for the reason 79.1 gives — a `str` promises
# codepoints, so one built out of invalid UTF-8 would lie about itself
def ps_str_from_bytesobj(ctx: *PsCtx, b: *PsBytes, file: const *char, line: i32) -> *PsStr:
    n: usize = usize(b->len) if b != None else usize(0)
    p: const *char = b->data if n > usize(0) else ""
    if not ps_utf8_valid(p, n):
        ps_raise(ctx, "these bytes are not valid UTF-8: keep them as bytes, or decode them yourself", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    return ps_str_new(ctx, p, n)


# ---------- buffers (19.4/52.3) ----------
def ps_buffer_new(ctx: *PsCtx, nbytes: i64, file: const *char, line: i32) -> *PsBuffer:
    # malloc'd, not collected: a worker holds this pointer, and the collector
    # that owns this context would move the object out from under it
    b: *PsBuffer = (*PsBuffer)(calloc(1, sizeof(PsBuffer)))
    b->obj.ty = PS_TY_BUFFER
    b->obj.size = u32(sizeof(PsBuffer))
    b->gone_from = None
    b->data = None
    b->nbytes = 0
    b->open = 0
    if nbytes < 0:
        ps_raise(ctx, "a buffer cannot have a negative size", PS_CAT_VALUE, file, line)
        return b
    b->data = (*char)(calloc(usize(nbytes) if nbytes > 0 else 1, 1))
    if b->data == None:
        ps_raise(ctx, "out of memory for the buffer", PS_CAT_VALUE, file, line)
        return b
    b->nbytes = usize(nbytes)
    b->open = 1
    return b

# 135.4: the block changes hands with zero copy, and the buffer is INVALIDATED.
# It is the same rule `transfer` follows (18.2) and it prevents the same
# mistake — two owners writing the same bytes — by making it an error instead
# of a race. Whoever wants to keep both writes `bytes(b)`, which copies.
#
# The `bytes` that comes out OWNS the block from here on, so it registers the
# finalizer and the buffer stops having one to run: `close` on a frozen buffer
# finds nothing to free, which is exactly right.
def ps_buffer_freeze(ctx: *PsCtx, b: *PsBuffer, file: const *char, line: i32) -> *PsBytes:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return ps_bytes_new(ctx, "", usize(0))
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return ps_bytes_new(ctx, "", usize(0))
    r: *PsBytes = ps_alloc(ctx, sizeof(PsBytes), PS_TY_BYTES)
    r->data = b->data
    r->len = b->nbytes
    r->owner = None
    r->foreign = 0
    r->hash = 0
    ps_add_final(ctx, (*PsObj)(r), ps_bytes_release)
    # the buffer gives the block up, and says so: `open = 0` is what every other
    # method already tests, so every one of them refuses from here on with the
    # message it already had
    b->data = None
    b->nbytes = usize(0)
    b->open = 0
    return r


def ps_buffer_close(ctx: *PsCtx, b: *PsBuffer):
    if b != None and b->open != 0:
        free(b->data)
        b->data = None
        b->open = 0

# 135.5: as operações valem nos DOIS, e `b[i]` num Buffer é um byte — pela
# mesma razão que num `bytes` é: um byte tem tipo próprio e um carácter não
# (3.4). Directo, sem passar por uma janela: uma janela por índice seria uma
# alocação por leitura.
def ps_buffer_at(ctx: *PsCtx, b: *PsBuffer, i: i64, file: const *char, line: i32) -> i64:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return 0
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return 0
    n: i64 = i64(b->nbytes)
    k: i64 = i + n if i < 0 else i        # 31.4: índice negativo conta de trás
    if k < 0 or k >= n:
        ps_raise(ctx, "index out of range", PS_CAT_INDEX, file, line)
        return 0
    return i64(u8(b->data[usize(k)]))


def ps_buffer_put(ctx: *PsCtx, b: *PsBuffer, i: i64, v: i64, file: const *char, line: i32):
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return
    n: i64 = i64(b->nbytes)
    k: i64 = i + n if i < 0 else i
    if k < 0 or k >= n:
        ps_raise(ctx, "index out of range", PS_CAT_INDEX, file, line)
        return
    b->data[usize(k)] = char(u8(v & 0xFF))


def ps_buffer_size(b: *PsBuffer) -> i64:
    return i64(b->nbytes) if b != None else 0

def ps_buffer_gone(ctx: *PsCtx, b: *PsBuffer) -> bool

private def ps_buffer_slot(ctx: *PsCtx, b: *PsBuffer, i: i64, file: const *char, line: i32) -> *f64:
    if ps_buffer_gone(ctx, b):
        ps_raise(ctx, "this buffer was transferred: it belongs to whoever received it (18.2)", PS_CAT_VALUE, file, line)
        return None
    if b == None or b->open == 0:
        ps_raise(ctx, "this buffer is closed", PS_CAT_VALUE, file, line)
        return None
    n: i64 = i64(b->nbytes / 8)
    k: i64 = i + n if i < 0 else i
    if k < 0 or k >= n:
        ps_raise(ctx, "buffer index out of range", PS_CAT_INDEX, file, line)
        return None
    return (*f64)(b->data + usize(k) * 8)

def ps_buffer_get_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, file: const *char, line: i32) -> f64:
    p: *f64 = ps_buffer_slot(ctx, b, i, file, line)
    return *p if p != None else 0.0

def ps_buffer_set_f64(ctx: *PsCtx, b: *PsBuffer, i: i64, v: f64, file: const *char, line: i32):
    p: *f64 = ps_buffer_slot(ctx, b, i, file, line)
    if p != None:
        *p = v

# has THIS context given the buffer away? (18.2)
# 110: `gc.stats()` — o estado do coletor DESTE contexto, como `Dict<str, int>`.
#
# Um dict e não um record: assim não há tipo novo para a linguagem aprender, o
# `print` já sabe imprimi-lo, e acrescentar uma medida depois não quebra
# programa nenhum. Mora aqui (camada dos valores) porque constrói dict e str; a
# memória só guarda os números.
def ps_gc_stats(ctx: *PsCtx) -> *PsDict:
    d: *PsDict = ps_dict_new(ctx, i32(sizeof(PsStrPtr)), i32(sizeof(i64)), 1, True, False)
    # 136.3: the two that make a LEAK measurable. Registered against released
    # is a number a gate can compare, and it is the whole reason the exit pass
    # exists — without it "the cleanup is guaranteed" is a claim nobody checks.
    NAMES: const *char[] = {"live", "alloced", "objects", "collections", "budget", "budget_objects",
                            "finalizers", "finalizers_run"}
    vals: i64[8]
    vals[0] = i64(ctx->live)
    vals[1] = i64(ctx->alloced)
    vals[2] = ctx->nalloc
    vals[3] = ctx->ngc
    vals[4] = i64(ctx->gc_bytes)
    vals[5] = ctx->gc_objects
    vals[6] = ctx->nfinal
    vals[7] = ctx->nfinal_run
    for i in range(8):
        k: *PsStr = ps_str_new(ctx, NAMES[i], strlen(NAMES[i]))
        kp: *PsStr = k
        slot: *char = ps_dict_put(ctx, d, (*char)(&kp))
        *(*i64)(slot) = vals[i]
    return d

# 39.2: `str()` de um `any`. Um `any` carrega o que é — um número, um bool ou
# None vão numa caixa com a espécie escrita (`PsAny.kind`), e um objecto tem o
# cabeçalho dele —, portanto isto rende sem que o compilador diga o tipo.
#
# O que NÃO se consegue é um contentor: o cabeçalho de uma lista diz que é uma
# lista e não diz DE QUÊ, e o mesmo para um dicionário. Escrever "List(3)"
# seria inventar; levantar com a frase que diz o que fazer é honesto, e a coisa a
# fazer é estreitar com `as` — que é a porta que o `any` sempre teve (55.2).
private def ps_any_render(ctx: *PsCtx, o: *PsObj, nested: bool, file: const *char, line: i32) -> *PsStr

def ps_str_of_any(ctx: *PsCtx, o: *PsObj, file: const *char, line: i32) -> *PsStr:
    return ps_any_render(ctx, o, False, file, line)

# `nested` diz se isto está DENTRO de um contentor, e a única coisa que muda é a
# string: `str("a")` é `a`, mas `["a"]` escreve-se `['a']`. É a distinção
# str/repr do Python, e o caminho estático já a faz — se este não a fizesse, o
# mesmo valor sairia de duas maneiras conforme o tipo com que foi anotado.
private def ps_any_render(ctx: *PsCtx, o: *PsObj, nested: bool, file: const *char, line: i32) -> *PsStr:
    if o == None:
        return ps_str_new(ctx, "None", 4)
    match o->ty:
        case PS_TY_ANY:
            a: *PsAny = (*PsAny)(o)
            if a->kind == PS_ANY_INT:
                return ps_str_from_int(ctx, a->i)
            if a->kind == PS_ANY_FLOAT:
                return ps_str_from_float(ctx, a->f)
            if a->kind == PS_ANY_BOOL:
                return ps_str_from_bool(ctx, a->i != 0)
            return ps_str_new(ctx, "None", 4)
        case PS_TY_STR:
            # `str()` de uma string é a própria string; dentro de um contentor
            # vai entre plicas, como o caminho estático faz
            return ps_str_quoted(ctx, (*PsStr)(o)) if nested else (*PsStr)(o)
        case PS_TY_BYTES:
            return ps_str_from_bytesobj(ctx, (*PsBytes)(o), file, line)
        case PS_TY_USER:
            # um `struct` do programa: o descritor traz tudo — o `to_str()` que o
            # tipo escreveu, ou a forma derivada da 44.3 —, e quem o percorre é o
            # mesmo `ps_repr_desc` que o `print` de um tipo estático usa. Uma só
            # implementação, portanto o mesmo texto pelos dois caminhos.
            u: *PsUser = (*PsUser)(o)
            if u->desc != None:
                return ps_repr_desc(ctx, (*void)(o), u->desc, 0)
            return ps_str_new(ctx, "<struct>", 8)
        case PS_TY_LIST:
            # 39.2 já garante que os elementos são `any` — o `any` não aceita
            # uma `List<int>`, só uma `List<any>` —, portanto cada um carrega o
            # que é e a recursão fecha.
            l: *PsList = (*PsList)(o)
            out: *PsStr = ps_str_new(ctx, "[", 1)
            base: **PsObj = (**PsObj)(ps_list_base(l))
            for i in range(i32(l->len)):
                if i > 0:
                    out = ps_str_concat(ctx, out, ps_str_new(ctx, ", ", 2))
                out = ps_str_concat(ctx, out, ps_any_render(ctx, base[i], True, file, line))
            return ps_str_concat(ctx, out, ps_str_new(ctx, "]", 1))
        case PS_TY_DICT:
            d: *PsDict = (*PsDict)(o)
            od: *PsStr = ps_str_new(ctx, "{", 1)
            n: i64 = ps_dict_len(d)
            for i in range(i32(n)):
                if i > 0:
                    od = ps_str_concat(ctx, od, ps_str_new(ctx, ", ", 2))
                kp: **PsStr = (**PsStr)(ps_dict_key_at(d, i64(i)))
                od = ps_str_concat(ctx, od, ps_str_quoted(ctx, *kp))
                od = ps_str_concat(ctx, od, ps_str_new(ctx, ": ", 2))
                vp: **PsObj = (**PsObj)(ps_dict_val_at(d, i64(i)))
                od = ps_str_concat(ctx, od, ps_any_render(ctx, *vp, True, file, line))
            return ps_str_concat(ctx, od, ps_str_new(ctx, "}", 1))
        case _:
            pass
    # o que sobra são punhos — um ficheiro, um socket, uma tarefa —, e nenhum
    # deles é um valor que se escreva. A 39.2 também não os deixa entrar num
    # `any`, portanto isto é a rede e não o caminho.
    ps_raise(ctx, "str() of an `any` that holds something with no written form", PS_CAT_TYPE, file, line)
    return ps_str_new(ctx, "", 0)

def ps_buffer_gone(ctx: *PsCtx, b: *PsBuffer) -> bool:
    return b != None and b->gone_from != None and b->gone_from == (*void)(ctx)
# ---------- the stable sort, shared by `key=` and by `Comparable` ----------
# Both sort INDICES and move the elements once at the end, because the runtime
# does not know what an element is — it moves bytes. `less` decides STRICTLY,
# and the merge takes from the left whenever the right is not strictly smaller,
# which is what makes the whole thing stable.
struct PsKeyCmp:
    keys: *f64

struct PsFnCmp:
    fn: def(env: *void, ctx: *PsCtx, a: const *void, b: const *void) -> i64
    env: *void
    ctx: *PsCtx
    base: *char
    es: usize

private def ps_less_key(env: *void, a: i64, b: i64) -> bool:
    k: *PsKeyCmp = (*PsKeyCmp)(env)
    return k->keys[a] < k->keys[b]

private def ps_less_cmp(env: *void, a: i64, b: i64) -> bool:
    c: *PsFnCmp = (*PsFnCmp)(env)
    if c->ctx->exc != None:
        return False
    return c->fn(c->env, c->ctx, c->base + usize(a) * c->es, c->base + usize(b) * c->es) < 0

private def ps_msort_idx(idx: *i64, n: i64, less: def(env: *void, a: i64, b: i64) -> bool, env: *void):
    if n < 2:
        return
    tmp: *i64 = (*i64)(malloc(usize(n) * sizeof(i64)))
    if tmp == None:
        return
    width: i64 = 1
    while width < n:
        i: i64 = 0
        while i < n:
            mid: i64 = i + width
            if mid > n:
                mid = n
            hi: i64 = i + 2 * width
            if hi > n:
                hi = n
            a: i64 = i
            b: i64 = mid
            o: i64 = i
            while a < mid and b < hi:
                # `not less(b, a)` and not `less(a, b)`: on a tie the LEFT one
                # goes first, which is the definition of stable
                if less(env, idx[b], idx[a]):
                    tmp[o] = idx[b]
                    b += 1
                else:
                    tmp[o] = idx[a]
                    a += 1
                o += 1
            while a < mid:
                tmp[o] = idx[a]
                a += 1
                o += 1
            while b < hi:
                tmp[o] = idx[b]
                b += 1
                o += 1
            i += 2 * width
        memcpy(idx, tmp, usize(n) * sizeof(i64))
        width *= 2
    free(tmp)

# `sorted(xs)` over a type that implements `Comparable` (62.1): the order comes
# from the type's own `cmp`, reached through an adapter the compiler emits per
# call site — the runtime never learns what the element is.
def ps_list_sorted_cmp(ctx: *PsCtx, l: *PsList, cmpfn: def(env: *void, ctx: *PsCtx, a: const *void, b: const *void) -> i64, env: *void) -> *PsList:
    n: i64 = l->len
    out: *PsList = ps_list_slice(ctx, l, 0, 0, 1, False, False, "<copy>", 0)
    if n < 2:
        return out
    idx: *i64 = (*i64)(malloc(usize(n) * sizeof(i64)))
    if idx == None:
        return out
    for i in range(i32(n)):
        idx[i] = i64(i)
    base: *char = (*char)(out->data) + sizeof(PsArr)
    es: usize = usize(out->esize)
    fenv: PsFnCmp = {cmpfn, env, ctx, base, es}
    ps_msort_idx(idx, n, ps_less_cmp, &fenv)
    if ctx->exc != None:
        free(idx)
        return out
    src: *char = (*char)(malloc(usize(n) * es))
    memcpy(src, base, usize(n) * es)
    for i2 in range(i32(n)):
        memcpy(base + usize(i2) * es, src + usize(idx[i2]) * es, es)
    free(src)
    free(idx)
    return out

def ps_list_sorted_by(ctx: *PsCtx, l: *PsList, keyfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> f64, env: *void) -> *PsList:
    n: i64 = l->len
    out: *PsList = ps_list_slice(ctx, l, 0, 0, 1, False, False, "<copy>", 0)
    if n < 2:
        return out
    # the key of each element, computed once (28.4)
    keys: *f64 = (*f64)(malloc(usize(n) * sizeof(f64)))
    idx: *i64 = (*i64)(malloc(usize(n) * sizeof(i64)))
    base: *char = (*char)(out->data) + sizeof(PsArr)
    es: usize = usize(out->esize)
    for i in range(i32(n)):
        keys[i] = keyfn(env, ctx, (*void)(base + usize(i) * es))
        idx[i] = i64(i)
        if ctx->exc != None:
            free(keys)
            free(idx)
            return out
    # STABLE merge sort over the INDICES. It was an insertion sort, which is
    # also stable and is O(n²) — fine for the ten-element case somebody had in
    # mind and a trap in a language that says it competes with Python, whose
    # sort is O(n log n). The elements themselves move once, at the end.
    kenv: PsKeyCmp = {keys}
    ps_msort_idx(idx, n, ps_less_key, &kenv)
    src: *char = (*char)(malloc(usize(n) * es))
    memcpy(src, base, usize(n) * es)
    for i2 in range(i32(n)):
        memcpy(base + usize(i2) * es, src + usize(idx[i2]) * es, es)
    free(src)
    free(keys)
    free(idx)
    return out

def ps_sys_monotonic() -> f64:
    ts: timespec
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return f64(ts.tv_sec) + f64(ts.tv_nsec) / 1000000000.0
def ps_sys_time() -> f64:
    tw: timespec
    clock_gettime(CLOCK_REALTIME, &tw)
    return f64(tw.tv_sec) + f64(tw.tv_nsec) / 1000000000.0
# ---------- function values (28.1/19.2) ----------
def ps_closure_new(ctx: *PsCtx, fn: *void, env: *PsObj, sig: const *char) -> *PsClosure:
    c: *PsClosure = (*PsClosure)(ps_alloc(ctx, sizeof(PsClosure), PS_TY_CLOSURE))
    c->fn = fn
    c->env = env
    c->sig = sig
    return c

# 29.4: the signature has to agree. The spellings are written by the compiler
# from the same canonical form on both sides, so a comparison of the text is a
# comparison of the TYPES — and it happens once, before the call.
def ps_closure_narrow(ctx: *PsCtx, c: *PsClosure, want: const *char, file: const *char, line: i32) -> *PsClosure:
    if c == None:
        ps_raise(ctx, "there is no function here to narrow", PS_CAT_VALUE, file, line)
        return None
    if c->sig == None or strcmp(c->sig, want) != 0:
        ps_raise_str(ctx, ps_str_concat(ctx, ps_str_new(ctx, "this function is ", 17), ps_str_concat(ctx, ps_str_new(ctx, c->sig if c->sig != None else "of unknown shape", strlen(c->sig) if c->sig != None else usize(16)), ps_str_concat(ctx, ps_str_new(ctx, ", not ", 6), ps_str_new(ctx, want, strlen(want))))), i64(PS_CAT_TYPE), file, line)
        return None
    return c

# ---------- `any` (39.2) and `as` (55.2) ----------
private def ps_any_new(ctx: *PsCtx, kind: i32) -> *PsAny:
    a: *PsAny = (*PsAny)(ps_alloc(ctx, sizeof(PsAny), PS_TY_ANY))
    a->kind = kind
    a->i = 0
    a->f = 0.0
    return a

def ps_any_int(ctx: *PsCtx, v: i64) -> *PsObj:
    a: *PsAny = ps_any_new(ctx, PS_ANY_INT)
    a->i = v
    return (*PsObj)(a)

def ps_any_float(ctx: *PsCtx, v: f64) -> *PsObj:
    a: *PsAny = ps_any_new(ctx, PS_ANY_FLOAT)
    a->f = v
    return (*PsObj)(a)

def ps_any_bool(ctx: *PsCtx, v: bool) -> *PsObj:
    a: *PsAny = ps_any_new(ctx, PS_ANY_BOOL)
    a->i = 1 if v else 0
    return (*PsObj)(a)

def ps_any_none(ctx: *PsCtx) -> *PsObj:
    return (*PsObj)(ps_any_new(ctx, PS_ANY_NONE))

# what an `any` says it is, in words, for the message a failed `as` prints
private def ps_any_what(v: *PsObj) -> const *char:
    if v == None:
        return "nothing"
    match v->ty:
        case PS_TY_STR:
            return "str"
        case PS_TY_LIST:
            return "List"
        case PS_TY_DICT:
            return "Dict"
        case PS_TY_ANY:
            a: *PsAny = (*PsAny)(v)
            if a->kind == PS_ANY_INT:
                return "int"
            if a->kind == PS_ANY_FLOAT:
                return "float"
            if a->kind == PS_ANY_BOOL:
                return "bool"
            return "None"
        case _:
            return "a value of another type"

private def ps_as_fail(ctx: *PsCtx, v: *PsObj, want: const *char, file: const *char, line: i32):
    msg: char[160]
    snprintf(msg, 160, "this `any` holds %s, not %s", ps_any_what(v), want)
    ps_raise(ctx, msg, PS_CAT_TYPE, file, line)

def ps_as_int(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> i64:
    if v == None or v->ty != PS_TY_ANY or ((*PsAny)(v))->kind != PS_ANY_INT:
        ps_as_fail(ctx, v, "int", file, line)
        return 0
    return ((*PsAny)(v))->i

def ps_as_float(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> f64:
    if v != None and v->ty == PS_TY_ANY:
        a: *PsAny = (*PsAny)(v)
        if a->kind == PS_ANY_FLOAT:
            return a->f
        if a->kind == PS_ANY_INT:
            return f64(a->i)      # int promotes to float, as everywhere (32.1)
    ps_as_fail(ctx, v, "float", file, line)
    return 0.0

def ps_as_bool(ctx: *PsCtx, v: *PsObj, file: const *char, line: i32) -> bool:
    if v == None or v->ty != PS_TY_ANY or ((*PsAny)(v))->kind != PS_ANY_BOOL:
        ps_as_fail(ctx, v, "bool", file, line)
        return False
    return ((*PsAny)(v))->i != 0

def ps_as_ref(ctx: *PsCtx, v: *PsObj, want: i32, what: const *char, file: const *char, line: i32) -> *PsObj:
    if v == None or v->ty != want:
        ps_as_fail(ctx, v, what, file, line)
        return None
    return v

def ps_is_kind(v: *PsObj, ty: i32, kind: i32) -> bool:
    if v == None:
        return False
    if ty != PS_TY_ANY:
        return v->ty == ty
    return v->ty == PS_TY_ANY and ((*PsAny)(v))->kind == kind

def ps_exc_take(ctx: *PsCtx) -> *PsErr:
    e: *PsErr = ctx->exc
    ctx->exc = None
    return e

def ps_exc_put(ctx: *PsCtx, e: *PsErr):
    if e != None:
        ctx->exc = e

# ---------- pack / unpack (59) ----------
# One field at a time, least significant byte first. Reading and writing go
# through the same shift ladder, so the format does not depend on how this
# machine happens to store an integer — and a float travels as the bits it is.
def ps_pack_int(ctx: *PsCtx, l: *PsList, v: u64, nbytes: i32, be: i32):
    for i in range(nbytes):
        # the shift ladder decides the order, so neither side depends on how
        # THIS machine happens to store an integer
        k: i32 = (nbytes - 1 - i) if be != 0 else i
        p: *char = ps_list_push(ctx, l)
        *(*u8)(p) = u8((v >> u64(k * 8)) & u64(255))

def ps_unpack_int(l: *PsList, off: i64, nbytes: i32, be: i32) -> u64:
    v: u64 = 0
    base: *u8 = (*u8)(ps_list_base(l))
    for i in range(nbytes):
        k: i32 = (nbytes - 1 - i) if be != 0 else i
        v = v | (u64(base[off + i64(i)]) << u64(k * 8))
    return v

def ps_pack_f64(ctx: *PsCtx, l: *PsList, v: f64, be: i32):
    b: u64 = 0
    memcpy(&b, &v, sizeof(b))
    ps_pack_int(ctx, l, b, 8, be)

def ps_unpack_f64(l: *PsList, off: i64, be: i32) -> f64:
    b: u64 = ps_unpack_int(l, off, 8, be)
    v: f64 = 0.0
    memcpy(&v, &b, sizeof(v))
    return v

def ps_pack_f32(ctx: *PsCtx, l: *PsList, v: f32, be: i32):
    b: u32 = 0
    memcpy(&b, &v, sizeof(b))
    ps_pack_int(ctx, l, u64(b), 4, be)

def ps_unpack_f32(l: *PsList, off: i64, be: i32) -> f32:
    b: u32 = u32(ps_unpack_int(l, off, 4, be))
    v: f32 = 0.0
    memcpy(&v, &b, sizeof(v))
    return v

def ps_unpack_check(ctx: *PsCtx, l: *PsList, want: i64, file: const *char, line: i32):
    if l == None or l->len != want:
        ps_raise(ctx, "these bytes are not the right length for this record", PS_CAT_VALUE, file, line)

# ---------- lists ----------
private def ps_list_grow(ctx: *PsCtx, l: *PsList, need: i64)

# 98.5: "walk INTO each element", for a list whose element is a tuple holding a
# reference. Returns the list so it can be said in one expression, where the
# container is built.
def ps_list_etrace(l: *PsList, fn: def(o: *void, to: *PsBlock)) -> *PsList:
    if l != None:
        l->etrace = fn
    return l

def ps_dict_vtrace(d: *PsDict, fn: def(o: *void, to: *PsBlock)) -> *PsDict:
    if d != None:
        d->vtrace = fn
    return d

def ps_list_new(ctx: *PsCtx, esize: i32, eref: bool, cap: i64) -> *PsList:
    l: *PsList = ps_alloc(ctx, sizeof(PsList), PS_TY_LIST)
    l->len = 0
    l->cap = 0
    l->esize = esize
    l->eref = eref
    l->etrace = None
    l->data = None
    l->raw = None       # an ordinary list OWNS its bytes (18.3 borrows them)
    l->owner = None
    if cap > 0:
        ps_list_grow(ctx, l, cap)
    return l

# Replaces the backing storage with a bigger one. The HEADER does not move, so
# every reference to the list survives a growth untouched.
private def ps_list_grow(ctx: *PsCtx, l: *PsList, need: i64):
    if need <= l->cap:
        return
    ncap: i64 = 8 if l->cap == 0 else l->cap * 2
    while ncap < need:
        ncap *= 2
    nb: usize = usize(ncap) * usize(l->esize)
    a: *PsArr = ps_alloc(ctx, sizeof(PsArr) + nb, PS_TY_ARR)
    a->nbytes = nb
    if l->data != None and l->len > 0:
        memcpy((*char)(a) + sizeof(PsArr), (*char)(l->data) + sizeof(PsArr), usize(l->len) * usize(l->esize))
    l->data = a
    l->cap = ncap

def ps_list_len(l: *PsList) -> i64:
    return l->len

# The base of the elements. A list with no storage yet answers a SCRATCH slot
# instead of None: after an index that raised, the generated code still performs
# the read whose value the exception check is about to throw away, and reading
# from nowhere would take the program down before the check ever runs.
private PS_SCRATCH: char[64]

def ps_list_base(l: *PsList) -> *char:
    # a view (18.3) borrows the buffer's bytes: they are where they always
    # were, and indexing, iterating and slicing all go through here
    if l->raw != None:
        return l->raw
    if l->data == None:
        return PS_SCRATCH
    return (*char)(l->data) + sizeof(PsArr)

def ps_arr_at(ctx: *PsCtx, i: i64, n: i64, file: const *char, line: i32) -> i64:
    k: i64 = i + n if i < 0 else i
    if k < 0 or k >= n:
        ps_raise(ctx, "array index out of range", PS_CAT_INDEX, file, line)
        return 0
    return k

def ps_list_at(ctx: *PsCtx, l: *PsList, i: i64, file: const *char, line: i32) -> i64:
    # negative counts from the end (31.4), and out of range RAISES (5.2) rather
    # than reading whatever is there
    k: i64 = i + l->len if i < 0 else i
    if k < 0 or k >= l->len:
        ps_raise(ctx, "list index out of range", PS_CAT_INDEX, file, line)
        return 0
    return k

def ps_list_push(ctx: *PsCtx, l: *PsList) -> *char:
    if l->raw != None:
        # 18.3: the window has exactly the elements the buffer has room for.
        # Growing would mean allocating, and then it would not be the same
        # bytes the other threads are looking at.
        ps_raise(ctx, "a view over a buffer has a fixed size", PS_CAT_VALUE, "<view>", 0)
        return PS_SCRATCH
    ps_list_grow(ctx, l, l->len + 1)
    p: *char = ps_list_base(l) + usize(l->len) * usize(l->esize)
    l->len += 1
    memset(p, 0, usize(l->esize))
    return p

# ---------- dicts and sets ----------
private def ps_dict_rehash(ctx: *PsCtx, d: *PsDict, ncap: i64)

def ps_hash_bytes(b: const *char, n: usize) -> u64:
    h: u64 = 1469598103934665603     # FNV-1a
    for i in range(n):
        h ^= u64(u8(b[i]))
        h *= 1099511628211
    return h

# the hash and the equality of ONE key, by kind. A `str` key hashes its BYTES
# and compares by content (22.2); everything else is bits, which is also what
# makes a float key compare `+0.0` and `-0.0` apart (47.1).
private def ps_key_hash(d: *PsDict, k: const *char) -> u64:
    if d->kkind == PS_K_STR:
        s: *PsStr = *(**PsStr)(k)
        return ps_hash_bytes(s->data, usize(s->len))
    return ps_hash_bytes(k, usize(d->ksize))

private def ps_key_eq(d: *PsDict, a: const *char, b: const *char) -> bool:
    if d->kkind == PS_K_STR:
        return ps_str_eq(*(**PsStr)(a), *(**PsStr)(b))
    return memcmp(a, b, usize(d->ksize)) == 0

# EMPTY and DEAD live in the index, not in a byte array of their own: a slot
# either names an entry or says why it does not.
# a raw byte array in the collected heap. Zeroed, because a field that is a
# reference has to start as None or the collector would follow whatever was
# there.
private def ps_arr_new(ctx: *PsCtx, nbytes: usize) -> *PsArr:
    a: *PsArr = ps_alloc(ctx, sizeof(PsArr) + nbytes, PS_TY_ARR)
    a->nbytes = nbytes
    memset((*char)(a) + sizeof(PsArr), 0, nbytes)
    return a

private def ps_arr_data(a: *PsArr) -> *char:
    return (*char)(a) + sizeof(PsArr)

private const PS_IDX_EMPTY: const i64 = -1
private const PS_IDX_DEAD: const i64 = -2

private def ps_idx_at(d: *PsDict, i: i64) -> i64:
    return *(*i64)(ps_arr_data(d->index) + usize(i) * sizeof(i64))

private def ps_idx_set(d: *PsDict, i: i64, v: i64):
    *(*i64)(ps_arr_data(d->index) + usize(i) * sizeof(i64)) = v

# The slot for `key`. Answers the ENTRY it holds, or -1 when the key is not
# there — and in that case `slot` comes back as the place to write it, which is
# the first DEAD slot of the probe chain if there was one, so a table that has
# been deleted from fills its holes instead of growing past them.
private def ps_dict_find(d: *PsDict, key: const *char, ref slot: i64) -> i64:
    mask: u64 = u64(d->cap) - 1
    i: u64 = ps_key_hash(d, key) & mask
    free: i64 = -1
    while True:
        e: i64 = ps_idx_at(d, i64(i))
        if e == PS_IDX_EMPTY:
            slot = i64(i) if free < 0 else free
            return -1
        if e == PS_IDX_DEAD:
            if free < 0:
                free = i64(i)
        elif ps_key_eq(d, ps_arr_data(d->keys) + usize(e) * usize(d->ksize), key):
            slot = i64(i)
            return e
        i = (i + 1) & mask

# Rebuilds the index from nothing and COMPACTS the entries, keeping their order.
# This is the only place a dead entry disappears, which is what keeps iteration
# proportional to what is alive rather than to everything that ever was.
#
# Nothing here holds a collected pointer across a safe point: `ps_alloc` never
# collects (that is the rule the whole moving collector rests on), so the old
# arrays stay put while the new ones are built.
private def ps_dict_rebuild(ctx: *PsCtx, d: *PsDict, ncap: i64, necap: i64):
    ok: *PsArr = d->keys
    ov: *PsArr = d->vals
    ost: *PsArr = d->state
    onent: i64 = d->nent
    d->index = ps_arr_new(ctx, usize(ncap) * sizeof(i64))
    d->keys = ps_arr_new(ctx, usize(necap) * usize(d->ksize))
    d->vals = ps_arr_new(ctx, usize(necap) * usize(d->vsize if d->vsize > 0 else 1))
    d->state = ps_arr_new(ctx, usize(necap))
    d->cap = ncap
    d->ecap = necap
    d->nent = 0
    d->n = 0
    # a fresh array arrives zeroed and zero is a perfectly good entry number, so
    # every slot has to be written as EMPTY on purpose
    k: i64 = 0
    while k < ncap:
        ps_idx_set(d, k, PS_IDX_EMPTY)
        k += 1
    if ost == None:
        return
    okeys: *char = ps_arr_data(ok)
    ovals: *char = ps_arr_data(ov)
    ostate: *char = ps_arr_data(ost)
    e: i64 = 0
    while e < onent:
        if ostate[e] == 1:
            kp: *char = okeys + usize(e) * usize(d->ksize)
            slot: i64 = 0
            ps_dict_find(d, kp, ref slot)
            ne: i64 = d->nent
            memcpy(ps_arr_data(d->keys) + usize(ne) * usize(d->ksize), kp, usize(d->ksize))
            if d->vsize > 0:
                memcpy(ps_arr_data(d->vals) + usize(ne) * usize(d->vsize), ovals + usize(e) * usize(d->vsize), usize(d->vsize))
            ps_arr_data(d->state)[ne] = 1
            ps_idx_set(d, slot, ne)
            d->nent = ne + 1
            d->n += 1
        e += 1

def ps_dict_new(ctx: *PsCtx, ksize: i32, vsize: i32, kkind: i32, kref: bool, vref: bool) -> *PsDict:
    d: *PsDict = ps_alloc(ctx, sizeof(PsDict), PS_TY_DICT)
    d->n = 0
    d->nent = 0
    d->ecap = 0
    d->cap = 0
    d->ksize = ksize
    d->vsize = vsize
    d->kkind = kkind
    d->vtrace = None
    d->kref = kref
    d->vref = vref
    d->index = None
    d->keys = None
    d->vals = None
    d->state = None
    ps_dict_rebuild(ctx, d, 8, 6)
    return d

def ps_dict_len(d: *PsDict) -> i64:
    return d->n

def ps_dict_put(ctx: *PsCtx, d: *PsDict, key: const *char) -> *char:
    # Two things can be full: the dense array of entries, and the index at its
    # 3/4 load. Either one rebuilds — and the rebuild only GROWS when it is the
    # live set that filled the table. A table full of dead entries is compacted
    # in place, which is what keeps delete-and-reinsert from growing for ever.
    if d->nent + 1 > d->ecap or (d->nent + 1) * 4 >= d->cap * 3:
        ncap: i64 = d->cap
        while (d->n + 1) * 4 >= ncap * 3:
            ncap = ncap * 2
        necap: i64 = ncap * 3 / 4
        if necap < 6:
            necap = 6
        ps_dict_rebuild(ctx, d, ncap, necap)
    slot: i64 = 0
    e: i64 = ps_dict_find(d, key, ref slot)
    if e < 0:
        e = d->nent
        memcpy(ps_arr_data(d->keys) + usize(e) * usize(d->ksize), key, usize(d->ksize))
        ps_arr_data(d->state)[e] = 1
        ps_idx_set(d, slot, e)
        d->nent = e + 1
        d->n += 1
    if d->vsize == 0:
        return None
    return ps_arr_data(d->vals) + usize(e) * usize(d->vsize)

def ps_dict_get(ctx: *PsCtx, d: *PsDict, key: const *char, file: const *char, line: i32) -> *char:
    slot: i64 = 0
    e: i64 = ps_dict_find(d, key, ref slot)
    if e < 0:
        # a missing key RAISES (5.2); `get(k, default)` is the other idiom
        ps_raise(ctx, "key not found", PS_CAT_KEY, file, line)
        return ps_arr_data(d->vals)
    return ps_arr_data(d->vals) + usize(e) * usize(d->vsize)

def ps_dict_has(d: *PsDict, key: const *char) -> bool:
    slot: i64 = 0
    return ps_dict_find(d, key, ref slot) >= 0

def ps_dict_del(d: *PsDict, key: const *char) -> bool:
    slot: i64 = 0
    e: i64 = ps_dict_find(d, key, ref slot)
    if e < 0:
        return False
    # the slot becomes DEAD so the probe chain stays walkable, and the entry
    # becomes dead so iteration skips it. The entry's room comes back at the
    # next rebuild and not before — its key may still be somebody's reference
    # until the collector says otherwise.
    ps_idx_set(d, slot, PS_IDX_DEAD)
    ps_arr_data(d->state)[e] = 0
    d->n -= 1
    return True

# ---------- iteration, which is where the order lives ----------
# `nent` is the high water of the DENSE array, so walking 0..nent and skipping
# what is dead visits the keys in the order they were inserted. That is the whole
# implementation of the guarantee.
def ps_dict_nent(d: *PsDict) -> i64:
    return d->nent

def ps_dict_live(d: *PsDict, i: i64) -> bool:
    return ps_arr_data(d->state)[i] == 1

def ps_dict_key_at(d: *PsDict, i: i64) -> *char:
    return ps_arr_data(d->keys) + usize(i) * usize(d->ksize)

def ps_dict_val_at(d: *PsDict, i: i64) -> *char:
    return ps_arr_data(d->vals) + usize(i) * usize(d->vsize)

# `d.keys()` and `d.values()` (61.4). A fresh LIST, in insertion order — a copy
# and not a view, because 17.3 says a slice copies and a view into a dict that
# moves would be an interior pointer into a moving object (the whole class of
# bug the stress mode exists to find).
#
# The element size and whether it is a reference come from the dict itself, so
# the lowering does not have to say them twice.
# ---------- 104: os operadores de conjunto ----------
#
# `|`, `&`, `-` e `^` entre sets, como no Python: um set NOVO, e a ordem do
# resultado é a de inserção (91.1) — primeiro o que veio do lado esquerdo, na
# ordem dele, depois o do direito. Python não promete ordem em set, mas ter uma
# ordem definida é melhor do que ter uma que depende do hash.
private def ps_set_add_all(ctx: *PsCtx, out: *PsDict, d: *PsDict, only_in: *PsDict, want: bool):
    if d == None:
        return
    i: i64 = 0
    while i < ps_dict_nent(d):
        if ps_dict_live(d, i):
            kp: *char = ps_dict_key_at(d, i)
            if only_in == None or ps_dict_has(only_in, kp) == want:
                ps_dict_put(ctx, out, kp)
        i += 1

def ps_set_op(ctx: *PsCtx, a: *PsDict, b: *PsDict, op: i32) -> *PsDict:
    out: *PsDict = ps_dict_new(ctx, a->ksize, a->vsize, a->kkind, a->kref, a->vref)
    if op == 0:
        # união
        ps_set_add_all(ctx, out, a, None, False)
        ps_set_add_all(ctx, out, b, None, False)
    elif op == 1:
        # interseção: os de A que estão em B
        ps_set_add_all(ctx, out, a, b, True)
    elif op == 2:
        # diferença: os de A que NÃO estão em B
        ps_set_add_all(ctx, out, a, b, False)
    else:
        # diferença simétrica: os que estão num só dos dois
        ps_set_add_all(ctx, out, a, b, False)
        ps_set_add_all(ctx, out, b, a, False)
    return out

# `<=` é subconjunto e `>=` é superconjunto, os nomes que o Python usa nos
# operadores. `<` e `>` são os próprios, ESTRITOS.
def ps_set_subset(a: *PsDict, b: *PsDict, strict: bool) -> bool:
    if a == None:
        return True
    if b == None:
        return a->n == 0
    if a->n > b->n or (strict and a->n == b->n):
        return False
    i: i64 = 0
    while i < ps_dict_nent(a):
        if ps_dict_live(a, i):
            if not ps_dict_has(b, ps_dict_key_at(a, i)):
                return False
        i += 1
    return True

# ---------- 104: `clear`, `copy` e `update` de dict/set ----------
def ps_dict_clear(d: *PsDict):
    if d == None:
        return
    d->nent = 0
    d->n = 0
    # a tabela de índices volta a VAZIA inteira, que é o estado em que ela nasce
    # — zero é um número de entrada perfeitamente válido, então cada slot tem de
    # ser escrito de propósito
    k: i64 = 0
    while k < d->cap:
        ps_idx_set(d, k, PS_IDX_EMPTY)
        k += 1

# Uma cópia RASA, como a do Python: as chaves e os valores são os mesmos bytes,
# então dois dicts passam a apontar para os mesmos objetos. O que não é
# compartilhado é a tabela — pôr no novo não mexe no velho.
def ps_dict_copy(ctx: *PsCtx, d: *PsDict) -> *PsDict:
    if d == None:
        return None
    out: *PsDict = ps_dict_new(ctx, d->ksize, d->vsize, d->kkind, d->kref, d->vref)
    out->vtrace = d->vtrace
    i: i64 = 0
    while i < ps_dict_nent(d):
        if ps_dict_live(d, i):
            kp: *char = ps_dict_key_at(d, i)
            slot: *char = ps_dict_put(ctx, out, kp)
            if d->vsize > 0:
                memcpy(slot, ps_dict_val_at(d, i), usize(d->vsize))
        i += 1
    return out

# `a.update(b)`: as chaves de b entram em a, e as que já existem são
# SOBRESCRITAS — a ordem de inserção de uma chave que já estava não muda (91.1),
# porque `ps_dict_put` devolve o slot que já existia.
def ps_dict_update(ctx: *PsCtx, a: *PsDict, b: *PsDict):
    if a == None or b == None or a == b:
        return
    i: i64 = 0
    while i < ps_dict_nent(b):
        if ps_dict_live(b, i):
            slot: *char = ps_dict_put(ctx, a, ps_dict_key_at(b, i))
            if b->vsize > 0 and a->vsize > 0:
                memcpy(slot, ps_dict_val_at(b, i), usize(b->vsize))
        i += 1

def ps_dict_keys(ctx: *PsCtx, d: *PsDict) -> *PsList:
    out: *PsList = ps_list_new(ctx, d->ksize, d->kref, d->n)
    i: i64 = 0
    while i < d->nent:
        if ps_dict_live(d, i):
            memcpy(ps_list_push(ctx, out), ps_dict_key_at(d, i), usize(d->ksize))
        i += 1
    return out

def ps_dict_values(ctx: *PsCtx, d: *PsDict) -> *PsList:
    out: *PsList = ps_list_new(ctx, d->vsize, d->vref, d->n)
    i: i64 = 0
    while i < d->nent:
        if ps_dict_live(d, i):
            memcpy(ps_list_push(ctx, out), ps_dict_val_at(d, i), usize(d->vsize))
        i += 1
    return out


# ---------- strings ----------
# counts codepoints in UTF-8: every byte that is not a continuation starts one
private def ps_utf8_count(b: const *char, n: usize) -> u32:
    c: u32 = 0
    for i in range(n):
        if (u8(b[i]) & 0xC0) != 0x80:
            c += 1
    return c

# 83.2: bytes that come from the outside are CHECKED before they become a
# `str`, because a `str` promises codepoints — `len()` counts them and `s[i]`
# is one. A string that lies about that is worse than an error.
def ps_utf8_valid(b: const *char, n: usize) -> bool:
    i: usize = 0
    while i < n:
        c: u8 = u8(b[i])
        need: i32 = 0
        lo: u32 = 0
        cp: u32 = 0
        if c < 0x80:
            i += 1
            continue
        elif (c & 0xE0) == 0xC0:
            need = 1
            cp = u32(c & 0x1F)
            lo = 0x80
        elif (c & 0xF0) == 0xE0:
            need = 2
            cp = u32(c & 0x0F)
            lo = 0x800
        elif (c & 0xF8) == 0xF0:
            need = 3
            cp = u32(c & 0x07)
            lo = 0x10000
        else:
            return False
        if i + usize(need) >= n + usize(0) and i + usize(need) > n - 1:
            return False
        for k in range(need):
            cc: u8 = u8(b[i + usize(k) + 1])
            if (cc & 0xC0) != 0x80:
                return False
            cp = (cp << 6) | u32(cc & 0x3F)
        if cp < lo or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
            return False
        i += usize(need) + 1
    return True

# 80.1b — indexing in O(1).
#
# The decision asked for PEP 393's adaptive width (latin-1/UCS-2/UCS-4 per
# string). Implementing that LITERALLY here would cost in a way that only
# became visible once the rest existed: everything in this system wants the
# UTF-8 bytes — the socket, the file, the message between heaps, the boundary
# with P (84.1), `print`. With the text held as UCS-4, every one of those
# crossings would have to MATERIALIZE the UTF-8, which is exactly why PEP 393
# keeps BOTH forms. The real price would be two copies of every string that
# crosses anything.
#
# What is here reaches the same observable property — `s[i]` and slicing in
# O(1) — with a single copy:
#
#   * ASCII (the overwhelming majority, and ALL protocol text) needs nothing:
#     `nchars == len` IS the proof that every byte is one character, so the
#     index is a direct access. That proof was in the header all along — it
#     just had never been read as one;
#   * everything else gets an OFFSET INDEX, built the first time someone
#     indexes that string and kept in it. O(n) once, O(1) from then on, and
#     nothing at all for a string nobody indexes.
#
# A `str` is immutable (31.3), so the index never has to be invalidated.
private def ps_str_ascii(s: *PsStr) -> bool:
    return s->nchars == s->len

# the index, built on demand and kept in the string itself
private def ps_str_index(ctx: *PsCtx, s: *PsStr) -> *PsArr:
    if s->offs != None:
        return s->offs
    n: usize = usize(s->len)
    cnt: usize = usize(s->nchars)
    a: *PsArr = (*PsArr)(ps_alloc(ctx, sizeof(PsArr) + (cnt + 1) * sizeof(u32), PS_TY_ARR))
    a->nbytes = (cnt + 1) * sizeof(u32)
    off: *u32 = (*u32)((*char)(a) + sizeof(PsArr))
    k: usize = 0
    i: usize = 0
    while i < n:
        if (u8(s->data[i]) & 0xC0) != 0x80:
            off[k] = u32(i)
            k += 1
        i += 1
    off[cnt] = u32(n)
    s->offs = a
    return a

# byte offset of codepoint `k`, or `n` when k is past the end
private def ps_utf8_off(b: const *char, n: usize, k: i64) -> usize:
    seen: i64 = 0
    for i in range(n):
        if (u8(b[i]) & 0xC0) != 0x80:
            if seen == k:
                return usize(i)
            seen += 1
    return n

def ps_str_new(ctx: *PsCtx, bytes: const *char, len: usize) -> *PsStr:
    s: *PsStr = ps_alloc(ctx, sizeof(PsStr) + len + 1, PS_TY_STR)
    s->len = u32(len)
    s->hash = 0
    if len > 0:
        memcpy(s->data, bytes, len)
    s->data[len] = '\0'
    s->nchars = ps_utf8_count(s->data, len)
    s->offs = None
    return s

# 79.1/83.2: bytes become text HERE, and only if they really are text. A `str`
# promises codepoints — `len()` counts them and `s[i]` is one — so a string
# built out of invalid UTF-8 would be a string that lies about itself.
def ps_str_from_bytes(ctx: *PsCtx, l: *PsList, file: const *char, line: i32) -> *PsStr:
    n: usize = usize(l->len) if l != None else usize(0)
    p: const *char = ps_list_base(l) if n > 0 else ""
    if not ps_utf8_valid(p, n):
        ps_raise(ctx, "these bytes are not valid UTF-8: keep them as bytes, or decode them yourself", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    return ps_str_new(ctx, p, n)

# 81.4/83.2: text COMING FROM the P side. The bytes are copied on arrival — the
# memory is theirs and the collector does not track it — and CHECKED, because a
# `str` promises codepoints and one that lied about that would be worse than an
# error.
def ps_str_checked(ctx: *PsCtx, p: const *char, n: usize, file: const *char, line: i32) -> *PsStr:
    if p == None:
        return ps_str_new(ctx, "", 0)
    if not ps_utf8_valid(p, n):
        ps_raise(ctx, "this text is not valid UTF-8 (it came from the other side of the boundary)", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    return ps_str_new(ctx, p, n)

# ... and raw bytes, which promise nothing and so are not checked. It builds a
# `List<u8>`, which is what its name now says: with a real `bytes` type in the
# language (135), `ps_bytes_new` is the constructor of THAT, and two functions
# with one name reading two different types was an accident waiting.
def ps_list_of_raw(ctx: *PsCtx, p: const *u8, n: usize) -> *PsList:
    l: *PsList = ps_list_new(ctx, 1, False, i64(n))
    i: usize = 0
    while i < n:
        dst: *char = ps_list_push(ctx, l)
        *dst = char(p[i])
        i += 1
    return l

def ps_str_concat(ctx: *PsCtx, a: *PsStr, b: *PsStr) -> *PsStr:
    n: usize = usize(a->len) + usize(b->len)
    s: *PsStr = ps_alloc(ctx, sizeof(PsStr) + n + 1, PS_TY_STR)
    s->len = u32(n)
    # CHARACTERS too (3.4): `len()` is O(1) because every constructor sets this,
    # and concatenation is the one that used to forget — a joined string
    # reported length 0 while printing perfectly.
    s->nchars = a->nchars + b->nchars
    s->hash = 0
    memcpy(s->data, a->data, usize(a->len))
    memcpy(s->data + a->len, b->data, usize(b->len))
    s->data[n] = '\0'
    s->offs = None
    return s

# The digits by hand rather than snprintf: `%lld` versus `%ld` for an i64 is a
# portability question with no good answer in a header meant to compile
# anywhere, and a runtime that warns is a runtime nobody trusts. Works in the
# NEGATIVES so that the most negative integer, which has no positive
# counterpart, needs no special case.
def ps_str_from_int(ctx: *PsCtx, v: i64) -> *PsStr:
    buf: char[24]
    i: i32 = 24
    neg: bool = v < 0
    n: i64 = v if neg else -v
    do:
        i -= 1
        buf[i] = char(i32('0') - i32(n % 10))
        n /= 10
    while n != 0
    if neg:
        i -= 1
        buf[i] = '-'
    return ps_str_new(ctx, buf + i, usize(24 - i))

# Python's repr: the SHORTEST form that reads back as the same double. Tries 15,
# then 16, then 17 significant digits and keeps the first that round-trips — the
# standard recipe, and the reason `0.1 + 0.2` prints all its digits instead of a
# tidy lie. A result with no '.', 'e', 'inf' or 'nan' in it gets a ".0", because
# a float that prints as `2` is indistinguishable from an int.
# ---------- the repr of a container (97) ----------
# `print([1, 2, 3])` shows `[1, 2, 3]`, and a string INSIDE shows with quotes.
# The quotes are the whole reason this is here rather than in the lowering:
# `['a, b']` and `['a', 'b']` print the same without them, and one of the two is
# a lie. WHICH quote follows Python's rule exactly — single, unless the string
# has a single and no double — so an oracle pair can compare the two outputs
# character for character instead of "close enough".
private def ps_repr_esc_len(s: *PsStr, q: char) -> usize:
    n: usize = 2
    i: usize = 0
    while i < usize(s->len):
        c: char = s->data[i]
        if c == '\\' or c == q:
            n += 2
        elif c == '\n' or c == '\r' or c == '\t':
            n += 2
        elif u8(c) < 32 or u8(c) == 127:
            n += 4          # \xNN
        else:
            n += 1
        i += 1
    return n

def ps_str_quoted(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    # Python picks the quote: single, unless that would need escaping and the
    # double would not
    q: char = '\''
    if memchr(s->data, int('\''), usize(s->len)) != None and memchr(s->data, int('"'), usize(s->len)) == None:
        q = '"'
    n: usize = ps_repr_esc_len(s, q)
    out: *PsStr = ps_alloc(ctx, sizeof(PsStr) + n + 1, PS_TY_STR)
    out->len = u32(n)
    out->hash = 0
    out->offs = None
    d: *char = out->data
    k: usize = 0
    d[k] = q
    k += 1
    i: usize = 0
    while i < usize(s->len):
        c: char = s->data[i]
        if c == '\\' or c == q:
            d[k] = '\\'
            d[k + 1] = c
            k += 2
        elif c == '\n':
            d[k] = '\\'
            d[k + 1] = 'n'
            k += 2
        elif c == '\r':
            d[k] = '\\'
            d[k + 1] = 'r'
            k += 2
        elif c == '\t':
            d[k] = '\\'
            d[k + 1] = 't'
            k += 2
        elif u8(c) < 32 or u8(c) == 127:
            snprintf(d + k, usize(5), "\\x%02x", int(u8(c)))
            k += 4
        else:
            d[k] = c
            k += 1
        i += 1
    d[k] = q
    k += 1
    d[k] = '\0'
    # the count of CHARACTERS, which is what `len` promises (3.4). The escapes
    # are ASCII, so what changes is only what was added.
    out->nchars = s->nchars + u32(n - usize(s->len))
    return out

# A growing byte buffer, malloc'd and freed here: the pieces are collected
# strings and joining them with `ps_str_concat` in a loop would be quadratic and
# would allocate a string per element in the heap the collector walks.
struct PsRepr:
    data: *char
    len: usize
    cap: usize

private def ps_repr_put(ref b: PsRepr, p: const *char, n: usize):
    if b.len + n + 1 > b.cap:
        nc: usize = b.cap * 2 if b.cap > 0 else usize(64)
        while nc < b.len + n + 1:
            nc *= 2
        b.data = (*char)(realloc(b.data, nc))
        b.cap = nc
    memcpy(b.data + b.len, p, n)
    b.len += n
    b.data[b.len] = '\0'

private def ps_repr_puts(ref b: PsRepr, s: *PsStr):
    if s != None:
        ps_repr_put(ref b, s->data, usize(s->len))

# THE CEILING (97.2). A cycle is reachable — `o.pai` is the normal case here, and
# a struct whose field is a list of itself closes the loop through a container.
# The static expansion of a record's fields stops at depth 3 on its own; this is
# the other door, and it is counted in the CONTEXT because the adapter that
# recurses is a function the compiler emitted, not a parameter it can thread.
# 110: a profundidade que o `repr` desce antes de escrever `...`
# (`-D PSRT_REPR_MAX=N`).
const if defined(PSRT_REPR_MAX):
    PS_REPR_MAX: const i32 = PSRT_REPR_MAX
else:
    PS_REPR_MAX: const i32 = 8

def ps_repr_seq(ctx: *PsCtx, l: *PsList, open: const *char, close: const *char, fn: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr, env: *void) -> *PsStr:
    if ctx->repr_depth >= PS_REPR_MAX:
        return ps_str_new(ctx, "...", usize(3))
    ctx->repr_depth += 1
    defer:
        ctx->repr_depth -= 1
    b: PsRepr = {None, 0, 0}
    ps_repr_put(ref b, open, strlen(open))
    base: *char = (*char)(l->data) + sizeof(PsArr) if l->data != None else None
    es: usize = usize(l->esize)
    i: i64 = 0
    while i < l->len:
        if i > 0:
            ps_repr_put(ref b, ", ", usize(2))
        ps_repr_puts(ref b, fn(env, ctx, (*void)(base + usize(i) * es)))
        if ctx->exc != None:
            break
        i += 1
    ps_repr_put(ref b, close, strlen(close))
    out: *PsStr = ps_str_new(ctx, b.data if b.data != None else "", b.len)
    free(b.data)
    return out

# `{k: v, ...}` for a dict and `{a, b}` for a set — and the two empty cases are
# not symmetric, because Python's are not: `{}` is the empty DICT and the empty
# set is `set()`, which is the only spelling that reads back as itself.
def ps_repr_dict(ctx: *PsCtx, d: *PsDict, kfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr, vfn: def(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr, env: *void) -> *PsStr:
    if vfn == None and d->n == 0:
        return ps_str_new(ctx, "set()", usize(5))
    if ctx->repr_depth >= PS_REPR_MAX:
        return ps_str_new(ctx, "...", usize(3))
    ctx->repr_depth += 1
    defer:
        ctx->repr_depth -= 1
    b: PsRepr = {None, 0, 0}
    ps_repr_put(ref b, "{", usize(1))
    first: bool = True
    i: i64 = 0
    while i < d->nent:
        if ps_dict_live(d, i):
            if not first:
                ps_repr_put(ref b, ", ", usize(2))
            first = False
            ps_repr_puts(ref b, kfn(env, ctx, (*void)(ps_dict_key_at(d, i))))
            if vfn != None:
                ps_repr_put(ref b, ": ", usize(2))
                ps_repr_puts(ref b, vfn(env, ctx, (*void)(ps_dict_val_at(d, i))))
            if ctx->exc != None:
                break
        i += 1
    ps_repr_put(ref b, "}", usize(1))
    out: *PsStr = ps_str_new(ctx, b.data if b.data != None else "", b.len)
    free(b.data)
    return out

def ps_str_from_float(ctx: *PsCtx, v: f64) -> *PsStr:
    buf: char[64]
    n: i32 = 0
    prec: i32 = 15
    while prec <= 17:
        n = snprintf(buf, 64, "%.*g", prec, v)
        if strtod(buf, None) == v:
            break
        prec += 1
    if strpbrk(buf, ".eEni") == None:
        buf[n] = '.'
        buf[n + 1] = '0'
        n += 2
        buf[n] = '\0'
    return ps_str_new(ctx, buf, usize(n))

def ps_str_from_bool(ctx: *PsCtx, v: bool) -> *PsStr:
    return ps_str_new(ctx, "True" if v else "False", usize(4 if v else 5))

# negative, zero or positive — C's convention, which is what the neighbourhood
# already speaks (and what `sorted` compares with)
def ps_str_nbytes(s: *PsStr) -> i64:
    return i64(s->len) if s != None else 0

def ps_str_step(ctx: *PsCtx, s: *PsStr, off: *i64) -> *PsStr:
    if s == None or *off >= i64(s->len):
        return ps_str_new(ctx, "", 0)
    a: usize = usize(*off)
    n: usize = 1
    c: u8 = u8(s->data[a])
    if (c & 0xF8) == 0xF0:
        n = 4
    elif (c & 0xF0) == 0xE0:
        n = 3
    elif (c & 0xE0) == 0xC0:
        n = 2
    if a + n > usize(s->len):
        n = usize(s->len) - a          # truncated tail: hand back what is there
    *off = i64(a + n)
    return ps_str_new(ctx, s->data + a, n)

def ps_str_has(hay: *PsStr, needle: *PsStr) -> bool:
    if hay == None or needle == None:
        return False
    n: usize = usize(needle->len)
    if n == usize(0):
        return True
    if n > usize(hay->len):
        return False
    limit: usize = usize(hay->len) - n
    i: usize = 0
    while i <= limit:
        if memcmp(hay->data + i, needle->data, n) == 0:
            return True
        i += 1
    return False

def ps_str_lt(a: *PsStr, b: *PsStr) -> i32:
    if a == None or b == None:
        return 0
    na: usize = usize(a->len)
    nb: usize = usize(b->len)
    n: usize = na if na < nb else nb
    r: int = memcmp(a->data, b->data, n)
    if r != 0:
        return -1 if r < 0 else 1
    if na == nb:
        return 0
    return -1 if na < nb else 1

def ps_str_eq(a: *PsStr, b: *PsStr) -> bool:
    if a == b:
        return True
    if a->len != b->len:
        return False
    return memcmp(a->data, b->data, usize(a->len)) == 0

def ps_str_cstr(s: *PsStr) -> const *char:
    return s->data if s != None else ""

def ps_str_len(ctx: *PsCtx, s: *PsStr) -> i64:
    # CHARACTERS, as 3.4 asks — counted once at creation, so this is O(1)
    return i64(s->nchars)

def ps_str_at(ctx: *PsCtx, s: *PsStr, i: i64, file: const *char, line: i32) -> *PsStr:
    k: i64 = i + i64(s->nchars) if i < 0 else i
    if k < 0 or k >= i64(s->nchars):
        ps_raise(ctx, "string index out of range", PS_CAT_INDEX, file, line)
        return ps_str_new(ctx, "", 0)
    if ps_str_ascii(s):
        return ps_str_new(ctx, s->data + usize(k), usize(1))
    idx: *PsArr = ps_str_index(ctx, s)
    off: *u32 = (*u32)((*char)(idx) + sizeof(PsArr))
    a: usize = usize(off[k])
    b: usize = usize(off[k + 1])
    return ps_str_new(ctx, s->data + a, b - a)

def ps_str_ord(ctx: *PsCtx, s: *PsStr, file: const *char, line: i32) -> i64:
    if s == None or s->nchars != 1:
        ps_raise(ctx, "ord() takes a string of exactly one character", PS_CAT_VALUE, file, line)
        return 0
    b: *u8 = (*u8)(s->data)
    c: u32 = u32(b[0])
    if c < 0x80:
        return i64(c)
    if (c & 0xE0) == 0xC0:
        return i64(((c & 0x1F) << 6) | (u32(b[1]) & 0x3F))
    if (c & 0xF0) == 0xE0:
        return i64(((c & 0x0F) << 12) | ((u32(b[1]) & 0x3F) << 6) | (u32(b[2]) & 0x3F))
    return i64(((c & 0x07) << 18) | ((u32(b[1]) & 0x3F) << 12) | ((u32(b[2]) & 0x3F) << 6) | (u32(b[3]) & 0x3F))

def ps_str_chr(ctx: *PsCtx, cp: i64, file: const *char, line: i32) -> *PsStr:
    if cp < 0 or cp > 1114111:
        ps_raise(ctx, "chr() takes a codepoint between 0 and 0x10FFFF", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    b: char[5]
    # the encoder lives in ONE place (`ps_utf8_put`); this is that plus a string
    n: usize = ps_utf8_put(&b[0], usize(0), i32(cp))
    return ps_str_new(ctx, &b[0], n)

def ps_str_slice(ctx: *PsCtx, s: *PsStr, a: i64, b: i64, st: i64, has_a: bool, has_b: bool, file: const *char, line: i32) -> *PsStr:
    n: i64 = i64(s->nchars)
    lo: i64 = 0
    hi: i64 = 0
    # the bounds are Python's, and they are resolved by the same code the list
    # uses — the two have to answer identically (see ps_slice_bounds)
    if not ps_slice_bounds(ctx, n, a, b, st, has_a, has_b, out lo, out hi, file, line):
        return ps_str_new(ctx, "", 0)
    if st == 1:
        # the common case: a contiguous run, which is one copy
        if lo >= hi:
            return ps_str_new(ctx, "", 0)
        if ps_str_ascii(s):
            return ps_str_new(ctx, s->data + usize(lo), usize(hi - lo))
        idx: *PsArr = ps_str_index(ctx, s)
        off: *u32 = (*u32)((*char)(idx) + sizeof(PsArr))
        ba: usize = usize(off[lo])
        bb: usize = usize(off[hi])
        return ps_str_new(ctx, s->data + ba, bb - ba)
    # a STEP means the characters are not contiguous, so they are copied one at
    # a time — and by character, not by byte, which is what makes `s[::-1]` on
    # text with an accent in it come out as text and not as broken UTF-8
    buf: *char = (*char)(malloc(usize(s->len) + usize(4)))
    k: usize = 0
    ascii: bool = ps_str_ascii(s)
    ix: *PsArr = None
    of: *u32 = None
    if not ascii:
        ix = ps_str_index(ctx, s)
        of = (*u32)((*char)(ix) + sizeof(PsArr))
    q: i64 = lo
    while (st > 0 and q < hi) or (st < 0 and q > hi):
        if ascii:
            buf[k] = s->data[usize(q)]
            k += 1
        else:
            ba2: usize = usize(of[q])
            bb2: usize = usize(of[q + 1])
            memcpy(buf + k, s->data + ba2, bb2 - ba2)
            k += bb2 - ba2
        q += st
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

def ps_str_find(ctx: *PsCtx, s: *PsStr, needle: *PsStr) -> i64:
    if needle->len == 0:
        return 0
    if needle->len > s->len:
        return -1
    chars: i64 = 0
    for i in range(usize(s->len) - usize(needle->len) + 1):
        if (u8(s->data[i]) & 0xC0) != 0x80:
            if memcmp(s->data + i, needle->data, usize(needle->len)) == 0:
                return chars
            chars += 1
    return -1

# `uc_decode` mora com a tabela de caixa, mais abaixo; as funções daqui
# precisam dele para andar de carácter em carácter
private def uc_decode(s: *PsStr, at: usize, ref w: usize) -> i32

# ---------- 104: o resto dos métodos de str ----------
#
# Todo índice que sai daqui é de CARÁCTER, não de byte, porque é o que `s[i]`
# indexa e o que `len` conta (3.4) — a busca acha em bytes e conta caracteres
# pelo caminho, que é o que `ps_str_find` já fazia.
def ps_str_count(s: *PsStr, needle: *PsStr) -> i64:
    if needle->len == 0:
        # o Python conta as POSIÇÕES entre caracteres, que são len+1
        return ps_str_nchars(s) + 1
    if needle->len > s->len:
        return 0
    n: i64 = 0
    i: usize = 0
    while i + usize(needle->len) <= usize(s->len):
        if memcmp(s->data + i, needle->data, usize(needle->len)) == 0:
            n += 1
            # NÃO sobrepostas, como no Python: "aaa".count("aa") é 1
            i += usize(needle->len)
        else:
            i += 1
    return n

# quantos CARACTERES tem
def ps_str_nchars(s: *PsStr) -> i64:
    # o número de caracteres já está no objeto, contado uma vez na criação (3.4)
    return i64(s->nchars)

def ps_str_rfind(s: *PsStr, needle: *PsStr) -> i64:
    if needle->len == 0:
        return ps_str_nchars(s)
    if needle->len > s->len:
        return -1
    best: i64 = -1
    chars: i64 = 0
    for i in range(usize(s->len) - usize(needle->len) + 1):
        if (u8(s->data[i]) & 0xC0) != 0x80:
            if memcmp(s->data + i, needle->data, usize(needle->len)) == 0:
                best = chars
            chars += 1
    return best

# `find` a partir de um começo, contado em CARACTERES (o `find(sub, start)` do
# Python). Um começo negativo conta do fim, como uma fatia.
def ps_str_find_from(ctx: *PsCtx, s: *PsStr, needle: *PsStr, start: i64) -> i64:
    nch: i64 = ps_str_nchars(s)
    st: i64 = start + nch if start < 0 else start
    if st < 0:
        st = 0
    if st > nch:
        return -1 if needle->len > 0 else nch
    # onde esse carácter começa, em bytes
    boff: usize = usize(s->len)
    seen: i64 = 0
    for i in range(usize(s->len)):
        if (u8(s->data[i]) & 0xC0) != 0x80:
            if seen == st:
                boff = i
                break
            seen += 1
    if st == nch:
        boff = usize(s->len)
    if needle->len == 0:
        return st
    if usize(needle->len) > usize(s->len) - boff:
        return -1
    chars: i64 = st
    i2: usize = boff
    while i2 + usize(needle->len) <= usize(s->len):
        if (u8(s->data[i2]) & 0xC0) != 0x80:
            if memcmp(s->data + i2, needle->data, usize(needle->len)) == 0:
                return chars
            chars += 1
        i2 += 1
    return -1

def ps_str_index_of(ctx: *PsCtx, s: *PsStr, needle: *PsStr, from_right: bool, file: const *char, line: i32) -> i64:
    i: i64 = ps_str_rfind(s, needle) if from_right else ps_str_find(ctx, s, needle)
    if i < 0:
        ps_raise(ctx, "substring not found", PS_CAT_VALUE, file, line)
        return 0
    return i

# O espaço em branco do Python, que é um conjunto FECHADO de 29 pontos de código
# (`str.isspace()` para todo o intervalo, conferido contra o Python 3 / Unicode
# 15). Está aqui à mão em vez de numa tabela gerada porque 29 pontos em 8 faixas
# não justificam uma tabela — e o oráculo compara os dois de qualquer forma.
def ps_str_is_space_cp(cp: i32) -> bool:
    if cp == 0x20 or (cp >= 0x09 and cp <= 0x0D) or (cp >= 0x1C and cp <= 0x1F):
        return True
    if cp == 0x85 or cp == 0xA0 or cp == 0x1680:
        return True
    if cp >= 0x2000 and cp <= 0x200A:
        return True
    if cp == 0x2028 or cp == 0x2029 or cp == 0x202F or cp == 0x205F or cp == 0x3000:
        return True
    return False

# `split()` SEM separador: parte em CORRIDAS de espaço, e não devolve pedaço
# vazio nenhum — nem no começo nem no fim. É outra função e não o `split(sep)`
# com um espaço porque o resultado é diferente: `" a  b ".split()` dá dois
# pedaços e `" a  b ".split(" ")` dá cinco.
def ps_str_split_ws(ctx: *PsCtx, s: *PsStr) -> *PsList:
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, 0)
    i: usize = 0
    n: usize = usize(s->len)
    while i < n:
        w: usize = 1
        cp: i32 = uc_decode(s, i, ref w)
        if ps_str_is_space_cp(cp):
            i += w
            continue
        st: usize = i
        while i < n:
            w2: usize = 1
            cp2: i32 = uc_decode(s, i, ref w2)
            if ps_str_is_space_cp(cp2):
                break
            i += w2
        piece: *PsStr = ps_str_new(ctx, s->data + st, i - st)
        *(**PsStr)(ps_list_push(ctx, out)) = piece
    return out

# `splitlines()`: as fronteiras de linha do Python, que são MAIS do que `\n` —
# `\r`, `\r\n`, e os separadores que o Unicode define. O terminador não vem no
# pedaço, e um terminador final NÃO produz um pedaço vazio.
private def ps_line_break(cp: i32) -> bool:
    if cp == 0x0A or cp == 0x0B or cp == 0x0C or cp == 0x0D or cp == 0x1C or cp == 0x1D or cp == 0x1E:
        return True
    return cp == 0x85 or cp == 0x2028 or cp == 0x2029

def ps_str_splitlines(ctx: *PsCtx, s: *PsStr) -> *PsList:
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, 0)
    i: usize = 0
    n: usize = usize(s->len)
    st: usize = 0
    while i < n:
        w: usize = 1
        cp: i32 = uc_decode(s, i, ref w)
        if ps_line_break(cp):
            *(**PsStr)(ps_list_push(ctx, out)) = ps_str_new(ctx, s->data + st, i - st)
            i += w
            if cp == 0x0D and i < n and s->data[i] == '\n':
                i += 1
            st = i
        else:
            i += w
    if st < n:
        *(**PsStr)(ps_list_push(ctx, out)) = ps_str_new(ctx, s->data + st, n - st)
    return out

def ps_str_removeaffix(ctx: *PsCtx, s: *PsStr, p: *PsStr, suffix: bool) -> *PsStr:
    if p->len == 0 or p->len > s->len:
        return s
    if suffix:
        if memcmp(s->data + usize(s->len) - usize(p->len), p->data, usize(p->len)) != 0:
            return s
        return ps_str_new(ctx, s->data, usize(s->len) - usize(p->len))
    if memcmp(s->data, p->data, usize(p->len)) != 0:
        return s
    return ps_str_new(ctx, s->data + usize(p->len), usize(s->len) - usize(p->len))

# `strip(chars)`: tira qualquer um dos CARACTERES do conjunto, das duas pontas —
# não é um prefixo. mode 0 as duas, 1 só à esquerda, 2 só à direita.
private def ps_chars_has(set: *PsStr, cp: i32) -> bool:
    i: usize = 0
    while i < usize(set->len):
        w: usize = 1
        c: i32 = uc_decode(set, i, ref w)
        if c == cp:
            return True
        i += w
    return False

def ps_str_strip_chars(ctx: *PsCtx, s: *PsStr, set: *PsStr, mode: i32) -> *PsStr:
    a: usize = 0
    b: usize = usize(s->len)
    if mode != 2:
        while a < b:
            w: usize = 1
            cp: i32 = uc_decode(s, a, ref w)
            if not ps_chars_has(set, cp):
                break
            a += w
    if mode != 1:
        while b > a:
            # anda para trás até o começo do último carácter
            e: usize = b - usize(1)
            while e > a and (u8(s->data[e]) & 0xC0) == 0x80:
                e -= usize(1)
            w2: usize = 1
            cp2: i32 = uc_decode(s, e, ref w2)
            if not ps_chars_has(set, cp2):
                break
            b = e
    return ps_str_new(ctx, s->data + a, b - a)

# `ljust`, `rjust`, `center` e `zfill`: a largura conta CARACTERES, e o
# preenchimento é um carácter. mode 0 esquerda (ljust), 1 direita (rjust),
# 2 centro. No centro o Python põe a sobra à DIREITA.
def ps_str_pad(ctx: *PsCtx, s: *PsStr, width: i64, fill: *PsStr, mode: i32, file: const *char, line: i32) -> *PsStr:
    if fill->len == 0 or ps_str_nchars(fill) != 1:
        ps_raise(ctx, "the fill has to be exactly one character", PS_CAT_VALUE, file, line)
        return s
    have: i64 = ps_str_nchars(s)
    if width <= have:
        return s
    total: i64 = width - have
    left: i64 = 0
    if mode == 1:
        left = total
    elif mode == 2:
        # A regra do `center` do CPython, com o termo de correção e tudo:
        # `left = marg // 2 + (marg & width & 1)`. Metade para cada lado deixa
        # a sobra à direita, mas quando a folga E a largura são ímpares o
        # Python a joga para a ESQUERDA — `"hi".center(7, "*")` é `***hi**`.
        # Sem esse termo o resultado difere em metade dos casos ímpares.
        left = total / 2 + (total & width & 1)
    right: i64 = total - left
    fl: usize = usize(fill->len)
    nb: usize = usize(s->len) + usize(left + right) * fl
    buf: *char = (*char)(malloc(nb + usize(1)))
    k: usize = 0
    for i in range(left):
        memcpy(buf + k, fill->data, fl)
        k += fl
    memcpy(buf + k, s->data, usize(s->len))
    k += usize(s->len)
    for i in range(right):
        memcpy(buf + k, fill->data, fl)
        k += fl
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

# `zfill`: zeros à esquerda, mas o SINAL fica na frente deles — `"-42".zfill(5)`
# é `"-0042"` e não `"00-42"`
def ps_str_zfill(ctx: *PsCtx, s: *PsStr, width: i64) -> *PsStr:
    have: i64 = ps_str_nchars(s)
    if width <= have:
        return s
    pad: i64 = width - have
    has_sign: bool = s->len > 0 and (s->data[0] == '+' or s->data[0] == '-')
    nb: usize = usize(s->len) + usize(pad)
    buf: *char = (*char)(malloc(nb + usize(1)))
    k: usize = 0
    if has_sign:
        buf[0] = s->data[0]
        k = 1
    for i in range(pad):
        buf[k] = '0'
        k += 1
    memcpy(buf + k, s->data + (usize(1) if has_sign else usize(0)), usize(s->len) - (usize(1) if has_sign else usize(0)))
    k += usize(s->len) - (usize(1) if has_sign else usize(0))
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

def ps_str_contains(s: *PsStr, needle: *PsStr) -> bool:
    if needle->len == 0:
        return True
    if needle->len > s->len:
        return False
    for i in range(usize(s->len) - usize(needle->len) + 1):
        if memcmp(s->data + i, needle->data, usize(needle->len)) == 0:
            return True
    return False

# ASCII, and said out loud: case in Unicode depends on LANGUAGE (Turkish's
# dotless i is the classic example), and a `lower()` that pretended to know
# better would be lying. What HTTP, a header and an identifier need is exactly
# this.
# ---------- case mapping (Unicode default, table-driven) ----------
#
# Case mapping is a TABLE, not an algorithm: `é` uppercases by an offset, `ß`
# uppercases to `SS` — two characters — and no rule produces either. The table
# is generated by `tools/gen_unicode_case.py` from the Unicode DEFAULT mappings
# and embedded at compile time (63.1), so it costs 17 KB of read-only data and
# nothing at run time: there is no initialisation and no allocation, only a
# binary search over the bytes.
#
# Not covered, said here rather than discovered later: the LOCALE-sensitive
# rules (Turkish dotless i, Lithuanian dot above) and the CONDITIONAL ones
# (Greek final sigma, which depends on position in the word). Python's
# `str.upper()` and JavaScript's `toUpperCase()` do not do them either — they
# are what `toLocaleUpperCase` is for — so the two oracles stay honest.
#
# Format, every number big-endian so the reader does not depend on the machine:
# "PSUC", 8 bytes of Unicode version, four counts, then the range tables and the
# one-to-many tables. See the generator for the full layout.
PS_CASE: const u8[] = embed_bytes("unicase.bin")

# os índices de tabela do arquivo da CAIXA, na ordem em que o gerador as escreve
private const UC_UP: const i32 = 0        # faixas de maiúscula
private const UC_UPM: const i32 = 1       # maiúscula de um-para-muitos
private const UC_LO: const i32 = 2
private const UC_LOM: const i32 = 3
private const UC_CASED: const i32 = 4     # Cased
private const UC_IGN: const i32 = 5       # Case_Ignorable


# ---------- 108: UM leitor para as tabelas geradas ----------
#
# Havia dois, quase iguais: um para `unicase.bin` (caixa) e um para
# `unicat.bin` (categorias). Cada um trazia o tamanho de entrada de cada tabela
# CRAVADO numa cadeia de ifs e três buscas binárias quase idênticas — 154 linhas
# entre os dois, e a aritmética de offset dos dois para manter em sincronia à
# mão. Foi onde a bateria 105 quase me pegou.
#
# Agora os dois arquivos se DESCREVEM: depois do cabeçalho vem um diretório com
# (quantas entradas, tamanho da entrada) por tabela, e toda entrada começa com
# `lo` e `hi` — um mapeamento de um-para-muitos repete o ponto de código, então
# `lo == hi`. Com isso o leitor não sabe quantas tabelas existem nem de que
# tamanho: calcula tudo do arquivo, e UMA busca binária serve as quinze.
#
#   magic 4 | versão 8 | ntab u32 | ntab × (count u32, esize u32) | tabelas
private const TB_HDR: const i32 = 4 + 8 + 4     # magic, versão, ntab

private def tb_u32(b: const *u8, off: i32) -> u32:
    return (u32(b[off]) << 24) | (u32(b[off + 1]) << 16) | (u32(b[off + 2]) << 8) | u32(b[off + 3])

private def tb_count(b: const *u8, i: i32) -> i32:
    return i32(tb_u32(b, TB_HDR + i * 8))

private def tb_esize(b: const *u8, i: i32) -> i32:
    return i32(tb_u32(b, TB_HDR + i * 8 + 4))

# onde a tabela `which` começa: o fim do diretório mais o tamanho das anteriores
private def tb_off(b: const *u8, which: i32) -> i32:
    ntab: i32 = i32(tb_u32(b, 4 + 8))
    o: i32 = TB_HDR + ntab * 8
    for i in range(which):
        o += tb_count(b, i) * tb_esize(b, i)
    return o

# a ENTRADA que contém `cp`, ou -1. É a única busca binária do módulo: as faixas,
# os conjuntos e os mapeamentos de um-para-muitos têm todos `lo`/`hi` na frente.
private def tb_find(b: const *u8, which: i32, cp: i32) -> i32:
    base: i32 = tb_off(b, which)
    es: i32 = tb_esize(b, which)
    lo: i32 = 0
    hi: i32 = tb_count(b, which) - 1
    while lo <= hi:
        mid: i32 = (lo + hi) / 2
        off: i32 = base + mid * es
        if cp < i32(tb_u32(b, off)):
            hi = mid - 1
        elif cp > i32(tb_u32(b, off + 4)):
            lo = mid + 1
        else:
            return off
    return -1

# está no conjunto?
private def tb_in(b: const *u8, which: i32, cp: i32) -> bool:
    return tb_find(b, which, cp) >= 0

# o mapeamento de um-para-um da tabela de faixas, ou o próprio ponto de código
private def tb_map(b: const *u8, which: i32, cp: i32) -> i32:
    off: i32 = tb_find(b, which, cp)
    if off < 0:
        return cp
    return cp + i32(tb_u32(b, off + 8))

# o de um-para-muitos: quantos saíram (0 = não está na tabela), escritos em `out`
private def tb_multi(b: const *u8, which: i32, cp: i32, out: *i32) -> i32:
    off: i32 = tb_find(b, which, cp)
    if off < 0:
        return 0
    n: i32 = 0
    for k in range(3):
        v: i32 = i32(tb_u32(b, off + 8 + k * 4))
        if v != 0:
            out[n] = v
            n += 1
    return n

# FINAL SIGMA (Unicode SpecialCasing, the non-locale conditional half): `Σ`
# lowercases to `ς` when a cased letter comes BEFORE it and none comes after,
# with case-ignorable characters in between not counting either way. It is the
# one conditional rule that is not about locale, and Python and JavaScript both
# do it — so it is here.
# one code point at byte offset `at`, and how wide it is. A `str` is valid UTF-8
# by construction (83.2), so there is no error path — a lone byte answers as
# itself, which is what keeps the caller simple.
private def uc_decode(s: *PsStr, at: usize, ref w: usize) -> i32:
    n: usize = usize(s->len)
    c0: u8 = u8(s->data[at])
    if c0 < 0x80:
        w = 1
        return i32(c0)
    if (c0 & 0xE0) == 0xC0 and at + usize(1) < n:
        w = 2
        return i32((u32(c0 & 0x1F) << 6) | (u32(u8(s->data[at + usize(1)])) & 0x3F))
    if (c0 & 0xF0) == 0xE0 and at + usize(2) < n:
        w = 3
        return i32((u32(c0 & 0x0F) << 12) | ((u32(u8(s->data[at + usize(1)])) & 0x3F) << 6) | (u32(u8(s->data[at + usize(2)])) & 0x3F))
    if (c0 & 0xF8) == 0xF0 and at + usize(3) < n:
        w = 4
        return i32((u32(c0 & 0x07) << 18) | ((u32(u8(s->data[at + usize(1)])) & 0x3F) << 12) | ((u32(u8(s->data[at + usize(2)])) & 0x3F) << 6) | (u32(u8(s->data[at + usize(3)])) & 0x3F))
    w = 1
    return i32(c0)

# start of the character before `at`, walking back over continuation bytes
private def uc_prev(s: *PsStr, at: usize) -> usize:
    k: usize = at
    while k > usize(0):
        k -= 1
        if (u8(s->data[k]) & 0xC0) != 0x80:
            return k
    return usize(0)

# Is the `Σ` at byte offset `at` FINAL? Cased before, not cased after, and
# case-ignorable characters on either side are skipped rather than counted.
private def uc_final_sigma(s: *PsStr, at: usize) -> bool:
    # before
    before: bool = False
    k: usize = at
    while k > usize(0):
        k = uc_prev(s, k)
        w: usize = 0
        cp: i32 = uc_decode(s, k, ref w)
        if tb_in(&PS_CASE[0], UC_IGN, cp):
            continue
        before = tb_in(&PS_CASE[0], UC_CASED, cp)
        break
    if not before:
        return False
    # after
    w2: usize = 0
    uc_decode(s, at, ref w2)
    j: usize = at + w2
    while j < usize(s->len):
        w3: usize = 0
        cp2: i32 = uc_decode(s, j, ref w3)
        if tb_in(&PS_CASE[0], UC_IGN, cp2):
            j += w3
            continue
        return not tb_in(&PS_CASE[0], UC_CASED, cp2)
    return True

# `upper` is table 0/1, `lower` is table 2/3. One walk of the string, decoding
# each character, mapping it, and encoding what comes back — which is the only
# shape that works once one character can become three.
private def ps_str_case(ctx: *PsCtx, s: *PsStr, upper: bool) -> *PsStr:
    rng: i32 = UC_UP if upper else UC_LO
    mul: i32 = UC_UPM if upper else UC_LOM
    # three code points out per one in, four bytes each, is the ceiling
    buf: *char = (*char)(malloc(usize(s->len) * usize(12) + usize(4)))
    k: usize = 0
    i: usize = 0
    n: usize = usize(s->len)
    while i < n:
        cp: i32 = 0
        w: usize = 1
        c0: u8 = u8(s->data[i])
        if c0 < 0x80:
            cp = i32(c0)
        elif (c0 & 0xE0) == 0xC0 and i + usize(1) < n:
            cp = i32((u32(c0 & 0x1F) << 6) | (u32(u8(s->data[i + usize(1)])) & 0x3F))
            w = 2
        elif (c0 & 0xF0) == 0xE0 and i + usize(2) < n:
            cp = i32((u32(c0 & 0x0F) << 12) | ((u32(u8(s->data[i + usize(1)])) & 0x3F) << 6) | (u32(u8(s->data[i + usize(2)])) & 0x3F))
            w = 3
        elif (c0 & 0xF8) == 0xF0 and i + usize(3) < n:
            cp = i32((u32(c0 & 0x07) << 18) | ((u32(u8(s->data[i + usize(1)])) & 0x3F) << 12) | ((u32(u8(s->data[i + usize(2)])) & 0x3F) << 6) | (u32(u8(s->data[i + usize(3)])) & 0x3F))
            w = 4
        else:
            # a `str` is valid UTF-8 by construction (83.2), so this cannot
            # happen — and if it ever does, the byte travels through untouched
            # rather than becoming something else
            buf[k] = s->data[i]
            k += 1
            i += 1
            continue
        outs: i32[4]
        cnt: i32 = 0
        if not upper and cp == 0x03A3:
            # `Σ` is the one character whose lowercase depends on WHERE it is
            outs[0] = 0x03C2 if uc_final_sigma(s, i) else 0x03C3
            cnt = 1
        else:
            cnt = tb_multi(&PS_CASE[0], mul, cp, &outs[0])
        if cnt == 0:
            outs[0] = tb_map(&PS_CASE[0], rng, cp)
            cnt = 1
        for q in range(cnt):
            k = ps_utf8_put(buf, k, outs[q])
        i += w
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

# ONE code point, UTF-8, into a buffer. The encoder itself is not written here
# any more: it is `stl/utf8`, which the compiler's lexer reads with and any P
# program can now use. This is the runtime's `i32` shape over it.
#
# There used to be THREE copies in this runtime alone — this one, `ps_str_chr`,
# and a `js_utf8` in the JSON writer whose comment argued that copies were safer
# than sharing because they could not drift. They could: repetition is what MAKES
# drift, and every site writing 0xC0/0xE0/0xF0 by hand is one more chance to
# write one of them wrong — which is what happened out in the packages, where
# three hand-written encoders turned out to be Latin-1 wearing a UTF-8 name.
def ps_utf8_put(buf: *char, k: usize, cp: i32) -> usize:
    return utf8_put(buf, k, u32(cp))

def ps_str_lower(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    return ps_str_case(ctx, s, False)

# ---------- 105: as CATEGORIAS do Unicode, também numa tabela ----------
#
# `isdigit`, `isalpha` e companhia não seguem de regra nenhuma: `"٣"` é dígito
# (três arábico-índico), `"³"` também (sobrescrito), `"三"` é `isnumeric` mas não
# `isdecimal`. É a base de caracteres do Unicode, que muda uma vez por ano — a
# mesma situação da caixa (89), e a mesma solução: uma tabela gerada do Python
# por `tools/gen_unicode_cat.py`, embutida em tempo de compilação (63.1), lida
# por busca binária. 27 KB de dado só-leitura e nada em tempo de execução.
#
# Fazer METADE disso é o que esta tabela existe para impedir: um predicado que
# responde para ASCII e discorda do Python no primeiro dígito não-latino, em
# silêncio, é pior do que um que não existe.
#
# A tabela traz também o mapeamento de TÍTULO, que é um terceiro mapeamento e
# não o de maiúscula: `ǳ` sobe para `Ǳ` e titula para `ǲ`, e `ß` titula para
# `Ss`. É dele que vivem `title()` e `capitalize()`.
PS_CAT: const u8[] = embed_bytes("unicat.bin")

# ... e os do arquivo das CATEGORIAS
private const CA_ALPHA: const i32 = 0
private const CA_DIGIT: const i32 = 1
private const CA_DECIMAL: const i32 = 2
private const CA_NUMERIC: const i32 = 3
private const CA_UPPER: const i32 = 4
private const CA_LOWER: const i32 = 5
# os caracteres de TÍTULO (categoria Lt): `ǅ` e uns trinta outros, que não são
# maiúsculos nem minúsculos. Têm conjunto próprio porque `isupper` tem de
# RECUSÁ-LOS e `istitle` tem de ACEITÁ-LOS — foi a varredura exaustiva do
# oráculo que cobrou isso, e nenhum exemplo escolhido à mão teria cobrado.
private const CA_TITLECHAR: const i32 = 6
private const CA_TIRANGE: const i32 = 7
private const CA_TIMULTI: const i32 = 8


# Os predicados do Python sobre a STRING INTEIRA, com a regra dele: todos os
# caracteres têm de satisfazer, e a string vazia é sempre False (não há
# caractere que sirva de contraexemplo, mas também não há nenhum que sirva de
# exemplo — e o Python escolheu False).
#
# `which` é o conjunto; -1 é `isspace`, que não vem da tabela (são 29 pontos de
# código, e o conjunto está escrito à mão em `ps_str_is_space_cp`); -2 é
# `isalnum`, que o Python define como alpha OU decimal OU digit OU numeric.
def ps_str_all_of(s: *PsStr, which: i32) -> bool:
    if s == None or s->len == 0:
        return False
    i: usize = 0
    n: usize = usize(s->len)
    while i < n:
        w: usize = 1
        cp: i32 = uc_decode(s, i, ref w)
        ok: bool = False
        if which == -1:
            ok = ps_str_is_space_cp(cp)
        elif which == -2:
            ok = tb_in(&PS_CAT[0], CA_ALPHA, cp) or tb_in(&PS_CAT[0], CA_DECIMAL, cp) or tb_in(&PS_CAT[0], CA_DIGIT, cp) or tb_in(&PS_CAT[0], CA_NUMERIC, cp)
        else:
            ok = tb_in(&PS_CAT[0], which, cp)
        if not ok:
            return False
        i += w
    return True

# `isupper` NÃO é "todo caractere é maiúsculo": é "não há minúsculo nem título,
# e há pelo menos um maiúsculo" — `"ABC1"` é True e `"1"` é False. O Python
# define os dois assim, sobre os caracteres COM caixa.
def ps_str_is_case(s: *PsStr, want_upper: bool) -> bool:
    if s == None or s->len == 0:
        return False
    i: usize = 0
    n: usize = usize(s->len)
    seen: bool = False
    while i < n:
        w: usize = 1
        cp: i32 = uc_decode(s, i, ref w)
        # o de TÍTULO nunca serve: nem para `isupper` nem para `islower`
        if tb_in(&PS_CAT[0], CA_TITLECHAR, cp):
            return False
        if tb_in(&PS_CAT[0], CA_LOWER if want_upper else CA_UPPER, cp):
            return False
        if tb_in(&PS_CAT[0], CA_UPPER if want_upper else CA_LOWER, cp):
            seen = True
        i += w
    return seen

# `istitle`: cada palavra começa com maiúscula (ou título) e segue em minúscula.
# A definição do Python é sobre o caractere ANTERIOR ter caixa: depois de um
# caractere com caixa, um maiúsculo é erro; depois de um sem caixa, um minúsculo
# é erro. E precisa de pelo menos um caractere com caixa.
def ps_str_is_title(s: *PsStr) -> bool:
    if s == None or s->len == 0:
        return False
    i: usize = 0
    n: usize = usize(s->len)
    prev_cased: bool = False
    seen: bool = False
    while i < n:
        w: usize = 1
        cp: i32 = uc_decode(s, i, ref w)
        # para o `istitle`, o de TÍTULO conta como maiúsculo (é o que ele é)
        up: bool = tb_in(&PS_CAT[0], CA_UPPER, cp) or tb_in(&PS_CAT[0], CA_TITLECHAR, cp)
        low: bool = tb_in(&PS_CAT[0], CA_LOWER, cp)
        if up:
            if prev_cased:
                return False
            seen = True
        elif low:
            if not prev_cased:
                return False
            seen = True
        prev_cased = up or low or tb_in(&PS_CASE[0], UC_CASED, cp)
        i += w
    return seen

# `title`, `capitalize` e `swapcase` (105). Os três são o MESMO percurso da
# caixa, com uma decisão por caractere:
#
#   title       o primeiro de cada palavra vira TÍTULO, o resto minúscula — e
#               "palavra" é definido pelo caractere anterior ter caixa, que é
#               como o CPython faz (`do_title`), não por espaço
#   capitalize  o primeiro caractere vira título, TODO o resto minúscula
#   swapcase    maiúsculo desce, minúsculo sobe, o resto passa
#
# `mode`: 0 title, 1 capitalize, 2 swapcase.
private def ps_str_recase(ctx: *PsCtx, s: *PsStr, mode: i32) -> *PsStr:
    if s == None or s->len == 0:
        return ps_str_new(ctx, "", 0)
    buf: *char = (*char)(malloc(usize(s->len) * usize(12) + usize(4)))
    k: usize = 0
    i: usize = 0
    n: usize = usize(s->len)
    prev_cased: bool = False
    while i < n:
        w: usize = 1
        cp: i32 = uc_decode(s, i, ref w)
        outs: i32[4]
        cnt: i32 = 0
        if mode == 2:
            # swapcase: quem é maiúsculo desce, quem é minúsculo sobe
            if tb_in(&PS_CAT[0], CA_UPPER, cp):
                cnt = tb_multi(&PS_CASE[0], UC_LOM, cp, &outs[0])
                if cnt == 0:
                    outs[0] = tb_map(&PS_CASE[0], UC_LO, cp)
                    cnt = 1
            elif tb_in(&PS_CAT[0], CA_LOWER, cp):
                cnt = tb_multi(&PS_CASE[0], UC_UPM, cp, &outs[0])
                if cnt == 0:
                    outs[0] = tb_map(&PS_CASE[0], UC_UP, cp)
                    cnt = 1
            else:
                outs[0] = cp
                cnt = 1
        else:
            first: bool = (i == 0) if mode == 1 else (not prev_cased)
            if first:
                # o mapeamento de TÍTULO: um-para-muitos e, se não estiver lá,
                # a faixa de um-para-um
                cnt = tb_multi(&PS_CAT[0], CA_TIMULTI, cp, &outs[0])
                if cnt == 0:
                    outs[0] = tb_map(&PS_CAT[0], CA_TIRANGE, cp)
                    cnt = 1
            else:
                # minúscula, com o sigma final que a 89 já resolve
                if cp == 0x03A3:
                    outs[0] = 0x03C2 if uc_final_sigma(s, i) else 0x03C3
                    cnt = 1
                else:
                    cnt = tb_multi(&PS_CASE[0], UC_LOM, cp, &outs[0])
                    if cnt == 0:
                        outs[0] = tb_map(&PS_CASE[0], UC_LO, cp)
                        cnt = 1
        for q in range(cnt):
            k = ps_utf8_put(buf, k, outs[q])
        prev_cased = tb_in(&PS_CAT[0], CA_UPPER, cp) or tb_in(&PS_CAT[0], CA_LOWER, cp) or tb_in(&PS_CASE[0], UC_CASED, cp)
        i += w
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

def ps_str_title(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    return ps_str_recase(ctx, s, 0)

def ps_str_capitalize(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    return ps_str_recase(ctx, s, 1)

def ps_str_swapcase(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    return ps_str_recase(ctx, s, 2)

# `casefold` é o `lower` do Python para COMPARAR, e difere dele em uns poucos
# lugares — `ß` dobra para `ss`, `ﬁ` para `fi`. Sem a tabela de CaseFolding não
# dá para prometer isso, e prometer errado é o que a 105 existe para evitar: o
# que está aqui é o `lower`, e o nome não é oferecido. Ver 105.4.

def ps_str_upper(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    return ps_str_case(ctx, s, True)

# `s * n` — Python's repetition. A negative or zero count is the empty string,
# as there, and an overflow of the product is a raise rather than a wrap (7.2).
def ps_str_repeat(ctx: *PsCtx, s: *PsStr, n: i64, file: const *char, line: i32) -> *PsStr:
    if n <= 0 or s->len == 0:
        return ps_str_new(ctx, "", 0)
    if usize(s->len) > usize(0) and usize(n) > usize(2147483647) / usize(s->len):
        ps_raise(ctx, "the repeated string does not fit", PS_CAT_VALUE, file, line)
        return ps_str_new(ctx, "", 0)
    total: usize = usize(s->len) * usize(n)
    buf: *char = (*char)(malloc(total + usize(1)))
    i: i64 = 0
    while i < n:
        memcpy(buf + usize(i) * usize(s->len), s->data, usize(s->len))
        i += 1
    out: *PsStr = ps_str_new(ctx, buf, total)
    free(buf)
    return out

# `s.replace(old, new)` — every occurrence, left to right, non-overlapping.
# An empty `old` is a no-op rather than Python's "insert between every
# character": that reading is a curiosity, not a use, and the loop that
# implements it is the one that never terminates when it is wrong.
def ps_str_replace(ctx: *PsCtx, s: *PsStr, old: *PsStr, new: *PsStr) -> *PsStr:
    if old->len == 0 or old->len > s->len:
        return s
    hits: usize = 0
    i: usize = 0
    while i + usize(old->len) <= usize(s->len):
        if memcmp(s->data + i, old->data, usize(old->len)) == 0:
            hits += 1
            i += usize(old->len)
        else:
            i += 1
    if hits == 0:
        return s
    outn: usize = usize(s->len) + hits * usize(new->len) - hits * usize(old->len)
    buf: *char = (*char)(malloc(outn + usize(1)))
    k: usize = 0
    i = 0
    while i < usize(s->len):
        if i + usize(old->len) <= usize(s->len) and memcmp(s->data + i, old->data, usize(old->len)) == 0:
            if new->len > 0:
                memcpy(buf + k, new->data, usize(new->len))
            k += usize(new->len)
            i += usize(old->len)
        else:
            buf[k] = s->data[i]
            k += 1
            i += 1
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

# `sep.join(parts)` — the separator is the receiver, as in Python. The whole
# length is known before anything is built, so this is ONE allocation rather
# than one per element, which is the entire reason `join` exists instead of a
# loop of `+`.
def ps_str_join(ctx: *PsCtx, sep: *PsStr, parts: *PsList) -> *PsStr:
    n: i64 = parts->len if parts != None else 0
    if n == 0:
        return ps_str_new(ctx, "", 0)
    base: **PsStr = (**PsStr)(ps_list_base(parts))
    total: usize = usize(sep->len) * usize(n - 1)
    i: i64 = 0
    while i < n:
        total += usize(base[i]->len)
        i += 1
    buf: *char = (*char)(malloc(total + usize(1)))
    k: usize = 0
    i = 0
    while i < n:
        if i > 0 and sep->len > 0:
            memcpy(buf + k, sep->data, usize(sep->len))
            k += usize(sep->len)
        if base[i]->len > 0:
            memcpy(buf + k, base[i]->data, usize(base[i]->len))
        k += usize(base[i]->len)
        i += 1
    out: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return out

# `abs`, `min`, `max`. Two forms each because pscript has two numeric types and
# no promotion at the call site would be free. `abs` of the smallest int RAISES:
# there is no positive counterpart of it in i64, and the alternative is to
# answer itself, which is the C behaviour and a lie (7.2).
def ps_abs_int(ctx: *PsCtx, v: i64, file: const *char, line: i32) -> i64:
    if v == -9223372036854775807 - 1:
        ps_raise(ctx, "abs() of the smallest int does not fit in an int", PS_CAT_VALUE, file, line)
        return 0
    return -v if v < 0 else v

def ps_abs_float(v: f64) -> f64:
    return -v if v < 0.0 else v

def ps_min_int(a: i64, b: i64) -> i64:
    return a if a < b else b

def ps_max_int(a: i64, b: i64) -> i64:
    return a if a > b else b

def ps_min_float(a: f64, b: f64) -> f64:
    return a if a < b else b

def ps_max_float(a: f64, b: f64) -> f64:
    return a if a > b else b

def ps_str_startswith(s: *PsStr, p: *PsStr) -> bool:
    if p->len > s->len:
        return False
    return memcmp(s->data, p->data, usize(p->len)) == 0

def ps_str_endswith(s: *PsStr, p: *PsStr) -> bool:
    if p->len > s->len:
        return False
    return memcmp(s->data + (usize(s->len) - usize(p->len)), p->data, usize(p->len)) == 0

# `lstrip` and `rstrip`: the same whitespace as `strip`, one end at a time.
def ps_str_lstrip(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    a: usize = 0
    b: usize = usize(s->len)
    while a < b and (s->data[a] == ' ' or s->data[a] == '\t' or s->data[a] == '\n' or s->data[a] == '\r'):
        a += 1
    return ps_str_new(ctx, s->data + a, b - a)

def ps_str_rstrip(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    b: usize = usize(s->len)
    while b > usize(0) and (s->data[b - 1] == ' ' or s->data[b - 1] == '\t' or s->data[b - 1] == '\n' or s->data[b - 1] == '\r'):
        b -= 1
    return ps_str_new(ctx, s->data, b)

def ps_str_strip(ctx: *PsCtx, s: *PsStr) -> *PsStr:
    a: usize = 0
    b: usize = usize(s->len)
    while a < b and (s->data[a] == ' ' or s->data[a] == '\t' or s->data[a] == '\n' or s->data[a] == '\r'):
        a += 1
    while b > a and (s->data[b - 1] == ' ' or s->data[b - 1] == '\t' or s->data[b - 1] == '\n' or s->data[b - 1] == '\r'):
        b -= 1
    return ps_str_new(ctx, s->data + a, b - a)

# splits on a NON-EMPTY separator, like Python's `s.split(sep)`
def ps_str_split(ctx: *PsCtx, s: *PsStr, sep: *PsStr) -> *PsList:
    out: *PsList = ps_list_new(ctx, i32(sizeof(PsStrPtr)), True, 4)
    if sep->len == 0:
        ps_raise(ctx, "split() needs a non-empty separator", PS_CAT_VALUE, "<split>", 0)
        return out
    start: usize = 0
    i: usize = 0
    n: usize = usize(s->len)
    m: usize = usize(sep->len)
    while i + m <= n:
        if memcmp(s->data + i, sep->data, m) == 0:
            piece: *PsStr = ps_str_new(ctx, s->data + start, i - start)
            slot: **PsStr = (**PsStr)(ps_list_push(ctx, out))
            *slot = piece
            i += m
            start = i
        else:
            i += 1
    last: *PsStr = ps_str_new(ctx, s->data + start, n - start)
    slot2: **PsStr = (**PsStr)(ps_list_push(ctx, out))
    *slot2 = last
    return out

def ps_str_to_int(ctx: *PsCtx, s: *PsStr) -> i64:
    end: *char = None
    v: i64 = strtoll(s->data, &end, 10)
    if end == s->data or *end != '\0':
        ps_raise(ctx, "int(): the string is not a number", PS_CAT_VALUE, "<int>", 0)
        return 0
    return v

def ps_str_to_float(ctx: *PsCtx, s: *PsStr) -> f64:
    end: *char = None
    v: f64 = strtod(s->data, &end)
    if end == s->data or *end != '\0':
        ps_raise(ctx, "float(): the string is not a number", PS_CAT_VALUE, "<float>", 0)
        return 0.0
    return v

# ---------- errors ----------
def ps_raise(ctx: *PsCtx, msg: const *char, cat: i32, file: const *char, line: i32):
    # The FIRST exception wins: a raise while one is already pending would lose
    # the original, and the original is the one that explains what happened.
    if ctx->exc != None:
        return
    e: *PsErr = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR)
    e->msg = ps_str_new(ctx, msg, strlen(msg))
    e->cat = cat
    e->file = file
    e->line = line
    ps_trace_capture(ctx, e)
    ctx->exc = e

def ps_raise_str(ctx: *PsCtx, msg: *PsStr, cat: i64, file: const *char, line: i32):
    if ctx->exc != None:
        return
    e: *PsErr = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR)
    e->msg = msg
    e->cat = i32(cat)
    e->file = file
    e->line = line
    ps_trace_capture(ctx, e)
    ctx->exc = e

def ps_err_new(ctx: *PsCtx, msg: *PsStr, cat: i64, file: const *char, line: i32) -> *PsErr:
    e: *PsErr = ps_alloc(ctx, sizeof(PsErr), PS_TY_ERR)
    e->msg = msg
    e->cat = i32(cat)
    # 107: onde o erro foi CONSTRUÍDO. `raise e` passa a mesma falha adiante e
    # por isso não toca na posição — então ela tem de nascer aqui, senão o erro
    # que o programa levanta é o único do sistema sem arquivo e linha.
    e->file = file
    e->line = line
    ps_trace_capture(ctx, e)
    return e

def ps_reraise(ctx: *PsCtx, e: *PsErr):
    # re-raising keeps the ORIGINAL position and category: the point of
    # `raise e` is to pass the same failure on, not to report a new one here
    if ctx->exc != None or e == None:
        return
    ctx->exc = e

def ps_has_exc(ctx: *PsCtx) -> bool:
    return ctx->exc != None

# O RELATÓRIO de um erro que ninguém apanhou, e o status que ele vira.
#
# Mora aqui, e não no epílogo, porque há DUAS portas por onde um programa sai
# com um erro pendente: o fim normal (`ps_ctx_done`) e um `sys.exit` explícito.
# A segunda passava direto — o `exit` corria com o código que o programa ia
# devolver e que nem chegou a ser calculado, e o processo saía com 0 e sem
# mensagem nenhuma. Um `sys.exit(await f())` em que `f` falha reportava SUCESSO.
def ps_report_exc(ctx: *PsCtx) -> int:
    if ctx == None or ctx->exc == None:
        return 0
    e: *PsErr = ctx->exc
    # o erro sai do contexto ANTES de se imprimir o que quer que seja: o
    # post-mortem chama o `repr` de cada variável, e o `repr` pergunta se há
    # exceção pendente para saber se ele próprio falhou. Com o erro ainda lá,
    # a primeira variável parecia sempre ter falhado a imprimir — e o `take`
    # que se seguia apagava o erro que se estava a relatar.
    ps_take_exc(ctx)
    # o que o programa imprimiu vem primeiro: com o stdout em blocos (um cano,
    # um arquivo) o erro ultrapassá-lo-ia
    fflush(stdout)
    fprintf(stderr, "%s:%d: error: %s\n", e->file if e->file != None else "?", e->line, e->msg->data if e->msg != None else "")
    # a pilha em que o erro NASCEU (15.2/34.2), de dentro para fora — e, com
    # `-g`, O QUE ESTAVA EM CADA VARIÁVEL (F6).
    #
    # Uma pilha diz ONDE. O post-mortem diz PORQUÊ, que é a pergunta a seguir e
    # a razão de alguém abrir um depurador. Aqui ela responde-se sem depurador
    # nenhum: os valores já foram copiados no `raise`, e o que os imprime é o
    # `repr` genérico da F5 — a tabela de campos sabe o que cada variável é.
    nv: i32 = 0
    for i in range(e->tr_n):
        if e->tr_line[i] != 0:
            fprintf(stderr, "  in %s (%s:%d)\n", e->tr_fn[i], e->tr_file[i] if e->tr_file[i] != None else "?", e->tr_line[i])
        else:
            fprintf(stderr, "  in %s (%s)\n", e->tr_fn[i], e->tr_file[i] if e->tr_file[i] != None else "?")
        for j in range(e->tr_nsl[i]):
            if nv >= 192:
                break
            nome: const *char = e->tr_name[nv]
            ty: const *PsTy = e->tr_ty[nv]
            v: *PsObj = e->tr_val[nv]
            nv += 1
            if nome == None:
                continue
            if v == None:
                fprintf(stderr, "      %s = None\n", nome)
                continue
            r: *PsStr = ps_repr_val(ctx, (*void)(v), ty, 1)
            if ps_has_exc(ctx):
                # o repr de um valor não pode enterrar o erro que se está a
                # relatar: se ele próprio falhar, diz-se isso e segue-se
                ps_take_exc(ctx)
                fprintf(stderr, "      %s = <não se deixou imprimir>\n", nome)
                continue
            fprintf(stderr, "      %s = %s\n", nome, r->data)
    if e->tr_lost > 0:
        fprintf(stderr, "  ... and %d more\n", e->tr_lost)
    return 1

def ps_take_exc(ctx: *PsCtx) -> *PsErr:
    e: *PsErr = ctx->exc
    ctx->exc = None
    return e

def ps_err_message(e: *PsErr) -> *PsStr:
    return e->msg

def ps_err_category(e: *PsErr) -> i64:
    return i64(e->cat)

# ---------- formatting ----------
# pads `src` to `width` according to `align`; `zero` fills with '0' after any
# sign, which is what `08d` means
private def ps_pad(ctx: *PsCtx, src: const *char, n: usize, width: i32, align: char, zero: bool) -> *PsStr:
    if width <= 0 or usize(width) <= n:
        return ps_str_new(ctx, src, n)
    total: usize = usize(width)
    pad: usize = total - n
    out: *PsStr = ps_alloc(ctx, sizeof(PsStr) + total + 1, PS_TY_STR)
    out->len = u32(total)
    out->hash = 0
    out->offs = None
    # padding is ASCII spaces or zeros, so the character count grows with it
    out->nchars = u32(pad) + ps_utf8_count(src, n)
    d: *char = out->data
    if zero and align != '^':
        # the sign stays in front of the zeros: -0042, never 00-42
        lead: usize = 1 if n > 0 and (src[0] == '-' or src[0] == '+') else 0
        memcpy(d, src, lead)
        memset(d + lead, '0', pad)
        memcpy(d + lead + pad, src + lead, n - lead)
    elif align == '<':
        memcpy(d, src, n)
        memset(d + n, ' ', pad)
    elif align == '^':
        left: usize = pad / 2
        memset(d, ' ', left)
        memcpy(d + left, src, n)
        memset(d + left + n, ' ', pad - left)
    else:
        memset(d, ' ', pad)
        memcpy(d + pad, src, n)
    d[total] = '\0'
    return out

def ps_fmt_int(ctx: *PsCtx, v: i64, width: i32, align: char, zero: bool, ty: char) -> *PsStr:
    buf: char[32]
    n: usize = 0
    if ty == 'x' or ty == 'X' or ty == 'b' or ty == 'o':
        base: i64 = 16 if (ty == 'x' or ty == 'X') else (2 if ty == 'b' else 8)
        digits: const *char = "0123456789abcdef" if ty != 'X' else "0123456789ABCDEF"
        i: i32 = 32
        u: u64 = u64(v)
        do:
            i -= 1
            buf[i] = digits[usize(u % u64(base))]
            u /= u64(base)
        while u != 0
        n = usize(32 - i)
        return ps_pad(ctx, buf + i, n, width, align, zero)
    t: *PsStr = ps_str_from_int(ctx, v)
    return ps_pad(ctx, t->data, usize(t->len), width, align, zero)

def ps_fmt_float(ctx: *PsCtx, v: f64, width: i32, prec: i32, align: char, zero: bool) -> *PsStr:
    if prec < 0:
        t: *PsStr = ps_str_from_float(ctx, v)
        return ps_pad(ctx, t->data, usize(t->len), width, align, zero)
    buf: char[64]
    n: i32 = snprintf(buf, 64, "%.*f", prec, v)
    return ps_pad(ctx, buf, usize(n), width, align, zero)

def ps_fmt_str(ctx: *PsCtx, s: *PsStr, width: i32, align: char) -> *PsStr:
    return ps_pad(ctx, s->data, usize(s->len), width, align, False)

# ---------- output ----------
# 78.2: the same text `print` would write, handed to the pool instead. What it
# buys is a program that keeps running while a full pipe or a slow terminal
# takes its time; what it costs is an `await`, which is why `print` itself was
# left alone.
# 78.2: stdout and stderr as ordinary files. They belong to the process, so
# `close()` on one does nothing — a program that closed the world's stdout
# would be a program nobody could debug.
def ps_std_file(ctx: *PsCtx, which: i32) -> *PsFile:
    f: *PsFile = (*PsFile)(ps_alloc(ctx, sizeof(PsFile), PS_TY_FILE))
    f->fp = stdout if which == 0 else stderr
    f->is_open = 1
    f->is_std = 1
    return f


def ps_print(ctx: *PsCtx, s: *PsStr):
    # 49.2: once an exception is pending, every call is a no-op until the check
    # at the end of the statement sees it. Printing here would be printing a
    # value that was never really computed.
    if ctx->exc != None:
        return
    # UMA escrita, não duas (107). `fwrite` do texto seguido de `fputc('\n')`
    # são duas chamadas de stdio, cada uma trancando o FILE por si — e como
    # stdout é o MESMO arquivo de todos os workers (cada um tem heap, coletor e
    # loop próprios, mas não uma saída própria), a linha de um saía no meio da
    # linha do outro. Medido: oito workers imprimindo 200 linhas cada davam 66
    # linhas costuradas e vazias. Com o texto e o `\n` na mesma chamada, o
    # trinco do stdio cobre a linha inteira e a saída volta a ser linhas.
    n: usize = usize(s->len)
    buf: char[1024]
    if n + usize(1) <= sizeof(buf):
        memcpy(&buf[0], s->data, n)
        buf[n] = '\n'
        fwrite(&buf[0], 1, n + usize(1), stdout)
        return
    p: *char = (*char)(malloc(n + usize(1)))
    if p == None:
        fwrite(s->data, 1, n, stdout)
        fputc('\n', stdout)
        return
    memcpy(p, s->data, n)
    p[n] = '\n'
    fwrite(p, 1, n + usize(1), stdout)
    free(p)

# ---------- arithmetic ----------
# Overflow raises (7.2). The checks are the portable ones: detect before the
# operation, so nothing ever relies on signed overflow, which is undefined in C
# and would let the target compiler delete the check.
def ps_add(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b > 0 and a > 9223372036854775807 - b:
        ps_raise(ctx, "integer overflow in +", PS_CAT_OVERFLOW, file, line)
        return 0
    if b < 0 and a < (-9223372036854775807 - 1) - b:
        ps_raise(ctx, "integer overflow in +", PS_CAT_OVERFLOW, file, line)
        return 0
    return a + b

def ps_sub(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b < 0 and a > 9223372036854775807 + b:
        ps_raise(ctx, "integer overflow in -", PS_CAT_OVERFLOW, file, line)
        return 0
    if b > 0 and a < (-9223372036854775807 - 1) + b:
        ps_raise(ctx, "integer overflow in -", PS_CAT_OVERFLOW, file, line)
        return 0
    return a - b

def ps_mul(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    # A PERGUNTA VEM ANTES DA MULTIPLICAÇÃO, e é essa a única coisa que importa
    # aqui.
    #
    # A forma anterior multiplicava e conferia depois, com a divisão:
    #
    #     r: i64 = a * b
    #     if b != 0 and (r / a != b or ...):   # tarde demais
    #
    # A conta está certa e o teste é exato; o problema é que `a * b` de signed
    # que estoura é COMPORTAMENTO INDEFINIDO em C. O gcc tem então o direito de
    # assumir que não estoura, provar que `r / a == b` sempre vale, e APAGAR o
    # `if`. Foi o que ele fez, e a garantia 7.2 — "estouro de int lança", um dos
    # quatro eixos de segurança — era falsa em todo build otimizado:
    #
    #     flags            9223372036854775807 * 2
    #     -O0              levanta          (correto)
    #     -O1              -2               EM SILÊNCIO
    #     -O2              -2               EM SILÊNCIO
    #     -O2 -flto        -2               EM SILÊNCIO
    #     -O2 -fwrapv      levanta          (porque aí o estouro passa a ser definido)
    #
    # `-fwrapv` conserta e é a saída errada: passa a depender de uma bandeira que
    # quem compila o programa gerado tem de lembrar de pôr, e a linguagem promete
    # C portável. `__builtin_mul_overflow` também não serve: o alvo inclui C89 em
    # compilador pequeno.
    #
    # Então a checagem é feita sobre os OPERANDOS, com divisão — que nunca
    # estoura —, nos quatro quadrantes de sinal. `ps_add` e `ps_sub` sempre
    # fizeram assim; só a multiplicação não fazia.
    if a == 0 or b == 0:
        return 0
    MIN: i64 = -9223372036854775807 - 1
    MAX: i64 = 9223372036854775807
    over: bool = False
    if a > 0:
        over = a > MAX / b if b > 0 else b < MIN / a
    else:
        # os dois negativos dão produto POSITIVO, e o teto é o MAX; um negativo
        # com um positivo dá produto negativo, e o piso é o MIN. O caso que a
        # forma antiga tratava à parte (`a == -1 and b == MIN`) cai aqui sem
        # exceção nenhuma: `MAX / MIN` é 0 e `-1 < 0`.
        over = a < MIN / b if b > 0 else a < MAX / b
    if over:
        ps_raise(ctx, "integer overflow in *", PS_CAT_OVERFLOW, file, line)
        return 0
    return a * b

def ps_neg(ctx: *PsCtx, a: i64, file: const *char, line: i32) -> i64:
    if a == (-9223372036854775807 - 1):
        ps_raise(ctx, "integer overflow in unary -", PS_CAT_OVERFLOW, file, line)
        return 0
    return -a

def ps_div(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64:
    # `/` is float even between ints (39.1), and dividing by zero RAISES the
    # way Python does (47.2) rather than producing inf
    if b == 0.0:
        ps_raise(ctx, "division by zero", PS_CAT_ZERO, file, line)
        return 0.0
    return a / b

def ps_floordiv(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b == 0:
        ps_raise(ctx, "integer division by zero", PS_CAT_ZERO, file, line)
        return 0
    if a == (-9223372036854775807 - 1) and b == -1:
        ps_raise(ctx, "integer overflow in //", PS_CAT_OVERFLOW, file, line)
        return 0
    q: i64 = a / b            # C truncates toward zero
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q -= 1                # Python floors
    return q

def ps_mod(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    if b == 0:
        ps_raise(ctx, "integer modulo by zero", PS_CAT_ZERO, file, line)
        return 0
    if a == (-9223372036854775807 - 1) and b == -1:
        return 0
    r: i64 = a % b            # C keeps the DIVIDEND's sign
    if r != 0 and ((r < 0) != (b < 0)):
        r += b                # Python takes the DIVISOR's, preserving
    return r                  #   a == (a//b)*b + a%b

def ps_fpow(a: f64, b: f64) -> f64:
    return pow(a, b)

# Python's `//` and `%` on floats are the same RULE as on integers: the quotient
# floors and the remainder carries the divisor's sign, so `a == (a//b)*b + a%b`
# holds there too. Dividing by zero raises, as it does everywhere else (32.2).
def ps_ffloordiv(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64:
    if b == 0.0:
        ps_raise(ctx, "float division by zero", PS_CAT_ZERO, file, line)
        return 0.0
    return floor(a / b)

def ps_fmod(ctx: *PsCtx, a: f64, b: f64, file: const *char, line: i32) -> f64:
    if b == 0.0:
        ps_raise(ctx, "float modulo by zero", PS_CAT_ZERO, file, line)
        return 0.0
    return a - floor(a / b) * b

# ---------- exact widths (68.2) ----------
def ps_fitw(ctx: *PsCtx, v: i64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64:
    if v < lo or v > hi:
        msg: char[96]
        snprintf(msg, 96, "overflow of %s", what)
        ps_raise(ctx, msg, PS_CAT_OVERFLOW, file, line)
        return 0
    return v

def ps_f_to_iw(ctx: *PsCtx, v: f64, lo: i64, hi: i64, what: const *char, file: const *char, line: i32) -> i64:
    if v != v or v < f64(lo) or v > f64(hi):
        msg: char[96]
        snprintf(msg, 96, "%f does not fit %s", v, what)
        ps_raise(ctx, msg, PS_CAT_OVERFLOW, file, line)
        return 0
    return i64(v)

def ps_uadd(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if a > ~u64(0) - b:
        ps_raise(ctx, "overflow of u64 in +", PS_CAT_OVERFLOW, file, line)
        return 0
    return a + b

def ps_usub(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if b > a:
        ps_raise(ctx, "overflow of u64 in - (the result would be negative)", PS_CAT_OVERFLOW, file, line)
        return 0
    return a - b

def ps_umul(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if a != 0 and b > (~u64(0)) / a:
        ps_raise(ctx, "overflow of u64 in *", PS_CAT_OVERFLOW, file, line)
        return 0
    return a * b

def ps_udiv(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if b == 0:
        ps_raise(ctx, "integer division by zero", PS_CAT_ZERO, file, line)
        return 0
    return a / b

def ps_umod(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    if b == 0:
        ps_raise(ctx, "integer modulo by zero", PS_CAT_ZERO, file, line)
        return 0
    return a % b

def ps_upow(ctx: *PsCtx, a: u64, b: u64, file: const *char, line: i32) -> u64:
    r: u64 = 1
    base: u64 = a
    e: u64 = b
    while e > 0:
        if e & 1 == 1:
            r = ps_umul(ctx, r, base, file, line)
            if ctx->exc != None:
                return 0
        e >>= 1
        if e > 0:
            base = ps_umul(ctx, base, base, file, line)
            if ctx->exc != None:
                return 0
    return r

def ps_u_to_i(ctx: *PsCtx, v: u64, file: const *char, line: i32) -> i64:
    if v > u64(9223372036854775807):
        ps_raise(ctx, "this u64 does not fit int", PS_CAT_OVERFLOW, file, line)
        return 0
    return i64(v)

def ps_f_to_i(ctx: *PsCtx, x: f64, file: const *char, line: i32) -> i64:
    """A travessia de float para int, CHECADA.

    `(int64_t)x` em C é comportamento indefinido quando `x` é NaN, infinito, ou
    finito mas fora da faixa do i64 — e o compilador exerce esse direito. Medido,
    o MESMO programa na MESMA máquina:

        int(1e300)      -O0   -9223372036854775808
                        -O2    9223372036854775807

    E não é só a otimização: no x86 o `cvttsd2si` devolve o "integer indefinite"
    (INT64_MIN) e no ARM64 o `fcvtzs` SATURA, então a mesma linha dá INT64_MIN num
    Linux de mesa e INT64_MAX num Apple Silicon. Uma linguagem que promete o mesmo
    programa em todo o lado não pode ter isto no caminho de `int(x)`.

    `1e300` mostra que não se trata de NaN: é um float finito que não cabe, ou
    seja ESTOURO, e a 7.2 diz que estouro levanta.

    As mensagens seguem o Python, que é o oráculo da linguagem: ele levanta
    `ValueError` no NaN e `OverflowError` no infinito. O terceiro caso é nosso —
    o `int` do Python é de precisão arbitrária e aceita `1e300`; o nosso é i64.

    A faixa é comparada em FLOAT, sem converter primeiro: 2^63 é exactamente
    representável em f64 e i64 vai até 2^63-1, logo o que cabe é
    `-2^63 <= x < 2^63`."""
    if x != x:
        ps_raise(ctx, "cannot convert float NaN to integer", PS_CAT_VALUE, file, line)
        return 0
    # depois do NaN, so' o infinito faz `x - x` nao ser zero
    if x - x != 0.0:
        ps_raise(ctx, "cannot convert float infinity to integer", PS_CAT_OVERFLOW, file, line)
        return 0
    if x >= 9223372036854775808.0 or x < -9223372036854775808.0:
        ps_raise(ctx, "this float does not fit int", PS_CAT_OVERFLOW, file, line)
        return 0
    return i64(x)

def ps_i_to_u64(ctx: *PsCtx, v: i64, file: const *char, line: i32) -> u64:
    if v < 0:
        ps_raise(ctx, "a negative int does not fit u64", PS_CAT_OVERFLOW, file, line)
        return 0
    return u64(v)

def ps_f_to_u64(ctx: *PsCtx, v: f64, file: const *char, line: i32) -> u64:
    if v != v or v < 0.0 or v >= 18446744073709551616.0:
        ps_raise(ctx, "this float does not fit u64", PS_CAT_OVERFLOW, file, line)
        return 0
    return u64(v)

def ps_wrapw(v: i64, bits: i32, uns: bool) -> i64:
    u: u64 = u64(v)
    if bits < 64:
        u &= (u64(1) << u64(bits)) - 1
    if not uns and bits < 64 and (u & (u64(1) << u64(bits - 1))) != 0:
        u |= ~((u64(1) << u64(bits)) - 1)      # sign-extend the wrapped value
    return i64(u)

def ps_str_from_uint(ctx: *PsCtx, v: u64) -> *PsStr:
    buf: char[24]
    i: i32 = 24
    n: u64 = v
    do:
        i -= 1
        buf[i] = char('0' + int(n % 10))
        n /= 10
    while n != 0
    return ps_str_new(ctx, buf + i, usize(24 - i))

def ps_fmt_uint(ctx: *PsCtx, v: u64, width: i32, align: char, zero: bool, ty: char) -> *PsStr:
    s: *PsStr = ps_str_from_uint(ctx, v)
    return ps_pad(ctx, s->data, usize(s->len), width, align, zero)

def ps_pow(ctx: *PsCtx, a: i64, b: i64, file: const *char, line: i32) -> i64:
    # A variable exponent cannot change the static type of the result (47.3), so
    # a negative one raises instead of quietly becoming a float. A constant
    # negative exponent is folded to a float long before it reaches here.
    if b < 0:
        ps_raise(ctx, "negative exponent on integers (write a float base for that)", PS_CAT_VALUE, file, line)
        return 0
    r: i64 = 1
    base: i64 = a
    e: i64 = b
    while e > 0:
        if e & 1 == 1:
            r = ps_mul(ctx, r, base, file, line)
            if ctx->exc != None:
                return 0
        e >>= 1
        if e > 0:
            base = ps_mul(ctx, base, base, file, line)
            if ctx->exc != None:
                return 0
    return r


# ---------- O REPR COMO DADO (F5) ----------
#
# Um só percurso, guiado pela tabela de campos, no lugar de uma função gerada
# por tipo. O que ele imprime é EXATAMENTE o que a forma gerada imprimia — os
# testes do corpus comparam caractere a caractere, e é essa a prova de que a
# troca não mudou a linguagem, só de onde vem o código.
#
# A profundidade é dinâmica e não estática: um tipo que se contém a si mesmo
# para em `Nome(...)` em vez de descer para sempre. Era um limite que a forma
# gerada tinha por construção (ela expandia o texto) e que aqui tem de ser dito.

private def ps_repr_dict2(ctx: *PsCtx, d: *PsDict, kt: const *PsTy, vt: const *PsTy) -> *PsStr

private def ps_ty_int(p: *void, ty: const *PsTy) -> i64:
    w: i32 = ty->width if ty->width != 0 else 64
    if ty->uns:
        if w == 8:
            return i64(*(*u8)(p))
        if w == 16:
            return i64(*(*u16)(p))
        if w == 32:
            return i64(*(*u32)(p))
        return i64(*(*u64)(p))
    if w == 8:
        return i64(*(*i8)(p))
    if w == 16:
        return i64(*(*i16)(p))
    if w == 32:
        return i64(*(*i32)(p))
    return *(*i64)(p)

# a assinatura que `ps_repr_seq` e `ps_repr_dict` pedem: o `env` é o TIPO do
# elemento, que é o que faltava para o runtime saber o que está a olhar
private def ps_repr_elem(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr:
    return ps_repr_ty(ctx, (*void)(ep), (*PsTy)(env), 1)

def ps_repr_ty(ctx: *PsCtx, p: *void, ty: const *PsTy, depth: i32) -> *PsStr:
    if ty == None or p == None:
        return ps_str_new(ctx, "?", usize(1))
    k: i32 = ty->kind
    if k == 1:
        if ty->uns and (ty->width == 64 or ty->width == 0):
            return ps_str_from_uint(ctx, *(*u64)(p))
        return ps_str_from_int(ctx, ps_ty_int(p, ty))
    if k == 2:
        if ty->width == 32:
            return ps_str_from_float(ctx, f64(*(*f32)(p)))
        return ps_str_from_float(ctx, *(*f64)(p))
    if k == 3:
        return ps_str_from_bool(ctx, *(*i32)(p) != 0)
    if k == 4:
        # 97.1: DENTRO de qualquer coisa, uma string sai com aspas. No topo é a
        # própria string, e quem decide isso é quem chama — aqui é sempre dentro.
        sp: *PsStr = *(**PsStr)(p)
        return ps_str_new(ctx, "None", usize(4)) if sp == None else ps_str_quoted(ctx, sp)
    if k == 5:
        lp: *PsList = *(**PsList)(p)
        if lp == None:
            return ps_str_new(ctx, "[]", usize(2))
        return ps_repr_seq(ctx, lp, "[", "]", ps_repr_elem, (*void)(ty->inner))
    if k == 6:
        sp2: *PsDict = *(**PsDict)(p)
        if sp2 == None:
            return ps_str_new(ctx, "set()", usize(5))
        return ps_repr_dict(ctx, sp2, ps_repr_elem, None, (*void)(ty->inner))
    if k == 7:
        dp: *PsDict = *(**PsDict)(p)
        if dp == None:
            return ps_str_new(ctx, "{}", usize(2))
        return ps_repr_dict2(ctx, dp, ty->key, ty->inner)
    if k == 8:
        return ps_repr_desc(ctx, p, ty->desc, depth)
    if k == 9:
        op: *void = *(**void)(p)
        if op == None:
            return ps_str_new(ctx, "None", usize(4))
        # o descritor do PRÓPRIO objeto: um campo declarado com o tipo de cima
        # pode guardar um valor de um tipo de baixo, e é o objeto que sabe
        u: *PsUser = (*PsUser)(op)
        return ps_repr_desc(ctx, op, u->desc if u->desc != None else ty->desc, depth)
    if k == 10:
        v: i32 = *(*i32)(p)
        if ty->names != None and v >= 0 and v < ty->nnames:
            return ps_str_new(ctx, ty->names[v], strlen(ty->names[v]))
        return ps_str_new(ctx, "?", usize(1))
    return ps_str_new(ctx, "?", usize(1))

# um dict quer DOIS tipos, e a devolução de `ps_repr_dict` só carrega um `env`.
# Duas chamadas encadeadas resolviam-no com um estado global; um par no stack
# resolve-o sem nada disso.
struct PsKV:
    k: const *PsTy
    v: const *PsTy

private def ps_repr_kv_k(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr:
    kv: *PsKV = (*PsKV)(env)
    return ps_repr_ty(ctx, (*void)(ep), kv->k, 1)

private def ps_repr_kv_v(env: *void, ctx: *PsCtx, ep: const *void) -> *PsStr:
    kv: *PsKV = (*PsKV)(env)
    return ps_repr_ty(ctx, (*void)(ep), kv->v, 1)

private def ps_repr_dict2(ctx: *PsCtx, d: *PsDict, kt: const *PsTy, vt: const *PsTy) -> *PsStr:
    kv: PsKV = {kt, vt}
    return ps_repr_dict(ctx, d, ps_repr_kv_k, ps_repr_kv_v, (*void)(&kv))

# O MESMO percurso, com a REFERÊNCIA em vez do endereço dela.
#
# Um campo de um struct é um endereço (é lá que ele está); uma expressão como
# `[1, 2]` é um valor sem morada — e pedir-lhe o endereço obrigaria a inventar
# um local no meio de uma expressão, que é justamente onde a baixa não tem um
# sítio garantido para o declarar. Duas portas para o mesmo corredor.
def ps_repr_val(ctx: *PsCtx, o: *void, ty: const *PsTy, depth: i32) -> *PsStr:
    if ty == None:
        return ps_str_new(ctx, "?", usize(1))
    k: i32 = ty->kind
    if k == 4:
        return ps_str_new(ctx, "None", usize(4)) if o == None else ps_str_quoted(ctx, (*PsStr)(o))
    if k == 5:
        return ps_str_new(ctx, "[]", usize(2)) if o == None else ps_repr_seq(ctx, (*PsList)(o), "[", "]", ps_repr_elem, (*void)(ty->inner))
    if k == 6:
        return ps_str_new(ctx, "set()", usize(5)) if o == None else ps_repr_dict(ctx, (*PsDict)(o), ps_repr_elem, None, (*void)(ty->inner))
    if k == 7:
        return ps_str_new(ctx, "{}", usize(2)) if o == None else ps_repr_dict2(ctx, (*PsDict)(o), ty->key, ty->inner)
    if k == 9:
        if o == None:
            return ps_str_new(ctx, "None", usize(4))
        u: *PsUser = (*PsUser)(o)
        return ps_repr_desc(ctx, o, u->desc if u->desc != None else ty->desc, depth)
    return ps_repr_ty(ctx, o, ty, depth)

def ps_repr_desc(ctx: *PsCtx, o: *void, d: const *PsDesc, depth: i32) -> *PsStr:
    if d == None or o == None:
        return ps_str_new(ctx, "?", usize(1))
    if d->to_str != None:
        # o `to_str()` escrito pelo tipo GANHA, a qualquer profundidade (44.3).
        # A forma gerada só sabia disto no topo; aqui vale sempre.
        return d->to_str(o, ctx)
    nb: usize = strlen(d->name)
    if depth > 3 or d->fields == None or d->at == None:
        out0: *PsStr = ps_str_concat(ctx, ps_str_new(ctx, d->name, nb), ps_str_new(ctx, "(...)", usize(5)))
        return out0
    out: *PsStr = ps_str_concat(ctx, ps_str_new(ctx, d->name, nb), ps_str_new(ctx, "(", usize(1)))
    for i in range(d->nfields):
        if i > 0:
            out = ps_str_concat(ctx, out, ps_str_new(ctx, ", ", usize(2)))
        fn: const *char = d->fields[i].name
        out = ps_str_concat(ctx, out, ps_str_new(ctx, fn, strlen(fn)))
        out = ps_str_concat(ctx, out, ps_str_new(ctx, "=", usize(1)))
        out = ps_str_concat(ctx, out, ps_repr_ty(ctx, d->at(o, i), d->fields[i].ty, depth + 1))
    return ps_str_concat(ctx, out, ps_str_new(ctx, ")", usize(1)))


# ---------- json.stringify, PELA MESMA TABELA (F5) ----------
#
# O `repr` mostra e o JSON transporta, então não são a mesma função: um `to_str`
# escrito pelo tipo GANHA no repr (é a forma de o tipo se mostrar) e NÃO ganha
# aqui (JSON é dado, e quem o vai ler do outro lado espera os campos). Um enum
# viaja pelo NOME da variante e não pelo número, porque o número é uma escolha
# de compilação e o nome é o que significa alguma coisa do outro lado.
#
# O que NÃO atravessa levanta em vez de sair como texto: uma função, um `any`,
# um dict com chave que não é string. JSON que sai errado em silêncio é pior do
# que JSON que não sai.

private def ps_json_esc(ref b: PsRepr, s: *PsStr):
    ps_repr_put(ref b, "\"", usize(1))
    i: usize = 0
    while i < usize(s->len):
        c: char = s->data[i]
        u: u8 = u8(c)
        if c == '"' or c == '\\':
            tmp: char[2]
            tmp[0] = '\\'
            tmp[1] = c
            ps_repr_put(ref b, tmp, usize(2))
        elif c == '\n':
            ps_repr_put(ref b, "\\n", usize(2))
        elif c == '\r':
            ps_repr_put(ref b, "\\r", usize(2))
        elif c == '\t':
            ps_repr_put(ref b, "\\t", usize(2))
        elif u < u8(32):
            esc: char[8]
            snprintf(esc, usize(8), "\\u%04x", int(u))
            ps_repr_put(ref b, esc, usize(6))
        else:
            ps_repr_put(ref b, &c, usize(1))
        i += usize(1)
    ps_repr_put(ref b, "\"", usize(1))

private def ps_json_bad(ctx: *PsCtx, what: const *char, caminho: const *char):
    m: *PsStr = ps_str_new(ctx, "json.stringify: ", usize(16))
    m = ps_str_concat(ctx, m, ps_str_new(ctx, what, strlen(what)))
    # o CAMINHO é a metade útil da mensagem: num documento de trezentas linhas,
    # "isto não atravessa" sem dizer onde não serve para nada. Na raiz não há
    # caminho a dizer, e a mensagem acaba antes de o prometer.
    if caminho != None and caminho[0] != '\0':
        m = ps_str_concat(ctx, m, ps_str_new(ctx, " em ", usize(4)))
        m = ps_str_concat(ctx, m, ps_str_new(ctx, caminho, strlen(caminho)))
    ps_raise_str(ctx, m, i64(PS_CAT_VALUE), "json", 0)

private def ps_json_ty(ctx: *PsCtx, ref b: PsRepr, p: *void, ty: const *PsTy, caminho: const *char, depth: i32)
private def ps_json_desc(ctx: *PsCtx, ref b: PsRepr, o: *void, d: const *PsDesc, caminho: const *char, depth: i32)

private def ps_json_any(ctx: *PsCtx, ref b: PsRepr, o: *PsObj, caminho: const *char, depth: i32)

private def ps_json_val(ctx: *PsCtx, ref b: PsRepr, o: *void, ty: const *PsTy, caminho: const *char, depth: i32):
    if ty == None:
        ps_json_bad(ctx, "tipo desconhecido", caminho)
        return
    k: i32 = ty->kind
    if k == 11:
        # 39.2: um `any` diz de si próprio o que é. E o que ele pode conter é
        # exactamente a lista de formas do JSON — número, texto, bool, None,
        # `List<any>` e `Dict<str, any>` —, portanto isto fecha sem inventar
        # nada. O `PsTy` estático não sabe; o VALOR sabe.
        ps_json_any(ctx, ref b, (*PsObj)(o), caminho, depth)
        return
    if k == 4:
        if o == None:
            ps_repr_put(ref b, "null", usize(4))
        else:
            ps_json_esc(ref b, (*PsStr)(o))
        return
    if k == 5 or k == 6:
        if o == None:
            ps_repr_put(ref b, "[]", usize(2))
            return
        ps_repr_put(ref b, "[", usize(1))
        if k == 5:
            l: *PsList = (*PsList)(o)
            base: *char = ps_list_base(l)
            es: usize = usize(l->esize)
            for i in range(l->len):
                if i > 0:
                    ps_repr_put(ref b, ",", usize(1))
                sub: char[64]
                snprintf(sub, usize(64), "%s[%d]", caminho, int(i))
                ps_json_ty(ctx, ref b, (*void)(base + usize(i) * es), ty->inner, sub, depth + 1)
                if ps_has_exc(ctx):
                    return
        else:
            # um conjunto viaja como ARRAY: JSON não tem conjunto, e a
            # alternativa (um objeto com valores `true`) seria inventar um
            # formato que o outro lado teria de conhecer
            d2: *PsDict = (*PsDict)(o)
            n: i32 = 0
            i2: i64 = 0
            while i2 < d2->nent:
                if not ps_dict_live(d2, i2):
                    i2 += 1
                    continue
                kp: *void = (*void)(ps_dict_key_at(d2, i2))
                if n > 0:
                    ps_repr_put(ref b, ",", usize(1))
                n += 1
                sub2: char[64]
                snprintf(sub2, usize(64), "%s[]", caminho)
                ps_json_ty(ctx, ref b, kp, ty->inner, sub2, depth + 1)
                if ps_has_exc(ctx):
                    return
                i2 += 1
        ps_repr_put(ref b, "]", usize(1))
        return
    if k == 7:
        if o == None:
            ps_repr_put(ref b, "{}", usize(2))
            return
        if ty->key == None or ty->key->kind != 4:
            ps_json_bad(ctx, "um objeto JSON só tem chaves de texto", caminho)
            return
        d3: *PsDict = (*PsDict)(o)
        ps_repr_put(ref b, "{", usize(1))
        n2: i32 = 0
        i3: i64 = 0
        while i3 < d3->nent:
            if not ps_dict_live(d3, i3):
                i3 += 1
                continue
            kp2: *void = (*void)(ps_dict_key_at(d3, i3))
            if n2 > 0:
                ps_repr_put(ref b, ",", usize(1))
            n2 += 1
            ks: *PsStr = *(**PsStr)(kp2)
            if ks == None:
                ps_json_bad(ctx, "uma chave vazia", caminho)
                return
            ps_json_esc(ref b, ks)
            ps_repr_put(ref b, ":", usize(1))
            sub3: char[128]
            snprintf(sub3, usize(128), "%s.%.*s", caminho, int(ks->len), ks->data)
            ps_json_ty(ctx, ref b, (*void)(ps_dict_val_at(d3, i3)), ty->inner, sub3, depth + 1)
            if ps_has_exc(ctx):
                return
            i3 += 1
        ps_repr_put(ref b, "}", usize(1))
        return
    if k == 9:
        if o == None:
            ps_repr_put(ref b, "null", usize(4))
            return
        u: *PsUser = (*PsUser)(o)
        ps_json_desc(ctx, ref b, o, u->desc if u->desc != None else ty->desc, caminho, depth)
        return
    ps_json_ty(ctx, ref b, o, ty, caminho, depth)

private def ps_json_any(ctx: *PsCtx, ref b: PsRepr, o: *PsObj, caminho: const *char, depth: i32):
    if o == None:
        ps_repr_put(ref b, "null", usize(4))
        return
    if depth > 32:
        ps_json_bad(ctx, "aninhamento demasiado fundo", caminho)
        return
    match o->ty:
        case PS_TY_ANY:
            a: *PsAny = (*PsAny)(o)
            if a->kind == PS_ANY_INT:
                num: char[32]
                snprintf(num, usize(32), "%lld", a->i)
                ps_repr_put(ref b, num, strlen(num))
            elif a->kind == PS_ANY_FLOAT:
                if a->f != a->f or a->f > 1.0e308 or a->f < -1.0e308:
                    ps_json_bad(ctx, "JSON não tem NaN nem infinito", caminho)
                    return
                fs: *PsStr = ps_str_from_float(ctx, a->f)
                ps_repr_put(ref b, fs->data, usize(fs->len))
            elif a->kind == PS_ANY_BOOL:
                if a->i != 0:
                    ps_repr_put(ref b, "true", usize(4))
                else:
                    ps_repr_put(ref b, "false", usize(5))
            else:
                ps_repr_put(ref b, "null", usize(4))
        case PS_TY_STR:
            ps_json_esc(ref b, (*PsStr)(o))
        case PS_TY_LIST:
            l: *PsList = (*PsList)(o)
            ps_repr_put(ref b, "[", usize(1))
            base: **PsObj = (**PsObj)(ps_list_base(l))
            for i in range(i32(l->len)):
                if i > 0:
                    ps_repr_put(ref b, ",", usize(1))
                sub: char[64]
                snprintf(sub, usize(64), "%s[%d]", caminho, int(i))
                ps_json_any(ctx, ref b, base[i], sub, depth + 1)
                if ps_has_exc(ctx):
                    return
            ps_repr_put(ref b, "]", usize(1))
        case PS_TY_DICT:
            d: *PsDict = (*PsDict)(o)
            ps_repr_put(ref b, "{", usize(1))
            n: i64 = ps_dict_len(d)
            for i in range(i32(n)):
                if i > 0:
                    ps_repr_put(ref b, ",", usize(1))
                kp: **PsStr = (**PsStr)(ps_dict_key_at(d, i64(i)))
                ps_json_esc(ref b, *kp)
                ps_repr_put(ref b, ":", usize(1))
                vp: **PsObj = (**PsObj)(ps_dict_val_at(d, i64(i)))
                sub2: char[64]
                snprintf(sub2, usize(64), "%s.%d", caminho, int(i))
                ps_json_any(ctx, ref b, *vp, sub2, depth + 1)
                if ps_has_exc(ctx):
                    return
            ps_repr_put(ref b, "}", usize(1))
        case _:
            ps_json_bad(ctx, "um `any` que guarda algo que o JSON não tem", caminho)

private def ps_json_ty(ctx: *PsCtx, ref b: PsRepr, p: *void, ty: const *PsTy, caminho: const *char, depth: i32):
    if ty == None or p == None:
        ps_json_bad(ctx, "tipo desconhecido", caminho)
        return
    if depth > 64:
        # 64 níveis não é um limite de gosto: é o que separa "aninhado" de "um
        # ciclo", e um ciclo tem de parar com o CAMINHO onde parou
        ps_json_bad(ctx, "fundo demais (um ciclo?)", caminho)
        return
    k: i32 = ty->kind
    if k == 1:
        num: char[32]
        if ty->uns and (ty->width == 64 or ty->width == 0):
            snprintf(num, usize(32), "%llu", *(*u64)(p))
        else:
            snprintf(num, usize(32), "%lld", ps_ty_int(p, ty))
        ps_repr_put(ref b, num, strlen(num))
        return
    if k == 2:
        v: f64 = f64(*(*f32)(p)) if ty->width == 32 else *(*f64)(p)
        if v != v or v > 1.0e308 or v < -1.0e308:
            ps_json_bad(ctx, "JSON não tem NaN nem infinito", caminho)
            return
        fs: *PsStr = ps_str_from_float(ctx, v)
        ps_repr_put(ref b, fs->data, usize(fs->len))
        return
    if k == 3:
        if *(*i32)(p) != 0:
            ps_repr_put(ref b, "true", usize(4))
        else:
            ps_repr_put(ref b, "false", usize(5))
        return
    if k == 8:
        ps_json_desc(ctx, ref b, p, ty->desc, caminho, depth)
        return
    if k == 10:
        # o NOME da variante, não o número: o número é uma escolha de
        # compilação e o nome é o que significa alguma coisa do outro lado
        ev: i32 = *(*i32)(p)
        if ty->names != None and ev >= 0 and ev < ty->nnames:
            nm: *PsStr = ps_str_new(ctx, ty->names[ev], strlen(ty->names[ev]))
            ps_json_esc(ref b, nm)
            return
        ps_json_bad(ctx, "um enum fora das variantes que tem", caminho)
        return
    if k == 4 or k == 5 or k == 6 or k == 7 or k == 9:
        ps_json_val(ctx, ref b, *(**void)(p), ty, caminho, depth)
        return
    ps_json_bad(ctx, "isto não atravessa (uma função, um `any`?)", caminho)

private def ps_json_desc(ctx: *PsCtx, ref b: PsRepr, o: *void, d: const *PsDesc, caminho: const *char, depth: i32):
    if d == None or d->fields == None or d->at == None:
        ps_json_bad(ctx, "um tipo sem campos declarados", caminho)
        return
    ps_repr_put(ref b, "{", usize(1))
    for i in range(d->nfields):
        if i > 0:
            ps_repr_put(ref b, ",", usize(1))
        fn: const *char = d->fields[i].name
        ns: *PsStr = ps_str_new(ctx, fn, strlen(fn))
        ps_json_esc(ref b, ns)
        ps_repr_put(ref b, ":", usize(1))
        sub: char[128]
        snprintf(sub, usize(128), "%s.%s", caminho, fn)
        ps_json_ty(ctx, ref b, d->at(o, i), d->fields[i].ty, sub, depth + 1)
        if ps_has_exc(ctx):
            return
    ps_repr_put(ref b, "}", usize(1))

def ps_json_stringify(ctx: *PsCtx, o: *void, ty: const *PsTy, file: const *char, line: i32) -> *PsStr:
    b: PsRepr = {None, usize(0), usize(0)}
    ps_json_val(ctx, ref b, o, ty, "", 0)
    if ps_has_exc(ctx):
        free(b.data)
        return ps_str_new(ctx, "", usize(0))
    out: *PsStr = ps_str_new(ctx, b.data if b.data != None else "", b.len)
    free(b.data)
    return out

def ps_json_stringify_at(ctx: *PsCtx, p: *void, ty: const *PsTy, file: const *char, line: i32) -> *PsStr:
    b: PsRepr = {None, usize(0), usize(0)}
    ps_json_ty(ctx, ref b, p, ty, "", 0)
    if ps_has_exc(ctx):
        free(b.data)
        return ps_str_new(ctx, "", usize(0))
    out: *PsStr = ps_str_new(ctx, b.data if b.data != None else "", b.len)
    free(b.data)
    return out


# ---------- 140/F6: o descodificador INCREMENTAL ----------
#
# É o que o `CharsetDecoder` do NIO é: alimentar bytes e receber o texto que já
# dá para dizer, guardando o que ficou a meio de um codepoint.
#
# A política de erro é SUBSTITUIR por U+FFFD e continuar. Um fluxo não é um
# ficheiro: um byte solto no meio de uma saída não é motivo para o programa
# parar, e `str(b)` continua a ser a resposta estrita para quem quer a outra.

def ps_dec_new(ctx: *PsCtx) -> *PsDecoder:
    d: *PsDecoder = ps_alloc(ctx, sizeof(PsDecoder), PS_TY_DECODER)
    d->acc = u32(0)
    d->need = 0
    d->lo = u32(0)
    return d


def ps_dec_pending(d: *PsDecoder) -> i64:
    """Quantos bytes estão retidos à espera do resto do codepoint. Zero quer
    dizer que tudo o que entrou já saiu — que é a pergunta que quem escreve um
    protocolo faz antes de decidir que a mensagem acabou."""
    return i64(d->need) if d != None else i64(0)


def ps_dec_feed(ctx: *PsCtx, d: *PsDecoder, b: *PsBytes) -> *PsStr:
    n: usize = usize(b->len) if b != None else usize(0)
    # o pior caso é cada byte virar um U+FFFD, que são três bytes
    cap: usize = n * usize(3) + usize(4)
    buf: *char = (*char)(malloc(cap))
    if buf == None:
        return ps_str_new(ctx, "", 0)
    k: usize = 0
    i: usize = 0
    while i < n:
        x: u32 = u32(u8(b->data[i]))
        i += 1
        if d->need > 0:
            if x >= u32(0x80) and x < u32(0xC0):
                d->acc = (d->acc << 6) | (x & u32(0x3F))
                d->need -= 1
                if d->need == 0:
                    cp: u32 = d->acc
                    # o que uma sequência bem formada NÃO pode ser: curta
                    # demais para o que codifica, um substituto, ou acima do
                    # último plano. As três dão o mesmo U+FFFD.
                    if cp < d->lo or (cp >= u32(0xD800) and cp <= u32(0xDFFF)) or cp > u32(0x10FFFF):
                        k = ps_utf8_put(buf, k, 0xFFFD)
                    else:
                        k = ps_utf8_put(buf, k, i32(cp))
                continue
            # a sequência partiu-se, e o byte que a partiu ainda é um byte: cai
            # um U+FFFD pelo que se perdeu e este byte é lido outra vez, do
            # princípio — largá-lo em silêncio engoliria saída de verdade
            d->need = 0
            k = ps_utf8_put(buf, k, 0xFFFD)
            i -= 1
            continue
        if x < u32(0x80):
            buf[k] = char(x)
            k += usize(1)
        elif x >= u32(0xC2) and x < u32(0xE0):
            # 0xC0 e 0xC1 nunca são legais: só codificariam ASCII em dois bytes
            d->acc = x & u32(0x1F)
            d->need = 1
            d->lo = u32(0x80)
        elif x >= u32(0xE0) and x < u32(0xF0):
            d->acc = x & u32(0x0F)
            d->need = 2
            d->lo = u32(0x800)
        elif x >= u32(0xF0) and x < u32(0xF5):
            d->acc = x & u32(0x07)
            d->need = 3
            d->lo = u32(0x10000)
        else:
            k = ps_utf8_put(buf, k, 0xFFFD)
    s: *PsStr = ps_str_new(ctx, buf, k)
    free(buf)
    return s


def ps_dec_finish(ctx: *PsCtx, d: *PsDecoder) -> *PsStr:
    """O fim do fluxo. Uma sequência a meio nunca vai ser completada, portanto o
    que sobrou é exactamente um caractere perdido."""
    if d == None or d->need == 0:
        return ps_str_new(ctx, "", 0)
    d->need = 0
    buf: char[8]
    k: usize = ps_utf8_put(buf, usize(0), 0xFFFD)
    return ps_str_new(ctx, buf, k)


# 22.2: `==` compara CONTEÚDO, e uma lista não era excepção — era um esquecimento.
#
# Antes disto, `[1, 2, 3] == [1, 2, 3]` respondia False, porque o que saía era
# uma comparação de PONTEIROS. É o mesmo engano que a 55.4 já tinha proibido no
# `in`, e a regra é a mesma: texto compara texto, o resto compara bytes.
#
# `kind` é `PS_K_STR` quando os elementos são strings, e o compilador é quem
# sabe — o runtime só move bytes.
def ps_list_eq(a: *PsList, b: *PsList, kind: i32) -> bool:
    if a == None or b == None:
        return a == b
    if a->len != b->len:
        return False
    if a->esize != b->esize:
        return False
    pa: *char = ps_list_base(a)
    pb: *char = ps_list_base(b)
    i: i64 = 0
    while i < a->len:
        oa: *char = pa + usize(i) * usize(a->esize)
        ob: *char = pb + usize(i) * usize(b->esize)
        if kind == PS_K_STR:
            if not ps_str_eq(*(**PsStr)(oa), *(**PsStr)(ob)):
                return False
        elif memcmp(oa, ob, usize(a->esize)) != 0:
            return False
        i += 1
    return True
# ---------- S2b/152.6: o Unicode que o motor de regex pede ----------
#
# As duas tabelas já existiam — `unicase.bin` e `unicat.bin`, geradas e conferidas
# por um oráculo que varre todo o ponto de código (105). O que faltava era uma
# porta: o motor mora na camada da biblioteca e os leitores são privados desta.

def ps_cp_fold(cp: i32) -> i32:
    """A dobra de caixa SIMPLES: a minúscula de um ponto de código, ou ele
    próprio.

    **Simples e não completa**, e é a escolha do RE2 e do `regexp` do Go — não
    uma limitação nossa. A dobra completa mapeia `ß` para `ss`, ou seja UM
    caractere para DOIS, e um autómato que anda um caractere de cada vez não tem
    como casar dois de entrada contra um do padrão sem guardar o que já leu — que
    é exactamente a propriedade que ele não tem, e a razão de ser linear.
    """
    return tb_map(&PS_CASE[0], UC_LO, cp)

# As categorias, pelos nomes que o `\p{...}` usa. `which` é um dos `PS_UCAT_*`.
def ps_cp_in_cat(cp: i32, which: i32) -> bool:
    if which == PS_UCAT_L:
        return tb_in(&PS_CAT[0], CA_ALPHA, cp)
    if which == PS_UCAT_LU:
        return tb_in(&PS_CAT[0], CA_UPPER, cp)
    if which == PS_UCAT_LL:
        return tb_in(&PS_CAT[0], CA_LOWER, cp)
    if which == PS_UCAT_LT:
        return tb_in(&PS_CAT[0], CA_TITLECHAR, cp)
    if which == PS_UCAT_N:
        return tb_in(&PS_CAT[0], CA_DECIMAL, cp) or tb_in(&PS_CAT[0], CA_DIGIT, cp) or tb_in(&PS_CAT[0], CA_NUMERIC, cp)
    if which == PS_UCAT_ND:
        return tb_in(&PS_CAT[0], CA_DECIMAL, cp)
    if which == PS_UCAT_ALNUM:
        return tb_in(&PS_CAT[0], CA_ALPHA, cp) or tb_in(&PS_CAT[0], CA_DECIMAL, cp) or tb_in(&PS_CAT[0], CA_DIGIT, cp) or tb_in(&PS_CAT[0], CA_NUMERIC, cp)
    if which == PS_UCAT_SPACE:
        return ps_str_is_space_cp(cp)
    return False

