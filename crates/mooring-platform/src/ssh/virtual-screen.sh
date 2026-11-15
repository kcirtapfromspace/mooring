# Mooring virtual screen, version 1. While this runs, the Linux desktop's
# workspaces show on a virtual Hyprland output sized to the viewing Mac, and
# wayvnc captures that output. An X11 desktop with no monitor in use is
# resized instead (see x11_screen below). It holds while Mooring sends a heartbeat on
# standard input. Hyprland's pointer is hidden meanwhile: the virtual output
# has no hardware cursor plane, so Hyprland would draw it into every captured
# frame, a frame behind the Mac's own pointer, which the viewer shows instead.
# When the heartbeat stops (Mooring ended the session, quit, crashed, or the
# network dropped), everything is put back: wayvnc returns to the screen it
# was capturing, the pointer shows again, the virtual output is removed so its
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
  case "$props" in *Type=wayland*|*Type=x11*) ;; *) continue ;; esac
  [ -z "$sid" ] && sid=$s
  case "$props" in *Active=yes*) sid=$s; break ;; esac
done
[ -n "$sid" ] || fail no-session
stype=$($T loginctl show-session "$sid" -p Type --value 2>/dev/null)
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
pidfile=$runtime/mooring-virtual-screen.pid
# Hold while heartbeats arrive. Each read waits at most 20 seconds; end of
# input or a missed heartbeat ends the hold.
hold() {
  if [ -n "$T" ]; then
    while :; do
      got=$(timeout 20 dd bs=1 count=1 2>/dev/null | wc -c)
      [ $((got + 0)) -eq 1 ] || break
    done
  else
    cat >/dev/null
  fi
}

# An X11 desktop, such as Unity on a headless Jetson behind x11vnc: its screen
# is resized with xrandr to the Mac's picture area in points (WIDTH/SCALE by
# HEIGHT/SCALE), so its interface is drawn at the Mac's size and the server
# has a quarter of the pixels to send to a Retina Mac. x11vnc's -xrandr resize
# sends the new size to the viewer. The old size is saved before the resize
# and comes back when the heartbeat stops; a size left by a session that
# could not restore it is put back first. A screen that a monitor shows is
# left alone: xrandr can't shrink it below the monitor, and a larger one would
# pan. No root is needed, only the desktop user's own X display.
x11_screen() {
  envs=
  command -v systemctl >/dev/null 2>&1 && envs=$(as_user systemctl --user show-environment 2>/dev/null)
  value() { printf '%s\n' "$envs" | sed -n "s/^$1=//p" | head -n 1; }
  dpy=$(value DISPLAY) xauth=$(value XAUTHORITY)
  [ -n "$dpy" ] || dpy=$($T loginctl show-session "$sid" -p Display --value 2>/dev/null)
  if [ -z "$dpy" ] && [ "$(ls /tmp/.X11-unix 2>/dev/null | wc -l)" -eq 1 ]; then
    dpy=:$(ls /tmp/.X11-unix | sed -n 's/^X\([0-9]*\)$/\1/p')
  fi
  if [ -z "$xauth" ]; then
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    for file in "$runtime/gdm/Xauthority" "$home/.Xauthority"; do
      [ -f "$file" ] && { xauth=$file; break; }
    done
  fi
  [ -n "$dpy" ] || fail no-display
  command -v xrandr >/dev/null 2>&1 || fail no-xrandr
  xr() { as_user env DISPLAY="$dpy" XAUTHORITY="$xauth" xrandr "$@"; }
  screen_line() { xr --current 2>/dev/null | sed -n '/^Screen [0-9]*:/{p;q;}'; }
  size_now() { screen_line | sed -n 's/.* current \([0-9]*\) x \([0-9]*\),.*/\1x\2/p'; }
  sizefile=$runtime/mooring-x11-screen.size
  if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
    fail in-use
  fi
  current=$(xr --current 2>/dev/null) || fail no-display
  in_use=$(printf '%s\n' "$current" | grep -c '^[^ ]* connected .*[0-9]x[0-9]*+[0-9]*+[0-9]')
  [ "$in_use" -eq 0 ] || fail monitor-in-use
  if [ -f "$sizefile" ]; then
    stale=$(sed -n '1{/^[0-9][0-9]*x[0-9][0-9]*$/p;}' "$sizefile")
    [ -n "$stale" ] && xr --fb "$stale" >/dev/null 2>&1
    rm -f "$sizefile"
    say stale-removed
  fi
  previous=$(size_now)
  [ -n "$previous" ] || fail no-display
  w=$((W / S)) h=$((H / S))
  maxw=$(screen_line | sed -n 's/.* maximum \([0-9]*\) x \([0-9]*\).*/\1/p')
  maxh=$(screen_line | sed -n 's/.* maximum \([0-9]*\) x \([0-9]*\).*/\2/p')
  if [ -n "$maxw" ] && [ -n "$maxh" ] && { [ "$w" -gt "$maxw" ] || [ "$h" -gt "$maxh" ]; }; then
    fail too-large
  fi
  restored=
  restore() {
    [ -n "$restored" ] && return
    restored=1
    xr --fb "$previous" >/dev/null 2>&1
    rm -f "$sizefile" "$pidfile"
    say restored
  }
  # Saved first, so an interrupted resize is still undone.
  echo "$previous" | as_user tee "$sizefile" >/dev/null
  trap restore EXIT
  trap 'exit 0' HUP INT TERM
  xr --fb "${w}x${h}" >/dev/null 2>&1 || fail mode-not-applied
  tries=0
  while [ "$(size_now)" != "${w}x${h}" ]; do
    tries=$((tries + 1))
    [ "$tries" -gt 30 ] && fail mode-not-applied
    sleep 0.1
  done
  echo $$ | as_user tee "$pidfile" >/dev/null
  say "ready ${w}x${h} X11 kind=x11 previous=$previous"
  hold
  exit 0
}
[ "$stype" = x11 ] && x11_screen

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
# Present while this script has Hyprland's pointer hidden.
cursorfile=$runtime/mooring-virtual-screen.cursor
show_cursor() {
  [ -f "$cursorfile" ] || return 0
  hypr eval 'hl.config({ cursor = { invisible = false } })' >/dev/null 2>&1
  rm -f "$cursorfile"
}

if [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
  fail in-use
fi
# A virtual screen or hidden pointer left by a session that could not clean up.
show_cursor
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
  show_cursor
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
# Only a pointer that is showing is hidden, and so shown again later. The
# file is written first, so an interrupted hide is still undone.
case "$(hypr -j getoption cursor:invisible 2>/dev/null | tr -d ' \n')" in
  *'"bool":false'*|*'"int":0'*)
    echo hidden | as_user tee "$cursorfile" >/dev/null
    hypr eval 'hl.config({ cursor = { invisible = true } })' >/dev/null 2>&1 ;;
esac
echo $$ | as_user tee "$pidfile" >/dev/null
say "ready ${W}x${H} $NAME workspaces=${moved:-none} kind=hyprland"
hold
