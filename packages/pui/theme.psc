"""The theme: eight numbers, and everything else derived from them.

The rule, in the words that decided it: *"criar uma estrutura de variáveis que
juntas formam o tema, como se fosse uma espécie de variáveis raiz de bootstrap;
você altera elas e consegue trocar todos os temas, porque todas as camadas
abaixo não usam cores diretamente mas referências como cor primária"*.

So **no layer uses a colour directly.** A widget asks for a ROLE — `panel_hi`,
`text_dim`, `syn_comment` — and each role is computed from a root. A theme is
eight numbers; a theme somebody has argued with is eight numbers plus the few
roles they overrode, because **overriding a role beats the derivation**.

Before this, `theme_dark()` was thirteen concrete fields and the editing widget
had twenty-one colour literals spread through it — the gutter, the caret, the
marks, the fold, the minimap and the five of the syntax. A second theme meant
finding all of them, and every widget written after would have added one more.

**Why the syntax colours are here** and not in the editor: two of the eight roots
ARE syntax (`string` and `keyword`). Splitting the palette in two would mean two
places to change to change one look, which is the thing this file exists to
prevent. The cost is that a `pui` used for something that is not an editor
carries five roles it does not ask for.

Colours are `0xAARRGGBB`, the same as everywhere else in the toolkit.
"""


record Roots:
    """A whole theme. Eight numbers, and each one names a MEANING rather than a
    place — which is what lets a role be derived from it."""
    surface: int      # every background: the page, the panels, the gutter, the bars
    on_surface: int   # every foreground: text, icons, line numbers
    primary: int      # accent, focus, selection, the caret
    danger: int       # errors, breakpoints, a failing test
    warning: int      # warnings, a folded block, something modified
    ok: int           # success, and comments
    string: int       # string and character literals
    keyword: int      # the words of the language, and types


record Theme:
    """The roles a widget may ask for. Nothing outside this file writes a colour.

    The three at the end are METRICS and not colours: they are here because they
    are the other half of "what this toolkit looks like", and a theme that
    changed the colours but not the padding would only be half a theme."""
    # ---- surfaces ----
    bg: int
    panel: int
    panel_hi: int         # hover
    panel_lo: int         # pressed / sunken
    border: int
    # ---- foreground ----
    text: int
    text_dim: int
    accent: int
    sel: int              # a selection's background
    # ---- the editing surface ----
    gutter: int
    gutter_text: int
    gutter_text_hi: int   # the line the caret is on
    cur_line: int         # ... and its background
    caret: int
    indent_guide: int
    match_brace: int      # the bracket matching the one under the caret
    popup: int            # the completion popup
    popup_sel: int
    minimap: int
    minimap_view: int     # the box showing what is on screen
    # ---- the gutter's marks ----
    mark_break: int
    mark_book: int
    mark_error: int
    fold_open: int
    fold_closed: int
    # ---- syntax ----
    syn_text: int
    syn_kw: int
    syn_str: int
    syn_num: int
    syn_comment: int
    # ---- the sixteen a terminal asks for ----
    #
    # They are ROLES like everything else, and they are derived from the same
    # eight roots: red IS danger, green IS ok, blue IS primary. So a terminal in
    # the light theme is a light terminal, and nobody had to write a second
    # palette to get one.
    #
    # "Bright" is a step further from the page and towards the text — which is
    # lighter on a dark page and darker on a light one, the same sentence
    # `contrast` is built on. Taking it to mean "add white" is what makes a
    # light theme's bright colours vanish into it.
    ansi_black: int
    ansi_red: int
    ansi_green: int
    ansi_yellow: int
    ansi_blue: int
    ansi_magenta: int
    ansi_cyan: int
    ansi_white: int
    # ---- metrics ----
    pad: int              # inner breathing room (buttons and the like)
    sep: int              # separation between a BOX's children
    handle: int           # thickness of the divider and of the bar


# ---------- the arithmetic ----------
#
# Eight roots cannot cover thirty roles by themselves; what covers them is these
# four functions, and they are the reason a theme is eight numbers.

def clamp8(v: int) -> int:
    return 0 if v < 0 else (255 if v > 255 else v)


def chan(c: int, shift: int) -> int:
    return (c >> shift) & 0xFF


def rgba(a: int, r: int, g: int, b: int) -> int:
    return (a << 24) | (clamp8(r) << 16) | (clamp8(g) << 8) | clamp8(b)


def lighten(c: int, pct: int) -> int:
    """Towards white by `pct` per cent of the distance."""
    r = chan(c, 16)
    g = chan(c, 8)
    b = chan(c, 0)
    return rgba(chan(c, 24), r + (255 - r) * pct // 100,
                g + (255 - g) * pct // 100, b + (255 - b) * pct // 100)


def darken(c: int, pct: int) -> int:
    """Towards black by `pct` per cent."""
    return rgba(chan(c, 24), chan(c, 16) * (100 - pct) // 100,
                chan(c, 8) * (100 - pct) // 100, chan(c, 0) * (100 - pct) // 100)


def mix(a: int, b: int, pct: int) -> int:
    """`pct` per cent of `a` over `b`. The alpha is `a`'s."""
    return rgba(chan(a, 24),
                (chan(a, 16) * pct + chan(b, 16) * (100 - pct)) // 100,
                (chan(a, 8) * pct + chan(b, 8) * (100 - pct)) // 100,
                (chan(a, 0) * pct + chan(b, 0) * (100 - pct)) // 100)


def fade(c: int, a: int) -> int:
    """The same colour at another opacity — for the minimap, which reads as a
    texture rather than as text."""
    return (c & 0x00FFFFFF) | (clamp8(a) << 24)


# ---------- the derivation ----------

def contrast(r: Roots, pct: int) -> int:
    """A surface `pct` per cent of the way from the page towards the text.

    This is the one idea that makes a light theme need no formulas of its own. A
    raised panel is not "lighter": it is a step AWAY from the page and towards
    what is written on it — which is lighter on a dark page and darker on a light
    one, automatically, because both directions are the same sentence."""
    return mix(r.on_surface, r.surface, pct)


def derive(r: Roots) -> Theme:
    """Thirty roles out of eight roots.

    The percentages are not arbitrary: they say a RELATIONSHIP. `panel` is a
    surface one step off the page, `panel_hi` is two — which is what "hover"
    means — and `panel_lo` is half a step, which is what "pressed" means: less
    raised, not darker.

    Two roles do not use `contrast` and the exception is the point of writing it
    down: a BORDER and the minimap are shadows, and a shadow is darker on any
    page. Deriving them with `contrast` gave a light theme a border LIGHTER than
    its own background — invisible, and only visible as a bug once somebody
    looked at the light theme."""
    return Theme(
        bg           = r.surface,
        panel        = contrast(r, 7),
        panel_hi     = contrast(r, 15),
        panel_lo     = contrast(r, 3),
        border       = darken(r.surface, 22),
        text         = r.on_surface,
        text_dim     = contrast(r, 55),
        accent       = r.primary,
        sel          = mix(r.primary, r.surface, 28),
        gutter       = contrast(r, 4),
        gutter_text  = contrast(r, 40),
        gutter_text_hi = contrast(r, 75),
        cur_line     = contrast(r, 5),
        caret        = mix(r.on_surface, r.primary, 80),
        indent_guide = contrast(r, 12),
        match_brace  = mix(r.primary, r.surface, 45),
        popup        = contrast(r, 7),
        popup_sel    = mix(r.primary, r.surface, 35),
        minimap      = darken(r.surface, 10),
        minimap_view = fade(r.on_surface, 0x18),
        mark_break   = r.danger,
        mark_book    = r.primary,
        mark_error   = r.danger,
        fold_open    = contrast(r, 40),
        fold_closed  = r.warning,
        syn_text     = r.on_surface,
        syn_kw       = r.keyword,
        syn_str      = r.string,
        syn_num      = mix(r.ok, r.on_surface, 45),
        syn_comment  = r.ok,
        ansi_black   = contrast(r, 18),
        ansi_red     = r.danger,
        ansi_green   = r.ok,
        ansi_yellow  = r.warning,
        ansi_blue    = r.primary,
        ansi_magenta = r.keyword,
        ansi_cyan    = mix(r.primary, r.ok, 50),
        ansi_white   = r.on_surface,
        pad          = 6,
        sep          = 4,
        handle       = 6)


# Functions and not constants, because a module in pscript holds no state: an
# imported module is a set of definitions, not a program to run.

def dark_roots() -> Roots:
    """The eight the editor has always looked like. The five that are not
    surface/foreground/primary come from the syntax it was already painting."""
    return Roots(0xFF1E1F22, 0xFFD4D4D4, 0xFF4F9CF7, 0xFFE05252,
                 0xFFD0A050, 0xFF6A9955, 0xFFCE9178, 0xFFC586C0)


def light_roots() -> Roots:
    """The same eight meanings, inverted. It is the whole light theme — the
    derivation notices which way round the two first roots are and lifts or sinks
    accordingly."""
    return Roots(0xFFFAFAFA, 0xFF1F2328, 0xFF0969DA, 0xFFCF222E,
                 0xFF9A6700, 0xFF1A7F37, 0xFFA31515, 0xFF8250DF)


def theme_dark() -> Theme:
    return derive(dark_roots())


def theme_light() -> Theme:
    return derive(light_roots())


# ---------- what a terminal asks for ----------
#
# A terminal names colours by NUMBER, and the numbers mean three different
# things: 0..15 are the sixteen a theme owns, 16..231 are a 6x6x6 cube and
# 232..255 a grey ramp. The last two are absolute by definition — a program that
# asks for 196 wants that red, and every terminal in the world gives it that red
# — so they are computed here rather than derived, and this file stays the only
# place in the toolkit where a colour is written down.

def base16(t: Theme, i: int) -> int:
    """0..7. The bright half goes through `bright` on top of this."""
    if i == 0:
        return t.ansi_black
    if i == 1:
        return t.ansi_red
    if i == 2:
        return t.ansi_green
    if i == 3:
        return t.ansi_yellow
    if i == 4:
        return t.ansi_blue
    if i == 5:
        return t.ansi_magenta
    if i == 6:
        return t.ansi_cyan
    return t.ansi_white


def bright(t: Theme, c: int) -> int:
    """A step further from the page, towards what is written on it."""
    return mix(c, t.text, 30)


def cube_level(i: int) -> int:
    """xterm's six levels. They are not evenly spaced, and rounding them to
    51*i is what makes a `ls --color` look washed out next to every other
    terminal."""
    return 0 if i <= 0 else 55 + 40 * i


def ansi(t: Theme, i: int) -> int:
    if i < 0:
        return t.text
    if i < 8:
        return base16(t, i)
    if i < 16:
        return bright(t, base16(t, i - 8))
    if i < 232:
        k = i - 16
        return rgba(0xFF, cube_level(k // 36), cube_level((k // 6) % 6), cube_level(k % 6))
    if i < 256:
        v = 8 + 10 * (i - 232)
        return rgba(0xFF, v, v, v)
    return t.text


def cube_index(v: int) -> int:
    """The nearest of the six levels to one 8-bit channel."""
    if v < 48:
        return 0
    if v < 115:
        return 1
    return clamp8((v - 35) // 40)


def cube_of(r: int, g: int, b: int) -> int:
    """24-bit colour, rounded into the 256 the grid can store.

    A cell keeps an INDEX and not a colour, because an index is a thing the
    theme can still have an opinion about and a colour is not. `38;2;r;g;b` is
    therefore rounded — and saying so is better than storing a colour that no
    theme can ever override."""
    rr = clamp8(r)
    gg = clamp8(g)
    bb = clamp8(b)
    hi = rr if rr > gg else gg
    hi = hi if hi > bb else bb
    lo = rr if rr < gg else gg
    lo = lo if lo < bb else bb
    if hi - lo < 10:
        # a grey: the 24-step ramp is finer than the cube's diagonal
        if rr < 8:
            return 16
        if rr > 238:
            return 231
        return 232 + (rr - 8) * 24 // 240
    n = cube_index(rr)
    if n > 5:
        n = 5
    m = cube_index(gg)
    if m > 5:
        m = 5
    k = cube_index(bb)
    if k > 5:
        k = 5
    return 16 + 36 * n + 6 * m + k
