#!/usr/bin/env bash
set -e

echo "=== Configuration du tunnel Cloudflare ==="

if [ -z "$CLOUDFLARE_TOKEN" ]; then
  echo "⚠️ AVERTISSEMENT : CLOUDFLARE_TOKEN n'est pas défini."
  echo "Le bureau web tourne localement sur le port 3000."
  exit 0
fi

# Téléchargement de cloudflared
if ! command -v cloudflared &> /dev/null; then
  echo "Téléchargement de cloudflared..."
  curl -L --output /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

echo "Démarrage de cloudflared en arrière-plan..."
# Démarrage du tunnel en arrière-plan vers le port 3000 (bureau web Webtop)
nohup cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TOKEN" > /tmp/cloudflared.log 2>&1 &
CLOUDFLARED_PID=$!
echo "$CLOUDFLARED_PID" > /tmp/cloudflared.pid

sleep 3
if ps -p "$CLOUDFLARED_PID" > /dev/null; then
  echo " Tunnel Cloudflare actif (PID: $CLOUDFLARED_PID)"
else
  echo "⚠️ Erreur lors du lancement de cloudflared, logs :"
  cat /tmp/cloudflared.log || true
fi
