# teste da STL: Vec<T>, Map<K,V>, StrMap<V>, Str, hash — tudo header-only
include <stdio.h>
include <string.h>
import "../../stl/vec.ph"
import "../../stl/map.ph"
import "../../stl/str.ph"
import "../../stl/set.ph"
import "../../stl/queue.ph"
import "../../stl/slice.ph"
import "../../stl/dict.ph"
import "../../stl/list.ph"

declare Vec<int>
implement Vec<int>

declare Map<int, *char>
implement Map<int, *char>

declare StrMap<int>
implement StrMap<int>

implement Str
implement StrSet

declare Set<int>
implement Set<int>

declare Queue<int>
implement Queue<int>

declare Slice<int>
implement Slice<int>

declare Dict<int, int>
implement Dict<int, int>
declare Dict<*char, int>
implement Dict<*char, int>

declare List<int>
implement List<int>
declare List<*char>
implement List<*char>

def main() -> int:
    # ---- Vec ----
    v: Vec<int>
    v.init()
    i: i32
    for i in range(10):
        v.push(i * 2)
    v.remove_at(0)
    v.swap_remove(1)
    printf("%d %d %d\n", v.get(0), v.get(1), v.len)
    v.deinit()

    # ---- Map (chaves int) ----
    m: Map<int, *char>
    m.init()
    m.put(1, "um")
    m.put(2, "dois")
    m.put(3, "tres")
    m.put(2, "DOIS")
    m.remove(3)
    printf("%s %s %d\n", m.get_or(1, "?"), m.get_or(2, "?"), m.size)
    printf("%s\n", m.get_or(3, "sumiu"))
    printf("iter:")
    for i in range(m.elen):
        if not m.dead[i]:
            printf(" %d=%s", m.keys[i], m.vals[i])
    printf("\n")
    m.deinit()

    # crescimento + tombstones
    big: Map<int, *char>
    big.init()
    for i in range(100):
        big.put(i, "x")
    for i in range(50):
        big.remove(i * 2)
    ok: i32 = 0
    for i in range(100):
        if big.has(i) == (i % 2 == 1 or i >= 99):
            ok += 1
    printf("big=%d ok=%d\n", big.size, ok)
    big.deinit()

    # ---- StrMap ----
    sm: StrMap<int>
    sm.init()
    sm.put("alfa", 1)
    sm.put("beta", 2)
    sm.put("alfa", 10)
    achou: int = 0
    tem: bool = sm.get("beta", &achou)
    printf("%d %d %d\n", sm.get_or("alfa", -1), achou, tem)
    printf("%d\n", sm.get_or("gama", -1))
    sm.deinit()

    # ---- Set ----
    st: Set<int>
    st.init()
    a1: bool = st.add(7)
    a2: bool = st.add(7)
    printf("%d %d %d\n", a1, a2, st.has(7))
    for i in range(50):
        st.add(i)
    for i in range(25):
        st.remove(i * 2)
    printf("set=%d has49=%d has48=%d\n", st.size, st.has(49), st.has(48))
    st.deinit()

    ss: StrSet
    ss.init()
    ss.add("a")
    ss.add("b")
    ss.add("a")
    printf("strset=%d %d %d\n", ss.size, ss.has("b"), ss.has("z"))
    ss.deinit()

    # ---- Queue ----
    q: Queue<int>
    q.init()
    for i in range(20):
        q.push(i)
    soma: i32 = 0
    for i in range(10):
        soma += q.pop()
    q.push(100)
    printf("q=%d peek=%d soma=%d\n", q.size, q.peek(), soma)
    q.deinit()

    # ---- Slice ----
    v2: Vec<int>
    v2.init()
    for i in range(10):
        v2.push(i * 10)
    sl: Slice<int>
    sl.init_from(v2.data, v2.len)
    mid: Slice<int> = sl.sub(3, 4)
    printf("slice=%d %d..%d\n", mid.len, mid.get(0), mid.last())
    v2.deinit()

    # ---- Str ----
    s: Str
    s.init()
    s.append("olá")
    s.push(',')
    s.push(' ')
    s.appendf("mundo %d!", 42)
    printf("%s len=%d\n", s.cstr(), i32(s.len))
    printf("eq=%d\n", s.eq("olá, mundo 42!"))
    s.deinit()

    # ---- Dict (unifica Map/StrMap por match type) ----
    di: Dict<int, int>
    di.init()
    di.put(10, 100)
    di.put(20, 200)
    di.put(10, 111)          # sobrescreve
    printf("dict<int>: %d %d has30=%d size=%d\n", di.get_or(10, -1), di.get_or(20, -1), di.has(30), di.size)
    di.deinit()

    ds: Dict<*char, int>     # chave por CONTEÚDO (como StrMap), posse própria
    ds.init()
    ds.put("alpha", 1)
    ds.put("beta", 2)
    buf: char[8]
    strcpy(buf, "alpha")     # ponteiro != literal, mesmo conteúdo
    printf("dict<str>: a=%d b=%d buf=%d\n", ds.get_or("alpha", -1), ds.get_or("beta", -1), ds.get_or(buf, -1))
    ds.remove("alpha")
    printf("dict<str> after remove: a=%d size=%d\n", ds.get_or("alpha", -1), ds.size)
    ds.deinit()

    # ---- List (Python-flavored, typed) ----
    li: List<int>
    li.init()
    for i in range(5):
        li.append(i * 2)         # 0 2 4 6 8
    li.insert(0, 99)             # 99 0 2 4 6 8
    li.remove_at(2)              # 99 0 4 6 8
    printf("list<int>: len=%d first=%d last=%d idx6=%d count4=%d has8=%d\n", li.len, li.get(0), li.get(-1), li.index(6), li.count(4), li.contains(8))
    li.deinit()

    ls2: List<*char>             # comparação por CONTEÚDO
    ls2.init()
    ls2.append("a")
    ls2.append("b")
    ls2.append("a")
    buf2: char[4]
    strcpy(buf2, "a")            # ponteiro != literal
    printf("list<str>: count(a)=%d idx(buf 'a')=%d has(c)=%d\n", ls2.count("a"), ls2.index(buf2), ls2.contains("c"))
    ls2.deinit()
    return 0
