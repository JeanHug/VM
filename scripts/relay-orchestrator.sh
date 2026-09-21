#!/usr/bin/env bash
set -e

RELAY_CYCLE="${RELAY_CYCLE:-1}"
SYNC_INTERVAL_MINS="${SYNC_INTERVAL_MINS:-10}"
RELAY_TRIGGER_MINS="${RELAY_TRIGGER_MINS:-315}"
RELAY_SHUTDOWN_MINS="${RELAY_SHUTDOWN_MINS:-345}"

echo "=================================================="
echo "    ORCHESTRATEUR DE RELAIS DE LA VM WEB LINUX    "
echo "=================================================="

START_TIME=$(date +%s)
NEXT_BACKUP_TIME=$(( START_TIME + SYNC_INTERVAL_MINS * 60 ))
TRIGGER_TIME=$(( START_TIME + RELAY_TRIGGER_MINS * 60 ))
SHUTDOWN_TIME=$(( START_TIME + RELAY_SHUTDOWN_MINS * 60 ))
RELAY_TRIGGERED=false

cleanup_and_exit() {
  echo "Arrêt ordonné..."
  ./scripts/backup-sync.sh backup || true
  pkill -f pinggy || true
  pkill -f localhost.run || true
  pkill -f cloudflared || true
  docker stop webtop || true
  exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

while true; do
  NOW=$(date +%s)
  ELAPSED_MINS=$(( (NOW - START_TIME) / 60 ))
  
  # Sauvegarde périodique
  if [ "$NOW" -ge "$NEXT_BACKUP_TIME" ]; then
    echo "[$(date +'%T')] Sauvegarde périodique..."
    ./scripts/backup-sync.sh backup || true
    NEXT_BACKUP_TIME=$(( NOW + SYNC_INTERVAL_MINS * 60 ))
  fi

  # Relais à 5h15
  if [ "$NOW" -ge "$TRIGGER_TIME" ] && [ "$RELAY_TRIGGERED" = false ]; then
    NEXT_CYCLE=$(( RELAY_CYCLE + 1 ))
    echo "Lancement du relais vers le cycle $NEXT_CYCLE"
    PAYLOAD=$(cat <<JSON
{
  "ref": "main",
  "inputs": {
    "relay_cycle": "$NEXT_CYCLE",
    "session_id": "${SESSION_ID:-session-main}"
  }
}
JSON
)
    curl -s -X POST \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/vm-relay.yml/dispatches" \
      -d "$PAYLOAD" || true
    RELAY_TRIGGERED=true
  fi

  if [ "$NOW" -ge "$SHUTDOWN_TIME" ]; then
    cleanup_and_exit
  fi

  sleep 30
done
