"""Ed25519 (RFC 8032): a assinatura que fecha o modo seguro.

Um repositório é um formato e a confiança vem do CONTEÚDO, não da conexão. O
hash já diz "isto é o que disseram que era"; falta a outra metade — "e quem o
disse foi quem eu penso". São duas assinaturas, com donos diferentes e por
razões diferentes:

  * o ÍNDICE é assinado pelo REPOSITÓRIO, e é o que impede alguém no meio de
    responder com uma lista velha (onde a versão com a falha ainda é a última);
  * cada VERSÃO é assinada pelo AUTOR, e é o que impede o próprio repositório de
    servir um tarball que o autor não fez.

Escolheu-se Ed25519 e não RSA nem ECDSA por três razões que se leem numa linha:
a chave pública tem 32 bytes e a assinatura 64 (cabem num JSON sem doer); não
precisa de aleatoriedade na hora de assinar (é determinística, e um gerador mau
não vaza a chave como vaza no ECDSA); e a verificação não tem casos especiais
que se possam implementar mal em silêncio.

**O que este pacote NÃO promete: tempo constante.** A multiplicação escalar é
duplica-e-soma sobre os bits do escalar, e o tempo depende deles. Para VERIFICAR
isso é irrelevante — não há segredo nenhum na verificação. Para ASSINAR, num
computador partilhado com um adversário capaz de medir, é uma fraqueza real.
Está escrito aqui em vez de estar escondido: quem assina versões numa máquina
dessas tem um problema maior do que este pacote.

A aritmética é de propósito a mais simples que dá para conferir lendo: inteiros
de 256 bits em oito palavras de 32, produto escolar, e redução módulo
2^255 - 19 usando 2^256 ≡ 38. Não há aqui truque de representação (o `ref10`
usa dez limbos de 25,5 bits) porque isto assina meia dúzia de coisas por
publicação, e o que se ganharia em velocidade paga-se em quem consegue rever.
"""

import <stl/cstr.ph>
include <string.h>

const ED25519_SEED_LEN: usize = 32
const ED25519_PUB_LEN: usize = 32
const ED25519_SIG_LEN: usize = 64

def ed25519_pubkey(seed: const *char, out_pub: *char):
    """A chave pública que corresponde a uma semente de 32 bytes.

    A semente É a chave privada: o resto (o escalar e o prefixo) sai dela por
    SHA-512, o que faz uma chave privada ser trinta e dois bytes que se guardam
    e mais nada."""

def ed25519_sign(seed: const *char, pub: const *char, msg: const *char, n: usize, out_sig: *char):
    """Assina `n` bytes. A assinatura tem 64 bytes e é DETERMINÍSTICA: a mesma
    mensagem com a mesma chave dá sempre a mesma assinatura, o que também quer
    dizer que não há gerador de aleatórios nenhum entre a chave e o resultado."""

def ed25519_verify(pub: const *char, msg: const *char, n: usize, sig: const *char) -> bool:
    """Confere. Devolve `False` para tudo o que não seja uma assinatura válida
    desta mensagem por esta chave — incluindo uma chave que não é um ponto da
    curva, um `S` fora do intervalo, e os pontos de ordem pequena que a RFC
    manda recusar."""

# ---------- a travessia para o pscript (45.5/84.1) ----------

def ed25519_pub_hex(in seed: CBytes) -> CStr:
    """A chave pública, em hexadecimal. É a forma que vai para o `pack.lock` e
    para o índice — texto, porque é lá que ela vive."""

def ed25519_sign_hex(in seed: CBytes, in msg: CBytes) -> CStr:
    """A assinatura em hexadecimal (128 dígitos)."""

def ed25519_verify_hex(in pub_hex: CStr, in msg: CBytes, in sig_hex: CStr) -> bool:
    """Confere, com a chave e a assinatura como texto. Um hexadecimal com o
    tamanho errado ou com um dígito que não é dígito é `False`, e não um erro:
    do ponto de vista de quem confere, um ficheiro estragado e uma assinatura
    errada são a mesma resposta."""
