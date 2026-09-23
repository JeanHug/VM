#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID 8.1 OREO NATIF AOSP ULTRA-RAPIDE      "
echo "    (Zéro Latence - 60 FPS - Mode Normal/Détecté) "
echo "=================================================="

DATA_DIR="/home/runner/vm_data_android"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR"

# 1. Nettoyage
docker rm -f redroid8 redroid13 android_vm 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f scrcpy 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true

# 2. Chargement des modules Binder & KVM du noyau Linux
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

# 3. Démarrage de Redroid 8.1.0 (Android 8.1 Oreo Officiel AOSP natif)
echo "=== Démarrage d'Android 8.1 Oreo (redroid/redroid:8.1.0-latest) ==="
docker pull redroid/redroid:8.1.0-latest
docker run -d \
  --name redroid8 \
  --privileged \
  -v "$DATA_DIR/data":/data \
  -p 5555:5555 \
  redroid/redroid:8.1.0-latest \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1440 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=60 \
  androidboot.redroid_gpu_mode=guest

# 4. Installation des paquets d'affichage ultra-rapides
echo "=== Installation des composants d'affichage et streaming ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq adb xvfb x11vnc novnc websockify scrcpy nginx curl >/dev/null 2>&1 || true

# 5. Connexion ADB et attente du boot rapide d'Android 8.1
echo "=== Connexion ADB au système Android 8.1 Oreo ==="
adb connect 127.0.0.1:5555 || true
for i in {1..35}; do
  BOOT_COMPLETED=$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r\n')
  if [ "$BOOT_COMPLETED" = "1" ]; then
    echo " Android 8.1 Oreo démarré et 100% opérationnel !"
    break
  fi
  echo "Initialisation Oreo [$i/35]..."
  sleep 2
done

# Déverrouiller et stabiliser
adb -s 127.0.0.1:5555 shell input keyevent 82 2>/dev/null || true

# 6. Démarrage Xvfb 720x1440 + Scrcpy 60 FPS + x11vnc sans aucun délai
echo "=== Démarrage de la chaîne graphique 60 FPS ==="
Xvfb :99 -screen 0 720x1440x24 -nocursor &
sleep 2

export DISPLAY=:99
scrcpy -s 127.0.0.1:5555 \
  --window-title="Android8Screen" \
  --window-x=0 --window-y=0 \
  --window-width=720 --window-height=1440 \
  --video-bit-rate=8M \
  --max-fps=60 \
  --stay-awake \
  --render-driver=software &
sleep 3

x11vnc -display :99 -nopw -forever -shared -repeat -rfbport 5900 -noxrecord -noxdamage -wait 0 -defer 0 &
sleep 2

websockify --web /usr/share/novnc 6080 127.0.0.1:5900 &
sleep 2

# 7. Démarrage de l'API Bridge Android
echo "=== Démarrage de l'API Bridge Android ==="
pkill -f android-bridge.cjs 2>/dev/null || true
CURRENT_DIR=$(pwd)
node "$CURRENT_DIR/scripts/android-bridge.cjs" &
sleep 1

# 8. Configuration NGINX Reverse-Proxy
echo "=== Configuration du Reverse-Proxy NGINX ==="
sudo mkdir -p /var/www/android-web
sudo cp -r "$CURRENT_DIR/android-web/"* /var/www/android-web/
sudo chmod -R 755 /var/www/android-web

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # Interface Web Android 8.1 (Mode Normal Smartphone avec cadre + bouton Détection Plein Écran)
    location / {
        root /var/www/android-web;
        index index.html;
        try_files $uri $uri/ @novnc_proxy;
    }

    # API Bridge Android (Détection clavier, saisie, touches matérielles)
    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    # Flux noVNC WebSockets
    location /websockify {
        proxy_pass http://127.0.0.1:6080/websockify;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    # Proxy noVNC direct (fichiers vnc.html, scripts, etc.)
    location @novnc_proxy {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 9. Validation active
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo " Serveur Web Android 8.1 opérationnel (HTTP 200) !"
    break
  fi
  sleep 2
done

echo "=================================================="
echo " Android 8.1 Oreo Prêt sur Port 3000 !"
echo "=================================================="
