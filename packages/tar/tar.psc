"""`ustar`: o envelope, ler e escrever.

Um pacote viaja como `.tar` e mais nada — sem compressão, sem formato nosso. A
razão é uma só e vale a diferença de tamanho: `tar tf pacote.tar` funciona sem
esta ferramenta, e "o que há dentro deste pacote?" é uma pergunta que ninguém
precisa de nos pedir licença para fazer.

O que está aqui é o `ustar` do POSIX e nada mais: cabeçalho de 512 bytes com os
campos em octal, o conteúdo em blocos de 512, dois blocos de zeros no fim. Sem
links, sem esparso, sem PAX, sem GNU longname.

E a LEITURA RECUSA o que não entende, em vez de adivinhar. Isto não é rigor de
enfeite — é a fronteira por onde entra código de fora, e cada recusa aqui é um
ataque conhecido que não acontece:

  * um caminho ABSOLUTO (`/etc/cron.d/x`) escreveria fora da árvore;
  * um `..` em qualquer componente faz o mesmo por outro caminho — é o
    *zip slip*, e a defesa é recusar o membro, não normalizar o nome;
  * um tipo que não seja arquivo comum ou diretório: um link simbólico dentro
    de um tarball é o mesmo ataque com mais passos (extrai-se `a -> /etc`, e o
    membro seguinte escreve em `a/passwd`);
  * um checksum que não bate, um `magic` que não é `ustar`, um tamanho que não
    é octal, um bloco que acaba a meio.

Cada uma delas para com um `error(...)` que diz o nome do membro. Um extrator
que "faz o melhor que pode" com um tarball estranho é um extrator que faz
exatamente o que o tarball estranho quer.
"""

# ---------- o que entra e sai ----------

struct Membro:
    nome: str          # relativo, sem `..`, com `/` como separador
    tipo: str          # "arquivo" ou "dir"
    modo: int          # as permissões, em binário (0o644, 0o755)
    mtime: int         # segundos desde a época
    dados: list<u8>    # vazio num diretório


def arquivo(nome: str, dados: list<u8>, modo: int, mtime: int) -> Membro:
    return Membro(nome, "arquivo", modo, mtime, dados)


def diretorio(nome: str, modo: int, mtime: int) -> Membro:
    vazio: list<u8> = []
    return Membro(nome if nome.endswith("/") else nome + "/", "dir", modo, mtime, vazio)


# ---------- bytes e texto ----------

def bytes_de(s: str) -> list<u8>:
    """O texto como UTF-8. Um nome de arquivo pode ter acento, e o que vai para
    o cabeçalho são BYTES — contar codepoints daria um comprimento que não é o
    do disco.

    >>> len(bytes_de("abc"))
    3
    >>> len(bytes_de("olá"))
    4
    """
    out: list<u8> = []
    for ch in s:
        cp = ord(ch)
        if cp < 0x80:
            out.append(u8(cp))
        elif cp < 0x800:
            out.append(u8(0xC0 | (cp >> 6)))
            out.append(u8(0x80 | (cp & 0x3F)))
        elif cp < 0x10000:
            out.append(u8(0xE0 | (cp >> 12)))
            out.append(u8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(u8(0x80 | (cp & 0x3F)))
        else:
            out.append(u8(0xF0 | (cp >> 18)))
            out.append(u8(0x80 | ((cp >> 12) & 0x3F)))
            out.append(u8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(u8(0x80 | (cp & 0x3F)))
    return out


# ---------- escrever ----------

def octal(v: int, largura: int) -> str:
    """Um campo numérico do ustar: octal, alinhado à direita com zeros, e o
    último byte reservado para o NUL. `largura` é o campo inteiro.

    >>> octal(0o644, 8)
    0000644
    >>> octal(0, 12)
    00000000000
    """
    d = ""
    n = v
    if n < 0:
        raise error("um campo do tar não é negativo: " + str(v), VALUE)
    while n > 0:
        d = str(n % 8) + d
        n = n // 8
    if d == "":
        d = "0"
    if len(d) > largura - 1:
        raise error(f"não cabe em {largura - 1} dígitos octais: {v}", VALUE)
    while len(d) < largura - 1:
        d = "0" + d
    return d


private def por_bytes(bloco: list<u8>, pos: int, bs: list<u8>, largura: int):
    if len(bs) > largura:
        raise error("um campo do cabeçalho não cabe", VALUE)
    i = 0
    for b in bs:
        bloco[pos + i] = b
        i += 1


private def por_texto(bloco: list<u8>, pos: int, s: str, largura: int):
    por_bytes(bloco, pos, bytes_de(s), largura)


def cabecalho(m: Membro) -> list<u8>:
    """Os 512 bytes de um membro. O `prefix` do ustar existe e é usado: um nome
    até 100 bytes vai inteiro em `name`, e mais do que isso parte-se num
    separador — o que dá 255 e chega para tudo o que um pacote tem."""
    nome_b = bytes_de(m.nome)
    prefixo = ""
    nome = m.nome
    if len(nome_b) > 100:
        # parte no ÚLTIMO `/` que deixe as duas metades dentro dos limites
        corte = -1
        i = len(nome) - 1
        while i > 0:
            if nome[i] == "/" and len(bytes_de(nome[i + 1:len(nome)])) <= 100 and len(bytes_de(nome[0:i])) <= 155:
                corte = i
                break
            i -= 1
        if corte < 0:
            raise error("o nome não cabe no ustar (100 + 155 bytes): " + m.nome, VALUE)
        prefixo = nome[0:corte]
        nome = nome[corte + 1:len(nome)]

    b: list<u8> = []
    for _ in range(512):
        b.append(u8(0))
    por_texto(b, 0, nome, 100)
    por_texto(b, 100, octal(m.modo, 8), 7)
    por_texto(b, 108, octal(0, 8), 7)          # uid: sempre 0, ver a nota abaixo
    por_texto(b, 116, octal(0, 8), 7)          # gid
    por_texto(b, 124, octal(len(m.dados), 12), 11)
    por_texto(b, 136, octal(m.mtime, 12), 11)
    # o checksum entra depois; enquanto se soma, o campo são OITO ESPAÇOS
    for i in range(8):
        b[148 + i] = u8(32)
    b[156] = u8(53) if m.tipo == "dir" else u8(48)   # '5' ou '0'
    por_texto(b, 257, "ustar", 6)
    b[262] = u8(0)
    por_texto(b, 263, "00", 2)
    # dono e grupo: NOMES vazios e ids 0. Um tarball de código-fonte que carrega
    # o utilizador de quem o fez é um tarball que muda quando muda de máquina —
    # e o hash dele é o que garante a distribuição. Reprodutível ou verificável:
    # escolhe-se uma vez, e escolheu-se aqui.
    por_texto(b, 329, octal(0, 8), 7)
    por_texto(b, 337, octal(0, 8), 7)
    if prefixo != "":
        por_texto(b, 345, prefixo, 155)
    soma = 0
    for x in b:
        soma += int(x)
    # seis dígitos octais, NUL, espaço — a forma que todo o mundo lê
    por_texto(b, 148, octal(soma, 7), 6)
    b[154] = u8(0)
    b[155] = u8(32)
    return b


def escrever(membros: list<Membro>) -> list<u8>:
    """O tarball inteiro em memória. Um pacote de código-fonte cabe, e ter os
    bytes todos na mão é o que permite hashear e escrever numa passagem só."""
    out: list<u8> = []
    for m in membros:
        if m.nome == "":
            raise error("um membro sem nome", VALUE)
        for b in cabecalho(m):
            out.append(b)
        for d in m.dados:
            out.append(d)
        resto = len(m.dados) % 512
        if resto != 0:
            for _ in range(512 - resto):
                out.append(u8(0))
    # a marca de fim: DOIS blocos de zeros
    for _ in range(1024):
        out.append(u8(0))
    return out


# ---------- ler ----------

private def texto_ate_nul(b: list<u8>, pos: int, largura: int) -> str:
    fatia: list<u8> = []
    i = 0
    while i < largura and b[pos + i] != u8(0):
        fatia.append(b[pos + i])
        i += 1
    return str(fatia)


private def le_octal(b: list<u8>, pos: int, largura: int, campo: str) -> int:
    v = 0
    i = 0
    visto = False
    while i < largura:
        c = int(b[pos + i])
        if c == 0 or c == 32:
            # espaços e NUL delimitam; depois deles não pode vir mais dígito
            i += 1
            while i < largura:
                c2 = int(b[pos + i])
                if c2 != 0 and c2 != 32:
                    raise error(f"o campo {campo} não é octal", VALUE)
                i += 1
            break
        if c < 48 or c > 55:
            raise error(f"o campo {campo} não é octal", VALUE)
        v = v * 8 + (c - 48)
        visto = True
        i += 1
    if not visto:
        return 0
    return v


def nome_seguro(nome: str) -> str:
    """A recusa que mais importa. Devolve "" quando o nome é bom, e a razão
    quando não é — para quem chama poder dizer QUAL membro e PORQUÊ.

    >>> nome_seguro("pkg/README.md") == ""
    True
    >>> len(nome_seguro("/etc/passwd")) > 0
    True
    >>> len(nome_seguro("a/../../etc/passwd")) > 0
    True
    """
    if nome == "":
        return "um membro sem nome"
    if nome.startswith("/"):
        return "caminho absoluto: " + nome
    if len(nome) > 1 and nome[1] == ":":
        return "caminho com unidade: " + nome
    for parte in nome.split("/"):
        if parte == "..":
            return "o caminho sobe para fora do destino: " + nome
    if "\\" in nome:
        return "uma barra invertida num nome de membro: " + nome
    return ""


def ler(dados: list<u8>) -> list<Membro>:
    """Os membros, em ordem. Levanta na primeira coisa que não entende."""
    out: list<Membro> = []
    pos = 0
    n = len(dados)
    while pos + 512 <= n:
        # um bloco todo zeros é o fim
        vazio = True
        for i in range(512):
            if dados[pos + i] != u8(0):
                vazio = False
                break
        if vazio:
            break
        # o checksum, com o campo lido como oito espaços
        declarado = le_octal(dados, pos + 148, 8, "checksum")
        soma = 0
        for i in range(512):
            soma += 32 if i >= 148 and i < 156 else int(dados[pos + i])
        if soma != declarado:
            raise error(f"checksum errado no bloco {pos // 512}: {soma} != {declarado}", VALUE)
        magic = texto_ate_nul(dados, pos + 257, 6)
        if magic != "ustar":
            raise error("não é ustar: " + magic, VALUE)
        nome = texto_ate_nul(dados, pos, 100)
        prefixo = texto_ate_nul(dados, pos + 345, 155)
        if prefixo != "":
            nome = prefixo + "/" + nome
        tipo_b = int(dados[pos + 156])
        # '\0' é a grafia antiga de "arquivo comum" e vale; tudo o resto não
        if tipo_b != 48 and tipo_b != 0 and tipo_b != 53:
            raise error(f"o membro '{nome}' é do tipo '{chr(tipo_b) if tipo_b > 32 else str(tipo_b)}', e aqui só entram arquivo e diretório", VALUE)
        mau = nome_seguro(nome)
        if mau != "":
            raise error(mau, VALUE)
        modo = le_octal(dados, pos + 100, 8, "modo")
        tam = le_octal(dados, pos + 124, 12, "tamanho")
        mtime = le_octal(dados, pos + 136, 12, "mtime")
        pos += 512
        corpo: list<u8> = []
        if tipo_b == 53:
            if tam != 0:
                raise error("um diretório com conteúdo: " + nome, VALUE)
        else:
            if pos + tam > n:
                raise error("o tarball acaba a meio de '" + nome + "'", VALUE)
            for i in range(tam):
                corpo.append(dados[pos + i])
            pos += tam
            resto = tam % 512
            if resto != 0:
                pos += 512 - resto
        out.append(Membro(nome, "dir" if tipo_b == 53 else "arquivo", modo, mtime, corpo))
    return out
