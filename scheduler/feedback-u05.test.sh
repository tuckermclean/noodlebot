#!/bin/sh
# Tests scheduler/feedback.py (U05-AC-5): the owner's approval comment (first line, without surrounding whitespace,
# exactly "Frozen lines approved at <7-40 hex>", whatever follows) is not feedback; an owner comment whose first line
# is anything else is feedback as before. Over G03's fake `gh api` and the fixtures of scheduler/testdata/feedback/
# (the cases' own comments are generated in the scratch folder).
#   sh scheduler/feedback-u05.test.sh   (make test)
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
ok() { name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

U=$tmp/U05
data=$U/data
mkdir -p "$U/bin"
cp -R "$src/testdata/feedback" "$data"
export FB_DATA=$data
cat >"$U/bin/gh" <<'EOS'
#!/bin/sh
# fake gh: only `gh api --paginate repos/o/r/(issues|pulls)/N/(comments|reviews)`, served from $FB_DATA.
[ "$1" = api ] && [ "$2" = --paginate ] && [ $# -eq 3 ] || { echo "fake gh: unexpected: $*" >&2; exit 2; }
case $3 in
repos/o/r/issues/*/comments | repos/o/r/pulls/*/comments | repos/o/r/pulls/*/reviews) ;;
*) echo "fake gh: unexpected path $3" >&2; exit 2 ;;
esac
f=$(echo "${3#repos/o/r/}" | tr / -)
if [ -f "$FB_DATA/$f.json" ]; then cat "$FB_DATA/$f.json"; else echo '[]'; fi
EOS
chmod +x "$U/bin/gh"
export PATH=$U/bin:$PATH
export GH_TOKEN=fake

# The cases: PR number, branch, then its owner conversation comments as (id, body); python writes the fixtures.
# A body is written with \n for line breaks. cases.txt lines: "<pr> <id> <body>"; the PR list is built from them.
APPR='Frozen lines approved at 0123abc'
cat >"$U/cases.txt" <<EOS
31 3101 $APPR
32 3201 $APPR\nplease also look at the docs, thanks
33 3301 $APPR and more words on the first line
34 3401 Please check this first\n$APPR
35 3501 $APPR
35 3502 ORDINARY-COMMENT please rename the flag
36 3601 \t  $APPR  \t\nwords below
37 3701 Frozen lines approved at 0123456789abcdef0123456789abcdef01234567
38 3801 Frozen lines approved at 0123ab
39 3901 Frozen lines approved at 0123456789abcdef0123456789abcdef012345678
40 4001 Frozen lines approved at 0123abz
41 4101 > $APPR
42 4201 $APPR\n\n> quoted owner words
43 4301 frozen lines approved at 0123abc
EOS
python3 -I - "$U/cases.txt" "$data" "$U/prs.tsv" <<'EOS'
import json, sys
cases, data, prs = sys.argv[1:4]
byp = {}
for line in open(cases):
    n, i, body = line.rstrip("\n").split(" ", 2)
    body = body.replace("\\n", "\n").replace("\\t", "\t")
    byp.setdefault(int(n), []).append({"id": int(i), "html_url": "https://github.com/o/r/pull/%s#issuecomment-%s" % (n, i),
        "user": {"login": "owner", "type": "User"}, "author_association": "OWNER", "body": body,
        "created_at": "2026-11-09T09:30:00Z"})
with open(prs, "w") as p:
    for n in sorted(byp):
        json.dump(byp[n], open("%s/issues-%d-comments.json" % (data, n), "w"))
        p.write("%d node/N%d-x %040d true MERGEABLE\n" % (n, n, n))
EOS

state=$U/state
mkdir -p "$state/feedback"          # a record folder exists: not the first run; every record is empty
fb() { python3 -I "$src/feedback.py" --repo o/r --state "$state" --owner owner --prs "$U/prs.tsv" "$@"; }
out=$(fb 2>"$U/err"); rc=$?
printed=" $(printf '%s\n' "$out" | cut -d' ' -f1 | tr '\n' ' ')"
has() { case "$printed" in *" $1 "*) return 0 ;; esac; return 1; }
# printed N: the run was clean and printed PR N, with its FEEDBACK.md
printed_ok() { [ "$rc" = 0 ] && has "$1" && [ -s "$state/feedback/$1.md" ]; }
# quiet N: the run was clean (it printed something, so the harness works), N is not printed, no FEEDBACK.md for it
quiet() { [ "$rc" = 0 ] && [ -n "$out" ] && ! has "$1" && [ ! -e "$state/feedback/$1.md" ]; }
nobody() { ! grep -qF -e "$2" "$state/feedback/$1.md" 2>/dev/null; }

ok "U05-AC-5: the run reads every PR and exits 0" test "$rc" = 0
ok "U05-AC-5: the owner's approval comment, alone, prints nothing and writes no FEEDBACK.md" quiet 31
ok "U05-AC-5: the approval comment with the owner's words after its first line prints nothing and writes no FEEDBACK.md" quiet 32
ok "U05-AC-5: an owner comment with more text after the sha on its first line prints the PR" printed_ok 33
ok "U05-AC-5: that comment is in FEEDBACK.md" grep -qF "more words on the first line" "$state/feedback/33.md"
ok "U05-AC-5: an owner comment with the approval line only below its first line prints the PR" printed_ok 34
ok "U05-AC-5: that comment is in FEEDBACK.md" grep -qF "Please check this first" "$state/feedback/34.md"
ok "U05-AC-5: an approval comment followed by an ordinary owner comment prints the PR" printed_ok 35
ok "U05-AC-5: ... FEEDBACK.md holds the ordinary comment" grep -qF "ORDINARY-COMMENT please rename the flag" "$state/feedback/35.md"
ok "U05-AC-5: ... and not the approval comment" nobody 35 "Frozen lines approved at"
ok "U05-AC-5: ... only the ordinary comment's id" sh -c 'grep -qxF "id: 3502" "$1" && ! grep -qxF "id: 3501" "$1"' x "$state/feedback/35.md"
ok "U05-AC-5: an approval line with whitespace around its first line prints nothing" quiet 36
ok "U05-AC-5: an approval with a 40-character sha prints nothing" quiet 37
ok "U05-AC-5: an approval with 6 hex characters is not an approval: prints the PR" printed_ok 38
ok "U05-AC-5: an approval with 41 hex characters is not an approval: prints the PR" printed_ok 39
ok "U05-AC-5: an approval with a non-hex character is not an approval: prints the PR" printed_ok 40
ok "U05-AC-5: a quoted approval line is feedback: prints the PR" printed_ok 41
ok "U05-AC-5: an approval line followed by a blank line and a quote prints nothing" quiet 42
ok "U05-AC-5: a different spelling (lower case) is not an approval: prints the PR" printed_ok 43

if [ "$fails" -gt 0 ]; then echo "$fails failed"; exit 1; fi
echo "all passed"
