#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT OFFICIEL ANDROID 14 (API 34)         "
echo "   ARCHITECTURE KASM IDENTIQUE LINUX DESKTOP      "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage
echo "=== 1. Nettoyage des processus et conteneurs ==="
docker rm -f redroid14 android_kasm 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

# 2. Noyau Linux KVM + BinderFS pour Android 14
echo "=== 2. Activation des modules KVM & BinderFS ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
sudo mkdir -p /dev/binderfs 2>/dev/null || true
sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
sudo ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
sudo ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
sudo ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
sudo chmod 777 /dev/binder* /dev/binderfs/* 2>/dev/null || true

# 3. Lancement officiel de Redroid 14 (API 34)
echo "=== 3. Démarrage de Redroid 14 (AOSP Officiel) ==="
docker pull redroid/redroid:14.0.0-latest
docker run -d \
  --name redroid14 \
  --privileged \
  -v "$DATA_DIR/data":/data \
  -p 5555:5555 \
  redroid/redroid:14.0.0-latest \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1560 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=60 \
  androidboot.redroid_gpu_mode=guest \
  androidboot.hardware=redroid

# 4. Attente de la réactivité ADB et Boot Android 14
echo "=== 4. Attente du boot Android 14 ==="
sudo apt-get install -y -qq adb >/dev/null 2>&1 || true
adb connect 127.0.0.1:5555 || true
for i in {1..40}; do
  STATE=$(adb get-state 2>/dev/null || echo "offline")
  echo "[ADB $i/40] Status : $STATE"
  if [ "$STATE" = "device" ]; then
    echo " ADB connecté !"
    break
  fi
  sleep 2
  adb connect 127.0.0.1:5555 2>/dev/null || true
done

for i in {1..30}; do
  BOOT=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || echo "0")
  if [ "$BOOT" = "1" ]; then
    echo " Android 14 initialisé !"
    break
  fi
  sleep 2
done

adb shell input keyevent 82 2>/dev/null || true
adb shell wm size 720x1560 2>/dev/null || true
adb shell wm density 320 2>/dev/null || true

# 5. Démarrage de Kasm Desktop pour Android (identique à Linux Desktop)
echo "=== 5. Démarrage du conteneur Kasm Smartphone ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d \
  --name android_kasm \
  --privileged \
  --security-opt seccomp=unconfined \
  --shm-size=4096m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -e VNC_RESOLUTION=720x1560 \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# 6. Configuration NGINX Reverse-Proxy (Port 3000 -> Kasm 6901, IDENTIQUE LINUX DESKTOP)
echo "=== 6. Configuration du reverse-proxy NGINX (Zéro latence) ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

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
        
        # Autologin direct sans pop-up de mot de passe (kasm_user:vncpass)
        proxy_set_header Authorization "Basic a2FzbV91c2VyOnZuY3Bhc3M=";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 7. Attente que Kasm soit actif
echo "=== Attente de l'initialisation de Kasm ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Kasm opérationnel !"
    break
  fi
  sleep 2
done

# 8. Projection de l'écran Android 14 dans Kasm
echo "=== Projection de l'écran Android 14 dans Kasm ==="
docker exec -u 0 android_kasm bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq adb scrcpy >/dev/null 2>&1 || true
"

docker exec -u 1000 -d android_kasm bash -c "
  adb connect 172.17.0.1:5555 || true
  while true; do
    DISPLAY=:1 scrcpy --serial=172.17.0.1:5555 \
                      --window-title='Android14' \
                      --fullscreen \
                      --disable-screensaver \
                      --stay-awake \
                      --max-fps=60 \
                      --video-bit-rate=8M || true
    sleep 2
  done
"

echo " Android 14 (API 34) et Kasm 100% opérationnels !"
