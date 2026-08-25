# api.p — a lista canónica da API de um módulo (ver api.ph para o contrato).
#
# Impressor PRÓPRIO, e não o do `backend_p`, de propósito: o que sai daqui é um
# formato ESTÁVEL que outros programas vão hashear e diffar, e amarrá-lo ao
# pretty-printer do P faria uma melhoria de formatação no impressor virar
# "a interface mudou" para o mundo inteiro.
include <string.h>
import "plang.ph"
import "ast.ph"
import "api.ph"
import "ps_ast.ph"
import <stl/hash.ph>

private def a_type(b: *StrBuf, t: *Type, no_const: bool = False)
private def a_doc(b: *StrBuf, owner: const *char, name: const *char, doc: const *char)
private def a_expr(b: *StrBuf, e: *Expr)

# ---------- operadores ----------
# A grafia canónica de cada operador. Não se reusa `tok_kind_name` porque a dele
# é para MENSAGEM ("'+'", "end of file"), e esta é para o formato.
private def a_op(op: i32) -> const *char:
    match TokKind(op):
        case TK_PLUS:
            return "+"
        case TK_MINUS:
            return "-"
        case TK_STAR:
            return "*"
        case TK_SLASH:
            return "/"
        case TK_PERCENT:
            return "%"
        case TK_AMP:
            return "&"
        case TK_PIPE:
            return "|"
        case TK_CARET:
            return "^"
        case TK_TILDE:
            return "~"
        case TK_SHL:
            return "<<"
        case TK_SHR:
            return ">>"
        case TK_LT:
            return "<"
        case TK_LE:
            return "<="
        case TK_GT:
            return ">"
        case TK_GE:
            return ">="
        case TK_EQ:
            return "=="
        case TK_NE:
            return "!="
        case TK_AND:
            return " and "
        case TK_OR:
            return " or "
        case TK_NOT:
            return "not "
        case TK_IS:
            return " is "
        case TK_ISNOT:
            return " is not "
        case TK_DOT:
            return "."
        case TK_ARROW:
            return "->"
        case _:
            return "?"

# ---------- tipos ----------
# A grafia do P: prefixo para ponteiro (`*T`), qualificador antes da estrela
# (`const *char`), genéricos entre sinais de menor (`Vec<Param>`).
private def a_type(b: *StrBuf, t: *Type, no_const: bool = False):
    if t == None:
        b->puts("void")
        return
    match t->kind:
        case TY_PTR:
            if t->is_ref:
                b->puts("ref ")
                a_type(b, t->inner)
                return
            # `def(...) -> R` já É um TY_PTR(TY_FUNC): uma estrela aqui faria
            # ponteiro para ponteiro de função
            if t->inner != None and t->inner->kind == TY_FUNC:
                a_type(b, t->inner)
                return
            if t->inner != None and t->inner->kind == TY_ARRAY:
                b->puts("*(")
                a_type(b, t->inner)
                b->putc(')')
                return
            # a grafia do FONTE hoista o `const` da base para a frente
            # (`const *char`), e um ponteiro const — que só chega aqui vindo do
            # C — sai como `*const char`. As duas formas são distintas de
            # propósito: um texto que existe para ser hasheado não pode ter duas
            # coisas com a mesma grafia.
            hoist: bool = False
            if not no_const:
                base2: *Type = t
                while base2 != None and base2->kind == TY_PTR:
                    base2 = base2->inner
                if base2 != None and base2->kind == TY_NAME and base2->is_const:
                    hoist = True
            if hoist:
                b->puts("const ")
            if t->is_restrict:
                b->puts("restrict ")
            b->putc('*')
            if t->is_const:
                b->puts("const ")
            a_type(b, t->inner, hoist or no_const)
        case TY_ARRAY:
            # `T[8][64]` é um array de 8 arrays de 64: a árvore aninha de fora
            # para dentro e a ORDEM DO FONTE é a mesma
            base: *Type = t
            while base != None and base->kind == TY_ARRAY:
                base = base->inner
            a_type(b, base)
            dim: *Type = t
            while dim != None and dim->kind == TY_ARRAY:
                b->putc('[')
                if dim->arr_len != None:
                    a_expr(b, dim->arr_len)
                b->putc(']')
                dim = dim->inner
        case TY_FUNC:
            b->puts("def(")
            for i in range(t->ntargs):
                if i != 0:
                    b->puts(", ")
                a_type(b, t->targs[i])
            b->putc(')')
            if not (t->inner == None or (t->inner->kind == TY_NAME and t->inner->name == "void")):
                b->puts(" -> ")
                a_type(b, t->inner)
        case _:
            if t->is_const and not no_const:
                b->puts("const ")
            if t->is_volatile:
                b->puts("volatile ")
            match t->tag_kind:
                case TAG_STRUCT:
                    b->puts("struct ")
                case TAG_UNION:
                    b->puts("union ")
                case TAG_ENUM:
                    b->puts("enum ")
                case _:
                    pass
            b->puts(t->name if t->name != None else "void")
            if t->ntargs > 0:
                b->putc('<')
                for j in range(t->ntargs):
                    if j != 0:
                        b->puts(", ")
                    a_type(b, t->targs[j])
                b->putc('>')

# ---------- expressões ----------
# Só aparecem em posição de INTERFACE: dimensão de array, valor de item de enum
# e inicializador de const pública. As três mudam o que quem depende enxerga, e
# por isso entram. O que não tem grafia própria vira uma forma de prefixo com o
# nome do nó — feia de ler e IMPOSSÍVEL de perder uma mudança, que é o que
# importa num texto que existe para ser hasheado.
private def a_expr(b: *StrBuf, e: *Expr):
    if e == None:
        b->puts("()")
        return
    match e->kind:
        case EX_IDENT, EX_NUMBER, EX_STRING, EX_CHARLIT:
            b->puts(e->text if e->text != None else "?")
        case EX_TRUE:
            b->puts("True")
        case EX_FALSE:
            b->puts("False")
        case EX_NONE:
            b->puts("None")
        case EX_UNARY:
            b->puts(a_op(e->op))
            a_expr(b, e->lhs)
        case EX_BINARY:
            b->putc('(')
            a_expr(b, e->lhs)
            b->puts(a_op(e->op))
            a_expr(b, e->rhs)
            b->putc(')')
        case EX_TERNARY:
            b->putc('(')
            a_expr(b, e->lhs)
            b->puts(" if ")
            a_expr(b, e->cond)
            b->puts(" else ")
            a_expr(b, e->rhs)
            b->putc(')')
        case EX_CALL:
            a_expr(b, e->lhs)
            b->putc('(')
            for i in range(e->nargs):
                if i != 0:
                    b->puts(", ")
                a_expr(b, e->args[i])
            b->putc(')')
        case EX_INDEX:
            a_expr(b, e->lhs)
            b->putc('[')
            a_expr(b, e->rhs)
            b->putc(']')
        case EX_FIELD:
            a_expr(b, e->lhs)
            b->puts(a_op(e->op))
            b->puts(e->field if e->field != None else "?")
        case EX_CAST:
            a_type(b, e->cast_type)
            b->putc('(')
            a_expr(b, e->lhs)
            b->putc(')')
        case EX_TYPEREF:
            a_type(b, e->cast_type)
        case EX_INITLIST:
            b->putc('{')
            for j in range(e->nargs):
                if j != 0:
                    b->puts(", ")
                a_expr(b, e->args[j])
            b->putc('}')
        case EX_DESIG:
            if e->field != None:
                b->putc('.')
                b->puts(e->field)
            else:
                b->putc('[')
                a_expr(b, e->rhs)
                b->putc(']')
            b->puts(" = ")
            a_expr(b, e->lhs)
        case _:
            # forma de prefixo: nada se perde, nem que fique feio
            b->printf("(k%d", i32(e->kind))
            if e->lhs != None:
                b->putc(' ')
                a_expr(b, e->lhs)
            if e->rhs != None:
                b->putc(' ')
                a_expr(b, e->rhs)
            for k in range(e->nargs):
                b->putc(' ')
                a_expr(b, e->args[k])
            b->putc(')')

# ---------- declarações ----------
private def a_tparams(b: *StrBuf, names: **char, bounds: **char, n: i32):
    if n <= 0:
        return
    b->putc('<')
    for i in range(n):
        if i != 0:
            b->puts(", ")
        b->puts(names[i])
        if bounds != None and bounds[i] != None:
            b->puts(": ")
            b->puts(bounds[i])
    b->putc('>')

# A assinatura de uma função: TIPOS, nunca nomes de parâmetro. O marcador
# `out`/`ref`/`in` entra porque ele muda o SÍTIO DA CHAMADA, e o valor padrão
# entra porque ele deixa o argumento ser omitido — as duas coisas são interface.
private def a_func(b: *StrBuf, f: *Func, owner: const *char):
    b->puts("def ")
    if owner != None:
        b->puts(owner)
        b->putc('.')
    b->puts(f->name if f->name != None else "?")
    a_tparams(b, f->tparams, f->tbounds, f->ntparams)
    b->putc('(')
    for i in range(f->nparams):
        if i != 0:
            b->puts(", ")
        p: *Param = &f->params[i]
        match p->byref:
            case 1:
                b->puts("out ")
            case 2:
                b->puts("ref ")
            case 3:
                b->puts("in ")
            case _:
                pass
        a_type(b, p->type)
        if p->dflt != None:
            b->puts(" = ")
            a_expr(b, p->dflt)
    if f->is_varargs:
        if f->nparams > 0:
            b->puts(", ")
        b->puts("...")
    b->putc(')')
    if not (f->ret == None or (f->ret->kind == TY_NAME and f->ret->name == "void")):
        b->puts(" -> ")
        a_type(b, f->ret)
    b->putc('\n')

private def a_agg(b: *StrBuf, d: *Decl, word: const *char):
    b->puts(word)
    b->putc(' ')
    b->puts(d->name if d->name != None else "?")
    a_tparams(b, d->tparams, d->tbounds, d->ntparams)
    if d->is_fwd:
        b->puts(" (fwd)\n")
        return
    b->puts(" {")
    for i in range(d->nfields):
        if i != 0:
            b->puts(", ")
        fl: *Field = &d->fields[i]
        b->puts(fl->name if fl->name != None else "_")
        b->puts(": ")
        a_type(b, fl->type)
        if fl->bit_width >= 0:
            b->printf(":%d", fl->bit_width)
    b->puts("}\n")
    for j in range(d->nmethods):
        a_func(b, d->methods[j], d->name)

# uma declaração é PÚBLICA quando outro módulo pode nomeá-la. Num `.ph` tudo é
# interface (um header existe para ser lido de fora); num `.p`, o que não é
# `private` — que é a palavra que este projeto acabou de adotar no lugar de
# `static`, e que vira `static` no C emitido.
private def a_is_public(d: *Decl, is_header: bool) -> bool:
    if is_header:
        return True
    match d->kind:
        case DL_FUNC:
            return d->func != None and not d->func->is_static
        case DL_VAR:
            return not d->is_static
        case _:
            return True

# `#doc <símbolo> <texto>` — uma linha, com a quebra escapada. Sem docstring,
# nenhuma linha: um símbolo sem documentação não ocupa espaço no relatório.
private def a_doc(b: *StrBuf, owner: const *char, name: const *char, doc: const *char):
    if doc == None or doc[0] == '\0':
        return
    # o front end do pscript guarda a docstring COM as aspas (46.3) e o do P sem
    # elas; aqui a resposta é uma só, então as aspas caem de qualquer um dos dois
    n0: usize = strlen(doc)
    if n0 >= 6 and doc[0] == '"' and doc[1] == '"' and doc[2] == '"':
        doc = doc + 3
        n0 -= 6
    elif n0 >= 2 and doc[0] == '"':
        doc = doc + 1
        n0 -= 2
    else:
        n0 = strlen(doc)
    if owner != None:
        b->printf("#doc %s.%s ", owner, name)
    else:
        b->printf("#doc %s ", name)
    i: usize = 0
    n: usize = n0
    while i < n:
        c: char = doc[i]
        if c == '\n':
            b->puts("\\n")
        elif c == '\\':
            b->puts("\\\\")
        else:
            b->putc(c)
        i += 1
    b->putc('\n')

# ---------- a API de um módulo PSCRIPT ----------
# A resposta 5 de um `.psc` sai da árvore da PRÓPRIA LINGUAGEM, e não da baixa.
#
# A razão é que a baixa não é a interface: ela funde o prelúdio e os módulos
# importados, inventa um `struct` de quadro por `async def`, troca `str` por
# `*PsStr` e põe um `*PsCtx` na frente de toda assinatura. Nada disso é o que
# quem usa o módulo escreve, e o hash de tudo isso mudava quando o RUNTIME
# mudava — o que faz a pergunta "a minha interface mudou?" responder errado.
#
# Aqui sai o que o módulo declara, com a grafia com que foi declarado.
private def p_type(b: *StrBuf, t: *PsType)
private def p_func(b: *StrBuf, f: *PsFunc, owner: const *char)

private def p_type(b: *StrBuf, t: *PsType):
    if t == None:
        b->puts("void")
        return
    match t->kind:
        case PT_INT:
            if t->width == 0:
                b->puts("int")
            else:
                b->printf("%c%d", 'u' if t->uns else 'i', t->width)
        case PT_FLOAT:
            b->puts("float" if t->width == 0 else "f32")
        case PT_BOOL:
            b->puts("bool")
        case PT_STR:
            b->puts("str")
        case PT_ANY:
            b->puts("any")
        case PT_VOID:
            b->puts("void")
        case PT_NAME:
            if t->qual != None:
                b->printf("%s.", t->qual)
            b->puts(t->name if t->name != None else "?")
        case PT_LIST:
            b->puts("List<")
            p_type(b, t->inner)
            b->putc('>')
        case PT_SET:
            b->puts("Set<")
            p_type(b, t->inner)
            b->putc('>')
        case PT_DICT:
            b->puts("Dict<")
            p_type(b, t->key)
            b->puts(", ")
            p_type(b, t->inner)
            b->putc('>')
        case PT_OPT:
            p_type(b, t->inner)
            b->putc('?')
        case PT_ARRAY:
            p_type(b, t->inner)
            b->puts("[]")
        case PT_TUPLE:
            b->putc('(')
            for i in range(t->nparams):
                if i > 0:
                    b->puts(", ")
                p_type(b, t->params[i])
            b->putc(')')
        case PT_FUNC:
            b->puts("def(")
            for i in range(t->nparams):
                if i > 0:
                    b->puts(", ")
                p_type(b, t->params[i])
            b->puts(") -> ")
            p_type(b, t->inner)
        case PT_TASK:
            b->puts("Task<")
            p_type(b, t->inner)
            b->putc('>')
        case PT_WORKER:
            b->puts("Worker<")
            p_type(b, t->inner)
            b->putc('>')
        case PT_BYTES:
            b->puts("bytes")
        case PT_MAPPING:
            b->puts("Mapping")
        case PT_DECODER:
            b->puts("Decoder")
        case PT_VIEW:
            b->puts("View<")
            p_type(b, t->inner)
            b->putc('>')
        case PT_FILE:
            b->puts("File")
        case PT_BUFFER:
            b->puts("Buffer")
        case PT_CONN:
            b->puts("Socket")
        case PT_PROC:
            b->puts("proc")
        case PT_TIMER:
            b->puts("Timer")
        case PT_DYN:
            b->puts("dyn ")
            b->puts(t->name if t->name != None else "?")
        case _:
            b->puts("?")

private def p_func(b: *StrBuf, f: *PsFunc, owner: const *char):
    b->puts("async def " if f->is_async else "def ")
    if owner != None:
        b->printf("%s.", owner)
    b->puts(f->name if f->name != None else "?")
    b->putc('(')
    first: bool = True
    for i in range(f->nparams):
        # o receptor não é parte da assinatura de quem chama
        if owner != None and i == 0 and f->params[i].name != None and strcmp(f->params[i].name, "self") == 0:
            continue
        if not first:
            b->puts(", ")
        first = False
        p_type(b, f->params[i].type)
    b->puts(") -> ")
    p_type(b, f->ret)
    b->putc('\n')

# público de um módulo pscript é o que NÃO é `private` (44.4) — a mesma noção
# que o resto do compilador usa, e uma só para tudo
private def ps_public(d: *PsDecl) -> bool:
    if d->kind == PD_FUNC and d->func != None:
        return not d->func->is_private
    return not d->is_private

def ps_api_dump(m: *PsModule, b: *StrBuf):
    b->printf("== %s\n", m->path)
    start: usize = b->len
    for i in range(m->ndecls):
        d: *PsDecl = m->decls[i]
        if not ps_public(d):
            continue
        match d->kind:
            case PD_IMPORT:
                b->printf("import %s\n", d->path if d->path != None else "?")
            case PD_INCLUDE:
                if d->is_pmod:
                    b->printf("import \"%s\"\n", d->path if d->path != None else "?")
                else:
                    b->printf("include <%s>\n", d->path if d->path != None else "?")
            case PD_ENUM:
                b->printf("enum %s {", d->name)
                for j in range(d->nitems):
                    if j > 0:
                        b->puts(", ")
                    b->puts(d->items[j].name)
                b->puts("}\n")
            case PD_RECORD, PD_STRUCT:
                b->printf("%s %s {", "record" if d->kind == PD_RECORD else "struct", d->name)
                for j in range(d->nfields):
                    if j > 0:
                        b->puts(", ")
                    b->printf("%s: ", d->fields[j].name)
                    p_type(b, d->fields[j].type)
                b->puts("}\n")
                for j in range(d->nmethods):
                    if not d->methods[j]->is_private:
                        p_func(b, d->methods[j], d->name)
            case PD_TRAIT:
                b->printf("trait %s\n", d->name)
                for j in range(d->nmethods):
                    p_func(b, d->methods[j], d->name)
            case PD_FUNC:
                if d->func != None:
                    p_func(b, d->func, None)
            case PD_VAR:
                b->printf("%s %s: ", "const" if d->is_const else "var", d->name)
                p_type(b, d->type)
                b->putc('\n')
            case _:
                pass
    h: u64 = hash_bytes(b->data + start, b->len - start)
    b->printf("#hash %016llx\n", h)
    # as docstrings DEPOIS do hash, pela mesma razão do lado P: mudar um texto
    # de documentação não muda a interface
    a_doc(b, None, ".", m->doc)
    for i in range(m->ndecls):
        d2: *PsDecl = m->decls[i]
        if not ps_public(d2):
            continue
        if d2->kind == PD_FUNC and d2->func != None:
            a_doc(b, None, d2->func->name, d2->func->doc)
            continue
        if d2->name == None:
            continue
        a_doc(b, None, d2->name, d2->doc)
        for j in range(d2->nmethods):
            a_doc(b, d2->name, d2->methods[j]->name, d2->methods[j]->doc)

def api_dump(m: *Module, b: *StrBuf):
    b->printf("== %s\n", m->path)
    start: usize = b->len
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        if not a_is_public(d, m->is_header):
            continue
        match d->kind:
            case DL_IMPORT:
                # o que um módulo importa é interface dele: um consumidor herda
                # os tipos que vieram por ali
                if d->is_include:
                    b->printf("include <%s>\n", d->import_path)
                elif d->import_system:
                    b->printf("import <%s>\n", d->import_path)
                else:
                    b->printf("import \"%s\"", d->import_path)
                    if d->import_alias != None:
                        b->printf(" as %s", d->import_alias)
                    b->putc('\n')
            case DL_FUNC:
                # um protótipo e a definição da mesma função são UM símbolo. A
                # declaração adiantada existe para a recursão mútua e para o
                # `.ph`; a interface não tem duas de nada.
                if d->func != None and not d->func->is_comptime:
                    dup: bool = False
                    for pj in range(i):
                        pd: *Decl = m->decls[pj]
                        if pd->kind == DL_FUNC and pd->func != None and pd->func->name != None and d->func->name != None:
                            if strcmp(pd->func->name, d->func->name) == 0:
                                dup = True
                                break
                    if not dup:
                        a_func(b, d->func, None)
            case DL_STRUCT:
                a_agg(b, d, "record" if d->is_record else "struct")
            case DL_UNION:
                a_agg(b, d, "union")
            case DL_TRAIT:
                b->printf("trait %s", d->name if d->name != None else "?")
                if d->assoc != None:
                    b->printf(" (type %s)", d->assoc)
                b->puts(" {")
                for j in range(d->nmethods):
                    b->putc(' ')
                    a_func(b, d->methods[j], None)
                b->puts("}\n")
            case DL_ENUM:
                b->printf("enum %s {", d->name if d->name != None else "?")
                for k in range(d->nitems):
                    if k != 0:
                        b->puts(", ")
                    b->puts(d->items[k].name)
                    if d->items[k].value != None:
                        b->puts(" = ")
                        a_expr(b, d->items[k].value)
                b->puts("}\n")
            case DL_VAR:
                # uma const pública é substituída em quem a usa: o VALOR é
                # interface. Uma variável global exporta só o símbolo e o tipo.
                b->puts("const " if d->is_const else "var ")
                b->puts(d->name if d->name != None else "?")
                b->puts(": ")
                a_type(b, d->type)
                if d->is_const and d->init != None:
                    b->puts(" = ")
                    a_expr(b, d->init)
                b->putc('\n')
            case DL_DECLARE:
                b->printf("declare %s\n", d->name if d->name != None else "?")
            case DL_IMPLEMENT:
                b->printf("implement %s", d->name if d->name != None else "?")
                if d->trait_for != None:
                    b->printf(" for %s", d->trait_for)
                b->putc('\n')
            case _:
                pass
    # o hash é sobre a lista DESTE módulo, não sobre o arquivo: é o que permite
    # dizer "a interface não mudou" sem comparar texto nenhum
    h: u64 = hash_bytes(b->data + start, b->len - start)
    b->printf("#hash %016llx\n", h)
    # As DOCSTRINGS vêm DEPOIS do hash, e é essa a decisão que importa: mudar a
    # documentação de uma função não muda a interface dela, e um consumidor que
    # só quer saber "o que eu uso mudou?" não pode ser acordado por uma vírgula
    # num comentário. Elas ficam aqui para quem QUER a documentação — a IDE, o
    # `pforge doc`, o gerador de site — e o hash acima continua estrutural.
    #
    # Uma linha por símbolo, com a quebra escapada: o formato é de linhas, e uma
    # docstring de dez linhas não pode virar dez registros.
    a_doc(b, None, ".", m->doc)
    for i in range(m->ndecls):
        d: *Decl = m->decls[i]
        if not a_is_public(d, m->is_header):
            continue
        if d->kind == DL_FUNC and d->func != None:
            # a baixa do pscript emite PROTÓTIPO e definição para a mesma
            # função, e as duas carregam a docstring — sem esta linha ela sairia
            # duas vezes. Num header, porém, o protótipo É a declaração.
            if d->func->body == None and not m->is_header:
                continue
            a_doc(b, None, d->func->name, d->func->doc)
            continue
        if d->name == None:
            continue
        a_doc(b, None, d->name, d->doc)
        for j in range(d->nmethods):
            a_doc(b, d->name, d->methods[j]->name, d->methods[j]->doc)
