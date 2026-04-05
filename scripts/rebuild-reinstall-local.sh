#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="/home/murphy/plank-reloaded"
BUILD_DIR="$REPO_DIR/build"
LOCAL_LIB_DIR="/usr/local/lib/x86_64-linux-gnu"
LOCAL_DOCKLETS_DIR="$LOCAL_LIB_DIR/plank/docklets"
SUDO=""

if [[ "${EUID}" -ne 0 ]]; then
  SUDO="sudo"
fi

cd "$REPO_DIR"

echo "[1/5] Building project..."
meson compile -C "$BUILD_DIR"

echo "[2/5] Installing core libplank to /usr/local..."
"$SUDO" install -d "$LOCAL_LIB_DIR"
"$SUDO" install -m 755 "$BUILD_DIR/lib/libplank.so.1.0.0" "$LOCAL_LIB_DIR/libplank.so.1.0.0"
"$SUDO" ln -sf "$LOCAL_LIB_DIR/libplank.so.1.0.0" "$LOCAL_LIB_DIR/libplank.so.1"
"$SUDO" ln -sf "$LOCAL_LIB_DIR/libplank.so.1.0.0" "$LOCAL_LIB_DIR/libplank.so"

echo "[3/5] Installing built docklets to /usr/local..."
"$SUDO" install -d "$LOCAL_DOCKLETS_DIR"
for docklet_so in \
  "Tray/libdocklet-tray.so" \
  "Clock/libdocklet-clock.so" \
  "NowPlaying/libdocklet-nowplaying.so"; do
  if [[ -f "$BUILD_DIR/docklets/$docklet_so" ]]; then
    "$SUDO" install -m 755 "$BUILD_DIR/docklets/$docklet_so" "$LOCAL_DOCKLETS_DIR/$(basename "$docklet_so")"
  fi
done

echo "[4/5] Refreshing linker cache..."
"$SUDO" ldconfig

echo "[5/5] Restarting Plank..."
pkill plank || true
nohup /usr/local/bin/plank >/tmp/plank-restart.log 2>&1 &
sleep 1

echo "Done."
echo "Plank PID(s):"
pgrep -a plank || true
echo "Plank binary:"
command -v plank || true
