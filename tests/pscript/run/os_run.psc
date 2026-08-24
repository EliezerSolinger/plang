"""`os.run` — rodar um processo, e esperá-lo com `await` (118 / pforge 1.2).

A peça que faltava na camada de sistema, e a única que o pforge não tinha como
escrever por fora. O que este arquivo prende:

  * NÃO passa por shell. O comando é um vetor de argumentos e o `execvp` o
    recebe como está — não há aspas para escapar, não há `&&`, não há glob, e
    nada do que o programa escreveu pode virar sintaxe. É por isso que o teste
    do argumento com espaço e aspas existe: num shell ele viraria dois
    argumentos, e aqui ele é um.
  * sair com status != 0 NÃO é exceção. Um `cc` que recusa o programa é
    resultado, e quem chamou decide o que fazer — levantar ali obrigaria todo
    build a envolver toda compilação num `try`.
  * o stderr vem JUNTO com o stdout, na ordem em que saíram, porque é assim que
    um relatório de erro se lê.
  * `env=` SUBSTITUI o ambiente (não mescla): o hash de uma aresta de build
    cobre o ambiente efetivo, e "mescla" não tem resposta única.
  * `stdout=` manda a saída para um arquivo sem passar pela memória — o que um
    build quer quando a saída é o artefato.
  * N processos ao mesmo tempo, com limite, que é o caso de uso inteiro.
"""
import os
import path

async def um(cmd: List<str>) -> proc:
    return await os.run(cmd)

async def go():
    r = await os.run(["/bin/echo", "ola mundo"])
    print("status:", r.status(), "saida:", r.output())

    # um argumento com espaço e aspas é UM argumento: sem shell, não há o que
    # quebrá-lo em dois
    q = await os.run(["/bin/echo", 'a b "c" $HOME'])
    print("um argumento so:", q.output())

    # status != 0 é resultado, e o stderr veio junto
    bad = await os.run(["/bin/sh", "-c", "echo saiu; echo erro >&2; exit 3"])
    print("status:", bad.status(), "saiu e erro:", bad.output())

    # morto por sinal: 128+sinal, a convenção que todo shell usa
    kil = await os.run(["/bin/sh", "-c", "kill -9 $$"])
    print("sinal:", kil.status())

    # env= substitui o ambiente inteiro
    e = await os.run(["/bin/sh", "-c", "echo [$OS_RUN_TESTE][$HOME]"], env={"OS_RUN_TESTE": "sim"})
    print("env:", e.output())

    # cwd= roda em outro diretório
    c = await os.run(["/bin/pwd"], cwd="/tmp")
    print("cwd:", c.output())

    # stdout= vai para o arquivo; o stderr continua vindo em output()
    os.makedirs("os_run_demo")
    s = await os.run(["/bin/sh", "-c", "echo no arquivo; echo no cano >&2"], stdout="os_run_demo/out.txt")
    print("com stdout=, output tem so o cano:", s.output())
    f = await open("os_run_demo/out.txt", "r")
    print("e o arquivo:", await f.text())
    await f.close()

    # N ao mesmo tempo, com limite: o caso do build. A ORDEM em que terminam não
    # é determinística, então o que se mede é a soma e o conjunto.
    cmds = [["/bin/sh", "-c", "echo n" + str(i)] for i in range(8)]
    rs = await gather_map(um, cmds, at_most=3)
    soma = 0
    vistos: List<str> = []
    for x in rs:
        soma += x.status()
        vistos.append(x.output())
    vistos = sorted(vistos)
    print("oito em paralelo: soma dos status", soma, "e", len(vistos), "saidas")
    print("a primeira e a ultima:", vistos[0], vistos[7])

    # o mtime em nanossegundos: mesma coisa que o de segundos, sem jogar fora a
    # parte de baixo — que é o que distingue dois arquivos escritos no mesmo
    # segundo, e é disso que um build incremental depende
    ns = path.getmtime_ns("os_run_demo/out.txt")
    sec = path.getmtime("os_run_demo/out.txt")
    print("mtime_ns bate com mtime:", ns // 1000000000 == sec)

    # e o que a máquina tem para oferecer
    print("nproc >= 1:", os.nproc() >= 1)

    os.remove("os_run_demo/out.txt")
    os.rmdir("os_run_demo")

await go()
