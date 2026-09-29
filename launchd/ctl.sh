#!/bin/sh
# Stop, start, restart, and inspect KanAI AFM Bridge after launchd/install.sh.
# Usage: sh launchd/ctl.sh {start|stop|restart|status|logs|awake on|awake off}
#   stop     unloads the agents until start, restart, or the next login
#   awake on keeps the Mac from idle sleeping while the bridge agent is loaded (opt in, off by default)
UID_N="$(id -u)"
AGENTS="$HOME/Library/LaunchAgents"
BRIDGE=com.christefano.kanai-afm-bridge
TUNNEL=com.christefano.kanai-afm-bridge-tunnel
AWAKE=com.christefano.kanai-afm-bridge-awake
ALL="$BRIDGE $TUNNEL $AWAKE"

loaded() { launchctl print "gui/$UID_N/$1" >/dev/null 2>&1; }

start_all() {
  for l in $ALL; do
    [ -f "$AGENTS/$l.plist" ] || continue
    loaded "$l" || launchctl bootstrap "gui/$UID_N" "$AGENTS/$l.plist"
  done
}
stop_all() {
  for l in $AWAKE $TUNNEL $BRIDGE; do
    if loaded "$l"; then
      launchctl bootout "gui/$UID_N/$l"
      n=0; while loaded "$l" && [ $n -lt 20 ]; do sleep 0.5; n=$((n+1)); done
    fi
  done
  return 0
}

case "$1" in
  start)   [ -f "$AGENTS/$BRIDGE.plist" ] || { echo "Not installed. Run: sh launchd/install.sh"; exit 1; }
           start_all; sh "$0" status ;;
  stop)    stop_all; echo "stopped" ;;
  restart) stop_all; start_all; sleep 2; sh "$0" status ;;
  status)
    for l in $ALL; do
      if loaded "$l"; then echo "$l: loaded (pid $(launchctl list | awk -v l="$l" '$3==l{print $1}'))"
      elif [ -f "$AGENTS/$l.plist" ]; then echo "$l: installed, stopped"
      else echo "$l: not installed"; fi
    done
    P="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:KANAI_AFM_BRIDGE_PORT' "$AGENTS/$BRIDGE.plist" 2>/dev/null || echo 11437)"
    curl -s -m 5 "http://127.0.0.1:$P/v1/models" >/dev/null && echo "bridge answers on 127.0.0.1:$P" || echo "bridge does not answer on 127.0.0.1:$P" ;;
  logs)    tail -n 40 "$HOME/Library/Logs/kanai-afm-bridge.log"; [ -f "$HOME/Library/Logs/kanai-afm-bridge-tunnel.log" ] && { echo "--- tunnel"; tail -n 10 "$HOME/Library/Logs/kanai-afm-bridge-tunnel.log"; } ;;
  awake)
    case "$2" in
      on)  cat > "$AGENTS/$AWAKE.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AWAKE</string>
    <key>ProgramArguments</key>
    <array><string>/usr/bin/caffeinate</string><string>-i</string></array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
PL
           loaded "$AWAKE" || launchctl bootstrap "gui/$UID_N" "$AGENTS/$AWAKE.plist"; echo "keep-awake on (idle sleep blocked until: awake off, or stop)" ;;
      off) launchctl bootout "gui/$UID_N/$AWAKE" 2>/dev/null; rm -f "$AGENTS/$AWAKE.plist"; echo "keep-awake off" ;;
      *)   echo "Usage: sh launchd/ctl.sh awake on|off"; exit 1 ;;
    esac ;;
  *) echo "Usage: sh launchd/ctl.sh {start|stop|restart|status|logs|awake on|awake off}"; exit 1 ;;
esac
