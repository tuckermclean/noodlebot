#!/bin/sh
# Container entrypoint (D06): run as the unprivileged user, never root.
#   1. refuses (one line on stderr, non-zero, nothing started) when run as root or when ~/.config/noodlebot
#      lacks repos, token or oauth-token;
#   2. clones the image copy ($NOODLEBOT_IMAGE_COPY, default /opt/noodlebot) to ~/gitrepos/noodlebot when absent,
#      with origin set to the image copy's origin URL; an existing checkout is left alone;
#   3. includes ~/.config/noodlebot/gitconfig from ~/.gitconfig when that file exists (once);
#   4. runs the checkout's scheduler/loops.sh start and stays in the foreground while the tmux server lives;
#      with an empty repos list no tmux session starts, so it then stays up until SIGTERM;
#   5. on SIGTERM or SIGINT runs loops.sh stop once and exits 0.
set -u
image=${NOODLEBOT_IMAGE_COPY:-/opt/noodlebot}
cfg=$HOME/.config/noodlebot
co=$HOME/gitrepos/noodlebot

die() { echo "entrypoint: $*" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die "refusing to run as root; run as an unprivileged user"
[ -d "$cfg" ] || die "config folder $cfg is missing"
for f in repos token oauth-token; do
	[ -e "$cfg/$f" ] || die "$cfg/$f is missing"
done

if [ ! -e "$co/.git" ]; then
	mkdir -p "$HOME/gitrepos" || die "cannot create $HOME/gitrepos"
	git clone -q "$image" "$co" >/dev/null 2>&1 || die "cannot clone $image to $co"
	url=$(git -C "$image" remote get-url origin 2>/dev/null) || url=
	[ -z "$url" ] || git -C "$co" remote set-url origin "$url"
fi

if [ -f "$cfg/gitconfig" ]; then
	git config --global --get-all include.path 2>/dev/null | grep -Fxq "$cfg/gitconfig" ||
		git config --global --add include.path "$cfg/gitconfig"
fi

stopped=0
on_stop() {
	trap '' TERM INT
	if [ "$stopped" = 0 ]; then
		stopped=1
		"$co/scheduler/loops.sh" stop >/dev/null 2>&1
	fi
	exit 0
}
trap on_stop TERM INT

tmux_up() { tmux has-session >/dev/null 2>&1 || tmux ls >/dev/null 2>&1; }

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
