#!/bin/sh
# Stops and removes the KanAI AFM Bridge LaunchAgents, including the optional keep-awake agent.
UID_N="$(id -u)"
for label in com.christefano.kanai-afm-bridge-awake com.christefano.kanai-afm-bridge-tunnel com.christefano.kanai-afm-bridge; do
  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
  echo "removed $label"
done
