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

RECORD_URL_FILE="/tmp/vm_public_url.txt"
rm -f "$RECORD_URL_FILE"

# Fonction pour publier l'URL sur la branche tunnel-url du repo GitHub
publish_url_to_github() {
  PUBLIC_URL="$1"
  echo "$PUBLIC_URL" > "$RECORD_URL_FILE"
  echo "=================================================="
  echo " URL DU BUREAU WEB : $PUBLIC_URL"
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
    git commit -m "chore(tunnel): update active public URL [$PUBLIC_URL]" || true
    git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g' || true
    cd /
    rm -rf "$TMP_URL_REPO"
    echo " URL enregistrée sur GitHub avec succès !"
  fi
}

TUNNEL_RUNNING=false

# STRATÉGIE A : Si CLOUDFLARE_TOKEN et CLOUDFLARE_ID sont fournis
if [ -n "$CLOUDFLARE_TOKEN" ] && [ -n "$CLOUDFLARE_ID" ]; then
  echo "Détection de CLOUDFLARE_TOKEN (clé API Cloudflare) et Account ID : $CLOUDFLARE_ID"
  
  # Si le token commence par cfat_ ou ressemble à une clé API Cloudflare :
  # On utilise l'API Cloudflare pour créer automatiquement un Named Tunnel et obtenir son token d'exécution !
  RANDOM_SECRET=$(head -c 32 /dev/urandom | base64)
  TUNNEL_NAME="vm-relay-runner-$(date +%s)"
  
  echo "Création dynamique d'un tunnel Cloudflare nommé '$TUNNEL_NAME'..."
  API_RES=$(curl -s -X POST "https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ID/cfd_tunnel" \
    -H "Authorization: Bearer $CLOUDFLARE_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$TUNNEL_NAME\",\"tunnel_secret\":\"$RANDOM_SECRET\"}")

  EXEC_TOKEN=$(echo "$API_RES" | grep -o '"token":"[^"]*' | cut -d'"' -f4 || true)
  TUNNEL_ID=$(echo "$API_RES" | grep -o '"id":"[^"]*' | head -n1 | cut -d'"' -f4 || true)

  if [ -n "$EXEC_TOKEN" ] && [ "$EXEC_TOKEN" != "null" ]; then
    echo " Token d'exécution Cloudflare généré avec succès ! (Tunnel ID: $TUNNEL_ID)"
    echo "$TUNNEL_ID" > /tmp/cloudflare_tunnel_id.txt
    
    # Lancement du tunnel avec le token d'exécution officiel
    nohup cloudflared tunnel --no-autoupdate run --token "$EXEC_TOKEN" > /tmp/cloudflared.log 2>&1 &
    CF_PID=$!
    echo "$CF_PID" > /tmp/cloudflared.pid
    sleep 4
    if ps -p "$CF_PID" > /dev/null; then
      echo " Tunnel Cloudflare d'entreprise actif (PID: $CF_PID)"
      TUNNEL_RUNNING=true
    fi
  else
    echo "Tentative d'utilisation directe du token avec 'cloudflared tunnel run'..."
    nohup cloudflared tunnel --no-autoupdate run --token "$CLOUDFLARE_TOKEN" > /tmp/cloudflared.log 2>&1 &
    CF_PID=$!
    echo "$CF_PID" > /tmp/cloudflared.pid
    sleep 4
    if ps -p "$CF_PID" > /dev/null; then
      TUNNEL_RUNNING=true
    fi
  fi
fi

# STRATÉGIE B (QUICK TUNNEL AUTO-GÉNÉRÉ) : Si aucun tunnel n'a pu tourner
# Cloudflare Quick Tunnel crée automatiquement une URL HTTPS publique sur trycloudflare.com
if [ "$TUNNEL_RUNNING" = false ]; then
  echo "=================================================="
  echo "Activation du Tunnel Rapide Automatique (Cloudflare Quick Tunnel)..."
  echo "=================================================="
  nohup cloudflared tunnel --url http://127.0.0.1:3000 > /tmp/cloudflared_quick.log 2>&1 &
  CF_PID=$!
  echo "$CF_PID" > /tmp/cloudflared.pid

  # Extraction automatique de l'URL publique générée par Cloudflare
  FOUND_URL=""
  for i in {1..20}; do
    sleep 2
    FOUND_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/cloudflared_quick.log | head -n1 || true)
    if [ -n "$FOUND_URL" ]; then
      break
    fi
    echo "En attente de l'attribution de l'URL Cloudflare ($i/20)..."
  done

  if [ -n "$FOUND_URL" ]; then
    publish_url_to_github "$FOUND_URL"
  else
    echo "⚠️ Impossible de récupérer l'URL Cloudflare dans les logs :"
    cat /tmp/cloudflared_quick.log || true
  fi
fi
