"""TARGETS: what you write in a build file, and what becomes an edge.

The engine knows one thing only — run an edge. Everything that is *tool
knowledge* lives here, and that boundary is deliberate: it is exactly where muon
accumulated 1,679 lines of toolchain catalogue and where CMake got lost. Here the
catalogue has two entries (`plangc` and `cc`), and one of them is ours.

The central piece is the `Ctx`: it carries the graph under construction, where
the artifacts go, and WHICH COMPILER to use — and that last point is what makes
the bootstrap ladder expressible. When the compiler is a file another edge
produced, it enters as an INPUT of the edges that use it, and the graph comes to
know that rebuilding the compiler rebuilds everything it generated. It is the
difference between a build that knows what it is doing and a script that runs
commands in the right order by luck.
"""
import os
import path
import graph as G
import manifest as MF

struct Target:
    """What changes between `linux-amd64`, `linux-amd64-musl` and `macos-arm64`.
    The name is OURS and short; the translation into the world's terms (QBE's
    `-t`, the `cc` triple) lives here, in this layer, and not in the engine.

    A `struct` and not a `record` because it carries `str`, and a record is raw
    bytes (58.2)."""
    name: str
    cc: str
    qbe: str

def host_target() -> Target:
    return Target("host", "cc", "amd64_sysv")

struct Ctx:
    g: G.Graph
    outdir: str        # where the artifacts land (build/obj, build/s1, ...)
    plangc: str        # the compiler that RUNS in the edges — may be an artifact
    plangc_is_built: bool   # ... and if it is, it enters as an input of the edges
    query: str         # the compiler that ANSWERS the protocol's questions
    target: Target
    cflags: List<str>
    # pscript's runtime, generated ONCE per context (see `psrt`): twenty pscript
    # programs are not twenty compilations of the runtime, and two edges
    # producing the same `.c` would be a graph the engine refuses
    rt_c: List<str>
    rt_h: List<str>
    rt_o: List<str>
    rt_ready: bool
    # this project's package roots (`--pkg-path`), in order. They go into EVERY
    # invocation of the compiler — the QUESTIONS included, because `--deps` of a
    # file that imports from a package needs to find the package to answer.
    pkgroots: List<str>
    # 2.13: the PREPROCESSOR flags the packages declare (`cflags` in the
    # manifest), already rewritten against each one's directory. They apply to
    # EVERY invocation of the compiler and not only to the package that declared
    # them, and the reason is the asymmetry of `include`: whoever imports
    # `<crc/crc.ph>` is the one who will preprocess that package's `crc32.h`, so
    # it is THEIR compilation that needs the `-I`. A flag from a package nobody
    # uses costs nothing; what the list does NOT decide is the link — what enters
    # the binary is the closure.
    pkgcpp: List<str>
    # objects already emitted: the `.o` path -> the signature of the edge that
    # makes it. The same `.c` compiled in the same objdir by two different
    # PROGRAMS has been routine ever since packages existed — `sha2` is read by a
    # test in P and by one in pscript — and a file has ONE producer. If the
    # signature matches, the second request returns the object that already
    # exists; if it does not, the engine refuses, which is what has to happen.
    objs_made: Dict<str, str>

def new_ctx(g: G.Graph, outdir: str, plangc: str) -> Ctx:
    # whoever ANSWERS and whoever RUNS may be different compilers, and on the
    # bootstrap ladder they ARE: the edges run each rung's compiler — which does
    # not exist yet when the graph is assembled — while the questions ("what does
    # this file read?", "what will it emit?") are about the SOURCE and can be put
    # to any compiler that understands the language. It is the same assumption
    # the bootstrap already makes: the seed compiles today's sources.
    return Ctx(g, outdir, plangc, False, plangc, host_target(), ["-O2", "-std=c11", "-w"], [], [], [], False, [], [], {})

def derive(c: Ctx, outdir: str, plangc: str) -> Ctx:
    """A CHILD context: another directory, another compiler, and the rest
    inherited.

    It exists because the rest gets forgotten. The package roots, the target and
    the `cc` flags belong to the PROJECT, not to the rung — and a new context
    that did not inherit them would ask the compiler without telling it where the
    packages are, which gives an empty answer and a graph that builds nothing
    successfully. That is exactly what happened the day `stl` became a
    package."""
    n = new_ctx(c.g, outdir, plangc)
    # the SAME object table, and on purpose: there is one graph, so "this `.o`
    # already has a producer" is a fact about the graph and not about the context.
    n.objs_made = c.objs_made
    n.query = c.query
    n.pkgroots = c.pkgroots
    n.pkgcpp = c.pkgcpp
    n.target = c.target
    n.cflags = c.cflags
    n.plangc_is_built = True
    return n

# ---------- asking the compiler ----------
# Answers 1 and 3 of the protocol, used where they exist to be used: the
# descriptor does not reimplement `import` resolution — it ASKS. A second
# implementation that diverged from the real one would give a stale build after
# an edit, which is the only failure mode that matters.
async def ask(c: Ctx, argv: List<str>) -> List<str>:
    """The ANSWER comes back through a file, not through the pipe.

    `os.run` merges standard error into standard output on purpose — that is what
    makes an error report read in the order it happened. But an ANSWER is not a
    report: the compiler may warn (`-Wshadow-prelude`, say) in the middle of
    answering, and the warning, mixed in, would become a line of the answer. That
    is exactly what happened: three warnings from the corpus became three "inputs
    nobody produces", and the whole graph was refused.

    With `stdout=` the answer goes to the file and `output()` is left with only
    what the compiler had to say — which is what gets shown when it refuses."""
    # the file name comes from the QUESTION: two different questions never write
    # to the same place, and an imported module may not have top-level variables
    # (it is a set of definitions, not a program) — a global counter would not
    # fit here.
    resp = path.join(c.outdir, ".pforge-answer." + str(G.hash_str(G.FNV_OFF, " ".join(argv))))
    d = path.dirname(resp)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    r = await os.run(argv, stdout=resp)
    if r.status() != 0:
        # NEVER in silence: a question that fails and returns an empty list
        # produces a graph that mentions nothing, and a graph that mentions
        # nothing "builds" everything successfully without doing anything. It is
        # the most dangerous failure mode there is here, and it took an
        # investigation to show up.
        raise error("the question to the compiler failed: " + " ".join(argv) + "\n" + r.output())
    f = await open(resp, "r")
    txt = await f.text()
    await f.close()
    os.remove(resp)
    out: List<str> = []
    for line in txt.split("\n"):
        if len(line) > 0:
            out.append(line)
    return out

def with_roots(c: Ctx, argv: List<str>) -> List<str>:
    """The `argv` with the package roots. They go into every invocation, the
    questions included: `--deps` of a file that imports `<pui/widget.ph>` needs to
    find `pui` to answer — and a question that does not find is an empty answer,
    which is the most dangerous failure mode there is in a build system."""
    out: List<str> = []
    out.append(argv[0])
    for r in c.pkgroots:
        out.append("--pkg-path")
        out.append(r)
    i = 1
    while i < len(argv):
        out.append(argv[i])
        i += 1
    return out

async def deps_of(c: Ctx, src: str, outdir: str) -> List<str>:
    """What this compilation READS — and "this" is the word that matters.

    The `--out-dir` goes into the QUESTION because it changes the answer: with
    it, naming a `.ph` pulls in the sibling `.p` (1.5a) and the compilation reads
    both; with `-o`, it does not pull it in and reads only the header. Asking
    without the mode and compiling with it was a real, silent bug — `--outputs
    selfhost/parser.ph --out-dir build/s1` already said it would WRITE `lexer.c`,
    while `--deps selfhost/parser.ph` did not say it would READ `lexer.p`. The
    edge was left without that input, and editing the compiler's lexer rebuilt
    nothing."""
    return await ask(c, with_roots(c, [c.query, "--deps", "--out-dir", outdir, src]))

async def outputs_of(c: Ctx, src: str, outdir: str) -> List<str>:
    return await ask(c, with_roots(c, [c.query, "--outputs", "--out-dir", outdir, src]))

# ---------- P and pscript -> C ----------
async def p_module(c: Ctx, src: str, outdir: str, flags: List<str>) -> List<str>:
    """One edge: `plangc [flags] --out-dir <dir> <source>`.

    The `flags` are the COMPILER's, and they change what it emits: `-O` drops
    `assert` (46.4), `-g` adds the stack trace. They go into the `argv`, and
    therefore into the edge's hash — swapping a flag rebuilds, which is the least
    one expects and what a Makefile with an environment variable does not
    guarantee.

    The inputs are what the COMPILER says it read (the source and the `.ph` files
    it imports, transitively) plus the compiler itself when it is built here. The
    outputs are what it says it will emit. None of this is guessed.
    """
    ins = await deps_of(c, src, outdir)
    outs = await outputs_of(c, src, outdir)
    argv: List<str> = [c.plangc]
    for r in c.pkgroots:
        argv.append("--pkg-path")
        argv.append(r)
    for fl in with_cpp(c, flags):
        argv.append(fl)
    argv.append("--out-dir")
    argv.append(outdir)
    argv.append(src)
    # DOES THIS EDGE ALREADY EXIST? It happens all the time and is not an error:
    # `import "x.ph"` (75.3) makes the compiler emit the P module along with
    # whoever imports it, and two programs importing the same module ask for the
    # same emission. A file has ONE producer, so the second time creates no edge
    # at all.
    #
    # What cannot be accepted is that when the command is DIFFERENT — then there
    # are two different emissions fighting over the same file, and that is exactly
    # what the engine's hygiene refuses. Hence the comparison is of the whole
    # `argv`.
    if already_emitted(c, outs, c.plangc, outdir):
        return outs
    e = G.new_edge(argv)
    for i in ins:
        e.ins.append(c.g.node(i).id)
    if c.plangc_is_built:
        # the LADDER: when the compiler is an artifact, touching it rebuilds
        # everything it generates. It enters as an implicit input because it is
        # not "what gets compiled", it is "what compiles it"
        e.implicit.append(c.g.node(c.plangc).id)
    for o in outs:
        n = c.g.node(o)
        if n.gen >= 0 and same_emitter(c, n.gen, c.plangc, outdir):
            # THIS file already has a producer, and it is the same compiler
            # writing the same mirror. It happens when two programs read the same
            # `.ph`: each emission writes the header, and the content is the same.
            # A file has ONE producer, so here it becomes an INPUT — which also
            # puts the right order between the two.
            e.implicit.append(n.id)
            continue
        e.outs.append(n.id)
    # the regenerated C comes out byte for byte identical on almost every edit,
    # and this is what turns "I rewrote the .c" into "I did not recompile the .o"
    e.restat = True
    e.desc = "generating " + path.basename(src)
    e.target = c.target.name
    c.g.add_edge(e)
    return outs

private def value_of(argv: List<str>, option: str) -> str:
    i = 0
    while i + 1 < len(argv):
        if argv[i] == option:
            return argv[i + 1]
        i += 1
    return ""

private def same_emitter(c: Ctx, eid: int, plangc: str, outdir: str) -> bool:
    old = c.g.edges[eid]
    if len(old.argv) == 0 or old.argv[0] != plangc:
        return False
    return value_of(old.argv, "--out-dir") == outdir

private def already_emitted(c: Ctx, outs: List<str>, plangc: str, outdir: str) -> bool:
    """Are these outputs already emitted — by the SAME compiler, into the SAME
    tree?

    It happens all the time and is not an error: `plangc --out-dir D x` emits the
    header of every `.ph` it read, so compiling `app.psc` already writes
    `stl/cstr.h`, and asking for `stl/cstr.ph` afterwards would ask for the same
    file again. The content is the same — it is the same compiler writing the
    same mirror from the same source — and what there cannot be is TWO producers.

    What is still refused (and the engine's hygiene catches it) is another
    compiler, another tree, or another tool writing over it."""
    if len(outs) == 0:
        return False
    for o in outs:
        n = c.g.node(o)
        if n.gen < 0:
            return False
        if not same_emitter(c, n.gen, plangc, outdir):
            return False
    return True

async def p_modules(c: Ctx, srcs: List<str>, outdir: str, flags: List<str>) -> List<str>:
    """The same, for a list. Returns EVERYTHING that was generated — `.c` and
    `.h`.

    Both matter, and for different reasons: the `.c` goes onto the `cc` command
    line, and the `.h` is an INPUT of it (the generated C includes the generated
    headers). A graph that returned only the `.c` files would not know the header
    has to exist first, and the build would fail on the first compilation — or
    worse, would use a stale header left over."""
    out: List<str> = []
    seen: Dict<str, int> = {}
    for s in srcs:
        for o in await p_module(c, s, outdir, flags):
            # the list is a SET. Since 1.5(a) the same file shows up by two
            # routes — compiling `psrt.ph` already emits the six layers' `.c`
            # files, and compiling each of their `.p` files returns theirs again
            # — and a repetition here becomes a second edge producing the same
            # `.o`, which is the graph the engine refuses.
            if o in seen:
                continue
            seen[o] = 1
            out.append(o)
    return out

def only(files: List<str>, suffix: str) -> List<str>:
    out: List<str> = []
    for f in files:
        if f.endswith(suffix):
            out.append(f)
    return out

# ---------- 2.13: the C a PACKAGE brings hand-written ----------
#
# It comes in through OUR front end and not straight into the `cc`, and that buys
# the three things the decision names: the `-Wall` of whoever consumes it does
# not stop at the package boundary, C89 and QBE stay available for the whole
# package, and the diagnostics are the same on both sides. The price, said
# precisely: whatever our front end does not accept does not get in.
#
# The manifest's paths are relative to the PACKAGE — it does not know where it was
# extracted (`build/pkg/<name>-<version>-<hash>/`) — and this is where they start
# to count. The same for `-I`: a relative include flag is rewritten against the
# package's directory, otherwise it would point at the builder's directory.
def package_cflags(dir: str, flags: List<str>) -> List<str>:
    out: List<str> = []
    for f in flags:
        if f.startswith("-I") and len(f) > 2 and not f[2:len(f)].startswith("/"):
            out.append("-I" + path.join(dir, f[2:len(f)]))
        else:
            out.append(f)
    return out


async def load_packages(c: Ctx):
    """Reads each root package's manifest and keeps their preprocessor flags in
    the context.

    Once per context, and not per program: they are the same roots for everything
    this project builds, and rereading ten manifests per target would be repeated
    work to always give the same answer."""
    fl: List<str> = []
    for r in c.pkgroots:
        if not path.isdir(r):
            continue
        for name in sorted(os.listdir(r)):
            dir = path.join(r, name)
            man = path.join(dir, "pack.json")
            if not path.isdir(dir) or not path.isfile(man):
                continue
            # a manifest that will not be read does NOT stop this scan, and the
            # reason is what the scan is: a collection of optional flags, not a
            # validator. Whoever validates is `pforge check` and the package's own
            # build, where the error has an owner and a message. Here, refusing
            # would let a directory that merely SITS next to a package — the
            # fixture for an invalid manifest, say — stop the whole project from
            # building, and over a file nobody asked to read.
            try:
                m = await MF.read(man)
                for x in package_cflags(dir, m.cflags):
                    if x not in fl:
                        fl.append(x)
            catch e:
                pass
    c.pkgcpp = fl


private def with_cpp(c: Ctx, flags: List<str>) -> List<str>:
    """The compiler's flags, with the packages' inside the `--cpp`.

    `plangc` has no C `-I` and no `-D`: what it has is `--cpp`, the COMMAND it
    preprocesses `include <h>` with — and that is how `pstudio` already passes
    SDL2's `-I` today. A package with C comes in through the same door, which is
    a good sign: it is not a new mechanism, it is the same one with another
    owner.

    When the caller already passed a `--cpp` (the editor), the packages' flags are
    APPENDED to their command. Replacing it would make the editor stop finding
    SDL2's header the day somebody published a package with C."""
    if len(c.pkgcpp) == 0:
        return flags
    extra = " ".join(c.pkgcpp)
    out: List<str> = []
    found = False
    i = 0
    while i < len(flags):
        out.append(flags[i])
        if flags[i] == "--cpp" and i + 1 < len(flags):
            out.append(flags[i + 1] + " " + extra)
            found = True
            i += 2
            continue
        i += 1
    if not found:
        out.append("--cpp")
        out.append(c.target.cc + " " + extra)
    return out


async def pkg_c_objects(c: Ctx, dir: str, csources: List<str>, objdir: str,
                        headers: List<str>) -> List<str>:
    """The objects for a package's C. Two edges per file: `plangc` reads the `.c`
    and emits `.c`, and the `cc` compiles what came out.

    The `cc` does not get the package's flags, and that is not an oversight: what
    it compiles is already our front end's output, with the `#include`s expanded
    and the `-D`s resolved. Passing them again would be asking the `cc` to redo
    work that is already done — and would give a different result from the one the
    front end saw."""
    objs: List<str> = []
    for rel in csources:
        src = path.join(dir, rel)
        emitted = await p_module(c, src, c.outdir, [])
        for generated in only(emitted, ".c"):
            objs.append(c_object(c, generated, obj_for(objdir, generated), [], headers))
    return objs


def package_of(pkgroots: List<str>, file: str) -> str:
    """The directory of the package `file` belongs to, or "" if it is not inside
    any root.

    The arithmetic is C's `-I`, inverted: if the file is under a search root, the
    first piece after it is the package's NAME. It is the same rule the compiler
    uses to resolve `<pkg/mod.ph>`, read backwards."""
    for r in pkgroots:
        pref = r + "/"
        if not file.startswith(pref):
            continue
        rest = file[len(pref):len(file)]
        k = rest.find("/")
        if k <= 0:
            continue
        return path.join(r, rest[0:k])
    return ""


# ---------- C -> object ----------
def c_object(c: Ctx, src: str, obj: str, flags: List<str>, extra_ins: List<str>) -> str:
    """`cc -c`, with `-MD` so the compiler says which headers it read. The `.d`
    stays on disk and is read in the next run's plan — on the C side there is no
    protocol, and this is the price.

    The `depfile` only exists AFTER the first compilation, and that is why the
    GENERATED headers enter as implicit inputs on the first one already: without
    them, the first run of a clean build could compile a `.c` before the `.h` it
    includes has been written. After the first, the `.d` covers the rest — the
    system headers included."""
    argv: List<str> = [c.target.cc]
    for f in c.cflags:
        argv.append(f)
    # 2.13: the flags of packages with C reach the `cc` too, and there is one
    # reason — `include "x.h"` (with quotes) is NOT ingested by our front end: it
    # crosses into the emitted C as `#include "x.h"`, and whoever resolves it is
    # the `cc`. Without this the package's `-I` counted when reading and did not
    # count when compiling, which is the half that fails far away.
    for f0 in c.pkgcpp:
        argv.append(f0)
    for f2 in flags:
        argv.append(f2)
    argv.append("-MD")
    argv.append("-MF")
    argv.append(obj + ".d")
    argv.append("-c")
    argv.append(src)
    argv.append("-o")
    argv.append(obj)
    signature = " ".join(argv)
    if obj in c.objs_made:
        if c.objs_made.get(obj, "") == signature:
            return obj
        # TWO DIFFERENT COMMANDS for the same source. It really happens and it is
        # nobody's mistake: the same `.c` from a package serves a program compiled
        # with the runtime's `-D`s and another compiled with SDL's, and the object
        # cannot be the same file. Instead of refusing (which would force every
        # harness to invent an objdir per flag combination), the object gets the
        # command's SEAL in its name. Deterministic: the same command always gives
        # the same seal, so the incremental build keeps working.
        obj = obj[0:len(obj) - 2] + "." + seal(signature) + ".o"
        # the `argv` ends in `-MD -MF <dep> -c <source> -o <object>`: the object is
        # last and the `.d` is fifth from the end. Miscounting here swapped the
        # SOURCE for the `.d`, and the `cc` complained that it could not execute a
        # piece of the name — a message with nothing to do with the problem.
        argv[len(argv) - 1] = obj
        argv[len(argv) - 5] = obj + ".d"
        signature = " ".join(argv)
        if obj in c.objs_made:
            return obj
    c.objs_made[obj] = signature
    e = G.new_edge(argv)
    e.ins.append(c.g.node(src).id)
    for x in extra_ins:
        e.implicit.append(c.g.node(x).id)
    e.outs.append(c.g.node(obj).id)
    e.depfile = obj + ".d"
    e.desc = "compiling " + path.basename(src)
    e.target = c.target.name
    c.g.add_edge(e)
    return obj

private def seal(s: str) -> str:
    """Eight hexadecimal digits of FNV-1a. It is NOT cryptographic and does not
    need to be: this tells two commands apart, it does not defend against anyone
    — the hash that defends is `sha2`'s, and it lives in the package manager."""
    # 32-bit FNV-1a, and 32 rather than 64 for a reason of arithmetic: the
    # integers here are 64-bit SIGNED and overflow is an error (not silence), so
    # FNV's 64-bit constant cannot even be a literal. The 32-bit one fits the
    # product with room to spare.
    h = 2166136261
    for ch in s:
        h = ((h ^ ord(ch)) * 16777619) & 0xffffffff
    d = ""
    for i in range(8):
        n = (h >> ((7 - i) * 4)) & 0xf
        d += "0123456789abcdef"[n]
    return d


def obj_for(objdir: str, src: str) -> str:
    """A source's object MIRRORS its path, not its name. Two `app.c` files from
    different folders with the same `basename` would be two edges producing the
    same `.o` — which is exactly the graph the engine refuses, and rightly so:
    which of the two defines the content would depend on the order."""
    return path.join(objdir, src + ".o")

def c_objects(c: Ctx, srcs: List<str>, objdir: str, flags: List<str>, extra_ins: List<str>) -> List<str>:
    objs: List<str> = []
    for s in srcs:
        objs.append(c_object(c, s, obj_for(objdir, s), flags, extra_ins))
    return objs

# ---------- objects -> binary ----------
def executable(c: Ctx, out: str, objs: List<str>, libs: List<str>) -> str:
    argv: List<str> = [c.target.cc]
    for f in c.cflags:
        argv.append(f)
    argv.append("-o")
    argv.append(out)
    for o in objs:
        argv.append(o)
    for l in libs:
        argv.append(l)
    e = G.new_edge(argv)
    for o2 in objs:
        e.ins.append(c.g.node(o2).id)
    e.outs.append(c.g.node(out).id)
    e.desc = "linking " + path.basename(out)
    e.target = c.target.name
    c.g.add_edge(e)
    return out

def cc_program(c: Ctx, out: str, srcs: List<str>, extra_ins: List<str>, flags: List<str>, libs: List<str>) -> str:
    """A binary straight from C sources, with no intermediate objects — which is
    what the compiler's seed is: a `cc` over the committed C."""
    argv: List<str> = [c.target.cc]
    for f in c.cflags:
        argv.append(f)
    for f2 in flags:
        argv.append(f2)
    argv.append("-o")
    argv.append(out)
    for s in srcs:
        argv.append(s)
    for l in libs:
        argv.append(l)
    e = G.new_edge(argv)
    for s2 in srcs:
        e.ins.append(c.g.node(s2).id)
    # what comes in without being on the command line: the generated headers,
    # which the generated C includes. They are IMPLICIT inputs — the same band the
    # `depfile` uses
    for x in extra_ins:
        e.implicit.append(c.g.node(x).id)
    e.outs.append(c.g.node(out).id)
    e.desc = "building " + path.basename(out)
    e.target = c.target.name
    c.g.add_edge(e)
    return out

# ---------- pscript -> binary ----------
# The runtime's module list used to live in SIX places (two blocks of run.sh,
# psbuild.sh, the Makefile, verify-all and the compiler's `RT_SRCS`). Here is its
# home: the descriptor is what knows what makes up a pscript program, and the
# other five copies vanish once the harnesses call `pforge`.
#
# The order matters and is not alphabetical: these are LAYERS (memory, values,
# what runs, the library, the system, the epilogue), and the compiler sees them
# in this order.
const RT_MODULES: List<str> = ["psrt.ph", "psrt_types.ph", "psrt_mem.ph", "psrt_val.ph",
                               "psrt_rt.ph", "psrt_std.ph", "psrt_os.ph", "psrt_top.ph",
                               "psrt_mem.p", "psrt_val.p", "psrt_rt.p", "psrt_std.p",
                               "psrt_os.p", "psrt_top.p"]

# glibc hides socket/getaddrinfo/poll/pipe under a strict `-std=`, and the runtime
# speaks POSIX from beginning to end
const PSDEFS: List<str> = ["-D_POSIX_C_SOURCE=200112L", "-D_DEFAULT_SOURCE"]


async def psrt(c: Ctx) -> List<str>:
    """pscript's runtime, compiled ONCE per context. Returns everything it
    generated — `.c` and `.h`."""
    if c.rt_ready:
        out: List<str> = []
        for x in c.rt_c:
            out.append(x)
        for y in c.rt_h:
            out.append(y)
        return out
    srcs: List<str> = []
    for m in RT_MODULES:
        srcs.append(path.join("pscript/runtime", m))
    all = await p_modules(c, srcs, c.outdir, [])
    c.rt_c = only(all, ".c")
    c.rt_h = only(all, ".h")
    c.rt_ready = True
    return all


private async def rt_objects(c: Ctx, objdir: str) -> List<str>:
    """The runtime compiled to OBJECTS, once for the whole context.

    Here is the difference you feel most: `psbuild.sh` relinks the runtime's six
    modules from C in EVERY program, and the pscript suite has more than a hundred
    programs — that is six hundred compilations of the same text. With objects, it
    is six."""
    if len(c.rt_o) > 0:
        return c.rt_o
    all = await psrt(c)
    c.rt_o = c_objects(c, only(all, ".c"), objdir, PSDEFS, only(all, ".h"))
    return c.rt_o


async def psc_program_with(c: Ctx, src: str, out: str, objdir: str, p_srcs: List<str>,
                           flags: List<str>, cflags: List<str>, libs: List<str>) -> str:
    """The same, plus P MODULES compiled alongside.

    It is the editor's case: the logic is pscript, but the hand that touches SDL2
    and the one that calls the compiler's lexer are P — pixels and pointers from
    beginning to end, which 45.5 does not let cross. From the graph's point of
    view there is nothing new: more sources, more generation edges, more
    objects."""
    rtos = await rt_objects(c, objdir)
    # the tree is SHARED, and it has to be: the generated C includes the
    # runtime's headers by a relative path inside the mirror
    # (`../../pscript/runtime/psrt.h`), so a program in a tree of its own would
    # not find the runtime that is in the other. Who takes care of two programs
    # emitting the same header is `p_module` — see the note there.
    #
    # the PROGRAM first, because answer 3 already includes the P modules it
    # imports with `import "x.ph"` (75.3) — the compiler emits them alongside.
    # Only what is left over after that needs an edge of its own: a `.ph` that
    # another module imports deeper down, and its `.p`.
    prog = await p_module(c, src, c.outdir, flags)
    extras = await p_modules(c, p_srcs, c.outdir, flags)
    headers: List<str> = []
    for h in c.rt_h:
        headers.append(h)
    for h2 in only(extras, ".h"):
        headers.append(h2)
    for h3 in only(prog, ".h"):
        headers.append(h3)
    all_cflags: List<str> = []
    for d in PSDEFS:
        all_cflags.append(d)
    for x in cflags:
        all_cflags.append(x)
    objs: List<str> = []
    for o in rtos:
        objs.append(o)
    for cf in only(extras, ".c"):
        objs.append(c_object(c, cf, obj_for(objdir, cf), all_cflags, headers))
    for cf2 in only(prog, ".c"):
        objs.append(c_object(c, cf2, obj_for(objdir, cf2), all_cflags, headers))
    closure: List<str> = []
    for a1 in prog:
        closure.append(a1)
    for a2 in extras:
        closure.append(a2)
    for co in await packages_c(c, closure, objdir, headers):
        objs.append(co)
    all_libs: List<str> = []
    for l in libs:
        all_libs.append(l)
    all_libs.append("-lm")
    all_libs.append("-pthread")
    return executable(c, out, objs, all_libs)


async def psc_program(c: Ctx, src: str, out: str, objdir: str, flags: List<str>, libs: List<str>) -> str:
    """A pscript program: the runtime alongside (16.4 — it is SOURCE compiled
    together, not a library the compiler links), the program's own import
    closure, and one link that joins everything.

    It is what `tests/psbuild.sh` does today in thirty lines of shell, with two
    differences that are not stylistic: each edge's inputs come from the
    compiler's answer 1 (editing an imported `.ph` rebuilds what needs it, and the
    shell — which asks nothing — rebuilt everything or nothing), and the runtime
    becomes an object once instead of being recompiled per program."""
    rtos = await rt_objects(c, objdir)
    prog = await p_module(c, src, c.outdir, flags)
    headers: List<str> = []
    for h in c.rt_h:
        headers.append(h)
    for h2 in only(prog, ".h"):
        headers.append(h2)
    objs: List<str> = []
    for o in rtos:
        objs.append(o)
    # `import "x.ph"` (75.3) makes the compiler emit the P module alongside, into
    # the same mirror — and answer 3 already lists it, so there is no glob here
    for cf in only(prog, ".c"):
        objs.append(c_object(c, cf, obj_for(objdir, cf), PSDEFS, headers))
    all_libs: List<str> = []
    for l in libs:
        all_libs.append(l)
    all_libs.append("-lm")
    all_libs.append("-pthread")
    return executable(c, out, objs, all_libs)


# ---------- SYSTEM dependencies ----------
# `pkg-config` is what exists, and it is asked HERE, while the graph is being
# assembled, and not inside an edge. The difference matters: what it answers goes
# into the `argv`, and therefore into the hash — changing the machine's SDL2
# version rebuilds what depends on it. An edge that called `pkg-config` from
# inside would always have the same command and the same hash, and the build would
# silently reuse another library's artifact.
async def pkg_config(c: Ctx, lib: str, what: str) -> List<str>:
    lines = await ask(c, ["pkg-config", what, lib])
    out: List<str> = []
    for l in lines:
        for w in l.split(" "):
            if len(w) > 0:
                out.append(w)
    return out


async def has_pkg(lib: str) -> bool:
    r = await os.run(["pkg-config", "--exists", lib])
    return r.status() == 0


private async def packages_c(c: Ctx, generated: List<str>, objdir: str,
                             headers: List<str>) -> List<str>:
    """The hand-written C of the packages this program reaches.

    WHICH packages is the compiler's answer 3, not a hand-kept list: what it is
    going to emit says which modules it went through, and a module under a search
    root belongs to the package whose name is the first piece. A package nobody
    imports does not enter the link — which is the property that makes `deps` in
    the manifest cost no binary size.

    Translating "what it will emit" into "what it read" is the `--out-dir`
    MIRROR: the C for `packages/sha2/sha2.p` comes out at
    `<outdir>/packages/sha2/sha2.c`, with the whole tree replicated inside.
    Stripping the prefix gives back the source path — and it is free, whereas
    asking again would cost one compiler invocation per program."""
    objs: List<str> = []
    seen: Dict<str, int> = {}
    pref = c.outdir + "/"
    for f in generated:
        rel = f[len(pref):len(f)] if f.startswith(pref) else f
        dir = package_of(c.pkgroots, rel)
        if len(dir) == 0 or dir in seen:
            continue
        seen[dir] = 1
        man = path.join(dir, "pack.json")
        if not path.isfile(man):
            continue
        m = await MF.read(man)
        for o in await pkg_c_objects(c, dir, m.csources, objdir, headers):
            objs.append(o)
    return objs


async def p_program(c: Ctx, src: str, out: str, objdir: str, flags: List<str>, libs: List<str>) -> str:
    """A program in P: its closure to objects, and one link. With no runtime at
    all — that is the whole difference between the two languages, and it shows up
    here as the absence of a line."""
    generated = await p_module(c, src, c.outdir, flags)
    headers: List<str> = only(generated, ".h")
    objs: List<str> = []
    for cf in only(generated, ".c"):
        objs.append(c_object(c, cf, obj_for(objdir, cf), [], headers))
    for co in await packages_c(c, generated, objdir, headers):
        objs.append(co)
    return executable(c, out, objs, libs)


# ---------- suites ----------
struct Case:
    """A test case: what to run, what is expected of it, and where it runs.

    A `struct` and not a `record` because it carries `str` (58.2)."""
    name: str
    binary: str
    expected: str
    status: int
    cwd: str


def suite(c: Ctx, name: str, cases: List<Case>, verdict: str, stampdir: str) -> str:
    """A suite: one edge PER CASE, and a stamp that joins them all.

    One edge per case is the whole point, and it has two consequences a shell
    harness does not have: the cases run in PARALLEL with the rest of the build
    (the queue is the same, the limit is the same), and a case whose binary and
    whose `.expected` did not change does NOT run again. A suite of three hundred
    cases starts costing what the cases that changed cost.

    What runs is not the case: it is the `verdict` (see `verdict.psc`), because a
    case's exit status is data and not a verdict."""
    stamps: List<str> = []
    for k in cases:
        st = path.join(stampdir, name + "." + k.name + ".ok")
        e = G.new_edge([verdict, k.binary, k.expected, str(k.status), k.cwd, st])
        e.ins.append(c.g.node(k.binary).id)
        e.ins.append(c.g.node(k.expected).id)
        e.implicit.append(c.g.node(verdict).id)
        e.outs.append(c.g.node(st).id)
        e.desc = name + ": " + k.name
        e.target = c.target.name
        c.g.add_edge(e)
        stamps.append(st)
    # an em dash and not a colon: the CLI's scoreboard groups by whatever comes
    # before `": "`, and a stamp that said "packages: 3 cases" would be counted as
    # one case named "3 cases"
    return phony(c, path.join(stampdir, name + ".suite"), stamps, name + " — " + str(len(cases)) + " cases")


def phony(c: Ctx, stamp: str, ins: List<str>, desc: str) -> str:
    """A node that exists only to be ASKED FOR: it depends on everything and
    produces a stamp. It is how you ask for "the whole suite" from a graph that
    only knows how to talk about files."""
    e = G.new_edge(["/bin/sh", "-c", "exit 0"])
    for i in ins:
        e.ins.append(c.g.node(i).id)
    e.outs.append(c.g.node(stamp).id)
    e.stdout_to = stamp
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return stamp


# ---------- an outside harness ----------
# The corpora (`tests/run.sh`, `gc-stress.sh`, the oracles) are NOT rewritten
# here, and that is a decision and not laziness: they work, they are read by
# people who are not going to read pscript, and rewriting them would be trading
# risk for nothing. What changes is that they become EDGES — they enter the graph,
# run in parallel with the rest, and do not run again when nothing that feeds them
# changed.
#
# Their configuration arrives through ENVIRONMENT VARIABLES (`PLANGC=`,
# `BACKEND=`), and that is where the one subtlety lives: an edge's `env=`
# REPLACES the environment, and a harness without `PATH` does not find `bash`. The
# way out is `/usr/bin/env` as argv[0]: it ADDS to the environment it inherited,
# the argument vector stays exact, and there is no shell in the middle to
# reinterpret anything.
def harness(c: Ctx, name: str, argv: List<str>, vars: Dict<str, str>,
            ins: List<str>, logdir: str, desc: str) -> str:
    line: List<str> = ["env"]
    ks: List<str> = []
    for k in vars:
        ks.append(k)
    ks = sorted(ks)     # sorted: the edge's hash cannot depend on the order
    for k2 in ks:
        line.append(k2 + "=" + vars[k2])
    for a in argv:
        line.append(a)
    log = path.join(logdir, name + ".log")
    e = G.new_edge(line)
    for i in ins:
        e.ins.append(c.g.node(i).id)
    e.outs.append(c.g.node(log).id)
    e.stdout_to = log
    e.desc = desc + " (report in " + log + ")"
    e.target = c.target.name
    c.g.add_edge(e)
    return log


def score_floor(c: Ctx, prog: str, log: str, prefix: str, minimum: str,
                stamp: str, desc: str) -> str:
    """A scoreboard's FLOOR: an edge that reads the number the suite printed and
    compares it with the minimum accepted.

    It is separate from the edge that RUNS the suite on purpose, for two reasons:
    the report keeps standing on its own (whoever wants the number reads the log),
    and changing the floor does not force the suite to be re-run — only the cheap
    edge changes, because the minimum goes into its `argv` and therefore into its
    hash.

    See `pforge/src/floor.psc` for what the program does."""
    e = G.new_edge([prog if prog.startswith("/") else "./" + prog, log, prefix, minimum, stamp])
    e.ins.append(c.g.node(log).id)
    e.ins.append(c.g.node(prog).id)
    e.outs.append(c.g.node(stamp).id)
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return stamp


# ---------- a gate by the NEGATIVE ----------
def must_not_match(c: Ctx, pattern: str, files: List<str>, stamp: str, desc: str) -> str:
    """Passes when the pattern does NOT appear in any of the files.

    It is the shape of several gates that are worth having, and of the one in
    `verify-all` that guards the libc typedef regression: on glibc the build
    passes either way, so the test has to be about the TEXT of the generated C.

    There is a shell here, and it is the only place in the descriptor where there
    is one: what we want is the INVERSE of a command's status, and inverting a
    status is what the shell's `!` does. The quoting is generated by us
    (`G.sh_quote`), which is what makes it correct — and the files are INPUTS of
    the edge, so none of them can be missing and make the `grep` fail for another
    reason."""
    cmd = "! grep -l -- " + G.sh_quote(pattern)
    for f in files:
        cmd += " " + G.sh_quote(f)
    cmd += " > /dev/null"
    e = G.new_edge(["/bin/sh", "-c", cmd])
    for i in files:
        e.ins.append(c.g.node(i).id)
    e.outs.append(c.g.node(stamp).id)
    e.stdout_to = stamp
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return stamp


# ---------- commands and checks ----------
def command(c: Ctx, argv: List<str>, ins: List<str>, outs: List<str>, desc: str) -> G.Edge:
    """The raw edge, always available. Whoever needs something the library does
    not foresee drops one level without leaving the language."""
    e = G.new_edge(argv)
    for i in ins:
        e.ins.append(c.g.node(i).id)
    for o in outs:
        e.outs.append(c.g.node(o).id)
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return e

def compare_dirs(c: Ctx, a: str, b: str, stamp: str, ins: List<str>, desc: str) -> G.Edge:
    """Two trees have to be IDENTICAL, and the `diff`'s output becomes the stamp.

    With no shell there is no `&&` and no `>`, and none is needed: the edge's
    standard output goes to the file (it is a field of the edge), and what decides
    whether it passed is the process's STATUS. The stamp exists so the graph has
    something to date.
    """
    e = G.new_edge(["diff", "-rq", a, b])
    for i in ins:
        e.ins.append(c.g.node(i).id)
    e.outs.append(c.g.node(stamp).id)
    e.stdout_to = stamp
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return e

def compare_files(c: Ctx, a: str, b: str, stamp: str, desc: str) -> G.Edge:
    e = G.new_edge(["cmp", a, b])
    e.ins.append(c.g.node(a).id)
    e.ins.append(c.g.node(b).id)
    e.outs.append(c.g.node(stamp).id)
    e.stdout_to = stamp
    e.desc = desc
    e.target = c.target.name
    c.g.add_edge(e)
    return e

# ---------- file helpers ----------
def glob(dir: str, suffix: str) -> List<str>:
    """The files in a directory with a suffix, SORTED. The glob lives in the
    DESCRIPTOR and never in an edge (1.6d): a pattern inside an edge would make
    the command's hash lie — two runs with different files on disk would be
    different builds with the same graph. And `os.listdir` sorts on purpose (111),
    so the graph comes out the same on every machine."""
    out: List<str> = []
    for n in os.listdir(dir):
        if n.endswith(suffix):
            out.append(path.join(dir, n))
    return out


async def write_file(target: str, text: str):
    """A file GENERATED in the plan. It is the route the doctest comes in by: each
    module's program is written here, from answer 5, and from then on it is a
    source like any other."""
    d = path.dirname(target)
    if len(d) > 0 and not path.isdir(d):
        os.makedirs(d)
    f = await open(target, "w")
    await f.write(text)
    await f.close()
