#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    INITIALISATION DES TUNNELS D'ACCÈS WEB        "
echo "=================================================="

sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client curl jq > /dev/null 2>&1 || true

# Test des ports locaux
echo "Vérification des ports locaux :"
curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1 && echo " Port HTTP 3000 actif" || echo "❌ Port 3000 inactif"
curl -s -k -f https://127.0.0.1:3001/ > /dev/null 2>&1 && echo " Port HTTPS 3001 actif" || echo "❌ Port 3001 inactif"

# 1. PINGGY TUNNEL (Supporte nativement KasmVNC & WebSockets sans configuration complexe)
echo "--- Lancement du tunnel Pinggy (Port 3000) ---"
ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa <<< y >/dev/null 2>&1 || true

nohup ssh -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -p 443 \
  -R 0:localhost:3000 \
  a.pinggy.io > /tmp/pinggy.log 2>&1 &

echo $! > /tmp/pinggy.pid

# 2. LOCALHOST.RUN TUNNEL (Second tunnel SSH haute disponibilité)
echo "--- Lancement du tunnel Localhost.run (Port 3000) ---"
nohup ssh -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -R 80:localhost:3000 \
  nokey@localhost.run > /tmp/localhost_run.log 2>&1 &

echo $! > /tmp/localhost_run.pid

# 3. CLOUDFLARE TUNNEL (Avec configuration Ingress WebSocket et noTLSVerify explicite)
if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

cat << 'CF_CONFIG' > /tmp/cf_config.yml
tunnel: quick
ingress:
  - service: http://127.0.0.1:3000
    originRequest:
      noTLSVerify: true
      connectTimeout: 30s
      http2Origin: false
CF_CONFIG

nohup cloudflared tunnel --config /tmp/cf_config.yml --url http://127.0.0.1:3000 > /tmp/cloudflared.log 2>&1 &
echo $! > /tmp/cloudflared.pid

# Récupération des URLs
PINGGY_URL=""
LHR_URL=""
CF_URL=""

echo "Attente de la génération des URLs..."
for i in {1..30}; do
  sleep 2
  if [ -z "$PINGGY_URL" ] && [ -f /tmp/pinggy.log ]; then
    PINGGY_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.pinggy\.link' /tmp/pinggy.log | head -n1 || true)
    [ -z "$PINGGY_URL" ] && PINGGY_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.a\.pinggy\.link' /tmp/pinggy.log | head -n1 || true)
  fi
  
  if [ -z "$LHR_URL" ] && [ -f /tmp/localhost_run.log ]; then
    LHR_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.lhr\.life' /tmp/localhost_run.log | head -n1 || true)
  fi

  if [ -z "$CF_URL" ] && [ -f /tmp/cloudflared.log ]; then
    CF_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n1 || true)
  fi

  if [ -n "$PINGGY_URL" ] || [ -n "$LHR_URL" ] || [ -n "$CF_URL" ]; then
    echo "URL trouvée (Cycle $i) : Pinggy=[$PINGGY_URL] LHR=[$LHR_URL] CF=[$CF_URL]"
    [ -n "$PINGGY_URL" ] && break
  fi
done

PRIMARY_URL="${PINGGY_URL:-${LHR_URL:-$CF_URL}}"

echo "=================================================="
echo "🎯 URL PRIMAIRE RETENUE : $PRIMARY_URL"
echo "  Pinggy        : $PINGGY_URL"
echo "  Localhost.run : $LHR_URL"
echo "  Cloudflare    : $CF_URL"
echo "=================================================="

# Publication sur la branche tunnel-url de GitHub
if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ] && [ -n "$PRIMARY_URL" ]; then
  TMP_URL_REPO=$(mktemp -d)
  cd "$TMP_URL_REPO"
  git init
  git config user.name "Multi-Tunnel-Deployer"
  git config user.email "bot@vm.multi-tunnel.local"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git checkout -B tunnel-url
  
  echo "$PRIMARY_URL" > current_url.txt
  echo "$PINGGY_URL" > pinggy_url.txt
  echo "$LHR_URL" > lhr_url.txt
  echo "$CF_URL" > cf_url.txt
  
  cat << JSON > tunnels.json
{
  "primary": "$PRIMARY_URL",
  "pinggy": "$PINGGY_URL",
  "localhost_run": "$LHR_URL",
  "cloudflare": "$CF_URL",
  "updated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON

  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at.txt
  git add current_url.txt pinggy_url.txt lhr_url.txt cf_url.txt tunnels.json updated_at.txt
  git commit -m "chore(tunnel): multi-tunnel update [$PRIMARY_URL]" || true
  git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
  cd /
  rm -rf "$TMP_URL_REPO"
  echo " URLs sauvegardées sur GitHub !"
fi
