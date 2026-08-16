# the values are a literal written at the call, never a dict variable (75.2)
d = {"a": 1, "b": 2}
print(render("rk.tpl", d))
