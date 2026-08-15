# embed() names a file that is not there: the compiler must say WHICH path it
# tried, resolved against this file's directory
X: const *char = embed("no_such_file.txt")
