"""HTTP/2 (bateria 158): os frames, os streams, as duas janelas, e as recusas.

O que este portão prova, por ordem do que custa mais caro estar errado:

1. **um pedido e uma resposta atravessam inteiros** — preâmbulo, SETTINGS,
   HEADERS com HPACK, DATA — e o `Response` que sai é o MESMO tipo que o HTTP/1
   produz, que é a razão de as duas versões viverem no mesmo pacote;
2. **o HPACK fecha sobre si próprio**, com a tabela dinâmica a crescer entre
   pedidos: o que o nosso codificador escreve, o nosso descodificador lê;
3. **as cinco recusas que são vulnerabilidades e não pedantismo** — CONTINUATION
   interrompida, WINDOW_UPDATE de zero, enchimento maior do que o frame,
   PUSH_PROMISE depois de termos dito que não, e índice zero no HPACK.
"""
import <http/h2.psc> as H2
import <http/hpack.psc> as HP
from <http/http.psc> import Header


def frame(kind: int, flags: int, stream: int, payload: List<u8>) -> bytes:
    out: List<u8> = []
    out.append(u8((len(payload) >> 16) & 0xFF))
    out.append(u8((len(payload) >> 8) & 0xFF))
    out.append(u8(len(payload) & 0xFF))
    out.append(u8(kind))
    out.append(u8(flags))
    out.append(u8((stream >> 24) & 0xFF))
    out.append(u8((stream >> 16) & 0xFF))
    out.append(u8((stream >> 8) & 0xFF))
    out.append(u8(stream & 0xFF))
    for p in payload:
        out.append(p)
    return bytes(out)


def kinds_of(b: bytes) -> str:
    """Os frames que saíram, como `tipo/stream`, mais `PRI` para o preâmbulo."""
    out = ""
    i = 0
    pre = H2.PREFACE.encode()
    if len(b) >= len(pre):
        same = True
        for k in range(len(pre)):
            if b[k] != pre[k]:
                same = False
        if same:
            out = "PRI"
            i = len(pre)
    while i + 9 <= len(b):
        ln = (int(b[i]) << 16) | (int(b[i + 1]) << 8) | int(b[i + 2])
        sid = ((int(b[i + 5]) << 24) | (int(b[i + 6]) << 16) | (int(b[i + 7]) << 8) | int(b[i + 8])) & 0x7FFFFFFF
        if len(out) > 0:
            out += " "
        out += str(int(b[i + 3])) + "/" + str(sid)
        i += 9 + ln
    return out


def list_of(b: bytes) -> List<u8>:
    out: List<u8> = []
    for x in b:
        out.append(x)
    return out


def bytes_of(xs: List<int>) -> List<u8>:
    out: List<u8> = []
    for x in xs:
        out.append(u8(x))
    return out


def bytes_of_b(xs: List<int>) -> bytes:
    return bytes(bytes_of(xs))


# ---------- 1. um pedido e uma resposta, de ponta a ponta ----------

noextra: List<Header> = []
empty: List<u8> = []

c = H2.new_conn(False)
H2.start(c)
print("o cliente abre com:", kinds_of(H2.take_out(c)))

# o servidor responde com o SEU settings; nós temos de o confirmar
srv_settings = frame(H2.F_SETTINGS, 0, 0, bytes_of([0, 4, 0, 1, 0, 0]))
print("frames lidos:", H2.feed(c, srv_settings))
print("e nos confirmamos:", kinds_of(H2.take_out(c)))
print("a janela inicial do par passou a", c.peer_initial_window)

extra: List<Header> = [Header("accept", "*/*")]
sid = H2.request(c, "GET", "https", "example.com", "/index.html", extra, bytes([]))
sent = H2.take_out(c)
print("stream", sid, "saiu como", kinds_of(sent))

# o que saiu decodifica-se com uma tabela de LEITOR: é o teste de que o nosso
# codificador e o nosso descodificador falam a mesma língua
peer = HP.new_table(4096)
block: List<u8> = []
for i in range(9, len(sent)):
    block.append(sent[i])
for h in HP.decode(peer, bytes(block)):
    print("  campo", h.name, "=", h.value)

# a resposta: HEADERS com :status, depois DATA com END_STREAM
enc = HP.new_table(4096)
rh: List<Header> = [Header(":status", "200"), Header("content-type", "text/plain"),
                    Header("x-first", "a"), Header("x-first", "b")]
resp_block = HP.encode(enc, rh)
nfa = H2.feed(c, frame(H2.F_HEADERS, H2.FL_END_HEADERS, sid, list_of(resp_block)))
nfb = H2.feed(c, frame(H2.F_DATA, H2.FL_END_STREAM, sid, list_of("ola mundo".encode())))
print("terminou:", H2.finished(c, sid))
r = H2.response_of(c, sid)
print("status", r.status, "corpo", str(r.body))
print("content-type:", r.header("content-type"))
print("repetido junta-se:", r.header("x-first"))
print("e demos credito de volta:", kinds_of(H2.take_out(c)))


# ---------- 2. as recusas ----------
#
# Cada uma destas é uma vulnerabilidade publicada e não uma regra de estilo, e é
# por isso que estão todas aqui em vez de espalhadas.

# 6.10: uma CONTINUATION interrompida. É o buraco da família CVE-2024-27316: um
# bloco de cabeçalhos que nunca acaba, alimentado para sempre num stream que
# nunca abre, com o descodificador HPACK — que é estado da LIGAÇÃO — a meio.
c2 = H2.new_conn(False)
H2.start(c2)
discard = H2.take_out(c2)
half = HP.encode(HP.new_table(4096), [Header(":status", "200")])
nf1 = H2.feed(c2, frame(H2.F_HEADERS, 0, 1, list_of(half)))   # sem END_HEADERS
try:
    nf2 = H2.feed(c2, frame(H2.F_PING, 0, 0, bytes_of([1, 2, 3, 4, 5, 6, 7, 8])))
    print("NAO RECUSOU a continuation interrompida")
catch e:
    print("recusa continuation:", e.message)

# 6.9.1: um WINDOW_UPDATE de zero não diz nada — e um DATA de zero bytes é legal.
# A assimetria é a parte que se esquece.
c3 = H2.new_conn(False)
try:
    nf3 = H2.feed(c3, frame(H2.F_WINDOW_UPDATE, 0, 0, bytes_of([0, 0, 0, 0])))
    print("NAO RECUSOU o window update de zero")
catch e:
    print("recusa window zero:", e.message)

# 6.1: enchimento maior do que o frame. Ler isto ao contrário é como se convence
# um analisador a ler para lá do fim.
#
# O stream tem de estar ABERTO primeiro: um DATA num stream ocioso já é erro por
# outra razão, e um teste que dispara a recusa errada não testa nada. Foi assim
# que este apareceu — recusava, e recusava pelo motivo que não era.
c4 = H2.new_conn(False)
H2.start(c4)
sid4 = H2.request(c4, "GET", "https", "e.com", "/", noextra, bytes(empty))
d4 = H2.take_out(c4)
try:
    nf4 = H2.feed(c4, frame(H2.F_DATA, H2.FL_PADDED, sid4, bytes_of([200, 65, 66])))
    print("NAO RECUSOU o enchimento grande demais")
catch e:
    print("recusa enchimento:", e.message)

# 8.4: dissemos ENABLE_PUSH=0 no nosso SETTINGS; uma promessa é o par a ignorá-lo
c5 = H2.new_conn(False)
try:
    nf5 = H2.feed(c5, frame(H2.F_PUSH_PROMISE, H2.FL_END_HEADERS, 1, bytes_of([0, 0, 0, 2])))
    print("NAO RECUSOU o push promise")
catch e:
    print("recusa push:", e.message)

# RFC 7541 6.1: o índice zero não nomeia campo nenhum
try:
    d1 = HP.decode(HP.new_table(4096), bytes_of_b([0x80]))
    print("NAO RECUSOU o indice zero")
catch e:
    print("recusa indice 0:", e.message)

# RFC 7541 5.2: o EOS não pode aparecer dentro de uma string Huffman
try:
    d2 = HP.decode(HP.new_table(4096), bytes_of_b([0x00, 0x84, 0xFF, 0xFF, 0xFF, 0xFF]))
    print("NAO RECUSOU o EOS")
catch e:
    print("recusa EOS:", e.message)


# ---------- 3. o HPACK contra os exemplos do proprio RFC ----------
#
# C.2.1: um literal com nome literal, sem Huffman. Se estes três falharem, o
# corpus de 47 142 casos vai falhar de uma maneira muito mais difícil de ler.
t = HP.new_table(4096)
ex1 = HP.decode(t, bytes_of_b([0x40, 0x0a, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d, 0x6b,
                               0x65, 0x79, 0x0d, 0x63, 0x75, 0x73, 0x74, 0x6f, 0x6d, 0x2d,
                               0x68, 0x65, 0x61, 0x64, 0x65, 0x72]))
print("C.2.1:", ex1[0].name, "=", ex1[0].value, "| tabela:", t.size)
# C.2.4: um campo indexado, o 2 da tabela estática
ex2 = HP.decode(HP.new_table(4096), bytes_of_b([0x82]))
print("C.2.4:", ex2[0].name, "=", ex2[0].value)
# C.4.1: o mesmo pedido de C.3.1 mas com Huffman
ex3 = HP.decode(HP.new_table(4096), bytes_of_b([0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3,
                                                0xc2, 0xe5, 0xf2, 0x3a, 0x6b, 0xa0, 0xab,
                                                0x90, 0xf4, 0xff]))
print("C.4.1:", len(ex3), "campos, o ultimo:", ex3[3].name, "=", ex3[3].value)
