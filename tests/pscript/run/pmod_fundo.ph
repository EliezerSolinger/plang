# pmod_fundo.ph — o módulo P que NÃO é importado pelo arquivo de cima.
#
# Quem o importa é `lib_fundo.psc`, que por sua vez é importado pelo programa.
# Antes da 1.5(d) esse `import` a essa profundidade era honrado só até meio
# caminho: as declarações entravam, o `#include` saía no C gerado, e o `.p`
# NÃO era compilado — o programa não linkava, e quem construía compensava à mão.
def fundo_dobro(v: i64) -> i64
def fundo_impar(v: i64) -> bool
