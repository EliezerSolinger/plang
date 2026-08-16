# pmod_text.ph — texto atravessando a fronteira (81/84/85/86).
#
# `CStr` é um PONTEIRO E O TAMANHO DELE, como valor: não aloca, não tem dono, e
# vive só enquanto a chamada dura. O lado pscript vê `str` e o lado P vê o par;
# quem constrói o par é o compilador, no sítio da chamada, apontando para os
# próprios bytes do objeto — zero cópia na ida, porque uma chamada C não coleta
# e portanto nada se move debaixo dela.
#
# Na volta é CÓPIA: a memória é do lado P e o coletor não a rastreia. O que o P
# devolve é EMPRESTADO — estático, ou um buffer dele válido até a próxima
# chamada — e ninguém libera nada.
include <stdio.h>
import "../../../stl/cstr.ph"

def texto_tamanho(in s: CStr) -> i64
def texto_maiusculo(in s: CStr) -> CStr
def bytes_soma(in b: CBytes) -> i64
def versao() -> CStr
def nao_utf8() -> CStr
