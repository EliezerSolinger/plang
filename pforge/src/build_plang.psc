"""THE DESCRIPTOR for this repository: plang's build, as a program.

This is the file `pforge/DESIGN.md` calls "the half nobody can copy from
elsewhere" — the one that knows the ladder, the module lists and the harnesses.
The engine is generic; this is specific, and that is why it exists.

**It starts with the LADDER, and not because it is the prettiest: because it is
the hardest.** If the fat edge cannot express "one stage's output is the next
stage's TOOL", the design is wrong — and it is better to find that out in the
first week than in the last. The ladder is:

    bootstrap/*.c  --cc-->  plangc_seed
    sources        --seed-->  s1/*.c  --cc-->  plangc_s1
    sources        --s1-->    s2/*.c  --cc-->  plangc_s2
    sources        --s2-->    s3/*.c
    s2/*.c == s3/*.c  (FIXED POINT: the compiler reproduces itself)

What makes that work in the graph is a single line: each stage's compiler enters
as an implicit INPUT of the edges that use it. From then on the engine knows,
without anybody telling it, that touching the compiler rebuilds everything it
generates.
"""
import os
import path
import <pforge/graph.psc> as G
import <pforge/targets.psc> as T
import <pforge/manifest.psc> as M
import <pforge/repo.psc> as R
import <pforge/api.psc> as A
import <pforge/doctest.psc> as DT

const BUILD: str = "build"

# the fixed-point compiler: what the ladder produces on the second rung, and what
# all the rest of the repository uses. It is the same one `verify-all` uses, and
# for one reason: it is the first binary on the ladder that has already been
# CHECKED against itself.
const PLANGC_S2: str = "build/bin/plangc_s2"

async def ladder(c: T.Ctx) -> str:
    """The bootstrap ladder with a fixed point. Returns the fixed point's
    stamp."""
    # 1) the seed: the committed C, compiled by the `cc` and nothing else. It is
    #    the only thing here that does not depend on us — it is how the compiler
    #    is born on a machine that does not have it yet.
    seed_srcs = T.glob("bootstrap/selfhost", ".c")
    seed = T.cc_program(c, path.join(BUILD, "bin/plangc_seed"), seed_srcs, [], [], [])

    # 2) the compiler's sources, in the order the `--out-dir` mirrors
    sources: List<str> = []
    # `stl` is NOT named: it is a package (`packages/stl`), the sources import it
    # through `<stl/vec.ph>`, and 1.5(a)'s closure brings its headers along. It
    # was the largest of the lists this descriptor used to carry.
    for f2 in T.glob("selfhost", ".ph"):
        sources.append(f2)
    for f3 in T.glob("selfhost", ".p"):
        sources.append(f3)

    # 3) the three rungs. Each one uses the previous one's compiler, and THAT is
    #    what the implicit input expresses.
    c1 = T.derive(c, BUILD, seed)
    s1all = await T.p_modules(c1, sources, path.join(BUILD, "s1"), [])
    s1c = T.only(s1all, ".c")
    p1 = T.cc_program(c1, path.join(BUILD, "bin/plangc_s1"), s1c, T.only(s1all, ".h"), [], [])

    c2 = T.derive(c, BUILD, p1)
    s2all = await T.p_modules(c2, sources, path.join(BUILD, "s2"), [])
    s2c = T.only(s2all, ".c")
    p2 = T.cc_program(c2, path.join(BUILD, "bin/plangc_s2"), s2c, T.only(s2all, ".h"), [], [])

    c3 = T.derive(c, BUILD, p2)
    s3all = await T.p_modules(c3, sources, path.join(BUILD, "s3"), [])

    # 4) the FIXED POINT: what s1 generated and what s2 generated have to be the
    #    same text. It is the test that says the compiler reproduces itself — and
    #    the reason the ladder has three rungs and not two.
    all: List<str> = []
    for x in s2all:
        all.append(x)
    for y in s3all:
        all.append(y)
    stamp = path.join(BUILD, "stamp/fixpoint")
    T.compare_dirs(c, path.join(BUILD, "s2"), path.join(BUILD, "s3"), stamp, all,
                   "fixed point: s2 == s3")

    # 5) the libc typedef gate. `sema` canonicalizes on the TAG on purpose (that
    #    is how the back ends learn the layout), and whoever has to print the
    #    typedef is the C back end. On glibc the build passes either way, so the
    #    only possible test is about the TEXT of the generated C — and it is by
    #    the negative: these four words may not appear.
    tag = T.must_not_match(c, "_IO_FILE\\|__sFILE\\|_G_config\\|__gnuc_va_list", s2all,
                     path.join(BUILD, "stamp/no-libc-tag"),
                     "no internal libc tag in the generated C")
    return T.phony(c, path.join(BUILD, "stamp/compiler"), [stamp, tag],
                   "the compiler checks itself")

# ---------- what is written in pscript ----------
# The compiler is P; everything above it is pscript, and every pscript program in
# this repository is built the same way: the runtime to objects once, the program
# to objects, and one link. The list lives here because it is the descriptor that
# knows what exists — and it is precisely the list that used to be spread across
# five shell harnesses.
struct Program:
    name: str
    source: str
    libs: List<str>

def programs() -> List<Program>:
    return [
        # the build system itself, built by the build system. It is not
        # showing off: it is the hardest test there is for it, because a wrong
        # edge here shows up on the next run.
        Program("pforge", "pforge/src/main.psc", []),
        # the suites' verdict (see `verdict.psc`)
        Program("verdict", "pforge/src/verdict.psc", []),
        # the engine's own suite
        Program("pforge-engine", "pforge/src/engine_test.psc", []),
        # a scoreboard's FLOOR (see `floor.psc`)
        Program("floor", "pforge/src/floor.psc", []),
    ]


async def all_pscript(c: T.Ctx) -> Dict<str, str>:
    """The pscript programs, and each binary's path by name."""
    out: Dict<str, str> = {}
    for p in programs():
        out[p.name] = await T.psc_program(c, p.source, path.join(BUILD, "bin", p.name),
                                          path.join(BUILD, "obj"), [], p.libs)
    return out


# ---------- the editor ----------
# `pstudio` is the only program in the repository that mixes the three languages
# into one binary, and that is why it proves the target library best: the logic is
# pscript, the hand that touches SDL2 and the one that calls the compiler's lexer
# are P, and SDL2 is C from outside, found by `pkg-config`.
def pstudio_p() -> List<str>:
    """What the import CLOSURE does not reach.

    Since 1.5(d) the compiler pulls in the P module of any `import "x.ph"` in the
    closure, and not only of the top file: `highlight.psc` imports `"hl.ph"`, and
    `hl.c` — and the `lexer.c` it uses — come along on their own. The list, which
    had nineteen entries copied from the `Makefile`, is down to two.

    And the two that remain do not remain for lack of compiler: `plang.ph`
    DECLARES `fatal_at` and whoever implements it is `util.p`, a file with another
    name. There is no import edge linking the two, and no closure rule would find
    that — it is knowledge about this repository, and knowledge about this
    repository is exactly what a descriptor exists to carry."""
    return ["selfhost/util.p", "selfhost/utf8.p"]


async def editors(c: T.Ctx) -> List<str>:
    """The two binaries, or an empty list if the machine has no SDL2 — and not
    having it is not an error: it is a machine without what an editor needs, and
    the rest of the build has nothing to do with that.

    TWO of them, from the same layers: `pcode` is the editor and `pstudio` is the
    editor plus the IDE. That they share everything below the entry point is not
    a claim in a document — `tests/decouple.sh` asks the compiler which files each
    one reads and fails if the answer changes."""
    if not await T.has_pkg("sdl2"):
        return []
    cf = await T.pkg_config(c, "sdl2", "--cflags")
    lb = await T.pkg_config(c, "sdl2", "--libs")
    # the compiler needs to PREPROCESS the SDL header in order to ingest
    # `include <SDL2/SDL.h>` (45.5), and it is the same `pkg-config` answer that
    # says where it is. `--cpp` instead of the environment variable: an edge's
    # `env=` REPLACES the environment, and a command with no `PATH` does not find
    # the `cc`.
    # SDL_cpuinfo.h pulls in the host architecture's SIMD-intrinsics header
    # (<arm_neon.h> on Apple Silicon's cc, <immintrin.h> and friends on x86)
    # whenever the matching feature macro is set, and those headers lean on
    # GNU statement expressions (`__extension__ ({ ... })`) for their
    # intrinsics — a construct this front end's expression parser does not
    # model. SDL ships an SDL_DISABLE_*_H per header exactly for a caller that
    # has no reason to parse any of them (nothing here calls an intrinsic):
    # each skips its header outright, on every platform, not just this one.
    # Same set tests/run.sh's own PLANGC_CPP already carries for the shell
    # harness — kept identical so neither build path is the one that forgot
    # an architecture.
    cpp = "cc -DSDL_DISABLE_IMMINTRIN_H -DSDL_DISABLE_MMINTRIN_H -DSDL_DISABLE_XMMINTRIN_H -DSDL_DISABLE_EMMINTRIN_H -DSDL_DISABLE_PMMINTRIN_H -DSDL_DISABLE_ARM_NEON_H -DSDL_DISABLE_MM3DNOW_H -DSDL_DISABLE_LSX_H -DSDL_DISABLE_LASX_H"
    for x in cf:
        cpp += " " + x
    out: List<str> = []
    for name in ["pcode", "pstudio"]:
        out.append(await T.psc_program_with(c, "pstudio/" + name + ".psc",
                                            path.join(BUILD, "bin/" + name),
                                            path.join(BUILD, "obj"), pstudio_p(),
                                            ["--cpp", cpp], cf, lb))
    return out


# ---------- the pscript suite ----------
# A hundred-odd programs that compile, run, and whose whole output is compared
# against an `.expected`. In `tests/run.sh` that is a shell loop that redoes
# everything on every run; here each case is an edge, and a case whose binary and
# whose expected output did not change does not run.
const CORPUS: str = "tests/pscript/run"

# 146.2: `os.watch` is Linux-only (inotify has no macOS answer yet — FSEvents
# is a different API, and it is not written). `watcher.psc` proves the raise,
# not the feature, so its `.expected` assumes the Linux behavior; running it
# elsewhere would be testing a gap the runtime already documents, not a bug.
const PSCRIPT_HOST_HAS_WATCH: bool = __PLANG_LINUX__

# the suite's stamp, which is how you ASK for "run the suite" from a graph that
# only knows how to talk about files (`pforge test`, or `pforge build <this path>`)
const SUITE_PSCRIPT: str = "build/t/stamp/pscript.suite"

async def pscript_suite(c: T.Ctx, verdict: str) -> str:
    cases: List<T.Case> = []
    for src in T.glob(CORPUS, ".psc"):
        base = path.basename(src)
        name = base[0:len(base) - 4]
        # `lib_*.psc` are import pieces, not programs
        if name.startswith("lib_"):
            continue
        if name == "watcher" and not PSCRIPT_HOST_HAS_WATCH:
            continue
        expected = path.join(CORPUS, name + ".expected")
        if not path.isfile(expected):
            continue
        status = 0
        status_file = path.join(CORPUS, name + ".exit")
        if path.isfile(status_file):
            status = int((await read_text(status_file)).strip())
        # a case may ask for compilation FLAGS (`<name>.flags`), which is how an
        # option that changes what gets emitted gets a gate at all: `-O` drops
        # `assert` (46.4), and the only way to see that is to build the same
        # program with it
        flags: List<str> = []
        flags_file = path.join(CORPUS, name + ".flags")
        if path.isfile(flags_file):
            for w in (await read_text(flags_file)).strip().split(" "):
                if len(w) > 0:
                    flags.append(w)
        binary = await T.psc_program(c, src, path.join(BUILD, "t/bin", name),
                                     path.join(BUILD, "t/obj"), flags, [])
        # each case runs in ITS OWN directory. `tests/run.sh` runs the hundred-odd
        # of them in the same one, one at a time; here they run in parallel, and
        # two cases creating a file with the same name would trample each other.
        cases.append(T.Case(name, binary, expected, status, path.join(BUILD, "t/run", name)))
    return T.suite(c, "pscript", cases, verdict, path.join(BUILD, "t/stamp"))


private async def read_text(p: str) -> str:
    f = await open(p, "r")
    t = await f.text()
    await f.close()
    return t


# ---------- the whole verification ----------
# `verify-all.sh` runs eight steps in sequence and takes what all eight take
# together. Here they are EDGES: what does not depend on the others runs
# alongside, and what did not change does not run. What each one does is still the
# usual harness — nothing is rewritten, and that is how it should be: they work,
# and they are read by people who are not going to read pscript.
#
# Each harness gets ITS OWN working directory (`OUT=`), because two runs of
# `tests/run.sh` in the same place trample each other — and both reports come out
# unreadable. This has already cost an investigation.
const VERIFY: str = "build/t/stamp/verify"
# the target of `pforge test`: the pscript suite case by case PLUS the C reading of
# the corpus (cases, modules, stl, p-suite, errors, pstudio, roundtrip). It is
# what `make test` always meant, and that is why it is what it still means.
const TEST: str = "build/t/stamp/test"

def shell_suites() -> List<str>:
    # the SAME list as `verify-all.sh`'s, and that is why `pstudio` and
    # `roundtrip` are here: a verification that runs less than the old one is not
    # the same verification
    return ["cases", "modules", "stl", "p-suite", "errors", "pstudio", "roundtrip", "pscript"]

async def verification(c: T.Ctx, plangc: str, floor_prog: str, suite: str, spkg: str, sdoc: str, fixpoint: str, editor: str) -> str:
    logs: List<str> = []
    logdir = path.join(BUILD, "t/log")
    gating = shell_suites()

    # the three readings of the same corpus: C, QBE and C89. They are the same
    # suite with the same compiler, and that is precisely why they are worth it —
    # what they compare is the BACK END.
    for mode in [["c", ""], ["qbe", "qbe"], ["c89", ""]]:
        vars: Dict<str, str> = {"PLANGC": plangc, "OUT": path.join(BUILD, "t/h", mode[0])}
        if len(mode[1]) > 0:
            vars["BACKEND"] = mode[1]
        if mode[0] == "c89":
            vars["STD"] = "c89"
        argv: List<str> = ["bash", "tests/run.sh"]
        for x in gating:
            argv.append(x)
        logs.append(T.harness(c, "suite-" + mode[0], argv, vars, [plangc], logdir,
                              "suite " + mode[0]))

    # the collector at every safe point, and the protocol the descriptor consumes
    logs.append(T.harness(c, "gc-stress", ["bash", "tests/gc-stress.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "gc-stress"))
    logs.append(T.harness(c, "protocol", ["bash", "tests/protocol.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "the protocol"))
    logs.append(T.harness(c, "knobs", ["bash", "tests/knobs.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "knobs"))
    logs.append(T.harness(c, "net-late", ["bash", "tests/net-late.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "net-late"))
    logs.append(T.harness(c, "print-atomic", ["bash", "tests/print-atomic.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "atomic print"))
    # `pforge check`: the invariants the build does not check because they are not
    # its job — the main one being that P stays runtime-free THROUGH the packages
    logs.append(T.harness(c, "check", ["./" + path.join(BUILD, "bin/pforge"), "check"],
                          {}, [path.join(BUILD, "bin/pforge"), plangc], logdir,
                          "the packages' invariants"))
    # THE ENGINE INSIDE THE EDITOR (F6): without this harness, "the build runs in
    # the editor" is a claim you can only check by looking at a window
    if len(editor) > 0:
        logs.append(T.harness(c, "pstudio-build", ["bash", "tests/pstudio-build.sh"],
                              {"PSTUDIO": editor}, [editor, path.join(BUILD, "bin/pforge")],
                              logdir, "the engine inside the editor"))
    # the committed `build.ninja` is the bootstrap without `pforge`, and a
    # generated file that stays committed has one way to fail: ageing in silence
    logs.append(T.harness(c, "ninja", ["bash", "tests/ninja.sh"],
                          {"PFORGE": path.join(BUILD, "bin/pforge")},
                          [path.join(BUILD, "bin/pforge")], logdir,
                          "the committed build.ninja"))
    logs.append(T.harness(c, "run-pforge", ["bash", "tests/run-cmd-pforge.sh"],
                          {"PFORGE": path.join(BUILD, "bin/pforge")},
                          [path.join(BUILD, "bin/pforge"), plangc], logdir, "run through pforge"))
    # the three harnesses that measure pscript against SOMETHING THAT IS NOT US:
    # corpora other people wrote, and our own programs also run in the reference
    # interpreter. They are not a scoreboard: they are a gate.
    logs.append(T.harness(c, "conformance", ["bash", "tests/conformance/run.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "conformance"))
    logs.append(T.harness(c, "oracle", ["bash", "tests/oracle/run.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "the oracles"))
    # and the OTHER back end's fixed point: a back end can pass every case and
    # still generate a compiler that diverges in a corner no case touches
    logs.append(T.harness(c, "qbe-fixpoint", ["bash", "tests/qbe-fixpoint.sh"],
                          {"PLANGC": plangc, "OUT": path.join(BUILD, "t/h/qbefp")},
                          [plangc], logdir, "the QBE fixed point"))
    logs.append(T.harness(c, "packages", ["bash", "tests/packages.sh"],
                          {"PLANGC": plangc, "OUT": path.join(BUILD, "t/h/packages")},
                          [plangc], logdir, "packages (import <>)"))
    logs.append(T.harness(c, "pforge", ["bash", "tests/pforge.sh"],
                          {"PLANGC": plangc}, [plangc], logdir, "the pforge engine"))

    # ---- the SCOREBOARDS, with the floor next to the suite that measures it ----
    #
    # `c-suite` and `wacct` neither pass nor fail: they measure. What makes them a
    # gate is the FLOOR, and it used to live in two shell variables at the top of
    # `verify-all.sh` — far from the suite, and invisible to whoever reads the
    # descriptor. Here each one is two edges: one that runs and writes the report,
    # another that reads its number and compares. The second is cheap and runs
    # again on its own when somebody lowers the floor by accident.
    for board in [["c-suite", "c-suite", "score: ", "220"],
                  ["wacct", "wacct-valid", "wacct-valid: ", "741"]]:
        lg = T.harness(c, board[0], ["bash", "tests/run.sh", board[1]],
                       {"PLANGC": plangc, "OUT": path.join(BUILD, "t/h/" + board[0])},
                       [plangc], logdir, "scoreboard " + board[0])
        logs.append(T.score_floor(c, floor_prog, lg, board[2], board[3],
                                  path.join(BUILD, "t/stamp", board[0] + ".floor"),
                                  board[0] + " >= " + board[3]))

    # `pforge test` is the C reading of the corpus plus the case-by-case suite: the
    # two measure the same thing by different routes, and together they are what
    # `make test` always meant. The rest (QBE, C89, oracles, collector) is
    # `verify`.
    T.phony(c, TEST, [logs[0], suite, spkg, sdoc],
            "test: the corpus in C, the suite case by case, the packages' tests and the DOCTESTS")

    # the pscript suite as a GRAPH comes along: it measures the same thing
    # `suite-c` does, by another route and case by case — and it is the fast one
    everything: List<str> = []
    for l in logs:
        everything.append(l)
    everything.append(suite)
    everything.append(spkg)
    everything.append(sdoc)
    # the FIXED POINT (the compiler reproduces itself) and the editor: steps 2, 3
    # and 7 of `verify-all`, which are already edges of this graph
    everything.append(fixpoint)
    if len(editor) > 0:
        everything.append(editor)      # the fixed point and the IDE close `verify`
    return T.phony(c, VERIFY, everything, "verify: " + str(len(everything)) + " parts")


# ---------- the workspace ----------
# A `pack.json` at the project's ROOT, with the members. It is what makes this
# repository, to `pforge`, a project like any other — and it is how the ecosystem
# is tested by the people who write it, against the hardest case there is.
#
# One thing comes out of it for the compiler: the search ROOTS. The directory that
# CONTAINS the members is a root, because that is how `import <pui/widget.ph>`
# resolves — the package's name is the path's first piece.
async def workspace_roots(manifest: str) -> List<str>:
    out: List<str> = []
    if not path.isfile(manifest):
        return out
    m = await M.read(manifest)
    if not m.is_workspace:
        return out
    base = path.dirname(manifest)
    for member in m.members:
        r = path.dirname(path.join(base, member))
        if len(r) == 0:
            r = "."
        already = False
        for x in out:
            if x == r:
                already = True
        if not already:
            out.append(r)
    return out


# ---------- the test that travels WITH the package ----------
# `packages/<name>/test/` belongs to the PACKAGE, not to the project. Three
# consequences, and all three are the point:
#
#   * a published package carries the proof that it works, and whoever installs it
#     can run that proof on their own machine;
#   * the test does not have to be named by hand in any harness — it is found
#     because it is where it has to be;
#   * and the project's `pforge test` runs the workspace packages' tests, which is
#     what makes moving a package here not lose coverage.
async def workspace_members(manifest: str) -> List<str>:
    out: List<str> = []
    if not path.isfile(manifest):
        return out
    m = await M.read(manifest)
    if not m.is_workspace:
        return out
    base = path.dirname(manifest)
    for member in m.members:
        out.append(path.join(base, member))
    return out


async def doctest_suite(c: T.Ctx, verdict: str) -> str:
    """The docstrings' examples, running.

    An example in a docstring ages in silence: it looks right, nobody runs it, and
    one day somebody copies a line that stopped working. Here it is a build edge
    like any other.

    Each module's program is GENERATED in the plan, from the compiler's answer 5 —
    the same canonical list `pforge doc` shows. Generating it in the plan is what
    guarantees it is always up to date: the docstring changed, the program
    changes, the edge goes dirty."""
    cases: List<T.Case> = []
    for dir in await workspace_members("pack.json"):
        pkg = path.basename(dir)
        mods: List<str> = []
        for f in sorted(os.listdir(dir)):
            if f.endswith(".psc") or f.endswith(".ph"):
                mods.append(f)
        for mod in mods:
            mod_path = path.join(dir, mod)
            resp = await T.ask(c, T.with_roots(c, [c.query, "--api", mod_path]))
            apis = A.parse("\n".join(resp))
            if len(apis) == 0:
                continue
            api = apis[0]
            base = mod[0:len(mod) - 4] if mod.endswith(".psc") else mod[0:len(mod) - 3]
            # a `.ph` comes in WHOLE (`import <pkg/mod.ph>`): what crosses from it
            # is decided by 45.5 and not by a list of names, and the names stay
            # visible without a qualifier. A `.psc` brings the public names in
            # through `from ... import`.
            imports = "<" + pkg + "/" + mod + ">"
            prog = DT.generate(api, imports) if mod.endswith(".psc") else DT.generate_ph(api, imports)
            if prog.count == 0:
                continue
            label = pkg + "/" + base
            src = path.join(BUILD, "t/doc", pkg + "-" + base + ".psc")
            exp = path.join(BUILD, "t/doc", pkg + "-" + base + ".expected")
            await T.write_file(src, prog.source)
            await T.write_file(exp, prog.expected)
            binary = await T.psc_program(c, src, path.join(BUILD, "t/doc/bin", pkg + "-" + base),
                                         path.join(BUILD, "t/obj"), [], [])
            cases.append(T.Case(label, binary, exp, 0,
                                path.join(BUILD, "t/run", "doc-" + pkg + "-" + base)))
    return T.suite(c, "doctest", cases, verdict, path.join(BUILD, "t/stamp"))


async def packages_suite(c: T.Ctx, verdict: str) -> str:
    cases: List<T.Case> = []
    for dir in await workspace_members("pack.json"):
        tdir = path.join(dir, "test")
        if not path.isdir(tdir):
            continue
        name = path.basename(dir)
        # a package's test may be in either language: `pui` is pscript and `sha2`
        # is P. The difference is only in how it gets built.
        sources: List<str> = []
        for a in T.glob(tdir, ".psc"):
            sources.append(a)
        for b in T.glob(tdir, ".p"):
            sources.append(b)
        for src in sorted(sources):
            base = path.basename(src)
            cut = 4 if src.endswith(".psc") else 2
            n = base[0:len(base) - cut]
            expected = path.join(tdir, n + ".expected")
            if not path.isfile(expected):
                continue
            label = name + "/" + n
            target = path.join(BUILD, "t/pkg", name + "-" + n)
            # objects SEPARATED by language, and that is not tidiness: the same
            # generated `.c` of a P module is compiled with the runtime's `-D`s
            # when it serves a pscript program and without them when it serves a P
            # program. Two different commands for the same `.o` is the graph the
            # engine refuses — rightly, because which of the two defines the
            # content would depend on the order.
            odir = path.join(BUILD, "t/obj" if src.endswith(".psc") else "t/objp")
            binary = ""
            if src.endswith(".psc"):
                binary = await T.psc_program(c, src, target, odir, [], [])
            else:
                binary = await T.p_program(c, src, target, odir, [], [])
            cases.append(T.Case(label, binary, expected, 0,
                                path.join(BUILD, "t/run", name + "-" + n)))
    return T.suite(c, "packages", cases, verdict, path.join(BUILD, "t/stamp"))


# ---------- the `run` manifest ----------
#
# The question the short path answers is a single one: "is what is on disk still
# what was built?". The answer is the list of files the build READ (which the
# compiler said, not which anybody guessed) with each one's date, plus the
# compiler that made it. If everything matches, there is nothing to ask and
# nothing to do.
#
# It is the same idea as the manifest that lived inside `plangc run`, moved house:
# the decision of where to keep it and when to invalidate it is policy, and policy
# belongs to the package manager. And now it lives in `build/run/`, inside the
# project, and not in a `~/.cache` that `make clean` cannot reach.

private def run_man_path(src: str, root: str) -> str:
    name = path.basename(src)
    return path.join(root, "run/.man", name + ".txt")


async def run_manifest_ok(src: str, root: str) -> str:
    """The binary, if it still holds. Empty when a build is needed."""
    man = run_man_path(src, root)
    if not path.isfile(man):
        return ""
    f = await open(man, "r")
    txt = await f.text()
    await f.close()
    lines = txt.split("\n")
    if len(lines) < 2:
        return ""
    binary = lines[0]
    if not path.isfile(binary):
        return ""
    for ln in lines[1:len(lines)]:
        if len(ln) == 0:
            continue
        k = ln.rfind(" ")
        if k < 0:
            return ""
        file = ln[0:k]
        if not path.isfile(file):
            return ""
        if str(path.getmtime_ns(file)) != ln[k + 1:]:
            return ""
    return binary


async def run_manifest_write(src: str, binary: str, g: G.Graph, root: str):
    """The list of what the build READ, with the dates. The inputs come from the
    GRAPH, which got them from the compiler — nothing here is guessed from the
    source."""
    seen: Dict<str, int> = {}
    lines: List<str> = [binary]
    for e in g.edges:
        for iid in e.ins:
            p = g.nodes[iid].p
            if p in seen or not path.isfile(p):
                continue
            seen[p] = 1
            lines.append(p + " " + str(path.getmtime_ns(p)))
        for iid2 in e.implicit:
            p2 = g.nodes[iid2].p
            if p2 in seen or not path.isfile(p2):
                continue
            seen[p2] = 1
            lines.append(p2 + " " + str(path.getmtime_ns(p2)))
    await T.write_file(run_man_path(src, root), "\n".join(lines) + "\n")


def script_root(src: str, forced: str) -> str:
    """Where a LOOSE script's build goes — a file that is no descriptor's target
    (architecture C′).

    It is born NEXT TO THE SCRIPT and not in the directory it was called from:
    `pforge run ../tools/x.psc` from inside another project has no reason to dirty
    that project's `build/` with something that is not its own. Whoever does not
    want that — a read-only directory, sending everything to `/tmp`, sharing
    between two checkouts — passes `--build-dir`.

    The default is local and explicit; the global one only exists if somebody
    types it, which is the lesson `pip` took twenty years to teach."""
    if len(forced) > 0:
        return forced
    d = path.dirname(src)
    return path.join(d, BUILD) if len(d) > 0 else BUILD


async def loose_program(g: G.Graph, query: str, src: str, root: str) -> str:
    """A file that is no descriptor's target, built to be run. It is what `plangc
    run` used to do internally, and the reason it left is that none of this is
    about translating a language: it is POLICY — where to keep the binary, when it
    is stale, what to do with the arguments.

    The binary comes out in `build/run/`, which belongs to the PROJECT like
    everything else: `make clean` takes it and so does `make clean-all`. `plangc
    run`'s `~/.cache` was the last thing in this system that wrote outside the
    tree."""
    roots = await workspace_roots("pack.json")
    for ri in R.installed_roots():
        roots.append(ri)
    c = T.new_ctx(g, path.join(root, "run"), PLANGC_S2)
    c.query = query
    c.plangc_is_built = True
    c.pkgroots = roots
    await T.load_packages(c)
    name = path.basename(src)
    name = name[0:len(name) - 4] if name.endswith(".psc") else name[0:len(name) - 2]
    out = path.join(root, "run/bin", name)
    if src.endswith(".psc"):
        return await T.psc_program(c, src, out, path.join(root, "run/obj"), [], [])
    return await T.p_program(c, src, out, path.join(root, "run/obj"), [], [])


async def assemble(query: str) -> G.Graph:
    """`query` is the compiler that ANSWERS the protocol's questions while the
    graph is assembled — normally the one already on the machine. Whoever RUNS on
    each rung is that rung's artifact, and the difference is what makes the ladder
    expressible."""
    g = G.new_graph()
    roots = await workspace_roots("pack.json")
    # ... and the ones `pforge install` materialized, AFTER the workspace's: what
    # is in the tree wins over what came from outside, which is what allows
    # working on a local copy of a dependency without touching the lock.
    for ri in R.installed_roots():
        roots.append(ri)
    c = T.new_ctx(g, BUILD, query)
    c.pkgroots = roots
    # 2.13: the flags the packages with C declare, read once
    await T.load_packages(c)
    stamp = await ladder(c)

    # everything above runs with the FIXED-POINT compiler — the same one
    # `verify-all` uses, and for the same reason.
    # ONE context for everything pscript: the runtime is generated and compiled
    # once, and every program shares it. Two contexts would generate the same `.c`
    # in two places — double work for nothing.
    cps = T.derive(c, path.join(BUILD, "psc"), PLANGC_S2)
    bins = await all_pscript(cps)
    eds = await editors(cps)
    editor = eds[1] if len(eds) > 1 else ""      # the IDE: what `--build`/`--run` measure
    suite = await pscript_suite(cps, bins["verdict"])
    spkg = await packages_suite(cps, bins["verdict"])
    sdoc = await doctest_suite(cps, bins["verdict"])
    await verification(cps, PLANGC_S2, bins["floor"], suite, spkg, sdoc, stamp, editor)

    # the default target is what "is built" means: the compiler checks itself, and
    # the tools above it exist. The suites are a target you ASK for (`pforge build
    # <stamp>`), not the default — building is not testing.
    g.default_targets.append(stamp)
    g.default_targets.append(bins["pforge"])
    for e in eds:
        g.default_targets.append(e)
    return g
