"""Engine."""
# The engine steps a value and keeps it in range.
from core.util import clamp


def run(x):
    y = x + 1
    y = clamp(y)
    return y


def stop():
    return None
