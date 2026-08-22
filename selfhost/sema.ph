# sema.ph — stage 5 of the pipeline: semantic analysis.
# Resolves casts T(x), method sugar p.m() -> Struct_m(&p),
# fixes ./->, registers symbols and loads imported modules (.ph).
import "plang.ph"
import "ast.ph"

# Global compiler context: arena + cache of parsed modules.
# 109: o dump de macros de um header do sistema, guardado por caminho. Um PAR
# num vetor só, e não dois vetores paralelos: `vec_grow` recebe UMA capacidade
# por referência, então dois vetores com a mesma capacidade fazem o segundo nunca
# crescer — o primeiro cresce, escreve a capacidade nova, e o segundo se acha
# grande. Foi exatamente o defeito que a suíte pegou aqui.
struct MacroDump:
    path: const *char
    text: const *char

struct Cc:
    arena: Arena
    mods: **Module
    nmods: i32
    cmods: i32
    defines: **char      # consts injected by the driver (-D NAME=VALUE)
    ndefines: i32
    backend_name: const *char   # active backend ("c"/"qbe") for __PLANG_BACKEND__
    std_version: i32     # target of the C backend: 99 (default) or 89 (--std=c89)
    cpp: const *char     # C compiler used to preprocess `include <h>` headers
                         #   (--cpp flag / PLANGC_CPP env; default "cc")
    inline_runtime: bool # --inline-runtime: compiler-injected helpers (the `in`
                         #   lowering's strcmp) become SELF-CONTAINED inline P
                         #   functions — no libc dependency in the output
    # 109: o texto do dump de macros de cada header do sistema, por caminho. O
    # PARSE do header já era cacheado; o dump (`cc -E -dM`) rodava uma vez por
    # MÓDULO que o inclui, e num programa de vários módulos isso é meio segundo
    # cada. Medido ao dividir o runtime em cinco camadas: 0,94 s viraram 4,08 s,
    # e 2,5 s eram cpp repetido. O registro em si continua por módulo (as
    # constantes são estado da sema); o que se guarda aqui é a CAPTURA.
    macs: *MacroDump
    nmac: i32
    cmac: i32
    # As RAÍZES de pacote (`--pkg-path`, repetível). Um `import <pkg/mod.ph>` é
    # procurado em cada uma, na ordem em que foram dadas, e a primeira que tiver
    # o arquivo ganha — a mesma regra do `-I` do C, e pela mesma razão: é a
    # única que dá para explicar numa linha.
    #
    # NÃO há recuo para caminho relativo. `<>` e `"..."` não se misturam: um diz
    # "isto vem de um pacote", o outro diz "isto está ao meu lado", e deixar o
    # primeiro cair no segundo faria um programa compilar por acidente com o
    # arquivo errado. A ambiguidade silenciosa foi recusada de propósito.
    pkgroots: **char
    npkgroots: i32

# Onde um `import <pkg/mod.ph>` está, procurando nas raízes de `--pkg-path`.
# Levanta com a lista das raízes quando não acha.
def pkg_resolve(cc: *Cc, file: const *char, d: *Decl) -> const *char

# Reads, decodes, lexes and parses a file (with cache by path).
def cc_load_module(cc: *Cc, path: const *char) -> *Module

# Runs sema on the module (resolving local .ph imports recursively).
# Mutates the AST: rewrites casts, method calls and ./-> operators.
def sema_run(cc: *Cc, m: *Module)
def cpp_capture_ex(a: *Arena, cpp_cmd: const *char, flags: const *char, path: const *char, is_sys: bool, dir: const *char) -> const *char

# the value of an object-like #define whose right side is an integer literal —
# the same reader on both boundaries (72.4)
def macro_int_val(txt: const *char, out: *i64) -> bool
