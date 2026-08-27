"""O que se prova SEM um servidor: o protocolo e a autenticação, contra vetores.

A conexão de verdade está em `../test_live.psc`, que precisa de um MariaDB e sai
do corpus por isso. Aqui fica o que roda em qualquer máquina — e é onde os dois
bugs que o porte teve morreriam antes de chegar ao servidor.
"""

import <mysql/packet.psc> as pkt
import <mysql/sha1.psc> as sha
import <mysql/auth.psc> as auth
import <mysql/mysql.psc> as my


def check(nome: str, got: str, want: str):
    if got == want:
        print(f"ok {nome}")
    else:
        print(f"FALHOU {nome}: {got} != {want}")


check("sha1 vazio", sha.sha1(bytes([])).hex(), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
check("sha1 abc", sha.sha1(b"abc").hex(), "a9993e364706816aba3e25717850c26c9cd0d89d")

salt20 = bytes([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20])
sc = auth.scramble_native_password(b"foobar", salt20)
check("scramble foobar", sc.hex(), "e419caeec63ade5aeb8e0f8bbb2ac2d86b183350")
empty = auth.scramble_native_password(bytes([]), salt20)
check("scramble vazio", f"{len(empty)}", "0")

q = pkt.new_packet(bytes([0x78, 0x56, 0x34, 0x12]))
check("uint32 LE", f"{q.read_uint32()}", "305419896")
r = pkt.new_packet(bytes([0x01, 0x02]))
check("uint16 LE", f"{r.read_uint16()}", "513")
t = pkt.new_packet(bytes([0xFC, 0x2C, 0x01]))
lv = t.read_length_encoded_integer()
if lv != None:
    check("lenenc 300", f"{lv}", "300")

check("lenenc write 10", pkt.lenenc_int(10).hex(), "0a")
check("lenenc write 300", pkt.lenenc_int(300).hex(), "fc2c01")
check("lenenc write 70000", pkt.lenenc_int(70000).hex(), "fd701101")

# ── o escape e a query parametrizada: a defesa contra injecao ─────────────────
check("format simples", my.format_query("id = %s", ["5"]), "id = '5'")
check("format aspas", my.format_query("nome = %s", ["O'Brien"]), "nome = 'O\\'Brien'")
check("format porcento", my.format_query("100%% e %s", ["x"]), "100% e 'x'")
check("format dois", my.format_query("%s e %s", ["a", "b"]), "'a' e 'b'")

# ── conversao de valor por tipo de coluna ────────────────────────────────────
# um Field falso e o valor cru; convert_value decide o tipo pscript
fi_int = my.Field("n", my.FIELD_LONG, 63, 0)
vi = my.convert_value(b"12345", fi_int)
if vi != None:
    check("convert INT", f"{vi as int}", "12345")
    check("convert INT tipo", typestr(vi as int), "int")

fi_big = my.Field("n", my.FIELD_LONGLONG, 63, 0)
vb = my.convert_value(b"9223372036854775807", fi_big)
if vb != None:
    check("convert BIGINT", f"{vb as int}", "9223372036854775807")

fi_dbl = my.Field("f", my.FIELD_DOUBLE, 63, 0)
vf = my.convert_value(b"3.14159", fi_dbl)
if vf != None:
    check("convert DOUBLE", f"{vf as float}", "3.14159")

fi_str = my.Field("s", my.FIELD_VAR_STRING, 45, 0)
vs = my.convert_value(b"texto", fi_str)
if vs != None:
    check("convert VARCHAR", vs as str, "texto")

# NULL atravessa como None
vn = my.convert_value(None, fi_int)
check("convert NULL", f"{vn == None}", "True")

# ── uma Row montada a mao: acesso por nome e por tipo ────────────────────────
flds: List<my.Field> = [my.Field("level", my.FIELD_LONG, 63, 0),
                        my.Field("nome", my.FIELD_VAR_STRING, 45, 0)]
raws: List<bytes?> = [b"42", b"Steve"]
rw = my.Row(flds, raws)
check("row get_int por nome", f"{rw.get_int(\"level\")}", "42")
check("row get_str por nome", rw.get_str("nome"), "Steve")
check("row column ausente", f"{rw.column(\"xyz\")}", "-1")

print("fim")
