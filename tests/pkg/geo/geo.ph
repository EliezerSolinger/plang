# geo.ph — a interface de um pacote P de teste.
#
# Um "pacote" aqui é só uma pasta com um nome: o compilador não sabe o que é
# versão nem o que é dependência — ele recebe uma raiz de busca (`--pkg-path`) e
# procura. Quem sabe de versão é o `ppack`, e é essa fronteira que faz o
# compilador não ter de aprender a gerir pacotes.
def geo_area(w: i64, h: i64) -> i64
def geo_perim(w: i64, h: i64) -> i64
