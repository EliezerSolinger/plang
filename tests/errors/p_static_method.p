# 118: the same refusal inside a struct. In P a method's `static` was privacy
# too, so `private def` is the spelling here as well.
struct Box:
    v: i32
    static def get(self: *Box) -> i32:
        return self->v
