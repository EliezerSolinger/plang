"""Cliente MySQL/MariaDB: o protocolo cliente-servidor, sobre a `net` do pscript.

Porte de `pymysql/connections.py`. O que o Python faz síncrono e bloqueante, aqui
é `async`: cada `read_exact` do socket ESTACIONA a tarefa (77.1), então uma
query não trava a thread — várias conexões convivem no mesmo escalonador, que é o
que o servidor de jogo precisa. É o "NIO" do pscript (baterias 135-143) posto a
trabalhar.

O que este módulo cobre, e é o que um servidor de jogo usa:

  * o aperto de mão e o login por `mysql_native_password` (o plugin padrão do
    MariaDB);
  * `query(sql)` que devolve um `Result` — as colunas e as linhas, cada valor
    como `bytes` (a conversão para número/data é de quem sabe o tipo da coluna);
  * `execute(sql)` para INSERT/UPDATE/DELETE, com `affected_rows` e `insert_id`;
  * o pacote de erro do servidor vira uma exceção com a mensagem e o código.

O que fica de fora, dito onde entraria: `caching_sha2_password` e `ed25519`
(outros plugins de auth), prepared statements (COM_STMT_*), TLS, e a compressão.
"""

import net
import <mysql/packet.psc> as pkt
import <mysql/auth.psc> as auth
import <mysql/escape.psc> as esc


const MAX_PACKET_LEN = 16777215     # 2^24 - 1

# ── flags de capacidade do cliente (constants/CLIENT.py) ──────────────────────
const CLIENT_LONG_PASSWORD  = 1
const CLIENT_LONG_FLAG      = 4
const CLIENT_CONNECT_WITH_DB = 8
const CLIENT_PROTOCOL_41    = 512
const CLIENT_TRANSACTIONS   = 8192
const CLIENT_SECURE_CONNECTION = 32768
const CLIENT_MULTI_RESULTS  = 131072
const CLIENT_PLUGIN_AUTH    = 524288
const CLIENT_PLUGIN_AUTH_LENENC = 2097152

# o mesmo conjunto que o pymysql manda por padrão, menos o CONNECT_ATTRS (que é
# enfeite de telemetria e não muda o login)
const DEFAULT_CAPS = (CLIENT_LONG_PASSWORD | CLIENT_LONG_FLAG | CLIENT_PROTOCOL_41
                      | CLIENT_TRANSACTIONS | CLIENT_SECURE_CONNECTION
                      | CLIENT_MULTI_RESULTS | CLIENT_PLUGIN_AUTH
                      | CLIENT_PLUGIN_AUTH_LENENC)

const COM_QUERY = 0x03
const COM_QUIT  = 0x01
const COM_PING  = 0x0E
const COM_INIT_DB = 0x02

const UTF8MB4_ID = 45      # o charset_nr de utf8mb4_general_ci


struct Field:
    """A descrição de uma coluna de um resultado."""
    name: str
    type_code: int
    charsetnr: int
    flags: int


struct Result:
    """O que uma query devolve. Para um SELECT, `fields` e `rows` (cada valor é
    `bytes?` — None é o NULL de SQL). Para um INSERT/UPDATE, `affected_rows` e
    `insert_id`."""
    fields: List<Field>
    rows: List<List<bytes?>>
    affected_rows: int
    insert_id: int

    def column(self, name: str) -> int:
        """O índice da coluna com este nome, ou -1."""
        i = 0
        while i < len(self.fields):
            if self.fields[i].name == name:
                return i
            i += 1
        return -1


struct Connection:
    sock: Socket
    seq: int              # o número de sequência do próximo pacote
    caps: int             # as capacidades do SERVIDOR, lidas no handshake
    salt: bytes
    server_version: str
    auth_plugin: str
    closed: bool

    # ── a camada de transporte: pacotes com cabeçalho de 4 bytes ──────────────

    async def read_exact(self, n: int) -> bytes:
        """Exatamente `n` bytes do socket, esperando o quanto for preciso. A
        `read_into` do runtime dá ATÉ n (semântica de recv), então o laço aqui é
        o que transforma um fluxo num pacote. Zero bytes de volta é o outro lado
        fechando, e no meio de um pacote isso é conexão perdida."""
        out: List<u8> = []
        with Buffer(n if n < 65536 else 65536) as rb:
            while len(out) < n:
                want = n - len(out)
                chunk = want if want < 65536 else 65536
                got = await self.sock.read_into(rb, 0, chunk)
                if got == 0:
                    self.closed = True
                    raise error("conexão perdida ao ler do MySQL")
                piece = bytes(rb[0:got])
                j = 0
                while j < got:
                    out.append(piece[j])
                    j += 1
        return bytes(out)

    async def read_packet(self) -> pkt.Packet:
        """Um pacote inteiro: o cabeçalho de 4 bytes (3 de tamanho, 1 de
        sequência) e a carga. Um pacote de 16 MB é continuado no próximo — o laço
        junta os pedaços, como o protocolo manda."""
        payload: List<u8> = []
        while True:
            header = await self.read_exact(4)
            length = int(header[0]) | (int(header[1]) << 8) | (int(header[2]) << 16)
            self.seq = (int(header[3]) + 1) % 256
            part = await self.read_exact(length)
            k = 0
            while k < len(part):
                payload.append(part[k])
                k += 1
            if length < MAX_PACKET_LEN:
                break
        p = pkt.new_packet(bytes(payload))
        if p.is_error_packet():
            raise_error(p)
        return p

    async def write_packet(self, payload: bytes):
        """Escreve um pacote com o cabeçalho. O número de sequência anda a cada
        pacote, e o servidor recusa um fora de ordem."""
        header: List<u8> = []
        n = len(payload)
        header.append(u8(n & 0xFF))
        header.append(u8((n >> 8) & 0xFF))
        header.append(u8((n >> 16) & 0xFF))
        header.append(u8(self.seq))
        self.seq = (self.seq + 1) % 256
        full: List<u8> = []
        h = bytes(header)
        i = 0
        while i < len(h):
            full.append(h[i])
            i += 1
        j = 0
        while j < n:
            full.append(payload[j])
            j += 1
        await self.sock.write(bytes(full))

    # ── o comando: um COM_* zera a sequência e manda ──────────────────────────

    async def send_command(self, cmd: int, arg: bytes):
        self.seq = 0
        body: List<u8> = [u8(cmd)]
        i = 0
        while i < len(arg):
            body.append(arg[i])
            i += 1
        await self.write_packet(bytes(body))

    # ── queries ───────────────────────────────────────────────────────────────

    async def query(self, sql: str) -> Result:
        """Uma query, e o resultado inteiro na memória. Um SELECT devolve colunas
        e linhas; um comando sem resultado devolve `affected_rows`."""
        await self.send_command(COM_QUERY, bytes_of_str(sql))
        return await self.read_result()

    async def execute(self, sql: str) -> Result:
        """O mesmo que `query`, e o nome existe só para dizer no sítio da chamada
        que não se espera um resultado — a leitura é a mesma."""
        return await self.query(sql)

    async def query_str(self, sql: str, args: List<str>) -> Result:
        """Uma query com valores, e a ÚNICA forma segura de os pôr: cada `%s` no
        `sql` é substituído por um `args` ESCAPADO e entre aspas. Concatenar o
        valor à mão no SQL é injeção; este método existe para que ninguém precise.

        Os valores entram como `str` (o chamador chama `str(n)` num número), e
        cada um é escapado e aspado. O número de `%s` tem de bater com o de args."""
        return await self.query(format_query(sql, args))

    async def ping(self):
        await self.send_command(COM_PING, bytes([]))
        p = await self.read_packet()
        if not p.is_ok_packet():
            raise error("o MySQL não respondeu o ping com um OK")

    async def select_db(self, db: str):
        await self.send_command(COM_INIT_DB, bytes_of_str(db))
        p = await self.read_packet()
        if not p.is_ok_packet():
            raise error("não consegui trocar de banco")

    async def read_result(self) -> Result:
        first = await self.read_packet()
        if first.is_ok_packet():
            return read_ok(first)
        # senão é um result set: o primeiro pacote é o número de colunas
        ncoln = first.read_length_encoded_integer()
        if ncoln == None:
            raise error("resposta de query malformada")
        ncol = ncoln
        fields: List<Field> = []
        c = 0
        while c < ncol:
            fp = await self.read_packet()
            fields.append(parse_field(fp))
            c += 1
        # um EOF fecha a lista de colunas
        eof1 = await self.read_packet()
        if not eof1.is_eof_packet():
            raise error("esperava o EOF depois das colunas")
        # as linhas, até o EOF final
        rows: List<List<bytes?>> = []
        while True:
            rp = await self.read_packet()
            if rp.is_eof_packet():
                break
            row: List<bytes?> = []
            cc = 0
            while cc < ncol:
                row.append(rp.read_length_coded_string())
                cc += 1
            rows.append(row)
        return Result(fields, rows, len(rows), 0)

    async def close(self):
        if not self.closed:
            self.seq = 0
            body: List<u8> = [u8(COM_QUIT)]
            # o servidor fecha ao receber COM_QUIT; um erro de escrita aqui é o
            # socket já ido, e não há o que fazer com ele
            try:
                await self.write_packet(bytes(body))
            catch e:
                pass
            self.sock.close()
            self.closed = True


# ── funções livres: o handshake, e os pedaços que não precisam do self ────────

async def connect(host: str, port: int, user: str, password: str, db: str = "") -> Connection:
    """Abre a conexão, faz o aperto de mão e autentica. Devolve a `Connection`
    pronta para `query`."""
    sock = await net.connect(host, port)
    conn = Connection(sock, 0, 0, bytes([]), "", "", False)

    # 1. o servidor fala primeiro: o Initial Handshake
    hs = await conn.read_packet()
    parse_handshake(conn, hs)

    # 2. a resposta do cliente, com a prova da senha
    scramble = auth.scramble_native_password(bytes_of_str(password), conn.salt)
    resp = build_handshake_response(conn, user, scramble, db)
    await conn.write_packet(resp)

    # 3. o servidor responde OK, ErrPacket, ou pede troca de plugin
    reply = await conn.read_packet()
    if reply.is_ok_packet():
        return conn
    if reply.is_auth_switch_request():
        raise error("o servidor pediu troca de plugin de auth: só "
                    + "mysql_native_password está implementado por ora")
    if not reply.is_ok_packet():
        raise error("o login não foi aceito")
    return conn


private def parse_handshake(conn: Connection, p: pkt.Packet):
    """Lê o Initial Handshake v10 (o único que MySQL >= 4.1 manda)."""
    p.read_uint8()                    # protocol version (10)
    ver = p.read_string()                 # server version, terminada em NUL
    if ver != None:
        conn.server_version = str(ver)
    p.read_uint32()                   # thread id
    salt1 = p.read(8)                     # a primeira metade do salt
    p.read_uint8()                    # filler (0x00)
    caps_low = p.read_uint16()
    conn.caps = caps_low
    if p.remaining() >= 6:
        p.read_uint8()                # charset
        p.read_uint16()               # status
        caps_high = p.read_uint16()
        conn.caps = caps_low | (caps_high << 16)
        salt_len = p.read_uint8()
        # reservado: 10 bytes de zero
        p.read(10)
        # a segunda metade do desafio: `max(12, salt_len - 9)` bytes, e são TODOS
        # eles — o NUL terminador do campo está DEPOIS destes, não dentro. Tirar
        # um byte aqui (o engano que eu cometi) dá um salt de 19 e o servidor
        # recusa com "Access denied", sem dizer que o problema foi o desafio.
        take = salt_len - 9
        if take < 12:
            take = 12
        salt2 = p.read(take)
        combined: List<u8> = []
        i = 0
        while i < len(salt1):
            combined.append(salt1[i])
            i += 1
        j = 0
        while j < len(salt2):
            combined.append(salt2[j])
            j += 1
        conn.salt = bytes(combined)
        # o NUL terminador do campo do salt, agora consumido
        p.read(1)
        # o nome do plugin de auth, se veio
        pn = p.read_string()
        if pn != None:
            conn.auth_plugin = str(pn)
        else:
            conn.auth_plugin = "mysql_native_password"
    else:
        conn.salt = salt1


private def build_handshake_response(conn: Connection, user: str, scramble: bytes, db: str) -> bytes:
    """A Handshake Response 41: flags, tamanho máximo, charset, o usuário, a
    prova, e (se houver) o banco e o nome do plugin."""
    out: List<u8> = []
    client_flags = DEFAULT_CAPS
    if len(db) > 0:
        client_flags = client_flags | CLIENT_CONNECT_WITH_DB

    # 4 bytes de flags, little-endian
    append_u32(out, client_flags)
    # 4 bytes de tamanho máximo de pacote
    append_u32(out, MAX_PACKET_LEN)
    # 1 byte de charset
    out.append(u8(UTF8MB4_ID))
    # 23 bytes reservados, zero
    r = 0
    while r < 23:
        out.append(u8(0))
        r += 1
    # o usuário, terminado em NUL
    append_bytes(out, bytes_of_str(user))
    out.append(u8(0))
    # a prova, precedida do tamanho (lenenc, porque mandamos a flag)
    append_bytes(out, pkt.lenenc_int(len(scramble)))
    append_bytes(out, scramble)
    # o banco, se pedido
    if len(db) > 0:
        append_bytes(out, bytes_of_str(db))
        out.append(u8(0))
    # o nome do plugin
    append_bytes(out, bytes_of_str("mysql_native_password"))
    out.append(u8(0))
    return bytes(out)


private def parse_field(p: pkt.Packet) -> Field:
    """A metadados de uma coluna. Só os campos que interessam a quem lê o
    resultado; o resto (catalog, db, org_*) é lido e descartado."""
    p.read_length_coded_string()      # catalog ("def")
    p.read_length_coded_string()      # schema
    p.read_length_coded_string()      # table
    p.read_length_coded_string()      # org_table
    name = p.read_length_coded_string()
    p.read_length_coded_string()      # org_name
    p.read_length_encoded_integer()   # length of fixed fields (0x0c)
    charsetnr = p.read_uint16()
    p.read_uint32()                   # column length
    type_code = p.read_uint8()
    flags = p.read_uint16()
    nm = ""
    if name != None:
        nm = str(name)
    return Field(nm, type_code, charsetnr, flags)


private def read_ok(p: pkt.Packet) -> Result:
    """O OK Packet: affected_rows e insert_id, ambos length-encoded."""
    p.read_uint8()                    # o 0x00 do header
    aff = p.read_length_encoded_integer()
    ins = p.read_length_encoded_integer()
    a = aff ?? 0
    ii = ins ?? 0
    return Result([], [], a, ii)


private def raise_error(p: pkt.Packet):
    """Transforma um ErrPacket na exceção da linguagem, com o código e a
    mensagem que o servidor mandou."""
    p.read_uint8()                    # 0xFF
    code = p.read_uint16()
    # o SQLSTATE vem depois de um '#', em 6 bytes, quando o protocolo é 4.1
    rest = p.read_all()
    msg = ""
    if len(rest) > 0 and rest[0] == 0x23:      # '#'
        # pula '#' e os 5 do sqlstate
        tail = rest[6:len(rest)]
        msg = str(tail)
    else:
        msg = str(rest)
    raise error(f"MySQL {code}: {msg}")


# ── ajudantes de bytes ────────────────────────────────────────────────────────

def format_query(sql: str, args: List<str>) -> str:
    """Substitui cada `%s` do `sql` pelo próximo `args`, escapado e entre aspas.
    Um `%s` a mais ou a menos do que args levanta — um descompasso aqui é um
    valor perdido ou um literal `%s` chegando ao servidor."""
    out = ""
    ai = 0
    i = 0
    n = len(sql)
    while i < n:
        if i + 1 < n and sql[i] == "%" and sql[i + 1] == "s":
            if ai >= len(args):
                raise error("mais %s do que argumentos na query")
            out += esc.quote_string(args[ai])
            ai += 1
            i += 2
        elif i + 1 < n and sql[i] == "%" and sql[i + 1] == "%":
            out += "%"
            i += 2
        else:
            out += sql[i]
            i += 1
    if ai != len(args):
        raise error(f"a query tem {ai} %s mas vieram {len(args)} argumentos")
    return out


private def bytes_of_str(s: str) -> bytes:
    """Uma `str` como os seus bytes UTF-8 — o que atravessa o socket."""
    return bytes(s.encode())


private def append_bytes(out: List<u8>, b: bytes):
    i = 0
    while i < len(b):
        out.append(b[i])
        i += 1


private def append_u32(out: List<u8>, v: int):
    out.append(u8(v & 0xFF))
    out.append(u8((v >> 8) & 0xFF))
    out.append(u8((v >> 16) & 0xFF))
    out.append(u8((v >> 24) & 0xFF))
