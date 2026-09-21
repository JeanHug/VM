#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CLOUDFLARE TUNNEL - INITIALISATION & TEST     "
echo "=================================================="

if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

echo "Version cloudflared : $(cloudflared --version)"

# Publication de l'URL sur GitHub
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

echo "=== VÉRIFICATION DU SERVICE WEBTOP ==="
curl -I -s http://127.0.0.1:3000/ || echo "Port 3000 non joignable"
curl -k -I -s https://127.0.0.1:3001/ || echo "Port 3001 non joignable"

# Tester quel port répond
ORIGIN_URL="http://127.0.0.1:3000"
if curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1; then
  echo " Port 3000 répond en HTTP"
  ORIGIN_URL="http://127.0.0.1:3000"
elif curl -s -k -f https://127.0.0.1:3001/ > /dev/null 2>&1; then
  echo " Port 3001 répond en HTTPS"
  ORIGIN_URL="https://127.0.0.1:3001"
fi

echo "Origine sélectionnée : $ORIGIN_URL"

# Lancer cloudflared avec logging complet
echo "Démarrage de cloudflared tunnel..."
nohup cloudflared tunnel \
  --no-tls-verify \
  --url "$ORIGIN_URL" > /tmp/cloudflared.log 2>&1 &

CF_PID=$!
echo "$CF_PID" > /tmp/cloudflared.pid
echo "cloudflared démarré avec PID $CF_PID"

FOUND_URL=""
for i in {1..40}; do
  sleep 2
  if ! ps -p "$CF_PID" > /dev/null 2>&1; then
    echo "❌ cloudflared s'est arrêté prématurément ! Logs :"
    cat /tmp/cloudflared.log
    exit 1
  fi
  FOUND_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n1 || true)
  if [ -n "$FOUND_URL" ]; then
    break
  fi
done

if [ -n "$FOUND_URL" ]; then
  publish_url_to_github "$FOUND_URL"
  echo "Vérification initiale du tunnel..."
  sleep 3
  curl -I -s -m 5 "$FOUND_URL" || echo "Test initial de propagation..."
else
  echo "❌ Impossible de trouver l'URL Cloudflare dans les logs :"
  cat /tmp/cloudflared.log
  exit 1
fi
