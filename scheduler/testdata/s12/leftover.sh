#!/bin/sh
# What the fake claude leaves behind: ignores SIGHUP and SIGTERM, keeps the inherited output open, never ends by itself
# (only SIGKILL ends it). $1: the file that gets its pid.
trap '' HUP TERM
sed 's/.*) //' "/proc/$$/stat" | cut -d" " -f3 >"$1.pg"
echo "$$" >"$1.tmp" && mv "$1.tmp" "$1"
while :; do sleep 1; done
