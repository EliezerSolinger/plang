"""pui in pscript: the widget tree, Godot's layout and retained drawing.

A port of `pstudio/pui.p` (1158 lines of P) into the language the editor is
going to live in. The arithmetic is the SAME — `BoxContainer::_resort` with a
fractional error accumulator, `SplitContainer` with the offset pinned by both
minimums — and that is why the test `tests/pstudio/pui_layout_ps.psc` prints the
same rectangles as the test in P: two programs, two languages, the same numbers.

What CHANGED in the port, and why:

  * **One node, no per-type payload.** P had `BoxData`/`SplitData`/`TextData`/
    `ScrollData`/`InputData`, each with a `malloc`, a `memset` and a `free` in
    the right place. Here the fields belong to the node and the collector is the
    owner: gone are the five structs, the five `malloc`s and the `node_release`.
  * **No bit masks.** `UF_VISIBLE|UF_DIRTY` became `visible` and `dirty`. The
    mask existed to fit in a `u32`; a bool costs the same here and does not
    read backwards.
  * **The font metric is a PARAMETER, not the driver.** The `Ui` receives the
    cell (width and height) and knows no SDL at all. It is what makes the
    toolkit testable without a window — and the headless test measures the real
    layout, not an imitation of it.
  * **Drawing is replay into a `Painter`.** P wrote into a `PgFb`; here `draw`
    receives five functions (rectangle, frame, clip, end clip, glyph).
    The app passes the shim's, the test passes counting ones — the same list of
    retained commands in both cases.
  * **A signal is a function, with no `ctx`.** In P it was `{fn, ctx}` because a
    free function does not capture; here a lambda captures the app (28.1/19.2),
    so the `ctx` has no reason to exist.
"""

# ---------- what a widget is ----------

enum WKind:
    WK_NONE
    WK_PANEL          # background; children stacked in the whole rectangle
    WK_BOX            # linear v/h container (BoxContainer's algorithm)
    WK_SPLIT          # two children and a draggable divider
    WK_LABEL
    WK_BUTTON
    WK_SCROLLBAR
    WK_INPUT          # one-line input (palette, search)
    WK_CUSTOM         # the app's widget: behaviour comes from the node's functions


enum CmdKind:
    CMD_RECT
    CMD_FRAME
    CMD_TEXT
    CMD_GLYPH


record Rect:
    x: int
    y: int
    w: int
    h: int


record Size:
    w: int
    h: int


# the … of elided text and of a folded block. A constant because `chr(0x2026)`
# in a drawing loop would be one allocation per frame.
const CP_ELLIPSIS: int = 0x2026


def rect_has(r: Rect, x: int, y: int) -> bool:
    return x >= r.x and y >= r.y and x < r.x + r.w and y < r.y + r.h


def rect_inter(a: Rect, b: Rect) -> Rect:
    x0 = a.x if a.x > b.x else b.x
    y0 = a.y if a.y > b.y else b.y
    x1 = a.x + a.w if a.x + a.w < b.x + b.w else b.x + b.w
    y1 = a.y + a.h if a.y + a.h < b.y + b.h else b.y + b.h
    return Rect(x0, y0, x1 - x0, y1 - y0)


def rect_empty(r: Rect) -> bool:
    return r.w <= 0 or r.h <= 0


# a drawing command KEPT: rewritten only when the widget goes dirty
struct Cmd:
    kind: CmdKind
    x: int
    y: int
    w: int
    h: int
    color: int
    cp: int
    text: str


# whoever puts pixels on the screen. The toolkit does not know whether SDL, a
# test counter or a file is on the other side — it just calls.
struct Painter:
    rect: def(int, int, int, int, int)        # x, y, w, h, colour
    frame: def(int, int, int, int, int)
    clip: def(int, int, int, int)
    clip_off: def()
    glyph: def(int, int, int, int)            # codepoint, x, y, colour


# the theme (a dark one, compiled in; a config file is another conversation)
struct Theme:
    bg: int
    panel: int
    panel_hi: int      # hover
    panel_lo: int      # pressed / sunken
    border: int
    text: int
    text_dim: int
    accent: int
    sel: int
    pad: int           # inner breathing room (buttons and the like)
    sep: int           # separation between a BOX's children
    handle: int        # thickness of the divider and of the bar


def theme_dark() -> Theme:
    return Theme(0xFF1E1F22, 0xFF2B2D30, 0xFF3A3D41, 0xFF232527, 0xFF17181A,
                 0xFFD4D4D4, 0xFF808080, 0xFF4F9CF7, 0xFF264F78, 6, 4, 6)


# A node of the tree. The payload fields of every type all live here: an empty
# node costs a few pointers, and the price of that is not having five structs,
# five allocations and a releaser that has to know about all of them.
struct Node:
    kind: WKind
    alive: bool
    parent: int          # -1 = root or detached
    first_child: int     # -1 = leaf
    next_sibling: int    # sibling order is drawing order (and the freelist)

    rect: Rect           # the FINAL rectangle, after layout
    min_w: int           # minimum the app asked for (0 = only what the type computes)
    min_h: int
    stretch: int         # the EXPAND weight inside a box
    cw: int              # the minimum COMPUTED by phase 1
    ch: int
    bg: int              # painted before everything; 0 = transparent
    pad: int             # the text's left indent

    visible: bool
    expand_h: bool
    expand_v: bool
    dirty: bool          # the command list has to be rewritten
    focusable: bool
    hover: bool          # computed by the input (read-only for the app)
    pressed: bool

    cmds: list<Cmd>      # the RETAINED list

    vertical: bool       # box, split, scrollbar
    offset: int          # split: the first child's size, in axis pixels
    dragging: bool       # split, scrollbar
    grab: int            # distance from the mouse to the value when the drag began
    text: str            # label, button, input
    cursor: int          # input: the caret, in CODEPOINTS
    total: int           # scrollbar: the content
    page: int            #            the visible part
    value: int           #            the position

    # `def(...)?` and not `def(...)`: a signal nobody connected is ABSENT, and
    # the language only lets that be None if the type says so (9.4). The
    # parenthesis in `(def(...) -> T)?` is there because without it the `?` would land on the RETURN type.
    sig_click: def(int, int)?
    sig_scroll: def(int, int)?
    sig_changed: def(int, int)?
    sig_submit: def(int, int)?
    sig_cancel: def(int, int)?

    c_min: (def(Ui, int) -> Size)?        # the minimum of the app's widget
    c_build: def(Ui, int)?                # rewrites the commands (cmd_*)
    c_input: (def(Ui, int, Event) -> bool)?
    c_layout: def(Ui, int, Rect)?         # positions its own children
    data: any?                            # the state of the app's widget


# ---------- events ----------
# The same ones the shim delivers, as a VALUE: whoever tests builds one by hand,
# and the app's loop builds one out of the scalar accessors.

enum EvKind:
    EV_NONE
    EV_QUIT
    EV_KEY
    EV_TEXT
    EV_MOUSE_DOWN
    EV_MOUSE_UP
    EV_MOUSE_MOVE
    EV_WHEEL
    EV_RESIZE


record Event:
    kind: EvKind
    key: int
    mods: int
    cp: int          # EV_TEXT: the codepoint typed
    x: int
    y: int
    button: int
    clicks: int
    wheel: int


# the keys the toolkit knows (SDL's codes, as in the shim)
const K_RETURN: int = 13
const K_ESCAPE: int = 27
const K_BACKSPACE: int = 8
const K_TAB: int = 9
const K_SPACE: int = 32
const K_DELETE: int = 127
const K_RIGHT: int = 1073741903
const K_LEFT: int = 1073741904
const K_HOME: int = 1073741898
const K_END: int = 1073741901


def new_node_blank() -> Node:
    """A zeroed node. It exists because a `struct` is built by field order and
    that list has to appear ONCE, not in every widget constructor."""
    return Node(WK_NONE, False, -1, -1, -1,
                Rect(0, 0, 0, 0), 0, 0, 1, 0, 0, 0, 0,
                True, False, False, True, False, False, False,
                [],
                False, 0, False, 0, "", 0, 1, 1, 0,
                None, None, None, None, None,
                None, None, None, None, None)


struct Ui:
    nodes: list<Node>
    free_head: int       # freelist, chained through next_sibling
    root: int
    focus: int           # keyboard focus: exactly one (Godot's model)
    capture: int         # the mouse stays captured by whoever pressed, until release
    hover: int
    theme: Theme
    cell_w: int          # the font cell, given from outside
    cell_h: int
    lay_w: int           # the size of the last layout (to redo it)
    lay_h: int
    needs_draw: bool     # something went dirty since the last draw: the loop looks at this
                         #   instead of repainting on every event

    # ---------- the tree ----------

    def node(self, id: int) -> Node:
        return self.nodes[id]

    def rect_of(self, id: int) -> Rect:
        return self.nodes[id].rect

    def data_of(self, id: int) -> any?:
        return self.nodes[id].data

    def is_vis(self, id: int) -> bool:
        return self.nodes[id].visible

    def unlink(self, id: int):
        nd = self.nodes[id]
        p = nd.parent
        if p < 0:
            nd.next_sibling = -1
            return
        pn = self.nodes[p]
        if pn.first_child == id:
            pn.first_child = nd.next_sibling
        else:
            s = pn.first_child
            while s >= 0 and self.nodes[s].next_sibling != id:
                s = self.nodes[s].next_sibling
            if s >= 0:
                self.nodes[s].next_sibling = nd.next_sibling
        nd.parent = -1
        nd.next_sibling = -1

    def link_last(self, id: int, parent: int):
        self.nodes[id].parent = parent
        self.nodes[id].next_sibling = -1
        if parent < 0:
            return
        fc = self.nodes[parent].first_child
        if fc < 0:
            self.nodes[parent].first_child = id
            return
        while self.nodes[fc].next_sibling >= 0:
            fc = self.nodes[fc].next_sibling
        self.nodes[fc].next_sibling = id

    def new_node(self, kind: WKind, parent: int) -> int:
        id = 0
        if self.free_head >= 0:
            id = self.free_head
            self.free_head = self.nodes[id].next_sibling
            self.nodes[id] = new_node_blank()
        else:
            id = len(self.nodes)
            self.nodes.append(new_node_blank())
        nd = self.nodes[id]
        nd.kind = kind
        nd.alive = True
        self.link_last(id, parent)
        if parent < 0 and self.root < 0:
            self.root = id
        return id

    def free_node(self, id: int):
        # a parent may draw as a function of its children: one leaves, it dirties
        p0 = self.nodes[id].parent
        if p0 >= 0:
            self.queue_redraw(p0)
        self.needs_draw = True
        c = self.nodes[id].first_child
        while c >= 0:
            nx = self.nodes[c].next_sibling
            self.free_node(c)
            c = nx
        self.unlink(id)
        nd = self.nodes[id]
        nd.alive = False
        nd.kind = WK_NONE
        nd.cmds = []
        nd.text = ""
        nd.data = None
        nd.c_min = None
        nd.c_build = None
        nd.c_input = None
        nd.c_layout = None
        nd.first_child = -1
        if self.focus == id:
            self.focus = -1
        if self.capture == id:
            self.capture = -1
        if self.hover == id:
            self.hover = -1
        if self.root == id:
            self.root = -1
        nd.next_sibling = self.free_head
        self.free_head = id

    def reparent(self, id: int, new_parent: int):
        self.unlink(id)
        self.link_last(id, new_parent)

    # ---------- constructors ----------

    def panel(self, parent: int) -> int:
        return self.new_node(WK_PANEL, parent)

    def box(self, parent: int, vertical: bool) -> int:
        id = self.new_node(WK_BOX, parent)
        self.nodes[id].vertical = vertical
        return id

    def split(self, parent: int, vertical: bool) -> int:
        id = self.new_node(WK_SPLIT, parent)
        self.nodes[id].vertical = vertical
        self.nodes[id].offset = 200
        return id

    def label(self, parent: int, text: str) -> int:
        id = self.new_node(WK_LABEL, parent)
        self.nodes[id].text = text
        return id

    def button(self, parent: int, text: str) -> int:
        id = self.new_node(WK_BUTTON, parent)
        self.nodes[id].text = text
        self.nodes[id].focusable = True
        return id

    def scrollbar(self, parent: int, vertical: bool) -> int:
        id = self.new_node(WK_SCROLLBAR, parent)
        self.nodes[id].vertical = vertical
        return id

    def line_input(self, parent: int) -> int:
        id = self.new_node(WK_INPUT, parent)
        self.nodes[id].focusable = True
        return id

    def custom(self, parent: int, data: any?) -> int:
        """The app's widget. The functions come afterwards (`set_custom`),
        because one of them normally needs the id this constructor just gave."""
        id = self.new_node(WK_CUSTOM, parent)
        self.nodes[id].data = data
        return id

    def set_custom(self, id: int, c_min: (def(Ui, int) -> Size)?, c_build: def(Ui, int)?,
                   c_input: (def(Ui, int, Event) -> bool)?, c_layout: def(Ui, int, Rect)?):
        nd = self.nodes[id]
        nd.c_min = c_min
        nd.c_build = c_build
        nd.c_input = c_input
        nd.c_layout = c_layout

    # ---------- properties ----------

    def set_expand(self, id: int, h: bool, v: bool):
        self.nodes[id].expand_h = h
        self.nodes[id].expand_v = v

    def set_min(self, id: int, w: int, h: int):
        self.nodes[id].min_w = w
        self.nodes[id].min_h = h

    def set_stretch(self, id: int, weight: int):
        self.nodes[id].stretch = weight if weight > 0 else 1

    def set_bg(self, id: int, color: int):
        self.nodes[id].bg = color
        self.queue_redraw(id)

    def set_pad(self, id: int, px: int):
        self.nodes[id].pad = px
        self.queue_redraw(id)

    def set_visible(self, id: int, vis: bool):
        nd = self.nodes[id]
        if nd.visible == vis:
            return
        nd.visible = vis
        if vis:
            nd.dirty = True
        elif self.focus == id:
            self.focus = -1
        self.relayout()

    def is_visible(self, id: int) -> bool:
        return self.nodes[id].visible

    def set_focusable(self, id: int, f: bool):
        self.nodes[id].focusable = f

    def set_text(self, id: int, text: str):
        nd = self.nodes[id]
        if nd.kind == WK_INPUT:
            nd.text = text
            nd.cursor = len(text)
        else:
            if nd.text == text:
                return          # the same text: nothing changed, so no repaint
            nd.text = text
        self.queue_redraw(id)

    def text_of(self, id: int) -> str:
        return self.nodes[id].text

    def input_clear(self, id: int):
        self.set_text(id, "")

    def set_rect(self, id: int, r: Rect):
        nd = self.nodes[id]
        old = nd.rect
        nd.rect = r
        if old.x != r.x or old.y != r.y or old.w != r.w or old.h != r.h:
            nd.dirty = True
            self.needs_draw = True

    def queue_redraw(self, id: int):
        self.nodes[id].dirty = True
        self.needs_draw = True

    def queue_redraw_tree(self, id: int):
        self.nodes[id].dirty = True
        self.needs_draw = True
        c = self.nodes[id].first_child
        while c >= 0:
            self.queue_redraw_tree(c)
            c = self.nodes[c].next_sibling

    # ---------- signals ----------

    def on_click(self, id: int, fn: def(int, int)?):
        self.nodes[id].sig_click = fn

    def on_scroll(self, id: int, fn: def(int, int)?):
        self.nodes[id].sig_scroll = fn

    def on_changed(self, id: int, fn: def(int, int)?):
        self.nodes[id].sig_changed = fn

    def on_submit(self, id: int, fn: def(int, int)?):
        self.nodes[id].sig_submit = fn

    def on_cancel(self, id: int, fn: def(int, int)?):
        self.nodes[id].sig_cancel = fn

    # ---------- split and scrollbar ----------

    def split_set(self, id: int, offset: int):
        self.nodes[id].offset = offset
        self.relayout()

    def split_offset(self, id: int) -> int:
        return self.nodes[id].offset

    def scroll_set(self, id: int, total: int, page: int, value: int):
        nd = self.nodes[id]
        nd.total = total if total > 0 else 1
        nd.page = page if page > 0 else 1
        hi = nd.total - nd.page
        if hi < 0:
            hi = 0
        nd.value = 0 if value < 0 else (hi if value > hi else value)
        self.queue_redraw(id)

    def scroll_value(self, id: int) -> int:
        return self.nodes[id].value

    # ---------- focus ----------

    def focus_set(self, id: int):
        if self.focus == id:
            return
        old = self.focus
        self.focus = id
        if old >= 0 and self.nodes[old].alive:
            self.queue_redraw(old)
        if id >= 0:
            self.queue_redraw(id)

    def focus_get(self) -> int:
        return self.focus

    # ---------- phase 1: the minimum, which goes up ----------

    def text_w(self, s: str) -> int:
        return len(s) * self.cell_w

    def measure(self, id: int):
        c = self.nodes[id].first_child
        while c >= 0:                     # post-order: the children first
            self.measure(c)
            c = self.nodes[c].next_sibling
        nd = self.nodes[id]
        th = self.theme
        w = 0
        h = 0
        match nd.kind:
            case WK_LABEL:
                w = self.text_w(nd.text)
                h = self.cell_h
            case WK_BUTTON:
                w = self.text_w(nd.text) + th.pad * 2
                h = self.cell_h + th.pad * 2
            case WK_INPUT:
                w = self.cell_w * 8
                h = self.cell_h + th.pad
            case WK_SCROLLBAR:
                w = th.handle * 2 if nd.vertical else 0
                h = 0 if nd.vertical else th.handle * 2
            case WK_BOX:
                nvis = 0
                c = nd.first_child
                while c >= 0:
                    if self.is_vis(c):
                        cn = self.nodes[c]
                        if nd.vertical:
                            h += cn.ch
                            w = cn.cw if cn.cw > w else w
                        else:
                            w += cn.cw
                            h = cn.ch if cn.ch > h else h
                        nvis += 1
                    c = self.nodes[c].next_sibling
                if nvis > 1:
                    if nd.vertical:
                        h += th.sep * (nvis - 1)
                    else:
                        w += th.sep * (nvis - 1)
            case WK_SPLIT:
                c = nd.first_child
                while c >= 0:
                    if self.is_vis(c):
                        cn2 = self.nodes[c]
                        if nd.vertical:
                            h += cn2.ch
                            w = cn2.cw if cn2.cw > w else w
                        else:
                            w += cn2.cw
                            h = cn2.ch if cn2.ch > h else h
                    c = self.nodes[c].next_sibling
                if nd.vertical:
                    h += th.handle
                else:
                    w += th.handle
            case WK_PANEL:
                c = nd.first_child
                while c >= 0:
                    if self.is_vis(c):
                        cn3 = self.nodes[c]
                        w = cn3.cw if cn3.cw > w else w
                        h = cn3.ch if cn3.ch > h else h
                    c = self.nodes[c].next_sibling
            case WK_CUSTOM:
                fmin = nd.c_min
                if fmin != None:
                    sz = fmin(self, id)
                    w = sz.w
                    h = sz.h
            case _:
                pass
        if nd.min_w > w:
            w = nd.min_w
        if nd.min_h > h:
            h = nd.min_h
        nd.cw = w
        nd.ch = h

    # ---------- phase 2: the rectangle, which comes down ----------

    # BoxContainer::_resort: sums the minimums and shares out what is left among
    # the children with EXPAND, in proportion to the weight, with an integer error accumulator
    def lay_box(self, id: int, r: Rect):
        nd = self.nodes[id]
        vert = nd.vertical
        sep = self.theme.sep
        nvis = 0
        combined_min = 0
        ratio_total = 0
        c = nd.first_child
        while c >= 0:
            if self.is_vis(c):
                cn = self.nodes[c]
                combined_min += cn.ch if vert else cn.cw
                if cn.expand_v if vert else cn.expand_h:
                    ratio_total += cn.stretch
                nvis += 1
            c = self.nodes[c].next_sibling
        if nvis == 0:
            return
        space = (r.h if vert else r.w) - sep * (nvis - 1)
        stretch_diff = space - combined_min
        if stretch_diff < 0:
            stretch_diff = 0
        err = 0
        pos = r.y if vert else r.x
        c = nd.first_child
        while c >= 0:
            nx = self.nodes[c].next_sibling
            if self.is_vis(c):
                cn2 = self.nodes[c]
                size = cn2.ch if vert else cn2.cw
                if (cn2.expand_v if vert else cn2.expand_h) and ratio_total > 0:
                    share = stretch_diff * cn2.stretch
                    size += share // ratio_total
                    err += share % ratio_total
                    if err >= ratio_total:
                        size += 1
                        err -= ratio_total
                if vert:
                    self.lay_assign(c, Rect(r.x, pos, r.w, size))
                else:
                    self.lay_assign(c, Rect(pos, r.y, size, r.h))
                pos += size + sep
            c = nx

    # SplitContainer: the offset is pinned between the first child's minimum and
    # what is left after the second's; the divider lives between the two
    def lay_split(self, id: int, r: Rect):
        nd = self.nodes[id]
        vert = nd.vertical
        a = -1
        b = -1
        c = nd.first_child
        while c >= 0:
            if self.is_vis(c):
                if a < 0:
                    a = c
                elif b < 0:
                    b = c
            c = self.nodes[c].next_sibling
        if a < 0:
            return
        axis = r.h if vert else r.w
        if b < 0:
            self.lay_assign(a, r)
            return
        hs = self.theme.handle
        amin = self.nodes[a].ch if vert else self.nodes[a].cw
        bmin = self.nodes[b].ch if vert else self.nodes[b].cw
        off = nd.offset
        if off > axis - hs - bmin:
            off = axis - hs - bmin
        if off < amin:
            off = amin
        if off < 0:
            off = 0
        nd.offset = off
        if vert:
            self.lay_assign(a, Rect(r.x, r.y, r.w, off))
            self.lay_assign(b, Rect(r.x, r.y + off + hs, r.w, axis - off - hs))
        else:
            self.lay_assign(a, Rect(r.x, r.y, off, r.h))
            self.lay_assign(b, Rect(r.x + off + hs, r.y, axis - off - hs, r.h))

    def lay_assign(self, id: int, r: Rect):
        self.set_rect(id, r)
        nd = self.nodes[id]
        match nd.kind:
            case WK_BOX:
                self.lay_box(id, r)
            case WK_SPLIT:
                self.lay_split(id, r)
            case WK_CUSTOM:
                flay = nd.c_layout
                if flay != None:
                    flay(self, id, r)          # the app positions its own children
                    return
                self.lay_stack(id, r)
            case _:
                self.lay_stack(id, r)

    def lay_stack(self, id: int, r: Rect):
        """PANEL and leaves: the children take the whole rectangle."""
        c = self.nodes[id].first_child
        while c >= 0:
            if self.is_vis(c):
                self.lay_assign(c, r)
            c = self.nodes[c].next_sibling

    def layout(self, w: int, h: int):
        self.lay_w = w
        self.lay_h = h
        self.needs_draw = True
        if self.root < 0:
            return
        self.measure(self.root)
        self.lay_assign(self.root, Rect(0, 0, w, h))

    def relayout(self):
        if self.lay_w > 0:
            self.layout(self.lay_w, self.lay_h)

    # ---------- the commands ----------

    def cmd_rect(self, id: int, r: Rect, color: int):
        self.nodes[id].cmds.append(Cmd(CMD_RECT, r.x, r.y, r.w, r.h, color, 0, ""))

    def cmd_frame(self, id: int, r: Rect, color: int):
        self.nodes[id].cmds.append(Cmd(CMD_FRAME, r.x, r.y, r.w, r.h, color, 0, ""))

    def cmd_text(self, id: int, x: int, y: int, text: str, color: int):
        self.nodes[id].cmds.append(Cmd(CMD_TEXT, x, y, 0, 0, color, 0, text))

    def cmd_glyph(self, id: int, x: int, y: int, cp: int, color: int):
        self.nodes[id].cmds.append(Cmd(CMD_GLYPH, x, y, 0, 0, color, cp, ""))

    def cmd_text_fit(self, id: int, x: int, y: int, text: str, max_w: int, color: int) -> int:
        """`text` cut to `max_w` pixels, ending in `…` when it does not fit.
        Returns the width drawn, so whoever builds columns knows where the next
        one can begin. Whoever draws text they did not measure goes through here:
        clipping the widget only HIDES the excess, it still paints over the
        frame the box was supposed to respect."""
        cw = self.cell_w
        if max_w < cw or len(text) == 0:
            return 0
        w = self.text_w(text)
        if w <= max_w:
            self.cmd_text(id, x, y, text, color)
            return w
        budget = max_w // cw - 1        # one cell belongs to the …
        if budget > 0:
            self.cmd_text(id, x, y, text[0:budget], color)
        self.cmd_glyph(id, x + budget * cw, y, CP_ELLIPSIS, color)
        return (budget + 1) * cw

    # ---------- the construction, by type ----------

    def scroll_thumb(self, id: int) -> Rect:
        nd = self.nodes[id]
        r = nd.rect
        axis = r.h if nd.vertical else r.w
        tl = axis * nd.page // nd.total
        if tl < 16:
            tl = 16
        if tl > axis:
            tl = axis
        hi = nd.total - nd.page
        tp = 0
        if hi > 0:
            tp = (axis - tl) * nd.value // hi
        if nd.vertical:
            return Rect(r.x + 2, r.y + tp, r.w - 4, tl)
        return Rect(r.x + tp, r.y + 2, tl, r.h - 4)

    def build_node(self, id: int):
        nd = self.nodes[id]
        nd.cmds = []
        th = self.theme
        r = nd.rect
        lh = self.cell_h
        if nd.bg != 0:
            self.cmd_rect(id, r, nd.bg)
        match nd.kind:
            case WK_PANEL:
                self.cmd_rect(id, r, th.panel)
            case WK_LABEL:
                self.cmd_text(id, r.x + nd.pad, r.y + (r.h - lh) // 2, nd.text, th.text)
            case WK_BUTTON:
                bg = th.panel_hi
                if nd.pressed:
                    bg = th.panel_lo
                elif nd.hover:
                    bg = 0xFF45484D
                self.cmd_rect(id, r, bg)
                self.cmd_frame(id, r, th.border)
                tw = self.text_w(nd.text)
                self.cmd_text(id, r.x + (r.w - tw) // 2, r.y + (r.h - lh) // 2, nd.text, th.text)
            case WK_INPUT:
                self.cmd_rect(id, r, th.panel_lo)
                self.cmd_frame(id, r, th.accent if self.focus == id else th.border)
                tx = r.x + (nd.pad if nd.pad > 0 else 4)
                ty = r.y + (r.h - lh) // 2
                self.cmd_text(id, tx, ty, nd.text, th.text)
                if self.focus == id:
                    self.cmd_rect(id, Rect(tx + nd.cursor * self.cell_w, ty, 1, lh), th.text)
            case WK_SPLIT:
                hs = th.handle
                if nd.vertical:
                    self.cmd_rect(id, Rect(r.x, r.y + nd.offset, r.w, hs), th.border)
                else:
                    self.cmd_rect(id, Rect(r.x + nd.offset, r.y, hs, r.h), th.border)
            case WK_SCROLLBAR:
                self.cmd_rect(id, r, th.panel_lo)
                self.cmd_rect(id, self.scroll_thumb(id), th.panel_hi)
            case WK_CUSTOM:
                fbld = nd.c_build
                if fbld != None:
                    fbld(self, id)
            case _:
                pass
        nd.dirty = False

    def build_dirty(self, id: int) -> int:
        """Rewrites whoever went dirty, and returns how many commands the tree
        has. It is `draw` without the `Painter` — what a headless test measures."""
        if not self.is_vis(id):
            return 0
        if self.nodes[id].dirty:
            self.build_node(id)
        n = len(self.nodes[id].cmds)
        c = self.nodes[id].first_child
        while c >= 0:
            n += self.build_dirty(c)
            c = self.nodes[c].next_sibling
        return n

    def build_all(self) -> int:
        return 0 if self.root < 0 else self.build_dirty(self.root)

    # ---------- the drawing ----------

    def draw_walk(self, p: Painter, id: int, clip: Rect):
        if not self.is_vis(id):
            return
        nclip = rect_inter(clip, self.nodes[id].rect)
        if rect_empty(nclip):
            return
        if self.nodes[id].dirty:
            self.build_node(id)
        nd = self.nodes[id]
        p.clip(nclip.x, nclip.y, nclip.w, nclip.h)
        for cm in nd.cmds:
            match cm.kind:
                case CMD_RECT:
                    p.rect(cm.x, cm.y, cm.w, cm.h, cm.color)
                case CMD_FRAME:
                    p.frame(cm.x, cm.y, cm.w, cm.h, cm.color)
                case CMD_TEXT:
                    gx = cm.x
                    for ch in cm.text:
                        p.glyph(ord(ch), gx, cm.y, cm.color)
                        gx += self.cell_w
                case CMD_GLYPH:
                    p.glyph(cm.cp, cm.x, cm.y, cm.color)
        c = nd.first_child
        while c >= 0:
            self.draw_walk(p, c, nclip)
            c = self.nodes[c].next_sibling

    def draw(self, p: Painter, w: int, h: int):
        self.needs_draw = False
        p.clip_off()
        p.rect(0, 0, w, h, self.theme.bg)
        if self.root >= 0:
            self.draw_walk(p, self.root, Rect(0, 0, w, h))
        p.clip_off()

    # ---------- the input ----------

    def hit_walk(self, id: int, x: int, y: int) -> int:
        if not self.is_vis(id) or not rect_has(self.nodes[id].rect, x, y):
            return -1
        best = id                  # the last child containing the point wins
        c = self.nodes[id].first_child
        while c >= 0:
            got = self.hit_walk(c, x, y)
            if got >= 0:
                best = got
            c = self.nodes[c].next_sibling
        return best

    def hit(self, x: int, y: int) -> int:
        return -1 if self.root < 0 else self.hit_walk(self.root, x, y)

    def emit(self, fn: def(int, int)?, id: int, arg: int):
        # the parameter is LOCAL, so the non-null proof holds here (43.1) — it is
        # the reason the signal goes through this function instead of being called in place
        if fn != None:
            fn(id, arg)

    def scroll_apply(self, id: int, pos: int):
        nd = self.nodes[id]
        r = nd.rect
        axis = r.h if nd.vertical else r.w
        t = self.scroll_thumb(id)
        tl = t.h if nd.vertical else t.w
        track = axis - tl
        hi = nd.total - nd.page
        if track <= 0 or hi <= 0:
            return
        rel = pos - (r.y if nd.vertical else r.x) - nd.grab
        v = rel * hi // track
        if v < 0:
            v = 0
        if v > hi:
            v = hi
        if v != nd.value:
            nd.value = v
            self.queue_redraw(id)
            self.emit(nd.sig_scroll, id, nd.value)

    def input_insert(self, id: int, s: str):
        nd = self.nodes[id]
        nd.text = nd.text[0:nd.cursor] + s + nd.text[nd.cursor:len(nd.text)]
        nd.cursor += len(s)
        self.queue_redraw(id)
        self.emit(nd.sig_changed, id, 0)

    def input_edit(self, id: int, ev: Event) -> bool:
        nd = self.nodes[id]
        if ev.kind == EV_TEXT:
            self.input_insert(id, chr(ev.cp))
            return True
        if ev.kind != EV_KEY:
            return False
        ncp = len(nd.text)
        if ev.key == K_BACKSPACE:
            if nd.cursor > 0:
                nd.text = nd.text[0:nd.cursor - 1] + nd.text[nd.cursor:ncp]
                nd.cursor -= 1
                self.queue_redraw(id)
                self.emit(nd.sig_changed, id, 0)
            return True
        if ev.key == K_DELETE:
            if nd.cursor < ncp:
                nd.text = nd.text[0:nd.cursor] + nd.text[nd.cursor + 1:ncp]
                self.queue_redraw(id)
                self.emit(nd.sig_changed, id, 0)
            return True
        if ev.key == K_LEFT:
            if nd.cursor > 0:
                nd.cursor -= 1
                self.queue_redraw(id)
            return True
        if ev.key == K_RIGHT:
            if nd.cursor < ncp:
                nd.cursor += 1
                self.queue_redraw(id)
            return True
        if ev.key == K_HOME:
            nd.cursor = 0
            self.queue_redraw(id)
            return True
        if ev.key == K_END:
            nd.cursor = ncp
            self.queue_redraw(id)
            return True
        if ev.key == K_RETURN:
            self.emit(nd.sig_submit, id, 0)
            return True
        if ev.key == K_ESCAPE:
            self.emit(nd.sig_cancel, id, 0)
            return True
        return False

    def node_input(self, id: int, ev: Event) -> bool:
        """The input aimed at ONE widget; True = consumed."""
        nd = self.nodes[id]
        match nd.kind:
            case WK_BUTTON:
                if ev.kind == EV_MOUSE_DOWN and ev.button == 1:
                    nd.pressed = True
                    self.queue_redraw(id)
                    return True
                if ev.kind == EV_MOUSE_UP and ev.button == 1:
                    was = nd.pressed
                    nd.pressed = False
                    self.queue_redraw(id)
                    if was and rect_has(nd.rect, ev.x, ev.y):
                        self.emit(nd.sig_click, id, 0)
                    return True
                if ev.kind == EV_KEY and (ev.key == K_RETURN or ev.key == K_SPACE):
                    self.emit(nd.sig_click, id, 0)
                    return True
            case WK_INPUT:
                if ev.kind == EV_MOUSE_DOWN and ev.button == 1:
                    cw = self.cell_w
                    inset = nd.pad if nd.pad > 0 else 4
                    rel = (ev.x - (nd.rect.x + inset) + cw // 2) // cw
                    ncp = len(nd.text)
                    nd.cursor = 0 if rel < 0 else (ncp if rel > ncp else rel)
                    self.queue_redraw(id)
                    return True
                return self.input_edit(id, ev)
            case WK_SCROLLBAR:
                vert0 = nd.vertical
                if ev.kind == EV_MOUSE_DOWN and ev.button == 1:
                    t = self.scroll_thumb(id)
                    pp = ev.y if vert0 else ev.x
                    if rect_has(t, ev.x, ev.y):
                        nd.dragging = True
                        nd.grab = pp - (t.y if vert0 else t.x)
                    else:
                        # a click on the track: jump one page that way
                        nv = nd.value - nd.page if pp < (t.y if vert0 else t.x) else nd.value + nd.page
                        self.scroll_set(id, nd.total, nd.page, nv)
                        self.emit(nd.sig_scroll, id, nd.value)
                    return True
                if ev.kind == EV_MOUSE_MOVE and nd.dragging:
                    self.scroll_apply(id, ev.y if vert0 else ev.x)
                    return True
                if ev.kind == EV_MOUSE_UP:
                    nd.dragging = False
                    return True
                if ev.kind == EV_WHEEL:
                    step = nd.page // 8
                    self.scroll_set(id, nd.total, nd.page,
                                    nd.value - ev.wheel * (step if step > 0 else 1))
                    self.emit(nd.sig_scroll, id, nd.value)
                    return True
            case WK_SPLIT:
                vert = nd.vertical
                r = nd.rect
                hr = Rect(r.x, r.y + nd.offset, r.w, self.theme.handle) if vert else Rect(r.x + nd.offset, r.y, self.theme.handle, r.h)
                if ev.kind == EV_MOUSE_DOWN and ev.button == 1 and rect_has(hr, ev.x, ev.y):
                    nd.dragging = True
                    nd.grab = (ev.y if vert else ev.x) - nd.offset
                    return True
                if ev.kind == EV_MOUSE_MOVE and nd.dragging:
                    nd.offset = (ev.y if vert else ev.x) - nd.grab
                    self.relayout()
                    self.queue_redraw(id)
                    return True
                if ev.kind == EV_MOUSE_UP and nd.dragging:
                    nd.dragging = False
                    return True
            case WK_CUSTOM:
                finp = nd.c_input
                if finp != None:
                    return finp(self, id, ev)
            case _:
                pass
        return False

    def set_hover(self, id: int):
        if self.hover == id:
            return
        old = self.hover
        self.hover = id
        if old >= 0 and self.nodes[old].alive:
            self.nodes[old].hover = False
            self.queue_redraw(old)
        if id >= 0:
            self.nodes[id].hover = True
            self.queue_redraw(id)

    def input_event(self, ev: Event) -> bool:
        match ev.kind:
            case EV_MOUSE_DOWN:
                t = self.hit(ev.x, ev.y)
                if t < 0:
                    return False
                # focus: the target if focusable, else the nearest focusable ancestor
                f = t
                while f >= 0 and not self.nodes[f].focusable:
                    f = self.nodes[f].parent
                if f >= 0:
                    self.focus_set(f)
                # bubbles up until somebody consumes it (this is where the split takes the divider)
                h = t
                while h >= 0:
                    if self.node_input(h, ev):
                        self.capture = h
                        return True
                    h = self.nodes[h].parent
                return False
            case EV_MOUSE_UP:
                if self.capture >= 0:
                    c = self.capture
                    self.capture = -1
                    self.node_input(c, ev)
                    return True
                return False
            case EV_MOUSE_MOVE:
                if self.capture >= 0:
                    return self.node_input(self.capture, ev)
                t2 = self.hit(ev.x, ev.y)
                self.set_hover(t2)
                # hands the movement to whoever is under the cursor, bubbling up
                # until it is consumed (Godot's `_gui_input`): it is how one part of
                # a composite widget lights up without capturing the mouse
                while t2 >= 0:
                    if self.node_input(t2, ev):
                        return True
                    t2 = self.nodes[t2].parent
                return False
            case EV_WHEEL:
                w = self.hit(ev.x, ev.y)
                while w >= 0:
                    if self.node_input(w, ev):
                        return True
                    w = self.nodes[w].parent
                return False
            case EV_KEY, EV_TEXT:
                if self.focus >= 0 and self.nodes[self.focus].alive:
                    return self.node_input(self.focus, ev)
                return False
            case _:
                pass
        return False


def new_ui(cell_w: int, cell_h: int) -> Ui:
    """The font cell comes from outside: the toolkit does not talk to the driver,
    and that is what lets the layout be measured without a window."""
    return Ui([], -1, -1, -1, -1, -1, theme_dark(), cell_w, cell_h, 0, 0, False)
