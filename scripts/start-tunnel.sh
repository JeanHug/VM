#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CLOUDFLARE TUNNEL SÉCURISÉ & AUTO-RÉTABLISSEMENT"
echo "=================================================="

if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

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

# Détermination de la cible Webtop
TARGET_ORIGIN="https://127.0.0.1:3001"
if [ -f /tmp/webtop_target_url.txt ]; then
  DETECTED=$(cat /tmp/webtop_target_url.txt)
  if [ -n "$DETECTED" ]; then
    TARGET_ORIGIN="$DETECTED"
  fi
fi

echo "Origine locale ciblée : $TARGET_ORIGIN"

start_tunnel_process() {
  pkill -9 -f cloudflared 2>/dev/null || true
  sleep 1
  rm -f /tmp/cloudflared_quick.log

  echo "[$(date +'%T')] Lancement de cloudflared vers $TARGET_ORIGIN (avec --no-tls-verify)..."
  nohup cloudflared tunnel \
    --no-tls-verify \
    --protocol http2 \
    --edge-ip-version 4 \
    --retries 10 \
    --url "$TARGET_ORIGIN" > /tmp/cloudflared_quick.log 2>&1 &
    
  QUICK_PID=$!
  echo "$QUICK_PID" > /tmp/cloudflared_quick.pid
  echo "Processus cloudflared démarré (PID: $QUICK_PID)"

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
    echo "⚠️ Impossible d'extraire l'URL trycloudflare :"
    head -n 25 /tmp/cloudflared_quick.log || true
  fi
}

# Premier lancement
start_tunnel_process

# Watchdog d'auto-rétablissement en continu
cat << 'WATCHDOG_SCRIPT' > /tmp/cf_watchdog.sh
#!/usr/bin/env bash

FAIL_COUNT=0

while true; do
  sleep 15
  
  QUICK_PID=$(cat /tmp/cloudflared_quick.pid 2>/dev/null || true)
  URL=$(cat /tmp/vm_public_url.txt 2>/dev/null || true)
  TARGET_ORIGIN=$(cat /tmp/webtop_target_url.txt 2>/dev/null || echo "https://127.0.0.1:3001")
  
  RESTART=false

  if [ -z "$QUICK_PID" ] || ! ps -p "$QUICK_PID" > /dev/null 2>&1; then
    echo "[WATCHDOG $(date +'%T')] cloudflared s'est arrêté !"
    RESTART=true
  fi

  if [ "$RESTART" = false ] && [ -n "$URL" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -I -w "%{http_code}" --max-time 8 "$URL" || echo "000")
    # 502, 504, 530 ou 000
    if [ "$HTTP_CODE" = "502" ] || [ "$HTTP_CODE" = "504" ] || [ "$HTTP_CODE" = "530" ] || [ "$HTTP_CODE" = "000" ]; then
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      echo "[WATCHDOG $(date +'%T')] Échec HTTP $HTTP_CODE sur $URL ($FAIL_COUNT/3)"
      if [ "$FAIL_COUNT" -ge 3 ]; then
        echo "[WATCHDOG $(date +'%T')] Bad Gateway détecté sur $URL ! Relance automatique du tunnel..."
        RESTART=true
        FAIL_COUNT=0
      fi
    else
      FAIL_COUNT=0
    fi
  fi

  if [ "$RESTART" = true ]; then
    echo "[WATCHDOG $(date +'%T')] Redémarrage de cloudflared vers $TARGET_ORIGIN..."
    pkill -9 -f cloudflared 2>/dev/null || true
    sleep 2
    rm -f /tmp/cloudflared_quick.log

    nohup cloudflared tunnel \
      --no-tls-verify \
      --protocol http2 \
      --edge-ip-version 4 \
      --retries 10 \
      --url "$TARGET_ORIGIN" > /tmp/cloudflared_quick.log 2>&1 &
      
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
      echo "[WATCHDOG $(date +'%T')] Nouveau tunnel opérationnel : $NEW_URL"
      
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
echo " Watchdog Cloudflare opérationnel (PID: $WATCHDOG_PID)."
