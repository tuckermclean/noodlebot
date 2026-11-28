"""Part of the GitHub backend (forges/github.py): `ci artifact`, a run's named artifact unpacked into a folder.

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs it, and the
functions named in _register at the end become methods of its Backend. Everything github.py defines is in scope here.
"""
import shutil
import stat
import subprocess
import tempfile
import zipfile
import zlib

ARTIFACT_TIMEOUT = 300  # the archive's download (a log read's 60 s is too short for a large one)


def _artifact_entries(zf, name, run):
    """[(zip entry, parts of its relative path or None for a folder)] of an archive whose every entry is a plain file or
    folder below the target; any other entry (absolute, '..', a link or another special file) refuses the whole archive."""
    out = []
    for info in zf.infolist():
        n = info.filename
        slashed = n.replace("\\", "/")
        why = None
        if not n or "\0" in n:
            why = "an empty or odd name"
        elif slashed.startswith("/") or (len(n) > 1 and n[1] == ":"):
            why = "an absolute path"
        elif ".." in slashed.split("/"):
            why = "a '..' component"
        else:
            mode = info.external_attr >> 16
            if mode and stat.S_IFMT(mode) not in (stat.S_IFREG, stat.S_IFDIR):
                why = "a link or another special file"
        if why:
            raise forge.ForgeError("the artifact %r of run %d is refused, nothing was written: the entry %r is %s" % (name, run, n, why))
        parts = [p for p in slashed.split("/") if p and p != "."]
        if parts:
            out.append((info, None if info.is_dir() else parts, parts))
    return out


def ci_artifact(self, run, name, dir):
    run = int(run)
    if os.path.isdir(dir) and os.listdir(dir):
        raise forge.ForgeError("ci artifact: %s exists and is not empty, the artifact %r of run %d was not downloaded" % (dir, name, run))
    where = "the artifact %r of run %d" % (name, run)
    try:
        listing = self._api("GET", self._r("/actions/runs/%d/artifacts" % run), None, ["-f", "name=" + name, "-f", "per_page=100"])
    except forge.ForgeError as e:
        if e.status == 403:
            raise forge.CapabilityOff("github", "ci_artifact")
        if e.status == 404:
            raise forge.ForgeError("%s was not found: the run has no such artifact (%s)" % (where, e))
        raise
    arts = listing.get("artifacts") if isinstance(listing, dict) else None
    if not isinstance(arts, list):
        raise forge.ForgeError("the answer for the artifacts of run %d does not parse: no artifacts list" % run)
    arts = [a for a in arts if isinstance(a, dict) and a.get("name") == name and isinstance(a.get("id"), int)]
    if not arts:
        raise forge.ForgeError("%s was not found: the run has no artifact of that name" % where)
    live = [a for a in arts if not a.get("expired")]
    if not live:
        raise forge.ForgeError("%s has expired" % where)
    art = live[0]
    # the archive: gh's stdout goes straight to a temporary file (bytes as served; gh follows the redirect without the token)
    env, tok = self._env()
    path = self._r("/actions/artifacts/%d/zip" % art["id"])
    fd, tmp = tempfile.mkstemp(prefix="artifact-", suffix=".zip")
    created = None
    try:
        try:
            with os.fdopen(fd, "wb") as fh:
                r = subprocess.run(["gh", "api", "-X", "GET", path], stdout=fh, stderr=subprocess.PIPE, stdin=subprocess.DEVNULL,
                                   timeout=ARTIFACT_TIMEOUT, env=env)
        except (OSError, subprocess.SubprocessError) as e:
            raise forge.ForgeError("gh api GET actions/artifacts zip failed: %s" % type(e).__name__)
        if r.returncode != 0:
            full = self._scrub(r.stderr.decode("utf-8", errors="replace"), tok)
            m = re.findall(r"\bHTTP (\d{3})\b", full)
            status = int(m[-1]) if m else None
            if status == 403:
                raise forge.CapabilityOff("github", "ci_artifact")
            if status == 410:
                raise forge.ForgeError("%s has expired" % where)
            raise forge.ForgeError("gh api GET actions/artifacts zip failed (exit %d): %s" % (r.returncode, full[:300]), status)
        try:
            zf = zipfile.ZipFile(tmp)
        except (OSError, zipfile.BadZipFile) as e:
            raise forge.ForgeError("%s: the archive is not a zip file (%s)" % (where, type(e).__name__))
        with zf:
            entries = _artifact_entries(zf, name, run)
            top = os.path.abspath(dir)   # the first folder the call has to create
            while not os.path.exists(os.path.dirname(top)) and os.path.dirname(top) != top:
                top = os.path.dirname(top)
            created = None if os.path.exists(dir) else top
            files = []
            try:
                os.makedirs(dir, exist_ok=True)
                for info, parts, rel in entries:
                    target = os.path.join(dir, *rel)
                    if parts is None:
                        os.makedirs(target, exist_ok=True)
                        continue
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    with zf.open(info) as src, open(target, "xb") as dst:
                        shutil.copyfileobj(src, dst)
                    files.append("/".join(parts))
            except (OSError, zipfile.BadZipFile, zlib.error) as e:
                if created:
                    shutil.rmtree(created, ignore_errors=True)
                else:
                    for n in os.listdir(dir):
                        p = os.path.join(dir, n)
                        shutil.rmtree(p, ignore_errors=True) if os.path.isdir(p) and not os.path.islink(p) else os.path.lexists(p) and os.remove(p)
                raise forge.ForgeError("%s could not be unpacked into %s: %s" % (where, dir, type(e).__name__))
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    return {"id": art["id"], "name": name, "dir": dir, "files": sorted(files)}


_register(ci_artifact)
