#!/usr/bin/env bash
# ============================================================================
#  setup-crd-mirror.sh — Chrome Remote Desktop "mirror the current session"
#  for CachyOS / Arch (KDE Plasma Wayland; GNOME Wayland also works)
#
#  What you get:
#   1. CRD starts automatically at boot (systemd, enabled)
#   2. When you connect, you see the REAL current session/screen (mirror),
#      not the separate virtual desktop CRD normally creates on Linux
#   3. ~0% CPU while nobody is connected (on-demand streaming)
#   4. Pixel-exact 1:1 view (the fake CRD display is pinned to the physical
#      screen resolution)
#
#  How it works:
#   CRD on Linux always spawns its own Xvfb, so the CRD session runs a
#   fullscreen RDP viewer that points at krdpserver (KDE's RDP server), which
#   shares your actual session over the 127.0.0.1 loopback. A watcher
#   (crd-ondemand) only turns the stream on while a CRD client is connected.
#
#  Usage:
#    ./setup-crd-mirror.sh              # same as install
#    ./setup-crd-mirror.sh install      # configure (safe to re-run)
#    ./setup-crd-mirror.sh status       # show state
#    ./setup-crd-mirror.sh force-on     # always stream (ignore auto-off)
#    ./setup-crd-mirror.sh force-off    # back to automatic
#    ./setup-crd-mirror.sh uninstall    # remove mirror, back to CRD defaults
#
#  Requirements: run as a normal user (the script calls sudo only when it must
#  install packages or write systemd system units). Packages: krdp, freerdp,
#  chrome-remote-desktop (AUR).
# ============================================================================

set -euo pipefail

# ------------------------------- 0. Helpers --------------------------------
ME="$(basename "$0")"
C_RESET=$'\033[0m'; C_B=$'\033[1m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
C_GRN=$'\033[32m'; C_CYN=$'\033[36m'
info() { printf '%s[setup]%s %s\n' "$C_CYN" "$C_RESET" "$*"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
err()  { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
note() { printf '%s[note]%s %s\n' "$C_CYN" "$C_RESET" "$*"; }
step() { printf '\n%s==> %s%s\n' "$C_B" "$*" "$C_RESET"; }

# Tunables (edit if needed)
RDP_PORT=3389          # loopback RDP port (listens on 127.0.0.1 only)
KRDP_QUALITY=70        # krdpserver encode quality
IDLE_SECS=300          # stop streaming after 5 minutes with no signal
LINGER=20              # wait 20s for a client to reconnect after disconnect
CPU_TICKS=3            # host CPU >= 3%/core means "in use" (fallback signal)

# --------------------------- 1. Resolve the user ---------------------------
if [ "$(id -u)" -eq 0 ]; then
  TARGET_USER="${SUDO_USER:-}"
  [ -n "$TARGET_USER" ] || die "Run as a normal user, no need to sudo directly: ./$ME install"
else
  TARGET_USER="$(id -un)"
fi
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
[ -d "$TARGET_HOME" ] || die "Cannot resolve home directory of $TARGET_USER"

CONF_DIR="$TARGET_HOME/.config/crd-mirror"
USER_SYSD="$TARGET_HOME/.config/systemd/user"
CRD_CONF_DIR="$TARGET_HOME/.config/chrome-remote-desktop"
SESSION_FILE="$TARGET_HOME/.chrome-remote-desktop-session"
CRD_UNIT="chrome-remote-desktop@${TARGET_USER}.service"
SCREEN_RES=""

# Run a command as the target user
uruncmd() {
  if [ "$(id -un)" = "$TARGET_USER" ]; then "$@"; else sudo -u "$TARGET_USER" -- "$@"; fi
}
# sudo wrapper that also works without a terminal (cron, scripted runs):
#   * password already cached     -> sudo
#   * SUDO_ASKPASS is set         -> sudo -A
#   * there is a terminal        -> normal sudo prompt
sudorun() {
  if sudo -n true 2>/dev/null; then sudo "$@"; return $?; fi
  if [ -n "${SUDO_ASKPASS:-}" ] && [ -x "${SUDO_ASKPASS:-/nonexistent}" ]; then
    sudo -A "$@"; return $?
  fi
  if [ -t 0 ] || [ -t 1 ] || [ -t 2 ]; then sudo "$@"; return $?; fi
  err "sudo is required but there is no terminal to ask for the password."
  note "Run from a terminal, or: export SUDO_ASKPASS=/path/to/askpass-helper"
  return 1
}
# Run systemctl --user for the target user
usystemctl() {
  if [ "$(id -un)" = "$TARGET_USER" ]; then
    systemctl --user "$@"
  else
    sudo -u "$TARGET_USER" env XDG_RUNTIME_DIR="/run/user/$TARGET_UID" \
      DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$TARGET_UID/bus" \
      systemctl --user "$@"
  fi
}
need_sudo() {
  if sudo -n true 2>/dev/null; then return 0; fi
  info "sudo is required (it will ask for the password) to install packages and configure systemd."
  if ! sudorun -v; then
    die "Cannot authenticate with sudo. Run this script from a terminal, or export SUDO_ASKPASS=/path/to/askpass-helper (an executable that prints the password)."
  fi
}
backup_once() { # backup_once <file> -> keeps one .orig of the ORIGINAL CRD session
  local f="$1"
  [ -e "$f" ] || return 0
  if grep -q 'crd-mirror' "$f" 2>/dev/null; then
    # Already the mirror session - never back that up as the "original".
    [ -e "$f.orig" ] || warn "No original CRD session backup found; 'uninstall' will restore CRD's default virtual desktop."
    return 0
  fi
  if [ ! -e "$f.orig" ]; then
    cp -p "$f" "$f.orig" && info "Backup: $f.orig"
  fi
  return 0
}

# --------------------------- 2. Preflight ----------------------------------
preflight() {
  step "Checking the environment"

  if [ -r /etc/os-release ]; then
    . /etc/os-release
    case "${ID_LIKE:-}${ID:-}" in
      *arch*) ok "Operating system: ${PRETTY_NAME:-$ID}" ;;
      *) warn "Not an Arch/CachyOS base (${PRETTY_NAME:-$ID}) - the script will still try." ;;
    esac
  fi

  command -v systemctl >/dev/null || die "systemd is required (no systemctl)."

  # Detect the graphical session of the target user
  local SESSION_TYPE=""
  if uruncmd pgrep -u "$TARGET_USER" -x kwin_wayland >/dev/null 2>&1; then
    SESSION_TYPE=wayland
  elif uruncmd pgrep -u "$TARGET_USER" -x gnome-shell >/dev/null 2>&1; then
    SESSION_TYPE=wayland
  elif [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    SESSION_TYPE=wayland
  elif uruncmd pgrep -u "$TARGET_USER" -x kwin_x11 >/dev/null 2>&1; then
    SESSION_TYPE=x11
  elif [ -n "${DISPLAY:-}" ]; then
    SESSION_TYPE=x11
  fi
  if [ -z "$SESSION_TYPE" ]; then
    warn "Cannot detect a graphical session - assuming Wayland."
    SESSION_TYPE=wayland
  fi

  if [ "$SESSION_TYPE" = "wayland" ]; then
    if uruncmd pgrep -u "$TARGET_USER" -x kwin_wayland >/dev/null 2>&1; then
      ok "Session: KDE Plasma (Wayland)"
    else
      ok "Session: Wayland"
    fi
  else
    warn "X11 session: mirroring X11 needs x11vnc instead of krdp. This script targets Wayland."
  fi

  # Required packages
  local pkgs=() p
  command -v krdpserver >/dev/null || pkgs+=(krdp)
  command -v xfreerdp3   >/dev/null || pkgs+=(freerdp)
  if ! command -v chrome-remote-desktop >/dev/null 2>&1 &&
     [ ! -x /opt/google/chrome-remote-desktop/chrome-remote-desktop ]; then
    pkgs+=(chrome-remote-desktop)
  fi

  if [ "${#pkgs[@]}" -gt 0 ]; then
    step "Installing packages: ${pkgs[*]}"
    local repo=() aur=()
    for p in "${pkgs[@]}"; do
      if pacman -Si "$p" >/dev/null 2>&1; then repo+=("$p"); else aur+=("$p"); fi
    done
    if [ "${#repo[@]}" -gt 0 ]; then
      info "From the repos: ${repo[*]}"
      sudorun pacman -S --needed --noconfirm "${repo[@]}"
    fi
    if [ "${#aur[@]}" -gt 0 ]; then
      command -v yay >/dev/null || die "${aur[*]} is AUR-only, install yay/paru first."
      info "From the AUR: ${aur[*]}"
      sudo -u "$TARGET_USER" yay -S --needed --noconfirm "${aur[@]}" ||
        die "Failed to install ${aur[*]} - try manually: yay -S ${aur[*]}"
    fi
  else
    ok "All required packages are already installed"
  fi

  # Is the CRD host linked to a Google account yet?
  if ! ls "$CRD_CONF_DIR"/host#*.json >/dev/null 2>&1; then
    warn "No CRD host config found ($CRD_CONF_DIR/host#*.json)."
    cat >&2 <<EOT

  Chrome Remote Desktop must be linked to a Google account once:
    1. Open https://remotedesktop.google.com/access on another machine, sign in.
    2. Pick "Set up remote access" (headless/no-screen machine).
    3. Run exactly the command the page gives you (looks like:
       DISPLAY= /opt/google/chrome-remote-desktop/chrome-remote-desktop
         --redirect-url=XXXX) in a terminal on this machine.
    4. Then re-run: ./setup-crd-mirror.sh install
       (or enable the service: sudo systemctl enable --now $CRD_UNIT)
EOT
  fi
}

# ----------------- 3. Detect the physical screen resolution ----------------
detect_display() {
  local out
  # Strip ANSI colours so the field layout is predictable
  out="$(uruncmd kscreen-doctor -o 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' || true)"
  if [ -n "$out" ]; then
    # Union of every enabled output (multi-monitor safe): "Geometry: x,y WxH"
    SCREEN_RES="$(printf '%s\n' "$out" | awk '
      /Geometry:/ {
        split($2, a, ","); split($3, b, "x");
        r = (a[1] + 0) + (b[1] + 0);
        d = (a[2] + 0) + (b[2] + 0);
        if (r > nr) nr = r;
        if (d > nb) nb = d
      }
      END { if (nr > 0 && nb > 0) printf "%dx%d", nr, nb }')"
  fi

  if [ -z "$SCREEN_RES" ]; then
    # Fallback: the current Xwayland/X11 screen ("current 1366 x 768,")
    SCREEN_RES="$(uruncmd xrandr --current 2>/dev/null | awk '
      /current/ { for (i = 1; i <= NF; i++) if ($i == "current") {
                    gsub(/,/, "", $(i+1)); gsub(/,/, "", $(i+3));
                    print $(i+1)"x"$(i+3) } }' | head -1)"
  fi

  # Sanity check: must look like 1366x768
  if ! printf '%s' "$SCREEN_RES" | grep -Eq '^[0-9]{3,5}x[0-9]{3,5}$'; then
    SCREEN_RES=""
  fi

  if [ -z "$SCREEN_RES" ]; then
    warn "Cannot read the resolution, falling back to 1600x1200 (still works)."
    SCREEN_RES="1600x1200"
  else
    ok "Physical screen: $SCREEN_RES (the CRD display will match this)"
  fi
}

# ------------------------ 4. Generate the config files ---------------------
install_files() {
  step "Generating the mirror configuration"

  mkdir -p "$CONF_DIR" "$USER_SYSD"
  chmod 700 "$CONF_DIR"

  # --- 4.1 loopback RDP credential (kept as-is if it already exists) ---
  local RDP_PASS
  RDP_PASS="$(grep -s '^CRD_RDP_PASS=' "$CONF_DIR/rdp.conf" 2>/dev/null | cut -d= -f2- || true)"
  if [ -z "$RDP_PASS" ]; then
    RDP_PASS="crd-$(openssl rand -hex 12)"
    info "Generated a new loopback RDP password (used on 127.0.0.1 only)"
  fi
  umask 077
  printf '# Loopback RDP bridge for Chrome Remote Desktop (127.0.0.1 only)\nCRD_RDP_USER=crd\nCRD_RDP_PASS=%s\nCRD_RDP_PORT=%s\n' \
    "$RDP_PASS" "$RDP_PORT" > "$CONF_DIR/rdp.conf"
  chmod 600 "$CONF_DIR/rdp.conf"

  # --- 4.2 the CRD session script (CRD runs this inside the fake display) ---
  backup_once "$SESSION_FILE"
  cat > "$SESSION_FILE" <<'EOF'
#!/bin/bash
# CRD session: mirror the current session through the loopback RDP bridge
exec "$HOME/.config/crd-mirror/crd-mirror-viewer.sh"
EOF
  chmod +x "$SESSION_FILE"

  # --- 4.3 the viewer ---
  cat > "$CONF_DIR/crd-mirror-viewer.sh" <<'EOF'
#!/usr/bin/env bash
# Chrome Remote Desktop session script: instead of starting a separate virtual
# desktop, show the real KDE session through the loopback RDP bridge
# (krdpserver = crd-mirror.service). It only streams while crd-ondemand has
# removed the PAUSE file (i.e. a CRD client is actually connected).
CONF="$HOME/.config/crd-mirror/rdp.conf"
GATE="$HOME/.config/crd-mirror/PAUSE"
RDP_HOST=127.0.0.1
LOG_TAG="crd-mirror"

if [ ! -r "$CONF" ]; then
  echo "$LOG_TAG: missing $CONF" >&2
  sleep 15
  exit 1
fi
. "$CONF"

echo "$LOG_TAG: idle (no client yet, or the RDP bridge is not up)"
while :; do
  if [ -e "$GATE" ]; then sleep 1; continue; fi

  # Wait for the bridge (krdpserver runs inside the target user session)
  rdp_up=0
  for _ in $(seq 1 3); do
    if (exec 3<>"/dev/tcp/${RDP_HOST}/${CRD_RDP_PORT}") 2>/dev/null; then
      rdp_up=1; exec 3>&- 3<&-; break
    fi
    sleep 1
  done
  [ "$rdp_up" = 1 ] || { sleep 1; continue; }

  echo "$LOG_TAG: streaming the current session"
  xfreerdp3 \
    /v:${RDP_HOST}:${CRD_RDP_PORT} \
    /u:"${CRD_RDP_USER}" \
    /p:"${CRD_RDP_PASS}" \
    /sec:tls \
    /cert:ignore \
    /f \
    +clipboard \
    /log-level:WARN
  echo "$LOG_TAG: viewer exited rc=$?"
  sleep 2
done
EOF
  chmod +x "$CONF_DIR/crd-mirror-viewer.sh"

  # --- 4.4 the on-demand watcher ---
  cat > "$CONF_DIR/crd-ondemand.sh" <<EOF
#!/usr/bin/env bash
# crd-ondemand - only run the mirror chain while somebody is connected over
# Chrome Remote Desktop.
#   * "Client connected:" in the CRD host log      -> start streaming
#   * "Client disconnected:"                       -> stop streaming (waits ${LINGER}s for a reconnect)
#   * CRD host CPU >= ${CPU_TICKS}% of one core        -> start streaming (fallback if the log is missing)
#   * ${IDLE_SECS}s with no signal at all               -> stop streaming (safety net)
DIR="\${XDG_CONFIG_HOME:-\$HOME/.config}/crd-mirror"
GATE="\$DIR/PAUSE"
CONN="\$DIR/.connected"
DISC="\$DIR/.disconnected"
CPUACT="\$DIR/.cpuactive"
FORCE="\$DIR/FORCE_ON"
UNIT="chrome-remote-desktop@\${USER}.service"
IDLE_SECS=${IDLE_SECS}
LINGER=${LINGER}
CPU_TICKS=${CPU_TICKS}

mkdir -p "\$DIR"

( journalctl -u "\$UNIT" -o cat -f --since now 2>/dev/null | \\
    while IFS= read -r line; do
      case "\$line" in
        *"Client connected:"*)    date +%s > "\$CONN" ;;
        *"Client disconnected:"*) date +%s > "\$DISC" ;;
      esac
    done ) &

touch_gate() { : > "\$GATE"; }
drop_gate()  { rm -f "\$GATE"; }
host_pid()   { pgrep -f 'chrome-remote-desktop-host' 2>/dev/null | head -1; }
age_of() { if [ -f "\$1" ]; then printf '%s' \$(( \$(date +%s) - \$(stat -c %Y "\$1" 2>/dev/null || echo 0) )); else echo 999999; fi; }

prev_ticks=0
while true; do
  want=0
  [ -e "\$FORCE" ] && want=1

  conn_age=\$(age_of "\$CONN"); disc_age=\$(age_of "\$DISC")
  if [ "\$conn_age" -lt "\$IDLE_SECS" ] && [ "\$conn_age" -lt \$(( disc_age + LINGER )) ]; then want=1; fi
  if [ "\$disc_age" -lt "\$conn_age" ] && [ "\$disc_age" -lt "\$LINGER" ]; then want=0; fi

  pid=\$(host_pid)
  if [ -n "\$pid" ] && [ -r "/proc/\$pid/stat" ]; then
    ticks=\$(awk '{print \$14+\$15}' "/proc/\$pid/stat" 2>/dev/null); [ -n "\$ticks" ] || ticks=0
    if [ "\$prev_ticks" -gt 0 ] && [ \$(( ticks - prev_ticks )) -ge "\$CPU_TICKS" ]; then
      want=1; date +%s > "\$CPUACT"
    fi
    prev_ticks="\$ticks"
  fi
  [ "\$(age_of "\$CPUACT")" -lt "\$IDLE_SECS" ] && want=1

  if [ "\$want" = 1 ]; then drop_gate; else touch_gate; pkill -x xfreerdp3 2>/dev/null; fi
  sleep 1
done
EOF
  chmod +x "$CONF_DIR/crd-ondemand.sh"

  # --- 4.5 the user systemd unit for krdpserver ---
  cat > "$USER_SYSD/crd-mirror.service" <<EOF
[Unit]
Description=Loopback RDP bridge for Chrome Remote Desktop (share the real screen)
After=graphical-session.target plasma-core.target plasma-xdg-desktop-portal-kde.service
Wants=plasma-core.target

[Service]
Type=simple
EnvironmentFile=%h/.config/crd-mirror/rdp.conf
ExecStart=/usr/bin/krdpserver --username \${CRD_RDP_USER} --password \${CRD_RDP_PASS} \\
  --address 127.0.0.1 --port \${CRD_RDP_PORT} --quality ${KRDP_QUALITY}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=graphical-session.target
EOF

  cat > "$USER_SYSD/crd-ondemand.service" <<EOF
[Unit]
Description=Chrome Remote Desktop on-demand mirror (stream only while connected)
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=%h/.config/crd-mirror/crd-ondemand.sh
Restart=always
RestartSec=2

[Install]
WantedBy=graphical-session.target
EOF

  # --- 4.6 pin the fake CRD display to the physical resolution (root) ---
  step "Writing systemd system configuration for CRD"
  local tmpconf f
  tmpconf="$(mktemp /tmp/crd-mirror-size.XXXXXX.conf)"
  cat > "$tmpconf" <<EOF
[Service]
# Mirror 1:1: the CRD display matches the physical resolution.
# Do not offer other sizes: resizing mid-session breaks the RDP stream.
Environment=CHROME_REMOTE_DESKTOP_DEFAULT_DESKTOP_SIZES=${SCREEN_RES}
EOF
  sudorun mkdir -p "/etc/systemd/system/${CRD_UNIT}.d"
  # Drop older drop-ins so only this one is active
  for f in "/etc/systemd/system/${CRD_UNIT}.d"/*.conf; do
    [ -e "$f" ] || continue
    sudorun rm -f "$f" && info "Removed old drop-in: $f"
  done
  sudorun install -m644 "$tmpconf" "/etc/systemd/system/${CRD_UNIT}.d/10-mirror-size.conf"
  rm -f "$tmpconf"

  ok "Written: $CONF_DIR, $USER_SYSD, $SESSION_FILE, /etc/systemd/system/${CRD_UNIT}.d/"
}

# ----------------------------- 5. Enable services --------------------------
enable_services() {
  step "Enabling and starting the services"
  usystemctl daemon-reload
  usystemctl enable --now crd-mirror.service crd-ondemand.service 2>&1 | sed 's/^/    /' || true

  sudorun systemctl daemon-reload
  sudorun systemctl enable "$CRD_UNIT" 2>&1 | sed 's/^/    /'

  info "Restarting the CRD host so the new session behaviour takes effect..."
  sudorun systemctl restart "$CRD_UNIT"
  ok "Enabled: $CRD_UNIT + crd-mirror + crd-ondemand"
}

wait_host_ready() {
  step "Waiting for the CRD host to become ready"
  local i
  for i in $(seq 1 30); do
    if journalctl -u "$CRD_UNIT" --since '3 minutes ago' --no-pager 2>/dev/null |
       grep -q 'ready to receive connections'; then
      ok "Host is ready to receive connections"
      return 0
    fi
    sleep 2
  done
  warn "No 'ready to receive connections' yet - check with: journalctl -u $CRD_UNIT -n 50"
}

# ------------------------------- 6. Status ---------------------------------
do_status() {
  detect_display
  step "Status"
  printf '  %-40s %s\n' "CRD host (system):" \
    "$(systemctl is-enabled "$CRD_UNIT" 2>/dev/null) / $(systemctl is-active "$CRD_UNIT" 2>/dev/null)"
  printf '  %-40s %s\n' "RDP bridge (krdpserver):" \
    "$(usystemctl is-enabled crd-mirror.service 2>/dev/null) / $(usystemctl is-active crd-mirror.service 2>/dev/null)"
  printf '  %-40s %s\n' "On-demand watcher:" \
    "$(usystemctl is-enabled crd-ondemand.service 2>/dev/null) / $(usystemctl is-active crd-ondemand.service 2>/dev/null)"
  printf '  %-40s %s\n' "Stream (PAUSE gate):" "$([ -f "$CONF_DIR/PAUSE" ] && echo 'OFF (idle)' || echo 'ON (streaming)')"
  printf '  %-40s %s\n' "force-on:" "$([ -f "$CONF_DIR/FORCE_ON" ] && echo YES || echo no)"
  printf '  %-40s %s\n' "viewer (xfreerdp3):" \
    "$(vcount=$(uruncmd pgrep -c -x xfreerdp3 2>/dev/null || true); echo "${vcount:-0} process(es)")"
  printf '  %-40s %s\n' "RDP loopback:" \
    "$(ss -ltn 2>/dev/null | awk -v p=":$RDP_PORT" '$4 ~ p {print "listening " $4}' | head -1)"
  printf '  %-40s %s\n' "CRD fake display:" \
    "$(pgrep -a -u "$TARGET_USER" Xvfb 2>/dev/null | grep -o '[0-9]\{3,4\}x[0-9]\{3,4\}x24' | head -1 | cut -d x -f1,2)"
  if [ -f "$CONF_DIR/PAUSE" ]; then
    note "Idle - connecting via CRD will start the stream within a few seconds."
  else
    note "Streaming the current session."
  fi
}

# ---------------------- 7. Manual stream on/off ----------------------------
force_on()  { mkdir -p "$CONF_DIR"; touch "$CONF_DIR/FORCE_ON"; ok "force-on: always streaming (use force-off to go back to automatic)."; }
force_off() { rm -f "$CONF_DIR/FORCE_ON"; ok "force-off: back to automatic (follows CRD connections)."; }

# ------------------------------- 8. Uninstall ------------------------------
do_uninstall() {
  step "Removing the mirror configuration (keeps CRD)"
  usystemctl disable --now crd-ondemand.service crd-mirror.service 2>/dev/null || true
  rm -f "$USER_SYSD/crd-mirror.service" "$USER_SYSD/crd-ondemand.service"
  usystemctl daemon-reload

  sudorun rm -f "/etc/systemd/system/${CRD_UNIT}.d/10-mirror-size.conf"
  sudorun rmdir "/etc/systemd/system/${CRD_UNIT}.d" 2>/dev/null || true
  sudorun systemctl daemon-reload

  # Restore the CRD session default (its own virtual desktop)
  local restored=""
  local cand
  for cand in "$SESSION_FILE.orig" "$SESSION_FILE.bak" "$SESSION_FILE".bak.*; do
    [ -e "$cand" ] || continue
    if ! grep -q 'crd-mirror' "$cand" 2>/dev/null; then
      cp -p "$cand" "$SESSION_FILE"
      info "Restored $SESSION_FILE from $cand"
      restored=yes
      break
    fi
  done
  if [ -z "$restored" ]; then
    cat > "$SESSION_FILE" <<'EOF'
#!/bin/bash
# Back to CRD's default Linux behaviour: its own virtual desktop
exec /usr/bin/startplasma-x11
EOF
    chmod +x "$SESSION_FILE"
    info "Restored CRD's default session (its own virtual desktop)"
  fi
  rm -rf "$CONF_DIR"

  sudorun systemctl restart "$CRD_UNIT"
  ok "Mirror removed; CRD is back to its own virtual desktop."
  note "To remove CRD completely: sudo systemctl disable --now $CRD_UNIT && yay -Rns chrome-remote-desktop"
}

# ------------------------------- 9. main -----------------------------------
CMD="${1:-install}"
case "$CMD" in
  install)
    need_sudo
    preflight
    detect_display
    install_files
    enable_services
    wait_host_ready
    step "Done"
    ok "CRD now: starts at boot + mirrors the current session + idles at ~0% CPU."
    note "Connect from a phone/other machine at https://remotedesktop.google.com/access"
    do_status
    ;;
  status)    do_status ;;
  force-on)  force_on ;;
  force-off) force_off ;;
  uninstall) need_sudo; do_uninstall ;;
  *) die "Unknown command: '$CMD' (use: install | status | force-on | force-off | uninstall)" ;;
esac
