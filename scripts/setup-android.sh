#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION DE LA VM NATIVE ANDROID 13      "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# Nettoyage d'anciens conteneurs
docker rm -f redroid13 ws_scrcpy android_vm 2>/dev/null || true

# 1. Préparation des modules noyau pour Android natif (Binder & KVM)
echo "=== Préparation des modules noyau (Binder / KVM) ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true

# Chargement du module binder si disponible
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
if [ ! -e /dev/binder ]; then
  sudo mkdir -p /dev/binderfs 2>/dev/null || true
  sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
  sudo ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
  sudo ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
  sudo ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
fi
sudo chmod 777 /dev/binder* /dev/binderfs/* 2>/dev/null || true

# 2. Démarrage d'Android 13
echo "=== Démarrage d'Android 13 en conteneur optimisé ==="
ANDROID_STARTED=false

# Tentative 1 : Redroid 13 natif si binder est présent
if [ -e /dev/binder ]; then
  echo "Binder détecté : lancement de Redroid 13 natif..."
  docker pull redroid/redroid:13.0.0-latest
  docker run -d \
    --name redroid13 \
    --privileged \
    -v "$DATA_DIR/data":/data \
    -p 5555:5555 \
    redroid/redroid:13.0.0-latest \
    androidboot.redroid_width=720 \
    androidboot.redroid_height=1280 \
    androidboot.redroid_dpi=320 \
    androidboot.redroid_fps=60 \
    androidboot.redroid_gpu_mode=guest
  ANDROID_STARTED=true
fi

# Tentative 2 : Si binder n'était pas disponible, démarrage du conteneur optimisé
if [ "$ANDROID_STARTED" = false ]; then
  echo "Lancement du conteneur Android haute performance..."
  docker pull budtmo/docker-android:emulator_11.0
  docker run -d \
    --name android_vm \
    --privileged \
    --device /dev/kvm \
    -p 6080:6080 \
    -p 5555:5555 \
    -e DEVICE="Samsung Galaxy S10" \
    -e WEB_VNC=true \
    -e WEB_PORT=6080 \
    -e APPIUM=false \
    -v "$DATA_DIR/data":/root/android \
    budtmo/docker-android:emulator_11.0
fi

# 3. Démarrage de l'interface Web WS-Scrcpy si Redroid 13 actif
if docker ps | grep -q redroid13; then
  echo "Lancement du serveur Web WS-Scrcpy (Flux H.264 ultra fluide)..."
  sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq adb >/dev/null 2>&1 || true
  adb connect 127.0.0.1:5555 || true

  docker run -d \
    --name ws_scrcpy \
    --net=host \
    sorcx/ws-scrcpy
fi

# 4. Configuration NGINX
echo "=== Configuration du reverse-proxy NGINX ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

TARGET_PORT=6080
if docker ps | grep -q ws_scrcpy; then
  TARGET_PORT=8000
fi

cat << NGINX_EOF | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location / {
        proxy_pass http://127.0.0.1:${TARGET_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 5. Attente active de la disponibilité du serveur Web
echo "=== Vérification active de la réponse Web ==="
for i in {1..40}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:${TARGET_PORT}/ || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo " Serveur Web Android actif (Code $HTTP_CODE) !"
    break
  fi
  sleep 2
done

echo " VM Android opérationnelle !"
