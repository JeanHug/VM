#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   [1/3] CONFIGURATION DU BUREAU VISUEL COMPLET   "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"
mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"

echo "=== [2/3] Démarrage du conteneur Webtop Ubuntu-XFCE ==="
docker pull lscr.io/linuxserver/webtop:ubuntu-xfce

# Nettoyage préventif
docker rm -f webtop 2>/dev/null || true

# Lancement de l'environnement graphique Webtop avec exposition des ports HTTP (3000) et HTTPS (3001)
docker run -d \
  --name webtop \
  --restart unless-stopped \
  --security-opt seccomp=unconfined \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Europe/Paris \
  -e SUBFOLDER=/ \
  -e TITLE="Linux Cloud Web Desktop (Chrome & XFCE)" \
  -p 3000:3000 \
  -p 3001:3001 \
  -v "$DATA_DIR":/config \
  --shm-size="2gb" \
  lscr.io/linuxserver/webtop:ubuntu-xfce

echo "=== [3/3] Vérification des ports Webtop (HTTP 3000 & HTTPS 3001) ==="
TARGET_URL=""
for i in {1..35}; do
  if curl -s -k -f https://127.0.0.1:3001/ > /dev/null 2>&1; then
    echo " Port HTTPS 3001 opérationnel !"
    TARGET_URL="https://127.0.0.1:3001"
    break
  fi
  if curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1; then
    echo " Port HTTP 3000 opérationnel !"
    TARGET_URL="http://127.0.0.1:3000"
    break
  fi
  echo "En attente du démarrage du serveur KasmVNC/Webtop ($i/35)..."
  sleep 2
done

# Sauvegarder la cible opérationnelle pour cloudflared
if [ -n "$TARGET_URL" ]; then
  echo "$TARGET_URL" > /tmp/webtop_target_url.txt
else
  # Par défaut, Webtop écoute sur HTTPS 3001
  echo "https://127.0.0.1:3001" > /tmp/webtop_target_url.txt
fi

echo "Cible origin retenue : $(cat /tmp/webtop_target_url.txt)"

# Installation de Google Chrome officiel
echo "=== Installation de Google Chrome officiel ==="
docker exec -u 0 webtop bash -c "
  apt-get update && \
  apt-get install -y --no-install-recommends wget curl gnupg git python3 python3-pip htop nano unzip ca-certificates && \
  wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg && \
  echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main' > /etc/apt/sources.list.d/google-chrome.list && \
  apt-get update && \
  apt-get install -y --no-install-recommends google-chrome-stable && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*
" || true

docker exec -u 1000 webtop bash -c "
  mkdir -p /config/Desktop
  cat << 'DESKTOP_EOF' > /config/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Name=Google Chrome
Comment=Accéder au Web
Exec=/usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage %U
Terminal=false
Icon=google-chrome
Type=Application
Categories=Network;WebBrowser;
DESKTOP_EOF
  chmod +x /config/Desktop/google-chrome.desktop
" || true

echo " Bureau visuel et Google Chrome configurés !"
