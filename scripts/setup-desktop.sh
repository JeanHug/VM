#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   [1/3] CONFIGURATION DU BUREAU VISUEL COMPLET   "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"
mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"

echo "=== [2/3] Installation des paquets X11, noVNC, XFCE & Google Chrome ==="
export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends \
  xvfb \
  x11vnc \
  novnc \
  websockify \
  xfce4 \
  xfce4-terminal \
  dbus-x11 \
  wget \
  curl \
  ca-certificates \
  gnupg \
  git \
  htop \
  python3 > /dev/null 2>&1 || true

# Installation de Google Chrome officiel
if ! command -v google-chrome &> /dev/null; then
  echo "Installation de Google Chrome..."
  wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
  sudo apt-get update -qq || true
  sudo apt-get install -y --no-install-recommends google-chrome-stable > /dev/null 2>&1 || true
fi

echo "=== [3/3] Démarrage du serveur d'affichage X11 + Desktop + noVNC ==="
export DISPLAY=:1

# Arrêt d'éventuels processus précédents
pkill -f Xvfb || true
pkill -f x11vnc || true
pkill -f websockify || true
pkill -f xfce4-session || true

# 1. Lancement de Xvfb (résolution 1280x800, 24 bits de couleur)
Xvfb :1 -screen 0 1280x800x24 &
sleep 2

# 2. Lancement de l'environnement de bureau XFCE
dbus-launch --exit-with-session startxfce4 &
sleep 3

# 3. Lancement du serveur VNC local (sans mot de passe, écoute uniquement sur 127.0.0.1:5900)
x11vnc -display :1 -nopw -listen 127.0.0.1 -xkb -forever -shared -bg &
sleep 2

# 4. Lancement de noVNC / websockify sur le port HTTP 3000
# /usr/share/novnc est le dossier des assets web HTML5
if [ -d "/usr/share/novnc" ]; then
  NOVNC_WEB="/usr/share/novnc"
else
  NOVNC_WEB="/usr/local/share/novnc"
fi

# Raccourci index.html pointant sur vnc.html avec autoconnect
sudo cp $NOVNC_WEB/vnc.html $NOVNC_WEB/index.html 2>/dev/null || true

# Démarrage de websockify (VNC WebSocket vers HTTP 3000)
websockify --web=$NOVNC_WEB 3000 127.0.0.1:5900 &
sleep 2

# Lancement automatique de Google Chrome dans la session X11
nohup google-chrome --no-sandbox --disable-dev-shm-usage --start-maximized "https://google.com" > /dev/null 2>&1 &

echo " Bureau visuel noVNC HTTP 3000 opérationnel !"
