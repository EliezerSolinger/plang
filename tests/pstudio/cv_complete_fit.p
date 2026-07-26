# The completion popup must never paint outside its own box. It used to draw the
# candidate's name and its whole SIGNATURE LINE unbounded — the only guard was
# on where the signature STARTED, not where it ended — so a long `def` spilled
# over the code, the minimap and the widget edge.
#
# Rather than pinning down geometry numbers, this checks the PROPERTY on the
# retained command list: every text/glyph command that belongs to the popup ends
# inside cmp_rect(). That holds whatever the pane size, so the same test covers
# the narrow-pane and low-pane clamps too.
include <stdio.h>
include <stdlib.h>
include <string.h>
import "../../pstudio/codeview.ph"
import "../../selfhost/plang.ph"     # StrBuf, to build the source text

# a struct whose members carry LONG signatures: `detail` is the trimmed source
# line, so these are what overflows
static def make_src() -> *char:
    b: StrBuf = {0}
    b.puts("struct Coisa:\n")
    for i in range(12):
        b.printf("    def metodo_de_nome_longo_%d(ref self: Coisa, primeiro: *Type, segundo: Vec<Param>, terceiro: bool) -> *Type\n", i)
    b.puts("\ndef usa(c: *Coisa):\n    c.met\n")
    return b.data

# how far right a command reaches (glyphs are one cell wide)
static def cmd_right(in ui: Ui, c: *Cmd) -> i32:
    if c->kind == CMD_TEXT:
        return c->x + ui.font.text_width(c->text)
    if c->kind == CMD_GLYPH:
        return c->x + ui.font.char_w()
    return c->x + c->w

# The popup's own commands are the ones emitted AFTER its background rect —
# code glyphs that happen to sit under the box came before it and are painted
# over, so counting them would be a false alarm.
static def check_contained(ref ui: Ui, in cv: CodeView) -> i32:
    pr: PgRect = cv.cmp_rect()
    n: *UINode = ui.node(cv.id)
    bad: i32 = 0
    inside: i32 = 0
    first: i32 = -1
    for i in range(n->cmds.len):
        c: *Cmd = &n->cmds.data[i]
        if (c->kind == CMD_RECT and c->x == pr.x and c->y == pr.y
                and c->w == pr.w and c->h == pr.h):
            first = i
    if first < 0:
        printf("   popup não encontrado na lista de comandos\n")
        return 1
    for i in range(first + 1, n->cmds.len):
        c: *Cmd = &n->cmds.data[i]
        if c->kind != CMD_TEXT and c->kind != CMD_GLYPH:
            continue
        inside += 1
        if cmd_right(in ui, c) > pr.x + pr.w:
            bad += 1
            printf("   VAZA: x=%d right=%d limite=%d [%s]\n", c->x, cmd_right(in ui, c),
                   pr.x + pr.w, c->text if c->kind == CMD_TEXT else "…")
    return bad if bad > 0 else -inside      # -N = N commands, all contained

static def probe(ref ui: Ui, ref cv: CodeView, w: i32, h: i32, what: const *char):
    ui.layout(w, h)
    tr: PgRect = cv.text_rect()
    fb: PgFb
    fb.init(w, h)
    ui.queue_redraw_tree(ui.root)
    ui.draw(ref fb)
    pr: PgRect = cv.cmp_rect()
    r: i32 = check_contained(ref ui, in cv)
    # the box itself has to be inside the text area, in both directions
    fits: bool = (pr.x >= tr.x and pr.x + pr.w <= tr.x + tr.w
                  and pr.y >= tr.y and pr.y + pr.h <= tr.y + tr.h)
    printf("%-14s caixa=%dx%d rows=%d dentro=%d cmds=%d vazamentos=%d\n",
           what, pr.w, pr.h, cv.cmp_rows(), 1 if fits else 0,
           -r if r < 0 else 0, r if r > 0 else 0)
    fb.deinit()

def main() -> int:
    ui: Ui
    ui.init(pg_font_default(pg_font_default_size()))
    root: i32 = ui.box(-1, True)
    id: i32 = cv_create(ref ui, root)
    ui.layout(900, 500)
    cv: *CodeView = cv_of(ref ui, id)
    src: *char = make_src()
    cv->set_text(src)

    # caret right after `c.met` on the last line: member completion on Coisa
    last: i32 = cv->buf.nlines() - 2      # the `    c.met` line (the file ends in \n)
    c: *Caret = cv->buf.caret(0)
    c->line = last; c->col = cv->buf.line_cp(last)
    c->aline = c->line; c->acol = c->col
    cv->complete_open()
    printf("candidatos=%d owner=%s\n", cv->cmp_hits.len,
           cv->cmp_owner if cv->cmp_owner != None else "-")

    probe(ref ui, ref *cv, 900, 500, "largo")
    probe(ref ui, ref *cv, 380, 500, "estreito")
    probe(ref ui, ref *cv, 900, 150, "baixo")
    probe(ref ui, ref *cv, 300, 120, "minusculo")

    free(src)
    ui.deinit()
    printf("complete-fit-ok\n")
    return 0
