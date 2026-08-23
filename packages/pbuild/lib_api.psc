"""The compiler's answer 5, read back.

`plangc --api <module>` answers a module's canonical interface — imports, enums,
structs, functions, constants — followed by its HASH and the DOCSTRINGS. It is
an answer made to be read by a machine, and this file is the machine.

The format, deliberately trivial:

    == <path>
    <one declaration per line>
    #hash <16 hex digits>
    #doc <symbol> <text, with \\n escaped>

What you gain by reading this instead of reparsing the source: the list is
already CANONICAL (the compiler normalized it), the docstring is already
separated from the code, and the hash already answers "did this change?" without
comparing text. None of that would be free in a second reader of the language —
and a second reader would diverge, which is the worst possible outcome.
"""

struct Symbol:
    decl: str       # the declaration as the compiler writes it
    name: str       # the name, pulled out so it can be searched for
    doc: str

struct Api:
    path: str
    hash: str
    doc: str            # the module's own
    symbols: list<Symbol>

    def find(self, name: str) -> int:
        i = 0
        while i < len(self.symbols):
            if self.symbols[i].name == name:
                return i
            i += 1
        return -1

# ---------- the name of a declaration ----------
# `def area(i32, i32) -> i64` -> `area`; `struct Point {...}` -> `Point`;
# `enum Shape {...}` -> `Shape`; `const MAX: i32 = 64` -> `MAX`.
def name_of(decl: str) -> str:
    words = decl.split(" ")
    if len(words) < 2:
        return ""
    head = words[0]
    if head == "import" or head == "include":
        return ""
    raw = words[1]
    for cut in ["(", "{", ":", "<"]:
        k = raw.find(cut)
        if k >= 0:
            raw = raw[0:k]
    return raw

private def unescape(s: str) -> str:
    out = ""
    i = 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            if s[i + 1] == "n":
                out += "\n"
                i += 2
                continue
            if s[i + 1] == "\\":
                out += "\\"
                i += 2
                continue
        out += s[i]
        i += 1
    return out

def cleandoc(t: str) -> str:
    """The docstring without the CODE's indentation.

    A docstring is written inside a body, so from the second line on it carries
    the function's indentation. Showing it as-is puts four extra spaces on
    everything and makes the second line look like a block quote. This is
    Python's `cleandoc`, and its rule: the first line loses its leading space,
    and the others lose the COMMON indent — the smallest of all the non-empty
    ones."""
    lines = t.split("\n")
    if len(lines) == 0:
        return t
    common = -1
    i = 1
    while i < len(lines):
        l = lines[i]
        if len(l.strip()) > 0:
            k = 0
            while k < len(l) and l[k] == " ":
                k += 1
            if common < 0 or k < common:
                common = k
        i += 1
    if common < 0:
        common = 0
    out = lines[0].strip()
    j = 1
    while j < len(lines):
        l2 = lines[j]
        out += "\n" + (l2[common:] if len(l2) >= common else l2.strip())
        j += 1
    return out.rstrip()

def parse(text: str) -> list<Api>:
    """The whole answer: one `Api` per module, in the order the compiler wrote
    them. A line that is not recognised is IGNORED rather than being an error —
    the format may gain new lines, and a reader that blows up on a line it does
    not know ages badly."""
    out: list<Api> = []
    cur = Api("", "", "", [])
    have = False
    for line in text.split("\n"):
        if len(line) == 0:
            continue
        if line.startswith("== "):
            if have:
                out.append(cur)
            cur = Api(line[3:], "", "", [])
            have = True
            continue
        if not have:
            continue
        if line.startswith("#hash "):
            cur.hash = line[6:]
            continue
        if line.startswith("#doc "):
            rest = line[5:]
            k = rest.find(" ")
            if k < 0:
                continue
            sym = rest[0:k]
            txt = cleandoc(unescape(rest[k + 1:]))
            if sym == ".":
                cur.doc = txt
                continue
            i = cur.find(sym)
            if i >= 0:
                cur.symbols[i].doc = txt
            else:
                # a symbol with a doc and no visible declaration: a METHOD
                # (`Struct.method`), which has no line of its own in the list
                cur.symbols.append(Symbol("", sym, txt))
            continue
        cur.symbols.append(Symbol(line, name_of(line), ""))
    if have:
        out.append(cur)
    return out
