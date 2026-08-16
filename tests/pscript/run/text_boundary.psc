"""Texto atravessando a fronteira P↔pscript (81/83/84/85/86).

O `str` do pscript e o `const *char` do P nunca se encontravam: a 45.5 só
deixava escalar passar. Agora existe um par — `CStr` para texto, `CBytes` para
bytes — que é um PONTEIRO E O TAMANHO DELE, como valor, e que não aloca nada.

Na IDA é empréstimo: o compilador monta o par apontando para os próprios bytes
do objeto, e isso é seguro porque uma chamada C não coleta (só `ps_gc_poll`
coleta, e C não o chama), então nada se move debaixo dela.

Na VOLTA é cópia, e para texto é cópia CONFERIDA: o P nunca dá posse — devolve
estático ou um buffer seu — e um `str` promete codepoints, então bytes que não
são UTF-8 válido lançam em vez de virar uma string que mente sobre si.
"""

import "pmod_text.ph"

nome = "olá mundo"
print("tamanho em BYTES do lado P:", texto_tamanho(nome))
print("tamanho em CARACTERES aqui:", len(nome))

print("maiusculo:", texto_maiusculo("plang e pscript"))
print("versao:", versao())

b: list<u8> = [1, 2, 3, 250]
print("soma dos bytes:", bytes_soma(b))

try:
    print(nao_utf8())
catch e:
    print("recusado:", e.message)
