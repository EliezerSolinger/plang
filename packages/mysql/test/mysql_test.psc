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

print("fim")
