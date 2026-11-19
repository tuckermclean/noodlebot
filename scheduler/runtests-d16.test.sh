#!/bin/sh
# D16-AC-1, D16-AC-2: the Makefile's `test` target starts the test files without the outer make's variables,
# so a test file that runs `make` itself gives the same result under the quick gate as when run directly.
#   sh scheduler/runtests-d16.test.sh   (make test)
#
#  - D16-AC-1: a fake test file runs `make -s -C <fixture> test` on a fixture Makefile (own TESTS = fixture-list);
#    the repository's test target runs it as `make -k -C <checkout> test TESTS="<fake>" D16_OUTER=1`. The inner make
#    must print TESTS=[fixture-list], OUTER=[1] and ORIGIN=[environment] (not command line), no `k` in the flag word of its MAKEFLAGS (the part before
#    any " -- "), and none of MAKEFLAGS, MAKEOVERRIDES, MFLAGS, MAKELEVEL may be set in the fake's environment.
#    The control runs the same fake through a planted Makefile without the clearing and must show the outer list.
#  - D16-AC-2: TEST_JOBS=2 make test TESTS="scheduler/deploy-d04.test.sh" exits 0 and prints no FAIL line.
# Every make this file runs itself has the four variables removed from its environment.
src=$(cd "$(dirname "$0")" && pwd)
. "$src/testdata/lib/common.sh"
root=$(cd "$src/.." && pwd)
d=$(mktemp -d) && [ -d "$d" ] || exit 1
trap 'rm -rf "$d"' EXIT

mk() { env -u MAKEFLAGS -u MAKEOVERRIDES -u MFLAGS -u MAKELEVEL make "$@"; }
# keep the forge and session variables of the caller out of the makes this file runs
unset USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION

mkdir "$d/fixture"
cat >"$d/fixture/Makefile" <<'MK'
TESTS = fixture-list
test:
	@echo "INNER TESTS=[$(TESTS)] OUTER=[$(D16_OUTER)] ORIGIN=[$(origin D16_OUTER)] MAKEFLAGS=[$(MAKEFLAGS)]"
MK
fake=$d/fake.test.sh
cat >"$fake" <<EOF2
#!/bin/sh
# runs make with the environment it inherited (no clearing here), after reporting the four variables
for v in MAKEFLAGS MAKEOVERRIDES MFLAGS MAKELEVEL; do
	if env | grep -q "^\$v="; then echo "ENV \$v=set"; else echo "ENV \$v=unset"; fi
done
make -s -C '$d/fixture' test
EOF2

# the inner make's line and its flag word
inner_line() { grep -a '^INNER TESTS=' "$1" | head -n 1; }
flag_word() { sed -n 's/^.*MAKEFLAGS=\[\(.*\)\]$/\1/p' | sed 's/ -- .*$//'; }

# --- AC-1: the repository's test target
(cd "$root" && mk -k -C "$root" test TESTS="$fake" D16_OUTER=1) >"$d/out1" 2>&1
line=$(inner_line "$d/out1")
echo "inner (target): $line"
case $line in
*"TESTS=[fixture-list]"*) pass "D16-AC-1: inner make sees the fixture's TESTS" ;;
*) fail "D16-AC-1: inner make sees the fixture's TESTS (line: [$line])" ;;
esac
case $line in
*"ORIGIN=[environment]"*) pass "D16-AC-1: inner make sees D16_OUTER only from the environment (ORIGIN=[environment])" ;;
*) fail "D16-AC-1: inner make sees D16_OUTER only from the environment (line: [$line])" ;;
esac
case $line in
*"OUTER=[1]"*) pass "D16-AC-1: inner make's environment still carries D16_OUTER=1" ;;
*) fail "D16-AC-1: inner make's environment still carries D16_OUTER=1 (line: [$line])" ;;
esac
fw=$(printf '%s\n' "$line" | flag_word)
case $line in
'') fail "D16-AC-1: no k among the inner make's flags (no inner make line found)" ;;
*)
	case $fw in
	*k*) fail "D16-AC-1: no k among the inner make's flags (flag word [$fw])" ;;
	*) pass "D16-AC-1: no k among the inner make's flags (flag word [$fw])" ;;
	esac ;;
esac
for v in MAKEFLAGS MAKEOVERRIDES MFLAGS MAKELEVEL; do
	if grep -qx "ENV $v=unset" "$d/out1"; then pass "D16-AC-1: $v not set in the test file's environment"
	else fail "D16-AC-1: $v not set in the test file's environment ($(grep -a "^ENV $v=" "$d/out1" || echo 'no ENV line'))"; fi
done

# --- AC-1 control: no clearing, the outer list reaches the inner make
cat >"$d/Makefile.plain" <<'MK'
test:
	sh scheduler/runtests.sh $(TESTS)
MK
(cd "$root" && mk -k -f "$d/Makefile.plain" -C "$root" test TESTS="$fake" D16_OUTER=1) >"$d/out2" 2>&1
cl=$(inner_line "$d/out2")
echo "inner (control): $cl"
case $cl in
*"TESTS=[$fake]"*"OUTER=[1]"*"ORIGIN=[command line]"*) pass "D16-AC-1: control shows the outer list (TESTS=[<fake>] OUTER=[1] ORIGIN=[command line])" ;;
*) fail "D16-AC-1: control shows the outer list (line: [$cl])" ;;
esac

# --- AC-2: the quick gate on deploy-d04
(cd "$root" && TEST_JOBS=2 mk -C "$root" test TESTS="scheduler/deploy-d04.test.sh") >"$d/out3" 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then pass "D16-AC-2: quick gate on deploy-d04 exits 0"
else fail "D16-AC-2: quick gate on deploy-d04 exits 0 (exit $rc)"; fi
if grep -a '^FAIL' "$d/out3" >"$d/fails3"; then
	fail "D16-AC-2: quick gate on deploy-d04 prints no FAIL line ($(wc -l <"$d/fails3") lines, first: $(head -n 1 "$d/fails3"))"
else pass "D16-AC-2: quick gate on deploy-d04 prints no FAIL line"; fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
