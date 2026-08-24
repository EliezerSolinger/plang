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
