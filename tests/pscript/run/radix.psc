"""`0o` e `0b`, e os separadores.

O texto do token é normalizado para decimal no lexer, então o que sai no C e o
que o QBE lê são o mesmo número — e o `0b`, que não é C, nunca chega ao C.
"""

print(0o755, 0o0, 0o7777)
print(0b1010, 0b0, 0b1111_1111)
print(0xFF, 0xff_ff)
print(1_000_000, 255 == 0b1111_1111)
print(0o644 == 420, 0b11 == 3)
