# materialize.py <src> <dst>: copies the fixture tree, replacing each JSON string "@now" or "@now+N"/"@now-N" by the
# integer epoch now+N (so ages in the canned responses are the same whenever the test runs). Other bytes are kept.
import os, re, sys, time
src, dst = sys.argv[1:3]
now = int(time.time())
for r, _, fs in os.walk(src):
    for f in fs:
        s = os.path.join(r, f)
        d = os.path.join(dst, os.path.relpath(s, src))
        os.makedirs(os.path.dirname(d), exist_ok=True)
        with open(s, "rb") as i, open(d, "wb") as o:
            o.write(re.sub(rb'"@now([+-][0-9]+)?"', lambda m: str(now + int(m.group(1) or 0)).encode(), i.read()))
