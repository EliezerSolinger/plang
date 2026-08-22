# o par de proc.psc: as MESMAS linhas, pelo `subprocess` do python3.
#
# `capture_output` com `stderr=STDOUT` é o que o nosso `os.run` faz: um cano só,
# na ordem em que as duas saídas aconteceram. E `env=` do subprocess substitui o
# ambiente, que é a mesma decisão que tomamos — mesclar não tem resposta única.
import subprocess


def run(argv, env=None, cwd=None):
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                       env=env, cwd=cwd)
    st = p.returncode
    # o shell (e nós) contam um filho morto por sinal como 128+sinal; o Python
    # devolve -sinal
    if st < 0:
        st = 128 - st
    return st, p.stdout.decode()


st, out = run(["/bin/echo", "ola"])
print(st, out)

st, out = run(["/bin/echo", "a b", "c"])
print(st, out)

st, out = run(["/bin/sh", "-c", "exit 7"])
print(st, out)

st, out = run(["/bin/sh", "-c", "echo um; echo dois >&2"])
print(st, out)

st, out = run(["/bin/sh", "-c", "kill -9 $$"])
print(st, out)

st, out = run(["/bin/sh", "-c", "echo [$ORACULO][$HOME]"], env={"ORACULO": "1"})
print(st, out)

st, out = run(["/bin/pwd"], cwd="/tmp")
print(st, out)
