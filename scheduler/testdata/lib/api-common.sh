# Shared by api.test.sh and api-root2.test.sh (P01): the fixture paths, pass/fail, the clean-up, live and ended
# sessions, the schema validator and the JSON helpers. Sourced after src and tmp are set; not run on its own.
fix=$src/testdata/api
schemas=$src/api-schema/v1
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
pids=''
cleanup() {
	for p in $pids $srv_pid; do kill -9 "$p" 2>/dev/null; done
	for p in $pids $srv_pid; do wait "$p" 2>/dev/null; done
	rm -rf "$tmp"
}
srv_pid=''
trap cleanup EXIT
trap 'exit 1' INT TERM
mkdir -p "$tmp/procs"
# Live things are processes started now: sessions whose command line is what loop.sh's alive() matches,
# and a process holding alpha's loop.lock. Ended sessions get the pid of a process that exited.
cat >"$tmp/procs/run-session.sh" <<'EOS'
#!/bin/sh
while :; do sleep 1; done
EOS
live() { # live <state dir> <worktree> <prompt words...>: session.pid of a running session
	d=$1 wt=$2; shift 2
	sh "$tmp/procs/run-session.sh" "$wt" "$d" "$@" </dev/null >/dev/null 2>&1 &
	pids="$pids $!"; echo $! >"$d/session.pid"
}
ended() { sh -c 'exit 0' & p=$!; wait "$p"; echo "$p" >"$1/session.pid"; }

# validate.py <schema> <instance>: a small JSON-schema validator (type, properties, required, items, enum,
# additionalProperties, const). Prints the first error and exits 1; "version" must be 1.
cat >"$tmp/validate.py" <<'EOP'
import json, sys
def check(s, v, p):
    if s is True or s is None: return
    if s is False: raise ValueError("%s: nothing is allowed" % p)
    if "type" in s:
        ts = s["type"] if isinstance(s["type"], list) else [s["type"]]
        def ok(t):
            if t == "null": return v is None
            if t == "boolean": return isinstance(v, bool)
            if t == "integer": return isinstance(v, int) and not isinstance(v, bool)
            if t == "number": return isinstance(v, (int, float)) and not isinstance(v, bool)
            if t == "string": return isinstance(v, str)
            if t == "array": return isinstance(v, list)
            if t == "object": return isinstance(v, dict)
            raise ValueError("unknown type %r" % t)
        if not any(ok(t) for t in ts): raise ValueError("%s: %r is not of type %s" % (p, v, "/".join(ts)))
    if "enum" in s and v not in s["enum"]: raise ValueError("%s: %r not in enum" % (p, v))
    if "const" in s and v != s["const"]: raise ValueError("%s: %r is not %r" % (p, v, s["const"]))
    if isinstance(v, dict):
        for k in s.get("required", []):
            if k not in v: raise ValueError("%s: missing %s" % (p, k))
        props = s.get("properties", {})
        for k, x in v.items():
            if k in props: check(props[k], x, p + "." + k)
            elif s.get("additionalProperties") is False: raise ValueError("%s: unexpected %s" % (p, k))
            elif isinstance(s.get("additionalProperties"), dict): check(s["additionalProperties"], x, p + "." + k)
    if isinstance(v, list) and "items" in s:
        for i, x in enumerate(v): check(s["items"], x, "%s[%d]" % (p, i))
schema = json.load(open(sys.argv[1])); inst = json.load(open(sys.argv[2]))
try:
    if not isinstance(inst, dict) or inst.get("version") != 1 or isinstance(inst.get("version"), bool): raise ValueError('"version": 1 is missing')
    check(schema, inst, "$")
except ValueError as e:
    print(e); sys.exit(1)
EOP

# jx <expr>: evaluate a Python expression over the last body as d; prints the result, "ERR" if not JSON.
jx() { python3 -I -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception: print("ERR"); sys.exit(0)
try: print(eval(sys.argv[2]))
except Exception as e: print("ERR", e)' "$tmp/resp" "$1"; }

nodefield() { # nodefield <ID> <python expr over n, the node>: true when the node's entry in the list satisfies it
	jx "(lambda n: $2)([n for n in d['nodes'] if n['id'] == '$1'][0])"
}
