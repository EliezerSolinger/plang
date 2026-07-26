# complete.ph — the completion index: what the editor knows about a file.
#
# It is built with the COMPILER'S OWN LEXER in tolerant mode (lex_ex), which is
# why it works on a half-typed buffer: real P tokens, so strings, comments and
# numbers never pollute the candidates. From the token stream it recovers
# declarations (`def f(...)`, `struct S:` and its members, `x: T`) and, for the
# `.`/`->` case, the type of a variable — that is what turns "words in the
# file" into member completion.
#
# It also indexes the .ph files the buffer imports, so completing a type from
# the STL or from another module works.
#
# What it is NOT: a type checker. Full expression typing needs a tolerant
# parser plus sema over the buffer; when that exists it plugs in behind the
# same query API.
include <stddef.h>
import "core.ph"
import "../stl/vec.ph"

enum SymKind:
    SYM_KEYWORD       # the language's own words
    SYM_WORD          # an identifier seen in the file (Sublime's baseline)
    SYM_TYPE          # struct / enum / union
    SYM_FUNC          # def at file scope
    SYM_MEMBER        # field or method of a struct

struct CSym:
    name: *char       # what gets inserted
    detail: *char     # shown dimmed on the right (signature, type); may be None
    owner: *char      # SYM_MEMBER: the struct it belongs to
    kind: SymKind

# `name: Type` seen at statement level — the bridge from `x.` to Type's members
struct CVar:
    name: *char
    type_name: *char

declare Vec<CSym>
declare Vec<CVar>
declare Vec<i32>

struct Index:
    syms: Vec<CSym>
    vars: Vec<CVar>
    version: u64      # the buffer version this was built from
    ready: bool

    def init(out self: Index)
    def deinit(ref self: Index)
    # (re)builds from the buffer and the .ph files it imports; `path` is the
    # buffer's own path (None for an unsaved buffer) and anchors the imports
    def build(ref self: Index, ref b: Buffer, path: const *char)
    def is_stale(in self: Index, ref b: Buffer) -> bool

    # indices into `syms` that complete `prefix`, best first. `owner != None`
    # restricts to that struct's members (the `x.` case).
    def query(in self: Index, prefix: const *char, owner: const *char, ref out_hits: Vec<i32>)
    def sym(in self: Index, i: i32) -> *CSym
    # the struct whose members `expr` exposes: a variable's declared type, or
    # the name itself when it IS a type. None when unknown.
    def owner_of(in self: Index, expr: const *char) -> const *char
