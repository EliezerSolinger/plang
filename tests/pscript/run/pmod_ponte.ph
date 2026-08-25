# pmod_ponte.ph — o lado de P da ponte da 138.
#
# Um mapa em P **não precisa de tipo novo nenhum**: é um ponteiro e um tamanho,
# e é exactamente isso que um `CBytes` (84.1) é — *"um struct de exactamente um
# ponteiro e um tamanho"*. Nada aqui sabe que os bytes vieram de um `mmap`, e é
# essa a razão de a ponte não ter custado uma linha de código novo.
import <stl/cstr.ph>

# `in` diz que os bytes são EMPRESTADOS: valem durante a chamada e esta função
# não os guarda (141.5). É a direcção que a costura permite, e a única.
def ponte_len(in b: CBytes) -> i64
def ponte_soma(in b: CBytes) -> i64
def ponte_igual(in b: CBytes, in outro: CBytes) -> bool
