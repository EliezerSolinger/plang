"""HTTP/1.1 escrito em pscript (77.2/78.1).

NADA de terceiro entra no runtime. O teste do que mora lá é: precisa de acesso
privilegiado ao heap, ao coletor ou ao escalonador? Coletor, escalonador, pool,
`poll`, socket e DNS precisam. Um parser de HTTP não — ele é uma máquina de
estados sobre bytes, e fica melhor aqui, onde quem usa lê e depura na própria
linguagem.

O llhttp, aliás, é ele mesmo uma máquina de estados descrita num DSL em
TypeScript que cospe C. O que está aqui é a mesma máquina a partir da
especificação (RFC 9112), com as mesmas decisões de robustez que ele toma:

  * a linha de pedido é `MÉTODO SP ALVO SP HTTP/1.x CRLF`, e um alvo com espaço
    é recusado em vez de adivinhado;
  * o nome de um cabeçalho não pode ter espaço antes dos dois-pontos — é o
    truque clássico de contrabando de pedido;
  * `Content-Length` e `Transfer-Encoding: chunked` juntos é recusado, pela
    mesma razão: dois tamanhos discordando é como se contrabandeia;
  * nome de cabeçalho vira minúsculo, porque o RFC diz que ele não distingue
    maiúsculas e um dict distingue;
  * `LF` sozinho é aceito como fim de linha (todo servidor aceita), mas `CR`
    sozinho não.

É INCREMENTAL: `feed(bytes)` engole o que chegou e diz se já dá para ler um
pedido. É assim que ele serve um socket, onde `read(n)` devolve o que houver
(79.2) e quase nunca a mensagem inteira.
"""

# ---------- o que sai do parser ----------

struct Request:
    method: str
    target: str
    version: str
    headers: dict<str, str>
    body: list<u8>

    def header(self, name: str) -> str:
        return self.headers[name] if name in self.headers else ""


enum HState:
    H_LINE = 0        # engolindo a linha de pedido
    H_HEADERS         # ... e os cabeçalhos
    H_BODY            # corpo de tamanho conhecido
    H_CHUNK_SIZE      # corpo em pedaços: a linha do tamanho
    H_CHUNK_DATA      # ... e os bytes do pedaço
    H_DONE
    H_ERROR


struct Parser:
    state: HState
    buf: list<u8>          # o que chegou e ainda não foi consumido
    pos: int               # até onde já se leu de `buf`
    method: str
    target: str
    version: str
    headers: dict<str, str>
    body: list<u8>
    need: int              # bytes que faltam do corpo (ou do pedaço)
    chunked: bool
    problema: str
    ultima: str            # a última linha lida por `linha()`

    # ---------- as peças ----------

    def erro(self, msg: str) -> bool:
        self.state = H_ERROR
        self.problema = msg
        return False

    # a próxima linha de `buf` a partir de `pos`, sem o fim de linha. Devolve
    # False quando ela ainda não chegou inteira; quando devolve True, o texto
    # está em `self.ultima`. (Um `str?` seria mais bonito e obrigaria um
    # narrowing por chamada — aqui a linha é lida em cinco lugares.)
    def linha(self) -> bool:
        i = self.pos
        n = len(self.buf)
        while i < n:
            c = self.buf[i]
            if c == 10:                       # LF
                fim = i
                if fim > self.pos and self.buf[fim - 1] == 13:
                    fim -= 1                  # CRLF
                crus: list<u8> = []
                k = self.pos
                while k < fim:
                    crus.append(self.buf[k])
                    k += 1
                self.pos = i + 1
                self.ultima = str(crus)
                return True
            if c == 13 and i + 1 >= n:
                return False                  # um CR que talvez seja CRLF
            i += 1
        return False

    def feed(self, chunk: list<u8>) -> bool:
        """Engole o que chegou e diz se um pedido inteiro já pode ser lido."""
        for b in chunk:
            self.buf.append(b)
        return self.passo()

    def passo(self) -> bool:
        while True:
            if self.state == H_DONE or self.state == H_ERROR:
                return self.state == H_DONE

            if self.state == H_LINE:
                if not self.linha():
                    return False
                l = self.ultima
                if len(l) == 0:
                    continue                  # linhas em branco antes do pedido
                partes = l.split(" ")
                if len(partes) != 3:
                    return self.erro("linha de pedido malformada")
                self.method = partes[0]
                self.target = partes[1]
                self.version = partes[2]
                if len(self.method) == 0 or len(self.target) == 0:
                    return self.erro("linha de pedido malformada")
                if not self.version.startswith("HTTP/1."):
                    return self.erro("versao nao suportada: " + self.version)
                self.state = H_HEADERS

            elif self.state == H_HEADERS:
                if not self.linha():
                    return False
                l2 = self.ultima
                if len(l2) == 0:
                    # fim dos cabeçalhos: o que vem depois depende deles
                    tem_len = "content-length" in self.headers
                    if self.chunked and tem_len:
                        return self.erro("content-length e chunked ao mesmo tempo")
                    if self.chunked:
                        self.state = H_CHUNK_SIZE
                    elif tem_len:
                        self.need = int(self.headers["content-length"])
                        if self.need < 0:
                            return self.erro("content-length negativo")
                        self.state = H_BODY if self.need > 0 else H_DONE
                    else:
                        self.state = H_DONE
                    continue
                dois = l2.find(":")
                if dois <= 0:
                    return self.erro("cabecalho sem dois-pontos")
                nome = l2[0:dois]
                if nome.endswith(" ") or nome.endswith("\t"):
                    # o truque clássico de contrabando: um espaço antes do `:`
                    return self.erro("espaco antes dos dois-pontos")
                valor = l2[dois + 1:len(l2)].strip()
                chave = nome.lower()
                self.headers[chave] = valor
                if chave == "transfer-encoding" and valor.lower() == "chunked":
                    self.chunked = True

            elif self.state == H_BODY:
                disponivel = len(self.buf) - self.pos
                leva = disponivel if disponivel < self.need else self.need
                k2 = 0
                while k2 < leva:
                    self.body.append(self.buf[self.pos + k2])
                    k2 += 1
                self.pos += leva
                self.need -= leva
                if self.need > 0:
                    return False
                self.state = H_DONE

            elif self.state == H_CHUNK_SIZE:
                if not self.linha():
                    return False
                l3 = self.ultima
                # o tamanho vem em hexadecimal, e pode trazer extensões após `;`
                # `find` devolve -1 quando não acha (o `CStr.find` do P devolve
                # o tamanho; são convenções diferentes e vale saber qual é qual)
                pv = l3.find(";")
                hexa = l3[0:pv] if pv >= 0 else l3
                v = hex_para_int(hexa.strip())
                if v < 0:
                    return self.erro("tamanho de pedaco invalido")
                self.need = v
                self.state = H_DONE if v == 0 else H_CHUNK_DATA

            elif self.state == H_CHUNK_DATA:
                disp2 = len(self.buf) - self.pos
                leva2 = disp2 if disp2 < self.need else self.need
                k3 = 0
                while k3 < leva2:
                    self.body.append(self.buf[self.pos + k3])
                    k3 += 1
                self.pos += leva2
                self.need -= leva2
                if self.need > 0:
                    return False
                # o CRLF que fecha o pedaço
                if not self.linha():
                    return False
                self.state = H_CHUNK_SIZE
        return False

    def pedido(self) -> Request:
        return Request(self.method, self.target, self.version, self.headers, self.body)


def novo_parser() -> Parser:
    return Parser(H_LINE, [], 0, "", "", "", {}, [], 0, False, "", "")


def hex_para_int(s: str) -> int:
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


# ---------- do outro lado: montar uma resposta ----------

def resposta(status: int, motivo: str, tipo: str, corpo: str) -> str:
    linhas = "HTTP/1.1 " + str(status) + " " + motivo + "\r\n"
    linhas += "content-type: " + tipo + "\r\n"
    linhas += "content-length: " + str(len(corpo)) + "\r\n"
    linhas += "connection: close\r\n\r\n"
    return linhas + corpo


def pedido(metodo: str, alvo: str, host: str, corpo: str) -> str:
    p = metodo + " " + alvo + " HTTP/1.1\r\n"
    p += "host: " + host + "\r\n"
    if len(corpo) > 0:
        p += "content-length: " + str(len(corpo)) + "\r\n"
    p += "connection: close\r\n\r\n"
    return p + corpo
