# pmod_blob.ph — o lado de P do blob PARTILHADO (161).
#
# O `CBytes` já atravessava, e só de leitura. O que a 161 acrescenta é o `CBuf`:
# o mesmo par com o `const` fora do `ptr`, e a assinatura a dizer qual dos dois
# lados é escrito antes de alguém ler o corpo.
#
# **O que o torna sólido é de onde ele pode vir.** A costura só constrói um
# `CBuf` sobre um `Buffer` do pscript ou uma `View<u8>` dele — e um `Buffer` é
# `calloc`'d, header e bytes, fora do monte coletado, porque a 19.4/52.3 o fez
# assim para outra thread poder segurar o ponteiro. Não se mexe, portanto uma
# colheita a meio da chamada não lhe toca.
import <stl/cstr.ph>

def blob_soma(in b: CBytes) -> i64
def blob_dobra(in d: CBuf)
def blob_enche(in d: CBuf, v: i64)
