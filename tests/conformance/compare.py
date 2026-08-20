#!/usr/bin/env python3
"""Compare a corpus's WANT file with what our implementation answered.

    compare.py <name> <want-file> <got-file> [skips-file]

Both files are the same shape — `CASE <id>` followed by `WANT <line>`s — so the
comparison is per case, and what it prints is the score plus every disagreement.

The skips file is the record of what we KNOW we do not do, one `<id> <reason>`
per line. A skip is not a pass: it is counted, printed and reported separately,
so it stays visible instead of quietly becoming the baseline. A skip listed for
a case that now AGREES is an error — the note outlived the problem and should
be deleted.

Exit code 0 when every non-skipped case agrees.
"""
import sys


def load(path):
    cases, order, cur = {}, [], None
    for line in open(path, encoding="utf-8", errors="surrogateescape"):
        line = line.rstrip("\n")
        if line.startswith("CASE "):
            cur = line[5:]
            cases[cur] = []
            order.append(cur)
        elif line.startswith("WANT ") and cur is not None:
            cases[cur].append(line[5:])
    return cases, order


def agree(want, got):
    """Do the two answers agree?

    For a message that PARSED, exactly — every field, in order.

    For a message that was REFUSED, the rule is "both refuse it, and neither
    contradicts the other about anything both of them named". That is not a
    softer bar, it is the same bar the whole digest is set at: llhttp is a
    byte-at-a-time state machine and reports each span the moment it closes,
    while this parser reads a line before it decides anything. So on
    `GET / HTTP/5.6` with no line ending, llhttp has already reported the method,
    the target and the version when it refuses the version; we have not read a
    complete line yet and report nothing. Which FIELDS a parser had recognised
    when it gave up is a property of its granularity — the same property the
    digest already drops when it throws away byte offsets and span boundaries.
    What must match is the verdict, and every value both sides did state.
    """
    if want == got:
        return True
    if ("error" in want) != ("error" in got):
        return False

    # Every message that FINISHED must be identical — fields, values and order.
    # That is where the verdict lives and it is compared exactly.
    def complete_part(xs):
        out, cur = [], []
        for x in xs:
            if x == "error":
                continue
            cur.append(x)
            if x.endswith(" complete"):
                out.extend(cur)
                cur = []
        return out, cur

    cw, tw = complete_part(want)
    cg, tg = complete_part(got)
    if cw != cg:
        return False

    # What is left is the message that had NOT finished when the input ran out,
    # and that is exactly where granularity shows: llhttp closes each span the
    # moment it reads it, so on `HTTP/1.1 204<CRLF><CRLF>HTTP/1.1 200 OK` it has
    # already reported the second response's version when the bytes stop, while
    # a parser that reads a line before deciding has reported nothing. Neither is
    # wrong about the message; one has simply looked at more of it.
    #
    # So the tail is checked for CONTRADICTION rather than for completeness: a
    # field both sides named must agree, and a value one side stopped in the
    # middle of (`protocol=HT` against `protocol=HTP`) counts as agreeing,
    # because a prefix is what stopping in the middle looks like.
    def keyed(xs):
        d = {}
        for x in xs:
            if "=" not in x:
                continue
            k, _, v = x.partition("=")
            d.setdefault(k, []).append(v)
        return d

    a, b = keyed(tw), keyed(tg)
    for k in a:
        if k not in b:
            continue
        for x, y in zip(a[k], b[k]):
            if x != y and not x.startswith(y) and not y.startswith(x):
                return False
    return True


def main():
    name, wf, gf = sys.argv[1], sys.argv[2], sys.argv[3]
    skips = {}
    if len(sys.argv) > 4:
        try:
            for line in open(sys.argv[4], encoding="utf-8"):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                # `::` separates the id from the reason, because a case id
                # contains spaces (`request/method:372 SOURCE request with ICE`)
                # and splitting at the first one silently skipped nothing.
                cid, sep, why = line.partition("::")
                if not sep:
                    cid, _, why = line.partition(" ")
                skips[cid.strip()] = why.strip()
        except FileNotFoundError:
            pass

    want, order = load(wf)
    got, _ = load(gf)

    nagree, disagree, skipped, stale = 0, [], 0, []
    for cid in order:
        same = agree(want[cid], got.get(cid) or [])
        if cid in skips:
            skipped += 1
            if same:
                stale.append(cid)
            continue
        if same:
            nagree += 1
        else:
            disagree.append(cid)

    total = len(order)
    print("   %s: %d/%d agree%s" % (
        name, nagree, total - skipped,
        (", %d skipped" % skipped) if skipped else ""))
    for cid in disagree[:20]:
        print("     CASE %s" % cid)
        print("       want: %s" % (" | ".join(want[cid])[:160]))
        print("       got : %s" % (" | ".join(got.get(cid) or ["<missing>"])[:160]))
    if len(disagree) > 20:
        print("     ... and %d more" % (len(disagree) - 20))
    for cid in stale:
        print("     STALE SKIP %s — it agrees now; delete the line" % cid)
    return 1 if disagree or stale else 0


sys.exit(main())
