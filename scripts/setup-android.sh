#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT D'ANDROID 13 NATIF (AOSP + SCRCPY)   "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu de tout ancien conteneur émulateur
docker rm -f android_vm redroid13 ws_scrcpy 2>/dev/null || true

# 2. Préparation du noyau Linux (Pilotes Binder & KVM natifs)
echo "=== Chargement des pilotes noyau Linux (Binder & KVM) ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true

# Chargement du module binder_linux pour le noyau Ubuntu runner
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) adb >/dev/null 2>&1 || true
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true

# Montage du système de fichiers BinderFS si nécessaire
sudo mkdir -p /dev/binderfs 2>/dev/null || true
sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
sudo ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
sudo ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
sudo ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
sudo chmod 777 /dev/binder* /dev/binderfs/* 2>/dev/null || true

# 3. Démarrage de Redroid 13 (Android 13 Officiel AOSP natif, sans émulateur QEMU)
echo "=== Démarrage d'Android 13 Natif (Redroid 13.0) ==="
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

# 4. Connexion ADB au système Android 13
echo "=== Connexion ADB au système Android 13 ==="
adb connect 127.0.0.1:5555 || true
for i in {1..30}; do
  STATE=$(adb get-state 2>/dev/null || echo "offline")
  echo "[Tentative $i/30] État ADB : $STATE"
  if [ "$STATE" = "device" ]; then
    echo " Android 13 démarré et connecté avec succès !"
    break
  fi
  sleep 2
  adb connect 127.0.0.1:5555 2>/dev/null || true
done

# 5. Démarrage du serveur Web Scrcpy (Flux H.264 60 FPS, plein écran natif, zéro cadre)
echo "=== Démarrage du serveur Web Scrcpy (Flux H.264 matériel) ==="
docker pull sorcx/ws-scrcpy:latest || true

docker run -d \
  --name ws_scrcpy \
  --net=host \
  --restart always \
  sorcx/ws-scrcpy:latest

# 6. Configuration de NGINX pour router vers WS-Scrcpy sur le port 3000
echo "=== Configuration du reverse-proxy NGINX ==="
sudo apt-get install -y -qq nginx >/dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    port_in_redirect off;
    absolute_redirect off;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    # Proxy direct vers le client WS-Scrcpy (Canvas Plein Écran H.264)
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 7. Test de validation en ligne
echo "=== Vérification active de WS-Scrcpy ==="
for i in {1..30}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  echo "[Tentative $i/30] WS-Scrcpy HTTP Status : $HTTP_CODE"
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo " Serveur WS-Scrcpy Android 13 actif et prêt !"
    break
  fi
  sleep 2
done

echo " Android 13 Natif AOSP opérationnel sans émulateur !"
