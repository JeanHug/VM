#!/usr/bin/env bash
set -e

echo "=================================================="
echo "  DÉMARRAGE DU TUNNEL CLOUDFLARE POUR VM ANDROID  "
echo "=================================================="

# 1. Installation de Cloudflared si nécessaire
if ! command -v cloudflared &>/dev/null; then
  echo "Installation de Cloudflared..."
  sudo curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  sudo chmod +x /usr/local/bin/cloudflared
fi

# Nettoyage des anciens tunnels
pkill -f cloudflared || true
pkill -f "nokey@localhost.run" || true

# 2. Lancement du tunnel Cloudflare (Port 3000 -> Android Web)
echo "Lancement du Quick Tunnel Cloudflare pour Android..."
cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate > /tmp/quick_tunnel_android.log 2>&1 &

# 3. Lancement de localhost.run en secours
echo "Lancement de localhost.run pour Android..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=15 -R 80:localhost:3000 nokey@localhost.run > /tmp/localhost_run_android.log 2>&1 &

# 4. Récupération des URLs
RAW_CF_URL=""
for i in {1..40}; do
  RAW_CF_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/quick_tunnel_android.log | head -n1 || true)
  if [ -n "$RAW_CF_URL" ]; then
    break
  fi
  sleep 1
done

RAW_LHR_URL=""
for i in {1..20}; do
  RAW_LHR_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.lhr\.life' /tmp/localhost_run_android.log | head -n1 || true)
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
echo "🎯 URL CLOUDFLARE ANDROID : $RAW_CF_URL"
echo "🎯 URL PRINCIPALE ANDROID : $PRIMARY_URL"
echo "=================================================="

# 5. Publication de l'URL sur la branche tunnel-url (tunnels-android.json)
if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ] && [ -n "$PRIMARY_URL" ]; then
  TMP_URL_REPO=$(mktemp -d)
  cd "$TMP_URL_REPO"
  git init
  git config user.name "VM-Tunnel-Auto"
  git config user.email "bot@vm.tunnel.local"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git checkout -B tunnel-url
  
  git pull origin tunnel-url --rebase 2>/dev/null || true

  cat << JSON > tunnels-android.json
{
  "name": "Smartphone Android",
  "primary": "$PRIMARY_URL",
  "cloudflare": "$RAW_CF_URL",
  "lhrLife": "$RAW_LHR_URL",
  "status": "online",
  "updated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON

  git add tunnels-android.json
  git commit -m "chore(tunnel): active Cloudflare Android URL [$PRIMARY_URL]" || true
  git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
  cd /
  rm -rf "$TMP_URL_REPO"
  echo " URL Cloudflare Android publiée avec succès sur tunnel-url !"
fi
