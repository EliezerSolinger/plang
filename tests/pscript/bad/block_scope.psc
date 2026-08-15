# 64.1: both languages have block scope, so this name dies with the branch.
# `nonlocal label` before the `if` is the way to keep it.
n = 3
if n > 2:
    label = "big"
else:
    label = "small"
print(label)
