# Shared by loop-s04*.test.sh (source after loop-prelude.sh): the waits and checks of the S04 runs.
# s4wait <seconds> <command...>: wait until the command succeeds. s4ok <name> <command...>: PASS when it succeeds.
s4wait() { wait_until "$@" 2>/dev/null; }
s4ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
