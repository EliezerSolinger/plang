# the completion index: declarations recovered from the compiler's own lexer
# (tolerant mode), member completion through `x: Type`, and imported headers.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/complete.ph"
import "../../pstudio/psys.ph"

SRC: const *char = "import \"lib.ph\"\n\nstruct Point:\n    x: i32\n    y: i32\n    def dist(in self: Point) -> i32\n\ndef make_point(a: i32) -> Point:\n    p: Point\n    total: i32 = 0\n    return p\n"

LIB: const *char = "struct Color:\n    r: u8\n    g: u8\n\ndef color_mix(a: Color, b: Color) -> Color\n"

static def show(in ix: Index, prefix: const *char, owner: const *char):
    hits: Vec<i32>
    hits.init()
    ix.query(prefix, owner, ref hits)
    printf("[%s%s] %d:", owner if owner != None else "", prefix, hits.len)
    for i in range(hits.len):
        if i == 6:
            printf(" …")
            break
        printf(" %s", ix.sym(hits.data[i])->name)
    printf("\n")
    hits.deinit()

def main() -> int:
    sh: *char
    ps_run("rm -rf cproj && mkdir -p cproj", out sh)
    free(sh)
    v: Vfs = vfs_local()
    vfs_write_all(in v, "cproj/main.p", SRC, strlen(SRC))
    vfs_write_all(in v, "cproj/lib.ph", LIB, strlen(LIB))

    b: Buffer
    b.init()
    b.load(SRC, strlen(SRC))
    ix: Index
    ix.init()
    printf("stale_before=%d\n", ix.is_stale(ref b))
    ix.build(ref b, "cproj/main.p")
    printf("stale_after=%d syms=%d vars=%d\n", ix.is_stale(ref b), ix.syms.len, ix.vars.len)

    # declarations of the file itself
    show(in ix, "make", None)
    show(in ix, "Poi", None)
    # members only show up behind an owner
    show(in ix, "", "Point")
    # `p: Point` bridges the variable to its type
    printf("owner(p)=%s owner(Point)=%s owner(nope)=%s\n",
           ix.owner_of("p"), ix.owner_of("Point"),
           ix.owner_of("nope") if ix.owner_of("nope") != None else "-")
    show(in ix, "d", ix.owner_of("p"))
    # the imported header contributes its declarations
    show(in ix, "col", None)
    show(in ix, "", "Color")
    # words of the buffer and keywords are there too
    show(in ix, "tot", None)
    show(in ix, "whi", None)
    # a signature is kept for the popup's right column
    hits: Vec<i32>
    hits.init()
    ix.query("make", None, ref hits)
    printf("detail=[%s]\n", ix.sym(hits.data[0])->detail)
    hits.deinit()

    # a half-typed buffer must still index (the lexer is tolerant)
    b.load("def f(:\n    x: Point\nstruct \"broken\n", 38)
    ix.build(ref b, "cproj/main.p")
    printf("broken: ok=%d owner(x)=%s\n", ix.ready, ix.owner_of("x"))

    ix.deinit()
    b.deinit()
    ps_run("rm -rf cproj", out sh)
    free(sh)
    printf("complete-ok\n")
    return 0
