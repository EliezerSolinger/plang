# mysql — cliente MySQL/MariaDB em pscript

O protocolo cliente-servidor do MySQL, portado de
[PyMySQL](https://github.com/PyMySQL/PyMySQL) 1.2.0, sobre a `net` do pscript.
Síncrono no Python, **`async` aqui**: cada leitura do socket estaciona a tarefa
(77.1), então uma query não trava a thread — é o "NIO" do pscript posto a
trabalhar, e é o que um servidor de jogo com muitas conexões precisa.

Escrito para o **Desbravacraft**, cujo servidor fala MariaDB.

## Uso

```python
import <mysql/mysql.psc> as my

async def main() -> int:
    conn = await my.connect("127.0.0.1", 3306, "usuario", "senha", "banco")

    r = await conn.query("SELECT id, nome, nivel FROM jogadores WHERE nivel > 10")
    for row in r.rows:
        # acesso por NOME e por TIPO — o valor já vem convertido
        id = row.get_int("id")          # INT -> int
        nome = row.get_str("nome")      # VARCHAR -> str
        nivel = row.get_int("nivel")
        ...

    # o caso "no máximo uma linha":
    dono = (await conn.query_str(
        "SELECT nome FROM jogadores WHERE id = %s", [str(id)])).one()
    if dono != None:
        print(dono.get_str("nome"))

    # e o escalar direto:
    total = (await conn.query("SELECT COUNT(*) FROM jogadores")).scalar()

    # NUNCA concatene o valor no SQL — isso é injeção. Use %s:
    r = await conn.query_str(
        "SELECT id FROM jogadores WHERE nome = %s AND nivel > %s",
        [nome_digitado, str(nivel_minimo)])

    # transação: as escritas valem JUNTAS, ou nenhuma
    await conn.begin()
    try:
        await conn.query_str("UPDATE jogadores SET online = 1 WHERE id = %s", [str(id)])
        await conn.query_str("INSERT INTO log (evento) VALUES (%s)", ["entrou"])
        await conn.commit()
    catch e:
        await conn.rollback()
        raise e

    await conn.close()
    return 0

sys.exit(await main())
```

## O que existe

| | |
|---|---|
| aperto de mão + login | `mysql_native_password` (o plugin padrão do MariaDB) |
| `query(sql)` / `execute(sql)` | devolvem um `Result` (colunas, linhas, `affected_rows`, `insert_id`) |
| `query_str(sql, args)` | uma query com `%s`, cada arg ESCAPADO e aspado — a forma segura |
| `Row` com acesso por nome | `row.get_int("level")`, `get_str`, `get_float`, `get_datetime`, `get`, `raw` |
| conversão de tipo por coluna | INT→`int`, DOUBLE→`float`, DATETIME→`LocalDateTime`, TEXT/JSON/ENUM→`str` |
| `Result.one()` / `.scalar()` | a linha única, o valor único (o `fetchone` do DB-API) |
| transações | `begin()` / `commit()` / `rollback()` / `set_autocommit()` |
| `execute_many(sql, rows)` | o mesmo comando por linha, numa transação se envolvido |
| `query_stream(sql)` → `Cursor` | lê linha a linha (`cur.next_row()`), sem carregar tudo — para SELECTs grandes |
| `next_result()` / `has_next()` | drena os result sets de uma multi-statement |
| **TLS** (`connect(..., tls=True)`) | cifra a ligação antes de a senha viajar (TLS 1.3 conferido) |
| autenticação | `mysql_native_password`, `caching_sha2_password` (MySQL 8), `client_ed25519` (MariaDB) |
| `ping()` / `select_db()` / `close()` | |
| erro do servidor | vira exceção com o código e a mensagem (`MySQL 1045: Access denied...`) |

Um valor de coluna vem no tipo que a coluna promete, como `any` (carrega o seu
tipo): `row.get("x")` devolve `any?`, e os atalhos `get_int`/`get_str`/... fazem o
`as` e levantam no NULL. Um **DECIMAL fica `str`** de propósito — um preço com
casas exatas viraria float e perderia o centavo, a mesma razão pela qual o `csv`
do pscript não adivinha que `007` é sete. Um **BLOB binário** vira `bytes` (o
`any` do core aprendeu a guardá-los durante este porte), e `row.raw()` continua
sendo o atalho direto para os bytes crus de qualquer coluna.

## O que existe agora, e o que ainda falta

Tudo o que o `pymysql` tem de essencial está aqui:

- **TLS** (`tls=True`, `tls_verify=False` para cert auto-assinado): manda um SSL
  Request, sobe o TLS pelo `net.starttls` do pscript, e só então o login viaja —
  cifrado. Conferido contra o MariaDB: `TLS_AES_256_GCM_SHA384` (TLS 1.3). O
  runtime do pscript ganhou um conserto no caminho: `SSL_pending` antes do
  `poll`, sem o qual qualquer protocolo TLS 1.3 que leia logo após o handshake
  trava.
- **Três plugins de auth**, cada um conferido byte a byte contra o pymysql:
  `mysql_native_password`, `caching_sha2_password` (o padrão do MySQL 8; caminho
  rápido com SHA-256, caminho lento com a senha sobre TLS) e `client_ed25519` (o
  do MariaDB, que usa o pacote `ed25519` do repo).
- **Streaming** (`query_stream`): um `Cursor` que entrega linha a linha, para o
  SELECT que não cabe na memória.
- **Multi-result** (`next_result`/`has_next`): drena os result sets de uma
  multi-statement.

O que fica de fora, e é o que o próprio pymysql também não faz ou raramente usa:

- **Prepared statements do protocolo** (`COM_STMT_*`): um valor entra por escape
  (`query_str`), que é o que o PyMySQL faz — o `execute(sql, args)` dele também
  escapa no cliente e manda texto. O protocolo binário seria mais rápido para a
  mesma query repetida muitas vezes.
- **`caching_sha2` sem TLS** (o caminho lento por RSA): com TLS ligado funciona;
  sem TLS, o RSA para cifrar a senha não está implementado.
- **`datetime` dentro de `any`**: um `LocalDateTime` é um `record`, e o `any` do
  core guarda números, bools, strings, bytes, listas e dicts — não records. Por
  isso uma data vem por `get_datetime()` (que a parseia dos bytes crus), não no
  `get()` genérico. `bytes` JÁ cabe no `any` (foi acrescentado neste porte),
  então um BLOB binário vem no `get()` como qualquer valor.

## Estrutura

```
packet.psc    o pacote e o cursor: inteiros LE, length-encoded, strings
sha1.psc      SHA-1 em pscript puro (o handshake precisa; ~70 linhas)
auth.psc      scramble_native_password: SHA1(pw) XOR SHA1(salt ++ SHA1(SHA1(pw)))
escape.psc    escapar um valor para dentro de uma query (a defesa contra injeção)
mysql.psc     a conexão: handshake, login, query, conversão, Row, transações
test/         o que se prova sem servidor (vetores de SHA-1 e do scramble)
test_live.psc a conexão de verdade, contra um MariaDB (fora do corpus)
```

## Os dois bugs que o porte teve, guardados nos testes

1. **`u8 << 8` fica preso em 8 bits.** `b[i]` devolve `u8`, e a aritmética de
   largura estreita mascara à largura (68.2). Ler um inteiro LE de bytes exige
   `int(b[i])` ANTES do shift, ou o byte alto some — e some em silêncio, o
   programa compila e roda. `test/` prende isso com `uint32 LE`.
2. **Um byte a menos no salt.** O desafio do handshake é 8 + 12 bytes, e o NUL
   terminador vem DEPOIS dos 12, não dentro. Tirar um byte dá um salt de 19 e o
   servidor recusa com "Access denied" — sem dizer que o problema foi o desafio.

## Verificar

```sh
# offline (vetores):
pforge run packages/mysql/test/mysql_test.psc

# contra um MariaDB de verdade (só leitura):
DB_HOST=127.0.0.1 DB_USER=... DB_PASSWORD=... DB_NAME=... \
    pforge run packages/mysql/test_live.psc
```
