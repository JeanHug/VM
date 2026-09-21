#!/usr/bin/env bash
set -e

RELAY_CYCLE="${RELAY_CYCLE:-1}"
SYNC_INTERVAL_MINS="${SYNC_INTERVAL_MINS:-10}"
RELAY_TRIGGER_MINS="${RELAY_TRIGGER_MINS:-315}"      # 5h15 = 315 minutes
RELAY_SHUTDOWN_MINS="${RELAY_SHUTDOWN_MINS:-345}"    # 5h45 = 345 minutes

echo "=================================================="
echo "    ORCHESTRATEUR DE RELAIS DE LA VM WEB LINUX    "
echo "=================================================="
echo "Cycle actuel          : $RELAY_CYCLE"
echo "Sauvegarde toutes les   : $SYNC_INTERVAL_MINS minutes"
echo "Déclenchement relais   : à $RELAY_TRIGGER_MINS minutes (5h15)"
echo "Arrêt propre          : à $RELAY_SHUTDOWN_MINS minutes (5h45)"
echo "=================================================="

START_TIME=$(date +%s)
NEXT_BACKUP_TIME=$(( START_TIME + SYNC_INTERVAL_MINS * 60 ))
TRIGGER_TIME=$(( START_TIME + RELAY_TRIGGER_MINS * 60 ))
SHUTDOWN_TIME=$(( START_TIME + RELAY_SHUTDOWN_MINS * 60 ))
RELAY_TRIGGERED=false

# Gestion de l'arrêt propre et passation de relais
cleanup_and_exit() {
  echo ""
  echo "=== [RELAY HANDOFF] Début de la passation de relais ==="
  echo "1. Sauvegarde delta finale des données..."
  ./scripts/backup-sync.sh backup || true
  
  echo "2. Arrêt du watchdog et du tunnel Cloudflare..."
  if [ -f /tmp/cf_watchdog.pid ]; then
    kill $(cat /tmp/cf_watchdog.pid) 2>/dev/null || true
  fi
  pkill -9 -f cloudflared 2>/dev/null || true
  
  echo "3. Arrêt du conteneur de bureau..."
  docker stop webtop 2>/dev/null || true
  
  echo " Handshake de passation terminé. Fin du cycle $RELAY_CYCLE."
  exit 0
}

trap cleanup_and_exit SIGTERM SIGINT

while true; do
  NOW=$(date +%s)
  ELAPSED_SECS=$(( NOW - START_TIME ))
  ELAPSED_MINS=$(( ELAPSED_SECS / 60 ))
  
  # 1. Sauvegarde périodique
  if [ "$NOW" -ge "$NEXT_BACKUP_TIME" ]; then
    echo "[$(date +'%T')] Exécution de la sauvegarde programmée (Uptime: ${ELAPSED_MINS}m)..."
    ./scripts/backup-sync.sh backup || echo "⚠️ Erreur non-bloquante lors de la sauvegarde"
    NEXT_BACKUP_TIME=$(( NOW + SYNC_INTERVAL_MINS * 60 ))
  fi

  # 2. Déclenchement du runner suivant (à T+5h15)
  if [ "$NOW" -ge "$TRIGGER_TIME" ] && [ "$RELAY_TRIGGERED" = false ]; then
    NEXT_CYCLE=$(( RELAY_CYCLE + 1 ))
    echo ""
    echo "=================================================="
    echo "⏰ HEURE DU RELAIS ATTEINTE (${ELAPSED_MINS} min) !"
    echo "Déclenchement automatique du cycle suivant ($NEXT_CYCLE)..."
    echo "=================================================="
    
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
    
    DISPATCH_HTTP_CODE=$(curl -s -o /tmp/dispatch_res.json -w "%{http_code}" \
      -X POST \
      -H "Accept: application/vnd.github.v3+json" \
      -H "Authorization: Bearer ${GH_TOKEN}" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/actions/workflows/vm-relay.yml/dispatches" \
      -d "$PAYLOAD")
      
    if [ "$DISPATCH_HTTP_CODE" = "204" ]; then
      echo " Runner suivant (Cycle $NEXT_CYCLE) déclenché avec succès !"
      RELAY_TRIGGERED=true
    else
      echo "⚠️ Échec du déclenchement du runner suivant (HTTP $DISPATCH_HTTP_CODE):"
      cat /tmp/dispatch_res.json 2>/dev/null || true
    fi
  fi

  # 3. Arrêt propre et passation à 5h45
  if [ "$NOW" -ge "$SHUTDOWN_TIME" ]; then
    echo ""
    echo "⏰ Uptime maximum atteint (${ELAPSED_MINS} min). Exécution de la passation de relais."
    cleanup_and_exit
  fi

  sleep 30
done
