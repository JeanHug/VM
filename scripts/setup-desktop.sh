#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   [1/3] CONFIGURATION DU BUREAU VISUEL COMPLET   "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"
mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"

echo "=== [2/3] Démarrage du conteneur Webtop Ubuntu-XFCE (HTTP pur sans TLS interne) ==="
docker pull lscr.io/linuxserver/webtop:ubuntu-xfce

docker rm -f webtop 2>/dev/null || true

# On désactive le SSL auto-signé interne de KasmVNC pour éviter les blocages 502/SSL
docker run -d \
  --name webtop \
  --restart unless-stopped \
  --security-opt seccomp=unconfined \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Europe/Paris \
  -e SUBFOLDER=/ \
  -e TITLE="Linux Cloud Web Desktop (Chrome & XFCE)" \
  -e NO_SSL=true \
  -p 3000:3000 \
  -v "$DATA_DIR":/config \
  --shm-size="2gb" \
  lscr.io/linuxserver/webtop:ubuntu-xfce

echo "=== [3/3] Vérification du port HTTP Webtop 3000 ==="
for i in {1..35}; do
  if curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1; then
    echo " Port HTTP 3000 opérationnel !"
    break
  fi
  echo "En attente du démarrage du serveur KasmVNC ($i/35)..."
  sleep 2
done

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
  rm -rf /var/lib/apt/lists/*" || true

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
  chmod +x /config/Desktop/google-chrome.desktop" || true

echo " Bureau visuel et Google Chrome configurés !"
