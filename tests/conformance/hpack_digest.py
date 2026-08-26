#!/usr/bin/env python3
"""http2jp/hpack-test-case -> the WANT file, plus the WIRE our decoder reads.

    hpack_digest.py <corpus-root> <want-out> <wire-out>

The corpus is `story_NN.json` per implementation, each a list of cases with a
`wire` (hex) and the `headers` it encodes. What makes it a real test, and what is
easy to miss: **the cases of one story share a dynamic table, in `seqno` order.**
Decoding each case with a fresh table passes and proves nothing about eviction,
which is where the bugs live.

Fourteen implementations encoded the same headers fourteen ways — Huffman and
not, table resized mid-stream, static-only. That is the other half of the value:
the decoder meets every strategy anybody shipped, not only the one our own
encoder happens to emit.

Written like `wpt_url_digest.py` next door, and it produces the same
`CASE`/`WANT` shape `compare.py` reads, so the comparison and the skips file are
the ones that already exist.
"""
import json, os, sys, glob


def esc(s):
    return (s.replace('\\', '\\\\').replace('\t', '\\t')
             .replace('\n', '\\n').replace('\r', '\\r'))


def main(root, want_out, wire_out):
    stories = sorted(glob.glob(os.path.join(root, '*', 'story_*.json')))
    want = open(want_out, 'w', encoding='utf-8')
    wire = open(wire_out, 'w', encoding='utf-8')
    n_story = n_case = 0
    for path in stories:
        try:
            d = json.load(open(path, encoding='utf-8'))
        except Exception:
            continue
        cases = d.get('cases') or []
        # raw-data/ holds the INPUT headers with no wire: it is what the corpus
        # was generated from, not a vector to decode
        if not cases or 'wire' not in cases[0]:
            continue
        rel = os.path.relpath(path, root)
        n_story += 1
        for c in sorted(cases, key=lambda x: x.get('seqno', 0)):
            cid = '%s#%d' % (rel, c.get('seqno', n_case))
            n_case += 1
            want.write('CASE %s\n' % cid)
            for pair in c['headers']:
                for k, v in pair.items():
                    want.write('WANT %s\t%s\n' % (esc(k), esc(str(v))))
            wire.write('%s %s\n' % (cid, c['wire']))
    want.close(); wire.close()
    print('%d stories, %d cases' % (n_story, n_case))


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2], sys.argv[3])
