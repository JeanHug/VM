#!/usr/bin/env bash
set -e

RELAY_CYCLE="${RELAY_CYCLE:-1}"
SYNC_INTERVAL_MINS="${SYNC_INTERVAL_MINS:-10}"
RELAY_TRIGGER_MINS="${RELAY_TRIGGER_MINS:-315}"
RELAY_SHUTDOWN_MINS="${RELAY_SHUTDOWN_MINS:-345}"

echo "=================================================="
echo "    ORCHESTRATEUR DE RELAIS VM SMARTPHONE ANDROID  "
echo "=================================================="

START_TIME=$(date +%s)
TRIGGER_TIME=$(( START_TIME + RELAY_TRIGGER_MINS * 60 ))
SHUTDOWN_TIME=$(( START_TIME + RELAY_SHUTDOWN_MINS * 60 ))
RELAY_TRIGGERED=false
CONSECUTIVE_TUNNEL_FAILS=0

cleanup_and_exit() {
  echo "Arrêt ordonné de la VM Android..."
  pkill -f cloudflared || true
  pkill -f "nokey@localhost.run" || true
  docker stop redroid ws_scrcpy 2>/dev/null || true
  exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

while true; do
  NOW=$(date +%s)

  # Relais automatique vers le prochain runner GitHub Android
  if [ "$NOW" -ge "$TRIGGER_TIME" ] && [ "$RELAY_TRIGGERED" = false ]; then
    NEXT_CYCLE=$(( RELAY_CYCLE + 1 ))
    echo "Lancement du relais Android vers le cycle $NEXT_CYCLE"
    
    PAYLOAD=$(cat <<JSON
{
  "ref": "main",
  "inputs": {
    "relay_cycle": "$NEXT_CYCLE",
    "session_id": "${SESSION_ID:-session-android}"
  }
}
JSON
)
    curl -s -X POST \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/vm-android.yml/dispatches" \
      -d "$PAYLOAD" || true
    RELAY_TRIGGERED=true
  fi

  if [ "$NOW" -ge "$SHUTDOWN_TIME" ]; then
    cleanup_and_exit
  fi

  sleep 25
done
