#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT OFFICIEL ANDROID 14 (API 34)         "
echo "   ARCHITECTURE KASM DOCKER-IN-DOCKER STABLE      "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu
echo "=== 1. Nettoyage des processus et conteneurs ==="
docker rm -f redroid14 redroid13 android_vm ws_scrcpy novnc_android android_vnc 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

# 2. Noyau Linux KVM + BinderFS pour Android 14
echo "=== 2. Activation des modules KVM & BinderFS ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true

# Réparation des dépôts APT corrompus sur le runner avant tout apt-get
sudo rm -f /etc/apt/sources.list.d/hashicorp.list 2>/dev/null || true
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) adb net-tools nginx curl jq >/dev/null 2>&1 || true

sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
sudo mkdir -p /dev/binderfs 2>/dev/null || true
sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
sudo ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
sudo ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
sudo ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
sudo chmod 777 /dev/binder* /dev/binderfs/* 2>/dev/null || true

# 3. Lancement officiel de Redroid 14 (API 34)
echo "=== 3. Démarrage du conteneur Redroid 14 (AOSP Officiel) ==="
docker run -d \
  --name redroid14 \
  --privileged \
  --pull always \
  -v "$DATA_DIR/data":/data \
  -p 5555:5555 \
  redroid/redroid:14.0.0-latest \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1560 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=60 \
  androidboot.redroid_gpu_mode=guest \
  androidboot.hardware=redroid

# 4. Attente active de la connexion ADB et de l'initialisation Android
echo "=== 4. Attente de la réactivité ADB et Boot Android 14 ==="
adb connect 127.0.0.1:5555 || true
for i in {1..45}; do
  STATE=$(adb get-state 2>/dev/null || echo "offline")
  echo "[ADB $i/45] État : $STATE"
  if [ "$STATE" = "device" ]; then
    echo " ADB connecté !"
    break
  fi
  sleep 2
  adb connect 127.0.0.1:5555 2>/dev/null || true
done

for i in {1..35}; do
  BOOT=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || echo "0")
  echo "[Boot $i/35] sys.boot_completed = $BOOT"
  if [ "$BOOT" = "1" ]; then
    echo " Android 14 prêt !"
    break
  fi
  sleep 2
done

adb shell input keyevent 82 2>/dev/null || true
adb shell wm size 720x1560 2>/dev/null || true
adb shell wm density 320 2>/dev/null || true

# 5. Démarrage de Kasm Desktop pour Android
echo "=== 5. Démarrage de Kasm Desktop Android ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d \
  --name android_vnc \
  --privileged \
  --security-opt seccomp=unconfined \
  --shm-size=2048m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -e VNC_RESOLUTION=720x1560 \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# 6. Attente que Kasm 6901 soit prêt
echo "=== Attente de l'initialisation de Kasm (Port 6901) ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ >/dev/null 2>&1; then
    echo " Port 6901 Kasm actif !"
    break
  fi
  sleep 2
done

# 7. Lancement de scrcpy à l'intérieur du conteneur Kasm
echo "=== Configuration et lancement de scrcpy ==="
docker exec -u 0 android_vnc bash -c "
  export DEBIAN_FRONTEND=noninteractive
  rm -f /etc/apt/sources.list.d/hashicorp.list 2>/dev/null || true
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq adb scrcpy >/dev/null 2>&1 || true
"

docker exec -u 1000 -d android_vnc bash -c "
  adb connect 172.17.0.1:5555 || true
  while true; do
    DISPLAY=:1 scrcpy --serial=172.17.0.1:5555 --max-size=1560 --video-bit-rate=8M --max-fps=60 --fullscreen --disable-screensaver --stay-awake || true
    sleep 2
  done
"

# 8. Configuration NGINX Reverse-Proxy
echo "=== Configuration du reverse-proxy NGINX (Port 3000) ==="
cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location / {
        proxy_pass https://127.0.0.1:6901;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Autologin direct kasm_user:vncpass
        proxy_set_header Authorization "Basic a2FzbV91c2VyOnZuY3Bhc3M=";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo nginx -t
sudo systemctl restart nginx || sudo service nginx restart

# 9. Test de validation HTTP NGINX
echo "=== Test de validation HTTP NGINX ==="
for i in {1..20}; do
  CODE=$(curl -s -k -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  echo "[Check $i/20] HTTP Port 3000: $CODE"
  if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
    echo " Port 3000 opérationnel avec Kasm !"
    break
  fi
  sleep 2
done

echo " Architecture Kasm + Android 14 prête !"
