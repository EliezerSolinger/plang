# the orphan rule (67.3): implementing someone else's trait for someone else's
# type is what makes two modules disagree about the same pair
import lib_trait
import lib_point

implement lib_trait.Printable for lib_point.Point:
    def show(in self) -> str:
        return "p"
