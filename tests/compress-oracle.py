"""O oraculo do compressor: o `zlib` do CPython e o `gunzip`.

Um compressor que so o nosso proprio `inflate` lesse teria os dois com o mesmo
defeito -- e por isso quem confere aqui sao dois leitores que nao compartilham
uma linha com este repositorio.
"""
import glob, gzip, os, subprocess, sys

d = sys.argv[1]
ok = 0
total = 0
for gz in sorted(glob.glob(d + "/caso*.gz"), key=lambda p: int(os.path.basename(p)[4:-3])):
    cru = gz[:-3] + ".raw"
    total += 1
    try:
        saiu = gzip.decompress(open(gz, "rb").read())
    except Exception as e:
        print("  FALHOU o zlib:", os.path.basename(gz), e)
        continue
    esperado = open(cru, "rb").read()
    if saiu == esperado:
        ok += 1
    else:
        print("  DIVERGIU:", os.path.basename(gz), len(saiu), "vs", len(esperado))
print("o zlib abriu e bate:", ok, "de", total)
r = subprocess.run(["gunzip", "-t"] + sorted(glob.glob(d + "/caso*.gz")), capture_output=True)
print("o gunzip -t aceita todos:", r.returncode == 0)
