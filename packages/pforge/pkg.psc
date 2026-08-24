"""The workspace's PACKAGE graph: who exists, who pulls whom.

It is a small graph and of a different nature from the build graph. The build one
talks about files and commands; this one talks about names and versions, and it
exists to answer the two questions every large lock eventually provokes:

    pforge tree            what this project uses, and through what
    pforge why <package>   who pulled it in

They are not a luxury. They are the ones that save the afternoon when something
shows up in the build and nobody knows where it came from — and ninja and samurai
both have them (`-t graph`, `-t query`), which already says something about how
often they are needed.

What this file does NOT do: resolve versions. Today the workspace's members are
the packages, and the requirement a dependency asks for is checked against the
version that exists. When there is a repository, this is where resolution comes
in — and the format of what it produces is `pack.lock`.
"""
import path
import manifest as M

struct Package:
    name: str
    version: str
    lang: str
    dir: str
    deps: List<str>       # the names, in the manifest's order
    reqs: List<str>       # ... and the requirement each one asked for

struct World:
    packages: List<Package>
    missing: List<str>    # dependencies asked for that nobody offers

    def find(self, name: str) -> int:
        i = 0
        while i < len(self.packages):
            if self.packages[i].name == name:
                return i
            i += 1
        return -1

    def who_pulls(self, name: str) -> List<str>:
        """The packages that depend on THIS one, in the order they appear."""
        out: List<str> = []
        for p in self.packages:
            for d in p.deps:
                if d == name:
                    out.append(p.name)
        return out


def check_languages(m: World) -> List<str>:
    """The invariant that keeps P runtime-free THROUGH the packages.

    A `lang: p` package may not depend on a `pscript` package. The reason is not
    tidiness: whoever uses a P package expects what P promises — no collector, no
    hidden allocation, C's ABI. A `p` that pulled in a `pscript` would drag the
    whole runtime along, and the promise would break in silence, one dependency
    below where somebody read it.

    The other direction is not symmetric and should not be: a pscript package MAY
    depend on a P package, and that is how `pforge` uses `sha2` — the 45.5 crossing
    exists for exactly that.

    Returns the list of problems, empty when all is well."""
    out: List<str> = []
    for p in m.packages:
        if p.lang != "p":
            continue
        for d in p.deps:
            i = m.find(d)
            if i < 0:
                continue
            if m.packages[i].lang != "p":
                out.append(p.name + " is `lang: p` and depends on " + d + ", which is `"
                           + m.packages[i].lang + "`: a P package that pulls in a pscript "
                           + "package drags the runtime along, and whoever uses the P expects the opposite")
    return out


async def read_world(members: List<str>) -> World:
    """Reads each workspace member's manifest. A member with no `pack.json` is
    ignored silently — the workspace may list a folder that is not a package yet,
    and refusing that would force you to edit the manifest just to experiment."""
    m = World([], [])
    for dir in members:
        man = path.join(dir, "pack.json")
        if not path.isfile(man):
            continue
        pk = await M.read(man)
        if pk.is_workspace:
            continue
        names: List<str> = []
        reqs: List<str> = []
        for d in pk.deps:
            names.append(d.name)
            reqs.append(d.req)
        m.packages.append(Package(pk.name, pk.version, pk.lang, dir, names, reqs))
    # what is asked for and does not exist: said ONCE, with the name of whoever
    # asked
    for p in m.packages:
        for d in p.deps:
            if m.find(d) < 0:
                m.missing.append(d + " (asked for by " + p.name + ")")
    return m


# ---------- the tree ----------
private def branch(m: World, name: str, prefix: str, last: bool, stack: List<str>) -> str:
    i = m.find(name)
    mark = "└─ " if last else "├─ "
    if i < 0:
        return prefix + mark + name + "  (not found)\n"
    p = m.packages[i]
    for x in stack:
        if x == name:
            # a cycle is reported and cut, not followed: following it would be not
            # stopping
            return prefix + mark + p.name + " " + p.version + "  (cycle)\n"
    out = prefix + mark + p.name + " " + p.version + "  (" + p.lang + ")\n"
    inner = prefix + ("   " if last else "│  ")
    stack.append(name)
    j = 0
    while j < len(p.deps):
        out += branch(m, p.deps[j], inner, j == len(p.deps) - 1, stack)
        j += 1
    popped = stack.pop()    # the value is unused, but discarding it is an unused expression
    if popped != name:
        return out + prefix + "   (the tree's stack went out of order — a defect)\n"
    return out


def tree(m: World) -> str:
    """The workspace's tree: the ROOTS first (whoever nobody pulls in), each with
    what it pulls in below it. A package that appears in two branches appears
    twice — it is a tree, and not a graph drawn as a tree, because what you want
    to see is the PATH to it."""
    out = ""
    roots: List<str> = []
    for p in m.packages:
        if len(m.who_pulls(p.name)) == 0:
            roots.append(p.name)
    if len(roots) == 0:
        # everything is pulled in by somebody: a cycle, or a workspace of one
        # package
        for p2 in m.packages:
            roots.append(p2.name)
    k = 0
    while k < len(roots):
        stack: List<str> = []
        out += branch(m, roots[k], "", k == len(roots) - 1, stack)
        k += 1
    return out
