#!/bin/sh
# A slow fake `claude` (install it as "claude" on a temporary PATH): prints its scripted stream-json in parts, each only
# once the test says so, so that a reader can look at the session while it is running.
#   FAKE_SLOW_DIR    folder for the hand-shake (required): "started" is created when the process starts; before part i
#                    (1, 2, ...) it waits for the file "go-<i>", then prints the part and creates "done-<i>"
#   FAKE_SLOW_PARTS  the files of the parts, space separated (they hold raw stream-json lines)
# It exits 0 after the last part. The wait is a condition (a file), polled every 50 ms, for at most 20 s.
dir=${FAKE_SLOW_DIR:?FAKE_SLOW_DIR}
mkdir -p "$dir"
: >"$dir/started"
i=0
for p in $FAKE_SLOW_PARTS; do
	i=$((i + 1))
	n=0
	while [ ! -e "$dir/go-$i" ] && [ $n -lt 400 ]; do n=$((n + 1)); sleep 0.05; done
	cat "$p"
	: >"$dir/done-$i"
done
exit 0
