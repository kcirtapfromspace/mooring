# Mooring virtual screen, version 1. While this runs, the Linux desktop's
# workspaces show on a virtual Hyprland output sized to the viewing Mac, and
# wayvnc captures that output. It holds while Mooring sends a heartbeat on
# standard input. When the heartbeat stops (Mooring ended the session, quit,
# crashed, or the network dropped), everything is put back: wayvnc returns to
# the screen it was capturing, the virtual output is removed so its
# workspaces return, and the first moved workspace is focused again.
#
# Arguments: WIDTH HEIGHT SCALE, as pixels and 1 or 2; checked again here.
# Mooring sends this fixed script; nothing from a saved connection is
# inserted into it.
set -f
PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C.UTF-8
W=$1 H=$2 S=$3
NAME=MOORING-1
say() { printf 'mooring-screen %s\n' "$*"; }
fail() { say "error $*"; exit 3; }
case "$W" in ''|*[!0-9]*) fail bad-size ;; esac
case "$H" in ''|*[!0-9]*) fail bad-size ;; esac
case "$S" in 1|2) ;; *) fail bad-scale ;; esac
T=
command -v timeout >/dev/null 2>&1 && T="timeout -k 1 5"
me=$(id -u)
command -v loginctl >/dev/null 2>&1 || fail no-logind
sid=
for s in $($T loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  props=$($T loginctl show-session "$s" -p Type -p Active 2>/dev/null)
  case "$props" in *Type=wayland*) ;; *) continue ;; esac
  [ -z "$sid" ] && sid=$s
  case "$props" in *Active=yes*) sid=$s; break ;; esac
done
[ -n "$sid" ] || fail no-session
uid=$($T loginctl show-session "$sid" -p User --value 2>/dev/null)
user=$($T loginctl show-session "$sid" -p Name --value 2>/dev/null)
if [ "$me" != "$uid" ] && { [ "$me" != 0 ] || ! command -v runuser >/dev/null 2>&1; }; then
  fail not-readable
fi
runtime=${MOORING_RUNTIME_ROOT:-/run/user}/$uid
as_user() {
  if [ "$me" = "$uid" ]; then
    env XDG_RUNTIME_DIR="$runtime" $T "$@"
  else
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" $T "$@"
  fi
}
sig=
for dir in $(ls -t "$runtime/hypr" 2>/dev/null); do
  [ -S "$runtime/hypr/$dir/.socket.sock" ] && { sig=$dir; break; }
done
[ -n "$sig" ] && command -v hyprctl >/dev/null 2>&1 || fail no-hyprland
command -v wayvncctl >/dev/null 2>&1 || fail no-wayvncctl
hypr() { as_user env HYPRLAND_INSTANCE_SIGNATURE="$sig" hyprctl "$@"; }
vnc() { as_user wayvncctl "$@"; }
monitors() { hypr monitors all 2>/dev/null | awk '/^Monitor /{print $2}'; }
size_of() { hypr monitors all 2>/dev/null | awk -v m="$1" '/^Monitor /{on = ($2 == m); next} on && /^[[:space:]]*[0-9]+x[0-9]+@/{split($1, a, "@"); print a[1]; exit}'; }
# "workspace 1 (1) on monitor eDP-1:" (older Hyprland: "workspace ID 1 ...").
workspaces_on() { hypr workspaces 2>/dev/null | awk -v m="$1" '/^workspace /{id = ($2 == "ID") ? $3 : $2; for (i = 1; i <= NF; i++) if ($i == "monitor") {n = $(i + 1); sub(":", "", n); if (n == m) print id}}'; }
pidfile=$runtime/mooring-virtual-screen.pid

if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  fail in-use
fi
# A virtual screen left by a session that could not clean up.
if monitors | grep -qx "$NAME"; then
  hypr output remove "$NAME" >/dev/null 2>&1
  say stale-removed
fi
previous=$(vnc output-list 2>/dev/null | awk '$1 == "*" {sub(":", "", $2); print $2; exit}')
[ -n "$previous" ] || previous=$(monitors | head -n 1)
moved=
restored=
restore() {
  [ -n "$restored" ] && return
  restored=1
  [ -n "$previous" ] && vnc output-set "$previous" >/dev/null 2>&1
  hypr output remove "$NAME" >/dev/null 2>&1
  first=${moved%%,*}
  [ -n "$first" ] && hypr dispatch "hl.dsp.focus({ workspace = \"$first\" })" >/dev/null 2>&1
  rm -f "$pidfile"
  say restored
}
trap restore EXIT
trap 'exit 0' HUP INT TERM

hypr output create headless "$NAME" >/dev/null 2>&1 || fail create-failed
hypr eval "hl.monitor({ output = \"$NAME\", mode = \"${W}x${H}@60\", position = \"auto\", scale = $S })" >/dev/null 2>&1
tries=0
while [ "$(size_of "$NAME")" != "${W}x${H}" ]; do
  tries=$((tries + 1))
  [ "$tries" -gt 30 ] && fail mode-not-applied
  sleep 0.1
done
for ws in $(workspaces_on "$previous"); do
  hypr dispatch "hl.dsp.focus({ workspace = \"$ws\" })" >/dev/null 2>&1
  hypr dispatch "hl.dsp.workspace.move({ monitor = \"$NAME\" })" >/dev/null 2>&1
  moved="$moved,$ws"
done
moved=${moved#,}
vnc output-set "$NAME" >/dev/null 2>&1 || fail capture-failed
echo $$ | as_user tee "$pidfile" >/dev/null
say "ready ${W}x${H} $NAME workspaces=${moved:-none}"
# Hold while heartbeats arrive. Each read waits at most 20 seconds; end of
# input or a missed heartbeat ends the hold.
if [ -n "$T" ]; then
  while :; do
    got=$(timeout 20 dd bs=1 count=1 2>/dev/null | wc -c)
    [ $((got + 0)) -eq 1 ] || break
  done
else
  cat >/dev/null
fi
