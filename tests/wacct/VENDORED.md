Vendored from https://github.com/nlsandler/writing-a-c-compiler-tests
(the test corpus for Nora Sandler's book "Writing a C Compiler")
commit ae12014d2dec14488f3f80d14df4b6d8e4634d7d, MIT license (see LICENSE).
Only the tests/ tree is vendored (the Python framework is not used);
../run.sh drives it: suite "c-invalid" (invalid_* must be rejected)
and the valid/ programs feed the C-frontend scoreboard.
