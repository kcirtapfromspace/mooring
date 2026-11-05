# Mooring desktop probe, version 1. Read-only: it reports whether the active
# graphical session is locked and whether its display is on, and changes
# nothing. Mooring sends this fixed script to `/bin/sh -s` over SSH and
# interprets the output itself (mooring_core::desktop); nothing from a saved
# connection is ever inserted into it.
set -f
PATH=$PATH:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C.UTF-8
T=
command -v timeout >/dev/null 2>&1 && T="timeout -k 1 3"
me=$(id -u)
echo "mooring-desktop-probe 1"
echo "ssh.uid=$me"
if ! command -v loginctl >/dev/null 2>&1; then
  echo "logind=absent"; echo "end"; exit 0
fi
# The active graphical session, or else the first graphical one.
sid=
for s in $($T loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
  props=$($T loginctl show-session "$s" -p Type -p Active 2>/dev/null)
  case "$props" in *Type=wayland*|*Type=x11*) ;; *) continue ;; esac
  [ -z "$sid" ] && sid=$s
  case "$props" in *Active=yes*) sid=$s; break ;; esac
done
if [ -z "$sid" ]; then
  echo "session=none"; echo "end"; exit 0
fi
uid= user=
for line in $($T loginctl show-session "$sid" -p Id -p Type -p Active -p Name -p User -p LockedHint -p Desktop 2>/dev/null); do
  case "$line" in
    Id=*|Type=*|Active=*|Name=*|User=*|LockedHint=*|Desktop=*) echo "session.$line" ;;
  esac
  case "$line" in User=*) uid=${line#User=} ;; Name=*) user=${line#Name=} ;; esac
done
if [ "$me" != "$uid" ] && { [ "$me" != 0 ] || ! command -v runuser >/dev/null 2>&1; }; then
  echo "session.readable=no"; echo "end"; exit 0
fi
runtime=${MOORING_RUNTIME_ROOT:-/run/user}/$uid
# Each query runs as the session's user, bounded in time, and only reads.
as_user() {
  if [ "$me" = "$uid" ]; then
    env XDG_RUNTIME_DIR="$runtime" $T "$@"
  else
    runuser -u "$user" -- env XDG_RUNTIME_DIR="$runtime" $T "$@"
  fi
}
hypr=
for dir in $(ls -t "$runtime/hypr" 2>/dev/null); do
  [ -S "$runtime/hypr/$dir/.socket.sock" ] && { hypr=$dir; break; }
done
if [ -n "$hypr" ] && command -v hyprctl >/dev/null 2>&1; then
  if monitors=$(as_user env HYPRLAND_INSTANCE_SIGNATURE="$hypr" hyprctl -j monitors 2>/dev/null); then
    printf 'hyprland.monitors=%s\n' "$(printf '%s' "$monitors" | tr -d '\n' | head -c 60000)"
    for option in misc:mouse_move_enables_dpms misc:key_press_enables_dpms; do
      value=$(as_user env HYPRLAND_INSTANCE_SIGNATURE="$hypr" hyprctl -j getoption "$option" 2>/dev/null)
      printf 'hyprland.option=%s\n' "$(printf '%s' "$value" | tr -d '\n' | head -c 2000)"
    done
  else
    echo "hyprland=unreadable"
  fi
fi
omarchy=${MOORING_OMARCHY_ROOT:-/usr/share/omarchy}
if command -v omarchy-shell >/dev/null 2>&1 && [ -f "$omarchy/shell/shell.qml" ]; then
  status=$(as_user env OMARCHY_PATH="$omarchy" omarchy-shell lock status 2>/dev/null | grep '^{' | tail -n 1 | head -c 4000)
  if [ -n "$status" ]; then printf 'omarchy.lock=%s\n' "$status"; else echo "omarchy=unreadable"; fi
fi
echo "end"
