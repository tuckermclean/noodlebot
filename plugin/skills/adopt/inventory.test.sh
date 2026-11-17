#!/bin/sh
# Tests plugin/skills/adopt/inventory.py (A03-AC-1 to A03-AC-4).
#   sh plugin/skills/adopt/inventory.test.sh   (make test)
# A fixture repository is built in a temporary folder from testdata/inventory/ (git init; vendor/ and
# node_modules/ made here and added with git add -f; executable mode set with chmod +x before git add):
# R2 has no docs/graph.yaml, R1 has a graph whose one node owns src/core/ and an out_of_scope legacy/,
# R3 has a graph with no ownership. JSON is parsed with python3 -I; with no inventory.py every check FAILs.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
inv="$src/inventory.py"
fix="$src/testdata/inventory"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fails=$((fails + 1)); }
GIT_CONFIG_GLOBAL=/dev/null
GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

# ---------- the checker: prints "ok <text>" or "bad <text>" per check, never stops early ----------
cat >"$tmp/chk.py" <<'PY'
import json, re, sys

mode, jpath = sys.argv[1], sys.argv[2]
rest = sys.argv[3:]
try:
    with open(jpath) as f:
        D = json.load(f)
    if not isinstance(D, dict):
        D = {}
except Exception:
    D = {}
out = []


def check(name, fn):
    try:
        r = fn()
        good = r is None or r is True
        msg = name if good else "%s (%s)" % (name, r)
    except Exception as e:
        good, msg = False, "%s (%s: %s)" % (name, type(e).__name__, e)
    out.append(("ok " if good else "bad ") + msg)


def lines(p):
    return open(p).read().split("\n") if p else []


def need(c, why=""):
    return True if c else why or "false"


def paths(key):
    return [x["path"] if isinstance(x, dict) else x for x in D[key]]


def links(src, sub):
    return [l for l in D["links"] if l["source"] == src and sub in l["raw"]]


def link_to(src, sub, kind, target):
    ls = links(src, sub)
    return need(ls and all(l["kind"] == kind and l["target"] == target for l in ls),
                "links %r" % ls)


if mode == "base":
    tracked = [l for l in lines(rest[0]) if l]
    byp = {}
    def f_files():
        global byp
        byp = {x["path"]: x for x in D["files"]}
        miss = sorted(set(tracked) - set(byp))
        extra = sorted(set(byp) - set(tracked))
        return need(not miss and not extra and len(byp) == len(D["files"]), "missing %s extra %s" % (miss, extra))
    check("A03-AC-1: --json files are exactly the tracked files", f_files)
    check("A03-AC-1: --json has exactly the keys files, languages, entrypoints, tests, ci, candidates, links, unowned, areas",
          lambda: need(sorted(D) == sorted("files languages entrypoints tests ci candidates links unowned areas".split()), sorted(D)))
    def lang(p, want):
        return lambda: need(byp[p]["language"] == want, byp[p]["language"])
    check("A03-AC-1: language of src/core/engine.py is python", lang("src/core/engine.py", "python"))
    check("A03-AC-1: language of web/index.js is javascript", lang("web/index.js", "javascript"))
    check("A03-AC-1: language of lib/common.sh is shell", lang("lib/common.sh", "shell"))
    check("A03-AC-1: language of README.md is markdown", lang("README.md", "markdown"))
    check("A03-AC-1: language of tools/gen (no extension, no shebang) is other", lang("tools/gen", "other"))
    check("A03-AC-1: language of run.sh is shell", lang("run.sh", "shell"))
    check("A03-AC-1: lines of src/core/engine.py is its 9 non-blank lines",
          lambda: need(byp["src/core/engine.py"]["lines"] == 9, byp["src/core/engine.py"]["lines"]))
    check("A03-AC-1: lines of README.md leave out blank lines (2)",
          lambda: need(byp["README.md"]["lines"] == 2, byp["README.md"]["lines"]))
    def f_langs():
        L = D["languages"]
        for lg, v in L.items():
            fs = [x for x in D["files"] if x["language"] == lg]
            if v["files"] != len(fs) or v["lines"] != sum(x["lines"] for x in fs):
                return "%s: %s" % (lg, v)
        return need(set(L) == {x["language"] for x in D["files"]} and "python" in L, sorted(L))
    check("A03-AC-1: languages sums files and lines per language", f_langs)
    ep = lambda: {(e["path"], e["kind"]) for e in D["entrypoints"]}
    check("A03-AC-1: entrypoint run.sh by shebang", lambda: need(("run.sh", "shebang") in ep(), sorted(ep())))
    check("A03-AC-1: entrypoint src/app/main.py by if __name__ == __main__",
          lambda: need(("src/app/main.py", "main") in ep(), sorted(ep())))
    check("A03-AC-1: entrypoint by a package manifest's main or bin",
          lambda: need(any(k == "manifest" and p in ("package.json", "web/index.js", "web/cli.js") for p, k in ep()), sorted(ep())))
    check("A03-AC-1: entrypoints by executable mode: run.sh and tools/gen",
          lambda: need(("run.sh", "executable") in ep() and ("tools/gen", "executable") in ep(), sorted(ep())))
    check("A03-AC-1: tools/gen (executable, no shebang) is not a shebang entrypoint, engine.py is no entrypoint",
          lambda: need(("tools/gen", "shebang") not in ep() and not any(p == "src/core/engine.py" for p, k in ep()), sorted(ep())))
    check("A03-AC-1: one entry per (path, kind)",
          lambda: need(len(ep()) == len(D["entrypoints"]), D["entrypoints"]))
    check("A03-AC-1: tests list tests/test_core.py and web/web.test.js, not engine.py",
          lambda: need({"tests/test_core.py", "web/web.test.js"} <= set(D["tests"]) and "src/core/engine.py" not in D["tests"], D["tests"]))
    check("A03-AC-1: ci lists exactly .github/workflows/ci.yml",
          lambda: need(D["ci"] == [".github/workflows/ci.yml"], D["ci"]))
    cand = lambda: {c["path"]: c["reason"] for c in D["candidates"]}
    for p in ("vendor/", "node_modules/", "api/client.py"):
        check("A03-AC-1: candidate %s with a reason" % p,
              (lambda p: lambda: need(isinstance(cand().get(p), str) and cand()[p].strip(), sorted(cand())))(p))
    check("A03-AC-1: no ordinary file is a candidate",
          lambda: need(not any(p.startswith(("src/", "web/", "tests/", "flat/")) for p in cand()), sorted(cand())))
    # ---- A03-AC-2
    check("A03-AC-2: python import in src/app/main.py resolves to src/core/engine.py",
          lambda: link_to("src/app/main.py", "core.engine", "import", "src/core/engine.py"))
    check("A03-AC-2: python import in engine.py resolves to src/core/util.py",
          lambda: link_to("src/core/engine.py", "core.util", "import", "src/core/util.py"))
    check("A03-AC-2: python import in tests/test_core.py resolves to src/core/engine.py",
          lambda: link_to("tests/test_core.py", "core.engine", "import", "src/core/engine.py"))
    check("A03-AC-2: JS import ... from resolves to web/lib/greet.js (kind require, raw as written)",
          lambda: link_to("web/index.js", "./lib/greet.js", "require", "web/lib/greet.js"))
    check("A03-AC-2: JS require( resolves to web/lib/util.js",
          lambda: link_to("web/index.js", "./lib/util.js", "require", "web/lib/util.js"))
    check("A03-AC-2: shell '. path' resolves to lib/common.sh",
          lambda: link_to("run.sh", "lib/common.sh", "source", "lib/common.sh"))
    check("A03-AC-2: shell 'source path' resolves to lib/helpers.sh",
          lambda: link_to("run.sh", "lib/helpers.sh", "source", "lib/helpers.sh"))
    check("A03-AC-2: python import of a missing module keeps its raw text, target null",
          lambda: link_to("src/app/main.py", "missing_module", "import", None))
    check("A03-AC-2: JS require of a missing file keeps its raw text, target null",
          lambda: link_to("web/index.js", "./missing.js", "require", None))
    check("A03-AC-2: shell source of a missing file keeps its raw text, target null",
          lambda: link_to("run.sh", "lib/missing.sh", "source", None))
    check("A03-AC-2: every link has source, kind, raw and target keys",
          lambda: need(D["links"] and all(sorted(l) == ["kind", "raw", "source", "target"] for l in D["links"]), D["links"][:1]))

elif mode == "unowned":
    want = sorted(l for l in lines(rest[0]) if l)
    label = rest[1]
    check("A03-AC-3: json unowned (%s) is exactly the expected sorted list" % label,
          lambda: need(D["unowned"] == want, "got %s want %s" % (D["unowned"], want)))

elif mode == "areas":
    elig = [l for l in lines(rest[0]) if l]
    n = int(rest[1])
    label = rest[2]
    split = rest[3] == "split"
    A = []
    def f_exact():
        global A
        A = D["areas"]
        seen = [p for a in A for p in a["files"]]
        dup = sorted({p for p in seen if seen.count(p) > 1})
        return need(sorted(seen) == sorted(set(seen)) and set(seen) == set(elig) and A,
                    "dup %s missing %s extra %s" % (dup, sorted(set(elig) - set(seen)), sorted(set(seen) - set(elig))))
    check("A03-AC-4: every eligible file is in exactly one area, no other file is (%s)" % label, f_exact)
    check("A03-AC-4: area names are kebab-case, distinct, never scaffold or plan (%s)" % label,
          lambda: need(A and all(re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", a["name"]) and a["name"] not in ("scaffold", "plan") for a in A)
                       and len({a["name"] for a in A}) == len(A), [a["name"] for a in A]))
    check("A03-AC-4: every area has globs and files (%s)" % label,
          lambda: need(A and all(a["globs"] and a["files"] for a in A), [a["name"] for a in A]))
    byp = {x["path"]: x["lines"] for x in D.get("files", [])}
    check("A03-AC-4: area lines are the sum of its files' lines (%s)" % label,
          lambda: need(A and all(a["lines"] == sum(byp[p] for p in a["files"]) for a in A), [(a["name"], a["lines"]) for a in A]))
    check("A03-AC-4: no area is over --max-lines %d unless it is one file (%s)" % (n, label),
          lambda: need(A and all(a["lines"] <= n or len(a["files"]) == 1 for a in A), [(a["name"], a["lines"], len(a["files"])) for a in A]))
    idx = lambda p: next(i for i, a in enumerate(A) if p in a["files"])
    if "src/core/engine.py" in elig:
        check("A03-AC-4: src/app/main.py's area does not come before the area of src/core/engine.py it imports (%s)" % label,
              lambda: need(idx("src/app/main.py") >= idx("src/core/engine.py"), "main %d engine %d" % (idx("src/app/main.py"), idx("src/core/engine.py"))))
        check("A03-AC-4: tests/test_core.py's area does not come before engine.py's (%s)" % label,
              lambda: need(A and idx("tests/test_core.py") >= idx("src/core/engine.py"), "no areas"))
    check("A03-AC-4: web/index.js's area does not come before web/lib/util.js's (%s)" % label,
          lambda: need(idx("web/index.js") >= idx("web/lib/util.js")))
    if split and "src/core/engine.py" in elig:
        check("A03-AC-4: main.py and engine.py (17 lines together) are in different areas, importer after imported (%s)" % label,
              lambda: need(idx("src/app/main.py") > idx("src/core/engine.py"), "main %d engine %d" % (idx("src/app/main.py"), idx("src/core/engine.py"))))
    if split:
        check("A03-AC-4: the flat folder (40 lines > %d) is split into groups of files in several areas (%s)" % (n, label),
              lambda: need(len({idx(p) for p in elig if p.startswith("flat/")}) >= 2, [a["files"] for a in A if any(p.startswith("flat/") for p in a["files"])]))

elif mode == "glob":
    pre = rest[1]
    tracked = [l for l in lines(rest[0]) if l and l.startswith(pre)]
    key = rest[2]
    def under(p):
        return p.startswith(pre)
    check("A03-AC-1: --glob %s limits files to the tracked files under it" % pre,
          lambda: need(sorted(paths("files")) == sorted(tracked) and tracked, paths("files")))
    def f_lists():
        bad = []
        for k in ("entrypoints", "tests", "ci", "candidates", "unowned"):
            bad += [p for p in paths(k) if not under(p)]
        bad += [l["source"] for l in D["links"] if not under(l["source"])]
        bad += [p for a in D["areas"] for p in a["files"] if not under(p)]
        return need(not bad, bad)
    check("A03-AC-1: --glob %s limits entrypoints, tests, ci, candidates, links, unowned and areas to it" % pre, f_lists)
    check("A03-AC-1: --glob %s keeps its own %s" % (pre, key), lambda: need(len(D[key]) > 0, D[key]))
    check("A03-AC-1: --glob %s languages cover only the limited files" % pre,
          lambda: need(sum(v["files"] for v in D["languages"].values()) == len(tracked), D["languages"]))

print("\n".join(out))
PY

report() { # report <result file>
	_n=0
	while IFS= read -r _l; do
		_n=$((_n + 1))
		case $_l in
		ok\ *) ok "${_l#ok }" ;;
		*) bad "${_l#bad }" ;;
		esac
	done <"$1"
	[ "$_n" -gt 0 ] || bad "A03: the checker printed nothing ($(head -n 2 "$tmp/chk.err" 2>/dev/null))"
}
chk() { # chk <mode> <json> args...
	python3 -I "$tmp/chk.py" "$@" >"$tmp/chk.out" 2>"$tmp/chk.err" || bad "A03: the checker crashed: $(head -n 3 "$tmp/chk.err")"
	report "$tmp/chk.out"
}
run() { # run <outfile> <repo> args...: run inventory.py, keep stdout, exit status in $rc
	_o=$1
	shift
	python3 -I "$inv" "$@" >"$_o" 2>"$tmp/run.err"
	rc=$?
}

# ---------- the fixture repositories ----------
mkrepo() { # mkrepo <dir>
	d=$1
	mkdir -p "$d"
	cp -R "$fix/." "$d/"
	rm -f "$d/graph.yaml"
	mkdir -p "$d/.github/workflows" "$d/vendor/lib" "$d/node_modules/pkg"
	mv "$d/ci/ci.yml" "$d/.github/workflows/ci.yml"
	rmdir "$d/ci"
	printf 'module.exports = 1;\nvar a = 2;\n' >"$d/vendor/lib/x.js"
	printf 'module.exports = 3;\n' >"$d/node_modules/pkg/index.js"
	chmod +x "$d/run.sh" "$d/tools/gen"
	(cd "$d" && git init -q && git add -f -A && git -c user.name=t -c user.email=t@t commit -q -m fixture)
}
mkrepo "$tmp/r2"
cp -R "$tmp/r2" "$tmp/r1"
mkdir -p "$tmp/r1/docs"
cp "$fix/graph.yaml" "$tmp/r1/docs/graph.yaml"
(cd "$tmp/r1" && git add -f -A && git -c user.name=t -c user.email=t@t commit -q -m graph)
cp -R "$tmp/r2" "$tmp/r3"
mkdir -p "$tmp/r3/docs"
cat >"$tmp/r3/docs/graph.yaml" <<'G'
template: {headings: [Purpose, Tests, Changes, Gate, Risks]}
nodes:
  - {id: X01, track: now, name: core, deps: [], summary: "No ownership here"}
G
(cd "$tmp/r3" && git add -f -A && git -c user.name=t -c user.email=t@t commit -q -m graph)
for r in r1 r2 r3; do (cd "$tmp/$r" && git ls-files | sort >"$tmp/$r.tracked"); done
# the files --areas must place: not candidates, not owned, not the regime's own
grep -v -e '^vendor/' -e '^node_modules/' -e '^api/client.py$' -e '^AGENTS.md$' "$tmp/r2.tracked" >"$tmp/r2.elig"
grep -v -e '^vendor/' -e '^node_modules/' -e '^api/client.py$' -e '^AGENTS.md$' -e '^docs/graph.yaml$' \
	-e '^src/core/' -e '^legacy/' "$tmp/r1.tracked" >"$tmp/r1.elig"
grep -v -e '^vendor/' -e '^node_modules/' -e '^api/client.py$' -e '^AGENTS.md$' -e '^docs/graph.yaml$' "$tmp/r3.tracked" >"$tmp/r3.elig"
# the files no owns and no out_of_scope covers, not the regime's own
grep -v -e '^AGENTS.md$' -e '^docs/graph.yaml$' -e '^src/core/' -e '^legacy/' "$tmp/r1.tracked" >"$tmp/r1.unowned"
: >"$tmp/none"

# ---------- A03-AC-1, A03-AC-2: the listing and the links (no graph, and with the graph) ----------
for r in r2 r1; do
	run "$tmp/$r.json" "$tmp/$r" "$tmp/$r" --json
	[ "$rc" -eq 0 ] && ok "A03-AC-1: --json on $r exits 0" || bad "A03-AC-1: --json on $r exits $rc ($(head -n 1 "$tmp/run.err"))"
	chk base "$tmp/$r.json" "$tmp/$r.tracked"
done

# the short summary
run "$tmp/sum.txt" "$tmp/r2"
[ "$rc" -eq 0 ] && ok "A03-AC-1: the summary exits 0" || bad "A03-AC-1: the summary exits $rc ($(head -n 1 "$tmp/run.err"))"
if [ -s "$tmp/sum.txt" ] && [ "$(head -c 1 "$tmp/sum.txt")" != "{" ]; then ok "A03-AC-1: the summary is text, not JSON"; else bad "A03-AC-1: the summary is text, not JSON"; fi
for w in python javascript shell run.sh src/app/main.py tests/test_core.py .github/workflows/ci.yml vendor/ node_modules/ api/client.py; do
	if grep -qF -e "$w" "$tmp/sum.txt" 2>/dev/null; then ok "A03-AC-1: the summary names $w"; else bad "A03-AC-1: the summary names $w"; fi
done

# --glob limits every list to one folder
for spec in "src/core/:files" "tests/:tests" "vendor/:candidates" ".github/:ci" "web/:links"; do
	g=${spec%%:*}
	k=${spec#*:}
	run "$tmp/glob.json" "$tmp/r2" --json --glob "$g"
	[ "$rc" -eq 0 ] && ok "A03-AC-1: --glob $g exits 0" || bad "A03-AC-1: --glob $g exits $rc"
	chk glob "$tmp/glob.json" "$tmp/r2.tracked" "$g" "$k"
done

# ---------- A03-AC-3: --unowned ----------
run "$tmp/u1.txt" "$tmp/r1" --unowned
[ "$rc" -eq 0 ] && ok "A03-AC-3: --unowned with the graph exits 0" || bad "A03-AC-3: --unowned with the graph exits $rc ($(head -n 1 "$tmp/run.err"))"
if [ -s "$tmp/u1.txt" ] && cmp -s "$tmp/u1.txt" "$tmp/r1.unowned"; then ok "A03-AC-3: --unowned with the graph lists exactly the sorted files no owns or out_of_scope covers, not the regime's"; else bad "A03-AC-3: --unowned with the graph lists exactly the sorted files no owns or out_of_scope covers, not the regime's (got $(wc -l <"$tmp/u1.txt") lines, want $(wc -l <"$tmp/r1.unowned"))"; fi
for p in src/core/engine.py legacy/old.py AGENTS.md docs/graph.yaml; do
	if [ -s "$tmp/u1.txt" ] && ! grep -qx "$p" "$tmp/u1.txt"; then ok "A03-AC-3: --unowned leaves out $p"; else bad "A03-AC-3: --unowned leaves out $p"; fi
done
chk unowned "$tmp/r1.json" "$tmp/r1.unowned" "graph owning src/core/"
for r in r2 r3; do
	run "$tmp/u.txt" "$tmp/$r" --unowned
	if [ "$rc" -eq 0 ]; then ok "A03-AC-3: --unowned on $r exits 0"; else bad "A03-AC-3: --unowned on $r exits $rc ($(head -n 1 "$tmp/run.err"))"; fi
	if [ "$rc" -eq 0 ] && [ -z "$(cat "$tmp/u.txt")" ]; then ok "A03-AC-3: --unowned lists nothing for $r (no graph / no ownership)"; else bad "A03-AC-3: --unowned lists nothing for $r (no graph / no ownership)"; fi
done
run "$tmp/r2u.json" "$tmp/r2" --json
chk unowned "$tmp/r2u.json" "$tmp/none" "no graph"
run "$tmp/r3.json" "$tmp/r3" --json
chk unowned "$tmp/r3.json" "$tmp/none" "graph without ownership"

# ---------- A03-AC-4: --areas ----------
# default --max-lines (4000): one or a few areas; small --max-lines 15: files split, flat folder in groups
for r in r2 r1; do
	run "$tmp/a.json" "$tmp/$r" --json
	chk areas "$tmp/a.json" "$tmp/$r.elig" 4000 "$r default max-lines" nosplit
	run "$tmp/a15.json" "$tmp/$r" --json --max-lines 15
	if [ "$rc" -eq 0 ]; then ok "A03-AC-4: --json --max-lines 15 on $r exits 0"; else bad "A03-AC-4: --json --max-lines 15 on $r exits $rc ($(head -n 1 "$tmp/run.err"))"; fi
	chk areas "$tmp/a15.json" "$tmp/$r.elig" 15 "$r max-lines 15" split
	run "$tmp/at.txt" "$tmp/$r" --areas --max-lines 15
	if [ "$rc" -eq 0 ] && [ -s "$tmp/at.txt" ] && grep -qF flat/ "$tmp/at.txt"; then ok "A03-AC-4: --areas lists the areas as text on $r"; else bad "A03-AC-4: --areas lists the areas as text on $r (exit $rc)"; fi
done
run "$tmp/a3.json" "$tmp/r3" --json --max-lines 15
chk areas "$tmp/a3.json" "$tmp/r3.elig" 15 "r3 graph without ownership, max-lines 15" split
[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
