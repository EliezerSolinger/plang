"""HTTP/1.1, written in pscript (77.2/78.1).

Nothing of anyone else's goes into the runtime. The test for what belongs there
is: does it need privileged access to the heap, the collector or the scheduler?
The collector, the scheduler, the pool, `poll`, the socket and DNS do. An HTTP
parser does not — it is a state machine over bytes, and it is better off here,
where whoever uses it reads and debugs it in the language they are writing.

llhttp is itself a state machine described in a TypeScript DSL that spits out
C. What is here is that same machine from the specification (RFC 9112), and it
is now MEASURED against llhttp's own fixtures — `bash tests/conformance/run.sh
http` runs the corpus node itself runs. Everything below marked `(corpus)` is a
rule this parser did not have until those fixtures asked for it.

The robustness decisions, and why each one is a refusal rather than a guess:

  * the request line is `METHOD SP TARGET SP HTTP/1.x CRLF`, and a target with
    a space in it is refused rather than guessed at;
  * a header name may not have a space before the colon — that is the classic
    request-smuggling trick;
  * `Content-Length` together with `Transfer-Encoding: chunked` is refused, for
    the same reason: two lengths disagreeing is how smuggling works;
  * (corpus) TWO `Content-Length` headers that disagree are refused, and even
    when they agree the duplicate is refused — same attack, one step further in;
  * (corpus) a `Content-Length` that is not all digits is refused, so that
    `Content-Length: 5, 5` and `Content-Length: +5` cannot mean five;
  * a header name is lowercased, because the RFC says it is case-insensitive
    and a dict is not;
  * (corpus) a repeated header is JOINED with `, ` in the dict (RFC 9110 §5.3)
    instead of the last one winning — and `raw` keeps every one of them, in
    arrival order, because `set-cookie` is the header that must NOT be joined;
  * a lone `LF` is accepted as a line ending (every server accepts it), a lone
    `CR` is not.

It is INCREMENTAL: `feed(bytes)` swallows what arrived and says whether a whole
message can be read yet. That is how it serves a socket, where `read(n)` gives
back whatever is there (79.2) and almost never the whole message. When the peer
closes, `finish()` says so — which is the only way a response with neither
`content-length` nor `chunked` can ever be complete.
"""

# ---------- what comes out of the parser ----------

# a `struct`, not a `record`: a record is a VALUE and holds only unboxed things
# (58.2), and both halves of a header are text
struct Header:
    name: str
    value: str


struct Request:
    method: str
    target: str
    protocol: str
    version: str
    headers: dict<str, str>
    raw: list<Header>
    body: list<u8>

    def header(self, name: str) -> str:
        return self.headers[name] if name in self.headers else ""


struct Response:
    protocol: str
    version: str
    status: int
    reason: str
    headers: dict<str, str>
    raw: list<Header>
    body: list<u8>

    def header(self, name: str) -> str:
        return self.headers[name] if name in self.headers else ""


enum HState:
    H_LINE = 0        # swallowing the start line
    H_HEADERS         # ... and the headers
    H_BODY            # a body whose length is known
    H_EOF_BODY        # a body that ends when the connection does
    H_CHUNK_SIZE      # a chunked body: the size line
    H_CHUNK_DATA      # ... and the bytes of the chunk
    H_TRAILER         # the headers that may follow the last chunk
    H_DONE
    H_ERROR


struct Parser:
    state: HState
    is_response: bool
    buf: list<u8>          # what arrived and has not been consumed yet
    pos: int               # how far into `buf` the reading has got
    method: str
    target: str
    protocol: str
    version: str
    status: int
    reason: str
    headers: dict<str, str>
    raw: list<Header>
    body: list<u8>
    need: int              # bytes still missing from the body (or the chunk)
    chunked: bool
    seen_length: bool      # a `content-length` was already given
    length: int
    closed: bool           # the peer hung up (`finish` was called)
    problem: str
    last: str              # the line `line()` most recently read

    # ---------- the pieces ----------

    def fail(self, msg: str) -> bool:
        self.state = H_ERROR
        self.problem = msg
        return False

    # The next line of `buf` from `pos`, without its ending. False when it has
    # not arrived whole yet; when it answers True the text is in `self.last`.
    # (A `str?` would be prettier and would ask for a narrowing at each call —
    # and the line is read in six places here.)
    def line(self) -> bool:
        i = self.pos
        n = len(self.buf)
        while i < n:
            c = self.buf[i]
            if c == 10:                       # LF
                stop = i
                if stop > self.pos and self.buf[stop - 1] == 13:
                    stop -= 1                 # CRLF
                raw: list<u8> = []
                k = self.pos
                while k < stop:
                    raw.append(self.buf[k])
                    k += 1
                self.pos = i + 1
                self.last = str(raw)
                return True
            if c == 13 and i + 1 >= n:
                return False                  # a CR that may yet be a CRLF
            i += 1
        return False

    # `HTTP/1.1` -> protocol `HTTP`, version `1.1`. Refused when it is neither.
    def take_version(self, tok: str) -> bool:
        slash = tok.find("/")
        if slash <= 0:
            return self.fail("a version needs a '/': " + tok)
        self.protocol = tok[0:slash]
        self.version = tok[slash + 1:len(tok)]
        if self.protocol != "HTTP":
            return self.fail("not HTTP: " + self.protocol)
        if not self.version.startswith("1."):
            return self.fail("unsupported version: " + tok)
        return True

    def feed(self, chunk: list<u8>) -> bool:
        """Swallows what arrived and says whether a whole message can be read."""
        for b in chunk:
            self.buf.append(b)
        return self.step()

    def finish(self) -> bool:
        """The peer closed. A body with no declared length ends exactly here."""
        self.closed = True
        if self.state == H_EOF_BODY:
            self.state = H_DONE
            return True
        return self.step()

    # (corpus) A header is added, not replaced. The dict joins repeats with
    # `, ` — which RFC 9110 §5.3 says is the same message — and `raw` keeps
    # each one apart, because `set-cookie` is exactly the header for which the
    # joined form is NOT equivalent.
    def add_header(self, name: str, value: str):
        h: Header = Header(name, value)
        self.raw.append(h)
        if name in self.headers:
            self.headers[name] = self.headers[name] + ", " + value
        else:
            self.headers[name] = value

    # (corpus) `Content-Length: 5x` must not mean five, and a second
    # `Content-Length` must not be a second opinion.
    def take_length(self, value: str) -> bool:
        if self.seen_length:
            return self.fail("content-length given twice")
        self.seen_length = True
        if len(value) == 0:
            return self.fail("an empty content-length")
        for ch in value:
            c = ord(ch)
            if c < 48 or c > 57:
                return self.fail("a content-length that is not a number: " + value)
        self.length = int(value)
        return True

    def start_line(self) -> bool:
        l = self.last
        if self.is_response:
            # `HTTP/1.1 200 OK`, and the reason phrase may be empty or absent
            sp = l.find(" ")
            if sp <= 0:
                return self.fail("malformed status line")
            if not self.take_version(l[0:sp]):
                return False
            rest = l[sp + 1:len(l)].strip()
            sp2 = rest.find(" ")
            code = rest[0:sp2] if sp2 > 0 else rest
            self.reason = rest[sp2 + 1:len(rest)] if sp2 > 0 else ""
            if len(code) != 3:
                return self.fail("a status code is three digits: " + code)
            for ch in code:
                c = ord(ch)
                if c < 48 or c > 57:
                    return self.fail("a status code is three digits: " + code)
            self.status = int(code)
            return True
        parts = l.split(" ")
        if len(parts) != 3:
            return self.fail("malformed request line")
        self.method = parts[0]
        self.target = parts[1]
        if len(self.method) == 0 or len(self.target) == 0:
            return self.fail("malformed request line")
        return self.take_version(parts[2])

    # What follows the headers is decided by the headers, and the rules differ
    # between the two directions: a REQUEST with no length has no body, while a
    # RESPONSE with no length has a body that ends with the connection.
    def after_headers(self) -> bool:
        if self.chunked and self.seen_length:
            return self.fail("content-length and chunked at once")
        if self.chunked:
            self.state = H_CHUNK_SIZE
            return True
        if self.is_response and (self.status < 200 or self.status == 204 or self.status == 304):
            self.state = H_DONE          # these carry no body, whatever they say
            return True
        if self.seen_length:
            self.need = self.length
            self.state = H_BODY if self.need > 0 else H_DONE
            return True
        if self.is_response:
            self.state = H_DONE if self.closed else H_EOF_BODY
            return True
        self.state = H_DONE
        return True

    def take_body(self, limit: int) -> int:
        have = len(self.buf) - self.pos
        take = have if have < limit else limit
        k = 0
        while k < take:
            self.body.append(self.buf[self.pos + k])
            k += 1
        self.pos += take
        return take

    def step(self) -> bool:
        while True:
            if self.state == H_DONE or self.state == H_ERROR:
                return self.state == H_DONE

            if self.state == H_LINE:
                if not self.line():
                    return False
                if len(self.last) == 0:
                    continue                  # blank lines before the message
                if not self.start_line():
                    return False
                self.state = H_HEADERS

            elif self.state == H_HEADERS or self.state == H_TRAILER:
                if not self.line():
                    return False
                l2 = self.last
                if len(l2) == 0:
                    if self.state == H_TRAILER:
                        self.state = H_DONE
                        continue
                    if not self.after_headers():
                        return False
                    continue
                colon = l2.find(":")
                if colon <= 0:
                    return self.fail("header without a colon")
                name = l2[0:colon]
                if name.endswith(" ") or name.endswith("\t"):
                    # the classic smuggling trick: a space before the `:`
                    return self.fail("space before the colon")
                value = l2[colon + 1:len(l2)].strip()
                key = name.lower()
                self.add_header(key, value)
                if key == "content-length":
                    if not self.take_length(value):
                        return False
                elif key == "transfer-encoding" and value.lower() == "chunked":
                    self.chunked = True

            elif self.state == H_BODY:
                self.need -= self.take_body(self.need)
                if self.need > 0:
                    return False
                self.state = H_DONE

            elif self.state == H_EOF_BODY:
                self.take_body(len(self.buf) - self.pos)
                if not self.closed:
                    return False
                self.state = H_DONE

            elif self.state == H_CHUNK_SIZE:
                if not self.line():
                    return False
                l3 = self.last
                # the size is hexadecimal and may carry extensions after `;`.
                # `find` answers -1 when there is none (P's `CStr.find` answers
                # the length instead; two conventions, worth knowing which)
                semi = l3.find(";")
                digits = l3[0:semi] if semi >= 0 else l3
                v = hex_to_int(digits.strip())
                if v < 0:
                    return self.fail("invalid chunk size")
                self.need = v
                self.state = H_TRAILER if v == 0 else H_CHUNK_DATA

            elif self.state == H_CHUNK_DATA:
                self.need -= self.take_body(self.need)
                if self.need > 0:
                    return False
                # the CRLF that closes the chunk
                if not self.line():
                    return False
                if len(self.last) != 0:
                    return self.fail("a chunk has to end with CRLF")
                self.state = H_CHUNK_SIZE
        return False

    def request(self) -> Request:
        return Request(self.method, self.target, self.protocol, self.version,
                       self.headers, self.raw, self.body)

    def response(self) -> Response:
        return Response(self.protocol, self.version, self.status, self.reason,
                        self.headers, self.raw, self.body)


def new_parser() -> Parser:
    return Parser(H_LINE, False, [], 0, "", "", "", "", 0, "", {}, [], [], 0,
                  False, False, 0, False, "", "")


def new_response_parser() -> Parser:
    p = new_parser()
    p.is_response = True
    return p


def hex_to_int(s: str) -> int:
    if len(s) == 0:
        return -1
    v = 0
    for ch in s:
        c = ord(ch)
        d = -1
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        if d < 0:
            return -1
        v = v * 16 + d
    return v


# ---------- the other direction: building a message ----------

def response(status: int, reason: str, kind: str, body: str) -> str:
    head = "HTTP/1.1 " + str(status) + " " + reason + "\r\n"
    head += "content-type: " + kind + "\r\n"
    head += "content-length: " + str(len(body)) + "\r\n"
    head += "connection: close\r\n\r\n"
    return head + body


def request(method: str, target: str, host: str, body: str) -> str:
    r = method + " " + target + " HTTP/1.1\r\n"
    r += "host: " + host + "\r\n"
    if len(body) > 0:
        r += "content-length: " + str(len(body)) + "\r\n"
    r += "connection: close\r\n\r\n"
    return r + body
