# pmod_bottom.ph — o módulo P que NÃO é importado pelo arquivo de cima.
#
# Quem o importa é `lib_bottom.psc`, que por sua vez é importado pelo programa.
# Antes da 1.5(d) esse `import` a essa profundidade era honrado só até meio
# caminho: as declarações entravam, o `#include` saía no C gerado, e o `.p`
# NÃO era compilado — o programa não linkava, e quem construía compensava à mão.
def bottom_double(v: i64) -> i64
def bottom_odd(v: i64) -> bool
