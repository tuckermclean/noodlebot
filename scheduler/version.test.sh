#!/bin/sh
# Test of scheduler/version.sh (the loop's version and the signature line) and of the
# version line status.sh prints, on temporary repositories and a temporary runtime root.
#   sh scheduler/version.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'kill $(cat "$tmp"/*.holder 2>/dev/null) 2>/dev/null; rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
# eq <name> <expected> <actual>
eq() {
	if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid

# mkrepo <dir>: a repository with one commit.
mkrepo() {
	git init -q "$1" && git -C "$1" commit -q --allow-empty -m one
}
# ver <args...>: version.sh's output and exit status ($rc), run with a timeout.
ver() {
	out=$(timeout 30 sh "$src/version.sh" "$@" 2>/dev/null </dev/null)
	rc=$?
}

# no tag
mkrepo "$tmp/notag"
short=$(git -C "$tmp/notag" rev-parse --short HEAD)
ver "$tmp/notag"
eq V01-AC-1:no-tag-prints-short-commit "$short" "$out"
eq V01-AC-1:no-tag-exits-0 0 "$rc"

# tagged commit
mkrepo "$tmp/tagged"
git -C "$tmp/tagged" tag v0.4.0
ver "$tmp/tagged"
eq V01-AC-1:tagged-commit-prints-the-tag v0.4.0 "$out"
eq V01-AC-1:tagged-exits-0 0 "$rc"

# commit after a tag
git -C "$tmp/tagged" commit -q --allow-empty -m two
want=$(git -C "$tmp/tagged" describe --tags --always)
case $want in v0.4.0-1-g*) pass "V01-AC-1:fixture-describe-shape" ;; *) fail "V01-AC-1:fixture-describe-shape ($want)" ;; esac
ver "$tmp/tagged"
eq V01-AC-1:after-tag-prints-tag-n-gshort "$want" "$out"
eq V01-AC-1:after-tag-exits-0 0 "$rc"

# outside any checkout
mkdir -p "$tmp/plain"
GIT_CEILING_DIRECTORIES=$tmp ver "$tmp/plain"
eq V01-AC-1:outside-checkout-prints-unknown unknown "$out"
eq V01-AC-1:outside-checkout-exits-0 0 "$rc"
GIT_CEILING_DIRECTORIES=$tmp ver "$tmp/does-not-exist"
eq V01-AC-1:missing-directory-prints-unknown unknown "$out"
eq V01-AC-1:missing-directory-exits-0 0 "$rc"
GIT_CEILING_DIRECTORIES=$tmp ver --signature "$tmp/plain"
eq V01-AC-2:outside-checkout-signature-has-unknown "— n00dl3b0t unknown" "$out"
eq V01-AC-2:outside-checkout-signature-exits-0 0 "$rc"

# signature with a GitHub origin, in each URL form
mkrepo "$tmp/gh"
git -C "$tmp/gh" tag v2.0.0
git -C "$tmp/gh" commit -q --allow-empty -m two
full=$(git -C "$tmp/gh" rev-parse HEAD)
gv=$(git -C "$tmp/gh" describe --tags --always)
sig() { git -C "$tmp/gh" remote remove origin 2>/dev/null; git -C "$tmp/gh" remote add origin "$2"; ver --signature "$tmp/gh"; eq "$1" "— n00dl3b0t [$gv](https://github.com/acme-co/widget-kit/commit/$full)" "$out"; eq "$1-exits-0" 0 "$rc"; }
sig V01-AC-2:https-origin-with-git-suffix https://github.com/acme-co/widget-kit.git
sig V01-AC-2:https-origin-without-git-suffix https://github.com/acme-co/widget-kit
sig V01-AC-2:ssh-origin git@github.com:acme-co/widget-kit.git
ver "$tmp/gh"
eq V01-AC-1:version-unchanged-by-origin "$gv" "$out"

# non-GitHub origin, no origin
git -C "$tmp/gh" remote remove origin
git -C "$tmp/gh" remote add origin https://git.example.invalid/acme-co/widget-kit.git
ver --signature "$tmp/gh"
eq V01-AC-2:non-github-origin-no-link "— n00dl3b0t $gv" "$out"
eq V01-AC-2:non-github-origin-exits-0 0 "$rc"
mkrepo "$tmp/noorigin"
nv=$(git -C "$tmp/noorigin" rev-parse --short HEAD)
ver --signature "$tmp/noorigin"
eq V01-AC-2:no-origin-no-link "— n00dl3b0t $nv" "$out"
eq V01-AC-2:no-origin-exits-0 0 "$rc"

# status.sh: version line from state/<name>/version while the loop runs
rt=$tmp/rt
mkdir -p "$rt/state/widget-kit" "$tmp/home/.config/noodlebot" "$tmp/bin"
printf '#!/bin/sh\necho fake-token\n' >"$tmp/home/.config/noodlebot/token"
chmod +x "$tmp/home/.config/noodlebot/token"
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"
echo v7.7.7-2-gabc1234 >"$rt/state/widget-kit/version"
setsid sh -c 'exec 9>"$1/state/widget-kit/loop.lock"; flock -n 9 || exit 1; echo $$ >"$1/holder"; while :; do sleep 0.2; done' sh "$rt" >/dev/null 2>&1 </dev/null &
i=0; while [ ! -s "$rt/holder" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
cp "$rt/holder" "$tmp/a.holder" 2>/dev/null
sout=$(HOME=$tmp/home NOODLEBOT_DATA=$rt PATH=$tmp/bin:$PATH timeout 60 bash "$src/status.sh" acme-co/widget-kit 2>&1 </dev/null)
case $sout in *"loop:    running"*) pass "V01-AC-8:fixture-loop-counts-as-running" ;; *) fail "V01-AC-8:fixture-loop-counts-as-running" ;; esac
case $sout in *"version: v7.7.7-2-gabc1234"*) pass "V01-AC-8:status-prints-version-line" ;; *) fail "V01-AC-8:status-prints-version-line" ;; esac

[ "$fails" = 0 ] || { echo "$fails failed"; exit 1; }
echo "all passed"
