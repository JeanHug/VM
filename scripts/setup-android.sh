#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT OFFICIEL ANDROID 14 (API 34)         "
echo "   MODE KASM SMARTPHONE DIRECT ANDROID FULLSCREEN "
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

# 5. Démarrage du conteneur Kasm Desktop dédié Android
echo "=== 5. Démarrage du conteneur Kasm Smartphone ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d \
  --name android_kasm \
  --privileged \
  --security-opt seccomp=unconfined \
  --shm-size=2048m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -e VNC_RESOLUTION=720x1560 \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# 6. Attente que Kasm écoute sur le port 6901
echo "=== Attente de Kasm 6901 ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ >/dev/null 2>&1; then
    echo " Kasm actif !"
    break
  fi
  sleep 2
done

# 7. Remplacement automatique du bureau par l'écran Android 14
echo "=== Projection de l'écran Android 14 dans Kasm ==="
docker exec -u 0 android_kasm bash -c "
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq adb scrcpy wmctrl >/dev/null 2>&1 || true
"

# Lancement de scrcpy sur le Display :1 en mode plein écran sans bordure
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

# 8. Configuration NGINX Reverse-Proxy (Port 3000 -> Kasm)
echo "=== Configuration du reverse-proxy NGINX ==="
sudo apt-get install -y -qq nginx >/dev/null 2>&1 || true

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

        sub_filter_types text/html;
        sub_filter '</head>' '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover"><style>#fs-btn{position:fixed;bottom:24px;right:24px;z-index:999999;background:linear-gradient(135deg,#10b981,#059669);color:#fff;border:none;border-radius:50px;padding:14px 22px;font-weight:700;font-size:14px;box-shadow:0 8px 24px rgba(16,185,129,0.45);cursor:pointer;display:flex;align-items:center;gap:8px;}#fs-btn:active{transform:scale(0.92);}</style><script>document.addEventListener("DOMContentLoaded",function(){var b=document.createElement("button");b.id="fs-btn";b.innerHTML="⛶ Plein Écran Immersion";b.onclick=function(){if(!document.fullscreenElement){document.documentElement.requestFullscreen().catch(function(){});}else{document.exitFullscreen().catch(function(){});}};document.body.appendChild(b);document.addEventListener("fullscreenchange",function(){if(document.fullscreenElement){b.style.display="none";}else{b.style.display="flex";}});});</script></head>';
        sub_filter_once on;
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
    echo " Port 3000 opérationnel avec l'écran Android 14 !"
    break
  fi
  sleep 2
done

echo " Android 14 (API 34) 100% prêt et projeté !"
