#!/usr/bin/env bash
# =============================================================================
#  samp-wine-launcher
#  Run GTA: San Andreas + SA-MP (or open.mp) on a headless Linux box through
#  Wine, and view/play it from a browser via noVNC.
#
#  Verified on: Debian 12 (bookworm), Wine 8.0 (win32 prefix), Intel HD 630
#               iGPU with an HDMI dummy plug, Mesa 25 + DXVK 2.4, x11vnc+noVNC.
#
#  Usage:
#     ./start_samp.sh                                  # CLI direct-connect (default)
#     ./start_samp.sh <nick> <host> <port>             # custom target
#     ./start_samp.sh gui                              # classic samp.exe window
#
#  All settings can also be set via environment variables (see below).
#
#  ---------------------------------------------------------------------------
#  SA-MP command-line rules (these are NOT intuitive; verified by testing):
#    1. the FIRST argument must be "IP:PORT" (IPv4). "-h <host>" does NOT work.
#    2. the nickname CANNOT be passed on the command line. It is read from the
#       Wine registry key  HKCU\Software\SAMP\PlayerName
#    3. "-c" is required (it means "empty RCON password")
#       =>  samp.exe 1.2.3.4:7777 -c
#
#  If a nickname is rejected with "Unacceptable NickName", the most common
#  cause is that the SAME account is already logged in elsewhere (SA-MP kicks
#  duplicates), NOT necessarily an illegal character.
#  ---------------------------------------------------------------------------
# =============================================================================
set -u

# ---------------------------- configuration ---------------------------------
MODE="${SAMP_MODE:-cli}"                 # cli | gui  (first arg "gui" also works)
NICK="${1:-${SAMP_NICK:-Player}}"
HOST="${2:-${SAMP_HOST:-127.0.0.1}}"
PORT="${3:-${SAMP_PORT:-7777}}"
if [ "${1:-}" = "gui" ]; then MODE=gui; shift; NICK="${1:-${SAMP_NICK:-Player}}"; fi

WINEPREFIX="${SAMP_WINEPREFIX:-$HOME/.samp-prefix}"
GAME="${SAMP_GAME_DIR:-$HOME/GTA San Andreas}"
DISP="${SAMP_DISPLAY:-:0}"
RES="${SAMP_RESOLUTION:-800x600}"
VNC_PORT="${SAMP_VNC_PORT:-5900}"
NOVNC_PORT="${SAMP_NOVNC_PORT:-6080}"
XORG_BIN="${SAMP_XORG_BIN:-/usr/lib/xorg/Xorg}"
DXVK_CONF="${SAMP_DXVK_CONF:-$WINEPREFIX/drive_c/windows/system32/dxvk.conf}"
export DISPLAY="$DISP"
export WINEPREFIX
export DXVK_CONFIG_FILE="$DXVK_CONF"

# Non-interactive sudo: set SAMP_SUDO_PASS, or configure sudoers NOPASSWD
# (recommended). Never hard-code a password in this file.
sdo(){ if [ -n "${SAMP_SUDO_PASS:-}" ]; then printf '%s\n' "$SAMP_SUDO_PASS" | sudo -S "$@"; else sudo "$@"; fi; }
log(){ printf '\033[1;32m[start]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }

# ---------------------------- 1. Xorg (root) --------------------------------
if ! pgrep -x Xorg >/dev/null 2>&1; then
  log "starting Xorg $DISP (needs a display; an HDMI dummy plug is recommended)"
  rm -f "/tmp/.X11-unix/X${DISP#:}" 2>/dev/null
  sdo setsid "$XORG_BIN" "$DISP" -noreset -ac -nolisten tcp \
      -logfile /tmp/xorg.log >/tmp/xorg.out 2>&1 &
  sleep 6
fi
if pgrep -x Xorg >/dev/null 2>&1; then
  log "Xorg ready ($(DISPLAY=$DISP xdpyinfo 2>/dev/null | grep -m1 dimensions))"
else
  warn "Xorg not ready; see /tmp/xorg.log"; tail -25 /tmp/xorg.log 2>/dev/null
fi

# ---------------------------- 2. resolution ---------------------------------
if pgrep -x Xorg >/dev/null 2>&1; then
  OUT=$(DISPLAY=$DISP xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')
  if [ -n "$OUT" ]; then
    if DISPLAY=$DISP xrandr --output "$OUT" --mode "$RES" >/dev/null 2>&1; then
      log "resolution set to $RES (output $OUT)"
    else
      warn "could not set $RES on $OUT"
    fi
  fi
fi

# ---------------------------- 3. openbox ------------------------------------
if ! pgrep -x openbox >/dev/null; then
  log "starting openbox"; setsid openbox >/dev/null 2>&1 & sleep 1
fi

# ---------------------------- 4. picom (compositor) -------------------------
# Without a compositor the VNC viewer can show a black screen while the game
# renders through DRI3 zero-copy present.
if ! pgrep -x picom >/dev/null; then
  log "starting picom (glx)"; setsid picom --backend glx >/tmp/picom.log 2>&1 & sleep 1
fi

# ---------------------------- 5. x11vnc -------------------------------------
if ! pgrep -x x11vnc >/dev/null; then
  log "starting x11vnc on :$VNC_PORT (no password)"
  setsid x11vnc -display "$DISP" -forever -shared -nopw -rfbport "$VNC_PORT" \
      -noxdamage >/tmp/x11vnc.log 2>&1 & sleep 2
fi

# ---------------------------- 6. noVNC / websockify -------------------------
if ! pgrep -f "websockify.*$NOVNC_PORT" >/dev/null; then
  log "starting noVNC on :$NOVNC_PORT"
  setsid websockify --web=/usr/share/novnc "$NOVNC_PORT" "localhost:$VNC_PORT" \
      >/tmp/novnc.log 2>&1 & sleep 1
fi

# ---------------------------- 7. CJK fonts (for Chinese servers) ------------
# SA-MP server text is GBK. Wine needs a CJK font *and* ANSI codepage 936
# (LANG=zh_CN.GBK) or the in-game text shows as garbage.
NOTO_TTC=/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc
if [ ! -f "$NOTO_TTC" ]; then
  log "installing fonts-noto-cjk (for CJK in-game text)"
  sdo apt-get install -y fonts-noto-cjk >/tmp/font_install.log 2>&1
fi
WFONTS="$WINEPREFIX/drive_c/windows/Fonts"
if [ -f "$NOTO_TTC" ] && [ ! -f "$WFONTS/NotoSansCJK-Regular.ttc" ]; then
  log "copying CJK font into wine prefix"
  mkdir -p "$WFONTS"
  cp -f "$NOTO_TTC" "$WFONTS/" 2>/dev/null
  cp -f /usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc "$WFONTS/" 2>/dev/null
fi
if [ "$(wine reg query "HKCU\\Software\\Wine\\Fonts\\Replacements" 2>/dev/null | grep -c 'Noto Sans CJK SC')" -lt 6 ]; then
  log "configuring wine font replacements"
  for f in "MS Shell Dlg" "MS Shell Dlg 2" "MS Sans Serif" "Tahoma" "System" "SimSun" "Microsoft Sans Serif" "MS Serif"; do
    wine reg add "HKCU\\Software\\Wine\\Fonts\\Replacements" /v "$f" /d "Noto Sans CJK SC" /f >/dev/null 2>&1
  done
fi

# ---------------------------- 8. base-game quirk ----------------------------
# A 2.8 MB version.dll shipped with some SA-MP repacks crashes the base game;
# rename it away. Harmless if absent.
if [ -f "$GAME/version.dll" ]; then
  log "disabling version.dll -> version.dll.bak"
  mv "$GAME/version.dll" "$GAME/version.dll.bak" 2>/dev/null
fi

# ---------------------------- 9. reset state --------------------------------
for p in $(pgrep -f 'gta_sa|samp\.exe|explorer /desktop' 2>/dev/null); do
  kill -9 "$p" 2>/dev/null
done
wineserver -k >/dev/null 2>&1
sleep 2

cd "$GAME" || { warn "game dir not found: $GAME"; exit 1; }

# ---------------------------- 9.5 sync game dir into registry ---------------
# samp.exe locates gta_sa.exe via HKCU\Software\SAMP\gta_sa_exe, and gta_sa.exe
# reads HKLM\...\Rockstar Games\GTA San Andreas. Both must match $GAME or a
# client-dir switch is silently ignored (or crashes). Write real Z:\ paths so
# no symlinks are involved.
to_win_path(){ printf 'Z:%s' "$1" | sed -e 's#/#\\#g'; }
GAME_WIN="$(to_win_path "$GAME")"
WANT_EXE="${GAME_WIN}\\gta_sa.exe"
CUR_EXE=$(wine reg query "HKCU\\Software\\SAMP" /v gta_sa_exe 2>/dev/null \
          | sed -n 's/.*REG_SZ[[:space:]]*//p' | tr -d '\r')
if [ "$(printf '%s' "$CUR_EXE" | tr 'A-Z' 'a-z')" \
     != "$(printf '%s' "$WANT_EXE" | tr 'A-Z' 'a-z')" ]; then
  log "syncing game dir into wine registry: $GAME_WIN"
  wine reg add "HKCU\\Software\\SAMP" /v gta_sa_exe /t REG_SZ /d "$WANT_EXE" /f >/dev/null 2>&1
  wine reg add "HKLM\\Software\\Rockstar Games\\GTA San Andreas" /v InstallationPath /t REG_SZ /d "$GAME_WIN" /f >/dev/null 2>&1
  wine reg add "HKLM\\Software\\Rockstar Games\\GTA San Andreas" /v ExePath /t REG_SZ /d "$WANT_EXE" /f >/dev/null 2>&1
fi

# ---------------------------- 10. launch ------------------------------------
if [ "$MODE" = "gui" ]; then
  log "launching SA-MP (GUI connect window)"
  env LANG=zh_CN.GBK LC_ALL=zh_CN.GBK \
    setsid wine explorer /desktop=gtasa,"$RES" samp.exe >/tmp/samp_run.log 2>&1 &
else
  # SA-MP's CLI only accepts an IPv4 literal -> resolve a hostname first.
  if ! printf '%s' "$HOST" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    RESOLVED=$(getent hosts "$HOST" 2>/dev/null | awk '{print $1; exit}')
    [ -n "$RESOLVED" ] && { log "resolved $HOST -> $RESOLVED"; HOST="$RESOLVED"; }
  fi
  log "setting nickname in registry: $NICK"
  wine reg add "HKCU\\Software\\SAMP" /v PlayerName /t REG_SZ /d "$NICK" /f >/dev/null 2>&1
  log "launching SA-MP (CLI direct-connect): $HOST:$PORT"
  env LANG=zh_CN.GBK LC_ALL=zh_CN.GBK \
    setsid wine explorer /desktop=gtasa,"$RES" samp.exe "$HOST:$PORT" -c >/tmp/samp_run.log 2>&1 &
fi

log "==================================================================="
log "  mode    : $MODE"
log "  server  : $HOST:$PORT   nick: $NICK"
log "  vnc     : http://<this-host>:$NOVNC_PORT/vnc.html   (no password)"
log "  game log: /tmp/samp_run.log"
log "==================================================================="
