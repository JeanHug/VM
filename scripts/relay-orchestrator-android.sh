#!/usr/bin/env bash
set -e

RELAY_CYCLE="${RELAY_CYCLE:-1}"
SESSION_ID="${SESSION_ID:-session-android}"
SYNC_INTERVAL_MINS="${SYNC_INTERVAL_MINS:-10}"
RELAY_TRIGGER_MINS="${RELAY_TRIGGER_MINS:-315}"
RELAY_SHUTDOWN_MINS="${RELAY_SHUTDOWN_MINS:-345}"

echo "=================================================="
echo "    ORCHESTRATEUR DE RELAIS VM ANDROID 13        "
echo "=================================================="
echo "Cycle actuel       : $RELAY_CYCLE"
echo "ID de session      : $SESSION_ID"
echo "Intervalle sync    : ${SYNC_INTERVAL_MINS}m"
echo "Déclencheur relais : ${RELAY_TRIGGER_MINS}m"
echo "Arrêt programmé    : ${RELAY_SHUTDOWN_MINS}m"
echo "=================================================="

START_TIME=$(date +%s)
NEXT_SYNC=$((START_TIME + SYNC_INTERVAL_MINS * 60))
RELAY_TRIGGER_TIME=$((START_TIME + RELAY_TRIGGER_MINS * 60))
SHUTDOWN_TIME=$((START_TIME + RELAY_SHUTDOWN_MINS * 60))

RELAY_TRIGGERED=false

trigger_next_relay() {
  NEXT_CYCLE=$((RELAY_CYCLE + 1))
  echo "=================================================="
  echo "🚀 LANCEMENT DU CYCLE DE RELAIS ANDROID N° $NEXT_CYCLE"
  echo "=================================================="

  if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ]; then
    # Synchronisation immédiate avant lancement du nouveau runner
    ./scripts/backup-sync-android.sh backup "$SESSION_ID" || true

    curl -s -X POST \
      -H "Authorization: Bearer $GH_TOKEN" \
      -H "Accept: application/vnd.github.v3+json" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/vm-android.yml/dispatches" \
      -d "{\"ref\":\"main\",\"inputs\":{\"relay_cycle\":\"$NEXT_CYCLE\",\"session_id\":\"$SESSION_ID\",\"relay_trigger_mins\":\"$RELAY_TRIGGER_MINS\",\"relay_shutdown_mins\":\"$RELAY_SHUTDOWN_MINS\"}}"
    
    echo " Relais Android cycle $NEXT_CYCLE déclenché avec succès !"
    RELAY_TRIGGERED=true
  else
    echo "⚠️ Pas de GH_TOKEN pour déclencher le cycle suivant."
  fi
}

# Boucle principale
while true; do
  NOW=$(date +%s)
  ELAPSED_MINS=$(( (NOW - START_TIME) / 60 ))

  # 1. Vérification de l'arrêt
  if [ "$NOW" -ge "$SHUTDOWN_TIME" ]; then
    echo "=== Heure d'arrêt atteinte (${RELAY_SHUTDOWN_MINS}m) ==="
    ./scripts/backup-sync-android.sh backup "$SESSION_ID" || true
    echo "Cycle $RELAY_CYCLE terminé proprement."
    exit 0
  fi

  # 2. Déclenchement du relais si l'heure est venue
  if [ "$NOW" -ge "$RELAY_TRIGGER_TIME" ] && [ "$RELAY_TRIGGERED" = false ]; then
    trigger_next_relay
  fi

  # 3. Synchronisation périodique des données
  if [ "$NOW" -ge "$NEXT_SYNC" ]; then
    echo "[$(date +'%H:%M:%S')] Synchronisation périodique des données Android..."
    ./scripts/backup-sync-android.sh backup "$SESSION_ID" || true
    NEXT_SYNC=$((NOW + SYNC_INTERVAL_MINS * 60))
  fi

  # 4. Vérification que le tunnel reste actif
  if ! pgrep -f cloudflared > /dev/null; then
    echo "⚠️ Cloudflared tombé, relance..."
    ./scripts/start-tunnel-android.sh || true
  fi

  sleep 30
done
