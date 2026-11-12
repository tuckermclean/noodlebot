#!/bin/sh
# Container entrypoint (D06): run as the unprivileged user, never root.
#   1. refuses (one line on stderr, non-zero, nothing started) when run as root or when ~/.config/noodlebot
#      lacks repos, token or oauth-token;
#   2. clones the image copy ($NOODLEBOT_IMAGE_COPY, default /opt/noodlebot) to ~/gitrepos/noodlebot when absent,
#      with origin set to the image copy's origin URL (read from its .git/config, as the image is root-owned;
#      refuses when there is none); cloned beside it and renamed into place, so a start sees a whole checkout
#      or none; an existing checkout is left alone;
#   3. includes ~/.config/noodlebot/gitconfig from ~/.gitconfig when that file exists (once);
#   4. runs the checkout's scheduler/loops.sh start and stays in the foreground while the tmux server lives;
#      with an empty repos list no tmux session starts, so it then stays up until SIGTERM;
#   5. on SIGTERM or SIGINT (trapped from the start) runs loops.sh stop once and exits 0; before loops.sh
#      start ran it only abandons a running clone and exits 0.
set -u
image=${NOODLEBOT_IMAGE_COPY:-/opt/noodlebot}
cfg=$HOME/.config/noodlebot
co=$HOME/gitrepos/noodlebot

stopped=0 started=0 cpid= tmp=
on_stop() {
	trap '' TERM INT
	if [ -n "$cpid" ]; then
		kill "$cpid" 2>/dev/null
		wait "$cpid" 2>/dev/null
		[ -z "$tmp" ] || rm -rf "$tmp"
	fi
	if [ "$stopped" = 0 ] && [ "$started" = 1 ]; then
		stopped=1
		"$co/scheduler/loops.sh" stop >/dev/null 2>&1
	fi
	exit 0
}
trap on_stop TERM INT

die() { echo "entrypoint: $*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "refusing to run as root; run as an unprivileged user"
[ -d "$cfg" ] || die "config folder $cfg is missing"
for f in repos token oauth-token; do
	[ -e "$cfg/$f" ] || die "$cfg/$f is missing"
done

if [ ! -e "$co/.git" ]; then
	mkdir -p "$HOME/gitrepos" || die "cannot create $HOME/gitrepos"
	# read the URL from the file: the image copy is owned by root, so git's ownership check would refuse
	url=$(git config --file "$image/.git/config" --get remote.origin.url 2>/dev/null) || url=
	[ -n "$url" ] || die "cannot read the origin URL of $image"
	tmp=$co.part
	rm -rf "$tmp"
	git -c safe.directory="$image" clone -q "$image" "$tmp" >/dev/null 2>&1 &
	cpid=$!
	wait "$cpid" || { rm -rf "$tmp"; die "cannot clone $image to $co"; }
	cpid=
	git -C "$tmp" remote set-url origin "$url" || { rm -rf "$tmp"; die "cannot set origin of $co"; }
	rm -rf "$co"
	mv "$tmp" "$co" || { rm -rf "$tmp"; die "cannot move the clone to $co"; }
fi

if [ -f "$cfg/gitconfig" ]; then
	git config --global --get-all include.path 2>/dev/null | grep -Fxq "$cfg/gitconfig" ||
		git config --global --add include.path "$cfg/gitconfig"
fi

tmux_up() { tmux has-session >/dev/null 2>&1 || tmux ls >/dev/null 2>&1; }

started=1
"$co/scheduler/loops.sh" start || echo "entrypoint: loops.sh start failed" >&2
if tmux_up; then
	while tmux_up; do
		sleep 5 &
		wait $!
	done
	echo "entrypoint: the tmux server is gone" >&2
	exit 1
fi
# no tmux server (empty repos list): stay up so `loops.sh status` can answer, until SIGTERM
while :; do
	sleep 5 &
	wait $!
done
