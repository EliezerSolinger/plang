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
import <datetime/datetime.psc> as dt
import <ed25519/ed25519.ph>


const MAX_PACKET_LEN = 16777215     # 2^24 - 1

# ── flags de capacidade do cliente (constants/CLIENT.py) ──────────────────────
const CLIENT_LONG_PASSWORD  = 1
const CLIENT_LONG_FLAG      = 4
const CLIENT_CONNECT_WITH_DB = 8
const CLIENT_PROTOCOL_41    = 512
const CLIENT_TRANSACTIONS   = 8192
const CLIENT_SSL            = 2048
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
const SERVER_MORE_RESULTS = 8   # SERVER_STATUS: há outro result set a seguir

# ── os tipos de coluna (constants/FIELD_TYPE.py) ──────────────────────────────
# O que decide para que tipo pscript um valor de texto do servidor vira. Só os
# que aparecem numa tabela real; o resto cai no ramo `str`.
const FIELD_DECIMAL    = 0
const FIELD_TINY       = 1
const FIELD_SHORT      = 2
const FIELD_LONG       = 3
const FIELD_FLOAT      = 4
const FIELD_DOUBLE     = 5
const FIELD_NULL       = 6
const FIELD_TIMESTAMP  = 7
const FIELD_LONGLONG   = 8
const FIELD_INT24      = 9
const FIELD_DATE       = 10
const FIELD_TIME       = 11
const FIELD_DATETIME   = 12
const FIELD_YEAR       = 13
const FIELD_NEWDECIMAL = 246
const FIELD_TINY_BLOB   = 249
const FIELD_MEDIUM_BLOB = 250
const FIELD_LONG_BLOB   = 251
const FIELD_BLOB        = 252
const FIELD_VAR_STRING  = 253
const FIELD_STRING      = 254

# charsetnr 63 é `binary`: um BLOB de verdade, e não texto. É o que separa um
# TEXT de um BLOB, que compartilham o type code.
const CHARSET_BINARY = 63


struct Field:
    """A descrição de uma coluna de um resultado."""
    name: str
    type_code: int
    charsetnr: int
    flags: int


struct Row:
    """Uma linha de resultado, acessada por NOME de coluna — é como o código do
    jogo lê (`row.get_int("level")`), e não por índice.

    A linha guarda os bytes CRUS de cada coluna e converte sob demanda: `get`
    devolve o tipo que a coluna promete (INT→int, DOUBLE→float, DATETIME→uma
    data, TEXT/JSON/ENUM→str), como `any?` — carrega o seu tipo, e `None` é o
    NULL de SQL. `raw` devolve os bytes sem conversão, para um BLOB binário ou
    para quem quer o texto exato.

    Os métodos tipados (`get_int`, `get_str`, `get_float`, `get_datetime`) são o
    atalho para o caso comum, e levantam se a coluna não existe ou é NULL —
    porque um `level` que falta é defeito, não um zero silencioso."""
    fields: List<Field>
    raws: List<bytes?>

    def column(self, name: str) -> int:
        i = 0
        while i < len(self.fields):
            if self.fields[i].name == name:
                return i
            i += 1
        return -1

    def raw(self, name: str) -> bytes?:
        """Os bytes crus da coluna, sem conversão nenhuma. É a porta para um
        BLOB binário (que não cabe num `any` ainda) e para quem quer o texto
        exato que o servidor mandou."""
        i = self.column(name)
        if i < 0:
            raise error(f"a query não tem a coluna '{name}'")
        return self.raws[i]

    def get(self, name: str) -> any?:
        """O valor da coluna já no tipo dela, `any?`. `None` se é NULL; levanta
        se o nome não existe (um nome errado é engano de quem escreveu a query)."""
        i = self.column(name)
        if i < 0:
            raise error(f"a query não tem a coluna '{name}'")
        return convert_value(self.raws[i], self.fields[i])

    def at(self, i: int) -> any?:
        """O valor pela POSIÇÃO, para quem sabe a ordem das colunas."""
        return convert_value(self.raws[i], self.fields[i])

    def is_null(self, name: str) -> bool:
        return self.raw(name) == None

    def get_int(self, name: str) -> int:
        v = self.get(name)
        if v == None:
            raise error(f"a coluna '{name}' é NULL, não um int")
        return v as int

    def get_float(self, name: str) -> float:
        v = self.get(name)
        if v == None:
            raise error(f"a coluna '{name}' é NULL, não um float")
        return v as float

    def get_str(self, name: str) -> str:
        v = self.get(name)
        if v == None:
            raise error(f"a coluna '{name}' é NULL, não uma string")
        return v as str

    def get_bytes(self, name: str) -> bytes:
        """Os bytes crus, e o mesmo que `raw` — mas levanta no NULL, para o
        caso em que a ausência é defeito."""
        v = self.raw(name)
        if v == None:
            raise error(f"a coluna '{name}' é NULL, não bytes")
        return v

    def get_datetime(self, name: str) -> dt.LocalDateTime:
        """A coluna como uma data, parseada dos bytes crus — não passa pelo
        `any`, porque um `LocalDateTime` não cabe nele. Levanta no NULL e num
        valor que não é uma data ISO (o `0000-00-00` do MySQL, por exemplo)."""
        b = self.raw(name)
        if b == None:
            raise error(f"a coluna '{name}' é NULL, não uma data")
        d = dt.parse_datetime(str(b))
        if d == None:
            raise error(f"a coluna '{name}' não é uma data reconhecível: {str(b)}")
        return d


struct Result:
    """O que uma query devolve. Para um SELECT, `fields` (as colunas) e `rows`
    (cada uma um `Row`, com os valores já convertidos). Para um INSERT/UPDATE,
    `affected_rows` e `insert_id`."""
    fields: List<Field>
    rows: List<Row>
    affected_rows: int
    insert_id: int

    def one(self) -> Row?:
        """A primeira linha, ou `None` se não veio nenhuma — o `fetchone` do
        DB-API, para uma query que espera no máximo uma linha."""
        if len(self.rows) == 0:
            return None
        return self.rows[0]

    def scalar(self) -> any?:
        """O primeiro valor da primeira linha — o `SELECT COUNT(*)`, o
        `SELECT id WHERE ...`. `None` se não veio linha nenhuma."""
        if len(self.rows) == 0:
            return None
        return self.rows[0].at(0)


struct Cursor:
    """Um result set lido LINHA A LINHA, sem carregar tudo na memória. É o que
    um SELECT de milhões de linhas pede — o `query` normal junta tudo, e para um
    resultado que não cabe isso estoura.

    `next_row()` devolve a próxima linha ou `None` no fim. Enquanto o cursor
    está aberto, a conexão está OCUPADA com ele: não se pode mandar outra query
    até drenar (chamar `next_row` até `None`) ou fechar."""
    conn: Connection
    fields: List<Field>
    done: bool

    async def next_row(self) -> Row?:
        if self.done:
            return None
        rp = await self.conn.read_packet()
        if rp.is_eof_packet():
            self.done = True
            return None
        raws: List<bytes?> = []
        cc = 0
        while cc < len(self.fields):
            raws.append(rp.read_length_coded_string())
            cc += 1
        return Row(self.fields, raws)

    async def drain(self):
        """Lê o resto e descarta — para quando se parou no meio e se quer a
        conexão livre de novo."""
        while not self.done:
            r = await self.next_row()


struct Connection:
    sock: Socket
    seq: int              # o número de sequência do próximo pacote
    caps: int             # as capacidades do SERVIDOR, lidas no handshake
    salt: bytes
    server_version: str
    auth_plugin: str
    closed: bool
    status: int           # o SERVER_STATUS do último OK/EOF (o has_next mora aqui)

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

    async def execute_many(self, sql: str, rows: List<List<str>>) -> int:
        """O mesmo `sql` com `%s`, executado uma vez por linha de `rows`, e
        devolve o total de linhas afetadas. É o INSERT em lote — mais rápido que
        um `query_str` por linha porque não paga a ida e volta de cada um... por
        ora paga: manda um comando por linha. O caminho de um único INSERT com
        muitos `VALUES` fica para quando o perfil pedir.

        Numa transação (entre `begin` e `commit`), ou todas entram ou nenhuma."""
        total = 0
        for r in rows:
            res = await self.query_str(sql, r)
            total += res.affected_rows
        return total

    # ── transações ────────────────────────────────────────────────────────────
    # Um servidor de jogo escreve várias linhas que têm de valer JUNTAS: tirar um
    # item do inventário e pô-lo num baú são duas escritas que não podem existir
    # uma sem a outra. É o que a transação garante — ou as duas, ou nenhuma.

    async def begin(self):
        """Abre uma transação. O que vier até `commit` fica invisível para os
        outros e reversível por `rollback`."""
        await self.query("BEGIN")

    async def commit(self):
        """Confirma tudo desde o `begin`. A partir daqui é definitivo."""
        await self.send_command(COM_QUERY, bytes_of_str("COMMIT"))
        p2 = await self.read_packet()
        if not p2.is_ok_packet():
            raise error("o COMMIT não foi confirmado")

    async def rollback(self):
        """Desfaz tudo desde o `begin`. É o que uma exceção no meio de uma
        escrita composta tem de chamar."""
        await self.send_command(COM_QUERY, bytes_of_str("ROLLBACK"))
        p3 = await self.read_packet()
        if not p3.is_ok_packet():
            raise error("o ROLLBACK não foi confirmado")

    async def set_autocommit(self, on: bool):
        """Liga ou desliga o commit automático de cada comando. Desligado, um
        `begin` é implícito e nada é definitivo até um `commit` — é como um
        servidor que faz escritas compostas costuma preferir."""
        v = "1" if on else "0"
        await self.query(f"SET autocommit = {v}")

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

    async def query_stream(self, sql: str) -> Cursor:
        """Como `query`, mas devolve um `Cursor` que entrega as linhas uma a uma
        em vez de todas na memória. Para um SELECT que não cabe."""
        await self.send_command(COM_QUERY, bytes_of_str(sql))
        first = await self.read_packet()
        if first.is_ok_packet():
            # sem result set (um comando): um cursor já vazio
            empty: List<Field> = []
            return Cursor(self, empty, True)
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
        eof1 = await self.read_packet()
        if not eof1.is_eof_packet():
            raise error("esperava o EOF depois das colunas")
        return Cursor(self, fields, False)

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
        # as linhas, até o EOF final. Cada valor cru (bytes ou NULL) é
        # convertido para o tipo pscript da sua coluna aqui, uma vez.
        rows: List<Row> = []
        while True:
            rp = await self.read_packet()
            if rp.is_eof_packet():
                # o EOF carrega o server_status: warnings (2 bytes) e status
                rp.read_uint8()          # o 0xFE
                rp.read_uint16()         # warnings
                self.status = rp.read_uint16()
                break
            raws: List<bytes?> = []
            cc = 0
            while cc < ncol:
                raws.append(rp.read_length_coded_string())
                cc += 1
            rows.append(Row(fields, raws))
        return Result(fields, rows, len(rows), 0)

    def has_next(self) -> bool:
        """Há outro result set a seguir? (uma multi-statement, ou um CALL de
        stored procedure que devolve vários)."""
        return self.status & SERVER_MORE_RESULTS != 0

    async def next_result(self) -> Result?:
        """O próximo result set de uma multi-statement, ou `None` se não há.
        Só faz sentido depois de um `query` cujo `has_next()` é verdade."""
        if not self.has_next():
            return None
        return await self.read_result()

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

async def connect(host: str, port: int, user: str, password: str, db: str = "",
                  tls: bool = False, tls_verify: bool = True) -> Connection:
    """Abre a conexão, faz o aperto de mão e autentica. Devolve a `Connection`
    pronta para `query`.

    `tls=True` cifra a ligação ANTES de a senha viajar: sem ele, a prova da senha
    e todos os dados vão em texto claro pela rede — o que só é aceitável quando o
    servidor está na mesma máquina (um socket que não sai dela). Numa rede, é
    obrigatório. Precisa que o runtime tenha sido compilado com `-D PSRT_TLS`; sem
    isso, `net.tls_available()` é falso e pedir `tls=True` levanta.

    `tls_verify=False` aceita um certificado auto-assinado (o que um MariaDB gera
    sozinho): cifra, mas não prova a identidade do servidor."""
    sock = await net.connect(host, port)
    conn = Connection(sock, 0, 0, bytes([]), "", "", False, 0)

    # 1. o servidor fala primeiro: o Initial Handshake
    hs = await conn.read_packet()
    parse_handshake(conn, hs)

    # 1b. TLS, se pedido: a ordem é o que importa. Manda-se um SSL Request — as
    # MESMAS flags do login mas SEM o usuário e SEM a senha —, faz-se o upgrade
    # do socket, e SÓ DEPOIS o resto do login viaja, já cifrado. É a sequência
    # `_do_ssl` do pymysql, e trocá-la manda a senha em claro no próprio pacote
    # que devia protegê-la.
    if tls:
        if not net.tls_available():
            raise error("TLS pedido mas o runtime não tem: recompile com -D PSRT_TLS")
        if conn.caps & CLIENT_SSL == 0:
            raise error("o servidor não anuncia suporte a TLS")
        ssl_req = build_ssl_request(conn, db)
        await conn.write_packet(ssl_req)
        # `tls_verify=False` aceita um certificado que a cadeia não valida — o
        # auto-assinado que um MariaDB gera sozinho. É a corda do `insecure`: a
        # ligação é cifrada na mesma, mas não se PROVA com quem se está a falar,
        # então um intermediário poderia pôr-se no meio. Para produção com um
        # certificado de verdade, deixe em True.
        ok_tls: bool = False
        if tls_verify:
            ok_tls = await net.starttls(sock, host)
        else:
            ok_tls = await net.starttls_insecure(sock, host)
        if not ok_tls:
            conn.sock.close()
            raise error(f"o aperto de mão TLS com {host} não completou")


    # 2. a resposta do cliente, com a prova da senha (já cifrada se houve TLS)
    scramble = auth.scramble_native_password(bytes_of_str(password), conn.salt)
    resp = build_handshake_response(conn, user, scramble, db, tls)
    await conn.write_packet(resp)

    # 3. o servidor responde OK, ErrPacket, pede troca de plugin, ou manda mais
    #    dados de auth (o caching_sha2 faz isso)
    reply = await conn.read_packet()
    await handle_auth_reply(conn, reply, password, conn.auth_plugin, tls)
    return conn


async def handle_auth_reply(conn: Connection, reply: pkt.Packet, password: str,
                           plugin: str, tls: bool):
    """Depois do primeiro login, o servidor pode: aceitar (OK), pedir OUTRO
    plugin (Auth Switch), ou mandar mais dados do plugin atual (o caching_sha2
    diz se a senha estava no cache). Aqui cada um desses caminhos é seguido até
    um OK ou um erro."""
    if reply.is_ok_packet():
        return

    if reply.is_auth_switch_request():
        # 0xFE + nome do plugin (NUL) + o novo salt
        reply.read_uint8()
        pn = reply.read_string()
        new_plugin = "mysql_native_password"
        if pn != None:
            new_plugin = str(pn)
        new_salt = reply.read_all()
        resp = auth_response(new_plugin, password, new_salt, tls)
        # conn.seq já é o próximo depois do read; a resposta vai com ele
        await conn.write_packet(resp)
        # o servidor pode ainda mandar os dados extras do caching_sha2
        nxt = await conn.read_packet()
        await handle_auth_reply(conn, nxt, password, new_plugin, tls)
        return

    if reply.is_extra_auth_data():
        # o caching_sha2 manda: 0x01 + (0x03 = cache HIT, ou 0x04 = precisa do
        # caminho lento). No HIT o próximo pacote é o OK; no MISS, mandamos a
        # senha (cifrada por TLS já em curso) e um NUL.
        reply.read_uint8()          # o 0x01
        marker = reply.read_uint8()
        if marker == 3:
            # cache hit: o servidor manda o OK a seguir
            ok = await conn.read_packet()
            if not ok.is_ok_packet():
                raise error("caching_sha2: esperava OK depois do cache hit")
            return
        # cache miss (marker == 4): a senha em claro, sobre TLS
        if not tls:
            raise error("caching_sha2 pediu o caminho lento e a ligação não é "
                        + "TLS: ligue tls=True (o caminho por RSA sem TLS não "
                        + "está implementado)")
        pw: List<u8> = []
        b = bytes(password.encode())
        i = 0
        while i < len(b):
            pw.append(b[i])
            i += 1
        pw.append(u8(0))
        await conn.write_packet(bytes(pw))
        ok2 = await conn.read_packet()
        if not ok2.is_ok_packet():
            raise error("caching_sha2: o login não foi aceito no caminho lento")
        return

    raise error("o login não foi aceito")


private def auth_response(plugin: str, password: str, salt: bytes, tls: bool) -> bytes:
    """A resposta de auth para o plugin que o servidor pediu no switch."""
    if plugin == "mysql_native_password":
        return auth.scramble_native_password(bytes(password.encode()), salt)
    if plugin == "caching_sha2_password":
        return auth.scramble_caching_sha2(bytes(password.encode()), salt)
    if plugin == "client_ed25519":
        # o plugin ed25519 do MariaDB: assina o salt com uma chave derivada da
        # senha. A conta é crypto de curva e vem do pacote `ed25519` (em P), que
        # devolve a assinatura em hex; aqui volta a bytes.
        sighex = ed25519_password_hex(bytes(password.encode()), salt)
        decoded = str(sighex).from_hex()
        if decoded == None:
            raise error("ed25519: a assinatura não voltou de hex")
        return decoded
    if plugin == "mysql_clear_password":
        # só sobre TLS: a senha vai em claro
        if not tls:
            raise error("mysql_clear_password sem TLS manda a senha em claro; ligue tls=True")
        pw: List<u8> = []
        b = bytes(password.encode())
        i = 0
        while i < len(b):
            pw.append(b[i])
            i += 1
        pw.append(u8(0))
        return bytes(pw)
    raise error(f"plugin de auth não implementado: {plugin}")


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


private def build_ssl_request(conn: Connection, db: str) -> bytes:
    """O SSL Request: os 32 bytes iniciais de um login (flags com CLIENT_SSL,
    tamanho máximo, charset, 23 reservados) e PARA por aí — nada de usuário nem
    senha, que é o que ainda não pode viajar em claro. O servidor lê estes 32
    bytes, faz o seu lado do TLS, e espera o resto cifrado."""
    out: List<u8> = []
    client_flags = DEFAULT_CAPS | CLIENT_SSL
    if len(db) > 0:
        client_flags = client_flags | CLIENT_CONNECT_WITH_DB
    append_u32(out, client_flags)
    append_u32(out, MAX_PACKET_LEN)
    out.append(u8(UTF8MB4_ID))
    r = 0
    while r < 23:
        out.append(u8(0))
        r += 1
    return bytes(out)


private def build_handshake_response(conn: Connection, user: str, scramble: bytes, db: str, tls: bool) -> bytes:
    """A Handshake Response 41: flags, tamanho máximo, charset, o usuário, a
    prova, e (se houver) o banco e o nome do plugin."""
    out: List<u8> = []
    client_flags = DEFAULT_CAPS
    if tls:
        client_flags = client_flags | CLIENT_SSL
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
    empty: List<Row> = []
    return Result([], empty, a, ii)


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

def convert_value(raw: bytes?, f: Field) -> any?:
    """Um valor cru de coluna vira o tipo pscript que a coluna promete.

    A tabela é a do `converters.py` do pymysql, e a regra é a dele: os inteiros
    viram `int`, os de ponto flutuante `float`, as datas um tipo do pacote
    `datetime`, e o resto — texto e binário — fica como `str` ou `bytes`. Um
    NULL (o `raw` ausente) atravessa como `None`.

    O que NÃO se adivinha: um DECIMAL fica `str`. Um preço com casas decimais
    exatas viraria float e perderia o último centavo — é a mesma razão pela qual
    o `csv` do pscript não adivinha que `007` é sete. Quem quer o número decide.

    Uma data ILEGAL (o MySQL guarda `0000-00-00`) não converte: volta como a
    `str` que era, que é o que o pymysql faz — levantar aqui seria transformar um
    dado velho do banco num erro de leitura."""
    if raw == None:
        return None
    t = f.type_code

    # inteiros
    if (t == FIELD_TINY or t == FIELD_SHORT or t == FIELD_LONG
            or t == FIELD_LONGLONG or t == FIELD_INT24 or t == FIELD_YEAR):
        r: any = int(str(raw))
        return r

    # ponto flutuante
    if t == FIELD_FLOAT or t == FIELD_DOUBLE:
        r2: any = float(str(raw))
        return r2

    # datas ficam como a `str` do servidor: um `any` não guarda um
    # `LocalDateTime` (é um struct, e o `any` carrega números, bools, strings,
    # listas e dicts). Quem quer a data como tipo chama `row.get_datetime(...)`,
    # que a parseia sem passar pelo `any`. É o mesmo motivo por que um BLOB vai
    # por `raw`: o tipo rico tem a sua própria porta.

    # um BLOB de charset `binary` é binário de verdade e vira `bytes` (o `any`
    # aprendeu a guardá-los); um "BLOB" de charset de texto (um TEXT, que
    # compartilha o type code) é UTF-8 e vira `str`.
    if (t == FIELD_BLOB or t == FIELD_TINY_BLOB or t == FIELD_MEDIUM_BLOB
            or t == FIELD_LONG_BLOB):
        if f.charsetnr == CHARSET_BINARY:
            rbin: any = raw
            return rbin
        rt: any = str(raw)
        return rt

    # DECIMAL fica str de propósito (a exatidão), e o resto (VARCHAR, STRING,
    # ENUM, SET, ...) é texto
    r7: any = str(raw)
    return r7


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
