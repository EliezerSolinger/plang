# an import fixture (`lib_*.psc` is never a test on its own): a module that is
# really a program, which is exactly what `import` must refuse
def helper() -> int:
    return 1

print("I am a program, not a module")
