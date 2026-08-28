"""`tz` (S4/149.2): os fusos com nome, lidos de onde eles vivem.

**Este pacote não traz uma cópia das regras. Lê a do sistema**, e o argumento é o
que a própria `STDLIB.md` usa para o `tls`: as regras de fuso mudam várias vezes
por ano, uma cópia nossa estaria errada em produção antes de a tinta secar, e o
mesmo `apt upgrade` que corrige tudo o resto já corrige aquela.

O portão compara com o `zoneinfo` do CPython, e os fusos foram escolhidos um a um
porque cada um apanha uma classe de erro:

* **Europe/Lisbon** — o caso comum, e o `t = 0` apanha quem assume que Portugal
  sempre esteve em WET (em 1970 estava a +1);
* **UTC** — sem mudança nenhuma, o caminho onde a busca binária não corre;
* **America/New_York** — deslocamento negativo, e o sinal do POSIX é ao
  contrário de tudo (`EST5` são cinco horas a OESTE);
* **Asia/Kathmandu** — **quarenta e cinco minutos**, que uma API que contasse
  horas não saberia escrever, e uma mudança de fuso em 1986 que não é DST;
* **Australia/Sydney** e **Pacific/Chatham** — o **hemisfério sul**, onde o verão
  atravessa o Ano Novo e a condição da regra POSIX se inverte. O Chatham é o
  caso duplo: sul E quarenta e cinco minutos.

E dois instantes **para lá do fim do ficheiro** (2050 e 2100), que é onde deixa
de haver transições listadas e passa a mandar a regra POSIX do rodapé. Sem ela,
uma implementação apressada devolve o último deslocamento e erra todas as datas
futuras — em silêncio.
"""
import <tz/tz.psc> as tz


e: List<int> = [0, 0]


def ck(name: str, got: int, want: int):
    if got == want:
        e[0] += 1
    else:
        e[1] += 1
        print("  " + name + ": deu " + str(got) + ", devia " + str(want))


async def go() -> int:
    WHEN: List<int> = [0, 946684800, 1719792000, 1735689600, 2524608000, 4102444800]
    NAMES: List<str> = ["Europe/Lisbon", "UTC", "America/New_York", "Asia/Kathmandu",
                        "Australia/Sydney", "Pacific/Chatham"]
    EXPECT: List<int> = [
        3600, 0, 3600, 0, 0, 0,
        0, 0, 0, 0, 0, 0,
        -18000, -18000, -14400, -18000, -18000, -18000,
        19800, 20700, 20700, 20700, 20700, 20700,
        36000, 39600, 36000, 39600, 39600, 39600,
        45900, 49500, 45900, 49500, 49500, 49500,
    ]
    for zi in range(len(NAMES)):
        z = await tz.load(NAMES[zi])
        for ti in range(len(WHEN)):
            ck(NAMES[zi] + " @" + str(WHEN[ti]), tz.offset_at(z, WHEN[ti]), EXPECT[zi * 6 + ti])

    # o horário de verão diz que é, e onde não há não é
    lx = await tz.load("Europe/Lisbon")
    ck("Lisboa em Julho e verao", 1 if tz.is_dst_at(lx, 1719792000) else 0, 1)
    ck("Lisboa em Janeiro nao e", 1 if tz.is_dst_at(lx, 1735689600) else 0, 0)
    ut = await tz.load("UTC")
    ck("UTC nunca e", 1 if tz.is_dst_at(ut, 1719792000) else 0, 0)

    # ---- o que ele RECUSA, e não é zelo ----
    #
    # o nome vem muitas vezes de fora (um cabeçalho, um campo de formulário), e
    # `../../etc/shadow` é um nome perfeitamente válido para quem não olha
    for mau in ["", "/etc/passwd", "../../etc/shadow", "Europe/../../etc/hosts"]:
        try:
            _ = await tz.load(mau)
            print("  ISTO NAO DEVIA APARECER: aceitou " + mau)
            e[1] += 1
        catch err:
            e[0] += 1

    # ... e um fuso que não existe LEVANTA, nunca recua para UTC (149.2)
    try:
        _ = await tz.load("Marte/Olympus")
        print("  ISTO NAO DEVIA APARECER: inventou um fuso")
        e[1] += 1
    catch err2:
        e[0] += 1

    print("tz: " + str(e[0]) + " ok, " + str(e[1]) + " falharam")
    return 0


await go()
