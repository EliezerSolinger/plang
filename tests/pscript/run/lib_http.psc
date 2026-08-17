"""HTTP/1.1, written in pscript (77.2/78.1).

Nothing of anyone else's goes into the runtime. The test for what belongs there
is: does it need privileged access to the heap, the collector or the scheduler?
The collector, the scheduler, the pool, `poll`, the socket and DNS do. An HTTP
parser does not — it is a state machine over bytes, and it is better off here,
where whoever uses it reads and debugs it in the language they are writing.

llhttp is itself a state machine described in a TypeScript DSL that spits out
C. What is here is that same machine from the specification (RFC 9112), with
the robustness decisions it makes:

  * the request line is `METHOD SP TARGET SP HTTP/1.x CRLF`, and a target with
    a space in it is refused rather than guessed at;
  * a header name may not have a space before the colon — that is the classic
    request-smuggling trick;
  * `Content-Length` together with `Transfer-Encoding: chunked` is refused, for
    the same reason: two lengths disagreeing is how smuggling works;
  * a header name is lowercased, because the RFC says it is case-insensitive
    and a dict is not;
  * a lone `LF` is accepted as a line ending (every server accepts it), a lone
    `CR` is not.

It is INCREMENTAL: `feed(bytes)` swallows what arrived and says whether a whole
request can be read yet. That is how it serves a socket, where `read(n)` gives
back whatever is there (79.2) and almost never the whole message.
"""

# ---------- what comes out of the parser ----------

struct Request:
    method: str
    target: str
    version: str
    headers: dict<str, str>
    body: list<u8>

    def header(self, name: str) -> str:
        return self.headers[name] if name in self.headers else ""


enum HState:
    H_LINE = 0        # swallowing the request line
    H_HEADERS         # ... and the headers
    H_BODY            # a body whose length is known
    H_CHUNK_SIZE      # a chunked body: the size line
    H_CHUNK_DATA      # ... and the bytes of the chunk
    H_DONE
    H_ERROR


struct Parser:
    state: HState
    buf: list<u8>          # what arrived and has not been consumed yet
    pos: int               # how far into `buf` the reading has got
    method: str
    target: str
    version: str
    headers: dict<str, str>
    body: list<u8>
    need: int              # bytes still missing from the body (or the chunk)
    chunked: bool
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
    # and the line is read in five places here.)
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

    def feed(self, chunk: list<u8>) -> bool:
        """Swallows what arrived and says whether a whole request can be read."""
        for b in chunk:
            self.buf.append(b)
        return self.step()

    def step(self) -> bool:
        while True:
            if self.state == H_DONE or self.state == H_ERROR:
                return self.state == H_DONE

            if self.state == H_LINE:
                if not self.line():
                    return False
                l = self.last
                if len(l) == 0:
                    continue                  # blank lines before the request
                parts = l.split(" ")
                if len(parts) != 3:
                    return self.fail("malformed request line")
                self.method = parts[0]
                self.target = parts[1]
                self.version = parts[2]
                if len(self.method) == 0 or len(self.target) == 0:
                    return self.fail("malformed request line")
                if not self.version.startswith("HTTP/1."):
                    return self.fail("unsupported version: " + self.version)
                self.state = H_HEADERS

            elif self.state == H_HEADERS:
                if not self.line():
                    return False
                l2 = self.last
                if len(l2) == 0:
                    # end of the headers: what follows depends on them
                    has_len = "content-length" in self.headers
                    if self.chunked and has_len:
                        return self.fail("content-length and chunked at once")
                    if self.chunked:
                        self.state = H_CHUNK_SIZE
                    elif has_len:
                        self.need = int(self.headers["content-length"])
                        if self.need < 0:
                            return self.fail("negative content-length")
                        self.state = H_BODY if self.need > 0 else H_DONE
                    else:
                        self.state = H_DONE
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
                self.headers[key] = value
                if key == "transfer-encoding" and value.lower() == "chunked":
                    self.chunked = True

            elif self.state == H_BODY:
                have = len(self.buf) - self.pos
                take = have if have < self.need else self.need
                k2 = 0
                while k2 < take:
                    self.body.append(self.buf[self.pos + k2])
                    k2 += 1
                self.pos += take
                self.need -= take
                if self.need > 0:
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
                self.state = H_DONE if v == 0 else H_CHUNK_DATA

            elif self.state == H_CHUNK_DATA:
                have2 = len(self.buf) - self.pos
                take2 = have2 if have2 < self.need else self.need
                k3 = 0
                while k3 < take2:
                    self.body.append(self.buf[self.pos + k3])
                    k3 += 1
                self.pos += take2
                self.need -= take2
                if self.need > 0:
                    return False
                # the CRLF that closes the chunk
                if not self.line():
                    return False
                self.state = H_CHUNK_SIZE
        return False

    def request(self) -> Request:
        return Request(self.method, self.target, self.version, self.headers, self.body)


def new_parser() -> Parser:
    return Parser(H_LINE, [], 0, "", "", "", {}, [], 0, False, "", "")


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
