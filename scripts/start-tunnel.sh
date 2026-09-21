#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CLOUDFLARE PRODUCTION TUNNEL AVEC AUTO-HEAL   "
echo "=================================================="

# 1. Vérifier ou installer cloudflared
if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

# Fonction de publication sur GitHub
publish_url_to_github() {
  PUBLIC_URL="$1"
  echo "$PUBLIC_URL" > /tmp/vm_public_url.txt
  echo "=================================================="
  echo " NOUVELLE URL DU BUREAU WEB : $PUBLIC_URL"
  echo "=================================================="
  
  if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ]; then
    echo "Publication sur GitHub (branche tunnel-url)..."
    TMP_URL_REPO=$(mktemp -d)
    cd "$TMP_URL_REPO"
    git init
    git config user.name "Cloudflare-Auto-Tunnel"
    git config user.email "bot@vm.cloudflare.local"
    git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
    git checkout -B tunnel-url
    echo "$PUBLIC_URL" > current_url.txt
    echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at.txt
    git add current_url.txt updated_at.txt
    git commit -m "chore(tunnel): active tunnel url update [$PUBLIC_URL]" || true
    git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
    cd /
    rm -rf "$TMP_URL_REPO"
    echo " URL enregistrée avec succès sur GitHub !"
  fi
}

RUN_TOKEN=""

# 2. Si CLOUDFLARE_TOKEN et CLOUDFLARE_ID sont présents, récupérer le vrai token d'exécution natif (eyJh...)
if [ -n "$CLOUDFLARE_TOKEN" ] && [ -n "$CLOUDFLARE_ID" ]; then
  echo "Récupération du token d'exécution du Named Tunnel depuis Cloudflare..."
  TUNNEL_ID="e58f3146-7b0d-41e4-bbb4-89f101de0d84"
  
  TOKEN_RES=$(curl -s -H "Authorization: Bearer $CLOUDFLARE_TOKEN"     -H "Content-Type: application/json"     "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ID/cfd_tunnel/$TUNNEL_ID/token")
    
  RUN_TOKEN=$(echo "$TOKEN_RES" | grep -o '"result":"[^"]*"' | cut -d'"' -f4 || true)
fi

# 3. Fonction pour démarrer cloudflared
start_tunnel_process() {
  pkill -9 -f cloudflared 2>/dev/null || true
  sleep 1
  rm -f /tmp/cloudflared.log

  if [ -n "$RUN_TOKEN" ]; then
    echo "Démarrage du tunnel permanent Cloudflare avec token natif..."
    nohup cloudflared tunnel       --protocol http2       --edge-ip-version 4       run --token "$RUN_TOKEN" > /tmp/cloudflared.log 2>&1 &
    CF_PID=$!
    echo "$CF_PID" > /tmp/cloudflared.pid
    echo "Tunnel permanent lancé (PID: $CF_PID)"
  fi

  # Également lancer le Quick Tunnel en parallèle pour URL instantanée trycloudflare.com
  echo "Démarrage du proxy d'accès instantané..."
  nohup cloudflared tunnel     --protocol http2     --edge-ip-version 4     --retries 10     --url http://127.0.0.1:3000 > /tmp/cloudflared_quick.log 2>&1 &
  QUICK_PID=$!
  echo "$QUICK_PID" > /tmp/cloudflared_quick.pid
  echo "Proxy d'accès lancé (PID: $QUICK_PID)"

  FOUND_URL=""
  for i in {1..35}; do
    sleep 2
    FOUND_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared_quick.log | head -n1 || true)
    if [ -n "$FOUND_URL" ]; then
      break
    fi
  done

  if [ -n "$FOUND_URL" ]; then
    publish_url_to_github "$FOUND_URL"
  else
    echo "⚠️ URL non trouvée dans les logs. Contenu :"
    head -n 20 /tmp/cloudflared_quick.log || true
  fi
}

# Lancement initial
start_tunnel_process

# 4. Watchdog automatique en continu
cat << 'WATCHDOG_SCRIPT' > /tmp/cf_watchdog.sh
#!/usr/bin/env bash

FAIL_COUNT=0

while true; do
  sleep 20
  
  QUICK_PID=$(cat /tmp/cloudflared_quick.pid 2>/dev/null || true)
  URL=$(cat /tmp/vm_public_url.txt 2>/dev/null || true)
  
  RESTART=false

  if [ -z "$QUICK_PID" ] || ! ps -p "$QUICK_PID" > /dev/null 2>&1; then
    echo "[WATCHDOG $(date +'%T')] cloudflared s'est arrêté !"
    RESTART=true
  fi

  if [ "$RESTART" = false ] && [ -n "$URL" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -I -w "%{http_code}" --max-time 8 "$URL" || echo "000")
    if [ "$HTTP_CODE" = "502" ] || [ "$HTTP_CODE" = "504" ] || [ "$HTTP_CODE" = "530" ] || [ "$HTTP_CODE" = "000" ]; then
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      echo "[WATCHDOG $(date +'%T')] Test HTTP: $HTTP_CODE (échec $FAIL_COUNT/3)"
      if [ "$FAIL_COUNT" -ge 3 ]; then
        echo "[WATCHDOG $(date +'%T')] Déconnexion confirmée. Redémarrage automatique du tunnel..."
        RESTART=true
        FAIL_COUNT=0
      fi
    else
      FAIL_COUNT=0
    fi
  fi

  if [ "$RESTART" = true ]; then
    echo "[WATCHDOG $(date +'%T')] Redémarrage en cours..."
    pkill -9 -f cloudflared 2>/dev/null || true
    sleep 2
    
    nohup cloudflared tunnel       --protocol http2       --edge-ip-version 4       --retries 10       --url http://127.0.0.1:3000 > /tmp/cloudflared_quick.log 2>&1 &
    NEW_PID=$!
    echo "$NEW_PID" > /tmp/cloudflared_quick.pid

    NEW_URL=""
    for j in {1..35}; do
      sleep 2
      NEW_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared_quick.log | head -n1 || true)
      if [ -n "$NEW_URL" ]; then
        break
      fi
    done

    if [ -n "$NEW_URL" ]; then
      echo "$NEW_URL" > /tmp/vm_public_url.txt
      echo "[WATCHDOG $(date +'%T')] Nouvelle URL : $NEW_URL"
      
      if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ]; then
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        git init
        git config user.name "Cloudflare-Auto-Tunnel"
        git config user.email "bot@vm.cloudflare.local"
        git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
        git checkout -B tunnel-url
        echo "$NEW_URL" > current_url.txt
        echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at.txt
        git add current_url.txt updated_at.txt
        git commit -m "chore(watchdog): auto-renew dropped tunnel [$NEW_URL]" || true
        git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
        cd /
        rm -rf "$TMP_DIR"
      fi
    fi
    FAIL_COUNT=0
  fi
done
WATCHDOG_SCRIPT

chmod +x /tmp/cf_watchdog.sh
nohup /tmp/cf_watchdog.sh > /tmp/cf_watchdog.log 2>&1 &
WATCHDOG_PID=$!
echo "$WATCHDOG_PID" > /tmp/cf_watchdog.pid
echo " Système Cloudflare & Watchdog opérationnel."
