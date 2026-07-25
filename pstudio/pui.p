# pui.p — implementação do toolkit (ver pui.ph). A matemática de layout segue
# a Godot: BoxContainer::_resort (min + EXPAND proporcional com acumulador de
# erro fracionário) e SplitContainer (offset clampado pelos mins dos lados).
include <stdlib.h>
include <string.h>
import "pui.ph"

implement Vec<Cmd>
implement Vec<UINode>

static def own_str(s: const *char) -> *char:
    r: *char = malloc(strlen(s) + 1)
    strcpy(r, s)
    return r

static def emit(sig: *UiSignal, id: i32, arg: i64):
    if sig->fn != None:
        sig->fn(sig->ctx, id, arg)

# ---------- payloads ----------

struct BoxData:
    vertical: bool

struct SplitData:
    vertical: bool
    offset: i32       # tamanho do primeiro filho, em px do eixo
    dragging: bool
    grab: i32         # distância mouse->offset no início do drag

struct TextData:      # label E button (button ganha sinal)
    text: *char
    sig: UiSignal

struct ScrollData:
    vertical: bool
    total: i64
    page: i64
    value: i64
    sig: UiSignal
    dragging: bool
    grab: i32         # offset do mouse dentro do polegar

struct InputData:
    text: *char       # UTF-8 NUL-terminado (malloc, cresce)
    len: usize        # bytes usados (sem o NUL)
    cap: usize
    cursor: i32       # posição do caret em CODEPOINTS
    sig_changed: UiSignal
    sig_submit: UiSignal
    sig_cancel: UiSignal

# ---------- tema default (dark) ----------

static def theme_dark() -> Theme:
    t: Theme = {0}
    with t:
        .bg = 0xFF1E1F22
        .panel = 0xFF2B2D30
        .panel_hi = 0xFF3A3D41
        .panel_lo = 0xFF232527
        .border = 0xFF17181A
        .text = 0xFFD4D4D4
        .text_dim = 0xFF808080
        .accent = 0xFF4F9CF7
        .sel = 0xFF264F78
        .pad = 6
        .sep = 4
        .handle = 6
    return t

# ---------- utf8 (o input de uma linha navega por codepoint) ----------

static def cp_len(s: const *char) -> i32:
    n: i32 = 0
    for i in range(strlen(s)):
        if (u8(s[i]) & 0xC0) != 0x80:
            n += 1
    return n

static def cp_to_byte(s: const *char, col: i32) -> usize:
    n: i32 = 0
    i: usize = 0
    while s[i] != '\0':
        if (u8(s[i]) & 0xC0) != 0x80:
            if n == col:
                return i
            n += 1
        i += 1
    return i

struct Ui:
    # protótipos dos helpers internos (usados antes de suas definições)
    static def is_vis(ref self: Ui, id: i32) -> bool
    static def unlink_node(ref self: Ui, id: i32)
    static def link_last(ref self: Ui, id: i32, parent: i32)
    static def node_release(ref self: Ui, id: i32)
    static def node_clear_cmds(ref self: Ui, id: i32)
    static def cmd_push(ref self: Ui, id: i32) -> *Cmd
    static def measure(ref self: Ui, id: i32)
    static def lay_assign(ref self: Ui, id: i32, r: PgRect)
    static def lay_box(ref self: Ui, id: i32, r: PgRect)
    static def lay_split(ref self: Ui, id: i32, r: PgRect)
    static def build_node(ref self: Ui, id: i32)
    static def draw_walk(ref self: Ui, ref fb: PgFb, id: i32, clip: PgRect)
    static def hit_walk(ref self: Ui, id: i32, x: i32, y: i32) -> i32
    static def node_input(ref self: Ui, id: i32, ev: *PgEvent) -> bool
    static def set_hover(ref self: Ui, id: i32)
    static def scroll_thumb(ref self: Ui, id: i32) -> PgRect
    static def scroll_apply(ref self: Ui, id: i32, pos: i32)
    static def text_new(ref self: Ui, kind: WidgetKind, parent: i32, text: const *char) -> i32
    static def input_edit(ref self: Ui, id: i32, ev: *PgEvent) -> bool
    static def input_insert(ref self: Ui, id: i32, s: const *char)

    # ---------- ciclo de vida ----------

    def init(out self: Ui, font: PgFont):
        self.nodes.init()
        self.free_head = -1
        self.root = -1
        self.focus = -1
        self.capture = -1
        self.hover = -1
        self.theme = theme_dark()
        self.font = font
        self.lay_w = 0
        self.lay_h = 0

    static def node_clear_cmds(ref self: Ui, id: i32):
        nd: *UINode = &self.nodes.data[id]
        for i in range(nd->cmds.len):
            free(nd->cmds.data[i].text)
        nd->cmds.clear()

    static def node_release(ref self: Ui, id: i32):
        nd: *UINode = &self.nodes.data[id]
        match nd->kind:
            case WK_CUSTOM:
                if nd->c_free != None:
                    nd->c_free(&self, id)
            case WK_LABEL, WK_BUTTON:
                td: *TextData = nd->data
                free(td->text)
                free(td)
            case WK_INPUT:
                idt: *InputData = nd->data
                free(idt->text)
                free(idt)
            case _:
                free(nd->data)
        nd->data = None
        self.node_clear_cmds(id)
        nd->cmds.deinit()

    def deinit(ref self: Ui):
        for i in range(self.nodes.len):
            if self.nodes.data[i].alive:
                self.node_release(i)
        self.nodes.deinit()

    def node(ref self: Ui, id: i32) -> *UINode:
        # CUIDADO: o ponteiro invalida no próximo new_node (o pool realoca)
        return &self.nodes.data[id]

    def data_of(ref self: Ui, id: i32) -> *void:
        return self.nodes.data[id].data

    def rect_of(ref self: Ui, id: i32) -> PgRect:
        return self.nodes.data[id].base.rect

    static def unlink_node(ref self: Ui, id: i32):
        nd: *UINode = &self.nodes.data[id]
        p: i32 = nd->parent
        if p < 0:
            nd->next_sibling = -1
            return
        pn: *UINode = &self.nodes.data[p]
        if pn->first_child == id:
            pn->first_child = nd->next_sibling
        else:
            s: i32 = pn->first_child
            while s >= 0 and self.nodes.data[s].next_sibling != id:
                s = self.nodes.data[s].next_sibling
            if s >= 0:
                self.nodes.data[s].next_sibling = nd->next_sibling
        nd->parent = -1
        nd->next_sibling = -1

    static def link_last(ref self: Ui, id: i32, parent: i32):
        self.nodes.data[id].parent = parent
        self.nodes.data[id].next_sibling = -1
        if parent < 0:
            return
        fc: i32 = self.nodes.data[parent].first_child
        if fc < 0:
            self.nodes.data[parent].first_child = id
            return
        while self.nodes.data[fc].next_sibling >= 0:
            fc = self.nodes.data[fc].next_sibling
        self.nodes.data[fc].next_sibling = id

    def new_node(ref self: Ui, kind: WidgetKind, parent: i32) -> i32:
        id: i32
        if self.free_head >= 0:
            id = self.free_head
            self.free_head = self.nodes.data[id].next_sibling
        else:
            id = self.nodes.len
            blank: UINode
            memset(&blank, 0, sizeof(UINode))
            self.nodes.push(blank)
        nd: *UINode = &self.nodes.data[id]
        memset(nd, 0, sizeof(UINode))
        nd->cmds.init()
        nd->kind = kind
        nd->alive = True
        nd->parent = -1
        nd->first_child = -1
        nd->next_sibling = -1
        nd->base.stretch = 1
        nd->base.flags = UF_VISIBLE | UF_DIRTY
        self.link_last(id, parent)
        if parent < 0 and self.root < 0:
            self.root = id
        return id

    def free_node(ref self: Ui, id: i32):
        # solta a subárvore de baixo pra cima (links morrem junto)
        c: i32 = self.nodes.data[id].first_child
        while c >= 0:
            nx: i32 = self.nodes.data[c].next_sibling
            self.free_node(c)
            c = nx
        self.unlink_node(id)
        self.node_release(id)
        if self.focus == id:
            self.focus = -1
        if self.capture == id:
            self.capture = -1
        if self.hover == id:
            self.hover = -1
        if self.root == id:
            self.root = -1
        nd: *UINode = &self.nodes.data[id]
        nd->alive = False
        nd->kind = WK_NONE
        nd->first_child = -1
        nd->next_sibling = self.free_head
        self.free_head = id

    def reparent(ref self: Ui, id: i32, new_parent: i32):
        self.unlink_node(id)
        self.link_last(id, new_parent)

    # ---------- construtores ----------

    def panel(ref self: Ui, parent: i32) -> i32:
        return self.new_node(WK_PANEL, parent)

    def box(ref self: Ui, parent: i32, vertical: bool) -> i32:
        id: i32 = self.new_node(WK_BOX, parent)
        bd: *BoxData = malloc(sizeof(BoxData))
        bd->vertical = vertical
        self.nodes.data[id].data = bd
        return id

    def split(ref self: Ui, parent: i32, vertical: bool) -> i32:
        id: i32 = self.new_node(WK_SPLIT, parent)
        sd: *SplitData = malloc(sizeof(SplitData))
        memset(sd, 0, sizeof(SplitData))
        sd->vertical = vertical
        sd->offset = 200
        self.nodes.data[id].data = sd
        return id

    static def text_new(ref self: Ui, kind: WidgetKind, parent: i32, text: const *char) -> i32:
        id: i32 = self.new_node(kind, parent)
        td: *TextData = malloc(sizeof(TextData))
        memset(td, 0, sizeof(TextData))
        td->text = own_str(text)
        self.nodes.data[id].data = td
        return id

    def label(ref self: Ui, parent: i32, text: const *char) -> i32:
        return self.text_new(WK_LABEL, parent, text)

    def button(ref self: Ui, parent: i32, text: const *char) -> i32:
        id: i32 = self.text_new(WK_BUTTON, parent, text)
        self.nodes.data[id].base.flags |= UF_FOCUSABLE
        return id

    def scrollbar(ref self: Ui, parent: i32, vertical: bool) -> i32:
        id: i32 = self.new_node(WK_SCROLLBAR, parent)
        sd: *ScrollData = malloc(sizeof(ScrollData))
        memset(sd, 0, sizeof(ScrollData))
        sd->vertical = vertical
        sd->total = 1
        sd->page = 1
        self.nodes.data[id].data = sd
        return id

    def line_input(ref self: Ui, parent: i32) -> i32:
        id: i32 = self.new_node(WK_INPUT, parent)
        idt: *InputData = malloc(sizeof(InputData))
        memset(idt, 0, sizeof(InputData))
        idt->cap = 64
        idt->text = malloc(idt->cap)
        idt->text[0] = '\0'
        self.nodes.data[id].data = idt
        self.nodes.data[id].base.flags |= UF_FOCUSABLE
        return id

    def custom(ref self: Ui, parent: i32, data: *void,
               c_min: def(ui: *Ui, id: i32, out_w: *i32, out_h: *i32),
               c_build: def(ui: *Ui, id: i32),
               c_input: def(ui: *Ui, id: i32, ev: *PgEvent) -> bool,
               c_layout: def(ui: *Ui, id: i32, r: PgRect),
               c_free: def(ui: *Ui, id: i32)) -> i32:
        id: i32 = self.new_node(WK_CUSTOM, parent)
        nd: *UINode = &self.nodes.data[id]
        nd->data = data
        nd->c_min = c_min
        nd->c_build = c_build
        nd->c_input = c_input
        nd->c_layout = c_layout
        nd->c_free = c_free
        return id

    # ---------- propriedades ----------

    def set_expand(ref self: Ui, id: i32, h: bool, v: bool):
        f: u32 = self.nodes.data[id].base.flags & ~(UF_EXPAND_H | UF_EXPAND_V)
        if h:
            f |= UF_EXPAND_H
        if v:
            f |= UF_EXPAND_V
        self.nodes.data[id].base.flags = f

    def set_min(ref self: Ui, id: i32, w: i32, h: i32):
        self.nodes.data[id].base.min_w = w
        self.nodes.data[id].base.min_h = h

    def set_stretch(ref self: Ui, id: i32, weight: i32):
        self.nodes.data[id].base.stretch = weight if weight > 0 else 1

    def set_visible(ref self: Ui, id: i32, vis: bool):
        f: u32 = self.nodes.data[id].base.flags
        was: bool = (f & UF_VISIBLE) != 0
        if was == vis:
            return
        if vis:
            self.nodes.data[id].base.flags = f | UF_VISIBLE | UF_DIRTY
        else:
            self.nodes.data[id].base.flags = f & ~UF_VISIBLE
            if self.focus == id:
                self.focus = -1
        self.relayout()

    def is_visible(ref self: Ui, id: i32) -> bool:
        return (self.nodes.data[id].base.flags & UF_VISIBLE) != 0

    static def is_vis(ref self: Ui, id: i32) -> bool:
        return (self.nodes.data[id].base.flags & UF_VISIBLE) != 0

    def set_focusable(ref self: Ui, id: i32, f: bool):
        if f:
            self.nodes.data[id].base.flags |= UF_FOCUSABLE
        else:
            self.nodes.data[id].base.flags &= ~UF_FOCUSABLE

    def set_text(ref self: Ui, id: i32, text: const *char):
        nd: *UINode = &self.nodes.data[id]
        if nd->kind == WK_INPUT:
            idt: *InputData = nd->data
            n: usize = strlen(text)
            if n + 1 > idt->cap:
                idt->cap = n + 1
                idt->text = realloc(idt->text, idt->cap)
            memcpy(idt->text, text, n + 1)
            idt->len = n
            idt->cursor = cp_len(idt->text)
        else:
            td: *TextData = nd->data
            free(td->text)
            td->text = own_str(text)
        self.queue_redraw(id)

    def text_of(ref self: Ui, id: i32) -> const *char:
        nd: *UINode = &self.nodes.data[id]
        if nd->kind == WK_INPUT:
            idt: *InputData = nd->data
            return idt->text
        td: *TextData = nd->data
        return td->text

    def input_clear(ref self: Ui, id: i32):
        self.set_text(id, "")

    def set_rect(ref self: Ui, id: i32, r: PgRect):
        old: PgRect = self.nodes.data[id].base.rect
        self.nodes.data[id].base.rect = r
        if old.x != r.x or old.y != r.y or old.w != r.w or old.h != r.h:
            self.nodes.data[id].base.flags |= UF_DIRTY

    def queue_redraw(ref self: Ui, id: i32):
        self.nodes.data[id].base.flags |= UF_DIRTY

    def queue_redraw_tree(ref self: Ui, id: i32):
        self.nodes.data[id].base.flags |= UF_DIRTY
        c: i32 = self.nodes.data[id].first_child
        while c >= 0:
            self.queue_redraw_tree(c)
            c = self.nodes.data[c].next_sibling

    # ---------- sinais ----------

    def on_click(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void):
        td: *TextData = self.nodes.data[id].data
        td->sig.fn = fn
        td->sig.ctx = ctx

    def on_scroll(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void):
        sd: *ScrollData = self.nodes.data[id].data
        sd->sig.fn = fn
        sd->sig.ctx = ctx

    def on_changed(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void):
        idt: *InputData = self.nodes.data[id].data
        idt->sig_changed.fn = fn
        idt->sig_changed.ctx = ctx

    def on_submit(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void):
        idt: *InputData = self.nodes.data[id].data
        idt->sig_submit.fn = fn
        idt->sig_submit.ctx = ctx

    def on_cancel(ref self: Ui, id: i32, fn: def(ctx: *void, id: i32, arg: i64), ctx: *void):
        idt: *InputData = self.nodes.data[id].data
        idt->sig_cancel.fn = fn
        idt->sig_cancel.ctx = ctx

    # ---------- split / scrollbar ----------

    def split_set(ref self: Ui, id: i32, offset: i32):
        sd: *SplitData = self.nodes.data[id].data
        sd->offset = offset
        self.relayout()

    def split_offset(ref self: Ui, id: i32) -> i32:
        sd: *SplitData = self.nodes.data[id].data
        return sd->offset

    def scroll_set(ref self: Ui, id: i32, total: i64, page: i64, value: i64):
        sd: *ScrollData = self.nodes.data[id].data
        sd->total = total if total > 0 else 1
        sd->page = page if page > 0 else 1
        sd->value = value
        hi: i64 = sd->total - sd->page
        if hi < 0:
            hi = 0
        if sd->value > hi:
            sd->value = hi
        if sd->value < 0:
            sd->value = 0
        self.queue_redraw(id)

    def scroll_value(ref self: Ui, id: i32) -> i64:
        sd: *ScrollData = self.nodes.data[id].data
        return sd->value

    # ---------- foco ----------

    def focus_set(ref self: Ui, id: i32):
        if self.focus == id:
            return
        old: i32 = self.focus
        self.focus = id
        if old >= 0 and self.nodes.data[old].alive:
            self.queue_redraw(old)
        if id >= 0:
            self.queue_redraw(id)

    def focus_get(ref self: Ui) -> i32:
        return self.focus

    # ---------- fase 1: minimum size (sobe) ----------

    static def measure(ref self: Ui, id: i32):
        # pós-ordem: filhos primeiro
        c: i32 = self.nodes.data[id].first_child
        while c >= 0:
            self.measure(c)
            c = self.nodes.data[c].next_sibling
        th: *Theme = &self.theme
        w: i32 = 0
        h: i32 = 0
        nd: *UINode = &self.nodes.data[id]
        match nd->kind:
            case WK_LABEL:
                td: *TextData = nd->data
                w = self.font.text_width(td->text)
                h = self.font.line_h()
            case WK_BUTTON:
                tb: *TextData = nd->data
                w = self.font.text_width(tb->text) + th->pad * 2
                h = self.font.line_h() + th->pad * 2
            case WK_INPUT:
                w = self.font.char_w() * 8
                h = self.font.line_h() + th->pad
            case WK_SCROLLBAR:
                sb: *ScrollData = nd->data
                w = th->handle * 2 if sb->vertical else 0
                h = 0 if sb->vertical else th->handle * 2
            case WK_BOX:
                bd: *BoxData = nd->data
                nvis: i32 = 0
                c = nd->first_child
                while c >= 0:
                    if self.is_vis(c):
                        cb: *WidgetBase = &self.nodes.data[c].base
                        if bd->vertical:
                            h += cb->ch
                            w = cb->cw if cb->cw > w else w
                        else:
                            w += cb->cw
                            h = cb->ch if cb->ch > h else h
                        nvis += 1
                    c = self.nodes.data[c].next_sibling
                if nvis > 1:
                    if bd->vertical:
                        h += th->sep * (nvis - 1)
                    else:
                        w += th->sep * (nvis - 1)
            case WK_SPLIT:
                sd: *SplitData = nd->data
                c = nd->first_child
                while c >= 0:
                    if self.is_vis(c):
                        sb2: *WidgetBase = &self.nodes.data[c].base
                        if sd->vertical:
                            h += sb2->ch
                            w = sb2->cw if sb2->cw > w else w
                        else:
                            w += sb2->cw
                            h = sb2->ch if sb2->ch > h else h
                    c = self.nodes.data[c].next_sibling
                if sd->vertical:
                    h += th->handle
                else:
                    w += th->handle
            case WK_PANEL:
                c = nd->first_child
                while c >= 0:
                    if self.is_vis(c):
                        pb: *WidgetBase = &self.nodes.data[c].base
                        w = pb->cw if pb->cw > w else w
                        h = pb->ch if pb->ch > h else h
                    c = self.nodes.data[c].next_sibling
            case WK_CUSTOM:
                if nd->c_min != None:
                    nd->c_min(&self, id, &w, &h)
            case _:
                pass
        if nd->base.min_w > w:
            w = nd->base.min_w
        if nd->base.min_h > h:
            h = nd->base.min_h
        nd->base.cw = w
        nd->base.ch = h

    # ---------- fase 2: atribuição de rects (desce) ----------

    # BoxContainer::_resort: mins somados; espaço restante repartido entre os
    # EXPAND proporcionalmente ao stretch, com acumulador de erro fracionário
    static def lay_box(ref self: Ui, id: i32, r: PgRect):
        bd: *BoxData = self.nodes.data[id].data
        vert: bool = bd->vertical
        sep: i32 = self.theme.sep
        nvis: i32 = 0
        combined_min: i32 = 0
        ratio_total: i32 = 0
        c: i32 = self.nodes.data[id].first_child
        while c >= 0:
            if self.is_vis(c):
                cb: *WidgetBase = &self.nodes.data[c].base
                combined_min += cb->ch if vert else cb->cw
                exp: u32 = UF_EXPAND_V if vert else UF_EXPAND_H
                if (cb->flags & exp) != 0:
                    ratio_total += cb->stretch
                nvis += 1
            c = self.nodes.data[c].next_sibling
        if nvis == 0:
            return
        space: i32 = (r.h if vert else r.w) - sep * (nvis - 1)
        stretch_diff: i32 = space - combined_min
        if stretch_diff < 0:
            stretch_diff = 0
        # distribui com acumulador de erro (inteiro): err += resto; >=total -> +1px
        err: i32 = 0
        pos: i32 = r.y if vert else r.x
        c = self.nodes.data[id].first_child
        while c >= 0:
            nx: i32 = self.nodes.data[c].next_sibling
            if self.is_vis(c):
                cb2: *WidgetBase = &self.nodes.data[c].base
                size: i32 = cb2->ch if vert else cb2->cw
                exp2: u32 = UF_EXPAND_V if vert else UF_EXPAND_H
                if (cb2->flags & exp2) != 0 and ratio_total > 0:
                    share: i32 = stretch_diff * cb2->stretch
                    size += share / ratio_total
                    err += share % ratio_total
                    if err >= ratio_total:
                        size += 1
                        err -= ratio_total
                cr: PgRect
                if vert:
                    cr = pg_rect(r.x, pos, r.w, size)
                else:
                    cr = pg_rect(pos, r.y, size, r.h)
                self.lay_assign(c, cr)
                pos += size + sep
            c = nx

    # SplitContainer: offset clampado entre o min do primeiro e o espaço menos
    # o min do segundo; o divisor fica entre os dois
    static def lay_split(ref self: Ui, id: i32, r: PgRect):
        sd: *SplitData = self.nodes.data[id].data
        vert: bool = sd->vertical
        a: i32 = -1
        b: i32 = -1
        c: i32 = self.nodes.data[id].first_child
        while c >= 0:
            if self.is_vis(c):
                if a < 0:
                    a = c
                elif b < 0:
                    b = c
            c = self.nodes.data[c].next_sibling
        if a < 0:
            return
        axis: i32 = r.h if vert else r.w
        if b < 0:
            self.lay_assign(a, r)
            return
        hs: i32 = self.theme.handle
        amin: i32 = self.nodes.data[a].base.ch if vert else self.nodes.data[a].base.cw
        bmin: i32 = self.nodes.data[b].base.ch if vert else self.nodes.data[b].base.cw
        off: i32 = sd->offset
        if off > axis - hs - bmin:
            off = axis - hs - bmin
        if off < amin:
            off = amin
        if off < 0:
            off = 0
        sd->offset = off
        if vert:
            self.lay_assign(a, pg_rect(r.x, r.y, r.w, off))
            self.lay_assign(b, pg_rect(r.x, r.y + off + hs, r.w, axis - off - hs))
        else:
            self.lay_assign(a, pg_rect(r.x, r.y, off, r.h))
            self.lay_assign(b, pg_rect(r.x + off + hs, r.y, axis - off - hs, r.h))

    static def lay_assign(ref self: Ui, id: i32, r: PgRect):
        self.set_rect(id, r)
        nd: *UINode = &self.nodes.data[id]
        match nd->kind:
            case WK_BOX:
                self.lay_box(id, r)
            case WK_SPLIT:
                self.lay_split(id, r)
            case WK_CUSTOM:
                if nd->c_layout != None:
                    nd->c_layout(&self, id, r)   # container próprio do app
                    return
                c0: i32 = nd->first_child
                while c0 >= 0:
                    if self.is_vis(c0):
                        self.lay_assign(c0, r)
                    c0 = self.nodes.data[c0].next_sibling
            case _:
                # PANEL/folhas: filhos empilhados no rect inteiro
                c: i32 = nd->first_child
                while c >= 0:
                    if self.is_vis(c):
                        self.lay_assign(c, r)
                    c = self.nodes.data[c].next_sibling

    def layout(ref self: Ui, w: i32, h: i32):
        self.lay_w = w
        self.lay_h = h
        if self.root < 0:
            return
        self.measure(self.root)
        self.lay_assign(self.root, pg_rect(0, 0, w, h))

    def relayout(ref self: Ui):
        if self.lay_w > 0:
            self.layout(self.lay_w, self.lay_h)

    # ---------- comandos ----------

    static def cmd_push(ref self: Ui, id: i32) -> *Cmd:
        nd: *UINode = &self.nodes.data[id]
        blank: Cmd
        memset(&blank, 0, sizeof(Cmd))
        nd->cmds.push(blank)
        return &nd->cmds.data[nd->cmds.len - 1]

    def cmd_rect(ref self: Ui, id: i32, r: PgRect, color: u32):
        c: *Cmd = self.cmd_push(id)
        c->kind = CMD_RECT
        c->x = r.x; c->y = r.y; c->w = r.w; c->h = r.h
        c->color = color

    def cmd_frame(ref self: Ui, id: i32, r: PgRect, color: u32):
        c: *Cmd = self.cmd_push(id)
        c->kind = CMD_FRAME
        c->x = r.x; c->y = r.y; c->w = r.w; c->h = r.h
        c->color = color

    def cmd_text(ref self: Ui, id: i32, x: i32, y: i32, text: const *char, color: u32):
        self.cmd_text_n(id, x, y, text, strlen(text), color)

    def cmd_text_n(ref self: Ui, id: i32, x: i32, y: i32, text: const *char, nbytes: usize, color: u32):
        c: *Cmd = self.cmd_push(id)
        c->kind = CMD_TEXT
        c->x = x; c->y = y
        c->color = color
        c->text = malloc(nbytes + 1)
        memcpy(c->text, text, nbytes)
        c->text[nbytes] = '\0'

    def cmd_glyph(ref self: Ui, id: i32, x: i32, y: i32, cp: u32, color: u32):
        c: *Cmd = self.cmd_push(id)
        c->kind = CMD_GLYPH
        c->x = x; c->y = y
        c->cp = cp
        c->color = color

    # ---------- builders por kind ----------

    # rect do polegar da scrollbar (também usado pelo input)
    static def scroll_thumb(ref self: Ui, id: i32) -> PgRect:
        nd: *UINode = &self.nodes.data[id]
        sd: *ScrollData = nd->data
        r: PgRect = nd->base.rect
        axis: i32 = r.h if sd->vertical else r.w
        tl: i32 = i32(i64(axis) * sd->page / sd->total)
        if tl < 16:
            tl = 16
        if tl > axis:
            tl = axis
        hi: i64 = sd->total - sd->page
        tp: i32 = 0
        if hi > 0:
            tp = i32(i64(axis - tl) * sd->value / hi)
        if sd->vertical:
            return pg_rect(r.x + 2, r.y + tp, r.w - 4, tl)
        return pg_rect(r.x + tp, r.y + 2, tl, r.h - 4)

    static def build_node(ref self: Ui, id: i32):
        self.node_clear_cmds(id)
        nd: *UINode = &self.nodes.data[id]
        th: *Theme = &self.theme
        r: PgRect = nd->base.rect
        lh: i32 = self.font.line_h()
        match nd->kind:
            case WK_PANEL:
                self.cmd_rect(id, r, th->panel)
            case WK_LABEL:
                td: *TextData = nd->data
                self.cmd_text(id, r.x, r.y + (r.h - lh) / 2, td->text, th->text)
            case WK_BUTTON:
                tb: *TextData = nd->data
                bg: u32 = th->panel_hi
                if (nd->base.flags & UF_PRESSED) != 0:
                    bg = th->panel_lo
                elif (nd->base.flags & UF_HOVER) != 0:
                    bg = 0xFF45484D
                self.cmd_rect(id, r, bg)
                self.cmd_frame(id, r, th->border)
                tw: i32 = self.font.text_width(tb->text)
                self.cmd_text(id, r.x + (r.w - tw) / 2, r.y + (r.h - lh) / 2, tb->text, th->text)
            case WK_INPUT:
                idt: *InputData = nd->data
                self.cmd_rect(id, r, th->panel_lo)
                self.cmd_frame(id, r, th->accent if self.focus == id else th->border)
                tx: i32 = r.x + 4
                ty: i32 = r.y + (r.h - lh) / 2
                self.cmd_text(id, tx, ty, idt->text, th->text)
                if self.focus == id:
                    cx: i32 = tx + idt->cursor * self.font.char_w()
                    self.cmd_rect(id, pg_rect(cx, ty, 1, lh), th->text)
            case WK_SPLIT:
                sd: *SplitData = nd->data
                # só o traço do divisor (os filhos se desenham)
                hs: i32 = th->handle
                if sd->vertical:
                    self.cmd_rect(id, pg_rect(r.x, r.y + sd->offset, r.w, hs), th->border)
                else:
                    self.cmd_rect(id, pg_rect(r.x + sd->offset, r.y, hs, r.h), th->border)
            case WK_SCROLLBAR:
                self.cmd_rect(id, r, th->panel_lo)
                self.cmd_rect(id, self.scroll_thumb(id), th->panel_hi)
            case WK_CUSTOM:
                if nd->c_build != None:
                    nd->c_build(&self, id)
            case _:
                pass
        self.nodes.data[id].base.flags &= ~UF_DIRTY

    static def draw_walk(ref self: Ui, ref fb: PgFb, id: i32, clip: PgRect):
        if not self.is_vis(id):
            return
        nclip: PgRect = clip.intersect(self.nodes.data[id].base.rect)
        if nclip.is_empty():
            return
        if (self.nodes.data[id].base.flags & UF_DIRTY) != 0:
            self.build_node(id)
        nd: *UINode = &self.nodes.data[id]
        fb.clip_set(nclip)
        for i in range(nd->cmds.len):
            c: *Cmd = &nd->cmds.data[i]
            match c->kind:
                case CMD_RECT:
                    fb.fill_rect(pg_rect(c->x, c->y, c->w, c->h), c->color)
                case CMD_FRAME:
                    fb.frame_rect(pg_rect(c->x, c->y, c->w, c->h), c->color)
                case CMD_TEXT:
                    fb.draw_text(in self.font, c->text, c->x, c->y, c->color)
                case CMD_GLYPH:
                    fb.draw_glyph(in self.font, c->cp, c->x, c->y, c->color)
        ch: i32 = nd->first_child
        while ch >= 0:
            self.draw_walk(ref fb, ch, nclip)
            ch = self.nodes.data[ch].next_sibling

    def draw(ref self: Ui, ref fb: PgFb):
        fb.clip_reset()
        fb.clear(self.theme.bg)
        if self.root >= 0:
            self.draw_walk(ref fb, self.root, pg_rect(0, 0, fb.w, fb.h))
        fb.clip_reset()

    # ---------- input ----------

    static def hit_walk(ref self: Ui, id: i32, x: i32, y: i32) -> i32:
        if not self.is_vis(id) or not self.nodes.data[id].base.rect.contains(x, y):
            return -1
        # último filho que contém o ponto ganha (desenha por cima)
        best: i32 = id
        c: i32 = self.nodes.data[id].first_child
        while c >= 0:
            got: i32 = self.hit_walk(c, x, y)
            if got >= 0:
                best = got
            c = self.nodes.data[c].next_sibling
        return best

    def hit(ref self: Ui, x: i32, y: i32) -> i32:
        if self.root < 0:
            return -1
        return self.hit_walk(self.root, x, y)

    static def scroll_apply(ref self: Ui, id: i32, pos: i32):
        nd: *UINode = &self.nodes.data[id]
        sd: *ScrollData = nd->data
        r: PgRect = nd->base.rect
        axis: i32 = r.h if sd->vertical else r.w
        t: PgRect = self.scroll_thumb(id)
        tl: i32 = t.h if sd->vertical else t.w
        track: i32 = axis - tl
        hi: i64 = sd->total - sd->page
        if track <= 0 or hi <= 0:
            return
        rel: i32 = pos - (r.y if sd->vertical else r.x) - sd->grab
        v: i64 = i64(rel) * hi / i64(track)
        if v < 0:
            v = 0
        if v > hi:
            v = hi
        if v != sd->value:
            sd->value = v
            self.queue_redraw(id)
            emit(&sd->sig, id, sd->value)

    static def input_insert(ref self: Ui, id: i32, s: const *char):
        idt: *InputData = self.nodes.data[id].data
        n: usize = strlen(s)
        at: usize = cp_to_byte(idt->text, idt->cursor)
        if idt->len + n + 1 > idt->cap:
            while idt->len + n + 1 > idt->cap:
                idt->cap *= 2
            idt->text = realloc(idt->text, idt->cap)
        memmove(idt->text + at + n, idt->text + at, idt->len - at + 1)
        memcpy(idt->text + at, s, n)
        idt->len += n
        idt->cursor += cp_len(s)
        self.queue_redraw(id)
        emit(&idt->sig_changed, id, 0)

    static def input_edit(ref self: Ui, id: i32, ev: *PgEvent) -> bool:
        idt: *InputData = self.nodes.data[id].data
        if ev->kind == PGE_TEXT:
            self.input_insert(id, ev->text)
            return True
        if ev->kind != PGE_KEY:
            return False
        ncp: i32 = cp_len(idt->text)
        if ev->key == PGK_BACKSPACE:
            if idt->cursor > 0:
                a: usize = cp_to_byte(idt->text, idt->cursor - 1)
                b: usize = cp_to_byte(idt->text, idt->cursor)
                memmove(idt->text + a, idt->text + b, idt->len - b + 1)
                idt->len -= b - a
                idt->cursor -= 1
                self.queue_redraw(id)
                emit(&idt->sig_changed, id, 0)
            return True
        if ev->key == PGK_DELETE:
            if idt->cursor < ncp:
                a2: usize = cp_to_byte(idt->text, idt->cursor)
                b2: usize = cp_to_byte(idt->text, idt->cursor + 1)
                memmove(idt->text + a2, idt->text + b2, idt->len - b2 + 1)
                idt->len -= b2 - a2
                self.queue_redraw(id)
                emit(&idt->sig_changed, id, 0)
            return True
        if ev->key == PGK_LEFT:
            if idt->cursor > 0:
                idt->cursor -= 1
                self.queue_redraw(id)
            return True
        if ev->key == PGK_RIGHT:
            if idt->cursor < ncp:
                idt->cursor += 1
                self.queue_redraw(id)
            return True
        if ev->key == PGK_HOME:
            idt->cursor = 0
            self.queue_redraw(id)
            return True
        if ev->key == PGK_END:
            idt->cursor = ncp
            self.queue_redraw(id)
            return True
        if ev->key == PGK_RETURN:
            emit(&idt->sig_submit, id, 0)
            return True
        if ev->key == PGK_ESCAPE:
            emit(&idt->sig_cancel, id, 0)
            return True
        return False

    # input dirigido a UM widget; True = consumiu
    static def node_input(ref self: Ui, id: i32, ev: *PgEvent) -> bool:
        nd: *UINode = &self.nodes.data[id]
        match nd->kind:
            case WK_BUTTON:
                td: *TextData = nd->data
                if ev->kind == PGE_MOUSE_DOWN and ev->button == 1:
                    nd->base.flags |= UF_PRESSED
                    self.queue_redraw(id)
                    return True
                if ev->kind == PGE_MOUSE_UP and ev->button == 1:
                    was: bool = (nd->base.flags & UF_PRESSED) != 0
                    nd->base.flags &= ~UF_PRESSED
                    self.queue_redraw(id)
                    if was and nd->base.rect.contains(ev->x, ev->y):
                        emit(&td->sig, id, 0)
                    return True
                if ev->kind == PGE_KEY and ev->key in {PGK_RETURN, PGK_SPACE}:
                    emit(&td->sig, id, 0)
                    return True
            case WK_INPUT:
                if ev->kind == PGE_MOUSE_DOWN and ev->button == 1:
                    idt: *InputData = nd->data
                    cw: i32 = self.font.char_w()
                    rel: i32 = (ev->x - (nd->base.rect.x + 4) + cw / 2) / cw
                    ncp: i32 = cp_len(idt->text)
                    idt->cursor = 0 if rel < 0 else (ncp if rel > ncp else rel)
                    self.queue_redraw(id)
                    return True
                return self.input_edit(id, ev)
            case WK_SCROLLBAR:
                sd: *ScrollData = nd->data
                vert0: bool = sd->vertical
                if ev->kind == PGE_MOUSE_DOWN and ev->button == 1:
                    t: PgRect = self.scroll_thumb(id)
                    p: i32 = ev->y if vert0 else ev->x
                    if t.contains(ev->x, ev->y):
                        sd->dragging = True
                        sd->grab = p - (t.y if vert0 else t.x)
                    else:
                        # clique na pista: pula uma página na direção
                        nv: i64 = sd->value - sd->page if p < (t.y if vert0 else t.x) else sd->value + sd->page
                        self.scroll_set(id, sd->total, sd->page, nv)
                        emit(&sd->sig, id, sd->value)
                    return True
                if ev->kind == PGE_MOUSE_MOVE and sd->dragging:
                    self.scroll_apply(id, ev->y if vert0 else ev->x)
                    return True
                if ev->kind == PGE_MOUSE_UP:
                    sd->dragging = False
                    return True
                if ev->kind == PGE_WHEEL:
                    step: i64 = sd->page / 8
                    self.scroll_set(id, sd->total, sd->page,
                                    sd->value - i64(ev->wheel_y) * (step if step > 0 else 1))
                    emit(&sd->sig, id, sd->value)
                    return True
            case WK_SPLIT:
                sd2: *SplitData = nd->data
                vert: bool = sd2->vertical
                r: PgRect = nd->base.rect
                hr: PgRect
                if vert:
                    hr = pg_rect(r.x, r.y + sd2->offset, r.w, self.theme.handle)
                else:
                    hr = pg_rect(r.x + sd2->offset, r.y, self.theme.handle, r.h)
                if ev->kind == PGE_MOUSE_DOWN and ev->button == 1 and hr.contains(ev->x, ev->y):
                    sd2->dragging = True
                    sd2->grab = (ev->y if vert else ev->x) - sd2->offset
                    return True
                if ev->kind == PGE_MOUSE_MOVE and sd2->dragging:
                    sd2->offset = (ev->y if vert else ev->x) - sd2->grab
                    self.relayout()
                    self.queue_redraw(id)
                    return True
                if ev->kind == PGE_MOUSE_UP and sd2->dragging:
                    sd2->dragging = False
                    return True
            case WK_CUSTOM:
                if nd->c_input != None:
                    return nd->c_input(&self, id, ev)
            case _:
                pass
        return False

    static def set_hover(ref self: Ui, id: i32):
        if self.hover == id:
            return
        old: i32 = self.hover
        self.hover = id
        if old >= 0 and self.nodes.data[old].alive:
            self.nodes.data[old].base.flags &= ~UF_HOVER
            self.queue_redraw(old)
        if id >= 0:
            self.nodes.data[id].base.flags |= UF_HOVER
            self.queue_redraw(id)

    def input_event(ref self: Ui, ev: *PgEvent) -> bool:
        match ev->kind:
            case PGE_MOUSE_DOWN:
                t: i32 = self.hit(ev->x, ev->y)
                if t < 0:
                    return False
                # foco: o alvo se focável, senão o ancestral focável mais próximo
                f: i32 = t
                while f >= 0 and (self.nodes.data[f].base.flags & UF_FOCUSABLE) == 0:
                    f = self.nodes.data[f].parent
                if f >= 0:
                    self.focus_set(f)
                # sobe até alguém consumir (split pega o clique no divisor aqui)
                h: i32 = t
                while h >= 0:
                    if self.node_input(h, ev):
                        self.capture = h
                        return True
                    h = self.nodes.data[h].parent
                return False
            case PGE_MOUSE_UP:
                if self.capture >= 0:
                    c: i32 = self.capture
                    self.capture = -1
                    self.node_input(c, ev)
                    return True
                return False
            case PGE_MOUSE_MOVE:
                if self.capture >= 0:
                    return self.node_input(self.capture, ev)
                self.set_hover(self.hit(ev->x, ev->y))
                return False
            case PGE_WHEEL:
                w: i32 = self.hit(ev->x, ev->y)
                while w >= 0:
                    if self.node_input(w, ev):
                        return True
                    w = self.nodes.data[w].parent
                return False
            case PGE_KEY, PGE_TEXT:
                if self.focus >= 0 and self.nodes.data[self.focus].alive:
                    return self.node_input(self.focus, ev)
                return False
            case _:
                pass
        return False
