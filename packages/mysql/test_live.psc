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

    # 1. a versao, pelo proprio SQL
    r1 = await conn.query("SELECT VERSION()")
    if len(r1.rows) > 0:
        v = r1.rows[0][0]
        if v != None:
            print(f"SELECT VERSION() = {str(v)}")

    # 2. quantas tabelas o banco tem
    r2 = await conn.query("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()")
    if len(r2.rows) > 0:
        c = r2.rows[0][0]
        if c != None:
            print(f"tabelas no banco: {str(c)}")

    # 3. algumas linhas de verdade, com nomes de coluna
    r3 = await conn.query("SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema = DATABASE() ORDER BY table_name LIMIT 5")
    print(f"colunas: ")
    for f in r3.fields:
        print(f"  - {f.name} (type {f.type_code})")
    print(f"primeiras {len(r3.rows)} tabelas:")
    for row in r3.rows:
        nome = row[0]
        linhas = row[1]
        ns = "?"
        if nome != None:
            ns = str(nome)
        ls = "?"
        if linhas != None:
            ls = str(linhas)
        print(f"  {ns}: {ls} linhas")

    # 4. uma query PARAMETRIZADA — a forma segura, com o valor escapado
    r4 = await conn.query_str("SELECT table_name FROM information_schema.tables WHERE table_schema = %s AND table_name LIKE %s LIMIT 3", [db, "a%"])
    print(f"tabelas que comecam com 'a' ({len(r4.rows)}):")
    for row in r4.rows:
        nm = row[0]
        if nm != None:
            print(f"  {str(nm)}")

    # 5. ping
    await conn.ping()
    print("ping ok")

    await conn.close()
    print("fechado. o conector funciona.")
    return 0


sys.exit(await main())
