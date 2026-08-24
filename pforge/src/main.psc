"""`pforge` — the command on top.

It is the library's FRONT END: the engine reports events and whoever prints is
here. The IDE (F6) is the other front end, and paints the same events — it is
that separation that makes the engine reusable instead of a script with a `print`
in the middle.

    pforge build [target...]   builds (the default is the graph's default target)
    pforge test                runs the pscript suite, case by case
    pforge verify              the whole verification (`verify-all`, as a graph)
    pforge run <target> [args] builds the target and runs it
    pforge explain <output>    why THIS output is dirty
    pforge graph               the graph as JSON, to inspect or to version
    pforge ninja [file]        writes the bootstrap's `build.ninja` (default: -)
    pforge doc <target> [name] a module's (or a package's) interface, with its
                              documentation — `target` is a file or the name of a
                              workspace package
    pforge tree                the workspace's packages, and what each one pulls in
    pforge why <package>       who pulled this package in
    pforge clean               deletes what the build produced
    pforge help

Options: `-j N` (processes in flight; the default is the number of cores), `-k N`
(keep going after N failures; the default is to stop at the first),
`-n`/`--dry-run`, `--query <plangc>` (the compiler that answers the protocol's
questions).
"""
import os
import path
import sys
import <pforge/graph.psc> as G
import <pforge/build.psc> as B
import <pforge/targets.psc> as T
import <pforge/ninja.psc> as N
import <pforge/api.psc> as A
import <pforge/manifest.psc> as MF
import <pforge/pkg.psc> as PK
import build_plang as BP
import <pforge/repo.psc> as R
import <tar/tar.psc> as TARM
import <pforge/lock.psc> as LK

const LOG: str = "build/log/build.log"

done_count: int = 0
total_edges: int = 0
failed: bool = False

def on_plan(total: int):
    """A new plan is a new build, and the report restarts with it.

    This is not tidiness: `pforge dev` and `--repro` build two or twenty times in
    the SAME process, and a counter that did not restart would say `[64/61]` on
    the second one — a number larger than the total, which is the fastest way to
    make somebody distrust an entire report."""
    global total_edges
    global done_count
    global failed
    global labels
    global score_ok
    global score_bad
    total_edges = total
    done_count = 0
    failed = False
    # an empty literal needs a type, and it is good that it does: a silent `= {}`
    # in an already-typed global would be one shape for two different intentions
    lab0: Dict<int, str> = {}
    ok0: Dict<str, int> = {}
    bad0: Dict<str, List<str>> = {}
    labels = lab0
    score_ok = ok0
    score_bad = bad0
    if json_out:
        print('{"event": "plan", "total": ' + str(total) + '}')
        return
    if total == 0:
        print("nothing to do")

# `--json`: the SAME data as the events and the queries, in JSON. One object per
# LINE in the event stream (whoever reads wants to react while the build runs, and
# a single document can only be read at the end); one document for the queries,
# which are an answer and not a stream.
json_out: bool = False

# the compiler that ANSWERS, kept here because the repository commands need it for
# a single question (the language's version, against the toolchain requirement)
# and threading it through six signatures for that would be worse
current_query: str = ""


def query_global() -> str:
    return current_query

labels: Dict<int, str> = {}

# the SCOREBOARD: how many edges of each suite passed, and which failed. The key
# is what comes before the first `: ` in the description — which is how the target
# library writes a case's label (`pscript: case_name`). An ordinary build has no
# suite at all and the scoreboard does not appear.
score_ok: Dict<str, int> = {}
score_bad: Dict<str, List<str>> = {}

private def suite_of(label: str) -> str:
    k = label.find(": ")
    return label[0:k] if k > 0 else ""

private def tally(label: str, ok: bool):
    global score_ok
    global score_bad
    su = suite_of(label)
    if len(su) == 0:
        return
    if su not in score_ok:
        score_ok[su] = 0
        score_bad[su] = []
    if ok:
        score_ok[su] = score_ok[su] + 1
    else:
        score_bad[su].append(label[len(su) + 2:])

def on_start(id: int, what: str):
    global labels
    labels[id] = what

def on_end(id: int, st: int, out: str, ms: int):
    global done_count
    global failed
    done_count += 1
    tally(labels[id] if id in labels else "", st == 0)
    if json_out:
        print('{"event": "end", "id": ' + str(id) + ', "status": ' + str(st)
              + ', "ms": ' + str(ms) + ', "what": ' + G.jstr(labels[id] if id in labels else "")
              + ', "output": ' + G.jstr(out) + '}')
        if st != 0:
            failed = True
        return
    mark = "[" + str(done_count) + "/" + str(total_edges) + "]"
    if st == 0:
        print(mark, "ok")
        if len(out) > 0:
            print(out.rstrip())
    else:
        failed = True
        # WHICH edge failed. Without this the report says something went wrong and
        # does not say what — and in a six-hundred-edge build that is not a report.
        who = labels[id] if id in labels else "?"
        print(mark, "FAILED (status " + str(st) + "):", who)
        if len(out) > 0:
            print(out.rstrip())

def on_error(msg: str):
    """A problem with the GRAPH — not with an edge. It comes out BEFORE any
    command runs, because it is the kind of thing that invalidates the whole
    build."""
    global failed
    failed = True
    if json_out:
        print('{"event": "error", "message": ' + G.jstr(msg) + '}')
        return
    print("error:", msg)

def on_done(ok: bool, fails: int):
    if json_out:
        parts: List<str> = []
        ks0: List<str> = []
        for k0 in score_ok:
            ks0.append(k0)
        for k1 in sorted(ks0):
            bad0: List<str> = []
            for nm in score_bad[k1]:
                bad0.append(G.jstr(nm))
            parts.append(G.jstr(k1) + ': {"ok": ' + str(score_ok[k1])
                         + ', "failed": [' + ", ".join(bad0) + ']}')
        print('{"event": "done", "ok": ' + ("true" if ok else "false")
              + ', "failed": ' + str(fails) + ', "suites": {' + ", ".join(parts) + '}}')
        return
    # the SCOREBOARD, when there was a suite. It exists because "587 edges ok" is
    # not what whoever runs tests wants to know: what you want is how many cases
    # passed, and WHICH failed — and a six-hundred-edge build hides both.
    ks: List<str> = []
    for k in score_ok:
        ks.append(k)
    for k2 in sorted(ks):
        bad = score_bad[k2]
        # "RAN", and not "exist": a case whose binary and whose expected output
        # did not change does not run, and saying "1 ok" when a hundred and
        # fourteen are up to date would be a scoreboard that lies. Whoever wants
        # the total runs with a clean tree.
        total = score_ok[k2] + len(bad)
        print("   " + k2 + ": " + str(total) + " ran — " + str(score_ok[k2])
              + " ok, " + str(len(bad)) + " failed")
        n = 0
        for name in bad:
            if n >= 10:
                print("       (and " + str(len(bad) - 10) + " more)")
                break
            print("       " + name)
            n += 1
    if not ok:
        print("build failed:", fails, "problem(s)")

# the reporter prints the DESCRIPTION at the start of each edge; the `on_start`
# above is empty because the line only makes sense next to the result when N run
# at the same time — with parallelism, "started" and "finished" interleave
def on_start_verbose(id: int, what: str):
    global labels
    labels[id] = what
    print("  ->", what)

async def cmd_build(targets: List<str>, jobs: int, keep: int, dry: bool, query: str,
                    verbose: bool, repro: bool) -> int:
    g = await BP.assemble(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_error)
    ok = await B.build(g, LOG, targets, B.Opts(jobs, keep, dry, False), rep)
    if not ok or dry or not repro:
        return 0 if ok else 1
    return await check_repro(g, targets, jobs, keep, query, rep)


const REPRO: str = "build/repro"

private async def check_repro(g: G.Graph, targets: List<str>, jobs: int, keep: int,
                              query: str, rep: B.Rep) -> int:
    """`--repro`: builds twice and compares byte for byte.

    `verify-all` already did this by hand for the compiler (`diff -rq out2 out3`,
    and the QBE fixed point); here it becomes a command, and starts holding for
    any project and any target.

    The second build starts from ZERO — the outputs and the build log get out of
    the way — because a second incremental run proves nothing: it runs no edge at
    all. What gets compared is the content, never the date: a reproducible build
    may well write the same byte in a different second.

    What the first build made is **moved** to `build/repro/`, and not copied. The
    difference matters for two reasons, and the second one cost a tree to
    discover: moving preserves the file as it is (the execute permission included,
    which a byte-for-byte copy through the language would lose), and it allows
    **putting everything back** when the second build fails — which is exactly
    when there is no new artifact to take its place.

    The second build's graph is assembled before anything gets moved: assembling
    it means ASKING the compiler, and the compiler is one of the outputs.

    The honest limit of this is measured and written down: the P and the pscript
    we generate have no date and no absolute path in what they emit, so they are
    reproducible by construction; a C package that uses `__DATE__`/`__TIME__` is
    not, and the world's answer to that (`SOURCE_DATE_EPOCH`) is the one to adopt
    the day it shows up."""
    outputs: List<str> = []
    for e in g.edges:
        if not e.want:
            continue
        for oid in e.outs:
            pth = g.nodes[oid].p
            if path.isfile(pth):
                outputs.append(pth)
    if len(outputs) == 0:
        print("--repro: the build produced no file to compare")
        return 0
    if path.isdir(REPRO):
        rmtree(REPRO)
    g2 = await BP.assemble(query)
    for p1 in outputs:
        aside = path.join(REPRO, p1)
        d = path.dirname(aside)
        if len(d) > 0 and not path.isdir(d):
            os.makedirs(d)
        os.rename(p1, aside)
    if path.isfile(LOG):
        os.remove(LOG)
    print("--repro: " + str(len(outputs)) + " output(s) moved aside; building again from scratch")
    if not await B.build(g2, LOG, targets, B.Opts(jobs, keep, False, False), rep):
        for p9 in outputs:
            if not path.isfile(p9):
                d9 = path.dirname(p9)
                if len(d9) > 0 and not path.isdir(d9):
                    os.makedirs(d9)
                os.rename(path.join(REPRO, p9), p9)
        rmtree(REPRO)
        print("--repro: the second build FAILED — and a build that only works")
        print("         the first time is the most expensive defect there is.")
        print("         what the first one had produced is back in place.")
        return 1
    diffs: List<str> = []
    for p3 in outputs:
        if not path.isfile(p3):
            diffs.append(p3 + "  (the second build did not produce it)")
            continue
        h1 = R.hash_of(await R.read_bytes(path.join(REPRO, p3)))
        h2 = R.hash_of(await R.read_bytes(p3))
        if h1 != h2:
            diffs.append(p3 + "  " + h1[0:16] + "… -> " + h2[0:16] + "…")
    if json_out:
        jd: List<str> = []
        for d0 in diffs:
            jd.append(G.jstr(d0))
        print('{"outputs": ' + str(len(outputs)) + ', "reproducible": '
              + ("true" if len(diffs) == 0 else "false") + ', "differ": [' + ", ".join(jd) + ']}')
    if len(diffs) == 0:
        rmtree(REPRO)
        if not json_out:
            print("--repro: both builds gave the SAME bytes in " + str(len(outputs)) + " file(s)")
        return 0
    if not json_out:
        print("--repro: " + str(len(diffs)) + " of " + str(len(outputs)) + " file(s) did NOT come out the same:")
        for d2 in diffs:
            print("   " + d2)
        print("   the first build is kept in " + REPRO + "/, to compare")
    return 1


async def cmd_run(targets: List<str>, jobs: int, query: str, verbose: bool, builddir: str) -> int:
    """Builds and runs. Two things it accepts, and the second is the one that
    closes F7:

      * a graph TARGET (`pforge run build/bin/pstudio`);
      * a source FILE (`pforge run x.psc`, `pforge run x.p`) — which is in no
        descriptor, and is built here, in `build/run/`.

    The second case is what `plangc run` used to do, and it was the only POLICY
    decision still living inside the compiler: where to keep the binary, when it
    is stale, and what to do with the arguments. None of that is about translating
    a language.

    And the program **becomes this process** (`os.exec`). Before, it ran as a
    child with its output captured, which serves a program that prints and nothing
    else: no keyboard, no screen, no terminal size, no Ctrl-C. That is why the
    exit status no longer needs a conversation either — it IS the program's,
    because it is the same process.

    A build that fails exits with 101 (cargo's convention), so a script can tell
    "the program refused" from "the program never came to exist"."""
    if len(targets) == 0:
        print("usage: pforge run <target|file.psc> [args...]")
        return 2
    target = targets[0]
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_error)
    loose: bool = (target.endswith(".psc") or target.endswith(".p")) and path.isfile(target)
    if loose:
        # THE SHORT PATH, and it is what makes `pforge run` worth having as a
        # script launcher: if the last run's manifest still matches — the same
        # compiler, the same files, the same dates — there is nothing to ask and
        # nothing to build, and the process becomes the program in milliseconds.
        # Without this, every run pays two compiler invocations (half a second) to
        # find out there was nothing to do.
        root = BP.script_root(target, builddir)
        ready = await BP.run_manifest_ok(target, root)
        if len(ready) > 0:
            argv0: List<str> = [ready if ready.startswith("/") else path.join(os.getcwd(), ready)]
            i0 = 1
            while i0 < len(targets):
                argv0.append(targets[i0])
                i0 += 1
            os.exec(argv0)
            return 127
    g = G.new_graph()
    if loose and path.isfile(BP.PLANGC_S2):
        # THE MINIMAL GRAPH, and this is what makes `run` fast: assembling the
        # whole descriptor costs hundreds of questions to the compiler (twelve
        # seconds here), and none of them is about this file. When the compiler
        # already exists, what gets built is only the program.
        target = await BP.loose_program(g, query, target, BP.script_root(target, builddir))
    else:
        g = await BP.assemble(query)
        if target not in g.by_path and loose:
            target = await BP.loose_program(g, query, target, BP.script_root(target, builddir))
        elif target not in g.by_path:
            print("I did not find '" + target + "' — neither a descriptor target nor a file")
            return 1
    if not await B.build(g, LOG, [target], B.Opts(jobs, 1, False, False), rep):
        return 101
    if loose:
        await BP.run_manifest_write(targets[0], target, g, BP.script_root(targets[0], builddir))
    argv: List<str> = [target if target.startswith("/") else path.join(os.getcwd(), target)]
    i = 1
    while i < len(targets):
        argv.append(targets[i])
        i += 1
    # there is no coming back from here: the process is the program
    os.exec(argv)
    return 127

async def cmd_dev(targets: List<str>, jobs: int, query: str, verbose: bool) -> int:
    """`pforge dev [target]` — builds, waits for something to change, and builds
    again. Until somebody presses Ctrl-C.

    **The list of what gets watched is not guessed**: it is the GRAPH, which got
    it from the compiler (answer 1). A `dev` that watched a whole directory would
    see editor saves, temporary files and `build/` itself; this one sees exactly
    the files the build reads, and nothing else.

    **And it uses neither inotify nor kqueue**, which is a decision and not a gap.
    Both exist, they differ from each other, and they would force a new primitive
    into the runtime — to watch a few hundred files whose dates are read in less
    than a millisecond. The loop asks every 200 ms; the cost does not show up in a
    profile and the code works the same everywhere. The day the tree is big enough
    for this to hurt, the primitive goes in underneath and this command does not
    change.

    **And it RESTARTS the program**: it kills the child, waits for it to leave,
    builds, relaunches. The `SIGTERM` is a request and not an execution — a
    `SIGKILL` does not let the program close what it had opened, and a loop that
    corrupts a file on every save is worse than one that waits half a second."""
    g = await BP.assemble(query)
    target = targets[0] if len(targets) > 0 else ""
    tl: List<str> = [target] if len(target) > 0 else []
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_error)
    await B.build(g, LOG, tl, B.Opts(jobs, 1000000, False, False), rep)
    # what to watch: the INPUTS of every edge, which is what the compiler said it
    # reads. A file that does not exist yet goes in just the same — coming into
    # existence is a change like any other.
    seen: Dict<str, int> = {}
    watched: List<str> = []
    for e in g.edges:
        for iid in e.ins:
            p = g.nodes[iid].p
            # what the build PRODUCES is not watched. A generated `.c` is an input
            # of the next compilation, so watching it would make the build trigger
            # itself forever — and that is exactly what it did the first time it
            # ran.
            if p.startswith(BP.BUILD + "/") or p in seen:
                continue
            seen[p] = 1
            watched.append(p)
    dates: Dict<str, int> = {}
    for p2 in watched:
        dates[p2] = path.getmtime_ns(p2) if path.isfile(p2) else 0
    # the program, when the target is one: launched now and relaunched on every
    # change
    pid = 0
    if len(target) > 0 and path.isfile(target):
        pid = os.spawn([target if target.startswith("/") else path.join(os.getcwd(), target)])
        print("dev: launched " + target + " (pid " + str(pid) + ")")
    print(f"dev: watching {len(watched)} file(s). Ctrl-C to leave.")

    while True:
        await sleep(0.2)
        changed: List<str> = []
        for p3 in watched:
            now_ns = path.getmtime_ns(p3) if path.isfile(p3) else 0
            if now_ns != dates.get(p3, 0):
                dates[p3] = now_ns
                changed.append(p3)
        if len(changed) == 0:
            continue
        # an editor's `save` writes the file in two steps (temporary + rename),
        # and there are editors that touch several in a row. Waiting a little
        # after the first change gathers everything into one build.
        await sleep(0.15)
        for p4 in watched:
            now2 = path.getmtime_ns(p4) if path.isfile(p4) else 0
            if now2 != dates.get(p4, 0):
                dates[p4] = now2
                if p4 not in changed:
                    changed.append(p4)
        print("")
        print("dev: changed " + ", ".join(changed[0:3]) + ("..." if len(changed) > 3 else ""))
        # the old program leaves BEFORE the new one is built: it is using the
        # binary the build is going to rewrite
        if pid > 0:
            os.kill(pid)
            waits = 0
            while os.alive(pid) and waits < 100:
                await sleep(0.05)
                waits += 1
            pid = 0
        g2 = await BP.assemble(query)
        ok2 = await B.build(g2, LOG, tl, B.Opts(jobs, 1000000, False, False), rep)
        if ok2 and len(target) > 0 and path.isfile(target):
            pid = os.spawn([target if target.startswith("/") else path.join(os.getcwd(), target)])
            print("dev: relaunched (pid " + str(pid) + ")")
    return 0


async def cmd_verify(jobs: int, query: str, verbose: bool) -> int:
    """The whole of `verify-all.sh`, as a GRAPH. Its eight steps are sequential
    and take what all eight take together; here what does not depend on the others
    runs alongside, and what did not change does not run."""
    g = await BP.assemble(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_error)
    ok = await B.build(g, LOG, [BP.VERIFY], B.Opts(jobs, 1000000, False, False), rep)
    return 0 if ok else 1

async def cmd_test(jobs: int, query: str, verbose: bool) -> int:
    """The suites. Two differences from `build`, and both are deliberate:

      * a high `-k` by default — whoever runs tests wants the whole SCOREBOARD,
        not the first failure. A build stops at the first because the rest was
        going to fail with it; a suite does not;
      * the target is the suite's stamp, and it is not the default target:
        building is not testing, and a `pforge build` that ran three hundred cases
        would be a `build` nobody would use."""
    g = await BP.assemble(query)
    st = on_start_verbose if verbose else on_start
    rep = B.Rep(on_plan, st, on_end, on_done, on_error)
    ok = await B.build(g, LOG, [BP.TEST], B.Opts(jobs, 1000000, False, False), rep)
    return 0 if ok else 1

async def cmd_explain(targets: List<str>, query: str) -> int:
    g = await BP.assemble(query)
    w = await B.why_dirty(g, LOG, targets)
    if len(w) == 0:
        if json_out:
            print('{"dirty": {}}')
        else:
            print("nothing is dirty")
        return 0
    ks: List<str> = []
    for k in w:
        ks.append(k)
    ks = sorted(ks)
    if json_out:
        parts: List<str> = []
        for k3 in ks:
            parts.append(G.jstr(k3) + ": " + G.jstr(w[k3]))
        print('{"dirty": {' + ", ".join(parts) + '}}')
        return 0
    for k2 in ks:
        print(k2 + ": " + w[k2])
    return 0

async def cmd_graph(query: str) -> int:
    g = await BP.assemble(query)
    print(G.to_json(g).rstrip())
    return 0

# ---------- the packages ----------
private async def world() -> PK.World:
    return await PK.read_world(await BP.workspace_members("pack.json"))

async def cmd_check(query: str) -> int:
    """`pforge check` — the invariants the build does not check because it is not
    its job.

    Two of them, and both are about the same promise: **P is runtime-free, and
    stays runtime-free through the packages**.

      1. a `lang: p` package does not depend on a `pscript` package (read from the
         manifests, for free);
      2. and no `.psc` shows up in the CLOSURE of a `p` package's root module —
         which is the same thing said where it actually happens, because an
         `import` reaches further than a manifest.

    What is NOT a problem, and therefore is not checked: a P package with tests in
    pscript. `sha2` has one, on purpose — it is how the 45.5 crossing is proven to
    work. It is not in the root's closure, and that is why the question is about
    the CLOSURE and not about the directory."""
    m = await world()
    problems = PK.check_languages(m)
    roots = await BP.workspace_roots("pack.json")
    dcheck = path.join(BP.BUILD, "check")
    if not path.isdir(dcheck):
        os.makedirs(dcheck)
    for p in m.packages:
        if p.lang != "p":
            continue
        man = await MF.read(path.join(p.dir, "pack.json"))
        if len(man.root) == 0:
            continue
        argv: List<str> = [query]
        for r in roots:
            argv.append("--pkg-path")
            argv.append(r)
        argv.append("--deps")
        argv.append("--out-dir")
        argv.append(dcheck)
        argv.append(path.join(p.dir, man.root))
        res = await os.run(argv, stdout=path.join(dcheck, "deps.txt"))
        if res.status() != 0:
            # the compiler is this invariant's FIRST gate: a `.ph` that imports a
            # pscript module it already refuses. When that happens what matters is
            # what IT said, not our paraphrase.
            problems.append(p.name + ": the closure of " + man.root + " would not be read:\n       "
                            + res.output().strip().replace("\n", "\n       "))
            continue
        f = await open(path.join(dcheck, "deps.txt"), "r")
        txt = await f.text()
        await f.close()
        for ln in txt.split("\n"):
            if ln.endswith(".psc"):
                problems.append(p.name + " is `lang: p` and the closure of " + man.root
                                + " goes through " + ln + ", which is pscript")
    # 2.7: a SYSTEM dependency is a DECLARATION in the manifest, and `pkg-config`
    # is one of its resolvers. Whoever calls it is us, never the package — the
    # list of programs these tools invoke is FIXED (`plangc`, `cc`, `pkg-config`)
    # and is not extensible by a third-party package. Here the declaration starts
    # being worth something before the build begins: if the library is not on this
    # machine, it is said now and by name.
    for p2 in m.packages:
        man2 = await MF.read(path.join(p2.dir, "pack.json"))
        for sd in man2.system:
            r2 = await os.run(["pkg-config", "--exists", sd.name])
            if r2.status() != 0:
                problems.append(p2.name + " declares the system library `" + sd.name
                                + "` and `pkg-config` does not find it on this machine")
    if json_out:
        js: List<str> = []
        for pr in problems:
            js.append(G.jstr(pr))
        print("[" + ", ".join(js) + "]")
        return 1 if len(problems) > 0 else 0
    if len(problems) == 0:
        print(f"check: {len(m.packages)} package(s), no problems")
        return 0
    for pr in problems:
        print("error: " + pr)
    return 1


async def cmd_tree() -> int:
    """`pforge tree` — what this project uses, and through what."""
    m = await world()
    if len(m.packages) == 0:
        print("no packages: this project has no workspace `pack.json`, or it lists no members")
        return 1
    if json_out:
        parts: List<str> = []
        for p in m.packages:
            ds: List<str> = []
            i = 0
            while i < len(p.deps):
                ds.append('{"name": ' + G.jstr(p.deps[i]) + ', "range": ' + G.jstr(p.reqs[i]) + '}')
                i += 1
            parts.append('{"name": ' + G.jstr(p.name) + ', "version": ' + G.jstr(p.version)
                         + ', "lang": ' + G.jstr(p.lang) + ', "dir": ' + G.jstr(p.dir)
                         + ', "deps": [' + ", ".join(ds) + ']}')
        print('{"packages": [' + ", ".join(parts) + ']}')
        return 0
    print(PK.tree(m).rstrip())
    if len(m.missing) > 0:
        print("")
        for f in m.missing:
            print("   MISSING: " + f)
        return 1
    return 0

async def cmd_why(targets: List<str>) -> int:
    """`pforge why <package>` — who pulled it in.

    It is the question every large lock eventually provokes, and the answer has to
    give the PATH and not only the name: knowing that `hash` is there because `map`
    asked for it, and `map` because the compiler asked for it, is what lets you
    decide what to do."""
    if len(targets) == 0:
        print("usage: pforge why <package>")
        return 2
    target = targets[0]
    m = await world()
    if m.find(target) < 0:
        print("'" + target + "' is not a package of this workspace")
        return 1
    who = m.who_pulls(target)
    if json_out:
        ns: List<str> = []
        for q in who:
            ns.append(G.jstr(q))
        print('{"package": ' + G.jstr(target) + ', "pulled_by": [' + ", ".join(ns) + ']}')
        return 0
    p = m.packages[m.find(target)]
    print(p.name + " " + p.version + "  (" + p.lang + ", in " + p.dir + ")")
    if len(who) == 0:
        print("   nobody pulls it in: it is a workspace member in its own right")
        return 0
    for q in who:
        i = m.find(q)
        req = ""
        j = 0
        while j < len(m.packages[i].deps):
            if m.packages[i].deps[j] == target:
                req = m.packages[i].reqs[j]
            j += 1
        print("   <- " + q + " asks for " + req)
    return 0

# ---------- doc ----------
private async def package_module(target: str) -> str:
    """The ROOT module of a workspace package, if `target` is a package name.

    This is what the manifest's `root` field is for: a package's interface is ONE
    module, and whoever wants its documentation does not have to know which file
    it lives in."""
    roots = await BP.workspace_roots("pack.json")
    for r in roots:
        man = path.join(r, target, "pack.json")
        if path.isfile(man):
            m = await MF.read(man)
            if len(m.root) == 0:
                return ""       # a package with no root: the caller LISTS the modules
            return path.join(r, target, m.root)
    return ""


private async def list_package(target: str) -> int:
    """A package with NO root is a set of modules, and what gets shown of it is
    the list. `stl` is like that: ten independent headers, and electing one as
    "the interface" would be arbitrary."""
    roots = await BP.workspace_roots("pack.json")
    for r in roots:
        dir = path.join(r, target)
        if not path.isfile(path.join(dir, "pack.json")):
            continue
        m = await MF.read(path.join(dir, "pack.json"))
        print("== " + target + " " + m.version + "  (" + m.lang + ")")
        if len(m.description) > 0:
            print("   " + m.description)
        print("")
        for name in sorted(os.listdir(dir)):
            if name.endswith(".ph") or name.endswith(".psc"):
                print("   " + target + "/" + name)
        print("")
        print("   pforge doc " + target + "/<module> for the interface of one of them")
        return 0
    return 1

private def indent(t: str) -> str:
    """The docstring, indented. Without this, a multi-line docstring hugs the
    margin and disappears into the list."""
    out = ""
    for l in t.split("\n"):
        out += "    " + l.rstrip() + "\n"
    return out.rstrip()

# ---------- the repository ----------

private async def package_api(dir: str, m: MF.Manifest, query: str,
                              api: Dict<str, List<str>>, hashes: Dict<str, str>):
    """The canonical symbol list of each of the package's modules, in the index.

    It is not decoration: it is what makes `pforge search draw_rect` search BY
    SYMBOL without downloading anything, and what makes semver honesty verifiable
    from the index — 0.1.0's interface and 0.1.1's are both there, and comparing
    them is a subtraction. And it comes for free, because the compiler already
    produces it (answer 5)."""
    mods: List<str> = []
    if len(m.root) > 0:
        mods.append(path.join(dir, m.root))
    else:
        # a package with NO root is a set of independent modules (`stl` is like
        # that): all of them go in
        for name in sorted(os.listdir(dir)):
            if name.endswith(".ph") or name.endswith(".psc"):
                mods.append(path.join(dir, name))
    roots = await BP.workspace_roots("pack.json")
    for mod in mods:
        argv: List<str> = [query]
        for r in roots:
            argv.append("--pkg-path")
            argv.append(r)
        argv.append("--api")
        argv.append(mod)
        res = await os.run(argv)
        if res.status() != 0:
            raise error("the compiler could not read the interface of " + mod + ":\n" + res.output())
        for a in A.parse(res.output()):
            # ONLY THIS package's modules. Answer 5 brings the whole closure —
            # `sha2` imports `stl/cstr.ph` and `stl`'s interface came along — and
            # an index that declared other people's interfaces would say `sha2`
            # offers `CStr.slice`, which is not its.
            if not a.path.startswith(dir + "/"):
                continue
            rel = a.path[len(dir) + 1:len(a.path)]
            syms: List<str> = []
            for sb in a.symbols:
                syms.append(sb.decl)
            api[rel] = syms
            hashes[rel] = a.hash


async def cmd_keygen(targets: List<str>) -> int:
    """`pforge keygen <file>` — a new key.

    It writes the PRIVATE one into `<file>` (32 bytes in hexadecimal, and nothing
    else) and the PUBLIC one into `<file>.pub`. The private one does not go into
    `build/`, does not go into the repository and is not committed: it is the one
    thing in this whole system that is not shared. The public one is to put into
    the index and the lock, where whoever reviews can see it."""
    if len(targets) == 0:
        print("usage: pforge keygen <file>")
        return 2
    target = targets[0]
    if path.isfile(target):
        print(target + " already exists. A key you overwrite is a key you lost — delete it by hand if that is what you want.")
        return 1
    seed = await R.new_seed()
    hex_text = ""
    for b in seed:
        hex_text += "0123456789abcdef"[int(b) >> 4] + "0123456789abcdef"[int(b) & 15]
    pub = R.public_key(seed)
    await R.write_bytes(target, R.bytes_of_text(hex_text + "\n"))
    await R.write_bytes(target + ".pub", R.bytes_of_text(pub + "\n"))
    print("private: " + target + "   (do NOT commit, do NOT share)")
    print("public:  " + target + ".pub")
    print("   " + pub)
    return 0


private async def compiler_version(query: str) -> str:
    """The LANGUAGE version this compiler accepts — `plangc 0.1.0 (hash)`.

    It is question 4 of the protocol, and it is the only thing a manifest's
    toolchain requirement has to compare against.

    In a project that CONSUMES packages there is no `build/bin/plangc_s2`: its
    compiler is installed, on the PATH. That is why the second attempt is `plangc`
    with no path — and if there is not even that, an empty string comes back and
    the caller SAYS it did not check. A gate that switches itself off in silence
    is worse than one that does not exist."""
    for cand in [query, "plangc"]:
        if len(cand) == 0:
            continue
        r = await os.run([cand, "--version"])
        if r.status() == 0:
            parts = r.output().strip().split(" ")
            if len(parts) > 1:
                return parts[1]
    return ""


private async def project_repos() -> List<R.Repo>:
    """This project's repositories, in search order."""
    out: List<R.Repo> = []
    if not path.isfile("pack.json"):
        return out
    m = await MF.read("pack.json")
    i = 0
    while i < len(m.repos):
        out.append(R.repo(m.repos[i], m.repos_unsafe[i]))
        i += 1
    return out


private async def stored_index(r: R.Repo) -> R.Index:
    target = path.join(R.indexes_dir(), r.id + ".json")
    if not path.isfile(target):
        raise error("no index for " + r.url + " — run `pforge update` first", IO)
    f = await open(target, "r")
    raw = await f.text()
    await f.close()
    return R.read_index(raw, target)


async def cmd_update() -> int:
    """`pforge update` — downloads the indexes and stores them. It is the ONLY
    operation that touches the network without somebody asking for a package, and
    that is on purpose: a build that resolves versions over the network is a build
    that changes its result without anything in the project having changed."""
    repos = await project_repos()
    if len(repos) == 0:
        print("no repositories: add \"repos\": [...] to the workspace's pack.json")
        return 1
    lk = await LK.read("pack.lock")
    n = 0
    for r in repos:
        bs = await R.fetch(r, "index.json")
        sig = await R.signature_of(r, "index.json")
        i = lk.known_repo(r.url)
        known = lk.repos[i].key if i >= 0 else ""
        # ---- the REPOSITORY's signature, and TOFU ----
        if len(known) > 0:
            # the key is already known: from here on it does NOT change in silence
            if not R.verify_sig(known, bs, sig):
                print(f"{r.url}: the index does NOT match the key this project accepted.")
                print(f"   the key is in pack.lock ({known[0:16]}…) and went through code review when it got there.")
                print("   either the index was swapped, or the repository changed keys — either way this stops here.")
                return 1
        elif len(sig) > 0:
            # TOFU: the first time it is seen. The key that signed goes into the
            # LOCK, which is COMMITTED — that is how trust gets versioned and a
            # future swap shows up in a diff instead of in a warning on one
            # person's terminal. You do not know whose key it is; you know that
            # from now on it has to be the same one.
            found = ""
            for name in R.index_keys(R.read_index(str(bs), "index")):
                if R.verify_sig(name, bs, sig):
                    found = name
            if len(found) == 0:
                print(f"{r.url}: the index comes signed, and the signature matches no key it declares.")
                print("   this is not an unknown key: it is a wrong signature.")
                return 1
            if i >= 0:
                lk.repos[i].key = found
            else:
                lk.repos.append(LK.KnownRepo(r.url, found, R.now_iso()[0:10]))
            print(f"   the repository's key accepted now (TOFU) and recorded in pack.lock: {found[0:16]}…")
        else:
            if not r.is_unsafe:
                print(f"{r.url}: the index does NOT come signed.")
                print("   a repository with no signature has to say so: {\"url\": ..., \"unsafe\": true} in pack.json.")
                return 1
            if i < 0:
                lk.repos.append(LK.KnownRepo(r.url, "", R.now_iso()[0:10]))
                print(f"   new repository, accepted now (TOFU) and recorded in pack.lock: {r.url}")
            print("   UNSAFE: this repository does not sign its index. Each package's hash is still checked.")
        target = path.join(R.indexes_dir(), r.id + ".json")
        await R.write_bytes(target, bs)
        ix = R.read_index(str(bs), target)
        count = 0
        for name2 in ix.names():
            count += len(ix.versions(name2))
        print(f"{ix.name if len(ix.name) > 0 else r.url}: {len(ix.packages)} package(s), {count} version(s)")
        n += 1
    await LK.write(lk, "pack.lock")
    return 0 if n > 0 else 1


async def cmd_search(targets: List<str>) -> int:
    """`pforge search <term>` — OFFLINE, in the stored index, and BY SYMBOL too.

    Searching by symbol without downloading anything is something no package
    manager does, and here it comes for free: the canonical list is already in the
    index because the compiler already produces it. Every line says where the hit
    came from, which is what lets you understand why a package showed up."""
    if len(targets) == 0:
        print("usage: pforge search <term>")
        return 2
    term = targets[0].lower()
    repos = await project_repos()
    found = 0
    jl: List<str> = []
    for r in repos:
        ix = await stored_index(r)
        for name in ix.names():
            for version in ix.versions(name):
                u = ix.get(name, version)
                lines: List<str> = []
                if term in name.lower():
                    lines.append("[name]        " + (u.description if len(u.description) > 0 else "—"))
                if term in u.description.lower():
                    lines.append("[description] " + u.description)
                mods: List<str> = []
                for mk in u.api:
                    mods.append(mk)
                for mod in sorted(mods):
                    for sb in u.api[mod]:
                        if term in sb.lower():
                            lines.append("[symbol]      " + sb)
                for ln in lines:
                    found += 1
                    if json_out:
                        k = ln.find("]")
                        jl.append('{"name": ' + G.jstr(name) + ', "version": ' + G.jstr(version)
                                  + ', "where": ' + G.jstr(ln[1:k]) + ', "text": ' + G.jstr(ln[k + 1:].strip())
                                  + ', "repo": ' + G.jstr(r.url) + '}')
                    else:
                        print(f"{name} {version}   {ln}")
    if json_out:
        print("[" + ", ".join(jl) + "]")
        return 0 if found > 0 else 1
    if found == 0:
        print("nothing found for '" + targets[0] + "'")
        return 1
    return 0


private def split_at(spec: str) -> List<str>:
    i = spec.find("@")
    if i < 0:
        return [spec, ""]
    return [spec[0:i], spec[i + 1:len(spec)]]


private async def resolve_lock(lk: LK.Lock, wanted: List<str>, swappable: List<str>,
                               unsafe_ok: bool, placed: List<str>) -> int:
    """The resolution, which is the same for `add` and for `lock`: follow the
    queue of requests, look each one up in the stored index, check the hash and
    the signature, keep the tarball in the store and lock the line down.

    It does NOT write the lock or the manifest — the caller decides that. Returns
    0, or the exit code of the problem that stopped it; `placed` gets one line per
    package that went in.

    `swappable` are the names that MAY change version: whatever was asked for on
    the command line. A DEPENDENCY that disagrees with what is already locked is
    still a conflict — there nobody chose, and choosing on our own would be the
    decision v1 does not take."""
    repos = await project_repos()
    vcomp = await compiler_version(query_global())
    if len(vcomp) == 0:
        print("warning: I did not find a `plangc` to ask the version — the toolchain requirement was not checked")
        print("         (`--query <path>`, or put `plangc` on the PATH)")
    queue: List<str> = []
    for pd in wanted:
        queue.append(pd)
    why: Dict<str, str> = {}
    while len(queue) > 0:
        cur = split_at(queue[0])
        queue = queue[1:len(queue)]
        n = cur[0]
        v = cur[1]
        already = lk.find(n)
        if already >= 0 and lk.packages[already].version == v:
            continue
        if already >= 0 and n in swappable:
            # the package ASKED FOR on the command line may change version: that
            # is exactly what `pforge add x@0.2.0` and `pforge up` mean. What
            # remains a conflict is a DEPENDENCY disagreeing with what is already
            # locked — there nobody chose, and choosing on our own would be the
            # decision v1 does not take.
            kept: List<LK.Locked> = []
            for t9 in lk.packages:
                if t9.name != n:
                    kept.append(t9)
            lk.packages = kept
        elif already >= 0:
            who = why[n] if n in why else "asked for on the command line"
            print(f"conflict on {n}: the lock has {lk.packages[already].version} and {who} asks for {v}.")
            print("v1 does not look for a version that serves both — resolve it by hand, raising one of the ends")
            return 1
        found = False
        for r in repos:
            ix = await stored_index(r)
            if not ix.has(n, v):
                continue
            u = ix.get(n, v)
            bs = await R.fetch(r, u.file)
            sha = R.hash_of(bs)
            if sha != u.sha256:
                print(f"the hash does NOT match for {n}@{v}:")
                print(f"   the index says {u.sha256}")
                print(f"   what arrived   {sha}")
                return 1
            # the AUTHOR's signature, which is what stops the repository itself
            # from serving a tarball the author did not make. The HASH was checked
            # above and is checked ALWAYS — "unsafe" means nobody signed, not that
            # the content goes unexamined.
            unsigned = len(u.author) == 0
            if not unsigned:
                sig = await R.signature_of(r, u.file)
                if not R.verify_sig(u.author, bs, sig):
                    print(f"{n}@{v}: the index says this was signed by {u.author[0:16]}…, and the signature does not match.")
                    return 1
            elif not (unsafe_ok or r.is_unsafe):
                print(f"{n}@{v} does not come signed.")
                print("   either `--unsafe` on this command, or the repository declared `unsafe` in pack.json —")
                print("   both forms record `\"unsafe\": true` in the lock, for whoever reviews the PR to see.")
                return 1
            # the TOOLCHAIN REQUIREMENT, checked before spending a second
            # compiling. The message that comes out of here — "package foo
            # requires plangc >= X, yours is Y" — is the best there is for this
            # problem; the alternative is a syntax error halfway through a module
            # that uses something which does not exist yet.
            if len(vcomp) > 0:
                bad = MF.toolchain_ok(u.toolchain, vcomp)
                if len(bad) > 0:
                    print(n + "@" + v + " " + bad)
                    return 1
            await R.write_bytes(path.join(R.tarballs_dir(), sha), bs)
            lk.packages.append(LK.Locked(n, v, sha, r.url, u.file,
                                         unsigned, u.toolchain))
            if lk.known_repo(r.url) < 0:
                lk.repos.append(LK.KnownRepo(r.url, "", R.now_iso()[0:10]))
            placed.append(n + " " + v + "  sha256 " + sha[0:16] + "…")
            for d in u.deps:
                why[d.name] = n + "@" + v
                queue.append(d.name + "@" + d.req)
            found = True
            break
        if not found:
            print(f"I did not find {n}@{v} in any stored index — `pforge update` first?")
            if n in why:
                print(f"   (it is a dependency of {why[n]})")
            return 1
    return 0


private def text_of(b: List<u8>) -> str:
    out = ""
    for x in b:
        out += chr(int(x))
    return out


private def looks_like_tarball(s: str) -> bool:
    return s.endswith(".tar")


private async def tar_bytes(where: str) -> List<u8>:
    """The bytes of a tarball, from a path or from a URL. Nothing else knows
    which of the two it was — which is the point."""
    if where.startswith("http://") or where.startswith("https://"):
        cut = where.rfind("/")
        r = R.repo(where[0:cut], True)
        return await R.fetch(r, where[cut + 1:])
    # `file://` is a URL that is a path, and it is the transport a test can use
    # without a network. Stripping it here is the whole difference.
    if where.startswith("file://"):
        return await R.read_bytes(where[7:])
    return await R.read_bytes(where)


private def manifest_in(bs: List<u8>) -> MF.Manifest:
    """The `pack.json` inside the tarball. A package packs itself with a
    `<name>-<version>/` prefix, so the manifest is the shortest path that ends
    in `pack.json` — anything deeper belongs to a member, not to the package."""
    best = ""
    raw = ""
    for mem in TARM.read(bs):
        if not mem.name.endswith("pack.json"):
            continue
        if len(best) == 0 or len(mem.name) < len(best):
            best = mem.name
            raw = text_of(mem.data)
    if len(best) == 0:
        return MF.empty("")
    return MF.parse(raw, best, False)


async def add_tarball(where: str, author: str, unsafe_ok: bool) -> int:
    """`pforge add ./foo-0.1.0.tar` — the tarball IS the package.

    There is no index to consult and nothing to resolve: the file that arrived
    carries its own `pack.json`, and that says the name, the version, the
    toolchain requirement and the dependencies. What this does is hash what
    arrived, keep it in the store under that hash, and write the line.

    **It is always `unsafe` unless somebody names the AUTHOR.** A `.sig` beside a
    tarball proves nothing on its own — it proves that whoever made the signature
    also made the signature. What a repository adds is a NAME to check it
    against, and a bare file has no repository. So: `--author <hex>` fetches the
    `.sig` and verifies it, and without it the line goes into the lock saying
    `"unsafe": true`, which is what the reviewer of the pull request sees.

    The hash is checked in the sense that matters here: it is COMPUTED from what
    arrived and written down, so the next `pforge install` on another machine
    gets the same bytes or fails. A JAR on a classpath does not have that."""
    bs = await tar_bytes(where)
    if len(bs) == 0:
        print("there is nothing at " + where)
        return 1
    sha = R.hash_of(bs)
    nonlocal m
    try:
        m = manifest_in(bs)
    catch e:
        # a file that is not a tar at all raises out of the reader, and the
        # message that comes out of THERE is about a checksum field. What
        # somebody typing this command needs to know is which file was wrong.
        print(where + ": I could not read this as a package (" + e.message + ")")
        return 1
    if len(m.name) == 0 or len(m.version) == 0:
        print(where + ": there is no pack.json inside this tarball, so it is not a package")
        return 1
    unsigned = True
    if len(author) > 0:
        sigb = await tar_bytes(where + ".sig")
        if len(sigb) == 0:
            print(where + ".sig is not there, and --author says it should be")
            return 1
        sig = text_of(sigb).strip()
        if not R.verify_sig(author, bs, sig):
            print(where + ": the signature does not match the key given to --author")
            return 1
        unsigned = False
    elif not unsafe_ok:
        print(where + " comes with nobody to check it against.")
        print("   `--author <hex>` to verify the `.sig` beside it, or `--unsafe` to take it as it is —")
        print("   the second records `\"unsafe\": true` in the lock, for whoever reviews the PR to see.")
        return 1
    vcomp = await compiler_version(query_global())
    if len(vcomp) > 0:
        bad = MF.toolchain_ok(m.toolchain, vcomp)
        if len(bad) > 0:
            print(m.name + "@" + m.version + " " + bad)
            return 1
    lk = await LK.read("pack.lock")
    kept: List<LK.Locked> = []
    for t in lk.packages:
        if t.name != m.name:
            kept.append(t)
    lk.packages = kept
    await R.write_bytes(path.join(R.tarballs_dir(), sha), bs)
    lk.packages.append(LK.Locked(m.name, m.version, sha, where, "", unsigned, m.toolchain))
    await LK.write(lk, "pack.lock")
    await MF.write_dep("pack.json", m.name, m.version)
    print(m.name + " " + m.version + "  sha256 " + sha[0:16] + "…" +
          ("  (unsafe: nobody signed for it)" if unsigned else "  (signed)"))
    # a dependency of the tarball is NOT followed: there is no index behind a
    # bare file to follow it into. Saying so beats an "I did not find" later.
    if len(m.deps) > 0:
        print("   it asks for " + str(len(m.deps)) + " dependency(ies) of its own; add them yourself —")
        print("   a bare tarball has no index behind it to follow them into")
    print("   `pforge install` to materialize it")
    return 0


async def cmd_add(targets: List<str>, unsafe_ok: bool) -> int:
    """`pforge add <name>@<version>` — writes to the manifest and to the lock.

    `add` and `build` are different commands ON PURPOSE: one touches the manifest
    and the lock, the other compiles. The commit's diff stays readable — two
    lines, one in each file — instead of "the build changed the world and now
    there are twenty new files".

    The dependencies of what you ask for come ALONG, and this is not resolving
    versions: the index carries the EXACT version of each one, and what happens is
    following it. When two demands disagree, the result is a message — not a
    search."""
    if len(targets) == 0:
        print("usage: pforge add <name>@<version> [--unsafe]")
        print("       pforge add ./foo-0.1.0.tar [--author <hex>] [--unsafe]")
        print("       pforge add https://somewhere/foo-0.1.0.tar [--author <hex>] [--unsafe]")
        return 2
    if looks_like_tarball(targets[0]):
        author = ""
        for i in range(1, len(targets)):
            if targets[i] == "--author" and i + 1 < len(targets):
                author = targets[i + 1]
        return await add_tarball(targets[0], author, unsafe_ok)
    asked = split_at(targets[0])
    name = asked[0]
    version = asked[1]
    if len(version) == 0:
        print("v1 has no resolver: the version is EXACT — `pforge add " + name + "@0.1.0`")
        return 2
    lk = await LK.read("pack.lock")
    placed: List<str> = []
    rc = await resolve_lock(lk, [name + "@" + version], [name], unsafe_ok, placed)
    if rc != 0:
        return rc
    await LK.write(lk, "pack.lock")
    await MF.write_dep("pack.json", name, version)
    if json_out:
        jadd: List<str> = []
        for t2 in lk.packages:
            jadd.append('{"name": ' + G.jstr(t2.name) + ', "version": ' + G.jstr(t2.version)
                        + ', "sha256": ' + G.jstr(t2.sha256) + ', "repo": ' + G.jstr(t2.repo)
                        + ', "unsafe": ' + ("true" if t2.is_unsafe else "false") + '}')
        print('{"asked": ' + G.jstr(name + "@" + version) + ', "locked": [' + ", ".join(jadd) + ']}')
        return 0
    for line in placed:
        print(line)
    if len(placed) > 1:
        print(f"   {len(placed) - 1} came in as dependencies; `pforge why <name>` says whose")
    print("   `pforge install` to materialize them")
    return 0


async def cmd_up(targets: List<str>, unsafe_ok: bool) -> int:
    """`pforge up [<name>]` — raises to the highest version the index knows.

    With no resolver there is no "the version that serves everyone": there is the
    highest one that exists, and the decision to take it belongs to whoever writes
    the command. That is why `up` is a command and not a side effect of `install`
    — raising a version is a choice, and a choice that happens on its own is a
    choice nobody reviewed.

    It touches the manifest and the lock, like `add`, and builds nothing."""
    if not path.isfile("pack.json"):
        print("there is no pack.json here")
        return 1
    m = await MF.read("pack.json")
    if not m.is_workspace or len(m.deps) == 0:
        print("this project's pack.json asks for no dependencies")
        return 1
    repos = await project_repos()
    which: List<str> = []
    for d in m.deps:
        if len(targets) == 0 or d.name in targets:
            which.append(d.name)
    if len(which) == 0:
        print("'" + targets[0] + "' is not a dependency of this project")
        return 1
    for name in which:
        cur = ""
        for d2 in m.deps:
            if d2.name == name:
                cur = d2.req
        best = ""
        for r in repos:
            ix = await stored_index(r)
            for v in ix.versions(name):
                if len(best) == 0 or MF.version_greater(v, best):
                    best = v
        if len(best) == 0:
            print(name + ": it is in no stored index — `pforge update` first?")
            continue
        if best == cur:
            print(name + " " + cur + " is already the highest the index has")
            continue
        print(name + ": " + cur + " -> " + best)
        rc = await cmd_add([name + "@" + best], unsafe_ok)
        if rc != 0:
            return rc
    return 0


async def cmd_lock(frozen: bool, unsafe_ok: bool) -> int:
    """`pforge lock` — brings `pack.lock` in line with `pack.json`, and nothing
    else.

    It is the command that was missing between `add` (which changes what you ask
    for) and `install` (which materializes what is already decided): here nothing
    new is asked for and no tree is unpacked — the lock is remade from the
    manifest.

    It **starts over** instead of patching, and that is what makes it exact: the
    lock becomes the closure of what `pack.json` asks for, and what nobody pulls
    in any more leaves on its own. What survives is the repositories section — the
    keys accepted by TOFU are not a result of the resolution, they are the trust
    this project already reviewed, and starting that over would be accepting again
    what was accepted once.

    None of this touches the network: each version's tarball is already in the
    store, with its hash checked, and the index is what the last `pforge update`
    kept.

    With `--frozen` it does not write: it says what would change and exits with 1,
    which is what a CI wants — "the lock that is committed is not what this
    manifest asks for"."""
    if not path.isfile("pack.json"):
        print("there is no pack.json here")
        return 1
    m = await MF.read("pack.json")
    old = await LK.read("pack.lock")
    diffs = await lock_vs_manifest(old)
    if frozen:
        if len(diffs) == 0:
            if json_out:
                print('{"changed": false}')
            else:
                print("pack.lock matches pack.json")
            return 0
        print("the lock does not match pack.json, and `--frozen` will not let me fix it:")
        for d0 in diffs:
            print("   " + d0)
        print("run `pforge lock` and commit pack.lock")
        return 1
    fresh = await LK.read("pack.lock")
    fresh.packages = []
    wanted: List<str> = []
    swappable: List<str> = []
    for d in m.deps:
        wanted.append(d.name + "@" + d.req)
        swappable.append(d.name)
    placed: List<str> = []
    rc = await resolve_lock(fresh, wanted, swappable, unsafe_ok, placed)
    if rc != 0:
        return rc
    if len(fresh.packages) == 0 and not path.isfile("pack.lock"):
        # a project with no outside dependency does not need a lock, and creating
        # an empty file just so the command did something is noise in a directory
        # somebody is going to commit
        if json_out:
            print('{"changed": false, "locked": []}')
        else:
            print("this project asks for no dependencies: there is nothing to lock")
        return 0
    await LK.write(fresh, "pack.lock")
    lines: List<str> = []
    for t in fresh.packages:
        i = old.find(t.name)
        if i < 0:
            lines.append("+ " + t.name + " " + t.version)
        elif old.packages[i].version != t.version:
            lines.append("~ " + t.name + " " + old.packages[i].version + " -> " + t.version)
        elif old.packages[i].sha256 != t.sha256:
            lines.append("~ " + t.name + " " + t.version + " (different content)")
    for t2 in old.packages:
        if fresh.find(t2.name) < 0:
            lines.append("- " + t2.name + " " + t2.version + " (nobody asks for it)")
    if json_out:
        jl: List<str> = []
        for t3 in fresh.packages:
            jl.append('{"name": ' + G.jstr(t3.name) + ', "version": ' + G.jstr(t3.version)
                      + ', "sha256": ' + G.jstr(t3.sha256) + '}')
        print('{"changed": ' + ("true" if len(lines) > 0 else "false")
              + ', "locked": [' + ", ".join(jl) + ']}')
        return 0
    if len(lines) == 0:
        print("pack.lock already matched pack.json (" + str(len(fresh.packages)) + " package(s))")
        return 0
    for l2 in lines:
        print(l2)
    print("   `pforge install` to materialize them")
    return 0


private async def lock_vs_manifest(lk: LK.Lock) -> List<str>:
    """What `pack.json` asks for and what `pack.lock` has — and the difference
    between the two, said in lines.

    A lock that does not match the manifest is the source of "it works on my
    machine": somebody added a dependency, forgot to commit the lock, and the
    other person's build installs something else. Here that is a LIST, which
    `install` prints and `--frozen` refuses."""
    out: List<str> = []
    if not path.isfile("pack.json"):
        return out
    m = await MF.read("pack.json")
    if not m.is_workspace:
        return out
    for d in m.deps:
        i = lk.find(d.name)
        if i < 0:
            out.append("+ " + d.name + "@" + d.req + " (the manifest asks for it, the lock does not have it)")
        elif lk.packages[i].version != d.req:
            out.append("~ " + d.name + ": the lock has " + lk.packages[i].version + ", the manifest asks for " + d.req)
    return out


async def cmd_install(frozen: bool) -> int:
    """`pforge install` — materializes what the lock says.

    What it does NOT do is decide: the versions are already decided, in the lock.
    It downloads what is missing, checks the hash ALWAYS, and unpacks the tree into
    `build/pkg/<name>-<version>-<hash>/`. The hash in the name is what makes "the
    same version with different content" impossible to confuse."""
    lk = await LK.read("pack.lock")
    # the lock and the manifest have to tell the same story. An `install` that
    # silently installed the old lock is the source of "it works on my machine":
    # somebody added a dependency and did not commit the lock.
    diffs = await lock_vs_manifest(lk)
    if len(diffs) > 0:
        if frozen:
            print("the lock does not match pack.json, and `--frozen` will not let me fix it:")
            for dd in diffs:
                print("   " + dd)
            print("run `pforge add <name>@<version>` and commit pack.lock")
            return 1
        print("the lock does not match pack.json:")
        for dd2 in diffs:
            print("   " + dd2)
        print("   (`pforge add <name>@<version>` fixes it; `--frozen` refuses instead of warning)")
    if len(lk.packages) == 0:
        # here too: whoever asked for JSON gets JSON. A sentence in the middle of a
        # stream of objects is what makes a consumer blow up far from where the
        # problem is.
        if json_out:
            print("[]")
            return 0
        print("the lock has no packages: `pforge add <name>@<version>` first")
        return 0
    repos = await project_repos()
    vcomp = await compiler_version(query_global())
    if len(vcomp) == 0 and not json_out:
        print("warning: I did not find a `plangc` to ask the version — the toolchain requirement was not checked")
    n = 0
    ji: List<str> = []
    for t in lk.packages:
        if len(vcomp) > 0:
            bad = MF.toolchain_ok(t.toolchain, vcomp)
            if len(bad) > 0:
                print(t.name + "@" + t.version + " " + bad)
                return 1
        dest = R.package_dir(t.name, t.version, t.sha256)
        if path.isdir(path.join(dest, t.name)):
            continue
        pak = path.join(R.tarballs_dir(), t.sha256)
        bs: List<u8> = []
        if path.isfile(pak):
            bs = await R.read_bytes(pak)
        else:
            found = False
            for r in repos:
                if r.url != t.repo:
                    continue
                bs = await R.fetch(r, t.file)
                found = True
            if not found:
                print(f"{t.name}: the lock says it came from {t.repo}, and that repository is not in pack.json")
                return 1
            await R.write_bytes(pak, bs)
        sha = R.hash_of(bs)
        if sha != t.sha256:
            print(f"the hash does NOT match for {t.name}@{t.version}: the lock says {t.sha256}, what is here says {sha}")
            return 1
        count = await R.extract_package(bs, dest, t.name)
        if json_out:
            ji.append('{"name": ' + G.jstr(t.name) + ', "version": ' + G.jstr(t.version)
                      + ', "dir": ' + G.jstr(dest) + ', "files": ' + str(count)
                      + ', "unsafe": ' + ("true" if t.is_unsafe else "false") + '}')
        else:
            print(f"{t.name} {t.version}  {count} file(s) in {dest}")
            if t.is_unsafe:
                print("   (unsafe: no signature — the hash matched)")
        n += 1
    if json_out:
        print("[" + ", ".join(ji) + "]")
        return 0
    if n == 0:
        print("nothing to install: everything the lock says is already unpacked")
    return 0


private def version_parts(v: str) -> List<int>:
    ps = v.split(".")
    out: List<int> = []
    for i in range(3):
        out.append(int(ps[i]) if i < len(ps) else 0)
    return out


private def psc_outside_test(dir: str, rel: str, found: List<str>):
    """A `.psc` inside a package declared `p`, not counting what is in `test/`.

    The test exception is not convenience: a package in P may very well be
    exercised from pscript — that is how `sha2` proves it crosses the 45.5
    boundary — and the test is not part of the interface anybody imports. What
    cannot be is a MODULE of the package being pscript when the manifest says it
    is P: whoever imports it as P gets an error that does not talk about the
    problem."""
    for name in sorted(os.listdir(dir)):
        full = path.join(dir, name)
        rel2 = name if len(rel) == 0 else rel + "/" + name
        if path.isdir(full):
            if name == "test" and len(rel) == 0:
                continue
            psc_outside_test(full, rel2, found)
        elif name.endswith(".psc"):
            found.append(rel2)


private async def publish_refusals(ix: R.Index, m: MF.Manifest, dir: str,
                                   u: R.Release, warn: List<str>) -> List<str>:
    """The three cases where publishing would mean publishing something that does
    not serve.

    None of them needs a new mechanism — that is the reason they exist: the index
    already carries the dependencies, the manifest already says the language, and
    the canonical API list is already computed to go into the index. Checking is
    comparing.

      1. **a dependency the destination does not resolve.** You publish a tarball
         that only builds on the author's machine, where the dependency is a
         workspace member. Whoever installs it later gets "I did not find
         foo@0.1.0" — far from here, and without knowing it was decided here.

      2. **a `.psc` in a package declared `p`** (outside `test/`).

      3. **the version went up and the interface does not match what the bump
         promises.** A `patch` says "nothing changed in the interface" and a
         `minor` says "I only added" — both are verifiable from the index, and
         that is why the canonical API list is there."""
    bad: List<str> = []
    for d in m.deps:
        if ix.has(d.name, d.req):
            continue
        bad.append("the dependency " + d.name + "@" + d.req
                   + " is not in this repository — publish it first")
    if m.lang == "p":
        found: List<str> = []
        psc_outside_test(dir, "", found)
        for a in found:
            bad.append(a + " is pscript, and the manifest declares `\"lang\": \"p\"`")
    prev = ""
    for v in ix.versions(m.name):
        if len(prev) == 0 or MF.version_greater(v, prev):
            prev = v
    if len(prev) == 0:
        return bad
    va = version_parts(prev)
    vn = version_parts(m.version)
    if vn[0] != va[0]:
        return bad                       # major: it may change whatever it likes
    prev_rel = ix.get(m.name, prev)
    if vn[1] == va[1]:
        # patch: the interface has to be the SAME, module by module
        for mod in sorted_keys(u.api_hash):
            if mod not in prev_rel.api_hash:
                bad.append("the module " + mod + " is new, and " + m.version
                           + " only bumps the `patch` of " + prev)
            elif prev_rel.api_hash[mod] != u.api_hash[mod]:
                bad.append("the interface of " + mod + " changed, and " + m.version
                           + " only bumps the `patch` of " + prev)
        for mod2 in sorted_keys(prev_rel.api_hash):
            if mod2 not in u.api_hash:
                bad.append("the module " + mod2 + " left, and " + m.version
                           + " only bumps the `patch` of " + prev)
        return bad
    # minor: it may ADD, and nothing else — EXCEPT while the major is 0.
    #
    # Semver says it out loud (clause 4): "anything MAY change at any time" while
    # the major is zero, and by convention the slot that carries the break is the
    # minor. Cargo treats `0.x` exactly that way, and refusing it here would mean
    # a library cannot correct its own interface before its first stable release
    # — which is what the pre-1.0 period is FOR.
    #
    # It warns instead of going quiet: the exception is real, and an exception
    # visible on every publication is one somebody can argue with. Hidden in the
    # rule, it would be a rule nobody knows they are relying on.
    zero_major = va[0] == 0
    prev_mods: List<str> = []
    for k3 in prev_rel.api:
        prev_mods.append(k3)
    for mod3 in sorted(prev_mods):
        if mod3 not in u.api:
            gone = "the module " + mod3 + " left, and " + m.version + " bumps the `minor` of " + prev
            if zero_major:
                warn.append(gone + " — allowed because the major is 0, where a minor MAY break")
            else:
                bad.append(gone + " (a minor adds, it does not take away)")
            continue
        now_syms: List<str> = u.api[mod3]
        for decl in prev_rel.api[mod3]:
            if decl not in now_syms:
                left = "`" + decl + "` left " + mod3 + ", and " + m.version + " bumps the `minor` of " + prev
                if zero_major:
                    warn.append(left + " — allowed because the major is 0, where a minor MAY break")
                else:
                    bad.append(left + " (a minor adds, it does not take away)")
    return bad


private def sorted_keys(d: Dict<str, str>) -> List<str>:
    ks: List<str> = []
    for k in d:
        ks.append(k)
    return sorted(ks)


async def cmd_publish(targets: List<str>, to_dir: str, key_file: str, query: str) -> int:
    """`pforge publish <package> --to <dir>` — the `.tar`, the hash and the index
    entry, in the author's local repository.

    It SENDS NOTHING, and that is a direct consequence of a repository being a
    format: sending is `rsync`, `scp` or `git push`, and none of those is
    something a package manager has to reimplement badly.

    What it checks before writing:

      * the manifest is valid (name, version, fields);
      * the version DOES NOT EXIST YET in the index — a published version is
        immutable, and that is the rule that makes a lock with a hash worth
        anything;
      * the interface matches what it is going to declare (the compiler gives it).

    What it does NOT do is run the tests: publishing and testing are different
    decisions, and joining them would make `publish` fail for reasons that are not
    about publishing."""
    if len(targets) == 0:
        print("usage: pforge publish <package> [--to <dir>]")
        return 2
    if len(to_dir) == 0:
        print("pforge publish needs a destination repository: --to <dir>")
        return 2
    target = targets[0]
    dir = ""
    for r in await BP.workspace_roots("pack.json"):
        cand = path.join(r, target)
        if path.isfile(path.join(cand, "pack.json")):
            dir = cand
            break
    if len(dir) == 0 and path.isfile(path.join(target, "pack.json")):
        dir = target
    if len(dir) == 0:
        print("I did not find the package '" + target + "' (neither in the workspace nor as a directory)")
        return 1
    m = await MF.read(path.join(dir, "pack.json"))
    if m.is_workspace:
        print(dir + "/pack.json is a workspace, not a package")
        return 1
    if len(m.name) == 0 or len(m.version) == 0:
        print(dir + "/pack.json: a published package needs `name` and `version`")
        return 1

    ixp = path.join(to_dir, "index.json")
    ix = R.new_index(path.basename(to_dir))
    if path.isfile(ixp):
        f = await open(ixp, "r")
        ix = R.read_index(await f.text(), ixp)
        await f.close()
    if ix.has(m.name, m.version):
        print(f"{m.name}@{m.version} is already published in {to_dir} — a published version is IMMUTABLE.")
        print("bump the version in pack.json, or delete the index entry if it never left here")
        return 1

    u = R.empty_release()
    u.name = m.name
    u.version = m.version
    u.author = ""
    u.lang = m.lang
    u.root = m.root
    u.deps = m.deps
    u.toolchain = m.toolchain
    u.description = m.description
    await package_api(dir, m, query, u.api, u.api_hash)
    # the REFUSAL happens before a byte is written. A repository with one tarball
    # too many and no index entry is a repository nobody knows how to fix.
    warn: List<str> = []
    bad = await publish_refusals(ix, m, dir, u, warn)
    if len(bad) > 0:
        print(dir + "/pack.json: error: this cannot be published as it is:")
        for mm in bad:
            print("   " + mm)
        return 1
    # what the `0.x` exception let through. It is printed on EVERY publication
    # that uses it, because an exception nobody sees is a rule nobody knows they
    # are relying on.
    for wm in warn:
        print(dir + "/pack.json: warning: " + wm)
    bs = await R.pack(dir, m.name + "-" + m.version)
    sha = R.hash_of(bs)
    rel = "pkg/" + m.name + "/" + m.name + "-" + m.version + ".tar"
    await R.write_bytes(path.join(to_dir, rel), bs)
    u.file = rel
    u.size = len(bs)
    u.sha256 = sha
    if m.name not in ix.packages:
        empty: Dict<str, R.Release> = {}
        ix.packages[m.name] = empty
    signed = False
    if len(key_file) > 0:
        # the AUTHOR's signature goes next to the tarball, and the key that made
        # it goes into the index: whoever verifies does not have to fetch it from
        # anywhere
        seed = await R.read_seed(key_file)
        u.author = R.public_key(seed)
        await R.write_bytes(path.join(to_dir, rel + ".sig"),
                            R.bytes_of_text(R.sign(seed, bs) + "\n"))
        signed = True
    ix.packages[m.name][m.version] = u
    ix.updated = R.now_iso()
    index_text = R.write_index(ix)
    await R.write_bytes(ixp, R.bytes_of_text(index_text))
    if len(key_file) > 0:
        # ... and the REPOSITORY's covers the whole index, which is what stops an
        # old list from being served as if it were today's
        seed2 = await R.read_seed(key_file)
        await R.write_bytes(ixp + ".sig",
                            R.bytes_of_text(R.sign(seed2, R.bytes_of_text(index_text)) + "\n"))

    if json_out:
        print('{"name": ' + G.jstr(m.name) + ', "version": ' + G.jstr(m.version)
              + ', "file": ' + G.jstr(path.join(to_dir, rel)) + ', "sha256": ' + G.jstr(sha)
              + ', "size": ' + str(len(bs)) + '}')
        return 0
    print(f"{m.name} {m.version} -> {path.join(to_dir, rel)}")
    print(f"   sha256 {sha}")
    print(f"   {len(bs)} bytes, {len(u.api)} interface module(s) in the index")
    if signed:
        print("   signed by " + u.author[0:16] + "… (the tarball and the index)")
    else:
        print("   NO SIGNATURE: this only serves a repository declared `unsafe`.")
        print("   `pforge keygen <file>` and then `--key <file>` to sign.")
    return 0


private def esc_html(t: str) -> str:
    out = ""
    for c in t:
        if c == "&":
            out += "&amp;"
        elif c == "<":
            out += "&lt;"
        elif c == ">":
            out += "&gt;"
        elif c == "\"":
            out += "&quot;"
        else:
            out += c
    return out


const CSS: str = """
:root { --fg:#1b1b1b; --bg:#fdfdfc; --dim:#6a6a68; --acc:#7a3b12; --line:#e3e0da;
        --code:#f4f2ee; }
@media (prefers-color-scheme: dark) {
  :root { --fg:#e6e4df; --bg:#1a1a19; --dim:#9a9894; --acc:#e0a06a; --line:#33322f;
          --code:#232322; }
}
* { box-sizing: border-box; }
body { margin:0; padding:2rem 1.25rem 4rem; background:var(--bg); color:var(--fg);
       font: 15px/1.65 -apple-system, "Segoe UI", Roboto, "Helvetica Neue", sans-serif;
       max-width: 52rem; margin-inline: auto; }
a { color: var(--acc); text-decoration: none; }
a:hover { text-decoration: underline; }
h1 { font-size: 1.45rem; margin: 0 0 .2rem; }
h2 { font-size: 1.05rem; margin: 2rem 0 .5rem; padding-bottom:.3rem;
     border-bottom: 1px solid var(--line); }
.sub { color: var(--dim); margin: 0 0 1.6rem; }
.hash { font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
        font-size: .8rem; color: var(--dim); }
pre, code { font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace; }
.decl { background: var(--code); border-left: 3px solid var(--acc);
        padding: .45rem .7rem; margin: 1.1rem 0 .35rem; overflow-x: auto;
        white-space: pre; font-size: .88rem; }
.doc { margin: 0 0 .2rem .75rem; white-space: pre-wrap; color: var(--fg); }
ul.mods { list-style: none; padding: 0; }
ul.mods li { padding: .25rem 0; border-bottom: 1px solid var(--line); }
ul.mods li span { color: var(--dim); float: right; font-size: .85rem; }
footer { margin-top: 3rem; color: var(--dim); font-size: .82rem;
         border-top: 1px solid var(--line); padding-top: .8rem; }
"""


private def page(title: str, body: str, up_link: str) -> str:
    """A page's frame. An INLINE stylesheet, and not a file next to it: a
    documentation folder you copy somewhere else and that still looks right is
    worth more than one that saves two kilobytes."""
    return ("<!doctype html>\n<html lang=\"en\">\n<meta charset=\"utf-8\">\n"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
            + "<title>" + esc_html(title) + "</title>\n<style>" + CSS + "</style>\n"
            + body
            + "\n<footer>generated by <code>pforge doc --html</code>"
            + (" · <a href=\"" + up_link + "\">index</a>" if len(up_link) > 0 else "")
            + "</footer>\n</html>\n")


private async def api_argv(file: str, query: str) -> List<str>:
    """`--api` with the PACKAGE ROOTS, which is what makes the question work on a
    module that imports `<pkg/mod.ph>`.

    Without them the compiler answers "I did not find `<stl/cstr.ph>`" and half
    the workspace's documentation is left out — in silence, because a module that
    does not answer looks like a module with no interface."""
    argv: List<str> = [query, "--api"]
    roots = await BP.workspace_roots("pack.json")
    for ri in R.installed_roots():
        roots.append(ri)
    for r in roots:
        argv.append("--pkg-path")
        argv.append(r)
    argv.append(file)
    return argv


private async def api_of(file: str, query: str) -> List<A.Api>:
    r = await os.run(await api_argv(file, query))
    if r.status() != 0:
        return []
    return A.parse(r.output())


private def file_name_for(rel: str) -> str:
    out = ""
    for c in rel:
        out += "-" if (c == "/" or c == "\\") else c
    return out + ".html"


async def cmd_doc_html(targets: List<str>, dest: str, query: str) -> int:
    """`pforge doc --html <folder>` — the same content as the terminal, as a site.

    The source is the SAME answer 5 from the compiler that `pforge doc` already
    reads; what changes is where it gets written. That is why this comes out cheap
    and cannot diverge: there is no second reader of the language, there is a
    second renderer of the same canonical list.

    With no target, it documents the whole workspace — every package and every one
    of its modules. The result is a folder of static files: no service, no
    network, no JavaScript. It opens with two clicks and copies anywhere."""
    mods: List<str> = []
    label: Dict<str, str> = {}
    if len(targets) > 0:
        for a in targets:
            if path.isfile(a):
                mods.append(a)
                label[a] = a
                continue
            root = await package_module(a)
            if len(root) > 0:
                mods.append(root)
                label[root] = a
                continue
            found = False
            for r0 in await BP.workspace_roots("pack.json"):
                d0 = path.join(r0, a)
                if not path.isfile(path.join(d0, "pack.json")):
                    continue
                found = True
                for nm in sorted(os.listdir(d0)):
                    if nm.endswith(".ph") or nm.endswith(".psc"):
                        mods.append(path.join(d0, nm))
                        label[path.join(d0, nm)] = a + "/" + nm
            if not found:
                print("I did not find '" + a + "': neither a file nor a workspace package")
                return 1
    else:
        for member in await BP.workspace_members("pack.json"):
            man = path.join(member, "pack.json")
            if not path.isfile(man):
                continue
            m = await MF.read(man)
            if len(m.root) > 0:
                mods.append(path.join(member, m.root))
                label[path.join(member, m.root)] = m.name
                continue
            for nm2 in sorted(os.listdir(member)):
                if nm2.endswith(".ph") or nm2.endswith(".psc"):
                    mods.append(path.join(member, nm2))
                    label[path.join(member, nm2)] = m.name + "/" + nm2
    if len(mods) == 0:
        print("there is no module to document")
        return 1
    if not path.isdir(dest):
        os.makedirs(dest)
    lines: List<str> = []
    written = 0
    symbols = 0
    for md in mods:
        apis = await api_of(md, query)
        if len(apis) == 0:
            print("warning: the compiler returned no interface for " + md)
            continue
        api = apis[0]
        lab = label[md] if md in label else md
        file = file_name_for(lab)
        body = "<h1>" + esc_html(lab) + "</h1>\n<p class=\"sub\">" + esc_html(api.path)
        body += " · <span class=\"hash\">" + esc_html(api.hash) + "</span></p>\n"
        if len(api.doc) > 0:
            body += "<p class=\"doc\">" + esc_html(api.doc) + "</p>\n"
        n = 0
        for sb in api.symbols:
            if len(sb.decl) == 0:
                continue
            n += 1
            body += "<div class=\"decl\">" + esc_html(sb.decl) + "</div>\n"
            if len(sb.doc) > 0:
                body += "<p class=\"doc\">" + esc_html(sb.doc) + "</p>\n"
        if n == 0:
            body += "<p class=\"sub\">this module declares nothing public</p>\n"
        await R.write_bytes(path.join(dest, file),
                            R.bytes_of_text(page(lab, body, "index.html")))
        lines.append("<li><a href=\"" + esc_html(file) + "\">" + esc_html(lab)
                     + "</a> <span>" + str(n) + " symbol(s)</span></li>")
        written += 1
        symbols += n
    idx = "<h1>documentation</h1>\n<p class=\"sub\">" + str(written) + " module(s), "
    idx += str(symbols) + " symbol(s)</p>\n<ul class=\"mods\">\n"
    idx += "\n".join(lines) + "\n</ul>\n"
    await R.write_bytes(path.join(dest, "index.html"),
                        R.bytes_of_text(page("documentation", idx, "")))
    if json_out:
        print('{"dir": ' + G.jstr(dest) + ', "modules": ' + str(written)
              + ', "symbols": ' + str(symbols) + '}')
        return 0
    print(str(written) + " module(s), " + str(symbols) + " symbol(s) -> "
          + path.join(dest, "index.html"))
    return 0


async def cmd_doc(targets: List<str>, query: str) -> int:
    """`pforge doc` — the documentation in the TERMINAL, of what already exists.

    Nothing is built and nothing is generated: the source is the compiler's answer
    5 (`--api`), which already carries the canonical interface and the docstrings.
    It is what `go doc` got right — offline, no site, no service — and here it
    comes for free because the format was already there."""
    if len(targets) == 0:
        print("usage: pforge doc <file|package> [symbol]")
        return 2
    target = targets[0]
    if not path.isfile(target):
        p2 = await package_module(target)
        if len(p2) == 0:
            # it may be a package with NO root (a set of modules), and then what
            # gets shown is the list of them
            if len(targets) == 1 and await list_package(target) == 0:
                return 0
            print("I did not find '" + target + "': neither a file nor a workspace package")
            return 1
        target = p2
    r = await os.run(await api_argv(target, query))
    if r.status() != 0:
        print(r.output().rstrip())
        return 1
    mods = A.parse(r.output())
    if len(mods) == 0:
        print("the compiler returned no interface at all for '" + target + "'")
        return 1
    m = mods[0]
    if len(targets) > 1:
        i = m.find(targets[1])
        if i < 0:
            print("'" + targets[1] + "' is not in the interface of " + m.path)
            return 1
        s = m.symbols[i]
        if json_out:
            print('{"path": ' + G.jstr(m.path) + ', "name": ' + G.jstr(s.name)
                  + ', "decl": ' + G.jstr(s.decl) + ', "doc": ' + G.jstr(s.doc) + '}')
            return 0
        if len(s.decl) > 0:
            print(s.decl)
        else:
            print(s.name)
        if len(s.doc) > 0:
            print(indent(s.doc))
        return 0
    if json_out:
        syms: List<str> = []
        for s3 in m.symbols:
            syms.append('{"decl": ' + G.jstr(s3.decl) + ', "name": ' + G.jstr(s3.name)
                        + ', "doc": ' + G.jstr(s3.doc) + '}')
        print('{"path": ' + G.jstr(m.path) + ', "hash": ' + G.jstr(m.hash)
              + ', "doc": ' + G.jstr(m.doc) + ', "symbols": [' + ", ".join(syms) + ']}')
        return 0
    print("== " + m.path + "  [" + m.hash + "]")
    if len(m.doc) > 0:
        print(indent(m.doc))
        print("")
    for s2 in m.symbols:
        if len(s2.decl) == 0:
            continue
        print(s2.decl)
        if len(s2.doc) > 0:
            print(indent(s2.doc))
    return 0

async def cmd_ninja(targets: List<str>, query: str) -> int:
    """The ninja export (see `lib_ninja.psc`): the bootstrap on a machine that
    does not have `pforge` yet, and `compile_commands.json` for free (`ninja -t
    compdb`). With no argument it goes to standard output, so it can be checked
    before being written."""
    g = await BP.assemble(query)
    txt = N.emit(g)
    if len(targets) == 0 or targets[0] == "-":
        print(txt.rstrip())
        return 0
    f = await open(targets[0], "w")
    await f.write(txt)
    await f.close()
    print("written:", targets[0], "(" + str(len(g.edges)), "edges)")
    return 0

async def cmd_clean() -> int:
    """The broom: it deletes what the build PRODUCED and keeps what it
    DOWNLOADED.

    The line is the origin: `build/pkg` (the indexes, the tarballs and the
    unpacked trees) came from outside, and downloading it again costs network and
    time for nothing — and no risk at all, because `pack.lock` has the hash of
    everything. To delete that too there is `make clean-all`, which is what you do
    to prove a clean checkout builds."""
    n = 0
    if path.isdir("build"):
        for name in sorted(os.listdir("build")):
            if name == "pkg":
                continue          # what came from outside stays; see the docstring
            d = path.join("build", name)
            if path.isdir(d):
                n += rmtree(d)
            else:
                os.remove(d)
                n += 1
    print("deleted:", n, "file(s)")
    return 0

def rmtree(d: str) -> int:
    n = 0
    for name in os.listdir(d):
        p = path.join(d, name)
        if path.isdir(p):
            n += rmtree(p)
        else:
            os.remove(p)
            n += 1
    os.rmdir(d)
    return n

def usage():
    print("usage: pforge <build|test|verify|run|doc|tree|why|explain|graph|ninja|clean|help> [target...] [-j N] [-k N] [-n] [--query <plangc>]")
    print("     --build-dir <dir>                    where a LOOSE script's build goes")
    print("                                          (default: next to the script)")
    print("     pforge check                          the invariants the build does not check")
    print("     pforge dev [target]                   builds whenever something changes, until Ctrl-C")
    print("     pforge keygen <file>                  a new key (private + .pub)")
    print("     pforge publish <package> --to <dir> [--key <file>]")
    print("                                          the .tar, the hash, the index and both signatures")
    print("     pforge update                         downloads the project's repository indexes")
    print("     pforge search <term>                  searches name, description and SYMBOL, offline")
    print("     pforge add <name>@<version> [--unsafe] writes to the manifest and the lock")
    print("     pforge up [<name>]                    raises to the highest version the index has")
    print("     pforge doc --html <folder> [target...] the same content as a static site")
    print("     pforge build --repro [target]         builds twice, from scratch, and compares byte for byte")
    print("     pforge lock [--frozen]                remakes pack.lock from pack.json, without building")
    print("     pforge install [--frozen]             materializes what the lock says (--frozen: CI, refuses if it is stale)")

async def main() -> int:
    args = sys.argv[1:]
    if len(args) == 0:
        usage()
        return 2
    global json_out
    global current_query
    cmd = args[0]
    targets: List<str> = []
    jobs = os.nproc()
    keep = 1
    dry = False
    verbose = False
    to_dir = ""
    key_file = ""
    unsafe_ok = False
    frozen = False
    repro = False
    html = ""
    builddir = ""
    query = ""
    # the compiler that answers the protocol. The default is not a fixed name: it
    # is the best one in the tree, from the most advanced to the least. A default
    # pointing at a path the build no longer produces is a trap that only shows up
    # much later, with a message that does not talk about the problem.
    for cand in ["build/bin/plangc_s2", "build/bin/plangc_s1", "build/bin/plangc_seed", "./plangc"]:
        if path.isfile(cand):
            query = cand
            break
    if query == "":
        query = "build/bin/plangc_seed"
    i = 1
    # everything after `--` belongs to the PROGRAM, not to us. Without this, `pforge
    # run p --version` would swallow the `--version` as an option of pforge's — and
    # a `run` that cannot pass arguments is good for nothing.
    rest: List<str> = []
    j = 1
    while j < len(args):
        if args[j] == "--":
            k = j + 1
            while k < len(args):
                rest.append(args[k])
                k += 1
            trimmed: List<str> = []
            m = 0
            while m < j:
                trimmed.append(args[m])
                m += 1
            args = trimmed
            break
        j += 1
    while i < len(args):
        a = args[i]
        if a == "-j" and i + 1 < len(args):
            i += 1
            jobs = int(args[i])
        elif a == "-k" and i + 1 < len(args):
            i += 1
            keep = int(args[i])
        elif a == "-n" or a == "--dry-run":
            dry = True
        elif a == "-v":
            verbose = True
        elif a == "--json":
            json_out = True
        elif a == "--query" and i + 1 < len(args):
            i += 1
            query = args[i]
        elif a == "--unsafe":
            unsafe_ok = True
        elif a == "--frozen":
            frozen = True
        elif a == "--repro":
            repro = True
        elif a == "--html" and i + 1 < len(args):
            i += 1
            html = args[i]
        elif a == "--build-dir" and i + 1 < len(args):
            i += 1
            builddir = args[i]
        elif a == "--to" and i + 1 < len(args):
            i += 1
            to_dir = args[i]
        elif a == "--key" and i + 1 < len(args):
            i += 1
            key_file = args[i]
        elif a.startswith("-"):
            print("unknown option:", a)
            return 2
        else:
            targets.append(a)
        i += 1
    current_query = query
    if cmd == "build":
        return await cmd_build(targets, jobs, keep, dry, query, verbose, repro)
    if cmd == "test":
        return await cmd_test(jobs, query, verbose)
    if cmd == "verify":
        return await cmd_verify(jobs, query, verbose)
    if cmd == "dev":
        return await cmd_dev(targets, jobs, query, verbose)
    if cmd == "run":
        for x in rest:
            targets.append(x)
        return await cmd_run(targets, jobs, query, verbose, builddir)
    if cmd == "explain":
        return await cmd_explain(targets, query)
    if cmd == "graph":
        return await cmd_graph(query)
    if cmd == "ninja":
        return await cmd_ninja(targets, query)
    if cmd == "doc":
        if len(html) > 0:
            return await cmd_doc_html(targets, html, query)
        return await cmd_doc(targets, query)
    if cmd == "publish":
        return await cmd_publish(targets, to_dir, key_file, query)
    if cmd == "keygen":
        return await cmd_keygen(targets)
    if cmd == "update":
        return await cmd_update()
    if cmd == "search":
        return await cmd_search(targets)
    if cmd == "add":
        return await cmd_add(targets, unsafe_ok)
    if cmd == "install":
        return await cmd_install(frozen)
    if cmd == "lock":
        return await cmd_lock(frozen, unsafe_ok)
    if cmd == "up":
        return await cmd_up(targets, unsafe_ok)
    if cmd == "tree":
        return await cmd_tree()
    if cmd == "check":
        return await cmd_check(query)
    if cmd == "why":
        return await cmd_why(targets)
    if cmd == "clean":
        return await cmd_clean()
    if cmd == "help":
        usage()
        return 0
    print("unknown command:", cmd)
    usage()
    return 2

sys.exit(await main())
