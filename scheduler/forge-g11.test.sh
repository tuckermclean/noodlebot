#!/bin/sh
# G11: the values that reach a request path, a query, a web URL or a git argument are checked before any call.
#   sh scheduler/forge-g11.test.sh   (make test)
#
#   G11-AC-1  ci runs --workflow: a workflow file name or a numeric id as before, anything else exit 2 / forge.BadValue
#   G11-AC-2  commit checks --sha, issue comments --since, site publish --target, label remove --name, repo url --ref
#             (forge.web_url, forge.commit_link, remote-commit-link) and branch push --branch: the same
#   G11-AC-3  the sweep of every operation's str and list arguments over the operation table with hostile values
#   G11-AC-4  forges/README.md names each accepted form, forge.BadValue and the kind path
# Both backends (the GitHub backend over the gh emulator testdata/forge/fakegh.py, which records each call, and the fake
# forge testdata/forge/fake.py, which records its calls when $FAKE_FORGE_CALLS is set), through the Python interface and the
# CLI. The cases are testdata/forge/g11.py. All scratch files are under $tmp/G11; HOME is scratch: the real token script is
# never run, no GH_TOKEN is set, and a push goes to a local bare repository (url.<bare>.insteadOf).
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
td=$src/testdata/forge
. "$src/testdata/lib/common.sh"
for v in $(env | sed -n 's/^\(NOODLEBOT_FORGE[A-Za-z_]*\)=.*/\1/p'); do unset "$v"; done
unset GH_TOKEN USAGE_7D_MARGIN NOODLEBOT_DATA NOODLEBOT_VERSION FAKE_FORGE_CALLS FAKE_GH_DIR
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
G=$tmp/G11
mkdir -p "$G/home" "$G/w/bin"
real_git=$(command -v git)
export HOME=$G/home XDG_CONFIG_HOME=$G/home GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.test GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.test
W=$G/w
printf '#!/bin/sh\nexec python3 "%s/fakegh.py" "$@"\n' "$td" >"$W/bin/gh"
# git: records the argv of each call in $W/gitlog once the cases run (the setup below is not recorded), then runs the real git
cat >"$W/bin/git" <<EOF2
#!/bin/sh
[ ! -e "$W/gitlog.on" ] || echo "\$*" >>"$W/gitlog"
exec "$real_git" "\$@"
EOF2
chmod +x "$W/bin/gh" "$W/bin/git"
"$real_git" init -q --bare "$W/bare-template.git"
"$real_git" init -q -b main "$W/checkout"
echo one >"$W/checkout/f" && "$real_git" -C "$W/checkout" add f && "$real_git" -C "$W/checkout" commit -q -m one
"$real_git" -C "$W/checkout" checkout -q -b feat/x
echo two >"$W/checkout/f" && "$real_git" -C "$W/checkout" commit -q -a -m two
printf '{"files": {"index.json": {"content": "{\\"a\\": 1}"}}}' >"$W/site-body.json"
: >"$W/gitlog.on"

python3 -I "$td/g11.py" "$W" "$real_git" >"$G/out" 2>"$G/err"
cat "$G/out"
fails=$((fails + $(grep -c '^FAIL: ' "$G/out")))
grep -q '^DONE$' "$G/out" || { echo "FAIL: G11: the cases did not run to their end: $(tail -n 3 "$G/err" | tr '\n' ' ')"; fails=$((fails + 1)); }
[ "$fails" -eq 0 ] || { echo "forge-g11: $fails check(s) failed"; exit 1; }
echo "forge-g11: all checks passed"
