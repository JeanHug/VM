#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    INITIALISATION DES TUNNELS D'ACCÈS WEB        "
echo "=================================================="

sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client curl jq ca-certificates > /dev/null 2>&1 || true

# Détecter le vrai port actif de Webtop
TARGET_ORIGIN=""
if curl -s -k -f https://127.0.0.1:3001/ > /dev/null 2>&1; then
  echo " Port HTTPS 3001 détecté !"
  TARGET_ORIGIN="https://127.0.0.1:3001"
  TUNNEL_LOCAL_PORT=3001
elif curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1; then
  echo " Port HTTP 3000 détecté !"
  TARGET_ORIGIN="http://127.0.0.1:3000"
  TUNNEL_LOCAL_PORT=3000
else
  # Fallback HTTPS 3001 par défaut pour Webtop KasmVNC
  TARGET_ORIGIN="https://127.0.0.1:3001"
  TUNNEL_LOCAL_PORT=3001
fi

echo "Origine locale sélectionnée : $TARGET_ORIGIN (port $TUNNEL_LOCAL_PORT)"

# 1. CLOUDFLARE QUICK TUNNEL avec --no-tls-verify (CRITIQUE pour Webtop KasmVNC self-signed HTTPS)
if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

echo "Démarrage Cloudflare Tunnel vers $TARGET_ORIGIN..."
nohup cloudflared tunnel --no-tls-verify --url "$TARGET_ORIGIN" > /tmp/cloudflared.log 2>&1 &
echo $! > /tmp/cloudflared.pid

# 2. PINGGY (Tunnel SSH sans clé, supporte HTTP & HTTPS origin)
mkdir -p ~/.ssh && chmod 700 ~/.ssh
ssh-keygen -q -t rsa -N '' -f ~/.ssh/id_rsa <<< y >/dev/null 2>&1 || true

echo "Démarrage Pinggy vers port $TUNNEL_LOCAL_PORT..."
nohup ssh -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -p 443 \
  -R 0:localhost:$TUNNEL_LOCAL_PORT \
  a.pinggy.io > /tmp/pinggy.log 2>&1 &
echo $! > /tmp/pinggy.pid

# 3. LOCALHOST.RUN
echo "Démarrage Localhost.run..."
nohup ssh -o StrictHostKeyChecking=no \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=3 \
  -R 80:localhost:$TUNNEL_LOCAL_PORT \
  nokey@localhost.run > /tmp/localhost_run.log 2>&1 &
echo $! > /tmp/localhost_run.pid

# Récupération et attente des URLs
CF_URL=""
PINGGY_URL=""
LHR_URL=""

echo "Recherche des URLs actives..."
for i in {1..35}; do
  sleep 2

  if [ -z "$CF_URL" ] && [ -f /tmp/cloudflared.log ]; then
    CF_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared.log | head -n1 || true)
  fi

  if [ -z "$PINGGY_URL" ] && [ -f /tmp/pinggy.log ]; then
    PINGGY_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.pinggy\.link' /tmp/pinggy.log | head -n1 || true)
    [ -z "$PINGGY_URL" ] && PINGGY_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.a\.pinggy\.link' /tmp/pinggy.log | head -n1 || true)
  fi

  if [ -z "$LHR_URL" ] && [ -f /tmp/localhost_run.log ]; then
    LHR_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.lhr\.life' /tmp/localhost_run.log | head -n1 || true)
  fi

  if [ -n "$CF_URL" ] || [ -n "$PINGGY_URL" ]; then
    echo "URL trouvée (Cycle $i) : CF=[$CF_URL] Pinggy=[$PINGGY_URL] LHR=[$LHR_URL]"
    break
  fi
done

# Définir l'URL primaire (Priorité à Cloudflare si valide, sinon Pinggy, sinon LHR)
PRIMARY_URL="${CF_URL:-${PINGGY_URL:-$LHR_URL}}"

echo "=================================================="
echo "🎯 URL PRIMAIRE RETENUE : $PRIMARY_URL"
echo "  Cloudflare    : $CF_URL"
echo "  Pinggy        : $PINGGY_URL"
echo "  Localhost.run : $LHR_URL"
echo "=================================================="

# Publication sur la branche tunnel-url
if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ] && [ -n "$PRIMARY_URL" ]; then
  TMP_URL_REPO=$(mktemp -d)
  cd "$TMP_URL_REPO"
  git init
  git config user.name "Multi-Tunnel-Deployer"
  git config user.email "bot@vm.multi-tunnel.local"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git checkout -B tunnel-url
  
  echo "$PRIMARY_URL" > current_url.txt
  echo "$CF_URL" > cf_url.txt
  echo "$PINGGY_URL" > pinggy_url.txt
  echo "$LHR_URL" > lhr_url.txt
  
  cat << JSON > tunnels.json
{
  "primary": "$PRIMARY_URL",
  "cloudflare": "$CF_URL",
  "pinggy": "$PINGGY_URL",
  "localhost_run": "$LHR_URL",
  "updated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON

  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at.txt
  git add current_url.txt cf_url.txt pinggy_url.txt lhr_url.txt tunnels.json updated_at.txt
  git commit -m "chore(tunnel): active tunnel url [$PRIMARY_URL]" || true
  git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
  cd /
  rm -rf "$TMP_URL_REPO"
  echo " URLs sauvegardées sur GitHub !"
fi
