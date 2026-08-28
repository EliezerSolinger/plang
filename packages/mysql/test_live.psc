"""Teste de integração contra um MariaDB de verdade.

Não vai no corpus — precisa de um servidor e de credenciais, que vêm do
ambiente, e o corpus tem de rodar em qualquer máquina. É o análogo do
`tests/tls.sh`, que também fala com o mundo.

    DB_HOST=127.0.0.1 DB_PORT=3306 DB_USER=... DB_PASSWORD=... DB_NAME=... \
        pforge run packages/mysql/test_live.psc

O programa é SÓ LEITURA: um SELECT de versão, um de contagem, e um de linhas. Não
escreve nada — é para provar o conector, não para mexer no banco.
"""

import sys
import <mysql/mysql.psc> as my


async def main() -> int:
    env = sys.env
    host = env.get("DB_HOST", "127.0.0.1")
    port_s = env.get("DB_PORT", "3306")
    user = env.get("DB_USER", "")
    password = env.get("DB_PASSWORD", "")
    db = env.get("DB_NAME", "")

    if len(user) == 0:
        print("faltam credenciais: exporte DB_USER, DB_PASSWORD, DB_NAME")
        return 1

    if host == "localhost":
        host = "127.0.0.1"   # o conector fala TCP; o socket unix e' outra porta

    port = int(port_s)
    print(f"conectando em {host}:{port} como {user}, banco {db}...")

    conn = await my.connect(host, port, user, password, db)
    print(f"conectado. servidor: {conn.server_version}")

    # 1. a versao, via scalar()
    v = (await conn.query("SELECT VERSION()")).scalar()
    if v != None:
        print(f"SELECT VERSION() = {str(v)}")

    # 2. contagem: um int de verdade, ja convertido (nao mais bytes)
    cnt = await conn.query("SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()")
    one = cnt.one()
    if one != None:
        n = one.get_int("n")   # <- INT convertido, acesso por NOME
        print(f"tabelas no banco: {n}  (typestr {typestr(n)})")

    # 3. linhas com acesso por NOME e tipo — o table_rows vem como int
    r3 = await conn.query("SELECT table_name, table_rows, create_time FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name LIMIT 3")
    print("colunas:")
    for f in r3.fields:
        print(f"  - {f.name} (type {f.type_code})")
    print("linhas (nome por get_str, linhas por get_int, data por get_datetime):")
    for row in r3.rows:
        name_s = row.get_str("table_name")
        rows = row.get_int("table_rows")
        when = "?"
        if not row.is_null("create_time"):
            d = row.get_datetime("create_time")
            when = f"{d.date.year}-{d.date.month}-{d.date.day}"
        print(f"  {name_s}: {rows} linhas, criada {when}")

    # 4. uma query PARAMETRIZADA — a forma segura, com o valor escapado
    r4 = await conn.query_str("SELECT table_name FROM information_schema.tables WHERE table_schema = %s AND table_name LIKE %s LIMIT 3", [db, "a%"])
    print(f"tabelas que comecam com 'a' ({len(r4.rows)}):")
    for row in r4.rows:
        print(f"  {row.get_str(\"table_name\")}")

    # 4b. STREAMING: ler linha a linha via cursor, sem carregar tudo
    cur = await conn.query_stream("SELECT table_name FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name")
    n = 0
    while True:
        row = await cur.next_row()
        if row == None:
            break
        n += 1
        if n <= 2:
            print(f"stream linha {n}: {row.get_str(\"table_name\")}")
    print(f"streaming leu {n} linhas uma a uma")

    # 5. TRANSACAO com rollback: prova begin/rollback sem deixar rastro no banco
    #    de producao. Cria uma tabela temporaria, insere, conta, e desfaz TUDO.
    await conn.query("CREATE TEMPORARY TABLE _dcp_probe (id INT, nome VARCHAR(50))")
    await conn.begin()
    await conn.query_str("INSERT INTO _dcp_probe (id, nome) VALUES (%s, %s)", ["1", "O'Brien"])
    await conn.query_str("INSERT INTO _dcp_probe (id, nome) VALUES (%s, %s)", ["2", "linha\ndupla"])
    inside = (await conn.query("SELECT COUNT(*) FROM _dcp_probe")).scalar()
    if inside != None:
        print(f"dentro da transacao: {str(inside)} linhas")
    await conn.rollback()
    after = (await conn.query("SELECT COUNT(*) FROM _dcp_probe")).scalar()
    if after != None:
        print(f"depois do rollback: {str(after)} linhas (deve ser 0)")

    # 6. execute_many: duas linhas de uma vez, e le de volta com o valor escapado
    await conn.execute_many("INSERT INTO _dcp_probe (id, nome) VALUES (%s, %s)",
                            [["10", "a'b"], ["20", "c\\d"]])
    n_read = await conn.query("SELECT id, nome FROM _dcp_probe ORDER BY id")
    print(f"execute_many inseriu {len(n_read.rows)}:")
    for row in n_read.rows:
        print(f"  id={row.get_int(\"id\")} nome={row.get_str(\"name_s\")}")

    # 7. ping
    await conn.ping()
    print("ping ok")

    await conn.close()
    print("fechado. o conector funciona.")
    return 0


sys.exit(await main())
