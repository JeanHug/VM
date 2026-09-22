#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    INITIALISATION DU TUNNEL WEB PUBLIC           "
echo "=================================================="

sudo apt-get update -qq && sudo apt-get install -y -qq curl jq ssh > /dev/null 2>&1 || true

# Nettoyer les anciens processus tunnel
pkill -f "nokey@localhost.run" 2>/dev/null || true
pkill -f "cloudflared tunnel" 2>/dev/null || true
sleep 1

# Attente que le port 3000 réponde
for i in {1..30}; do
  if curl -s http://127.0.0.1:3000/ > /dev/null 2>&1 || curl -s -I http://127.0.0.1:3000/ | grep -q "HTTP"; then
    echo " Port HTTP 3000 actif !"
    break
  fi
  sleep 1
done

# 1. Lancement du tunnel direct SSH localhost.run (.lhr.life) avec keepalive
echo "Démarrage du tunnel direct SSH localhost.run..."
rm -f /tmp/localhost_run.log
nohup ssh -o StrictHostKeyChecking=no \
          -o ServerAliveInterval=15 \
          -o ServerAliveCountMax=3 \
          -o ExitOnForwardFailure=yes \
          -R 80:127.0.0.1:3000 \
          nokey@localhost.run > /tmp/localhost_run.log 2>&1 &
echo $! > /tmp/localhost_run.pid

# 2. Lancement du tunnel Cloudflare en parallèle (fallback)
if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

rm -f /tmp/quick_tunnel.log
nohup cloudflared tunnel --url http://127.0.0.1:3000 > /tmp/quick_tunnel.log 2>&1 &
echo $! > /tmp/quick_tunnel.pid

RAW_LHR_URL=""
for i in {1..20}; do
  RAW_LHR_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.lhr\.life' /tmp/localhost_run.log | head -n1 || true)
  if [ -n "$RAW_LHR_URL" ]; then
    break
  fi
  sleep 1
done

RAW_CF_URL=""
for i in {1..25}; do
  RAW_CF_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/quick_tunnel.log | head -n1 || true)
  if [ -n "$RAW_CF_URL" ]; then
    break
  fi
  sleep 1
done

PRIMARY_URL="$RAW_LHR_URL"
if [ -z "$PRIMARY_URL" ]; then
  PRIMARY_URL="$RAW_CF_URL"
fi

echo "=================================================="
echo "🎯 URL DIRECTE LHR.LIFE : $RAW_LHR_URL"
echo "🎯 URL CLOUDFLARE       : $RAW_CF_URL"
echo "🎯 URL PRINCIPALE ACTIVE: $PRIMARY_URL"
echo "=================================================="

if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ] && [ -n "$PRIMARY_URL" ]; then
  TMP_URL_REPO=$(mktemp -d)
  cd "$TMP_URL_REPO"
  git init
  git config user.name "VM-Tunnel-Auto"
  git config user.email "bot@vm.tunnel.local"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git checkout -B tunnel-url
  
  echo "$PRIMARY_URL" > current_url.txt
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at.txt
  
  cat << JSON > tunnels.json
{
  "primary": "$PRIMARY_URL",
  "lhrLife": "$RAW_LHR_URL",
  "cloudflare": "$RAW_CF_URL",
  "status": "online",
  "updated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON

  git add current_url.txt updated_at.txt tunnels.json
  git commit -m "chore(tunnel): active direct lhr url [$PRIMARY_URL]" || true
  git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
  cd /
  rm -rf "$TMP_URL_REPO"
  echo " URLs publiées avec succès sur la branche tunnel-url !"
fi
