#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID 8.1 OREO DIRECT BOOT - FORMAT PORTRAIT"
echo "  (Native Redroid Container + Scrcpy 720x1280)    "
echo "=================================================="

# 1. Configuration des modules de noyau Binder pour Android
echo "=== Chargement des modules Binder & Ashmem ==="
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
sudo modprobe ashmem_linux 2>/dev/null || true

# Configuration propre de BinderFS
if [ ! -d "/dev/binderfs" ]; then
  sudo mkdir -p /dev/binderfs
  sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
fi

# Construction des arguments de montage Docker pour Binder de manière dynamique et sûre
DOCKER_BINDER_ARGS=""
if [ -d "/dev/binderfs" ]; then
  DOCKER_BINDER_ARGS="$DOCKER_BINDER_ARGS -v /dev/binderfs:/dev/binderfs"
fi

for b in binder hwbinder vndbinder; do
  if [ -e "/dev/$b" ]; then
    DOCKER_BINDER_ARGS="$DOCKER_BINDER_ARGS -v /dev/$b:/dev/$b"
  elif [ -e "/dev/binderfs/$b" ]; then
    DOCKER_BINDER_ARGS="$DOCKER_BINDER_ARGS -v /dev/binderfs/$b:/dev/$b"
  fi
done

sudo chmod 666 /dev/binder* /dev/ashmem* /dev/binderfs/* 2>/dev/null || true

# 2. Nettoyage des anciens processus
pkill -9 -f scrcpy 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
docker rm -f redroid_vm android_oreo 2>/dev/null || true

# 3. Installation des outils requis (Scrcpy, Xvfb, x11vnc, noVNC, websockify, NGINX)
echo "=== Installation des outils graphiques & Scrcpy ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq adb scrcpy xvfb x11vnc websockify novnc nginx curl wget >/dev/null 2>&1 || true

# 4. Lancement du conteneur natif Android 8.1 Oreo calibré en Portrait 720x1280
echo "=== Démarrage d'Android 8.1 Oreo (720x1280, 280 DPI, 60 fps) ==="
docker run -d --privileged \
  --name android_oreo \
  $DOCKER_BINDER_ARGS \
  -p 5555:5555 \
  redroid/redroid:8.1.0-latest \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1280 \
  androidboot.redroid_dpi=280 \
  androidboot.redroid_fps=60 \
  androidboot.use_memfd=1 \
  androidboot.redroid_gpu_mode=guest

# 5. Attente de la fin du démarrage Android (boot_completed)
echo "=== Attente du démarrage complet d'Android (sys.boot_completed=1) ==="
sleep 3
adb connect 127.0.0.1:5555 || true
for i in {1..35}; do
  BOOT=$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || echo "0")
  if [ "$BOOT" = "1" ]; then
    echo " Android 8.1 Oreo a terminé son boot avec succès !"
    break
  fi
  sleep 2
done

# Configuration du déverrouillage et de l'environnement graphique
adb -s 127.0.0.1:5555 shell input keyevent 82 2>/dev/null || true # Unlock screen

# 6. Démarrage de l'affichage X11 virtuel en Portrait 720x1280 exact
echo "=== Lancement du serveur d'affichage Xvfb (720x1280x24) ==="
export DISPLAY=:99
Xvfb :99 -screen 0 720x1280x24 -ac +extension GLX +render -noreset &
sleep 2

# Lancement de Scrcpy plein cadre dans l'écran 720x1280
echo "=== Lancement du miroir Scrcpy vers le serveur X ==="
scrcpy -s 127.0.0.1:5555 \
  --window-title="Android Oreo" \
  --window-x=0 --window-y=0 \
  --window-width=720 --window-height=1280 \
  --window-borderless \
  --max-fps=60 \
  --video-bit-rate=8M \
  --turn-screen-off \
  --stay-awake &
sleep 2

# 7. Serveur VNC x11vnc configuré pour diffuser exactement la surface 720x1280
echo "=== Lancement de x11vnc sur :99 (port 5900) ==="
x11vnc -display :99 -forever -shared -nopw -rfbport 5900 -quiet -bg
sleep 1

# 8. Websockify reliant VNC 5900 vers le port 6080
echo "=== Lancement de websockify (port 6080 -> 5900) ==="
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 &
sleep 1

# 9. Bridge ADB pour le clavier direct et les touches
CURRENT_DIR=$(pwd)
WORK_DIR="/home/runner/work/VM/VM"
if [ -d "$WORK_DIR" ]; then
  CURRENT_DIR="$WORK_DIR"
fi
node "$CURRENT_DIR/scripts/android-bridge.cjs" &
sleep 1

# 10. Configuration NGINX Reverse-Proxy
echo "=== Configuration NGINX ==="
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

    # Interface Web Android 8.1 Oreo Smartphone
    location / {
        root /var/www/android-web;
        index index.html;
        try_files $uri $uri/ @novnc_proxy;
    }

    # API ADB / Touch / Key
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

    # Proxy noVNC direct
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

# 11. Validation du port 3000
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo " Serveur Web Android 8.1 Oreo opérationnel (HTTP 200) !"
    break
  fi
  sleep 2
done

echo "=================================================="
echo " Android 8.1 Oreo Smartphone GUI Prêt !"
echo "=================================================="
