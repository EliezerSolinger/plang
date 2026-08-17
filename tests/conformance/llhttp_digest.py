#!/usr/bin/env python3
"""Turn llhttp's markdown fixtures into something two parsers can be compared on.

llhttp's fixtures are `.md` files: an ```http block of input and a ```log block
of the events its state machine emits, offset by offset. We do not emit events
by offset — our parser (tests/pscript/run/lib_http.psc) answers with a request:
method, target, version, headers, body. So the log is REDUCED here to the part
both can state, and that reduction is what gets compared:

    method=GET
    url=/
    version=1.1
    header:content-length=5
    body=68656c6c6f
    complete
    error

Nothing about this reduction is generous to us: every field it drops is a field
llhttp checks and we do not model (byte offsets, span boundaries, the pause API,
the `flags` bitfield). What it keeps is every field we DO model, and a case
where we disagree on one of them is a case where two HTTP servers would read the
same bytes as different requests.

Input normalisation follows llhttp's own test/md-test.ts exactly — the escapes
(`\\r`, `\\n`, `\\t`, `\\f`, `\\xNN`, `\\NNN`), the line-continuation, and the
LF→CRLF normalisation. Getting this wrong would silently change the corpus.

Usage:  llhttp_digest.py <dir-with-request/-and-response/> [--list-skipped]

Writes the case file on stdout:  CASE / KIND / INPUT <hex> / WANT ... / END
"""
import json
import os
import re
import sys

# llhttp can be told to relax specific rules at run time (`-lenient-headers`,
# `-lenient-chunked-length`, …). Those fixtures measure the RELAXED machine.
# Ours has no relaxed mode and is not getting one: every one of these flags
# exists to accept something the RFC refuses, and the reason llhttp has them is
# backwards compatibility with deployed clients — a debt we do not carry.
# `-finish` and `pausing` drive an API (pause/resume, finish) we do not expose.
SKIP_TYPE = re.compile(r"lenient|finish|pause")

# A fixture whose input is built by evaluating inline JavaScript (`${...}`).
# There are a handful; they are reported, not silently dropped.
JS_INTERP = re.compile(r"\$\{(.+?)\}")


def normalise(text):
    """llhttp's test/md-test.ts, line for line."""
    # `\Z`, not `$`: llhttp's JS regex `/\n$/` matches only at the very end,
    # while Python's `$` ALSO matches just before a trailing newline — so `$`
    # here ate two newlines instead of one, and every fixture arrived one CRLF
    # short of ending its headers.
    text = re.sub(r"\n\Z", "", text)
    text = re.sub(r"\\(\r\n|\r|\n)", "", text)      # escaped line continuation
    text = re.sub(r"\r\n|\r|\n", "\r\n", text)      # every ending is CRLF
    text = text.replace("\\r", "\r").replace("\\n", "\n")
    text = text.replace("\\t", "\t").replace("\\f", "\f")
    text = re.sub(r"\\x([0-9a-fA-F]+)", lambda m: chr(int(m.group(1), 16)), text)
    text = re.sub(r"\\([0-7]{1,3})", lambda m: chr(int(m.group(1), 8)), text)
    return text


def unescape_span(s):
    """A span's payload in the log is a JS string literal body."""
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            e = s[i + 1]
            if e == "r": out.append("\r"); i += 2; continue
            if e == "n": out.append("\n"); i += 2; continue
            if e == "t": out.append("\t"); i += 2; continue
            if e == "f": out.append("\f"); i += 2; continue
            if e == "x":
                out.append(chr(int(s[i + 2:i + 4], 16))); i += 4; continue
            out.append(e); i += 2; continue
        out.append(c)
        i += 1
    return "".join(out)


def parse_md(path):
    """One test per input/log PAIR — not per heading.

    The first cut of this grouped by `## `, and that was wrong in a way worth
    recording: the fixtures nest, `### Setting flag` and `### Restarting when
    keep-alive is explicit` living under one `## keep-alive`, each with its own
    input and its own log. Grouping by the outer heading collected several
    inputs and several logs under one name and then compared the first of each —
    so most of the corpus was being read as a different corpus.

    Streaming instead: whatever heading was seen last names the test, and a
    ```log block CLOSES one, pairing with the input that came before it.
    """
    raw = open(path, encoding="utf-8").read().split("\n")
    tests = []
    name, line_no = "", 0
    meta, pending_in, cur, lang = None, None, None, None
    for i, line in enumerate(raw):
        if re.match(r"^#{1,6} ", line):
            name, line_no = line.lstrip("# ").strip(), i + 1
            continue
        m = re.match(r"<!--\s*meta=(\{.*\})\s*-->", line)
        if m:
            try:
                meta = json.loads(m.group(1))
            except ValueError:
                meta = None
            continue
        m = re.match(r"^```(\w*)\s*$", line)
        if m:
            if cur is None:
                cur, lang = [], m.group(1)
            else:
                # every line inside a fence is newline-TERMINATED; joining with
                # newlines instead loses the last one, and the last one of an
                # HTTP fixture is half of the CRLFCRLF that ends the headers
                body = "\n".join(cur) + "\n"
                if lang in ("http", "url"):
                    pending_in = (lang, body)
                elif lang == "log" and pending_in is not None:
                    tests.append((name, line_no, meta, pending_in, body))
                    pending_in, meta = None, None
                cur = None
            continue
        if cur is not None:
            cur.append(line)
    return tests


def digest_log(log):
    """The log's events, reduced to what a request/response object can state.

    PER MESSAGE. A keep-alive connection carries several, and llhttp's spans
    just keep coming — reading them as one message turns two `PUT`s into a
    method named `PUTPUT`. Each message is prefixed `m0 `, `m1 `, … and our
    side restarts its parser on the same boundary.

    Header values are STRIPPED of surrounding whitespace. llhttp reports byte
    SPANS — what is on the wire, tab and all — while a parser reports a value,
    and RFC 9112 §5 says the optional whitespace around a field value is not
    part of it. Trimming both sides compares the parse, not the reporting.
    """
    out = []
    state = {"msg": 0, "spans": {}, "headers": [], "field": None, "status": None}

    def flush(complete):
        spans, headers = state["spans"], state["headers"]
        if not spans and not headers and not complete:
            return
        pre = "m%d " % state["msg"]
        if "method" in spans:
            out.append(pre + "method=" + spans["method"])
        if "url" in spans:
            out.append(pre + "url=" + spans["url"])
        if "protocol" in spans:
            out.append(pre + "protocol=" + spans["protocol"])
        if "version" in spans:
            out.append(pre + "version=" + spans["version"])
        if state["status"]:           # the CODE, which only `headers complete` states
            out.append(pre + "status=" + state["status"])
        if "status" in spans:         # `span[status]` is the REASON phrase
            out.append(pre + "reason=" + spans["status"].strip())
        for f, v in headers:
            out.append(pre + "header:" + f.lower() + "=" + v.strip())
        if "body" in spans:
            out.append(pre + "body=" + spans["body"].encode("utf-8", "surrogateescape").hex())
        if complete:
            out.append(pre + "complete")
        state["spans"], state["headers"], state["field"], state["status"] = {}, [], None, None

    for line in log.split("\n"):
        line = line.strip()
        if not line:
            continue
        if "message begin" in line:
            continue
        m = re.match(r'off=\d+ len=\d+ span\[(\w+)\]="(.*)"$', line)
        if m:
            k, v = m.group(1), unescape_span(m.group(2))
            state["spans"][k] = state["spans"].get(k, "") + v
            continue
        m = re.match(r"off=\d+ (\w+) complete", line)
        if m:
            k = m.group(1)
            if k == "header_field":
                state["field"] = state["spans"].pop("header_field", "")
            elif k == "header_value":
                state["headers"].append((state["field"] or "",
                                         state["spans"].pop("header_value", "")))
                state["field"] = None
            elif k == "headers":
                # NOT the `v=1/1` here: that fires at the END of the headers,
                # and our parser knows the version the moment it has read the
                # start line — `span[version]` fires there, the same timing. The
                # status CODE is the exception; it appears nowhere else, so it
                # keeps llhttp's timing and our side gates it the same way.
                s = re.search(r"status=(\d+)", line)
                if s:
                    state["status"] = s.group(1)
            elif k == "message":
                flush(True)
                state["msg"] += 1
            continue
        if re.search(r"off=\d+ error code=", line):
            flush(False)
            out.append("error")
            return out
    flush(False)
    return out


def main():
    root = sys.argv[1]
    show_skipped = "--list-skipped" in sys.argv
    kept = skipped = 0
    reasons = {}
    for sub in ("request", "response"):
        d = os.path.join(root, sub)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".md"):
                continue
            path = os.path.join(d, fn)
            for name, line, meta, pending_in, log in parse_md(path):
                lang, src = pending_in
                if lang != "http":
                    continue
                ty = (meta or {}).get("type") or ""
                cid = "%s/%s:%d %s" % (sub, fn[:-3], line, name)
                if not meta or SKIP_TYPE.search(ty):
                    skipped += 1
                    reasons[cid] = ty or "no type metadata"
                    continue
                if JS_INTERP.search(src):
                    skipped += 1
                    reasons[cid] = "inline JavaScript in the input"
                    continue
                data = normalise(src).encode("utf-8", "surrogateescape")
                want = digest_log(log)
                print("CASE " + cid)
                print("KIND " + ("response" if sub == "response" else "request"))
                print("INPUT " + data.hex())
                for w in want:
                    print("WANT " + w)
                print("END")
                kept += 1
    print("# kept=%d skipped=%d" % (kept, skipped), file=sys.stderr)
    if show_skipped:
        for k, v in sorted(reasons.items()):
            print("# skip %-60s %s" % (k, v), file=sys.stderr)


main()
