# Fakes that more than one scheduler/loop*.test.sh uses (source after loop-prelude.sh).

# fake_main_gh: $tmp/bin/gh. Merged PRs come from $tmp/merged.tsv ("<number> <head branch>"), no open PRs. Issues
# labelled noodlebot come from $tmp/issues.json, each labelled by the owner (tuckermclean); label calls are logged
# to $tmp/labels.log, and removing noodlebot empties the list.
fake_main_gh() {
	echo '[]' >"$tmp/issues.json"
	cat >"$tmp/bin/gh" <<EOF2
#!/bin/sh
case " \$* " in
*" --state merged "*) cat "$tmp/merged.tsv" ;;
*"/issues?labels=noodlebot"*) cat "$tmp/issues.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*) echo "\$*" >>"$tmp/labels.log"; echo '[]' >"$tmp/issues.json"; echo '[]' ;;
*"/labels"*) echo "\$*" >>"$tmp/labels.log"; cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF2
	chmod +x "$tmp/bin/gh"
}

# write_closed_py <file>: the fake gh's answer to `gh pr list --state closed` (S01, S03): reads $S01/closed.tsv, rows
# "<number> <branch> <closed time, epoch seconds> <1 if merged>"; with --json and no -q it prints the JSON array
# (number, headRefName, closedAt, mergedAt, state); with -q it applies the forms
# `.[] | "text \(.field) \(.field // "x") \(.field != null)"` and `.[].field`.
write_closed_py() {
	cat >"$1" <<'EOF2'
import datetime, json, os, re, sys
a = sys.argv[1:]
rows = []
for line in open(os.environ["S01"] + "/closed.tsv"):
    f = line.split()
    if len(f) < 4:
        continue
    iso = datetime.datetime.fromtimestamp(int(f[2]), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    rows.append({"number": int(f[0]), "headRefName": f[1], "closedAt": iso,
                 "mergedAt": iso if f[3] == "1" else None, "state": "MERGED" if f[3] == "1" else "CLOSED"})
q = next((a[i + 1] for i, x in enumerate(a) if x in ("-q", "--jq") and i + 1 < len(a)), None)
if q is None:
    print(json.dumps(rows)); sys.exit(0)
def ev(e, r):
    m = re.fullmatch(r'\s*\.(\w+)\s*(?:(!=|==)\s*(null|"[^"]*")|//\s*"([^"]*)")?\s*', e)
    if not m:
        sys.exit("fake gh: unsupported jq expression: " + e)
    v = r.get(m[1])
    if m[2]:
        return str((v == (None if m[3] == "null" else m[3].strip('"'))) == (m[2] == "==")).lower()
    if m[4] is not None and v is None:
        return m[4]
    return "null" if v is None else str(v)
m = re.fullmatch(r'\s*\.\[\]\.(\w+)\s*', q)
if m:
    for r in rows: print(ev("." + m[1], r))
    sys.exit(0)
m = re.fullmatch(r'\s*\.\[\]\s*\|\s*"(.*)"\s*', q)
if not m:
    sys.exit("fake gh: unsupported jq expression: " + q)
for r in rows:
    print(re.sub(r'\\\(((?:[^()]|\([^()]*\))*)\)', lambda x: ev(x[1], r), m[1]))
EOF2
}

# S01 and S03 helpers: process groups (sessions run under setsid; a session's group id is the pid in its session.pid).
# grp_gone <pgid>: no live (non-zombie) process is in that group. dead <pid>: gone or a zombie.
grp_gone() { ! ps -eo pgid=,stat= | awk -v g="$1" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }'; }
grp_up() { ! grp_gone "$1"; }
dead() { [ ! -d "/proc/$1" ] || grep -q ') Z' "/proc/$1/stat"; }
