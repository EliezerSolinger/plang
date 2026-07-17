# STL de P — header-only, 100% `.ph`

Biblioteca padrão de P. **Não faz parte do compilador** e não tem nada para
linkar: é só código `.ph`. Genéricos são templates (não geram C até você
pedir com `declare`/`implement`); o que não é genérico é `static inline`.

Origem: lógica portada do runtime C do
[jaketa](https://github.com/EliezerSolinger/jaketa/tree/main/runtime-c)
(que era todo em macros), reimplementada nativa em P — sem refcounting:
memória manual via `init`/`deinit`, como manda a filosofia da linguagem.

## Uso

```python
import "stl/vec.ph"          # caminho relativo ao seu arquivo
import "stl/map.ph"
import "stl/str.ph"

declare Vec<int>             # no seu .ph (ou .p): emite a definição
implement Vec<int>           # em UM único .p: emite os corpos

def main() -> int:
    v: Vec<int>
    v.init()
    v.push(42)
    printf("%d\n", v.get(0))
    v.deinit()
    return 0
```

Transpile os `.ph` da stl junto (gera os `.h` ao lado): `plangc stl/*.ph`.

## Módulos

| Módulo | O quê | Notas |
|---|---|---|
| `vec.ph` | `Vec<T>` array dinâmico | `push/pop/get/set/last/remove_at/swap_remove/reserve/clear`; sem bounds-check (semântica C) |
| `map.ph` | `Map<K,V>` e `StrMap<V>` | compact dict estilo Python 3.7: ordem de inserção preservada, probe linear, tombstones, resize a 2/3 de carga |
| `str.ph` | `Str` string dinâmica | sempre NUL-terminada; `append/appendf(fmt, ...)/push/eq/cstr`; exige `implement Str` em um `.p` |
| `set.ph` | `Set<T>` e `StrSet` | mesma topologia do dict, sem hash cacheado (recalcula no resize — economia de memória); `StrSet` copia as chaves e exige `implement StrSet` |
| `queue.ph` | `Queue<T>` FIFO | ring buffer; resize dobra e lineariza |
| `slice.ph` | `Slice<T>` view | `{data, len}` não-dona — não sobrevive ao dono; `sub()` sem cópia |
| `hash.ph` | FNV-1a, splitmix64, combine | determinístico; sem proteção HashDoS |

## Regras dos mapas

- `Map<K,V>`: chaves comparadas **por bytes** — use ints, enums, ponteiros
  (identidade). Não use structs com padding nem `*char` por conteúdo.
- `StrMap<V>`: chaves `*char` por **conteúdo**; o mapa guarda cópias
  próprias e as libera em `remove`/`deinit`. Valores são sempre do caller.
- Iteração em ordem de inserção:
  ```python
  i: i32
  for i in range(m.elen):
      if not m.dead[i]:
          usar(m.keys[i], m.vals[i])
  ```

## Convenções

- `init()` zera; `deinit()` libera e zera — sem construtores mágicos.
- **Uma regra só**: `.ph` nunca gera código executável; `implement`
  materializa — `implement Vec<int>` (genérico) e `implement Str`
  (não-genérico) em **um único** `.p` do programa.
- `declare X<...>` no `.ph` público se outros módulos usam o tipo.
- Se o linker reclamar de `undefined reference to Str_...`, faltou o
  `implement Str` em algum `.p`.
