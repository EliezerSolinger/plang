trait Sized:
    def size(self: *Sized) -> i32
struct Box:
    w: i32
implement Sized for Box:
    def size(self: *Box) -> i32:
        return self->w
implement Sized for Box:
    def size(self: *Box) -> i32:
        return 0
