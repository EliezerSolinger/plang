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

    r = await conn.query("SELECT id, nome FROM jogadores WHERE nivel > 10")
    for row in r.rows:
        id_bytes = row[0]
        nome_bytes = row[1]
        # cada valor é `bytes?` — None é o NULL de SQL, e a conversão para
        # número/texto é de quem sabe o tipo da coluna
        ...

    # NUNCA concatene o valor no SQL — isso é injeção. Use %s:
    r = await conn.query_str(
        "SELECT id FROM jogadores WHERE nome = %s AND nivel > %s",
        [nome_digitado, str(nivel_minimo)])

    up = await conn.execute("UPDATE jogadores SET online = 1 WHERE id = 42")
    print(up.affected_rows)

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
| `ping()` / `select_db()` / `close()` | |
| erro do servidor | vira exceção com o código e a mensagem (`MySQL 1045: Access denied...`) |

Cada valor de uma linha chega como `bytes?`. **Não há conversão de tipo por
coluna ainda** — quem lê sabe se a coluna é `INT` ou `VARCHAR` e chama `int(...)`
ou `str(...)`. É a decisão que o `csv` do próprio pscript tomou pela mesma razão
(não adivinhar que `007` é sete perde o zero de um CEP).

## O que falta, e onde entraria

- **`caching_sha2_password`** (o padrão do MySQL 8) e **`ed25519`** (uma opção do
  MariaDB): o primeiro precisa de RSA no caminho lento, o segundo de curva de
  Edwards. O ponto de entrada é o pedido de troca de plugin, tratado em
  `connect`.
- **Prepared statements do protocolo** (`COM_STMT_*`): hoje um valor entra por
  escape (`query_str`), que é o que o PyMySQL faz — o `execute(sql, args)` dele
  também escapa no cliente e manda texto, não usa `COM_STMT`. O protocolo binário
  seria mais rápido para a mesma query repetida muitas vezes; para segurança, o
  escape já resolve.
- **TLS**: o pscript tem `net.starttls`; o gancho é depois do handshake, antes do
  login.
- **Conversão de tipo por coluna**: o `type_code` do `Field` já está lido.

## Estrutura

```
packet.psc    o pacote e o cursor: inteiros LE, length-encoded, strings
sha1.psc      SHA-1 em pscript puro (o handshake precisa; ~70 linhas)
auth.psc      scramble_native_password: SHA1(pw) XOR SHA1(salt ++ SHA1(SHA1(pw)))
escape.psc    escapar um valor para dentro de uma query (a defesa contra injeção)
mysql.psc     a conexão: handshake, login, query, leitura de resultado
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
