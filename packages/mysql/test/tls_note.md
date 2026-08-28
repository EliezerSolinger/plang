# Testar o TLS e a autenticação contra um servidor

O teste offline (`mysql_test.psc`) prova o protocolo e os três scrambles de auth
contra vetores — roda em qualquer máquina, sem servidor. Estes precisam de um
MariaDB/MySQL de verdade e saem do corpus por isso.

## Login e queries (sem TLS)

```sh
DB_HOST=127.0.0.1 DB_USER=... DB_PASSWORD=... DB_NAME=... \
    pforge run packages/mysql/test_live.psc
```

Exercita: conversão de tipo por coluna, acesso por nome, datas, streaming,
transação com rollback, execute_many. Só leitura no banco (a transação faz
rollback; o execute_many usa uma tabela TEMPORARY).

## TLS

O TLS precisa do runtime compilado com `-D PSRT_TLS` e linkado a `-lssl
-lcrypto` — o `pforge run` não passa esses por padrão, então compila-se à mão:

```sh
plangc --pkg-path packages -D PSRT_TLS --out-dir out pscript/runtime/psrt.ph
plangc --pkg-path packages -D PSRT_TLS --out-dir out prog.psc
cc -D_POSIX_C_SOURCE=200112L -D_DEFAULT_SOURCE -Iout \
   out/prog.c out/pscript/runtime/psrt_*.c -o prog -lm -pthread -lssl -lcrypto
```

No `connect`, `tls=True` liga; `tls_verify=False` aceita o certificado
auto-assinado que um MariaDB gera sozinho. Contra o MariaDB local, a ligação
negocia TLS 1.3 (`TLS_AES_256_GCM_SHA384`).

## Os plugins de auth

`mysql_native_password` é o padrão do MariaDB e o que o `test_live` usa.
`caching_sha2_password` (MySQL 8) e `client_ed25519` (MariaDB) entram por Auth
Switch — para exercitá-los, crie um usuário com `IDENTIFIED VIA
caching_sha2_password` ou `ed25519`. Os três scrambles estão conferidos byte a
byte contra o pymysql no teste offline.
