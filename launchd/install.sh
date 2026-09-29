#!/bin/sh
# Installs KanAI AFM Bridge (and optionally its SSH tunnel) as per-user LaunchAgents.
# Usage: sh launchd/install.sh                  bridge only
#        sh launchd/install.sh user@host        bridge and reverse tunnel to that host
# Optional environment variables:
#   KANAI_AFM_BRIDGE_PORT   bridge and tunnel port on both ends (default 11437)
#   KANAI_TUNNEL_SSH_PORT   SSH port of the server (default 22)
#   KANAI_TUNNEL_KEY        private key for the tunnel (default ~/.ssh/kanai-tunnel)
#   KANAI_AFM_BRIDGE_TOKEN  optional bearer token the bridge requires (default none, no authentication)
set -e
DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
UID_N="$(id -u)"
PORT="${KANAI_AFM_BRIDGE_PORT:-11437}"
SSH_PORT="${KANAI_TUNNEL_SSH_PORT:-22}"
KEY="${KANAI_TUNNEL_KEY:-$HOME/.ssh/kanai-tunnel}"
TOKEN="${KANAI_AFM_BRIDGE_TOKEN:-}"
case "$TOKEN" in *[!A-Za-z0-9._~-]*) echo "Token may use only letters, digits, and . _ ~ -"; exit 1;; esac
case "$PORT$SSH_PORT" in *[!0-9]*|"") echo "Ports must be numbers."; exit 1;; esac
[ -x "$DIR/kanai-afm-bridge" ] || { echo "Build first: sh $DIR/build.sh"; exit 1; }
mkdir -p "$AGENTS" "$HOME/Library/Logs"

install_agent() {
  label="$1"
  dest="$AGENTS/$label.plist"
  sed -e "s|__BIN__|$DIR/kanai-afm-bridge|g" -e "s|__HOME__|$HOME|g" -e "s|__PORT__|$PORT|g" \
      -e "s|__SSH_PORT__|$SSH_PORT|g" -e "s|__KEY__|$KEY|g" -e "s|__TUNNEL_TARGET__|${TARGET:-}|g" -e "s|__TOKEN__|$TOKEN|g" \
    "$DIR/launchd/$label.plist" > "$dest"
  chmod 600 "$dest"
  plutil -lint "$dest" >/dev/null
  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  n=0; while launchctl print "gui/$UID_N/$label" >/dev/null 2>&1 && [ $n -lt 20 ]; do sleep 0.5; n=$((n+1)); done
  launchctl bootstrap "gui/$UID_N" "$dest"
  echo "loaded $label"
}

install_agent com.christefano.kanai-afm-bridge

if [ -n "${1:-}" ]; then
  TARGET="$1"
  [ -f "$KEY" ] || { echo "Missing $KEY (see INSTALL.md, section SSH tunnel that survives a restart)."; exit 1; }
  install_agent com.christefano.kanai-afm-bridge-tunnel
fi
launchctl list | grep kanai-afm-bridge || true
echo "Stop, start, and restart with: sh $DIR/launchd/ctl.sh {start|stop|restart|status|logs}"
