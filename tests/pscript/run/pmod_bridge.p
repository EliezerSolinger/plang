include <string.h>
import "pmod_bridge.ph"

def bridge_len(in b: CBytes) -> i64:
    return i64(b.len)

def bridge_sum(in b: CBytes) -> i64:
    t: i64 = 0
    for i in range(b.len):
        t += i64(u8(b.ptr[i]))
    return t

def bridge_eq(in b: CBytes, in other: CBytes) -> bool:
    # à mão, e não com o `CBytes.eq` do `stl`: este módulo é ligado a TODOS os
    # programas da suíte (75.3 emite o `.p` ao lado), e depender do `cstr.p`
    # faria cada um deles precisar dele no link. Um portão da ponte não deve
    # arrastar meia biblioteca para provar o que prova.
    if b.len != other.len:
        return False
    return b.len == usize(0) or memcmp((*void)(b.ptr), (*void)(other.ptr), b.len) == 0
