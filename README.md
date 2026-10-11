# setup-chrome-remote-destop-arch
Script setup Chrome Remote Desktop for your ArchOS base.

```
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

```
