#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CLOUDFLARE TUNNEL PRO AVEC AUTO-HEAL WATCHDOG "
echo "=================================================="

# 1. Vérification / Installation de cloudflared
if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

# Publication de l'URL courante sur la branche tunnel-url du repo GitHub
publish_url_to_github() {
  PUBLIC_URL="$1"
  echo "$PUBLIC_URL" > /tmp/vm_public_url.txt
  echo "=================================================="
  echo " NOUVELLE URL ACTIVE DU BUREAU WEB : $PUBLIC_URL"
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

# Lancer un tunnel avec paramètres optimisés
start_cloudflared_process() {
  echo "[$(date +'%T')] Lancement de cloudflared (HTTP/2 multiplexing + keepalive)..."
  pkill -9 -f cloudflared 2>/dev/null || true
  sleep 1
  rm -f /tmp/cloudflared.log

  # --protocol http2 évite les coupures QUIC/UDP récurrentes sur les runners GitHub Actions
  nohup cloudflared tunnel     --protocol http2     --edge-ip-version 4     --retries 10     --url http://127.0.0.1:3000 > /tmp/cloudflared.log 2>&1 &
    
  CF_PID=$!
  echo "$CF_PID" > /tmp/cloudflared.pid
  echo "cloudflared démarré avec PID: $CF_PID"

  EXTRACTED_URL=""
  for i in {1..30}; do
    sleep 2
    EXTRACTED_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n1 || true)
    if [ -n "$EXTRACTED_URL" ]; then
      break
    fi
  done

  if [ -n "$EXTRACTED_URL" ]; then
    publish_url_to_github "$EXTRACTED_URL"
  else
    echo "⚠️ Impossible de trouver l'URL dans les logs :"
    head -n 25 /tmp/cloudflared.log || true
  fi
}

# Premier lancement
start_cloudflared_process

# 2. Lancement du Watchdog d'auto-rétablissement en arrière-plan
cat << 'WATCHDOG_SCRIPT' > /tmp/cf_watchdog.sh
#!/usr/bin/env bash

FAIL_COUNT=0

while true; do
  sleep 15
  
  CF_PID=$(cat /tmp/cloudflared.pid 2>/dev/null || true)
  URL=$(cat /tmp/vm_public_url.txt 2>/dev/null || true)
  
  NEED_RESTART=false

  # 1. Vérifier si le processus est mort
  if [ -z "$CF_PID" ] || ! ps -p "$CF_PID" > /dev/null 2>&1; then
    echo "[WATCHDOG $(date +'%T')] Processus cloudflared mort !"
    NEED_RESTART=true
  fi

  # 2. Si le processus est vivant, tester la réponse HTTP de Webtop local
  if [ "$NEED_RESTART" = false ]; then
    LOCAL_STATUS=$(curl -s -o /dev/null -I -w "%{http_code}" --max-time 3 http://127.0.0.1:3000 || echo "000")
    if [ "$LOCAL_STATUS" = "000" ]; then
      echo "[WATCHDOG $(date +'%T')] Alerte : Webtop local ne répond pas sur le port 3000 !"
    fi
  fi

  # 3. Tester l'URL publique Cloudflare
  if [ "$NEED_RESTART" = false ] && [ -n "$URL" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -I -w "%{http_code}" --max-time 8 "$URL" || echo "000")
    if [ "$HTTP_CODE" = "502" ] || [ "$HTTP_CODE" = "504" ] || [ "$HTTP_CODE" = "530" ] || [ "$HTTP_CODE" = "000" ]; then
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      echo "[WATCHDOG $(date +'%T')] HTTP $HTTP_CODE sur $URL (Échec $FAIL_COUNT/3)"
      if [ "$FAIL_COUNT" -ge 3 ]; then
        echo "[WATCHDOG $(date +'%T')] Tunnel déconnecté (Bad Gateway répété). Auto-rétablissement immédiat !"
        NEED_RESTART=true
        FAIL_COUNT=0
      fi
    else
      FAIL_COUNT=0
    fi
  fi

  # 4. Redémarrage si nécessaire
  if [ "$NEED_RESTART" = true ]; then
    echo "[WATCHDOG $(date +'%T')] Redémarrage du tunnel en cours..."
    pkill -9 -f cloudflared 2>/dev/null || true
    sleep 2
    rm -f /tmp/cloudflared.log

    nohup cloudflared tunnel       --protocol http2       --edge-ip-version 4       --retries 10       --url http://127.0.0.1:3000 > /tmp/cloudflared.log 2>&1 &
      
    NEW_PID=$!
    echo "$NEW_PID" > /tmp/cloudflared.pid

    NEW_URL=""
    for j in {1..30}; do
      sleep 2
      NEW_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n1 || true)
      if [ -n "$NEW_URL" ]; then
        break
      fi
    done

    if [ -n "$NEW_URL" ]; then
      echo "$NEW_URL" > /tmp/vm_public_url.txt
      echo "[WATCHDOG $(date +'%T')] Nouveau tunnel actif : $NEW_URL"
      
      # Publication GitHub
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
echo " Watchdog Cloudflare activé (PID: $WATCHDOG_PID). Rétablissement automatique en cas de Bad Gateway."
