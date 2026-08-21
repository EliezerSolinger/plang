"""A camada de sistema: `os` e `path` (111).

Vinda do `psys.p` do pstudio, porque a decisão 1.1 do pbuild manda a parte de
sistema para a lib/runtime do pscript — o editor e o build passam a usar a
MESMA. As contas sobre o NOME (join/dirname/basename/normpath) são conferidas
por varredura contra o `posixpath` do CPython em tests/oracle/py/paths.psc; o
que este arquivo mede é o que TOCA o disco, que nenhum oráculo pode conferir.

Duas escolhas que se veem aqui:
  * `listdir` devolve ORDENADO. O Python devolve na ordem do sistema de
    arquivos, e essa é a divergência deliberada: um build e um editor querem a
    mesma lista em toda máquina, e quem tem a ordenada não pode recuperar a do
    disco — o contrário é `sorted()`.
  * `mkdir` levanta se o diretório existe; `makedirs` é o `mkdir -p` e não
    levanta. É o `exist_ok=True` que todo mundo escreve no Python, posto como
    padrão de quem cria a árvore inteira.
"""
import os
import path

D: str = "syslayer_demo"

os.makedirs(D + "/sub/deep")
print("makedirs again ok: " + str(path.isdir(D + "/sub/deep")))
os.makedirs(D + "/sub/deep")          # já existe: não levanta

# `await f.close()` e não `f.close()`: um `close` sem `await` é uma TASK
# pendente, e o `getsize` logo abaixo veria o arquivo ainda com os bytes no
# buffer do stdio. É o modelo de tasks a funcionar, e é uma armadilha registrada
# na 111.4 — quem escreve e depois LÊ o que escreveu tem de esperar o close.
f = await open(path.join(D, "b.txt"), "w")
await f.write("two")
await f.close()
g = await open(path.join(D, "a.txt"), "w")
await g.write("hello world")
await g.close()

print(os.listdir(D))
print(os.listdir(D + "/sub"))
print("size a=" + str(path.getsize(D + "/a.txt")) + " b=" + str(path.getsize(D + "/b.txt")))
print("mtime recente: " + str(path.getmtime(D + "/a.txt") > 1600000000))
print("isfile/isdir/exists: " + str(path.isfile(D + "/a.txt")) + " " + str(path.isdir(D + "/a.txt")) + " " + str(path.exists(D + "/a.txt")))
print("ausente: " + str(path.exists(D + "/nope")) + " " + str(path.isdir(D + "/nope")) + " " + str(path.isfile(D + "/nope")))

os.rename(D + "/a.txt", D + "/c.txt")
print(os.listdir(D))

# `getcwd` e `abspath`: um caminho relativo passa a começar na raiz, e o
# `abspath` de "." é o próprio diretório de trabalho
print("cwd absoluto: " + str(os.getcwd().startswith("/")))
print("abspath('.') == getcwd(): " + str(path.abspath(".") == os.getcwd()))
print("abspath junta e normaliza: " + str(path.abspath(D + "/./x/../y") == os.getcwd() + "/" + D + "/y"))

# ---- o que levanta ----
try:
    os.listdir(D + "/nope")
    print("unreachable")
catch e:
    print("listdir: " + e.message + " (io? " + str(e.category == IO) + ")")
try:
    path.getsize(D + "/nope")
catch e:
    print("getsize: " + e.message)
try:
    os.mkdir(D + "/sub")
catch e:
    print("mkdir: " + e.message)
try:
    os.remove(D + "/nope")
catch e:
    print("remove: " + e.message)
try:
    os.rmdir(D)          # não está vazio
catch e:
    print("rmdir: " + e.message)
try:
    os.rename(D + "/nope", D + "/n2")
catch e:
    print("rename: " + e.message)
# um caminho com o byte 0 no meio cortaria no zero e agiria sobre OUTRO arquivo
try:
    print(path.exists(D + chr(0) + "/a.txt"))
catch e:
    print("nul: " + e.message)

# ---- limpeza, que é o resto da API ----
os.remove(D + "/b.txt")
os.remove(D + "/c.txt")
os.rmdir(D + "/sub/deep")
os.rmdir(D + "/sub")
os.rmdir(D)
print("limpo: " + str(path.exists(D)))
