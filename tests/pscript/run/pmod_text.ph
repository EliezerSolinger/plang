# pmod_text.ph — text crossing the boundary (81/84/85/86).
#
# `CStr` is A POINTER AND ITS LENGTH, as a value: it does not allocate, has no
# owner, and lives only as long as the call does. The pscript side sees `str`
# and the P side sees the pair; the compiler is what builds the pair, at the
# call site, pointing at the object's own bytes — no copy on the way out,
# because a C call cannot collect and so nothing moves underneath it.
#
# On the way back it is a COPY: the memory is P's and the collector does not
# track it. What P returns is BORROWED — static, or a buffer of its own valid
# until the next call — and nobody frees anything.
include <stdio.h>
import "../../../stl/cstr.ph"

def text_length(in s: CStr) -> i64
def text_upper(in s: CStr) -> CStr
def bytes_sum(in b: CBytes) -> i64
def version() -> CStr
def not_utf8() -> CStr
