#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION DU TUNNEL CLOUDFLARE AVEC WATCHDOG"
echo "=================================================="

# 1. Télécharger cloudflared si non présent
if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

# Fonction de publication sur la branche tunnel-url du repo GitHub
publish_url_to_github() {
  PUBLIC_URL="$1"
  echo "$PUBLIC_URL" > /tmp/vm_public_url.txt
  echo "=================================================="
  echo " NOUVELLE URL DU BUREAU WEB : $PUBLIC_URL"
  echo "=================================================="
  
  if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ]; then
    echo "Publication automatique de l'URL sur GitHub (branche tunnel-url)..."
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

# Fonction pour lancer un Quick Tunnel et extraire l'URL
launch_quick_tunnel() {
  echo "[$(date +'%T')] Lancement d'un nouveau tunnel Cloudflare Quick Tunnel..."
  pkill -9 -f cloudflared 2>/dev/null || true
  sleep 1

  nohup cloudflared tunnel --url http://127.0.0.1:3000 > /tmp/cloudflared_quick.log 2>&1 &
  CF_PID=$!
  echo "$CF_PID" > /tmp/cloudflared_quick.pid
  echo "Processus cloudflared lancé (PID: $CF_PID)"

  FOUND_URL=""
  for i in {1..25}; do
    sleep 2
    FOUND_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared_quick.log | head -n1 || true)
    if [ -n "$FOUND_URL" ]; then
      break
    fi
  done

  if [ -n "$FOUND_URL" ]; then
    publish_url_to_github "$FOUND_URL"
  else
    echo "⚠️ Impossible de capturer l'URL trycloudflare dans les logs :"
    cat /tmp/cloudflared_quick.log || true
  fi
}

# Premier lancement
launch_quick_tunnel

# 2. Création et lancement du Watchdog permanent en arrière-plan
cat << 'WATCHDOG_SCRIPT' > /tmp/cf_watchdog.sh
#!/usr/bin/env bash

FAIL_COUNT=0

while true; do
  sleep 15
  
  CF_PID=$(cat /tmp/cloudflared_quick.pid 2>/dev/null || true)
  URL=$(cat /tmp/vm_public_url.txt 2>/dev/null || true)
  
  NEEDS_RESTART=false

  # Test 1 : Le processus cloudflared est-il vivant ?
  if [ -z "$CF_PID" ] || ! ps -p "$CF_PID" > /dev/null 2>&1; then
    echo "[WATCHDOG $(date +'%T')] Le processus cloudflared s'est arrêté !"
    NEEDS_RESTART=true
  fi

  # Test 2 : Si le processus est vivant et qu'on a une URL, tester la joignabilité HTTP
  if [ "$NEEDS_RESTART" = false ] && [ -n "$URL" ]; then
    HTTP_CODE=$(curl -s -o /dev/null -I -w "%{http_code}" --max-time 8 "$URL" || echo "000")
    # Si le code est 502 (Bad Gateway côté tunnel fermé), 504, 530 ou 000 (timeout de connexion)
    if [ "$HTTP_CODE" = "502" ] || [ "$HTTP_CODE" = "504" ] || [ "$HTTP_CODE" = "530" ] || [ "$HTTP_CODE" = "000" ]; then
      FAIL_COUNT=$(( FAIL_COUNT + 1 ))
      echo "[WATCHDOG $(date +'%T')] Échec HTTP ($HTTP_CODE) sur $URL (Échec $FAIL_COUNT/3)"
      if [ "$FAIL_COUNT" -ge 3 ]; then
        echo "[WATCHDOG $(date +'%T')] Tunnel mort détecté après 3 échecs consécutifs ! Relance automatique..."
        NEEDS_RESTART=true
        FAIL_COUNT=0
      fi
    else
      FAIL_COUNT=0
    fi
  fi

  if [ "$NEEDS_RESTART" = true ]; then
    echo "[WATCHDOG $(date +'%T')] Redémarrage immédiat d'un nouveau tunnel..."
    pkill -9 -f cloudflared 2>/dev/null || true
    sleep 2
    nohup cloudflared tunnel --url http://127.0.0.1:3000 > /tmp/cloudflared_quick.log 2>&1 &
    NEW_PID=$!
    echo "$NEW_PID" > /tmp/cloudflared_quick.pid

    NEW_URL=""
    for j in {1..25}; do
      sleep 2
      NEW_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared_quick.log | head -n1 || true)
      if [ -n "$NEW_URL" ]; then
        break
      fi
    done

    if [ -n "$NEW_URL" ]; then
      echo "$NEW_URL" > /tmp/vm_public_url.txt
      echo "[WATCHDOG $(date +'%T')] Nouveau tunnel rétabli : $NEW_URL"
      
      # Mise à jour sur GitHub
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
        echo "[WATCHDOG $(date +'%T')] URL mise à jour sur GitHub !"
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
echo " Watchdog permanent de tunnel activé (PID: $WATCHDOG_PID). Surveillance continue 24/7."
