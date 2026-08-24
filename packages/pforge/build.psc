"""THE ENGINE: what is stale, in what order, and who runs it.

It is the analogue of samurai's 1,546 lines, with this project's decisions. The
reading that produced it is in `pforge/DESIGN.md`; what follows is a summary of
what each piece does and why, because a build engine is made of choices that look
arbitrary until somebody explains the alternative.

**A known limit, said before anyone discovers it:** the date comparison is "the
output is OLDER than the input", with a strict less-than — as in ninja. Two files
written in the same instant are indistinguishable, and on a filesystem with
coarse granularity (macOS's HFS+ has one second) that is a real hole: editing and
rebuilding within the same second may not recompile. The `mtime` here is in
NANOSECONDS precisely to shrink the window where there is resolution, and the
definitive way out — comparing the CONTENT of the inputs, as is already done for
outputs under `restat` — is noted and not done: it costs reading the whole tree
on every build.

**The library does NOT print.** It reports five events, and whoever decides what
to do with them is the front end: the command line prints, the IDE paints. That
is what separates a reusable engine from a script with a `print` in the middle —
and it is easy to get wrong on the first line, so it is said here.
"""
import os
import path
import time
import graph as G
import log as L

# ---------- the five events ----------
# A small contract is a contract you can change. The reason for the dirtiness and
# the graph are asked for by whoever wants them (`explain`) instead of travelling
# in every event.
struct Rep:
    on_plan: def(int)                    # how many edges are going to run
    on_start: def(int, str)              # id, what is being done
    on_end: def(int, int, str, int)      # id, status, the WHOLE output, ms
    on_done: def(bool, int)              # did it work?, how many failed
    # the fifth event: a problem with the GRAPH, not with an edge — two edges
    # producing the same file, an input nobody produces, a cycle, an output
    # promised and not created. It exists because the first version only counted
    # the problems, and "build failed: 3 problem(s)" without saying WHICH is
    # exactly the report that is good for nothing.
    on_error: def(str)

private def nop_error(msg: str):
    pass

private def nop_plan(total: int):
    pass

private def nop_start(id: int, what: str):
    pass

private def nop_end(id: int, st: int, out: str, ms: int):
    pass

private def nop_done(ok: bool, fails: int):
    pass

def quiet() -> Rep:
    """A reporter that does nothing — for whoever only wants the result."""
    return Rep(nop_plan, nop_start, nop_end, nop_done, nop_error)

record Opts:
    jobs: int          # how many processes in flight
    keep_going: int    # -k N: how many failures before stopping (1 = stop at the first)
    dry_run: bool
    explain: bool

def default_opts() -> Opts:
    # the default is the number of cores. This repository's measurement says it
    # saturates at ~4 (the critical path is ONE file of 4.96 s in a 5.0 s build),
    # but the optimum belongs to the project and cores is the honest guess.
    return Opts(os.nproc(), 1, False, False)

struct Build:
    g: G.Graph
    lg: L.Log
    op: Opts
    rep: Rep
    ready: list<int>       # ready edges, the most expensive at the front
    running: int           # how many edges are IN FLIGHT right now
    fails: int
    total: int             # how many edges the plan will run
    console: bool          # a terminal edge is running: nothing else starts
    errs: list<str>        # hygiene: what stops the build from being trustworthy
    why: dict<str, str>    # explain: why each output is dirty

# ---------- hygiene ----------
# Three things are ERRORS, not warnings, because each one breaks the correctness
# of the incremental build: an edge that promises `x.o` and does not create it
# poisons every later build; a cycle never ends; and an input nobody produces and
# which does not exist is a graph lying about what it knows.
private def err(b: Build, msg: str):
    b.errs.append(msg)
    b.rep.on_error(msg)

private def explain(b: Build, node: str, msg: str):
    if b.op.explain:
        b.why[node] = msg

# ---------- dirtiness ----------
# Ninja's SIX tests, read at the source (`graph.cc:222`) and in the order it does
# them. The order matters: `restat` has to swap the mtime BEFORE the comparison,
# otherwise an output that came out clean in an earlier run dirties the world.
private def out_dirty(b: Build, e: G.Edge, n: G.Node, newest: int) -> bool:
    n.stat_now()
    if n.mtime == G.MTIME_MISSING:
        explain(b, n.p, "does not exist")
        return True
    ent = b.lg.get(n.p)
    used_restat = False
    if e.restat and b.lg.has(n.p):
        # 2: on a `restat` edge what counts is the RECORDED mtime, not the disk's
        # — that is how an output that did not really change fails to dirty
        # whoever reads it
        used_restat = True
    if not used_restat and newest >= 0 and n.mtime < newest:
        explain(b, n.p, "older than the newest input")
        return True
    if b.lg.has(n.p):
        if not e.generator and ent.hash != e.hash:
            explain(b, n.p, "the command changed")
            return True
        if newest >= 0 and ent.vtime < newest:
            # 5: the disk's mtime can be new and the content old — a run that
            # wrote the output and died halfway leaves exactly that. What gets
            # compared is the `vtime` (when this edge was CHECKED against its
            # inputs), not the `mtime` (when the output's content changed): on a
            # `restat` edge the two diverge, and using the wrong one makes the
            # edge run forever. See the note on the two dates in `lib_log.psc`.
            explain(b, n.p, "the recorded check is older than the newest input")
            return True
    elif not e.generator:
        explain(b, n.p, "there is no record in the log")
        return True
    return False

# ---------- a graph is reusable ----------
# The PLAN's state (what is dirty, how many inputs are missing, the weight) lives
# on the edge, and a graph can be planned more than once: the IDE builds, the
# programmer edits a file, and the same in-memory graph is built again (F6).
# Without clearing this, the second time sees the first one's plan and concludes
# there is nothing to do — which is the worst possible error, because it is
# silent.
private def reset_plan(g: G.Graph):
    for e in g.edges:
        e.want = False
        e.dirty_in = False
        e.dirty_out = False
        e.nblock = 0
        e.nprune = 0
        e.cpw = 0
    for n in g.nodes:
        n.mtime = G.MTIME_UNKNOWN
        n.dirty = False

# ---------- what the tool READ and we did not know ----------
# `cc -MD` leaves a `.d` next to the `.o`, and it stays on disk: it is read in the
# next run's PLAN, which is what a Makefile does with `-include`. Ninja copies
# those files into a binary log of its own for SPEED (it measures projects with
# hundreds of thousands of edges); here there are thousands, and one more log to
# keep consistent would cost more than it saves.
#
# On OUR side none of this is needed: `plangc` answers question 1 of the protocol
# and says what it read, without going through a file at all.
private async def load_depfiles(b: Build):
    for e in b.g.edges:
        if len(e.depfile) == 0 or not path.isfile(e.depfile):
            continue
        f = await open(e.depfile, "r")
        txt = await f.text()
        await f.close()
        for d in L.parse_depfile(txt):
            nid = b.g.node(d).id
            already = False
            for x in e.ins:
                if x == nid:
                    already = True
            for y in e.implicit:
                if y == nid:
                    already = True
            if already:
                continue
            e.implicit.append(nid)
            b.g.nodes[nid].used.append(e.id)

# ---------- the date that COUNTS ----------
# A tool rewrites its output even when it comes out identical — our `plangc` does
# that, and nearly every tool does. The date on disk changes, the content does
# not, and a build that looked only at the date would rebuild the world for
# nothing.
#
# That is what `restat` already solves WITHIN a run (pruning). What was missing
# was CROSSING runs: on the next run the disk's date is new again, and whoever
# reads the file believes itself out of date. Here that closes: for every output
# of a `restat` edge that has a content hash in the log, if the content is STILL
# that one, the date that counts is the log's — not the disk's.
#
# The cost is reading those files once per plan. They are the compiler's outputs
# (dozens in this repository, hundreds in the suite), and that is why this engine
# can do what ninja does not: ninja measures projects with hundreds of thousands
# of edges, and reading everything would be prohibitive for it.
private async def stamp_restat(b: Build):
    for e in b.g.edges:
        if not e.restat:
            continue
        for oid in e.outs:
            n = b.g.nodes[oid]
            ent = b.lg.get(n.p)
            if ent.chash == u64(0):
                continue
            n.stat_now()
            if n.mtime == G.MTIME_MISSING or n.mtime == ent.mtime:
                continue
            if await content_hash(n.p) == ent.chash:
                n.mtime = ent.mtime

# ---------- the plan ----------
private def want_node(b: Build, nid: int, stack: list<int>) -> bool:
    """Marks what has to be built for `nid` to exist and be up to date. Returns
    whether the node ended up dirty. It is recursive and keeps the stack, because
    a cycle here is the only way for the engine to spin forever."""
    n = b.g.nodes[nid]
    if n.gen < 0:
        n.stat_now()
        if n.mtime == G.MTIME_MISSING:
            err(b, "input that does not exist and nobody produces: " + n.p)
        n.dirty = False
        return False
    e = b.g.edges[n.gen]
    for s in stack:
        if s == n.gen:
            err(b, "cycle in the graph, through: " + n.p)
            return False
    if e.want:
        return n.dirty
    e.want = True
    stack.append(n.gen)
    e.nblock = 0
    newest = -1
    ndirty = False
    i = 0
    while i < len(e.ins) + len(e.implicit) + len(e.order):
        # the three bands, in order: normal, implicit, and ORDER-only (which just
        # have to exist beforehand, and dirty nothing)
        isorder = i >= len(e.ins) + len(e.implicit)
        iid = 0
        if i < len(e.ins):
            iid = e.ins[i]
        elif i < len(e.ins) + len(e.implicit):
            iid = e.implicit[i - len(e.ins)]
        else:
            iid = e.order[i - len(e.ins) - len(e.implicit)]
        i += 1
        d = want_node(b, iid, stack)
        inn = b.g.nodes[iid]
        if not isorder:
            if d:
                e.dirty_in = True
            if inn.mtime != G.MTIME_MISSING and inn.mtime > newest:
                newest = inn.mtime
        if d or (inn.gen >= 0 and b.g.edges[inn.gen].nblock > 0):
            e.nblock += 1
    for oid in e.outs:
        if out_dirty(b, e, b.g.nodes[oid], newest):
            e.dirty_out = True
    for oid2 in e.out_implicit:
        if out_dirty(b, e, b.g.nodes[oid2], newest):
            e.dirty_out = True
    # the PRUNE counter: how many blocking inputs have to be pruned before this
    # edge's outputs can be pruned too. It applies whenever the output is not
    # dirty in itself — including when the edge is going to run because of an
    # input, which is the case where pruning has something to prune.
    if not e.dirty_out:
        e.nprune = e.nblock
    if e.dirty_in or e.dirty_out:
        for od in e.outs:
            b.g.nodes[od].dirty = True
        for od2 in e.out_implicit:
            b.g.nodes[od2].dirty = True
        b.total += 1
        ndirty = True
    # the top HAS to be this edge: the stack is the path of the recursion, and it
    # is what detects the cycle. Checking costs nothing and the `pop`'s value is
    # not lost — discarding it would be an unused expression, which the compiler
    # (rightly) warns about
    top = stack.pop()
    if top != n.gen:
        err(b, "the plan's stack went out of order: this is a defect in the engine")
    return ndirty

# ---------- the critical path ----------
# Ninja orders by critical path in NUMBER of edges (weight 1 per edge,
# `build.cc:473`) and ignores the duration it records itself. In a shallow graph
# like this repository's that ties everything: the compiler's 19 TUs all have the
# same length to the binary, and the 4.96 s edge can go last in a 5.0 s build.
# Here the weight is last time's DURATION.
private def cost(e: G.Edge) -> int:
    if e.dur_ms > 0:
        return e.dur_ms
    return 1000     # never ran: a one-second guess, so it does not end up last

private def critical_path(b: Build):
    order: list<int> = []
    seen: list<bool> = []
    for _e in b.g.edges:
        seen.append(False)
    # topological order: a producer appears BEFORE whoever consumes it
    for e in b.g.edges:
        if e.want:
            visit_topo(b, e.id, seen, order)
    for e2 in b.g.edges:
        e2.cpw = cost(e2)
    i = len(order) - 1
    while i >= 0:
        e3 = b.g.edges[order[i]]
        for iid in e3.ins:
            pn = b.g.nodes[iid]
            if pn.gen >= 0:
                pe = b.g.edges[pn.gen]
                cand = e3.cpw + cost(pe)
                if cand > pe.cpw:
                    pe.cpw = cand
        for iid2 in e3.implicit:
            pn2 = b.g.nodes[iid2]
            if pn2.gen >= 0:
                pe2 = b.g.edges[pn2.gen]
                cand2 = e3.cpw + cost(pe2)
                if cand2 > pe2.cpw:
                    pe2.cpw = cand2
        i -= 1

private def visit_topo(b: Build, eid: int, seen: list<bool>, order: list<int>):
    if seen[eid]:
        return
    seen[eid] = True
    e = b.g.edges[eid]
    for iid in e.ins:
        n = b.g.nodes[iid]
        if n.gen >= 0:
            visit_topo(b, n.gen, seen, order)
    for iid2 in e.implicit:
        n2 = b.g.nodes[iid2]
        if n2.gen >= 0:
            visit_topo(b, n2.gen, seen, order)
    order.append(eid)

# ---------- the queue ----------
private def enqueue(b: Build, eid: int):
    """The most expensive at the front. Ordered insertion and not a `sorted` every
    time: the queue changes one edge at a time, and one scan of N is cheaper than
    a repeated N log N sort."""
    e = b.g.edges[eid]
    i = 0
    while i < len(b.ready):
        if b.g.edges[b.ready[i]].cpw < e.cpw:
            break
        i += 1
    b.ready.insert(i, eid)

private def take_ready(b: Build) -> int:
    """The next edge to run — or -1, which means "not now".

    The queue already comes ordered by critical path; what gets decided here is
    the `console` POOL, and it is an exclusion rule in three lines:

      * a console edge only starts on empty ground (`running == 0`), because it
        talks to the terminal and nobody else may talk at the same time;
      * while it runs, nothing else starts.

    It is ninja's `pool = console`, and the reason it exists is the same as the
    capture in the rest of the build: two things writing to the same place at the
    same time interleave each other's lines. The difference is that here the
    place is the caller's terminal, and not a buffer that gets flushed at the
    end."""
    if len(b.ready) == 0 or b.console:
        return -1
    v = b.ready[0]
    if b.g.edges[v].pool == "console" and b.running > 0:
        # it is the most expensive one and it is ready, but the ground is not
        # clear: it waits. Skipping over it would be possible and is deliberately
        # left out — the queue's order is the critical path, and puncturing it
        # for convenience is how you lose the property it exists to give.
        return -1
    b.ready = b.ready[1:len(b.ready)]
    return v

# ---------- an output's content ----------
# Ninja's `restat` compares MTIME, and that only prunes when the tool refuses to
# rewrite an identical file. Our `plangc` always rewrites — as nearly every tool
# does — so here `restat` compares CONTENT. It is the difference between pruning
# working and not working, and it is what is worth this repository's 18 s: the
# regenerated C comes out byte for byte identical on almost every edit.
private async def content_hash(p: str) -> u64:
    if not path.isfile(p):
        return u64(0)
    f = await open(p, "r")
    txt = await f.text()
    await f.close()
    return G.hash_str(G.FNV_OFF, txt)

# ---------- finishing an edge ----------
private def newest_input(b: Build, e: G.Edge) -> int:
    """The date of this edge's newest input — the same arithmetic the plan does,
    and for the same reason (ORDER-only ones do not count: they merely have to
    exist)."""
    newest = -1
    for i in e.ins:
        n = b.g.nodes[i]
        if n.mtime != G.MTIME_MISSING and n.mtime > newest:
            newest = n.mtime
    for j in e.implicit:
        n2 = b.g.nodes[j]
        if n2.mtime != G.MTIME_MISSING and n2.mtime > newest:
            newest = n2.mtime
    return newest

private def node_done(b: Build, nid: int, prune: bool):
    """An output became ready. Two things can happen to whoever depends on it,
    and the difference between the two is the entire pruning mechanism:

      * if this output did not CHANGE (`prune`), whoever depended on it only
        because of it does not need to run — and THEIR outputs did not change
        either, so the pruning moves on, transitively;
      * otherwise, whoever depended on it has one fewer missing input, and once
        none are missing it enters the queue.

    It is samurai's `nodedone` logic, with the two counters (`nblock` and
    `nprune`) it uses."""
    n = b.g.nodes[nid]
    for eid in n.used:
        e = b.g.edges[eid]
        if not e.want:
            continue
        # THE TWO COUNTERS MOVE SEPARATELY, and every input that finishes touches
        # both: `nblock` is "how many inputs are still missing" and `nprune` is
        # "how many can still arrive unchanged". An input that CHANGED lowers only
        # the first; one that came out identical lowers both.
        #
        # The previous version picked ONE of the counters per input, and because
        # of that an edge with MIXED inputs — one that changed and one that did
        # not — was left with both at 1 and never came out again: it neither ran
        # nor got pruned. The arm waiting for it saw an empty queue, nobody in
        # flight, and left. The build finished successfully with work left to do,
        # and only the next run continued. That is how one edit to the lexer took
        # five `make` runs to reach the compiler.
        prunable = not e.dirty_out
        if prune and prunable:
            e.nprune -= 1
        e.nblock -= 1
        if prunable and e.nprune == 0:
            # EVERYTHING that blocked it came back unchanged: this edge does not
            # need to run, and its outputs did not change either — the pruning
            # moves on
            for oid in e.outs:
                node_done(b, oid, True)
            if e.dirty_in or e.dirty_out:
                b.total -= 1
        elif e.nblock == 0 and (e.dirty_in or e.dirty_out):
            enqueue(b, eid)

private async def finish(b: Build, e: G.Edge, ok: bool, dur_ms: int):
    if not ok:
        return
    if b.op.dry_run:
        # in a dry run nothing was created, so there is no output to date and
        # none to hold to account. What still counts is UNBLOCKING whoever was
        # waiting: that is what makes the dry run walk the whole graph instead of
        # stopping at the first edge.
        for oid0 in e.outs:
            node_done(b, oid0, False)
        for oid1 in e.out_implicit:
            node_done(b, oid1, False)
        return
    # the `depfile`: what the tool READ and we did not know. It stays on disk and
    # is read in the next PLAN (which is what a Makefile does with `-include`);
    # ninja copies it into a binary log for speed, and here that does not pay for
    # itself yet — these are thousands of files, not millions.
    for oid in e.outs:
        n = b.g.nodes[oid]
        before = b.lg.get(n.p)
        n.mtime = G.MTIME_UNKNOWN
        n.stat_now()
        if n.mtime == G.MTIME_MISSING:
            err(b, "the edge promised '" + n.p + "' and did not create it")
            continue
        prune = False
        ch = u64(0)
        if e.restat:
            ch = await content_hash(n.p)
            if before.chash != u64(0) and ch == before.chash:
                # it came out IDENTICAL: whoever reads it does not need to run,
                # and the node keeps the OLD date so that the pruning crosses
                # this run.
                prune = True
                n.mtime = before.mtime
                # BOTH dates go into the log: the old one (the content did not
                # change) and the newest input's (this edge is checked against
                # it). The first is what stops readers from recompiling; the
                # second is what stops THIS edge from running again forever. See
                # the note on the two dates in `lib_log.psc`.
                b.lg.put(n.p, before.mtime, newest_input(b, e), dur_ms, e.hash, ch)
        if not prune:
            b.lg.put(n.p, n.mtime, newest_input(b, e), dur_ms, e.hash, ch)
        node_done(b, oid, prune)
    for oid2 in e.out_implicit:
        n2 = b.g.nodes[oid2]
        n2.mtime = G.MTIME_UNKNOWN
        n2.stat_now()
        node_done(b, oid2, False)

# ---------- the executor ----------
# Each arm takes the most expensive edge that is ready, runs it, and comes back
# for another. When one finishes and more than one becomes ready, it wakes new
# arms up to the limit — which is what stops parallelism from collapsing to one
# when a long edge unblocks several.
private async def pump(b: Build) -> int:
    while True:
        if b.fails >= b.op.keep_going:
            break
        eid = take_ready(b)
        if eid < 0:
            # Nothing READY right now. Two different things look like this: the
            # build is over, or somebody is still running and will unblock more
            # edges when they finish. Only the first is a reason to leave.
            if b.running == 0:
                break
            await sleep(0.001)
            continue
        e = b.g.edges[eid]
        # an output's directory has to exist BEFORE the tool runs. Nobody
        # declares that in a build file — ninja does not require it either — and
        # the engine does it because the alternative is every edge carrying a
        # `mkdir -p` that has nothing to do with what it does.
        if not b.op.dry_run:
            for oid in e.outs:
                d = path.dirname(b.g.nodes[oid].p)
                if len(d) > 0 and not path.isdir(d):
                    os.makedirs(d)
            if len(e.stdout_to) > 0:
                d2 = path.dirname(e.stdout_to)
                if len(d2) > 0 and not path.isdir(d2):
                    os.makedirs(d2)
        b.rep.on_start(e.id, e.label())
        # `running` is how many edges are IN FLIGHT. An arm that finds no work
        # looks at it to know whether to wait or to leave.
        b.running += 1
        alone = e.pool == "console"
        if alone:
            b.console = True
        if b.op.dry_run:
            b.rep.on_end(e.id, 0, "", 0)
            await finish(b, e, True, 0)
        elif alone:
            # no capture: the child inherits THIS terminal, and what comes back is
            # only the status. The event carries an empty output because it has
            # already been seen — inventing a text here would repeat what the user
            # read.
            t1 = time_ms()
            r1 = await os.run(e.argv, env=e.env, cwd=e.cwd, console=True)
            ms1 = time_ms() - t1
            b.rep.on_end(e.id, r1.status(), "", ms1)
            if r1.status() != 0:
                b.fails += 1
            await finish(b, e, r1.status() == 0, ms1)
        else:
            t0 = time_ms()
            r = await os.run(e.argv, env=e.env, cwd=e.cwd, stdout=e.stdout_to)
            ms = time_ms() - t0
            b.rep.on_end(e.id, r.status(), r.output(), ms)
            if r.status() != 0:
                b.fails += 1
            await finish(b, e, r.status() == 0, ms)
        if alone:
            b.console = False
        b.running -= 1
    return 0

private def time_ms() -> int:
    # the MONOTONIC clock: measuring a duration with the wall clock would give a
    # negative number on the day the system fixes the time in the middle of a
    # build
    return int(time.monotonic() * 1000.0)

# ---------- the facade ----------
async def build(g: G.Graph, logpath: str, targets: list<str>, op: Opts, rep: Rep) -> bool:
    """Builds `targets` (or the graph's default). Returns whether it worked.

    The phases are here in the order the design names them: PLAN (what is stale),
    DECIDE (in what order), EXECUTE (run), RECORD (the log).
    """
    b = Build(g, await L.load(logpath), op, rep, [], 0, 0, 0, False, [], {})
    reset_plan(g)
    # the log comes in BEFORE the plan: it is what knows the command hash and the
    # duration
    for e0 in g.edges:
        for oid in e0.outs:
            ent = b.lg.get(g.nodes[oid].p)
            if ent.dur_ms > e0.dur_ms:
                e0.dur_ms = ent.dur_ms
    for dup in g.dupes:
        err(b, "two edges produce the same file: " + dup)
    await load_depfiles(b)
    await stamp_restat(b)
    tl = targets
    if len(tl) == 0:
        tl = g.default_targets
    if len(tl) == 0:
        # with no target given, everything nobody consumes is a target — which is
        # what "build the project" means
        for n in g.nodes:
            if n.gen >= 0 and len(n.used) == 0:
                tl.append(n.p)
    stack: list<int> = []
    for t in tl:
        if t not in g.by_path:
            err(b, "unknown target: " + t)
            continue
        want_node(b, g.by_path[t], stack)
    if len(b.errs) > 0:
        rep.on_done(False, len(b.errs))
        return False
    critical_path(b)
    for e in g.edges:
        if e.want and e.nblock == 0 and (e.dirty_in or e.dirty_out):
            enqueue(b, e.id)
    rep.on_plan(b.total)
    # what decides whether there is work is the QUEUE, not the counter: the
    # counter is a report (and pruning lowers it while the build runs)
    if len(b.ready) > 0:
        # THE ARMS ARE CREATED ALL AT ONCE, and not by one another.
        #
        # The first shape had each arm multiply itself and then wait for its
        # children, which made a CHAIN of nested waits — thirteen `pump`s on the
        # stack with `-j 8`. Besides limiting nothing, it deadlocked: at the
        # bottom of the chain someone waited for whoever had already finished, and
        # the program died with "deadlock: awaiting a task that nothing can
        # finish" after printing everything green.
        #
        # A FLAT POOL has no chain: N identical arms, each taking from the queue
        # until nothing is in flight any more. Whoever finds no work and sees
        # someone running waits a millisecond and looks again — that is the price
        # of having no signalling, and it is only paid while an arm is IDLE.
        arms: list<Task<int>> = []
        n = b.op.jobs if b.op.jobs > 0 else 1
        for i in range(n):
            arms.append(pump(b))
        await gather(arms)
    await L.save(b.lg)
    ok = b.fails == 0 and len(b.errs) == 0
    rep.on_done(ok, b.fails + len(b.errs))
    return ok

async def why_dirty(g: G.Graph, logpath: str, targets: list<str>) -> dict<str, str>:
    """`--explain`, and it is a QUERY and not an event: it runs only the PLAN and
    returns, per output, the reason it is dirty. It stays out of the event stream
    on purpose — the reason is almost never read, and carrying it in every event
    would fatten the contract the IDE is going to consume.

    It is the question that saves the afternoon when the build rebuilds what it
    should not have."""
    b = Build(g, await L.load(logpath), Opts(1, 1, True, True), quiet(), [], 0, 0, 0, False, [], {})
    reset_plan(g)
    await load_depfiles(b)
    await stamp_restat(b)
    tl = targets
    if len(tl) == 0:
        tl = g.default_targets
    stack: list<int> = []
    for t in tl:
        if t in g.by_path:
            want_node(b, g.by_path[t], stack)
    return b.why

def errors(b: Build) -> list<str>:
    return b.errs
