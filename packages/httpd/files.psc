"""Servir uma árvore de ficheiros (F8/D13/D21).

Metade do que um servidor de jogo faz é isto, e escrevê-lo à mão em cada projecto
é onde nascem os path traversals. O que está aqui é a versão com as recusas
certas — e as recusas são a parte que interessa.

**A raiz é resolvida uma vez, e todo o caminho pedido tem de ficar debaixo dela.**
Não se procuram `..` no texto do pedido: essa é a defesa que se rompe, porque há
sempre mais uma maneira de escrever o mesmo — `%2e%2e`, `..%2f`, `.%2e/`, um `\\`
no Windows, um `..;/` que alguns servidores partem. A defesa que não se rompe é
juntar, NORMALIZAR, e comparar o resultado com a raiz: se o caminho normalizado
não começa pela raiz, é 403, seja qual for a grafia que lá chegou.

**Nunca lista o directório** (D21). Sem `index.html`, 404. Uma listagem é
vazamento de informação por omissão, e quem a tem costuma não saber que a tem —
por isso nem como interruptor.

**O ETag é forte e vem do que se pode saber sem ler o ficheiro**: tamanho e data
de modificação em nanossegundos. Um resumo do conteúdo seria melhor e obrigaria a
ler o ficheiro inteiro para responder 304 — que é exactamente o trabalho que o 304
existe para evitar.
"""
import <httpd/httpd.psc> as httpd
import os
import path


def mime_for(nome: str) -> str:
    """O tipo pela extensão. A lista é curta de propósito: são os tipos que um
    servidor de jogo e um site servem, e uma tabela completa da IANA envelheceria
    aqui dentro. O que não está na lista sai como `application/octet-stream`, que
    é o que o RFC 9110 §8.3 manda quando não se sabe — e que faz o browser
    descarregar em vez de adivinhar, que é o lado seguro do engano."""
    i = nome.rfind(".")
    if i < 0:
        return "application/octet-stream"
    ext = nome[i + 1:].lower()
    match ext:
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js", "mjs":
            return "text/javascript; charset=utf-8"
        case "json":
            return "application/json"
        case "txt", "md":
            return "text/plain; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "ico":
            return "image/x-icon"
        case "wasm":
            return "application/wasm"
        case "mp3":
            return "audio/mpeg"
        case "ogg":
            return "audio/ogg"
        case "wav":
            return "audio/wav"
        case "mp4":
            return "video/mp4"
        case "webm":
            return "video/webm"
        case "woff2":
            return "font/woff2"
        case "woff":
            return "font/woff"
        case "ttf":
            return "font/ttf"
        case "glb":
            return "model/gltf-binary"
        case _:
            return "application/octet-stream"


struct Files:
    """Uma árvore, servida. A raiz vem já absoluta e normalizada — resolvê-la a
    cada pedido seria pagar um `realpath` por pedido para obter sempre a mesma
    resposta."""
    raiz: str
    index: str          # o que servir para um directório; "" = 404
    cache: str          # o `cache-control`; "" = não pôr nenhum


def files(dir: str, index: str = "index.html", cache: str = "") -> Files:
    return Files(path.abspath(dir), index, cache)


def dentro(raiz: str, alvo: str) -> bool:
    """O alvo normalizado fica debaixo da raiz?

    A comparação é por PREFIXO MAIS SEPARADOR, e o separador não é decoração:
    sem ele, uma raiz `/srv/www` deixaria passar `/srv/www-privado`, que é um
    directório completamente diferente com o mesmo princípio.
    """
    if alvo == raiz:
        return True
    return alvo.startswith(raiz + "/")


def etag_de(tamanho: int, mtime_ns: int) -> str:
    """Um ETag FORTE a partir do que se sabe sem ler o ficheiro.

    Forte e não fraco (`W/`) porque a comparação que o `Range` precisa exige um
    validador forte (RFC 9110 §13.1.3): com um fraco, um cliente que peça um
    pedaço depois de o ficheiro mudar receberia dois pedaços de ficheiros
    diferentes e ninguém daria por isso.
    """
    return "\"" + str(tamanho) + "-" + str(mtime_ns) + "\""


def parse_range(cab: str, tamanho: int) -> List<int>:
    """`bytes=0-499` -> `[0, 499]`. `[]` quando não se aplica, `[-1, -1]` quando
    é impossível de satisfazer (e aí a resposta é 416).

    Só a forma de UM intervalo. Vários intervalos numa resposta obrigam a um
    corpo `multipart/byteranges`, e nenhum cliente que interesse os pede: um
    leitor de vídeo pede um intervalo de cada vez.
    """
    if not cab.startswith("bytes="):
        return []
    spec = cab[6:]
    if spec.find(",") >= 0:
        return []
    i = spec.find("-")
    if i < 0:
        return []
    a = spec[0:i].strip()
    b = spec[i + 1:].strip()
    if len(a) == 0:
        # `-500`: os ÚLTIMOS 500 bytes
        if len(b) == 0 or not b.isdigit():
            return []
        n = int(b)
        if n == 0:
            return [-1, -1]
        ini = tamanho - n
        return [0 if ini < 0 else ini, tamanho - 1]
    if not a.isdigit():
        return []
    ini2 = int(a)
    if ini2 >= tamanho:
        return [-1, -1]
    if len(b) == 0:
        return [ini2, tamanho - 1]
    if not b.isdigit():
        return []
    fim = int(b)
    if fim >= tamanho:
        fim = tamanho - 1
    if fim < ini2:
        return [-1, -1]
    return [ini2, fim]


async def ler_pedaco(caminho: str, ini: int, n: int) -> bytes:
    """Um pedaco do ficheiro, sem ler o resto.

    E o `pread` e nao um `seek` seguido de `read`, e a diferenca importa mesmo com
    um so worker: o `pread` leva o deslocamento COMO ARGUMENTO e nao mexe no
    cursor, portanto duas leituras do mesmo ficheiro nao se atrapalham. Com um
    cursor partilhado, dois pedidos de `Range` ao mesmo video intercalam-se e cada
    um le o pedaco do outro.

    E e por causa dele que o `Range` de um video de um gigabyte nao custa um
    gigabyte de memoria."""
    if n <= 0:
        return b""
    with await open(caminho, "r") as fh:
        with Buffer(n) as buf:
            k = os.pread(fh, buf, ini, n)
            return bytes(buf[0:k])


async def serve(f: Files, req: httpd.Request) -> httpd.Response:
    """O handler. `req.path` e o caminho pedido; o que ele nomeia e procurado
    debaixo da raiz, e tudo o que nao ficar la debaixo e 403."""
    if req.method != "GET" and req.method != "HEAD":
        r0 = httpd.status_code(405)
        r0.headers.append(httpd.Header("allow", "GET, HEAD"))
        return r0

    # o caminho pedido vem percent-decodificado UMA vez, e nao duas: decodificar
    # duas vezes faria `%252e%252e` virar `..`, que e o truque
    rel = httpd.pct_decode_seg(req.path)
    if rel.find(chr(0)) >= 0:
        # um NUL no caminho e sempre um ataque: nenhum ficheiro tem um no nome, e
        # a razao de ele ser tentado e truncar a string numa camada escrita em C
        return httpd.status_code(400)

    alvo = path.normpath(path.join(f.raiz, rel[1:] if rel.startswith("/") else rel))
    if not dentro(f.raiz, alvo):
        # AQUI e onde o path traversal morre, e note-se o que NAO se fez: nao se
        # procuraram `..` no texto. Essa defesa rompe-se porque ha sempre mais
        # uma grafia -- `%2e%2e`, `..%2f`, `.%2e/`, `..;/`. Esta compara o
        # caminho NORMALIZADO com a raiz, e nao ha grafia que escape a isso.
        return httpd.status_code(403)

    if path.isdir(alvo):
        if len(f.index) == 0:
            # D21: NUNCA lista. Uma listagem e vazamento por omissao, e quem a
            # tem costuma nao saber que a tem -- por isso nem como interruptor.
            return httpd.status_code(404)
        alvo = path.join(alvo, f.index)

    if not path.isfile(alvo):
        return httpd.status_code(404)

    tamanho = path.getsize(alvo)
    et = etag_de(tamanho, path.getmtime_ns(alvo))
    tipo = mime_for(alvo)

    # ---- 304: o cliente ja tem esta versao ----
    #
    # A conferencia e ANTES de qualquer leitura, que e o ponto inteiro do ETag:
    # um 304 que lesse o ficheiro para o poder recusar nao pouparia nada.
    inm = req.header("if-none-match")
    if len(inm) > 0 and (inm == et or inm == "*"):
        r1 = httpd.status_code(304)
        r1.headers.append(httpd.Header("etag", et))
        return r1

    cabecalhos: List<httpd.Header> = [
        httpd.Header("content-type", tipo),
        httpd.Header("etag", et),
        # dizer que se aceita `Range` e o que faz um leitor de video tentar
        # saltar em vez de descarregar tudo
        httpd.Header("accept-ranges", "bytes"),
    ]
    if len(f.cache) > 0:
        cabecalhos.append(httpd.Header("cache-control", f.cache))

    # ---- Range: um pedaco ----
    rg = req.header("range")
    if len(rg) > 0:
        # `If-Range`: o pedaco so e servido se o ficheiro for O MESMO. Sem isto,
        # um cliente que retoma uma descarga de um ficheiro que mudou entretanto
        # cose dois ficheiros diferentes e ninguem da por isso.
        ifr = req.header("if-range")
        if len(ifr) == 0 or ifr == et:
            faixa = parse_range(rg, tamanho)
            if len(faixa) == 2 and faixa[0] < 0:
                r2 = httpd.status_code(416)
                r2.headers.append(httpd.Header("content-range", "bytes */" + str(tamanho)))
                return r2
            if len(faixa) == 2:
                n = faixa[1] - faixa[0] + 1
                corpo = await ler_pedaco(alvo, faixa[0], n)
                r3 = httpd.Response(206, cabecalhos, corpo, False)
                r3.headers.append(httpd.Header("content-range",
                    "bytes " + str(faixa[0]) + "-" + str(faixa[1]) + "/" + str(tamanho)))
                return r3

    return httpd.Response(200, cabecalhos, await ler_pedaco(alvo, 0, tamanho), False)
