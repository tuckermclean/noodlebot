"""Part of the GitHub backend (forges/github.py): `ci artifact`, a run's named artifact unpacked into a folder.

Not a module of its own: github.py compiles this file into its own namespace the first time a call needs it, and the
functions named in _register at the end become methods of its Backend. Everything github.py defines is in scope here.
"""
import shutil
import stat
import tempfile
import zipfile

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
            if stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
                why = "a link or another special file"
        if why:
            raise forge.ForgeError("the artifact %r of run %d is refused, nothing was written: the entry %r is %s" % (name, run, n, why))
        parts = [p for p in slashed.split("/") if p and p != "."]
        if parts:
            out.append((info, None if info.is_dir() else parts, parts))
    return out


def _artifact_mkdir(path, made, link_ok):
    """Create one folder; record it in made only when this call's own mkdir made it. An existing folder is fine and not
    recorded (below the --dir, a link to one is not); anything else existing there is a failure."""
    try:
        os.mkdir(path)
    except FileExistsError:
        if os.path.isdir(path) and (link_ok or not os.path.islink(path)):
            return
        raise
    made.append((path, True))


def _artifact_mkdirs(dir, rel, made, top):
    """Create the --dir (top: with its missing ancestors) or the folders rel below it, one level at a time."""
    if top:
        chain = []
        d = dir
        while not os.path.isdir(d):
            chain.append(d)
            up = os.path.dirname(d)
            if up == d:
                break
            d = up
        for d in reversed(chain):
            _artifact_mkdir(d, made, True)
        return
    d = dir
    for p in rel:
        d = os.path.join(d, p)
        _artifact_mkdir(d, made, False)


def ci_artifact(self, run, name, dir):
    run = int(run)
    given = dir
    dir = os.path.realpath(dir)   # resolved once, before any check, links followed as the OS follows them
    if os.path.exists(dir) and not os.path.isdir(dir):
        raise forge.ForgeError("ci artifact: %s exists and is not a folder, the artifact %r of run %d was not downloaded" % (dir, name, run))
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
    path = self._r("/actions/artifacts/%d/zip" % art["id"])
    fd, tmp = tempfile.mkstemp(prefix="artifact-", suffix=".zip")
    files = []
    try:
        try:
            with os.fdopen(fd, "wb") as fh:
                self._gh_to_file(["api", "-X", "GET", path], fh, "gh api GET actions/artifacts zip", ARTIFACT_TIMEOUT)
        except forge.ForgeError as e:
            if e.status == 403:
                raise forge.CapabilityOff("github", "ci_artifact")
            if e.status == 410:
                raise forge.ForgeError("%s has expired" % where)
            raise
        try:
            zf = zipfile.ZipFile(tmp)
        except (OSError, zipfile.BadZipFile) as e:
            raise forge.ForgeError("%s: the archive is not a zip file (%s)" % (where, type(e).__name__))
        with zf:
            entries = _artifact_entries(zf, name, run)
            made = []   # [(path, is a folder)] this call itself created, in order: the only paths a failure removes
            try:
                _artifact_mkdirs(dir, [], made, True)
                for info, parts, rel in entries:
                    target = os.path.join(dir, *rel)
                    if parts is None:
                        _artifact_mkdirs(dir, rel, made, False)
                        continue
                    _artifact_mkdirs(dir, rel[:-1], made, False)
                    with zf.open(info) as src, open(target, "xb") as dst:
                        made.append((target, False))   # recorded only once this call's own exclusive create succeeded
                        shutil.copyfileobj(src, dst)
                    files.append("/".join(parts))
            except Exception as e:
                for p, folder in reversed(made):
                    try:
                        if folder:
                            os.rmdir(p)    # a folder now holding something of another process's stays
                        else:
                            os.remove(p)   # a link in its place is removed, never followed
                    except OSError:
                        pass
                why = " ".join(str(e).split())[:200]
                raise forge.ForgeError("%s could not be unpacked into %s: %s%s" % (where, dir, type(e).__name__, ": " + why if why else ""))
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass
    return {"id": art["id"], "name": name, "dir": given, "files": sorted(files)}


_register(ci_artifact)
