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


def main():
    name, wf, gf = sys.argv[1], sys.argv[2], sys.argv[3]
    skips = {}
    if len(sys.argv) > 4:
        try:
            for line in open(sys.argv[4], encoding="utf-8"):
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                cid, _, why = line.partition(" ")
                skips[cid] = why.strip()
        except FileNotFoundError:
            pass

    want, order = load(wf)
    got, _ = load(gf)

    agree, disagree, skipped, stale = 0, [], 0, []
    for cid in order:
        same = want[cid] == got.get(cid)
        if cid in skips:
            skipped += 1
            if same:
                stale.append(cid)
            continue
        if same:
            agree += 1
        else:
            disagree.append(cid)

    total = len(order)
    print("   %s: %d/%d agree%s" % (
        name, agree, total - skipped,
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
