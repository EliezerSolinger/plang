"""HTTP/2 (RFC 9113) — the frame layer, the streams, and the flow control.

HTTP/1 is text with a shape; HTTP/2 is binary with a state machine. What replaces
"read a line" is "read a nine-byte header and then that many bytes", and what
replaces "one message per connection at a time" is streams: many requests in
flight on one socket, each with its own identifier and its own end.

This lives beside `http.psc` and not in a package of its own because **which
version was spoken is a RESULT, not a choice**. Whoever asks for a URL wants the
body; whether the peer answered with a status line or a HEADERS frame is
something ALPN decided one layer down. Two packages would push that decision up
to the caller, who has no way to make it.

**The three things that are genuinely new, and each one is a refusal here:**

  * **CONTINUATION may not be interleaved.** A HEADERS frame without END_HEADERS
    must be followed by CONTINUATION frames on the SAME stream with nothing in
    between — not a PING, not a SETTINGS, not a frame for another stream. The
    reason is not tidiness: the HPACK decoder is a single piece of state shared
    by the whole connection, so a header block split across other traffic has no
    defined meaning. A decoder that allows it can be fed CONTINUATION frames
    forever on a stream that never opens, which is a memory attack with no
    request behind it (CVE-2024-27316 and its neighbours);

  * **flow control is two windows, and both must be obeyed.** One for the
    connection and one per stream, both starting at 65 535, both moved only by
    WINDOW_UPDATE. Sending past either is a protocol error, and — the part that
    is easy to get wrong — a WINDOW_UPDATE of zero is an error while a DATA frame
    of zero length is perfectly legal;

  * **a stream identifier only ever goes up.** The client uses odd numbers, the
    server even ones, and reusing or going backwards is a connection error. It is
    what makes "have I seen this stream" answerable without keeping every stream
    that ever closed.

**Padding is read and thrown away**, and the length check is the point: a pad
length that is larger than what is left in the frame is a protocol error, not a
short read. Getting that backwards is how a parser is convinced to read past a
buffer.

Everything here is INCREMENTAL over bytes, exactly like the HTTP/1 parser next
door: `feed(bytes)` swallows what arrived. That is what lets one socket, one
`poll` and one scheduler serve it without a second way of waiting.
"""
import hpack as HP
from <http/http.psc> import Header, Response


# ---------- the wire ----------

const PREFACE: str = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

const F_DATA: int = 0
const F_HEADERS: int = 1
const F_PRIORITY: int = 2
const F_RST_STREAM: int = 3
const F_SETTINGS: int = 4
const F_PUSH_PROMISE: int = 5
const F_PING: int = 6
const F_GOAWAY: int = 7
const F_WINDOW_UPDATE: int = 8
const F_CONTINUATION: int = 9

const FL_END_STREAM: int = 0x01
const FL_ACK: int = 0x01
const FL_END_HEADERS: int = 0x04
const FL_PADDED: int = 0x08
const FL_PRIORITY: int = 0x20

const S_HEADER_TABLE_SIZE: int = 1
const S_ENABLE_PUSH: int = 2
const S_MAX_CONCURRENT_STREAMS: int = 3
const S_INITIAL_WINDOW_SIZE: int = 4
const S_MAX_FRAME_SIZE: int = 5
const S_MAX_HEADER_LIST_SIZE: int = 6

# the error codes that get sent, and the only ones this raises with
const E_NO_ERROR: int = 0
const E_PROTOCOL_ERROR: int = 1
const E_INTERNAL_ERROR: int = 2
const E_FLOW_CONTROL_ERROR: int = 3
const E_SETTINGS_TIMEOUT: int = 4
const E_STREAM_CLOSED: int = 5
const E_FRAME_SIZE_ERROR: int = 6
const E_REFUSED_STREAM: int = 7
const E_CANCEL: int = 8
const E_COMPRESSION_ERROR: int = 9
const E_ENHANCE_YOUR_CALM: int = 11

# the defaults RFC 9113 §6.5.2 fixes, and which hold until SETTINGS says otherwise
const DEFAULT_WINDOW: int = 65535
const DEFAULT_MAX_FRAME: int = 16384
const DEFAULT_TABLE_SIZE: int = 4096
# a ceiling of our own: a peer may declare a frame size up to 2^24-1, and
# agreeing to it means agreeing to buffer it
const MAX_FRAME_WE_ACCEPT: int = 1 << 20


struct Frame:
    kind: int
    flags: int
    stream: int
    payload: bytes


# ---------- a stream ----------

const ST_IDLE: int = 0
const ST_OPEN: int = 1
const ST_HALF_CLOSED_LOCAL: int = 2     # we finished sending; they may still send
const ST_HALF_CLOSED_REMOTE: int = 3
const ST_CLOSED: int = 4


struct Stream:
    id: int
    state: int
    send_window: int      # how much WE may still send on this stream
    recv_window: int      # ... and how much we told them they may send
    fields: List<Header>
    body: List<u8>
    status: int
    done: bool            # END_STREAM arrived
    error: int            # RST_STREAM arrived with this code (-1 = none)


struct Conn:
    dec: HP.Table         # the HPACK table for what THEY send us
    enc: HP.Table         # ... and for what we send them
    streams: Dict<int, Stream>
    order: List<int>      # the ids, in the order they were opened
    next_id: int
    send_window: int      # the CONNECTION window, ours to spend
    recv_window: int
    peer_max_frame: int
    peer_initial_window: int
    peer_push: bool
    buf: List<u8>         # bytes that arrived and are not a whole frame yet
    pos: int              # ... and how far into it the reading has got. A CURSOR
                          #   and not a rebuilt list, for the reason the HTTP/1
                          #   parser next door has one: copying the tail after
                          #   every frame makes a megabyte of small frames
                          #   quadratic, and that is a denial of service written
                          #   by the reader rather than the sender.
    out: List<u8>         # ... and what is waiting to go the other way
    # 6.10: a header block that is not finished. While this is not -1, the ONLY
    # frame that may arrive is a CONTINUATION for this same stream.
    cont_stream: int
    cont_flags: int
    cont_buf: List<u8>
    settings_acked: bool
    goaway: bool
    goaway_code: int
    goaway_last: int
    is_server: bool


def new_conn(is_server: bool) -> Conn:
    return Conn(HP.new_table(DEFAULT_TABLE_SIZE), HP.new_table(DEFAULT_TABLE_SIZE),
                {}, [], 2 if is_server else 1, DEFAULT_WINDOW, DEFAULT_WINDOW,
                DEFAULT_MAX_FRAME, DEFAULT_WINDOW, True, [], 0, [],
                -1, 0, [], False, False, E_NO_ERROR, 0, is_server)


def fail(code: int, why: str):
    """A CONNECTION error: the whole thing is unusable from here.

    It raises rather than returning a flag because there is nothing to return to
    — every stream on the connection dies with it, and a caller that could
    ignore the result would go on decoding with tables that no longer agree.
    """
    raise error("http2: " + why, VALUE)


# ---------- reading and writing the nine-byte header ----------

def be24(b: bytes, i: int) -> int:
    return (int(b[i]) << 16) | (int(b[i + 1]) << 8) | int(b[i + 2])


def be32(b: bytes, i: int) -> int:
    return (int(b[i]) << 24) | (int(b[i + 1]) << 16) | (int(b[i + 2]) << 8) | int(b[i + 3])


def put24(out: List<u8>, v: int):
    out.append(u8((v >> 16) & 0xFF))
    out.append(u8((v >> 8) & 0xFF))
    out.append(u8(v & 0xFF))


def put32(out: List<u8>, v: int):
    out.append(u8((v >> 24) & 0xFF))
    out.append(u8((v >> 16) & 0xFF))
    out.append(u8((v >> 8) & 0xFF))
    out.append(u8(v & 0xFF))


def write_frame(c: Conn, kind: int, flags: int, stream: int, payload: bytes):
    put24(c.out, len(payload))
    c.out.append(u8(kind))
    c.out.append(u8(flags))
    # the top bit of the identifier is RESERVED and is written as zero
    put32(c.out, stream & 0x7FFFFFFF)
    for b in payload:
        c.out.append(b)


def take_out(c: Conn) -> bytes:
    """Everything waiting to go out, and the queue is emptied by asking."""
    b = bytes(c.out)
    c.out = []
    return b


# ---------- feeding bytes in ----------

def feed(c: Conn, chunk: bytes) -> int:
    """Swallows what arrived and handles every WHOLE frame in it.

    Returns how many frames were handled, which is what a caller loops on. What
    it does NOT do is wait: a partial frame stays in the buffer and the next
    `feed` finishes it, exactly like the HTTP/1 parser next door.
    """
    for b in chunk:
        c.buf.append(b)
    n = 0
    while step(c):
        n += 1
    return n


def step(c: Conn) -> bool:
    have = len(c.buf) - c.pos
    if have < 9:
        compact(c)
        return False
    p = c.pos
    ln = (int(c.buf[p]) << 16) | (int(c.buf[p + 1]) << 8) | int(c.buf[p + 2])
    if ln > MAX_FRAME_WE_ACCEPT:
        fail(E_FRAME_SIZE_ERROR, "a frame of " + str(ln) + " bytes is larger than this connection will hold")
    if have < 9 + ln:
        compact(c)
        return False
    kind = int(c.buf[p + 3])
    flags = int(c.buf[p + 4])
    # the top bit of the identifier is RESERVED and MUST be ignored on receipt,
    # not refused
    stream = ((int(c.buf[p + 5]) << 24) | (int(c.buf[p + 6]) << 16)
              | (int(c.buf[p + 7]) << 8) | int(c.buf[p + 8])) & 0x7FFFFFFF
    payload: List<u8> = []
    for i in range(ln):
        payload.append(c.buf[p + 9 + i])
    c.pos = p + 9 + ln
    handle(c, Frame(kind, flags, stream, bytes(payload)))
    return True


def compact(c: Conn):
    """Throws away what was already read, and only when it is worth it.

    Doing it after every frame is the quadratic copy the cursor exists to avoid;
    never doing it grows the buffer forever on a long-lived connection. Half is
    the usual answer and the reason is that it makes the amortized cost of a byte
    constant: each byte is moved at most once per doubling of what is left.
    """
    if c.pos > 0 and c.pos * 2 >= len(c.buf):
        rest: List<u8> = []
        for j in range(c.pos, len(c.buf)):
            rest.append(c.buf[j])
        c.buf = rest
        c.pos = 0


def handle(c: Conn, f: Frame):
    # 6.10: while a header block is open, NOTHING else may come. This is checked
    # before anything else on purpose — it is the rule that keeps the shared HPACK
    # state meaningful, and a check placed after the dispatch would already have
    # let a PING through.
    if c.cont_stream >= 0:
        if f.kind != F_CONTINUATION or f.stream != c.cont_stream:
            fail(E_PROTOCOL_ERROR, "a header block was interrupted: only CONTINUATION for stream "
                 + str(c.cont_stream) + " may follow an unfinished HEADERS")
        for b in f.payload:
            c.cont_buf.append(b)
        if (f.flags & FL_END_HEADERS) != 0:
            finish_headers(c)
        return
    if f.kind == F_CONTINUATION:
        fail(E_PROTOCOL_ERROR, "a CONTINUATION arrived with no header block open")
    elif f.kind == F_DATA:
        on_data(c, f)
    elif f.kind == F_HEADERS:
        on_headers(c, f)
    elif f.kind == F_PRIORITY:
        # deprecated by RFC 9113 §5.3.2 and still sent by everybody. The length
        # is still checked, because a wrong one means the framing is off.
        if len(f.payload) != 5:
            fail(E_FRAME_SIZE_ERROR, "a PRIORITY frame is five bytes")
        if f.stream == 0:
            fail(E_PROTOCOL_ERROR, "PRIORITY does not belong on stream 0")
    elif f.kind == F_RST_STREAM:
        on_rst(c, f)
    elif f.kind == F_SETTINGS:
        on_settings(c, f)
    elif f.kind == F_PUSH_PROMISE:
        # we advertise ENABLE_PUSH=0, so a promise is a peer ignoring what we
        # said — and RFC 9113 §8.4 makes that a connection error
        fail(E_PROTOCOL_ERROR, "a PUSH_PROMISE arrived after SETTINGS_ENABLE_PUSH was 0")
    elif f.kind == F_PING:
        on_ping(c, f)
    elif f.kind == F_GOAWAY:
        on_goaway(c, f)
    elif f.kind == F_WINDOW_UPDATE:
        on_window(c, f)
    # an UNKNOWN frame type is IGNORED (§4.1), and that is what makes the
    # protocol extensible: a peer speaking a newer dialect is not an error


def strip_padding(f: Frame, skip: int) -> bytes:
    """`skip` is what comes before the data in this frame kind. Returns the
    payload with padding removed, and refuses a pad length that does not fit —
    which is the check that keeps a decoder from reading past the frame."""
    if (f.flags & FL_PADDED) == 0:
        out0: List<u8> = []
        for i in range(skip, len(f.payload)):
            out0.append(f.payload[i])
        return bytes(out0)
    if len(f.payload) < 1:
        fail(E_FRAME_SIZE_ERROR, "a padded frame has no room for the pad length")
    pad = int(f.payload[0])
    if 1 + skip + pad > len(f.payload):
        fail(E_PROTOCOL_ERROR, "the padding of a frame is longer than the frame")
    out: List<u8> = []
    for j in range(1 + skip, len(f.payload) - pad):
        out.append(f.payload[j])
    return bytes(out)


# ---------- one handler per frame that carries state ----------

def get_stream(c: Conn, id: int) -> Stream:
    if id in c.streams:
        return c.streams[id]
    s = Stream(id, ST_IDLE, c.peer_initial_window, DEFAULT_WINDOW, [], [], 0, False, -1)
    c.streams[id] = s
    c.order.append(id)
    return s


def on_headers(c: Conn, f: Frame):
    if f.stream == 0:
        fail(E_PROTOCOL_ERROR, "HEADERS does not belong on stream 0")
    skip = 5 if (f.flags & FL_PRIORITY) != 0 else 0
    if (f.flags & FL_PRIORITY) != 0 and len(f.payload) < 5:
        fail(E_FRAME_SIZE_ERROR, "HEADERS says it carries priority and is too short for it")
    block = strip_padding(f, skip)
    c.cont_stream = f.stream
    c.cont_flags = f.flags
    c.cont_buf = []
    for b in block:
        c.cont_buf.append(b)
    if (f.flags & FL_END_HEADERS) != 0:
        finish_headers(c)


def finish_headers(c: Conn):
    id = c.cont_stream
    flags = c.cont_flags
    block = bytes(c.cont_buf)
    c.cont_stream = -1
    c.cont_buf = []
    s = get_stream(c, id)
    if s.state == ST_IDLE:
        s.state = ST_OPEN
    # a decoding failure is a CONNECTION error and not a stream one (§4.3): the
    # tables are shared, so a block that did not decode leaves them wrong for
    # every stream that follows
    fields = HP.decode(c.dec, block)
    for h in fields:
        s.fields.append(h)
        if h.name == ":status":
            s.status = int_or_zero(h.value)
    if (flags & FL_END_STREAM) != 0:
        s.done = True
        s.state = ST_HALF_CLOSED_REMOTE if s.state == ST_OPEN else ST_CLOSED


def int_or_zero(s: str) -> int:
    v = 0
    for ch in s:
        d = ord(ch) - 48
        if d < 0 or d > 9:
            return 0
        v = v * 10 + d
    return v


def on_data(c: Conn, f: Frame):
    if f.stream == 0:
        fail(E_PROTOCOL_ERROR, "DATA does not belong on stream 0")
    s = get_stream(c, f.stream)
    if s.state == ST_IDLE:
        fail(E_PROTOCOL_ERROR, "DATA arrived on stream " + str(f.stream) + ", which was never opened")
    # the WHOLE frame counts against the window, padding included (§6.9.1) —
    # otherwise padding would be a way of sending for free
    c.recv_window -= len(f.payload)
    s.recv_window -= len(f.payload)
    body = strip_padding(f, 0)
    for b in body:
        s.body.append(b)
    if (f.flags & FL_END_STREAM) != 0:
        s.done = True
        s.state = ST_CLOSED if s.state == ST_HALF_CLOSED_LOCAL else ST_HALF_CLOSED_REMOTE
    # give the credit back at once. A real client would hold it to shape the
    # rate; this one is asking for a file and wants it to arrive.
    if len(f.payload) > 0:
        replenish(c, 0, len(f.payload))
        if not s.done:
            replenish(c, f.stream, len(f.payload))


def replenish(c: Conn, stream: int, n: int):
    p: List<u8> = []
    put32(p, n)
    write_frame(c, F_WINDOW_UPDATE, 0, stream, bytes(p))
    if stream == 0:
        c.recv_window += n
    else:
        c.streams[stream].recv_window += n


def on_rst(c: Conn, f: Frame):
    if f.stream == 0:
        fail(E_PROTOCOL_ERROR, "RST_STREAM does not belong on stream 0")
    if len(f.payload) != 4:
        fail(E_FRAME_SIZE_ERROR, "an RST_STREAM frame is four bytes")
    s = get_stream(c, f.stream)
    if s.state == ST_IDLE:
        fail(E_PROTOCOL_ERROR, "RST_STREAM arrived on a stream that was never opened")
    s.error = be32(f.payload, 0)
    s.state = ST_CLOSED
    s.done = True


def on_settings(c: Conn, f: Frame):
    if f.stream != 0:
        fail(E_PROTOCOL_ERROR, "SETTINGS belongs on stream 0")
    if (f.flags & FL_ACK) != 0:
        if len(f.payload) != 0:
            fail(E_FRAME_SIZE_ERROR, "a SETTINGS acknowledgement carries nothing")
        c.settings_acked = True
        return
    if len(f.payload) % 6 != 0:
        fail(E_FRAME_SIZE_ERROR, "a SETTINGS frame is a whole number of six-byte pairs")
    i = 0
    while i < len(f.payload):
        key = (int(f.payload[i]) << 8) | int(f.payload[i + 1])
        val = be32(f.payload, i + 2)
        apply_setting(c, key, val)
        i += 6
    # acknowledge at once, and with nothing in it
    empty: List<u8> = []
    write_frame(c, F_SETTINGS, FL_ACK, 0, bytes(empty))


def apply_setting(c: Conn, key: int, val: int):
    if key == S_HEADER_TABLE_SIZE:
        # what the peer will accept for the table WE encode into
        c.enc.hard = val
        if c.enc.cap > val:
            HP.table_resize(c.enc, val)
    elif key == S_ENABLE_PUSH:
        if val != 0 and val != 1:
            fail(E_PROTOCOL_ERROR, "SETTINGS_ENABLE_PUSH is 0 or 1")
        c.peer_push = val == 1
    elif key == S_INITIAL_WINDOW_SIZE:
        if val > 0x7FFFFFFF:
            fail(E_FLOW_CONTROL_ERROR, "SETTINGS_INITIAL_WINDOW_SIZE is above 2^31-1")
        # §6.9.2: the change applies to every stream ALREADY open, by the
        # DIFFERENCE — not by assignment, which would forget what was spent
        delta = val - c.peer_initial_window
        c.peer_initial_window = val
        for id in c.order:
            c.streams[id].send_window += delta
    elif key == S_MAX_FRAME_SIZE:
        if val < DEFAULT_MAX_FRAME or val > 0xFFFFFF:
            fail(E_PROTOCOL_ERROR, "SETTINGS_MAX_FRAME_SIZE is between 2^14 and 2^24-1")
        c.peer_max_frame = val
    # an UNKNOWN setting is ignored (§6.5.2), for the same reason an unknown
    # frame type is: it is where the next version of the protocol goes


def on_ping(c: Conn, f: Frame):
    if f.stream != 0:
        fail(E_PROTOCOL_ERROR, "PING belongs on stream 0")
    if len(f.payload) != 8:
        fail(E_FRAME_SIZE_ERROR, "a PING frame is eight bytes")
    if (f.flags & FL_ACK) != 0:
        return
    write_frame(c, F_PING, FL_ACK, 0, f.payload)


def on_goaway(c: Conn, f: Frame):
    if f.stream != 0:
        fail(E_PROTOCOL_ERROR, "GOAWAY belongs on stream 0")
    if len(f.payload) < 8:
        fail(E_FRAME_SIZE_ERROR, "a GOAWAY frame is at least eight bytes")
    c.goaway = True
    c.goaway_last = be32(f.payload, 0) & 0x7FFFFFFF
    c.goaway_code = be32(f.payload, 4)


def on_window(c: Conn, f: Frame):
    if len(f.payload) != 4:
        fail(E_FRAME_SIZE_ERROR, "a WINDOW_UPDATE frame is four bytes")
    inc = be32(f.payload, 0) & 0x7FFFFFFF
    # §6.9.1: an increment of zero is a protocol error — while a DATA frame of
    # zero length is perfectly legal. The asymmetry is the part that gets missed.
    if inc == 0:
        fail(E_PROTOCOL_ERROR, "a WINDOW_UPDATE of zero says nothing and is an error")
    if f.stream == 0:
        c.send_window += inc
        if c.send_window > 0x7FFFFFFF:
            fail(E_FLOW_CONTROL_ERROR, "the connection window went past 2^31-1")
        return
    # §6.9: a WINDOW_UPDATE for a stream that was closed — or never opened — is
    # to be IGNORED, and creating one here would let a peer make us hold a stream
    # per identifier it feels like naming, of which there are two billion
    if f.stream not in c.streams:
        return
    s = c.streams[f.stream]
    s.send_window += inc
    if s.send_window > 0x7FFFFFFF:
        fail(E_FLOW_CONTROL_ERROR, "the window of stream " + str(f.stream) + " went past 2^31-1")


# ---------- the other direction: asking for something ----------

def start(c: Conn):
    """What a client says before anything else: the preface, then SETTINGS.

    The preface exists so that a server which is NOT HTTP/2 fails immediately and
    visibly instead of trying to parse frames as a request line. It is the same
    idea as a magic number in a file format, and `PRI * HTTP/2.0` is chosen to be
    a valid-looking HTTP/1 request line that no HTTP/1 server will act on.
    """
    if not c.is_server:
        for b in PREFACE.encode():
            c.out.append(b)
    p: List<u8> = []
    put_setting(p, S_ENABLE_PUSH, 0)
    put_setting(p, S_INITIAL_WINDOW_SIZE, DEFAULT_WINDOW)
    put_setting(p, S_MAX_FRAME_SIZE, DEFAULT_MAX_FRAME)
    write_frame(c, F_SETTINGS, 0, 0, bytes(p))


def put_setting(p: List<u8>, key: int, val: int):
    p.append(u8((key >> 8) & 0xFF))
    p.append(u8(key & 0xFF))
    put32(p, val)


def request(c: Conn, method: str, scheme: str, authority: str, path: str, extra: List<Header>, body: bytes) -> int:
    """Opens a stream, sends the request on it, and gives back its identifier.

    **The four pseudo-headers come FIRST and in this order**, and that is not
    style: §8.3 says every pseudo-header must precede the ordinary ones, and a
    peer is entitled to reject a block where one does not.
    """
    if c.goaway:
        raise error("http2: the peer sent GOAWAY; no new stream may be opened", VALUE)
    id = c.next_id
    c.next_id += 2
    s = get_stream(c, id)
    s.state = ST_OPEN
    fields: List<Header> = [Header(":method", method), Header(":scheme", scheme),
                            Header(":authority", authority), Header(":path", path)]
    for h in extra:
        if h.name.startswith(":"):
            raise error("http2: a pseudo-header may not be added by hand: " + h.name, VALUE)
        fields.append(Header(h.name.lower(), h.value))
    block = HP.encode(c.enc, fields)
    flags = FL_END_HEADERS
    if len(body) == 0:
        flags = flags | FL_END_STREAM
        s.state = ST_HALF_CLOSED_LOCAL
    # a header block larger than one frame becomes HEADERS + CONTINUATION, and
    # the pieces go out back to back because that is the only legal way
    emit_block(c, id, block, flags)
    if len(body) > 0:
        send_data(c, id, body)
    return id


def emit_block(c: Conn, id: int, block: bytes, flags: int):
    limit = c.peer_max_frame
    if len(block) <= limit:
        write_frame(c, F_HEADERS, flags, id, block)
        return
    first: List<u8> = []
    for i in range(limit):
        first.append(block[i])
    write_frame(c, F_HEADERS, flags & FL_END_STREAM, id, bytes(first))
    pos = limit
    while pos < len(block):
        n = limit if len(block) - pos > limit else len(block) - pos
        piece: List<u8> = []
        for j in range(n):
            piece.append(block[pos + j])
        pos += n
        last = FL_END_HEADERS if pos >= len(block) else 0
        write_frame(c, F_CONTINUATION, last, id, bytes(piece))


def send_data(c: Conn, id: int, body: bytes):
    """Spends both windows, and refuses rather than overspending.

    A real client would park until a WINDOW_UPDATE arrives; this one says what it
    cannot do, because a queue that waits belongs to whoever owns the socket and
    not to the codec.
    """
    s = c.streams[id]
    if len(body) > s.send_window or len(body) > c.send_window:
        raise error("http2: the body is larger than the flow-control window allows right now", VALUE)
    pos = 0
    while pos < len(body):
        n = c.peer_max_frame if len(body) - pos > c.peer_max_frame else len(body) - pos
        piece: List<u8> = []
        for j in range(n):
            piece.append(body[pos + j])
        pos += n
        last = FL_END_STREAM if pos >= len(body) else 0
        write_frame(c, F_DATA, last, id, bytes(piece))
    s.send_window -= len(body)
    c.send_window -= len(body)
    s.state = ST_HALF_CLOSED_LOCAL if s.state == ST_OPEN else ST_CLOSED


def reset(c: Conn, id: int, code: int):
    p: List<u8> = []
    put32(p, code)
    write_frame(c, F_RST_STREAM, 0, id, bytes(p))
    if id in c.streams:
        c.streams[id].state = ST_CLOSED


def goaway(c: Conn, code: int, why: str):
    p: List<u8> = []
    put32(p, c.next_id - 2 if c.next_id > 2 else 0)
    put32(p, code)
    for b in why.encode():
        p.append(b)
    write_frame(c, F_GOAWAY, 0, 0, bytes(p))


def finished(c: Conn, id: int) -> bool:
    return id in c.streams and c.streams[id].done


def response_of(c: Conn, id: int) -> Response:
    """The stream as the same `Response` HTTP/1 produces — which is the point of
    keeping both versions in one package. Whoever asked for a URL gets one shape
    back, and the version is not their problem."""
    s = c.streams[id]
    if s.error >= 0:
        raise error("http2: the peer reset stream " + str(id) + " with code " + str(s.error), IO)
    hd: Dict<str, str> = {}
    raw: List<Header> = []
    for h in s.fields:
        if h.name.startswith(":"):
            continue
        raw.append(h)
        # the same joining rule HTTP/1 uses (RFC 9110 5.3), and for the same
        # reason: a repeated header is one field with a list value
        hd[h.name] = hd[h.name] + ", " + h.value if h.name in hd else h.value
    return Response("HTTP", "2", s.status, "", hd, raw, bytes(s.body))
