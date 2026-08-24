# 139: the old spelling is refused, and the message says what to write.
#
# It is refused by the DIAGNOSTIC and not by a hole in the grammar: the name is
# still recognised, so what comes out names the new spelling instead of "unknown
# type 'list'", which is what a reader of five-year-old code needs to see.
xs: list<int> = [1, 2, 3]
print(len(xs))
