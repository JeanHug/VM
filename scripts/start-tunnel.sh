#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    INITIALISATION DU TUNNEL CLOUDFLARE PUBLIC    "
echo "=================================================="

sudo apt-get update -qq && sudo apt-get install -y -qq curl jq > /dev/null 2>&1 || true

if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

# Attente et test du port HTTP 3000
for i in {1..20}; do
  if curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1; then
    echo " Port HTTP 3000 prêt pour le tunnel !"
    break
  fi
  sleep 1
done

# Vérifier si un token Cloudflare officiel est disponible
if [ -n "$CLOUDFLARE_TOKEN" ]; then
  echo "Démarrage Cloudflare Tunnel avec jeton de tunnel dédié..."
  nohup cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TOKEN" > /tmp/cloudflared.log 2>&1 &
  echo $! > /tmp/cloudflared.pid
fi

# Lancer le Quick Tunnel public trycloudflare.com
echo "Démarrage du tunnel éphémère trycloudflare.com..."
nohup cloudflared tunnel --url http://127.0.0.1:3000 --no-tls-verify > /tmp/quick_tunnel.log 2>&1 &
echo $! > /tmp/quick_tunnel.pid

FOUND_URL=""
for i in {1..35}; do
  sleep 2
  FOUND_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/quick_tunnel.log | head -n1 || true)
  if [ -n "$FOUND_URL" ]; then
    break
  fi
done

echo "=================================================="
echo "🎯 URL CLOUDFLARE ACTIVE : $FOUND_URL"
echo "=================================================="

if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ] && [ -n "$FOUND_URL" ]; then
  TMP_URL_REPO=$(mktemp -d)
  cd "$TMP_URL_REPO"
  git init
  git config user.name "Cloudflare-Auto-Tunnel"
  git config user.email "bot@vm.cloudflare.local"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git checkout -B tunnel-url
  
  echo "$FOUND_URL" > current_url.txt
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at.txt
  
  cat << JSON > tunnels.json
{
  "primary": "$FOUND_URL",
  "cloudflare": "$FOUND_URL",
  "updated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON

  git add current_url.txt updated_at.txt tunnels.json
  git commit -m "chore(tunnel): active cloudflare tunnel [$FOUND_URL]" || true
  git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
  cd /
  rm -rf "$TMP_URL_REPO"
  echo " URL sauvegardée avec succès sur GitHub !"
fi
