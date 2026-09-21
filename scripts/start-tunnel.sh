#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION AUTOMATIQUE DU TUNNEL CLOUDFLARE"
echo "=================================================="

# 1. Télécharger cloudflared
if ! command -v cloudflared &> /dev/null; then
  echo "Installation de cloudflared..."
  curl -s -L -o /tmp/cloudflared.deb https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb
  sudo dpkg -i /tmp/cloudflared.deb || true
  rm -f /tmp/cloudflared.deb
fi

# Fonction de publication sur la branche tunnel-url du repo GitHub
publish_url_to_github() {
  PUBLIC_URL="$1"
  TUNNEL_TYPE="${2:-auto}"
  echo "$PUBLIC_URL" > /tmp/vm_public_url.txt
  echo "=================================================="
  echo " URL DU BUREAU WEB : $PUBLIC_URL"
  echo " Mode du Tunnel     : $TUNNEL_TYPE"
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
    echo "$TUNNEL_TYPE" > tunnel_type.txt
    echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at.txt
    git add current_url.txt tunnel_type.txt updated_at.txt
    git commit -m "chore(tunnel): update active public URL [$PUBLIC_URL]" || true
    git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
    cd /
    rm -rf "$TMP_URL_REPO"
    echo " URL enregistrée sur GitHub avec succès !"
  fi
}

TUNNEL_RUNNING=false

# STRATÉGIE A : Récupération automatique du token d'exécution du Tunnel Cloudflare via API
if [ -n "$CLOUDFLARE_TOKEN" ] && [ -n "$CLOUDFLARE_ID" ]; then
  echo "Tentative d'activation via Cloudflare API (Account: $CLOUDFLARE_ID)..."

  # Chercher le tunnel existant 'vm-persistent-relay' ou le créer
  TUNNELS_LIST=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ID/cfd_tunnel" \
    -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
    -H "Content-Type: application/json")

  TUNNEL_ID=$(echo "$TUNNELS_LIST" | grep -o '"name":"vm-persistent-relay"[^}]*' | grep -o '"id":"[^"]*' | cut -d'"' -f4 || true)

  if [ -z "$TUNNEL_ID" ]; then
    echo "Création du tunnel persistant 'vm-persistent-relay'..."
    RANDOM_SECRET=$(head -c 32 /dev/urandom | base64)
    CREATE_RES=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ID/cfd_tunnel" \
      -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"name\":\"vm-persistent-relay\",\"tunnel_secret\":\"$RANDOM_SECRET\"}")
    TUNNEL_ID=$(echo "$CREATE_RES" | grep -o '"id":"[^"]*' | head -n1 | cut -d'"' -f4 || true)
  fi

  if [ -n "$TUNNEL_ID" ]; then
    echo "ID du Tunnel Cloudflare : $TUNNEL_ID"
    echo "$TUNNEL_ID" > /tmp/cloudflare_tunnel_id.txt

    # Configurer l'ingress HTTP sur le port 3000
    curl -s -X PUT "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
      -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
      -H "Content-Type: application/json" \
      -d '{"config":{"ingress":[{"service":"http://localhost:3000"}]}}' > /dev/null 2>&1 || true

    # Récupérer le token d'exécution natif (eyJh...) du tunnel
    EXEC_TOKEN_RES=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ID/cfd_tunnel/$TUNNEL_ID/token" \
      -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
      -H "Content-Type: application/json")
    EXEC_TOKEN=$(echo "$EXEC_TOKEN_RES" | grep -o '"result":"[^"]*' | cut -d'"' -f4 || true)

    if [ -n "$EXEC_TOKEN" ] && [ "$EXEC_TOKEN" != "null" ]; then
      echo " Token d'exécution Cloudflare obtenu avec succès !"
      nohup cloudflared tunnel --no-autoupdate run --token "$EXEC_TOKEN" > /tmp/cloudflared.log 2>&1 &
      CF_PID=$!
      echo "$CF_PID" > /tmp/cloudflared.pid
      sleep 5
      if ps -p "$CF_PID" > /dev/null; then
        echo " Tunnel Cloudflare d'infrastructure démarré (PID: $CF_PID)"
        TUNNEL_RUNNING=true
      fi
    fi
  fi
fi

# STRATÉGIE B (QUICK TUNNEL AUTO-GÉNÉRÉ) :
# Si aucun domaine personnalisé ou pour accès immédiat en 1-clic avec URL HTTPS trycloudflare.com
echo "Lancement du Quick Tunnel Cloudflare (URL HTTPS publique automatique)..."
nohup cloudflared tunnel --url http://127.0.0.1:3000 > /tmp/cloudflared_quick.log 2>&1 &
QUICK_PID=$!
echo "$QUICK_PID" > /tmp/cloudflared_quick.pid

FOUND_URL=""
for i in {1..25}; do
  sleep 2
  FOUND_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared_quick.log | head -n1 || true)
  if [ -n "$FOUND_URL" ]; then
    break
  fi
  echo "En attente de l'URL Cloudflare ($i/25)..."
done

if [ -n "$FOUND_URL" ]; then
  publish_url_to_github "$FOUND_URL" "trycloudflare"
else
  echo "⚠️ Erreur de récupération de l'URL dans les logs :"
  cat /tmp/cloudflared_quick.log || true
fi
