import "pmod_blob.ph"

def blob_soma(in b: CBytes) -> i64:
    t: i64 = 0
    for i in range(b.len):
        t += i64(b.ptr[i])
    return t

# à mão, e não com o `CBuf.set` do `stl`: este módulo é ligado a TODOS os
# programas da suíte (75.3 emite o `.p` ao lado), e depender do `cstr.p` faria
# cada um deles precisar dele no link. É a mesma razão que o `pmod_ponte` já
# tinha escrito, e continua a valer para o par mutável.
def blob_dobra(in d: CBuf):
    for i in range(d.len):
        d.ptr[i] = u8(i32(d.ptr[i]) * 2)

def blob_enche(in d: CBuf, v: i64):
    for i in range(d.len):
        d.ptr[i] = u8(v)
