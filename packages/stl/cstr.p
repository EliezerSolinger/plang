# The bodies of `CStr`'s and `CBytes`'s methods, materialized HERE.
#
# `implement X` emits the bodies the `.ph` declared, and emits them with external
# linkage — so TWO modules implementing the same type collide in the linker, with
# a message that talks about `CStr_at` and not about the problem. It happened the
# day two packages (`sha2` and `ed25519`) needed the pscript boundary at the same
# time.
#
# The rule that teaches is simple and it is this: **whoever DECLARES the type is
# whoever materializes it**. `cstr.ph` belongs to `stl`, so `cstr.p` does too —
# and 1.5(a) does the rest on its own: whoever writes `import <stl/cstr.ph>`
# pulls this file in with it, once, without having to know it exists.
import <stl/cstr.ph>
implement CStr
implement CBytes
implement CBuf
