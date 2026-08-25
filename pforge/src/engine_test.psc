"""The pforge ENGINE, mechanism by mechanism (F2B).

Every case here exists because, without it, a build lies in a different way — and
lying is the only defect that matters in a build system: recompiling too much
costs time, but not recompiling what changed costs an afternoon of investigation.

The graphs are synthetic and tiny on purpose: what gets measured is the DECISION
(to run or not to run, in what order, and what to say when the graph lies), not
the compilation of anything.
"""
import os
import path
import sys
import <pforge/graph.psc> as G
import <pforge/build.psc> as B
import <pforge/ninja.psc> as N
import <pforge/targets.psc> as T
import <pforge/manifest.psc> as M
import <pforge/api.psc> as A
import <pforge/pkg.psc> as PK
import build_plang as BP

const DIR: str = "tests/out/pforge"

ok_count: int = 0
fail_count: int = 0

def check(what: str, want: str, got: str):
    global ok_count
    global fail_count
    if want == got:
        ok_count += 1
    else:
        fail_count += 1
        print("  FAIL " + what + ": expected '" + want + "', got '" + got + "'")

# ---------- a reporter that only COUNTS ----------
ran: List<str> = []
order: List<str> = []
# how many edges are IN FLIGHT now, and how many ever were: it is how you observe
# `-j` from the outside, without looking inside the engine
in_flight: int = 0
peak: int = 0

def r_plan(total: int):
    pass

# each edge's LABEL and what its event brought back: it is how a case checks the
# OUTPUT of a specific edge, and not only the scoreboard
labels: Dict<int, str> = {}
outputs: Dict<str, str> = {}

def r_start(id: int, what: str):
    global order
    global in_flight
    global peak
    global labels
    labels[id] = what
    order.append(what)
    in_flight += 1
    if in_flight > peak:
        peak = in_flight

def r_end(id: int, st: int, out: str, ms: int):
    global ran
    global in_flight
    global outputs
    in_flight -= 1
    outputs[labels[id] if id in labels else str(id)] = out
    ran.append(str(st))

def r_done(ok: bool, fails: int):
    pass

# the fifth event: the GRAPH's problems, kept so the hygiene cases can check the
# MESSAGE and not only the count
errors: List<str> = []

def r_error(msg: str):
    global errors
    errors.append(msg)

def rep() -> B.Rep:
    return B.Rep(r_plan, r_start, r_end, r_done, r_error)

def reset():
    global ran
    global order
    global errors
    fresh: List<str> = []
    fresh2: List<str> = []
    fresh3: List<str> = []
    global in_flight
    global peak
    global labels
    global outputs
    fresh4: Dict<int, str> = {}
    fresh5: Dict<str, str> = {}
    ran = fresh
    order = fresh2
    errors = fresh3
    labels = fresh4
    outputs = fresh5
    in_flight = 0
    peak = 0

private def opts(jobs: int) -> B.Opts:
    return B.Opts(jobs, 1, False, False)

private async def write_file(p: str, txt: str):
    f = await open(p, "w")
    await f.write(txt)
    await f.close()

private async def write_newer(p: str, txt: str, than: str):
    """Writes `p` and makes sure it ends up with an mtime GREATER than `than`'s.

    Without this the test is sensitive to the filesystem: the engine compares
    mtimes with "less than" (which is what ninja does), so two files written in
    the same instant are indistinguishable. On ext4 the mtimes are nanoseconds and
    the first write is enough; on a coarse-grained system — macOS's HFS+ has ONE
    SECOND — the wait is real, and it is what makes the test measure what it says
    it measures instead of passing by luck.
    """
    n = 0
    while n < 400:
        await write_file(p, txt)
        if path.getmtime_ns(p) > path.getmtime_ns(than):
            return
        n += 1
    # after 400 tries the problem is not granularity: let it through and the case
    # fails saying what failed, which is better than hanging here

private def touch_cmd(p: str, txt: str) -> List<str>:
    return ["/bin/sh", "-c", "printf '%s' " + txt + " > " + p]

# ---------- the cases ----------
async def case_incremental():
    """Builds once, does not build the second time, and builds again when the
    input changes. It is the whole build in three lines."""
    reset()
    await write_file(DIR + "/a.in", "1")
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/a.in > " + DIR + "/a.out"])
    e.ins.append(g.node(DIR + "/a.in").id)
    e.outs.append(g.node(DIR + "/a.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/a.out")
    lg = DIR + "/log1"
    await B.build(g, lg, [], opts(1), rep())
    check("incremental: the first run runs", "1", str(len(ran)))
    reset()
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/a.in > " + DIR + "/a.out"])
    e2.ins.append(g2.node(DIR + "/a.in").id)
    e2.outs.append(g2.node(DIR + "/a.out").id)
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/a.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("incremental: the second run does NOT run", "0", str(len(ran)))
    reset()
    await write_newer(DIR + "/a.in", "2", DIR + "/a.out")
    g3 = G.new_graph()
    e3 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/a.in > " + DIR + "/a.out"])
    e3.ins.append(g3.node(DIR + "/a.in").id)
    e3.outs.append(g3.node(DIR + "/a.out").id)
    g3.add_edge(e3)
    g3.default_targets.append(DIR + "/a.out")
    await B.build(g3, lg, [], opts(1), rep())
    check("incremental: the input changed, it runs", "1", str(len(ran)))

async def case_command_changed():
    """Ninja catches this and no date comparison would: the input is the same, the
    output is the same, and the COMMAND changed."""
    reset()
    await write_file(DIR + "/b.in", "x")
    lg = DIR + "/log2"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo one > " + DIR + "/b.out"])
    e.ins.append(g.node(DIR + "/b.in").id)
    e.outs.append(g.node(DIR + "/b.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/b.out")
    await B.build(g, lg, [], opts(1), rep())
    reset()
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "echo TWO > " + DIR + "/b.out"])
    e2.ins.append(g2.node(DIR + "/b.in").id)
    e2.outs.append(g2.node(DIR + "/b.out").id)
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/b.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("the command changed: it runs", "1", str(len(ran)))

async def case_env_changed():
    """The extension over ninja: the hash covers the effective ENVIRONMENT.
    Swapping `CC=clang` for `CC=gcc` without this reuses the artifact in
    silence."""
    reset()
    lg = DIR + "/log3"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo $Q > " + DIR + "/c.out"])
    e.env["Q"] = "one"
    e.outs.append(g.node(DIR + "/c.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/c.out")
    await B.build(g, lg, [], opts(1), rep())
    reset()
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "echo $Q > " + DIR + "/c.out"])
    e2.env["Q"] = "two"
    e2.outs.append(g2.node(DIR + "/c.out").id)
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/c.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("the environment changed: it runs", "1", str(len(ran)))

async def case_restat():
    """`restat`: the edge ran, the output came out IDENTICAL, and whoever depends
    on it does NOT run. It is what turns "I regenerated identical C" into "I did
    not recompile the 18 s"."""
    reset()
    lg = DIR + "/log4"
    await write_file(DIR + "/d.in", "1")
    g = G.new_graph()
    gen = G.new_edge(["/bin/sh", "-c", "echo constant > " + DIR + "/d.mid"])
    gen.ins.append(g.node(DIR + "/d.in").id)
    gen.outs.append(g.node(DIR + "/d.mid").id)
    gen.restat = True
    gen.desc = "generates d.mid"
    g.add_edge(gen)
    use = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/d.mid > " + DIR + "/d.out"])
    use.ins.append(g.node(DIR + "/d.mid").id)
    use.outs.append(g.node(DIR + "/d.out").id)
    use.desc = "uses d.mid"
    g.add_edge(use)
    g.default_targets.append(DIR + "/d.out")
    await B.build(g, lg, [], opts(1), rep())
    check("restat: the first time runs both", "2", str(len(ran)))
    # the input changes; the generator runs again and produces the SAME content
    reset()
    await write_newer(DIR + "/d.in", "2", DIR + "/d.mid")
    g2 = G.new_graph()
    gen2 = G.new_edge(["/bin/sh", "-c", "echo constant > " + DIR + "/d.mid"])
    gen2.ins.append(g2.node(DIR + "/d.in").id)
    gen2.outs.append(g2.node(DIR + "/d.mid").id)
    gen2.restat = True
    gen2.desc = "generates d.mid"
    g2.add_edge(gen2)
    use2 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/d.mid > " + DIR + "/d.out"])
    use2.ins.append(g2.node(DIR + "/d.mid").id)
    use2.outs.append(g2.node(DIR + "/d.out").id)
    use2.desc = "uses d.mid"
    g2.add_edge(use2)
    g2.default_targets.append(DIR + "/d.out")
    await B.build(g2, lg, [], opts(1), rep())
    # the generator runs (the input changed) and produces IDENTICAL bytes; the
    # consumer is pruned. With ninja's mtime-based `restat` this would not happen
    # — the `echo` rewrites the file and the mtime changes — and that is why here
    # it compares content.
    check("restat: only the generator runs again", "1", str(len(ran)))

    # AND THE NEXT RUN RUNS NOTHING. This is the test that separates "I did not
    # recompile this time" from "I do not recompile any more": the generator
    # rewrote `d.mid` (new date on disk, same content), and its input ended up
    # newer than the date the log had recorded. Without the two fixes — the
    # NEWEST INPUT's date in the log, and the log's date counting for an output
    # whose content did not change — the generator ran on every run, forever, and
    # `pforge verify` redid 296 edges for nothing. That is how it showed up.
    reset()
    g3 = G.new_graph()
    gen3 = G.new_edge(["/bin/sh", "-c", "echo constant > " + DIR + "/d.mid"])
    gen3.ins.append(g3.node(DIR + "/d.in").id)
    gen3.outs.append(g3.node(DIR + "/d.mid").id)
    gen3.restat = True
    gen3.desc = "generates d.mid"
    g3.add_edge(gen3)
    use3 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/d.mid > " + DIR + "/d.out"])
    use3.ins.append(g3.node(DIR + "/d.mid").id)
    use3.outs.append(g3.node(DIR + "/d.out").id)
    use3.desc = "uses d.mid"
    g3.add_edge(use3)
    g3.default_targets.append(DIR + "/d.out")
    await B.build(g3, lg, [], opts(1), rep())
    check("restat: the next run runs nothing", "0", str(len(ran)))

async def case_parallel_and_order():
    """Eight independent edges with four arms, and the most EXPENSIVE one first.
    The weight comes from last time's duration (which ninja records and does not
    use)."""
    reset()
    lg = DIR + "/log5"
    g = G.new_graph()
    i = 0
    while i < 8:
        e = G.new_edge(["/bin/sh", "-c", "echo " + str(i) + " > " + DIR + "/p" + str(i) + ".out"])
        e.outs.append(g.node(DIR + "/p" + str(i) + ".out").id)
        e.desc = "p" + str(i)
        e.dur_ms = (i + 1) * 10    # index 7 is the most expensive; zero means
                                   # "never ran", and then the engine guesses one second
        g.add_edge(e)
        g.default_targets.append(DIR + "/p" + str(i) + ".out")
        i += 1
    await B.build(g, lg, [], opts(4), rep())
    check("parallel: all eight ran", "8", str(len(ran)))
    check("order: the most expensive started first", "p7", order[0])

async def case_pool_console():
    """`pool = console`: the edge that talks to the TERMINAL, and alone.

    It is the only one in the graph whose output is not captured — the child
    inherits this process's descriptors. That is why it has to run alone: the
    capture exists in the rest of the build to stop two jobs from interleaving
    each other's lines, and without capture the only way to keep that property is
    for there not to be two at once.

    Both things get pinned down here, and both are observable from outside:

      * with four arms and three ready console edges, the PEAK in flight is 1;
      * the ordinary edge brings what it printed in its event (it was captured)
        and the console one brings an EMPTY output — what it printed went to the
        terminal, and shows up in the middle of this report, which is the proof
        you can read."""
    reset()
    lg = DIR + "/log_console"
    g = G.new_graph()
    i = 0
    while i < 3:
        c = G.new_edge(["/bin/sh", "-c", "echo '-- console " + str(i)
                        + " (this line went to the terminal) --'; printf x > "
                        + DIR + "/con" + str(i) + ".out"])
        c.outs.append(g.node(DIR + "/con" + str(i) + ".out").id)
        c.desc = "console" + str(i)
        c.pool = "console"
        g.add_edge(c)
        g.default_targets.append(DIR + "/con" + str(i) + ".out")
        i += 1
    await B.build(g, lg, [], opts(4), rep())
    check("console: all three ran", "3", str(len(ran)))
    check("console: never two at once", "1", str(peak))
    check("console: the event brings no output at all", "", outputs["console0"])

    # and now with company: the ordinary one is captured, the console one is not
    reset()
    g2 = G.new_graph()
    cm = G.new_edge(["/bin/sh", "-c", "echo captured; printf y > " + DIR + "/cap.out"])
    cm.outs.append(g2.node(DIR + "/cap.out").id)
    cm.desc = "ordinary"
    g2.add_edge(cm)
    g2.default_targets.append(DIR + "/cap.out")
    cn = G.new_edge(["/bin/sh", "-c", "printf z > " + DIR + "/con9.out"])
    cn.outs.append(g2.node(DIR + "/con9.out").id)
    cn.desc = "console9"
    cn.pool = "console"
    g2.add_edge(cn)
    g2.default_targets.append(DIR + "/con9.out")
    await B.build(g2, DIR + "/log_console2", [], opts(4), rep())
    check("console: the ordinary one was captured", "captured", outputs["ordinary"].strip())
    check("console: the console one was not", "", outputs["console9"])

async def case_failure_stops():
    """One failure stops the build (ninja's and samurai's default): the first
    message is almost always the cause, and the ones after it are consequences."""
    reset()
    lg = DIR + "/log6"
    g = G.new_graph()
    bad = G.new_edge(["/bin/sh", "-c", "exit 3"])
    bad.outs.append(g.node(DIR + "/never.out").id)
    bad.desc = "the failing one"
    g.add_edge(bad)
    dep = G.new_edge(["/bin/sh", "-c", "echo late > " + DIR + "/after.out"])
    dep.ins.append(g.node(DIR + "/never.out").id)
    dep.outs.append(g.node(DIR + "/after.out").id)
    dep.desc = "the dependent one"
    g.add_edge(dep)
    g.default_targets.append(DIR + "/after.out")
    okv = await B.build(g, lg, [], opts(2), rep())
    check("failure: the build fails", "False", str(okv))
    check("failure: the dependent one did NOT run", "1", str(len(ran)))

async def case_output_not_produced():
    """The edge promised a file and did not create it. It is an ERROR and not a
    warning: an output that does not exist poisons every later build."""
    reset()
    lg = DIR + "/log7"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "true"])
    e.outs.append(g.node(DIR + "/promised.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/promised.out")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("output not produced: fails", "False", str(okv))

async def case_orphan_input():
    """An input that does not exist and that nobody produces: the graph lies about
    what it knows, and saying so BEFORE running anything is the point."""
    reset()
    lg = DIR + "/log8"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "true"])
    e.ins.append(g.node(DIR + "/does_not_exist.in").id)
    e.outs.append(g.node(DIR + "/x.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/x.out")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("orphan input: fails before running", "False", str(okv))
    check("orphan input: nothing ran", "0", str(len(ran)))

async def case_cycle():
    """A cycle is the only way for the engine to spin forever."""
    reset()
    lg = DIR + "/log9"
    g = G.new_graph()
    e1 = G.new_edge(["/bin/sh", "-c", "true"])
    e1.ins.append(g.node(DIR + "/cycle_a").id)
    e1.outs.append(g.node(DIR + "/cycle_b").id)
    g.add_edge(e1)
    e2 = G.new_edge(["/bin/sh", "-c", "true"])
    e2.ins.append(g.node(DIR + "/cycle_b").id)
    e2.outs.append(g.node(DIR + "/cycle_a").id)
    g.add_edge(e2)
    g.default_targets.append(DIR + "/cycle_b")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("cycle: detected", "False", str(okv))

async def case_dry_run():
    """`--dry-run`: says what it would do and does not do it."""
    reset()
    lg = DIR + "/log10"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo should not exist > " + DIR + "/dry.out"])
    e.outs.append(g.node(DIR + "/dry.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/dry.out")
    await B.build(g, lg, [], B.Opts(1, 1, True, False), rep())
    check("dry-run: reported", "1", str(len(ran)))
    check("dry-run: created nothing", "False", str(path.exists(DIR + "/dry.out")))

async def case_depfile():
    """`cc -MD` leaves a `.d` saying what it READ. Without reading that file, an
    edited header recompiles nothing — the most classic failure mode there is in a
    C build."""
    reset()
    lg = DIR + "/log11"
    await write_file(DIR + "/dep.in", "1")
    await write_file(DIR + "/dep.h", "a")
    await write_file(DIR + "/dep.d", DIR + "/dep.out: " + DIR + "/dep.in " + DIR + "/dep.h\n")
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/dep.in > " + DIR + "/dep.out"])
    e.ins.append(g.node(DIR + "/dep.in").id)
    e.outs.append(g.node(DIR + "/dep.out").id)
    e.depfile = DIR + "/dep.d"
    g.add_edge(e)
    g.default_targets.append(DIR + "/dep.out")
    await B.build(g, lg, [], opts(1), rep())
    check("depfile: the first time runs", "1", str(len(ran)))
    # touching the HEADER, which is not among the declared inputs, has to
    # recompile
    reset()
    await write_newer(DIR + "/dep.h", "b", DIR + "/dep.out")
    g2 = G.new_graph()
    e2 = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/dep.in > " + DIR + "/dep.out"])
    e2.ins.append(g2.node(DIR + "/dep.in").id)
    e2.outs.append(g2.node(DIR + "/dep.out").id)
    e2.depfile = DIR + "/dep.d"
    g2.add_edge(e2)
    g2.default_targets.append(DIR + "/dep.out")
    await B.build(g2, lg, [], opts(1), rep())
    check("depfile: the header changed, it runs", "1", str(len(ran)))

async def case_two_producers():
    """Two edges producing the same file: which of them defines the content
    depends on the order they run in, and the incremental build starts depending
    on luck."""
    reset()
    lg = DIR + "/log12"
    g = G.new_graph()
    a = G.new_edge(["/bin/sh", "-c", "echo a > " + DIR + "/two.out"])
    a.outs.append(g.node(DIR + "/two.out").id)
    g.add_edge(a)
    b2 = G.new_edge(["/bin/sh", "-c", "echo b > " + DIR + "/two.out"])
    b2.outs.append(g.node(DIR + "/two.out").id)
    g.add_edge(b2)
    g.default_targets.append(DIR + "/two.out")
    okv = await B.build(g, lg, [], opts(1), rep())
    check("two producers: refused", "False", str(okv))
    check("two producers: nothing ran", "0", str(len(ran)))

async def case_keep_going():
    """`-k N`: keep going after a failure, to see them ALL. The default is to stop
    at the first (the first message is almost always the cause), and this is the
    opposite of that, for when you want the complete scoreboard."""
    reset()
    lg = DIR + "/log13"
    g = G.new_graph()
    i = 0
    while i < 3:
        e = G.new_edge(["/bin/sh", "-c", "exit " + str(i + 1)])
        e.outs.append(g.node(DIR + "/k" + str(i) + ".out").id)
        e.desc = "k" + str(i)
        g.add_edge(e)
        g.default_targets.append(DIR + "/k" + str(i) + ".out")
        i += 1
    okv = await B.build(g, lg, [], B.Opts(1, 9, False, False), rep())
    check("keep-going: failed", "False", str(okv))
    check("keep-going: all three ran", "3", str(len(ran)))

async def case_explain():
    """The query that says WHY something is dirty."""
    reset()
    lg = DIR + "/log14"
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "echo x > " + DIR + "/ex.out"])
    e.outs.append(g.node(DIR + "/ex.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/ex.out")
    w = await B.why_dirty(g, lg, [])
    check("explain: says it does not exist", "does not exist", w[DIR + "/ex.out"])

async def case_graph_reused():
    """The SAME in-memory graph, built twice — which is what the IDE does: it
    builds, the programmer edits, it builds again. The plan's state lives on the
    edge, and if it is not cleared the second time sees the first one's plan and
    concludes there is nothing to do. Silently."""
    reset()
    lg = DIR + "/log15"
    await write_file(DIR + "/re.in", "1")
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "cat " + DIR + "/re.in > " + DIR + "/re.out"])
    e.ins.append(g.node(DIR + "/re.in").id)
    e.outs.append(g.node(DIR + "/re.out").id)
    g.add_edge(e)
    g.default_targets.append(DIR + "/re.out")
    await B.build(g, lg, [], opts(1), rep())
    check("reuse: the first time runs", "1", str(len(ran)))
    reset()
    await B.build(g, lg, [], opts(1), rep())
    check("reuse: nothing changed, does not run", "0", str(len(ran)))
    reset()
    await write_newer(DIR + "/re.in", "2", DIR + "/re.out")
    await B.build(g, lg, [], opts(1), rep())
    check("reuse: the input changed, it runs", "1", str(len(ran)))

async def case_json():
    """The graph goes out and comes back through JSON without losing anything —
    the 1.3 export."""
    g = G.new_graph()
    e = G.new_edge(["cc", "-c", "a.c", "-o", "a.o"])
    e.ins.append(g.node("a.c").id)
    e.implicit.append(g.node("a.h").id)
    e.order.append(g.node("build").id)
    e.outs.append(g.node("a.o").id)
    e.env["CC"] = "cc"
    e.restat = True
    e.desc = "compiling a.c"
    g.add_edge(e)
    j = G.to_json(g)
    g2 = G.from_json(j)
    check("json: same edges", "1", str(len(g2.edges)))
    check("json: same hash", str(e.hash), str(g2.edges[0].compute_hash()))
    check("json: the three bands", "1 1 1", str(len(g2.edges[0].ins)) + " " + str(len(g2.edges[0].implicit)) + " " + str(len(g2.edges[0].order)))
    check("json: restat survived", "True", str(g2.edges[0].restat))

async def case_ninja():
    """The ninja export (F3): the QUOTING, which is where every build system that
    assembles a command line by concatenation breaks.

    The case is deliberately built with everything that bites: a path with a
    space, an argument with a `$` (which ninja eats and the shell would expand),
    one with a single quote (the only escape that single-quote quoting has), an
    environment, a directory and a redirection. And it is not enough for the text
    to look right: the exported command is RUN by a shell, and what it writes to
    disk has to be what the edge promised."""
    g = G.new_graph()
    e = G.new_edge(["/bin/sh", "-c", "printf '%s' \"$UM\" > \"$1\"", "sh", DIR + "/with space.txt"])
    e.env["UM"] = "value with 'quote'"
    e.ins.append(g.node(DIR + "/n.in").id)
    e.implicit.append(g.node(DIR + "/n.h").id)
    e.order.append(g.node(DIR).id)
    e.outs.append(g.node(DIR + "/with space.txt").id)
    e.out_implicit.append(g.node(DIR + "/n.extra").id)
    e.depfile = DIR + "/n.d"
    e.restat = True
    e.generator = True
    e.pool = "console"
    e.desc = "generating with a $ in the middle"
    g.add_edge(e)
    g.default_targets.append(DIR + "/with space.txt")
    txt = N.emit(g)

    # what ninja READS: space and `$` escaped in the path, the three bands in
    # their three separators, and the rule's four keys
    check("ninja: a space in the path becomes '$ '", "True", str(txt.find("with$ space.txt") >= 0))
    check("ninja: the three bands", "True", str(txt.find(": e0 ") >= 0 and txt.find(" | ") >= 0 and txt.find(" || ") >= 0))
    check("ninja: restat", "True", str(txt.find("\n  restat = 1\n") >= 0))
    check("ninja: generator", "True", str(txt.find("\n  generator = 1\n") >= 0))
    check("ninja: pool", "True", str(txt.find("\n  pool = console\n") >= 0))
    check("ninja: depfile and deps", "True", str(txt.find("\n  depfile = ") >= 0 and txt.find("\n  deps = gcc\n") >= 0))
    check("ninja: default", "True", str(txt.find("\ndefault ") >= 0))
    check("ninja: env -i (replaces, does not merge)", "True", str(txt.find("env -i") >= 0))
    # every `$` in the command comes in a PAIR: a lone `$` is a ninja variable,
    # and our argument's `$UM` would become empty before the shell ever saw it
    cmd_line = ""
    for l in txt.split("\n"):
        if l.startswith("  command = "):
            cmd_line = l
    paired = True
    ci = 0
    while ci < len(cmd_line):
        if cmd_line[ci] == "$":
            if ci + 1 >= len(cmd_line) or cmd_line[ci + 1] != "$":
                paired = False
                break
            ci += 1
        ci += 1
    check("ninja: every $ in the command comes in a pair", "True", str(paired))
    check("ninja: and our $UM survived escaped", "True", str(cmd_line.find("$$UM") >= 0))

    # ... and what the SHELL reads: the exported command, actually run
    cmd = N.cmdline(e).replace("$$", "$")
    r = await os.run(["/bin/sh", "-c", cmd])
    check("ninja: the exported command runs", "0", str(r.status()))
    f = await open(DIR + "/with space.txt", "r")
    content = await f.text()
    await f.close()
    check("ninja: and it wrote what the edge promised", "value with 'quote'", content)
    os.remove(DIR + "/with space.txt")

    # two exports of the same graph give the SAME file: a committed `build.ninja`
    # that changes order on every run is a diff for nothing
    check("ninja: deterministic", "True", str(N.emit(g) == txt))

async def case_packages():
    """The PACKAGE graph: the tree and the "who pulled it in" (F4).

    They are the two questions every large lock eventually provokes, and the
    fixture has exactly the shape that makes them interesting: `txt` depends on
    `geo`, and `color` on nobody."""
    reset()
    members: List<str> = ["tests/pkg/geo", "tests/pkg/txt", "tests/pkg/color"]
    m = await PK.read_world(members)
    check("packages: all three", "3", str(len(m.packages)))
    check("packages: nothing missing", "0", str(len(m.missing)))
    check("packages: who pulls geo in", "txt", " ".join(m.who_pulls("geo")))
    check("packages: nobody pulls txt in", "", " ".join(m.who_pulls("txt")))

    # the TREE: the roots first, and what they pull in below them
    t = PK.tree(m)
    check("tree: txt is a root", "True", str(t.find("txt 0.2.0") >= 0))
    check("tree: and geo hangs off it", "True", str(t.find("└─ geo 0.1.0") >= 0))
    check("tree: color is a root too", "True", str(t.find("color 0.1.0") >= 0))

    # a dependency nobody offers is said ONCE, with the name of whoever asked —
    # and not in silence, which is how a build starts to lie
    m2 = await PK.read_world(["tests/pkg/txt"])
    check("packages: what is missing is said", "1", str(len(m2.missing)))
    check("packages: and it says who asked", "True", str(m2.missing[0].find("geo") >= 0 and m2.missing[0].find("txt") >= 0))

async def case_package_with_c():
    """2.13: a package that brings HAND-WRITTEN C, built end to end.

    The `tests/pkg/crc` fixture is the whole case on one page: a `.p` that only
    declares, a `.c` that does the arithmetic, a header that is only found through
    an `-I` relative to the package, and a `-D` without which the C refuses to
    compile (`#error`). If the program runs and gives the right CRC, then all four
    things happened — the C was found, the manifest's flags reached it, the `-I`
    was rewritten against the package's directory, and the object entered the
    link.

    And the package NOBODY imports does not come in: it is what makes `deps` in
    the manifest cost no binary size."""
    reset()
    dir = DIR + "/pkgc"
    if not path.isdir(dir):
        os.makedirs(dir)
    prog = dir + "/uses_crc.p"
    f = await open(prog, "w")
    await f.write("include <stdio.h>\nimport <crc/crc.ph>\n\n"
                  + "def main() -> int:\n"
                  + "    printf(\"%u\\n\", crc32_of(\"123456789\"))\n"
                  + "    return 0\n")
    await f.close()
    g = G.new_graph()
    c = T.new_ctx(g, dir + "/o", BP.PLANGC_S2)
    c.pkgroots = ["tests/pkg"]
    await T.load_packages(c)
    bin = await T.p_program(c, prog, dir + "/uses_crc", dir + "/obj", [], [])
    g.default_targets.append(bin)
    okb = await B.build(g, dir + "/log", [], opts(4), rep())
    check("package with C: builds", "True", str(okb))
    if not okb:
        for e in errors:
            print("      " + e)
        for k in outputs:
            if len(outputs[k]) > 0:
                print("      " + k + ": " + outputs[k].strip())
        return
    r = await os.run([path.join(os.getcwd(), bin)])
    # the CRC-32 of "123456789" is 0xCBF43926 — the check vector every text about
    # CRC quotes, and the one a polynomial or bit-order mistake gets wrong
    check("package with C: and the arithmetic is right", "3421780262", r.output().strip())

async def case_api():
    """Answer 5 read back (`lib_api.psc`): it is what makes `pforge doc` exist
    without a second reader of the language — and a second reader would diverge,
    which is the worst possible outcome."""
    reset()
    dump = ("== geom.ph\n"
            + "include <stdio.h>\n"
            + "struct Point {x: i32, y: i32}\n"
            + "def area(i32, i32) -> i64\n"
            + "const MAX: i32 = 64\n"
            + "#hash 0123456789abcdef\n"
            + "#doc . The module.\\nWith a second line.\n"
            + "#doc area The area.\n"
            + "#doc Point.add The sum.\n"
            + "== other.p\n"
            + "def f() -> void\n"
            + "#hash fedcba9876543210\n")
    ms = A.parse(dump)
    check("api: two modules", "2", str(len(ms)))
    check("api: the path and the hash", "geom.ph 0123456789abcdef", ms[0].path + " " + ms[0].hash)
    check("api: the module's doc, unescaped", "The module.\nWith a second line.", ms[0].doc)
    check("api: finds a symbol", "True", str(ms[0].find("area") >= 0))
    check("api: and its doc", "The area.", ms[0].symbols[ms[0].find("area")].doc)
    check("api: the method comes in even with no line of its own", "The sum.",
          ms[0].symbols[ms[0].find("Point.add")].doc)
    check("api: the second module", "other.p", ms[1].path)

    # the NAME of each form of declaration
    check("api: name of a def", "area", A.name_of("def area(i32, i32) -> i64"))
    check("api: name of a struct", "Point", A.name_of("struct Point {x: i32}"))
    check("api: name of an enum", "Shape", A.name_of("enum Shape {A, B}"))
    check("api: name of a const", "MAX", A.name_of("const MAX: i32 = 64"))
    check("api: an import is not a symbol", "", A.name_of("import \"x.ph\""))

    # the CODE's indentation comes out of the docstring (Python's `cleandoc`)
    check("api: cleandoc", "First.\n\nSecond.",
          A.cleandoc("First.\n\n    Second.\n    "))

async def case_manifest():
    """`pack.json`: package, workspace, and the error WITH A POSITION (F4).

    The manifest is data and never a program — it is the file the IDE's panel
    edits — and that is why its error has to be clickable by the same route a
    compile error is: `file:line:column: error: ...`. Without that, configuring a
    package from the IDE would be guesswork."""
    reset()
    g1 = await M.read("tests/pkg/geo/pack.json")
    check("manifest: name and version", "geo 0.1.0", g1.name + " " + g1.version)
    check("manifest: lang and root", "p geo.ph", g1.lang + " " + g1.root)
    check("manifest: no dependency", "0", str(len(g1.deps)))

    t1 = await M.read("tests/pkg/txt/pack.json")
    check("manifest: the dependency came through", "geo >= 0.1.0",
          t1.deps[0].name + " " + t1.deps[0].req)

    w = await M.read("tests/pkg/pack.json")
    check("manifest: a workspace knows itself", "True", str(w.is_workspace))
    check("manifest: the members", "geo txt color crc", " ".join(w.members))

    # the search ROOT comes out of the workspace: it is the directory that
    # CONTAINS the members, because that is how `import <geo/geo.ph>` resolves
    rs = await BP.workspace_roots("tests/pkg/pack.json")
    check("workspace: one root, the one containing the members", "tests/pkg", " ".join(rs))

    # and this REPOSITORY's: `packages` is the root, because that is where `stl`
    # lives
    rp = await BP.workspace_roots("pack.json")
    check("workspace: this repository's root", "packages", " ".join(rp))

    # a package with no `root` is legitimate: `stl` is ten independent headers and
    # none of them is "the interface"
    st = await M.read("packages/stl/pack.json")
    check("manifest: a package with no root", "stl 0.1.0 p ", st.name + " " + st.version + " " + st.lang + " " + st.root)

    # S0: o metapacote — um NOME para um conjunto de pacotes. Ele INSTALA e não
    # IMPORTA: não cria espaço de nomes nenhum, traz os membros e sai da frente,
    # e é isso que torna verdadeira a cláusula "não são inseparáveis".
    mt = await M.read("tests/pkg/meta/pack.json")
    check("meta: sabe-se metapacote", "True", str(mt.is_meta))
    check("meta: sem lingua e sem raiz", "conjunto 0.1.0  ", mt.name + " " + mt.version + " " + mt.lang + " " + mt.root)
    check("meta: os membros vieram", "geo txt", mt.deps[0].name + " " + mt.deps[1].name)

    # ... e ele exige o OPOSTO do que um pacote normal exige: sem código não há
    # língua, sem língua não há raiz
    nonlocal msg
    msg = ""
    try:
        await M.read("tests/pkg/badmeta/pack.json")
        msg = "nao levantou"
    catch em:
        msg = em.message
    check("meta: uma raiz num metapacote e recusada", "True",
          str(msg.find("has no code") > 0))

    # and the error has a line and a column
    msg = ""
    try:
        await M.read("tests/pkg/bad/pack.json")
        msg = "it did not raise"
    catch e:
        msg = e.message
    check("manifest: the error has a position", "True",
          str(msg.find("tests/pkg/bad/pack.json:2:3: error:") == 0))
    check("manifest: and it says what was wrong", "True", str(msg.find("lowercase") > 0))

async def case_arm_limit():
    """`-j N` REALLY limits: there are never more than N edges in flight.

    The arm counter used to be incremented when the arm STARTED running, and
    creating a task does not put it to work — so the loop that multiplies arms
    always saw `alive == 1` and created one arm per ready edge. In a clean build
    that is hundreds of processes at once, more pipes than the runtime's `poll`
    keeps up with, and the build ended in deadlock. `-j` limited nothing, and
    nobody noticed because the build FINISHED — only too fast and, now and then,
    never.

    Here it is observed from outside: the reporter counts who started and who
    finished."""
    reset()
    g = G.new_graph()
    for i in range(10):
        e = G.new_edge(["/bin/sh", "-c", "sleep 0.05; echo " + str(i) + " > " + DIR + "/j" + str(i) + ".out"])
        e.outs.append(g.node(DIR + "/j" + str(i) + ".out").id)
        e.desc = "j" + str(i)
        g.add_edge(e)
        g.default_targets.append(DIR + "/j" + str(i) + ".out")
    ok = await B.build(g, DIR + "/log12", [], opts(3), rep())
    check("limit: all ten ran", "10 True", str(len(ran)) + " " + str(ok))
    check("limit: never more than 3 in flight", "True", str(peak <= 3))
    check("limit: and it did use the limit", "True", str(peak >= 2))

async def case_negative_gate():
    """A gate by the NEGATIVE: it passes when the pattern does NOT appear (F3).

    It is the shape of the gate that guards the libc typedef regression, and it is
    the only place in the descriptor where there is a shell — because what you
    want is the INVERSE of a command's status, and inverting a status is what `!`
    does. What gets pinned here is that it REALLY inverts: green when it does not
    find, red when it does."""
    reset()
    await write_file(DIR + "/clean.h", "typedef struct Queue Queue;\n")
    await write_file(DIR + "/dirty.h", "typedef struct _IO_FILE FILE;\n")

    g = G.new_graph()
    T.must_not_match(T.new_ctx(g, DIR, "plangc"), "_IO_FILE", [DIR + "/clean.h"],
               DIR + "/clean.ok", "no tag in the clean file")
    g.default_targets.append(DIR + "/clean.ok")
    ok1 = await B.build(g, DIR + "/log9", [], opts(1), rep())
    check("negative gate: green when it does not find", "True", str(ok1))

    g2 = G.new_graph()
    T.must_not_match(T.new_ctx(g2, DIR, "plangc"), "_IO_FILE", [DIR + "/dirty.h"],
               DIR + "/dirty.ok", "a tag in the dirty file")
    g2.default_targets.append(DIR + "/dirty.ok")
    ok2 = await B.build(g2, DIR + "/log10", [], opts(1), rep())
    check("negative gate: red when it does find", "False", str(ok2))

    # and the quoting: a pattern with a single quote crosses whole
    await write_file(DIR + "/quote.h", "nothing here\n")
    g3 = G.new_graph()
    T.must_not_match(T.new_ctx(g3, DIR, "plangc"), "o'brien", [DIR + "/quote.h"],
               DIR + "/quote.ok", "a single quote in the pattern")
    g3.default_targets.append(DIR + "/quote.ok")
    ok3 = await B.build(g3, DIR + "/log11", [], opts(1), rep())
    check("negative gate: a single quote in the pattern", "True", str(ok3))

async def go():
    os.makedirs(DIR)
    await case_incremental()
    await case_command_changed()
    await case_env_changed()
    await case_restat()
    await case_parallel_and_order()
    await case_pool_console()
    await case_failure_stops()
    await case_output_not_produced()
    await case_orphan_input()
    await case_cycle()
    await case_dry_run()
    await case_keep_going()
    await case_explain()
    await case_depfile()
    await case_two_producers()
    await case_graph_reused()
    await case_json()
    await case_ninja()
    await case_packages()
    await case_package_with_c()
    await case_api()
    await case_manifest()
    await case_arm_limit()
    await case_negative_gate()
    print("   pforge-engine: " + str(ok_count) + " ok, " + str(fail_count) + " failed")
    if fail_count > 0:
        sys.exit(1)

await go()
