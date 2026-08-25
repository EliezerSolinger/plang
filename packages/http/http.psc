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
    headers: Dict<str, str>
    raw: List<Header>
    body: bytes

    def header(self, name: str) -> str:
        return self.headers[name] if name in self.headers else ""


struct Response:
    protocol: str
    version: str
    status: int
    reason: str
    headers: Dict<str, str>
    raw: List<Header>
    body: bytes

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
    H_HANDOFF         # (corpus) the connection stopped being HTTP/1 here: the
                      #   HTTP/2 preface. Terminal, and NOT complete — there is
                      #   no message to hand anybody, only a socket.
    H_DONE
    H_ERROR


struct Parser:
    state: HState
    is_response: bool
    buf: List<u8>          # what arrived and has not been consumed yet
    pos: int               # how far into `buf` the reading has got
    method: str
    target: str
    protocol: str
    version: str
    status: int
    reason: str
    headers: Dict<str, str>
    raw: List<Header>
    body: List<u8>
    need: int              # bytes still missing from the body (or the chunk)
    chunked: bool
    seen_length: bool      # a `content-length` was already given
    length: int
    te: List<str>          # the transfer codings, in the order they were given,
                           #   across every `transfer-encoding` header (6.1)
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
                if i == self.pos or self.buf[i - 1] != 13:
                    # (corpus) A BARE LF IS NOT A LINE ENDING EITHER, and this
                    # reverses what this file used to say. "every server accepts
                    # it" was true and beside the point: the argument against the
                    # bare CR is word for word the argument against the bare LF,
                    # because the attack is not about which byte it is —
                    #
                    #     Host: x<LF>Transfer-Encoding: chunked
                    #
                    # is one header to a hop that requires CRLF and two to a hop
                    # that does not, and one of them then reads a body the other
                    # reads as a second request. llhttp refuses it in strict mode
                    # for exactly this reason and offers leniency as an explicit
                    # opt-in for talking to old clients, which is a debt taken on
                    # deliberately rather than a default.
                    self.fail("a bare LF is not a line ending")
                    return False
                stop = i - 1
                raw: List<u8> = []
                k = self.pos
                while k < stop:
                    raw.append(self.buf[k])
                    k += 1
                self.pos = i + 1
                self.last = str(raw)
                return True
            if c == 13:
                if i + 1 >= n:
                    return False              # a CR that may yet be a CRLF
                if self.buf[i + 1] != 10:
                    # (corpus) A BARE CR IS NOT A LINE ENDING, and this is not
                    # pedantry — it is the request-smuggling payload. RFC 9112
                    # §2.2 lets a recipient accept a bare LF and forbids reading
                    # a bare CR as a terminator, and the reason is that middle
                    # boxes disagree about it: given
                    #
                    #     x:<CR>Transfer-Encoding: chunked
                    #
                    # a parser that ends the line at the CR sees a header `x`
                    # and NO transfer-encoding, while one that does not sees
                    # both. Two hops reading the same bytes as different
                    # requests is the whole attack. Refusing is the only answer
                    # that cannot be exploited.
                    self.fail("a bare CR is not a line ending")
                    return False
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
        # (corpus) EXACTLY one digit, a dot, one digit — `HTTP/01.1`, `HTTP/11.1`
        # and `HTTP/1.01` are all refused. A parser that reads the number
        # loosely and one that does not disagree about which version they are
        # speaking, and the version decides whether the connection persists.
        if len(self.version) != 3 or self.version[1] != ".":
            return self.fail("a version is one digit, a dot and one digit: " + tok)
        a = ord(self.version[0])
        b = ord(self.version[2])
        if a < 48 or a > 57 or b < 48 or b > 57:
            return self.fail("a version is one digit, a dot and one digit: " + tok)
        if self.version[0] != "1" and self.version[0] != "0":
            return self.fail("unsupported version: " + tok)
        return True

    def feed(self, chunk: bytes) -> bool:
        """Swallows what arrived and says whether a whole message can be read.

        What comes IN is `bytes` — that is what a read gives (135.2) — and what
        it lands in is a `List<u8>`, because the parser accumulates across calls
        and a list is what accumulates (135.6)."""
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
        # (corpus) The value has to FIT, and the bound is checked while reading
        # rather than after: a length nobody can represent is a length two hops
        # will disagree about, which is the same disagreement smuggling lives in.
        # 2^53 is the ceiling llhttp uses; anything a body could really be is far
        # below it.
        v = 0
        for ch in value:
            c = ord(ch)
            if c < 48 or c > 57:
                return self.fail("a content-length that is not a number: " + value)
            if v > 900719925474099:
                return self.fail("a content-length that does not fit: " + value)
            v = v * 10 + (c - 48)
        self.length = v
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
            # (corpus) EXACTLY ONE SPACE after the version. `HTTP/1.1  200 OK`
            # is refused rather than tidied up: a parser that skips runs of
            # spaces and one that does not disagree about where the code starts,
            # and the code is what decides whether a body follows.
            rest = l[sp + 1:len(l)]
            sp2 = rest.find(" ")
            code = rest[0:sp2] if sp2 >= 0 else rest
            # the reason phrase may be empty and may itself begin with spaces;
            # llhttp reports it without the leading run, so the run goes here
            self.reason = rest[sp2 + 1:len(rest)].lstrip() if sp2 >= 0 else ""
            if len(code) != 3:
                return self.fail("a status code is three digits: " + code)
            for ch in code:
                c = ord(ch)
                if c < 48 or c > 57:
                    return self.fail("a status code is three digits: " + code)
            self.status = int(code)
            return True
        parts = l.split(" ")
        # (corpus) HTTP/0.9: a request line with no version at all. It is two
        # tokens, it has no headers and no body, and it is over as soon as it is
        # read. Supporting it is not nostalgia — a server that refuses it and one
        # that accepts it disagree about whether a connection carried a request,
        # and llhttp accepts it.
        if len(parts) == 2 and len(parts[0]) > 0 and len(parts[1]) > 0:
            self.method = parts[0]
            self.target = parts[1]
            if not self.target_ok():
                return False
            self.state = H_DONE
            return True
        if len(parts) != 3:
            return self.fail("malformed request line")
        self.method = parts[0]
        self.target = parts[1]
        if len(self.method) == 0 or len(self.target) == 0:
            return self.fail("malformed request line")
        if not self.target_ok():
            return False
        return self.take_version(parts[2])

    # (corpus) THE TARGET IS ASCII, and printable. RFC 3986 builds a URI out of a
    # fixed set of characters; a raw byte above 0x7E in a path is not a character
    # at all until somebody decides an encoding for it, and two hops deciding
    # differently is how the same request reaches two different resources.
    # Percent-encoding is how those bytes travel.
    def target_ok(self) -> bool:
        for ch in self.target:
            c = ord(ch)
            if c <= 0x20 or c >= 0x7F:
                return self.fail("a request target is printable ASCII")
        return True

    # What follows the headers is decided by the headers, and the rules differ
    # between the two directions: a REQUEST with no length has no body, while a
    # RESPONSE with no length has a body that ends with the connection.
    def after_headers(self) -> bool:
        # (corpus) TRANSFER-ENCODING, by RFC 9112 6.1, which is three rules and
        # each one closes a smuggling door:
        #
        #   * a message may not carry both a `transfer-encoding` and a
        #     `content-length` — two answers to "how long is the body";
        #   * `chunked` must be the LAST coding, because it is the one that
        #     delimits, and anything after it has no delimiter left;
        #   * a coding that is not `chunked` in last place leaves a REQUEST with
        #     no way to know where the body ends, and a request whose end cannot
        #     be found is refused rather than guessed at. A RESPONSE can end with
        #     the connection, so it may read to EOF.
        # (corpus) THESE DECIDE FIRST. A 1xx, a 204 or a 304 carries no body
        # whatever its headers say (RFC 9112 §6.3), so the transfer-encoding of a
        # `101 Switching Protocols` is not a description of a body — reading one
        # hands the next protocol's first bytes to whoever asked for the response.
        if self.is_response and (self.status < 200 or self.status == 204 or self.status == 304):
            self.state = H_DONE
            return True
        if len(self.te) > 0:
            if self.seen_length:
                return self.fail("both a content-length and a transfer-encoding")
            last = self.te[len(self.te) - 1]
            if len(last) == 0:
                return self.fail("an empty transfer-encoding")
            i = 0
            while i < len(self.te) - 1:
                if self.te[i] == "chunked":
                    # a REQUEST with chunked out of last place has no delimiter
                    # and is refused; a RESPONSE can always end with the
                    # connection, which is what 6.1 says to do here
                    if not self.is_response:
                        return self.fail("chunked has to be the last transfer-encoding")
                    self.state = H_DONE if self.closed else H_EOF_BODY
                    return True
                i += 1
            if last == "chunked":
                self.chunked = True
                self.state = H_CHUNK_SIZE
                return True
            if not self.is_response:
                return self.fail("a request with an undelimited body: " + last)
            self.state = H_DONE if self.closed else H_EOF_BODY
            return True
        # (corpus) `PRI * HTTP/1.1` is the HTTP/2 connection preface. There is no
        # HTTP/1 message here to complete — what follows is `SM\r\n\r\n` and
        # then binary frames — so the parser stops without answering yes.
        if not self.is_response and self.method == "PRI" and self.target == "*":
            self.state = H_HANDOFF
            return True
        # (corpus) CONNECT has no body either, whatever it says. What follows a
        # successful CONNECT is a TUNNEL — bytes for the other end, not a body
        # for this parser — so reading them as one would hand the tunnel's first
        # packet to whoever asked for the request.
        if not self.is_response and self.method == "CONNECT":
            self.state = H_DONE
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
            if self.state == H_DONE or self.state == H_ERROR or self.state == H_HANDOFF:
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
                # (corpus) ON SIGHT. A header line that begins with a space is
                # obs-fold and is refused (RFC 9112 §5.2) — and it can be refused
                # from the first byte, without waiting for the rest of the line
                # to arrive. Waiting means a truncated fold reads as "still
                # thinking" where llhttp has already said no.
                if self.pos < len(self.buf):
                    f = self.buf[self.pos]
                    if f == 32 or f == 9:
                        return self.fail("a header may not be continued on the next line")
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
                # (corpus) OBS-FOLD IS GONE. A header line beginning with a
                # space or a tab used to CONTINUE the one before it (RFC 2616
                # §2.2); RFC 9112 §5.2 deprecated it and tells a server to
                # refuse. It is the same disagreement again — a hop that folds
                # and a hop that does not read different headers — and the shape
                # `Foo: bar<CRLF><SP>Content-Length: 38` is the exploit.
                if l2[0] == " " or l2[0] == "\t":
                    return self.fail("a header may not be continued on the next line")
                colon = l2.find(":")
                if colon <= 0:
                    return self.fail("header without a colon")
                name = l2[0:colon]
                # the space before the colon is a token violation like any other,
                # but it is THE smuggling trick, so it keeps its own message —
                # a diagnostic that names the attack is worth more than one that
                # names the grammar
                if name.endswith(" ") or name.endswith("\t"):
                    return self.fail("space before the colon")
                # (corpus) A NAME IS A TOKEN (RFC 9110 §5.1) — the tchar set and
                # nothing else. `Fo@:`, `en-US Content-Type:` and a name with a
                # control byte in it are not headers whose meaning is unclear;
                # they are bytes that two parsers will split differently.
                for ch in name:
                    if not is_tchar(ord(ch)):
                        return self.fail("a header name is a token: " + name)
                value = l2[colon + 1:len(l2)].strip()
                # (corpus) and the VALUE carries no control characters. A form
                # feed or a NUL inside a value is refused rather than passed on
                # to whatever reads it next.
                for ch in value:
                    c2 = ord(ch)
                    if c2 < 32 and c2 != 9:
                        return self.fail("a control character in a header value")
                    if c2 == 127:
                        return self.fail("a control character in a header value")
                key = name.lower()
                # (corpus) CHECKED FIRST, then recorded. A `content-length` that
                # is a duplicate, or not a number, or too big, must not appear in
                # the message at all — reporting it and then failing says the
                # parser accepted something it did not.
                if key == "content-length":
                    if not self.take_length(value):
                        return False
                    if len(self.te) > 0:
                        return self.fail("both a content-length and a transfer-encoding")
                if key == "transfer-encoding":
                    # (corpus) CHECKED AS IT ARRIVES. Waiting for the end of the
                    # headers means recording a header that is about to be
                    # refused, which reads as "accepted, then failed" — and the
                    # empty value is refusable on sight.
                    if len(value.strip()) == 0:
                        return self.fail("an empty transfer-encoding")
                    if self.seen_length:
                        return self.fail("both a content-length and a transfer-encoding")
                self.add_header(key, value)
                if key == "transfer-encoding":
                    # every coding of every header, in order. `chunked` has to be
                    # the LAST one or the body has no delimiter at all (6.1), and
                    # that is a property of the whole list rather than of one
                    # header — so the list is what gets kept.
                    for part in value.split(","):
                        self.te.append(part.strip().lower())

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
                # (corpus) NO STRIPPING. `3 ` and `a ` are not chunk sizes: a
                # trailing space means one parser reads 3 and another reads
                # nothing, and the length of a chunk is exactly the kind of
                # disagreement that smuggles a request through.
                v = hex_to_int(digits)
                if v < 0:
                    return self.fail("invalid chunk size")
                if semi >= 0 and not chunk_ext_ok(l3[semi + 1:len(l3)]):
                    return self.fail("a malformed chunk extension")
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

    # (corpus) MAY ANOTHER MESSAGE FOLLOW THIS ONE ON THE SAME CONNECTION?
    #
    # This is connection semantics rather than parsing, and it is the half llhttp
    # models that a message parser alone does not: HTTP/1.1 keeps the connection
    # unless `Connection: close`, HTTP/1.0 closes it unless `Connection:
    # keep-alive`, and `Connection: upgrade` hands what follows to another
    # protocol entirely. Bytes arriving after a message that said the connection
    # was over are not a second request — they are somebody's idea of a second
    # request, which is where two hops start disagreeing again.
    def keep_alive(self) -> bool:
        conn = self.headers["connection"].lower() if "connection" in self.headers else ""
        if "close" in conn:
            return False
        if self.hands_over():
            return False
        if self.version == "1.0":
            return "keep-alive" in conn
        return True

    # (corpus) DOES THIS MESSAGE HAND THE CONNECTION OVER? A CONNECT that
    # succeeded, or an `Upgrade`, means the bytes after it belong to another
    # protocol — a tunnel or a websocket — and they are not a second HTTP
    # message and not an error either. That distinction is the difference
    # between llhttp's `HPE_PAUSED_UPGRADE`, which is a handoff, and its "Data
    # after `Connection: close`", which is a refusal. Reading the first as the
    # second turns a working websocket handshake into a rejected request.
    def hands_over(self) -> bool:
        conn = self.headers["connection"].lower() if "connection" in self.headers else ""
        if "upgrade" in conn:
            return True
        if not self.is_response and self.method == "CONNECT":
            return True
        # (corpus) `PRI * HTTP/1.1` is the HTTP/2 connection preface, and what
        # follows it is `SM\r\n\r\n` and then HTTP/2 frames. An HTTP/1 parser
        # that reads on treats binary frames as requests, which is a protocol
        # downgrade with a parser on the wrong side of it.
        if not self.is_response and self.method == "PRI" and self.target == "*":
            return True
        return self.is_response and self.status == 101

    # ... and it is HERE, at the boundary, that the accumulated list becomes
    # the value that crosses. One conversion, said out loud (135.6).
    def request(self) -> Request:
        return Request(self.method, self.target, self.protocol, self.version,
                       self.headers, self.raw, bytes(self.body))

    def response(self) -> Response:
        return Response(self.protocol, self.version, self.status, self.reason,
                        self.headers, self.raw, bytes(self.body))


def new_parser() -> Parser:
    return Parser(H_LINE, False, [], 0, "", "", "", "", 0, "", {}, [], [], 0,
                  False, False, 0, [], False, "", "")


def new_response_parser() -> Parser:
    p = new_parser()
    p.is_response = True
    return p


# RFC 9110 §5.6.2: the characters a token may be made of. Everything a header
# NAME is allowed to contain, and nothing else.
def is_tchar(c: int) -> bool:
    if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122):
        return True
    return c == 0x21 or c == 0x23 or c == 0x24 or c == 0x25 or c == 0x26 or c == 0x27 or c == 0x2A or c == 0x2B or c == 0x2D or c == 0x2E or c == 0x5E or c == 0x5F or c == 0x60 or c == 0x7C or c == 0x7E


# RFC 9112 §7.1.1: `chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS
# chunk-ext-val ] )`, where a value is a token or a QUOTED string. What this
# rejects is the shapes that are not that: a `;` with nothing after it, and a
# quoted value whose quote never closes — the second one because an unbalanced
# quote is where one parser keeps reading and another stops.
def chunk_ext_ok(ext: str) -> bool:
    if len(ext) == 0:
        return False
    i = 0
    n = len(ext)
    while i < n:
        # the name
        start = i
        while i < n and is_tchar(ord(ext[i])):
            i += 1
        if i == start:
            return False
        if i < n and ext[i] == "=":
            i += 1
            if i < n and ext[i] == "\"":
                i += 1
                closed = False
                while i < n:
                    if ext[i] == "\\" and i + 1 < n:
                        i += 2
                        continue
                    if ext[i] == "\"":
                        closed = True
                        i += 1
                        break
                    i += 1
                if not closed:
                    return False
            else:
                vs = i
                while i < n and is_tchar(ord(ext[i])):
                    i += 1
                if i == vs:
                    return False
        if i < n:
            if ext[i] != ";":
                return False
            i += 1
            if i >= n:
                return False
    return True


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
