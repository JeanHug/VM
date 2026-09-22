#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    LANCEMENT D'ANDROID 13 NATIF (AOSP 60 FPS)    "
echo "=================================================="

DATA_DIR="/home/runner/vm_data_android"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR"

# 1. Chargement des modules noyau Linux Binder
echo "=== Chargement des pilotes noyau Linux (Binder & KVM) ==="
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
sudo mkdir -p /dev/binderfs 2>/dev/null || true
sudo mount -t binder binder /dev/binderfs 2>/dev/null || true

for node in binder hwbinder vndbinder; do
  if [ -e "/dev/binderfs/$node" ] && [ ! -e "/dev/$node" ]; then
    sudo ln -s "/dev/binderfs/$node" "/dev/$node" 2>/dev/null || true
  fi
  if [ -e "/dev/$node" ]; then
    sudo chmod 666 "/dev/$node" 2>/dev/null || true
  fi
done

if [ -e "/dev/kvm" ]; then
  sudo chmod 666 /dev/kvm 2>/dev/null || true
fi

# 2. Nettoyage et Démarrage du conteneur Redroid 13 Natif AOSP
echo "=== Démarrage d'Android 13 Natif (Redroid 13.0) ==="
docker rm -f redroid13 2>/dev/null || true
docker pull redroid/redroid:13.0.0-latest

docker run -d \
  --name redroid13 \
  --privileged \
  -v "$DATA_DIR/data":/data \
  -p 5555:5555 \
  redroid/redroid:13.0.0-latest \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1560 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=60 \
  androidboot.redroid_gpu_mode=guest

# 3. Installation des paquets nécessaires
echo "=== Installation des composants d'affichage et streaming ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq adb xvfb x11vnc novnc websockify scrcpy nginx curl >/dev/null 2>&1 || true

# 4. Connexion ADB et attente de l'initialisation complète
echo "=== Connexion ADB et attente du démarrage Android 13 ==="
adb connect 127.0.0.1:5555 || true

for i in {1..45}; do
  BOOT_COMPLETED=$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
  if [ "$BOOT_COMPLETED" = "1" ]; then
    echo " Android 13 démarré et 100% opérationnel !"
    break
  fi
  echo "Attente initialisation système [$i/45]..."
  sleep 2
done

# Déverrouiller l'écran et s'assurer qu'il est allumé
adb -s 127.0.0.1:5555 shell input keyevent 82 2>/dev/null || true
adb -s 127.0.0.1:5555 shell wm set-fix-to-user-rotation enabled 2>/dev/null || true

# 5. Démarrage de l'affichage virtuel Xvfb et Scrcpy
echo "=== Démarrage du moteur de rendu X11 / Scrcpy (60 FPS) ==="
pkill -f Xvfb 2>/dev/null || true
pkill -f scrcpy 2>/dev/null || true
pkill -f x11vnc 2>/dev/null || true
pkill -f websockify 2>/dev/null || true

Xvfb :99 -screen 0 720x1560x24 -nocursor &
sleep 2

export DISPLAY=:99
scrcpy -s 127.0.0.1:5555 \
  --window-title="Android13" \
  --window-x=0 --window-y=0 \
  --window-width=720 --window-height=1560 \
  --stay-awake \
  --render-driver=software &
sleep 3

x11vnc -display :99 -nopw -forever -shared -repeat -rfbport 5900 -noxrecord -noxdamage -wait 5 -defer 5 &
sleep 2

websockify --web /usr/share/novnc 6080 127.0.0.1:5900 &
sleep 2

# 6. Démarrage de l'API Bridge Android (Clavier & Touches)
echo "=== Démarrage de l'API Bridge Android ==="
pkill -f android-bridge.cjs 2>/dev/null || true
CURRENT_DIR=$(pwd)
node "$CURRENT_DIR/scripts/android-bridge.cjs" &
sleep 1

# 7. Configuration NGINX pour le smartphone Web Plein Écran
echo "=== Configuration du Reverse-Proxy NGINX ==="
cat << NGINX_EOF | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # Page d'accueil : Smartphone Web Plein Écran
    location = / {
        root $CURRENT_DIR/android-web;
        try_files /index.html =404;
    }

    # API Bridge Android (Saisie texte, touches matérielles)
    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # Flux noVNC WebSockets
    location /websockify {
        proxy_pass http://127.0.0.1:6080/websockify;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Fichiers et lecteur noVNC
    location / {
        proxy_pass http://127.0.0.1:6080/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

echo "=================================================="
echo " Android 13 Smartphone Plein Écran Prêt sur Port 3000 !"
echo "=================================================="
