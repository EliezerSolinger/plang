"""`datetime` (S4): o modelo do `java.time`, e a razão de ser esse.

**O TIPO responde se tem fuso.** É a decisão inteira, e é a correcção do defeito
mais documentado da biblioteca do Python: lá um `datetime` pode ou não ter fuso,
a mesma função recebe os dois, e o programa descobre a diferença em produção.
Aqui não há como perguntar — `LocalDateTime` não tem, `ZonedDateTime` tem, e uma
função que precisa de um não aceita o outro.

O portão anda por três eixos, e cada um apanha uma classe de erro diferente: o
CALENDÁRIO (o algoritmo do Hinnant, exacto para qualquer ano), a ARITMÉTICA (onde
o `Period` e o `Duration` divergem de propósito) e os FORMATOS (ISO, HTTP e
`strftime`), incluindo os dois formatos de HTTP que a norma proíbe gerar e obriga
a aceitar.
"""
import <datetime/datetime.psc> as dt


e: List<int> = [0, 0]


def ck(name: str, got: str, want: str):
    if got == want:
        e[0] += 1
    else:
        e[1] += 1
        print("  " + name + ": deu   " + got)
        print("  " + name + ": devia " + want)


def cki(name: str, got: int, want: int):
    ck(name, str(got), str(want))


def main():
    # ---- 1. o calendário: ida e volta em toda a parte ----
    #
    # A era de 400 anos é a do calendário gregoriano — 146097 dias exactos — e é
    # isso que faz o algoritmo não ter tabela nem laço.
    cki("epoch", dt.days_from_civil(1970, 1, 1), 0)
    cki("ontem da epoch", dt.days_from_civil(1969, 12, 31), -1)
    cki("2000-03-01", dt.days_from_civil(2000, 3, 1), 11017)
    d0 = dt.civil_from_days(0)
    ck("civil(0)", dt.date_iso(d0), "1970-01-01")
    ck("civil(-1)", dt.date_iso(dt.civil_from_days(-1)), "1969-12-31")

    # ida e volta sobre um pedaço grande, incluindo anos negativos
    mau = 0
    n = -800000
    while n < 800000:
        c = dt.civil_from_days(n)
        if dt.days_from_civil(c.year, c.month, c.day) != n:
            mau += 1
        n += 997
    cki("ida e volta do calendario", mau, 0)

    # ---- 2. bissextos: as três regras, e a que quase toda a gente esquece ----
    ck("1900 nao e", str(dt.is_leap(1900)), "False")
    ck("2000 e", str(dt.is_leap(2000)), "True")
    ck("2024 e", str(dt.is_leap(2024)), "True")
    ck("2100 nao e", str(dt.is_leap(2100)), "False")
    cki("fevereiro de 2024", dt.days_in_month(2024, 2), 29)
    cki("fevereiro de 2100", dt.days_in_month(2100, 2), 28)

    # ---- 3. dia da semana ----
    #
    # 1970-01-01 foi uma quinta, e é dessa âncora que sai tudo o resto.
    ck("epoch foi quinta", str(dt.weekday(dt.date(1970, 1, 1))), "3")
    ck("2026-08-25", str(dt.weekday(dt.date(2026, 8, 25))), "1")
    cki("dia do ano", dt.day_of_year(dt.date(2024, 12, 31)), 366)

    # ---- 4. o instante e o local ----
    i = dt.instant_of(1000000000, 0)
    ck("mil milhoes", dt.instant_iso(i), "2001-09-09T01:46:40Z")
    ck("de volta", str(dt.from_utc(dt.to_utc(i)).second), "1000000000")

    # ---- 5. Duration e Period NÃO são a mesma coisa, e é o ponto ----
    #
    # 31 de Janeiro mais um MÊS fica no último dia de Fevereiro: a alternativa
    # (transbordar para 3 de Março) faz `x + 1 mês - 1 mês` deixar de voltar ao
    # sítio, e ninguém espera isso.
    ck("31/1 + 1 mes", dt.date_iso(dt.plus_months(dt.date(2026, 1, 31), 1)), "2026-02-28")
    ck("31/1 + 1 mes (bissexto)", dt.date_iso(dt.plus_months(dt.date(2024, 1, 31), 1)), "2024-02-29")
    ck("e volta", dt.date_iso(dt.plus_months(dt.plus_months(dt.date(2026, 1, 31), 1), -1)), "2026-01-28")
    # a ORDEM dentro de um Period: anos e meses primeiro, dias depois (a da ISO)
    ck("31/1 + P1M1D", dt.date_iso(dt.plus_period(dt.date(2026, 1, 31), dt.Period(0, 1, 1))), "2026-03-01")
    # ... enquanto um Duration de um dia são 86400 segundos e mais nada
    ck("um dia exacto", dt.instant_iso(dt.plus(dt.instant_of(0, 0), dt.days(1))), "1970-01-02T00:00:00Z")
    ck("PT2H30M", dt.duration_iso(dt.Duration(9000, 0)), "PT2H30M")
    ck("PT0S", dt.duration_iso(dt.Duration(0, 0)), "PT0S")
    ck("com fraccao", dt.duration_iso(dt.Duration(1, 500000000)), "PT1.5S")
    ck("negativo", dt.duration_iso(dt.Duration(-90, 0)), "-PT1M30S")

    # ---- 6. ISO 8601 / RFC 3339 ----
    ck("com fuso", dt.zoned_iso(dt.zoned(i, 5400)), "2001-09-09T03:16:40+01:30")
    ck("Nepal", dt.offset_iso(5 * 3600 + 45 * 60), "+05:45")
    ck("a oeste", dt.offset_iso(-8 * 3600), "-08:00")
    p = dt.parse_instant("2026-08-25T14:30:00Z")
    if p != None:
        ck("le Z", dt.instant_iso(p), "2026-08-25T14:30:00Z")
    q = dt.parse_instant("2026-08-25T14:30:00+01:00")
    if q != None:
        ck("le deslocamento", dt.instant_iso(q), "2026-08-25T13:30:00Z")
    r = dt.parse_datetime("2026-08-25 14:30:00.123")
    if r != None:
        ck("espaco em vez de T", dt.datetime_iso(r), "2026-08-25T14:30:00.123")
    # o que NÃO é uma data devolve None, e não levanta (4.2)
    ck("vazio", str(dt.parse_date("") == None), "True")
    ck("mes 13", str(dt.parse_date("2026-13-01") == None), "True")
    ck("30 de fevereiro", str(dt.parse_date("2026-02-30") == None), "True")
    ck("29/2 de 2024 existe", str(dt.parse_date("2024-02-29") == None), "False")
    ck("sem fuso nao e instante", str(dt.parse_instant("2026-08-25T14:30:00") == None), "True")

    # ---- 7. as datas do HTTP: gerar UMA, aceitar TRÊS ----
    h = dt.instant_of(784111777, 0)
    ck("IMF-fixdate", dt.http_date(h), "Sun, 06 Nov 1994 08:49:37 GMT")
    for text in ["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994"]:
        got = dt.parse_http_date(text)
        if got == None:
            ck("http: " + text, "None", "784111777")
        else:
            ck("http: " + text, str(got.second), "784111777")
    ck("http mau", str(dt.parse_http_date("nao e uma data") == None), "True")

    # ---- 8. strftime / strptime ----
    x = dt.datetime_of(2026, 8, 25, 14, 30, 5)
    ck("strftime", dt.strftime("%Y-%m-%d %H:%M:%S", x), "2026-08-25 14:30:05")
    ck("nomes", dt.strftime("%a %A %b %B", x), "Tue Tuesday Aug August")
    ck("doze horas", dt.strftime("%I:%M %p", x), "02:30 PM")
    ck("por cento", dt.strftime("100%%", x), "100%")
    y = dt.strptime("2026-08-25 14:30:05", "%Y-%m-%d %H:%M:%S")
    if y != None:
        ck("strptime", dt.datetime_iso(y), "2026-08-25T14:30:05")
    ck("strptime mau", str(dt.strptime("nada", "%Y") == None), "True")
    ck("sobra texto", str(dt.strptime("2026-08-25 sobra", "%Y-%m-%d") == None), "True")

    # ---- 9. um varrimento contra o CPython, incluindo antes da epoch ----
    #
    # Os valores foram tirados do `datetime` do Python e escritos aqui: uma
    # implementação de calendário que "parece certa" não vale nada, porque um
    # erro de um dia é plausível em todo o lado. 2038-01-19T03:14:07Z é o
    # transbordo do inteiro de 32 bits; 1900 e -2208988800 são antes da epoch;
    # 2400 é a era seguinte do algoritmo.
    VET: List<int> = [0, 946684799, 951825600, 2147483647, -2208988800, 13574563200]
    ISO: List<str> = ["1970-01-01T00:00:00Z", "1999-12-31T23:59:59Z", "2000-02-29T12:00:00Z",
                      "2038-01-19T03:14:07Z", "1900-01-01T00:00:00Z", "2400-02-29T00:00:00Z"]
    HTTP: List<str> = ["Thu, 01 Jan 1970 00:00:00 GMT", "Fri, 31 Dec 1999 23:59:59 GMT",
                       "Tue, 29 Feb 2000 12:00:00 GMT", "Tue, 19 Jan 2038 03:14:07 GMT",
                       "Mon, 01 Jan 1900 00:00:00 GMT", "Tue, 29 Feb 2400 00:00:00 GMT"]
    DIA: List<int> = [3, 4, 1, 1, 0, 1]
    ANO: List<int> = [1, 365, 60, 19, 1, 60]
    for k in range(len(VET)):
        it = dt.instant_of(VET[k], 0)
        ck("iso " + str(k), dt.instant_iso(it), ISO[k])
        ck("http " + str(k), dt.http_date(it), HTTP[k])
        cki("dia da semana " + str(k), dt.weekday(dt.to_utc(it).date), DIA[k])
        cki("dia do ano " + str(k), dt.day_of_year(dt.to_utc(it).date), ANO[k])
        back = dt.parse_instant(ISO[k])
        if back == None:
            ck("le de volta " + str(k), "None", str(VET[k]))
        else:
            cki("le de volta " + str(k), back.second, VET[k])
        hb = dt.parse_http_date(HTTP[k])
        if hb == None:
            ck("http de volta " + str(k), "None", str(VET[k]))
        else:
            cki("http de volta " + str(k), hb.second, VET[k])

    print("datetime: " + str(e[0]) + " ok, " + str(e[1]) + " falharam")


main()
