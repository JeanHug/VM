#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    INITIALISATION DU TUNNEL WEB PUBLIC           "
echo "=================================================="

sudo apt-get update -qq && sudo apt-get install -y -qq curl jq ssh > /dev/null 2>&1 || true

if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

# Attente que le port 3000 réponde
for i in {1..30}; do
  if curl -s http://127.0.0.1:3000/ > /dev/null 2>&1 || curl -s -I http://127.0.0.1:3000/ | grep -q "HTTP"; then
    echo " Port HTTP 3000 actif !"
    break
  fi
  sleep 1
done

# Lancement du tunnel Cloudflare vers HTTP 3000
echo "Démarrage Cloudflare Tunnel vers http://127.0.0.1:3000..."
nohup cloudflared tunnel --url http://127.0.0.1:3000 > /tmp/quick_tunnel.log 2>&1 &
echo $! > /tmp/quick_tunnel.pid

# Lancement du tunnel de secours localhost.run en parallèle
nohup ssh -o StrictHostKeyChecking=no -R 80:127.0.0.1:3000 nokey@localhost.run > /tmp/localhost_run.log 2>&1 &
echo $! > /tmp/localhost_run.pid

RAW_CF_URL=""
for i in {1..40}; do
  sleep 2
  RAW_CF_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/quick_tunnel.log | head -n1 || true)
  if [ -n "$RAW_CF_URL" ]; then
    break
  fi
done

RAW_LHR_URL=""
for i in {1..15}; do
  RAW_LHR_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.lhr\.life' /tmp/localhost_run.log | head -n1 || true)
  if [ -n "$RAW_LHR_URL" ]; then
    break
  fi
  sleep 1
done

PRIMARY_URL="$RAW_CF_URL"
if [ -z "$PRIMARY_URL" ]; then
  PRIMARY_URL="$RAW_LHR_URL"
fi

echo "=================================================="
echo "🎯 URL CLOUDFLARE ACTIVE : $RAW_CF_URL"
echo "🎯 URL REPLI LOCALHOST.RUN: $RAW_LHR_URL"
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
  "cloudflare": "$RAW_CF_URL",
  "localhostRun": "$RAW_LHR_URL",
  "updated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON

  git add current_url.txt updated_at.txt tunnels.json
  git commit -m "chore(tunnel): active ultra-modern linux desktop [$PRIMARY_URL]" || true
  git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
  cd /
  rm -rf "$TMP_URL_REPO"
  echo " URLs sauvegardées avec succès !"
fi
