#!/usr/bin/env python3
"""web-platform-tests' URL corpus, turned into a case file.

`url/resources/urltestdata.json` is the file every browser is measured against:
891 cases, 267 of which must FAIL to parse. Each case is an input, an optional
base, and the components the result must have.

The input and base go across as hex because they are full of tabs, newlines,
lone surrogates and C0 controls — the corpus is mostly made of the things that
break naive parsers, so any text encoding of it would be one more thing to get
wrong between the two sides.

Usage:  wpt_url_digest.py <urltestdata.json>
"""
import json
import sys

# The components a `Url` here can state. `origin` is deliberately absent: it is
# optional in the corpus, and it is a different algorithm (opaque origins,
# blob unwrapping) that belongs with a `URL` object rather than with a parser.
FIELDS = ["href", "protocol", "username", "password", "host", "hostname",
          "port", "pathname", "search", "hash"]


def main():
    data = json.load(open(sys.argv[1], encoding="utf-8"))
    n = 0
    for case in data:
        if not isinstance(case, dict):
            continue          # the corpus interleaves comment strings
        if "input" not in case:
            continue
        print("CASE %d" % n)
        print("INPUT " + case["input"].encode("utf-8", "surrogatepass").hex())
        base = case.get("base")
        print("BASE " + (base.encode("utf-8", "surrogatepass").hex() if base is not None else "-"))
        if case.get("failure"):
            print("WANT failure")
        else:
            for f in FIELDS:
                if f in case:
                    print("WANT %s=%s" % (f, case[f]))
        print("END")
        n += 1
    print("# cases=%d" % n, file=sys.stderr)


main()
