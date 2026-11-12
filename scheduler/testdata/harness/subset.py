"""subset.py <expected> <actual>: both JSON-lines files. Exit 0 when they have the same number of lines and every
key of each expected object is in the actual one with an equal value (nested objects likewise, anything else
equal); else print each difference and exit 1. Extra fields in the actual events are allowed."""
import json
import sys


def sub(e, a, path, bad):
    if isinstance(e, dict):
        if not isinstance(a, dict):
            bad.append("%s: expected an object, got %r" % (path, a))
            return
        for k, v in e.items():
            if k not in a:
                bad.append("%s.%s: missing (expected %r)" % (path, k, v))
            else:
                sub(v, a[k], path + "." + k, bad)
    elif isinstance(e, bool) or isinstance(a, bool):
        if e is not a:
            bad.append("%s: expected %r, got %r" % (path, e, a))
    elif e != a:
        bad.append("%s: expected %r, got %r" % (path, e, a))


def load(p):
    with open(p) as f:
        return [json.loads(l) for l in f if l.strip()]


try:
    exp, act = load(sys.argv[1]), load(sys.argv[2])
except (OSError, ValueError) as x:
    print("cannot read: %s" % x)
    sys.exit(1)
bad = []
if len(exp) != len(act):
    bad.append("%d events expected, %d found" % (len(exp), len(act)))
for i, (e, a) in enumerate(zip(exp, act)):
    sub(e, a, "event %d" % (i + 1), bad)
print("\n".join(bad[:12]))
sys.exit(1 if bad else 0)
