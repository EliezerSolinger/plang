"""O grafo de PACOTES do workspace: quem existe, quem puxa quem.

É um grafo pequeno e de outra natureza que o grafo de build. O de build fala de
arquivos e comandos; este fala de nomes e versões, e existe para responder duas
perguntas que todo lock grande acaba por provocar:

    ppack tree            o que este projeto usa, e por dentro de quê
    ppack why <pacote>    quem o puxou

Elas não são luxo. São as que salvam a tarde em que algo aparece no build e
ninguém sabe de onde veio — e o ninja e o samurai têm as duas (`-t graph`,
`-t query`), o que já diz alguma coisa sobre a frequência com que se precisa
delas.

O que este arquivo NÃO faz: resolver versões. Hoje os membros do workspace são
os pacotes, e a faixa que uma dependência pede é conferida contra a versão que
existe. Quando houver repositório, é aqui que a resolução entra — e o formato do
que ela produz é o `pack.lock`.
"""
import path
import lib_manifest as M

struct Pacote:
    nome: str
    versao: str
    lang: str
    dir: str
    deps: list<str>       # os nomes, na ordem do manifesto
    faixas: list<str>     # ... e a faixa que cada um pediu

struct Mundo:
    pacotes: list<Pacote>
    faltando: list<str>   # dependências pedidas que ninguém oferece

    def acha(self, nome: str) -> int:
        i = 0
        while i < len(self.pacotes):
            if self.pacotes[i].nome == nome:
                return i
            i += 1
        return -1

    def quem_puxa(self, nome: str) -> list<str>:
        """Os pacotes que dependem DESTE, na ordem em que aparecem."""
        out: list<str> = []
        for p in self.pacotes:
            for d in p.deps:
                if d == nome:
                    out.append(p.nome)
        return out


async def ler_mundo(membros: list<str>) -> Mundo:
    """Lê o manifesto de cada membro do workspace. Um membro sem `pack.json` é
    ignorado em silêncio — o workspace pode listar uma pasta que ainda não é
    pacote, e recusar isso obrigaria a mexer no manifesto para experimentar."""
    m = Mundo([], [])
    for dir in membros:
        man = path.join(dir, "pack.json")
        if not path.isfile(man):
            continue
        pk = await M.ler(man)
        if pk.eh_workspace:
            continue
        nomes: list<str> = []
        faixas: list<str> = []
        for d in pk.deps:
            nomes.append(d.nome)
            faixas.append(d.faixa)
        m.pacotes.append(Pacote(pk.nome, pk.versao, pk.lang, dir, nomes, faixas))
    # o que se pede e não existe: dito UMA vez, com o nome de quem pediu
    for p in m.pacotes:
        for d in p.deps:
            if m.acha(d) < 0:
                m.faltando.append(d + " (pedido por " + p.nome + ")")
    return m


# ---------- a árvore ----------
private def galho(m: Mundo, nome: str, prefixo: str, ultimo: bool, pilha: list<str>) -> str:
    i = m.acha(nome)
    marca = "└─ " if ultimo else "├─ "
    if i < 0:
        return prefixo + marca + nome + "  (não achado)\n"
    p = m.pacotes[i]
    for x in pilha:
        if x == nome:
            # um ciclo é dito e cortado, não seguido: seguir seria não parar
            return prefixo + marca + p.nome + " " + p.versao + "  (ciclo)\n"
    out = prefixo + marca + p.nome + " " + p.versao + "  (" + p.lang + ")\n"
    dentro = prefixo + ("   " if ultimo else "│  ")
    pilha.append(nome)
    j = 0
    while j < len(p.deps):
        out += galho(m, p.deps[j], dentro, j == len(p.deps) - 1, pilha)
        j += 1
    fora = pilha.pop()      # o valor não se usa, mas descartá-lo é expressão sem uso
    if fora != nome:
        return out + prefixo + "   (a pilha da árvore saiu de ordem — defeito)\n"
    return out


def arvore(m: Mundo) -> str:
    """A árvore do workspace: as RAÍZES primeiro (quem ninguém puxa), e cada uma
    com o que ela puxa por baixo. Um pacote que aparece em dois ramos aparece
    duas vezes — é uma árvore, e não um grafo desenhado como árvore, porque o
    que se quer ver é o CAMINHO até ele."""
    out = ""
    raizes: list<str> = []
    for p in m.pacotes:
        if len(m.quem_puxa(p.nome)) == 0:
            raizes.append(p.nome)
    if len(raizes) == 0:
        # tudo é puxado por alguém: um ciclo, ou um workspace de um pacote só
        for p2 in m.pacotes:
            raizes.append(p2.nome)
    k = 0
    while k < len(raizes):
        pilha: list<str> = []
        out += galho(m, raizes[k], "", k == len(raizes) - 1, pilha)
        k += 1
    return out
