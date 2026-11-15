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
uid= user= stype=
for line in $($T loginctl show-session "$sid" -p Id -p Type -p Active -p Name -p User -p LockedHint -p Desktop 2>/dev/null); do
  case "$line" in
    Id=*|Type=*|Active=*|Name=*|User=*|LockedHint=*|Desktop=*) echo "session.$line" ;;
  esac
  case "$line" in User=*) uid=${line#User=} ;; Name=*) user=${line#Name=} ;; Type=*) stype=${line#Type=} ;; esac
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
# An X11 desktop, such as Unity or GNOME on Ubuntu 18.04: its desktop name,
# display power, screen size, monitors in use and screen saver. DISPLAY and
# XAUTHORITY come from the session's own environment, as its user manager
# holds it; only the values below are printed, never the environment itself.
if [ "$stype" = x11 ]; then
  envs=
  command -v systemctl >/dev/null 2>&1 && envs=$(as_user systemctl --user show-environment 2>/dev/null)
  value() { printf '%s\n' "$envs" | sed -n "s/^$1=//p" | head -n 1; }
  dpy=$(value DISPLAY) xauth=$(value XAUTHORITY) desk=$(value XDG_CURRENT_DESKTOP) bus=$(value DBUS_SESSION_BUS_ADDRESS)
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
  [ -n "$bus" ] || { [ -S "$runtime/bus" ] && bus=unix:path=$runtime/bus; }
  printf 'x11.desktop=%s\n' "$desk"
  printf 'x11.display=%s\n' "$dpy"
  x() { as_user env DISPLAY="$dpy" XAUTHORITY="$xauth" "$@"; }
  if [ -n "$dpy" ] && command -v xset >/dev/null 2>&1; then
    q=$(x xset q 2>/dev/null)
    dpms=$(printf '%s\n' "$q" | sed -n 's/^ *Monitor is //p' | head -n 1)
    [ -n "$dpms" ] || dpms=$(printf '%s\n' "$q" | sed -n 's/^ *DPMS is //p' | head -n 1)
    [ -n "$dpms" ] && printf 'x11.dpms=%s\n' "$dpms"
  fi
  if [ -n "$dpy" ] && command -v xrandr >/dev/null 2>&1 && screen=$(x xrandr --current 2>/dev/null); then
    printf '%s\n' "$screen" | sed -n 's/^Screen [0-9]*:.* current \([0-9]*\) x \([0-9]*\),.*/x11.screen=\1x\2/p' | head -n 1
    # Monitors in use: connected outputs showing part of the screen.
    printf 'x11.monitors=%s\n' "$(printf '%s\n' "$screen" | grep -c '^[^ ]* connected .*[0-9]x[0-9]*+[0-9]*+[0-9]')"
  fi
  if [ -n "$bus" ] && command -v gdbus >/dev/null 2>&1; then
    call() { as_user env DBUS_SESSION_BUS_ADDRESS="$bus" gdbus call --session "$@" 2>/dev/null; }
    # Unity 7 draws its own lock screen and answers whether it is locked; it
    # sets neither logind's LockedHint nor a screen saver state that tracks
    # the lock.
    locked=$(call --dest com.canonical.Unity --object-path /com/canonical/Unity/Session \
      --method com.canonical.Unity.Session.IsLocked)
    case "$locked" in
      *true*) echo "x11.unity_locked=true" ;;
      *false*) echo "x11.unity_locked=false" ;;
    esac
    for name in gnome cinnamon mate; do
      active=$(call --dest "org.$name.ScreenSaver" --object-path "/org/$name/ScreenSaver" \
        --method "org.$name.ScreenSaver.GetActive")
      case "$active" in
        *true*) printf 'x11.screensaver=org.%s.ScreenSaver true\n' "$name" ;;
        *false*) printf 'x11.screensaver=org.%s.ScreenSaver false\n' "$name" ;;
        *) continue ;;
      esac
      if [ "$name" = gnome ] && command -v gsettings >/dev/null 2>&1; then
        enabled=$(as_user env DBUS_SESSION_BUS_ADDRESS="$bus" gsettings get org.gnome.desktop.screensaver lock-enabled 2>/dev/null)
        case "$enabled" in true|false) printf 'x11.lock_enabled=%s\n' "$enabled" ;; esac
      fi
      break
    done
  fi
fi
echo "end"
