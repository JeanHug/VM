#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID 13 ULTRA BASSE-LATENCE & AUTO-DETECT   "
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

# 2. Démarrage de Redroid 13 Natif AOSP Ultra-Fluid (720x1560, 60fps)
echo "=== Démarrage d'Android 13 Natif (Redroid 13.0) ==="
docker rm -f redroid13 android_vm 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

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

# 3. Installation des paquets de rendu ultra-rapides
echo "=== Installation des composants d'affichage et streaming ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq adb xvfb x11vnc novnc websockify scrcpy nginx curl >/dev/null 2>&1 || true

# 4. Connexion ADB et attente du boot
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

# Déverrouiller l'écran
adb -s 127.0.0.1:5555 shell input keyevent 82 2>/dev/null || true
adb -s 127.0.0.1:5555 shell wm set-fix-to-user-rotation enabled 2>/dev/null || true

# 5. Démarrage Xvfb, Scrcpy (Optimisé 0-lag 8Mbps) et x11vnc ultra-réactif
echo "=== Démarrage de la chaîne vidéo 60 FPS Faible Latence ==="
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
  --video-bit-rate=8M \
  --max-fps=60 \
  --stay-awake \
  --render-driver=software &
sleep 3

# x11vnc configuré pour un temps de réponse instantané (-wait 0, -defer 0, -nowf)
x11vnc -display :99 -nopw -forever -shared -repeat -rfbport 5900 -noxrecord -noxdamage -wait 0 -defer 0 &
sleep 2

websockify --web /usr/share/novnc 6080 127.0.0.1:5900 &
sleep 2

# 6. Démarrage du Détecteur de Clavier et de l'API Bridge Android
echo "=== Démarrage de l'API Bridge & Détecteur d'IME (Clavier) ==="
pkill -f android-bridge.cjs 2>/dev/null || true
CURRENT_DIR=$(pwd)
node "$CURRENT_DIR/scripts/android-bridge.cjs" &
sleep 1

# 7. Configuration NGINX Reverse-Proxy
echo "=== Configuration du Reverse-Proxy NGINX ==="
cat << NGINX_EOF | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # Page d'accueil : Interface Smartphone Plein Écran + Auto Clavier
    location = / {
        root $CURRENT_DIR/android-web;
        try_files /index.html =404;
    }

    # API Bridge Android (Détection clavier, saisie, touches matérielles)
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

    # Fichiers statiques noVNC
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
echo " Android 13 Ultra-Fluide Prêt sur Port 3000 !"
echo "=================================================="
