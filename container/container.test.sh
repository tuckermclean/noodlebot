#!/bin/sh
# Tests the static structure of the container files (D06-AC-2 static part, D06-AC-7, D06-AC-8 structure, D06-AC-9,
# D06-AC-10):  sh container/container.test.sh   (make test)
#
# Reads container/Containerfile, .containerignore, container/compose.yaml, container/k8s/*, .github/workflows/image.yml,
# README.md, SPEC.md, AGENTS.md. YAML is read with PyYAML (python3 -I, as plugin/skills/node/check-regime.py does).
# Offline, no container runtime, no kubectl. A missing file gives FAIL lines, never a crash of the harness.
# Choices where the spec leaves room (each marked "choice" below):
#   - the Containerfile gives noodlebot an explicit uid (useradd/adduser -u N); the manifests' runAsUser must equal it;
#   - .containerignore is evaluated with Docker's rules (last matching pattern wins, "!" re-includes, "**", a pattern
#     for a directory covers what is below it); every tracked file must be admitted, .git admitted, and out/, the
#     .gitignore entries and .config/noodlebot/ must be excluded (an exclude-all-then-allow-list satisfies this);
#   - an image push step is: a run line with docker/podman/buildah/skopeo ... push, or build-push-action with a push
#     that is not literally false;
#   - the README's one-replica statement matches: (one|a single|exactly one|1) replica | replicas: 1.
set -u
src=$(cd "$(dirname "$0")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0

cat >"$tmp/check.py" <<'EOPY'
import fnmatch
import json
import os
import re
import shlex
import subprocess
import sys

import yaml

root = sys.argv[1]
nfail = 0


def chk(name, fn):
    global nfail
    try:
        r = fn()
        ok, detail = (r if isinstance(r, tuple) else (bool(r), ""))
    except Exception as e:  # a missing file or key is a failure, never a crash
        ok, detail = False, "%s: %s" % (type(e).__name__, e)
    if ok:
        print("PASS: %s" % name)
    else:
        nfail += 1
        print("FAIL: %s%s" % (name, (" (" + str(detail)[:150] + ")") if detail else ""))


def path(*p):
    return os.path.join(root, *p)


def text(*p):
    with open(path(*p), encoding="utf-8") as f:
        return f.read()


def yload(*p):
    return yaml.safe_load(text(*p))


def safe(fn):
    try:
        return fn()
    except Exception:
        return None


# ---------------------------------------------------------------- Containerfile
def instructions(src):
    out, cur = [], ""
    for line in src.splitlines():
        s = line.strip()
        if not cur and (not s or s.startswith("#")):
            continue
        if s.startswith("#"):
            continue
        if s.endswith("\\"):
            cur += s[:-1] + " "
            continue
        cur += s
        m = re.match(r"(\w+)\s*(.*)$", cur)
        if m:
            out.append((m.group(1).upper(), m.group(2)))
        cur = ""
    return out


cf_text = safe(lambda: text("container", "Containerfile"))
cf = instructions(cf_text) if cf_text is not None else None


def copy_dests():
    d = []
    for k, rest in cf:
        if k in ("COPY", "ADD"):
            toks = [t for t in shlex.split(rest) if not t.startswith("--")]
            d.append(toks[-1].strip('[]",'))
    return d


def cf_uid():
    for k, rest in cf:
        if k == "RUN":
            for seg in re.split(r"&&|;|\n", rest):
                if re.search(r"\b(useradd|adduser)\b", seg) and re.search(r"\bnoodlebot\b", seg):
                    m = re.search(r"(?:\s-u|\s--uid)[ =]+(\d+)", seg)
                    if m:
                        return int(m.group(1))
    return None


chk("D06-AC-2 container/Containerfile exists", lambda: cf_text is not None)
chk("D06-AC-2 Containerfile copies the build context to /opt/noodlebot",
    lambda: any(d.rstrip("/") == "/opt/noodlebot" for d in copy_dests()))


def origin_from_arg():
    args = [re.match(r"([A-Za-z_][A-Za-z0-9_]*)", r).group(1) for k, r in cf if k == "ARG"]
    for k, rest in cf:
        if "origin" in rest and k in ("RUN", "ENV"):
            for a in args:
                if re.search(r"\$\{?%s\b" % re.escape(a), rest):
                    return True
    return False


chk("D06-AC-2 Containerfile sets origin from a build ARG", origin_from_arg)
chk("D06-AC-2 Containerfile names no repository (no owner name, no github.com/<x>/<y>)",
    lambda: (not re.search(r"tuckermclean", cf_text, re.I)
             and not re.search(r"(?<![\w.-])github\.com[/:][\w.-]+/[\w.-]+", cf_text),
             "repository literal in file"))
chk("D06-AC-2 Containerfile copies nothing into a .config/noodlebot path",
    lambda: (cf is not None and not any(".config/noodlebot" in d for d in copy_dests())
             and not any(k in ("COPY", "ADD") and ".config/noodlebot" in r for k, r in cf)))
chk("D06-AC-2 Containerfile ends running as USER noodlebot",
    lambda: [r for k, r in cf if k == "USER"][-1].split(":")[0].strip() == "noodlebot")
chk("D06-AC-2 Containerfile gives noodlebot home /home/noodlebot",
    lambda: any(k in ("RUN", "ENV") and "/home/noodlebot" in r for k, r in cf))
chk("D06-AC-2 Containerfile ENTRYPOINT runs container/entrypoint.sh",
    lambda: any(k == "ENTRYPOINT" and "container/entrypoint.sh" in r.replace("\\/", "/")
                or k == "ENTRYPOINT" and "entrypoint.sh" in r for k, r in cf))
chk("D06-AC-2 Containerfile gives noodlebot an explicit uid (useradd -u N)", lambda: cf_uid() is not None)


# ---------------------------------------------------------------- .containerignore
def ignore_rules(src):
    rules = []
    for line in src.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        neg = s.startswith("!")
        if neg:
            s = s[1:].strip()
        s = s.lstrip("/").rstrip("/")
        if s.startswith("./"):
            s = s[2:]
        out, i = "", 0
        while i < len(s):
            c = s[i]
            if s[i:i + 3] == "**/":
                out += "(?:.*/)?"
                i += 3
                continue
            if s[i:i + 2] == "**":
                out += ".*"
                i += 2
                continue
            if c == "*":
                out += "[^/]*"
            elif c == "?":
                out += "[^/]"
            elif c == "[":
                j = s.find("]", i + 1)
                if j < 0:
                    out += re.escape(c)
                else:
                    out += s[i:j + 1].replace("[!", "[^")
                    i = j
            else:
                out += re.escape(c)
            i += 1
        rules.append((neg, re.compile("^" + out + "$")))
    return rules


def admitted(rules, p):
    parts = p.split("/")
    state = True  # in the context unless a pattern excludes it
    for neg, rx in rules:
        if any(rx.match("/".join(parts[:n])) for n in range(1, len(parts) + 1)):
            state = neg
    return state


ci_text = safe(lambda: text(".containerignore"))
rules = ignore_rules(ci_text) if ci_text is not None else None
tracked = safe(lambda: subprocess.run(["git", "-C", root, "ls-files"], capture_output=True, text=True,
                                      check=True).stdout.split("\n"))
tracked = [t for t in (tracked or []) if t]

chk(".containerignore exists (D06-AC-2)", lambda: ci_text is not None)
chk("D06-AC-2 .containerignore admits .git (HEAD, objects, refs)",
    lambda: all(admitted(rules, p) for p in (".git/HEAD", ".git/objects/ab/cdef", ".git/refs/tags/v1", ".git/packed-refs")))
chk("D06-AC-2 .containerignore admits every tracked file",
    lambda: ([t for t in tracked if not admitted(rules, t)][:3] == [] and len(tracked) > 0,
             [t for t in tracked if not admitted(rules, t)][:3]))
chk("D06-AC-2 .containerignore excludes out/ (untracked work files)",
    lambda: not admitted(rules, "out/node/D06/brief.md") and not admitted(rules, "out/x"))


def gitignore_probes():
    probes = []
    for line in text(".gitignore").splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("!"):
            continue
        anchored = s.startswith("/") or ("/" in s.rstrip("/"))
        name = s.strip("/")
        if "*" in name or "?" in name:
            name = name.replace("*", "probe").replace("?", "p")
        probes.append(name + "/probe-file")
        if not anchored:
            probes.append("scheduler/" + name + "/probe-file")
            probes.append("scheduler/" + name)
    return probes


chk("D06-AC-2 .containerignore excludes what .gitignore ignores",
    lambda: ([p for p in gitignore_probes() if admitted(rules, p)][:3] == [] and len(gitignore_probes()) > 0,
             [p for p in gitignore_probes() if admitted(rules, p)][:3]))
chk("D06-AC-2 .containerignore excludes .config/noodlebot/ (no credential in the context)",
    lambda: not admitted(rules, ".config/noodlebot/token") and not admitted(rules, ".config/noodlebot/oauth-token"))

# ---------------------------------------------------------------- compose (AC-7)
compose = safe(lambda: yload("container", "compose.yaml"))
svc = safe(lambda: list(compose["services"].values())[0])
named_vols = safe(lambda: set((compose.get("volumes") or {}).keys())) or set()


def volumes():
    out = []
    for v in svc.get("volumes") or []:
        if isinstance(v, dict):
            out.append((v.get("type"), str(v.get("source", "")), v.get("target"),
                        bool(v.get("read_only")) or v.get("read_only") == "true"))
        else:
            m = re.match(r"^(.*):(/[^:]*)(?::([A-Za-z,]+))?$", str(v))
            src_, tgt, opts = m.group(1), m.group(2), (m.group(3) or "")
            ro = "ro" in opts.split(",")
            typ = "volume" if src_ in named_vols or re.match(r"^[A-Za-z0-9_.-]+$", src_) and not src_.startswith(".") else "bind"
            out.append((typ, src_, tgt, ro))
    return out


def grace_seconds(v):
    if isinstance(v, (int, float)):
        return float(v)
    tot, ok = 0.0, False
    for n, u in re.findall(r"(\d+(?:\.\d+)?)(ms|h|m|s)", str(v)):
        tot += float(n) * {"h": 3600, "m": 60, "s": 1, "ms": 0.001}[u]
        ok = True
    if not ok:
        raise ValueError("duration %r" % (v,))
    return tot


chk("D06-AC-7 container/compose.yaml exists and parses", lambda: isinstance(compose, dict))
chk("D06-AC-7 compose has exactly one service", lambda: len(compose["services"]) == 1)
chk("D06-AC-7 service image is ghcr.io/<owner>/<name>:latest",
    lambda: re.match(r"^ghcr\.io/\S+/\S+:latest$", str(svc["image"])) is not None)
chk("D06-AC-7 a named volume (declared under volumes:) is mounted at /home/noodlebot",
    lambda: any(t == "/home/noodlebot" and s in named_vols and not s.startswith(("/", ".", "~"))
                for _, s, t, _ in volumes()))
chk("D06-AC-7 the config folder is bind-mounted read-only at /home/noodlebot/.config/noodlebot",
    lambda: any(t == "/home/noodlebot/.config/noodlebot" and ro and s not in named_vols and s != ""
                for _, s, t, ro in volumes()))
chk("D06-AC-7 service carries nested-podman settings (devices, security_opt or cap_add)",
    lambda: any(svc.get(k) for k in ("devices", "security_opt", "cap_add")))
chk("D06-AC-7 service is not privileged",
    lambda: str(svc.get("privileged", False)).lower() not in ("true", "yes", "1", "on") and svc is not None)
chk("D06-AC-7 no volume mounts a container-runtime socket",
    lambda: not any(re.search(r"\.sock\b|^/(var/)?run(/|$)|docker|podman|containerd", s) and not s in named_vols
                    for _, s, _, _ in volumes()) and svc is not None)
chk("D06-AC-7 restart: unless-stopped", lambda: svc["restart"] == "unless-stopped")
chk("D06-AC-7 publishes no port", lambda: svc is not None and not svc.get("ports"))
chk("D06-AC-7 stop_grace_period is longer than loops.sh stop's 300 s wait",
    lambda: grace_seconds(svc["stop_grace_period"]) > 300)

# ---------------------------------------------------------------- k8s (AC-8)
kdir = path("container", "k8s")
kfiles = safe(lambda: sorted(f for f in os.listdir(kdir) if f.endswith((".yaml", ".yml"))))
kust = safe(lambda: yload("container", "k8s", "kustomization.yaml"))
docs = []
for f in kfiles or []:
    if f in ("kustomization.yaml", "kustomization.yml"):
        continue
    d = safe(lambda: [x for x in yaml.safe_load_all(text("container", "k8s", f)) if x])
    docs += d or []
sts = [d for d in docs if d.get("kind") == "StatefulSet"]
pod = safe(lambda: sts[0]["spec"]["template"]["spec"])
ctrs = safe(lambda: (pod.get("containers") or []) + (pod.get("initContainers") or []))


def listed_ok():
    res = kust["resources"]
    others = [f for f in kfiles if f not in ("kustomization.yaml", "kustomization.yml")]
    missing = [r for r in res if not os.path.exists(path("container", "k8s", r))]
    unlisted = [f for f in others if f not in [os.path.normpath(r) for r in res]]
    return (len(res) > 0 and not missing and not unlisted, "missing %s unlisted %s" % (missing, unlisted))


def uid_ok():
    uid = cf_uid()
    if uid is None:
        return False, "no uid in the Containerfile"
    pc = (pod.get("securityContext") or {}).get("runAsUser")
    if pc is not None:
        return pc == uid, "runAsUser %r vs %r" % (pc, uid)
    return all((c.get("securityContext") or {}).get("runAsUser") == uid for c in pod["containers"]), "container runAsUser"


def hostpath_ok():
    for v in pod.get("volumes") or []:
        hp = (v.get("hostPath") or {}).get("path")
        if hp is not None and re.search(r"\.sock\b|^/(var/)?run(/|$)", hp):
            return False, hp
    return True, ""


def claim_mount():
    names = [c["metadata"]["name"] for c in sts[0]["spec"]["volumeClaimTemplates"]]
    return any(m["name"] in names and m["mountPath"] == "/home/noodlebot"
               for c in pod["containers"] for m in c.get("volumeMounts") or [])


def secret_mount():
    vols = [v for v in pod["volumes"] if (v.get("secret") or {}).get("secretName") == "noodlebot-config"]
    mounts = [m for c in pod["containers"] for m in c.get("volumeMounts") or []
              if m["mountPath"] == "/home/noodlebot/.config/noodlebot" and m["name"] in [v["name"] for v in vols]]
    return len(vols) == 1 and len(mounts) > 0 and all(m.get("readOnly") is True for m in mounts)


def secret_mode():
    s = [v for v in pod["volumes"] if (v.get("secret") or {}).get("secretName") == "noodlebot-config"][0]["secret"]
    if isinstance(s.get("defaultMode"), int):
        return s["defaultMode"] & 0o100 != 0, "defaultMode %o" % s["defaultMode"]
    items = s.get("items") or []
    return bool(items) and all(isinstance(i.get("mode"), int) and i["mode"] & 0o100 for i in items), "items modes"


chk("D06-AC-8 container/k8s/kustomization.yaml exists and parses", lambda: isinstance(kust, dict))
chk("D06-AC-8 kustomization resources lists every manifest in the folder, each listed file exists", listed_ok)
chk("D06-AC-8 manifests define a StatefulSet", lambda: len(sts) >= 1)
chk("D06-AC-8 StatefulSet has replicas: 1", lambda: sts[0]["spec"]["replicas"] == 1)
chk("D06-AC-8 pod runs as noodlebot's uid (the Containerfile's useradd -u)", uid_ok)
chk("D06-AC-8 no container is privileged",
    lambda: len(ctrs) > 0 and not any((c.get("securityContext") or {}).get("privileged") for c in ctrs)
    and not (pod.get("securityContext") or {}).get("privileged"))
chk("D06-AC-8 no hostPath volume is a socket", hostpath_ok)
chk("D06-AC-8 a volumeClaimTemplates claim is mounted at /home/noodlebot", claim_mount)
chk("D06-AC-8 Secret noodlebot-config is mounted read-only at /home/noodlebot/.config/noodlebot", secret_mount)
chk("D06-AC-8 the Secret volume has a mode with the owner execute bit", secret_mode)
chk("D06-AC-8 manifests have no Service", lambda: len(docs) > 0 and not any(d.get("kind") == "Service" for d in docs))
chk("D06-AC-8 manifests have no Secret data (no Secret with data/stringData, no secretGenerator)",
    lambda: len(docs) > 0 and not any(d.get("kind") == "Secret" and (d.get("data") or d.get("stringData")) for d in docs)
    and not kust.get("secretGenerator"))
chk("D06-AC-8 terminationGracePeriodSeconds is longer than loops.sh stop's 300 s wait",
    lambda: pod["terminationGracePeriodSeconds"] > 300)
chk("D06-AC-8 kustomization has an images: entry (the owner can name another image)",
    lambda: len(kust["images"]) > 0 and all("name" in i for i in kust["images"]))

# ---------------------------------------------------------------- workflow (AC-9)
wf_text = safe(lambda: text(".github", "workflows", "image.yml"))
wf = safe(lambda: yaml.safe_load(wf_text))
on = safe(lambda: wf["on"] if "on" in wf else wf[True])  # YAML 1.1 reads the key on: as True
jobs = safe(lambda: wf["jobs"]) or {}


def push_steps():
    """(job id, job, step) for each step that pushes an image."""
    out = []
    for jid, j in jobs.items():
        for s in j.get("steps") or []:
            run = str(s.get("run", ""))
            uses = str(s.get("uses", ""))
            if re.search(r"\b(docker|podman|buildah|skopeo)\b[^\n]*\bpush\b", run):
                out.append((jid, j, s))
            elif "build-push-action" in uses and str((s.get("with") or {}).get("push", "false")).strip().lower() != "false":
                out.append((jid, j, s))
    return out


def push_only_main():
    ps = push_steps()
    if not ps:
        return False, "no step pushes an image"
    branches = (on.get("push") or {}).get("branches") if isinstance(on.get("push"), dict) else None
    for jid, j, s in ps:
        cond = str(j.get("if", "")) + " " + str(s.get("if", ""))
        ev = re.search(r"github\.event_name\s*==\s*'push'", cond)
        main = re.search(r"refs/heads/main|github\.ref_name\s*==\s*'main'", cond) or branches == ["main"]
        if not (ev and main):
            return False, "job %s pushes without a push-to-main condition" % jid
    return True, ""


def push_job_text():
    return json.dumps([j for _, j, _ in push_steps()])


def perms_ok():
    p = wf["permissions"]
    if not isinstance(p, dict):
        return False, "workflow-level permissions must be a mapping"
    return all(v in ("read", "none") for v in p.values()) and set(p) <= {"contents"}, "perms %r" % p


def pkg_write_only_pusher():
    pushers = {jid for jid, _, _ in push_steps()}
    if not pushers:
        return False, "no pushing job"
    for jid, j in jobs.items():
        w = (j.get("permissions") or {}).get("packages") == "write" if isinstance(j.get("permissions"), dict) else False
        if w != (jid in pushers):
            return False, "job %s packages write=%s" % (jid, w)
    return True, ""


def secrets_ok():
    t = "\n".join(re.sub(r"(^|\s)#.*$", "", l) for l in wf_text.splitlines())
    names = set()
    for expr in re.findall(r"\$\{\{(.*?)\}\}", t, re.S):
        for m in re.finditer(r"\bsecrets\b(\.([A-Za-z0-9_]+)|\[|(?![.\w]))", expr):
            names.add(m.group(2) or "<whole secrets context>")
    if re.search(r"^\s*secrets:\s*inherit", t, re.M):
        names.add("<inherit>")
    return names <= {"GITHUB_TOKEN"}, "secrets %s" % sorted(names)


chk("D06-AC-9 .github/workflows/image.yml exists and parses", lambda: isinstance(wf, dict))
chk("D06-AC-9 pull_request trigger lists container/**, .containerignore and the workflow file",
    lambda: {"container/**", ".containerignore", ".github/workflows/image.yml"} <= set(on["pull_request"]["paths"]))
chk("D06-AC-9 push trigger is on main",
    lambda: "main" in on["push"]["branches"])
chk("D06-AC-9 an image is pushed, and only in a job or step conditioned on a push to main", push_only_main)
chk("D06-AC-9 pushes to ghcr.io/ plus the lowercased github.repository",
    lambda: re.search(r"ghcr\.io/", push_job_text() + wf_text) and re.search(r"github\.repository|GITHUB_REPOSITORY", wf_text)
    and re.search(r"GITHUB_REPOSITORY,,|\[:upper:\].{0,12}\[:lower:\]|toLower\(github\.repository\)|metadata-action", wf_text)
    and not re.search(r"tuckermclean", wf_text, re.I) and len(push_steps()) > 0)
chk("D06-AC-9 pushed image is tagged with the commit SHA and latest",
    lambda: re.search(r"github\.sha|GITHUB_SHA", wf_text) and re.search(r"\blatest\b", push_job_text() + wf_text)
    and len(push_steps()) > 0)
chk("D06-AC-9 workflow-level permissions are at most contents: read", perms_ok)
chk("D06-AC-9 only the pushing job has packages: write", pkg_write_only_pusher)
chk("D06-AC-9 the only secret referenced is GITHUB_TOKEN", secrets_ok)

def checkout_steps():
    return [s for j in jobs.values() for s in (j.get("steps") or [])
            if str(s.get("uses", "")).startswith("actions/checkout")]

def checkouts_keep_no_creds():
    cs = checkout_steps()
    return len(cs) > 0 and all(
        ((s.get("with") or {}).get("persist-credentials", True) in (False, "false")) for s in cs)

chk("D06-AC-2 image.yml checkout steps keep persist-credentials: false (no CI token in /opt/noodlebot/.git/config)",
    checkouts_keep_no_creds)

# ---------------------------------------------------------------- README, SPEC, AGENTS (AC-10)


def section(src, head_rx, level_of=lambda l: len(l) - len(l.lstrip("#"))):
    lines, start, lvl = src.splitlines(), None, 0
    for i, l in enumerate(lines):
        if re.match(r"^#{1,6}\s", l) and re.search(head_rx, l):
            start, lvl = i, level_of(l)
            break
    if start is None:
        raise ValueError("no heading matching %s" % head_rx)
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r"^#{1,6}\s", lines[j]) and level_of(lines[j]) <= lvl:
            end = j
            break
    return "\n".join(lines[start:end])


readme = safe(lambda: section(text("README.md"), r"ontainer"))


def derived_settings():
    out = []
    for d in svc.get("devices") or []:
        out.append(("device", str(d).split(":")[0]))
    for s in svc.get("security_opt") or []:
        out.append(("security_opt", str(s)))
    for c in svc.get("cap_add") or []:
        out.append(("cap_add", str(c)))
    scs = [pod.get("securityContext") or {}] + [c.get("securityContext") or {} for c in ctrs]
    for sc in scs:
        for c in (sc.get("capabilities") or {}).get("add") or []:
            out.append(("k8s capability", str(c)))
        for k in ("seccompProfile", "appArmorProfile"):
            if k in sc:
                out.append(("k8s " + k, k))
                if sc[k].get("localhostProfile"):
                    out.append(("k8s " + k + " profile", sc[k]["localhostProfile"]))
        if "procMount" in sc:
            out.append(("k8s procMount", "procMount"))
    if "hostUsers" in pod:
        out.append(("k8s hostUsers", "hostUsers"))
    for v in pod.get("volumes") or []:
        hp = (v.get("hostPath") or {}).get("path", "")
        if hp.startswith("/dev"):
            out.append(("k8s hostPath device", hp))
    seen, res = set(), []
    for k, v in out:
        if (k, v) not in seen:
            seen.add((k, v))
            res.append((k, v))
    return res


chk("D06-AC-10 README has a container section (a heading containing 'ontainer')", lambda: readme is not None)
for what in ("container/compose.yaml", "container/k8s/", "noodlebot-config", "gitconfig"):
    chk("D06-AC-10 README container section names %s" % what, lambda what=what: what in readme)
try:
    settings = derived_settings()
except Exception:
    settings = []
if not settings:
    chk("D06-AC-10 nested-podman settings of the compose file and the manifests are found to check the README against",
        lambda: False)
for kind, val in settings:
    chk("D06-AC-10 README container section names the %s setting %s" % (kind, val), lambda val=val: val in readme)
chk("D06-AC-10 README container section says one runtime root takes one replica",
    lambda: re.search(r"(?i)\b(one|a single|exactly one|1)\s+replica\b|replicas:\s*1\b", readme))
chk("D06-AC-10 SPEC.md section 2 names container/",
    lambda: "container/" in section(text("SPEC.md"), r"^## 2\."))
chk("D06-AC-10 AGENTS.md 'Where things are' names container/",
    lambda: "container/" in section(text("AGENTS.md"), r"^## Where things are"))

print("DONE")
sys.exit(1 if nfail else 0)
EOPY

python3 -I "$tmp/check.py" "$src" >"$tmp/out" 2>"$tmp/err"
rc=$?
cat "$tmp/out"
n=$(grep -c '^FAIL' "$tmp/out")
if ! grep -q '^DONE$' "$tmp/out"; then
	echo "FAIL: container checks did not run to the end (rc=$rc)"; head -5 "$tmp/err"
	n=$((n + 1))
fi
fails=$n
[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all container checks passed"
