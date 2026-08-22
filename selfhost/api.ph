# api.ph — a LISTA CANÓNICA da API de um módulo (perguntas 2 e 5 do protocolo).
#
# O que o `pbuild`/`ppack` perguntam ao compilador, e por quê: só o compilador
# sabe o que um módulo oferece, e hoje quem quer saber tem de ler o fonte de
# novo (é o que um gerador de doc faz, e é como a doc apodrece). A lista sai
# daqui em UMA forma, e serve três consumidores: verificar semver na publicação,
# gerar doc, e dar ao caminho QBE — que não tem header — uma noção de interface.
#
# O que a lista é, com precisão:
#
#   * a INTERFACE DECLARADA — nomes, tipos, layout de struct, valores de enum e
#     de const pública, na ordem em que o fonte os declara;
#   * SEM comentário, SEM docstring, SEM nome de parâmetro (renomear um
#     parâmetro não muda chamada nenhuma) e sem corpo de função.
#
# E o que ela NÃO é, dito antes que alguém suponha: ela não cobre o CORPO de uma
# função de header (`private inline def` num `.ph`, que a stl usa inteira). No
# caminho C isso não é buraco — o `.h` emitido carrega esse corpo, e é o `.h` que
# o build compara para decidir recompilação (o `restat` do grafo faz isso por
# conteúdo). A lista é para semver e doc; o `.h` é do que a compilação depende.
import "plang.ph"
import "ast.ph"

# escreve a lista canónica de `m` em `b`, terminando com a linha `#hash <16 hex>`
def api_dump(m: *Module, b: *StrBuf)
