#!/usr/bin/env bash
set -e

echo "=================================================="
echo "  DÉMARRAGE DU TUNNEL CLOUDFLARE POUR VM ANDROID  "
echo "=================================================="

# 1. Vérification que NGINX tourne bien sur le port 3000
echo "Attente que le port local 3000 soit actif..."
for i in {1..30}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo " Port local 3000 opérationnel (Code $HTTP_CODE) !"
    break
  fi
  sleep 2
done

# 2. Installation de Cloudflared si nécessaire
if ! command -v cloudflared &>/dev/null; then
  echo "Installation de Cloudflared..."
  sudo curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64
  sudo chmod +x /usr/local/bin/cloudflared
fi

# Nettoyage des anciens processus
pkill -9 -f cloudflared || true
pkill -9 -f "nokey@localhost.run" || true

# 3. Lancement du tunnel Cloudflare avec tunnel persistant (si CLOUDFLARE_TOKEN présent) ou Quick Tunnel avec log détaillé
if [ -n "$CLOUDFLARE_TOKEN" ]; then
  echo "Lancement du tunnel Cloudflare officiel persistant via Token..."
  cloudflared tunnel run --token "$CLOUDFLARE_TOKEN" > /tmp/cf_tunnel_android.log 2>&1 &
fi

echo "Lancement du Quick Tunnel Cloudflare..."
cloudflared tunnel --url http://127.0.0.1:3000 --no-autoupdate > /tmp/quick_tunnel_android.log 2>&1 &

# 4. Lancement de localhost.run comme secours
echo "Lancement de localhost.run..."
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=15 -R 80:localhost:3000 nokey@localhost.run > /tmp/localhost_run_android.log 2>&1 &

# 5. Récupération de l'URL Cloudflare avec validation active
RAW_CF_URL=""
for i in {1..50}; do
  RAW_CF_URL=$(grep -o 'https://[-a-zA-Z0-9_.]*\.trycloudflare\.com' /tmp/quick_tunnel_android.log | head -n1 || true)
  if [ -n "$RAW_CF_URL" ]; then
    echo "URL Cloudflare détectée : $RAW_CF_URL"
    # Vérification que Cloudflare répond bien en 200/302
    STATUS=$(curl -s -o /dev/null -w "%{http_code}" "$RAW_CF_URL" || echo "000")
    if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
      echo " Tunnel Cloudflare testé et validé (Code $STATUS) !"
      break
    fi
  fi
  sleep 2
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

# 6. Publication de l'URL sur la branche tunnel-url (tunnels-android.json)
if [ -n "$GH_TOKEN" ] && [ -n "$GITHUB_REPOSITORY" ] && [ -n "$PRIMARY_URL" ]; then
  TMP_URL_REPO=$(mktemp -d)
  cd "$TMP_URL_REPO"
  git init -q
  git config user.name "VM-Android-Auto"
  git config user.email "bot@vm.android.local"
  git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
  git checkout -B tunnel-url

  git pull origin tunnel-url --rebase 2>/dev/null || true

  echo "$PRIMARY_URL" > current_url_android.txt
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > updated_at_android.txt

  cat << JSON > tunnels-android.json
{
  "name": "Smartphone Android 14",
  "primary": "$PRIMARY_URL",
  "cloudflare": "$RAW_CF_URL",
  "lhrLife": "$RAW_LHR_URL",
  "status": "online",
  "updated_at": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
JSON

  git add current_url_android.txt updated_at_android.txt tunnels-android.json
  if ! git diff --staged --quiet; then
    git commit -m "chore(tunnel-android): active Cloudflare Android URL [$PRIMARY_URL]"
    git push --force origin tunnel-url 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g'
    echo " URL Android publiée avec succès sur tunnel-url !"
  fi
  cd /
  rm -rf "$TMP_URL_REPO"
fi
