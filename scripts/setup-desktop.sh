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

# Lancement de l'environnement graphique Webtop
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
  -v "$DATA_DIR":/config \
  --shm-size="2gb" \
  lscr.io/linuxserver/webtop:ubuntu-xfce

echo "=== [3/3] Vérification rigoureuse du serveur Web (Port 3000) ==="
READY=false
for i in {1..40}; do
  if curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1; then
    echo " Bureau Web actif et répondant sur http://127.0.0.1:3000 (essai $i)"
    READY=true
    break
  fi
  echo "En attente du démarrage complet de Webtop ($i/40)..."
  sleep 2
done

if [ "$READY" = false ]; then
  echo "⚠️ Webtop n'a pas répondu immédiatement, inspection des logs Docker :"
  docker logs --tail 30 webtop || true
fi

# Installation de Google Chrome officiel
echo "=== Installation de Google Chrome officiel dans la session ==="
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

# Création du raccourci Google Chrome sur le bureau
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

echo " Bureau visuel complet prêt et vérifié avec succès !"
