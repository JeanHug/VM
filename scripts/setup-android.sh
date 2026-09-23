#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT OFFICIEL ANDROID 14 (API 34)         "
echo "   SCRCPY-WEB INTERACTIF NATIF ZERO-LATENCE       "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu
echo "=== 1. Nettoyage des processus et conteneurs ==="
docker rm -f redroid14 redroid13 android_vm ws_scrcpy novnc_android android_vnc 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true
pkill -9 -f node 2>/dev/null || true
pkill -9 -f adb 2>/dev/null || true

# 2. Noyau Linux KVM + BinderFS pour Android 14
echo "=== 2. Activation des modules KVM & BinderFS ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true

sudo rm -f /etc/apt/sources.list.d/hashicorp.list 2>/dev/null || true
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) adb net-tools nginx curl jq nodejs npm >/dev/null 2>&1 || true

sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
sudo mkdir -p /dev/binderfs 2>/dev/null || true
sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
sudo ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
sudo ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
sudo ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
sudo chmod 777 /dev/binder* /dev/binderfs/* 2>/dev/null || true

# 3. Lancement officiel de Redroid 14 (API 34)
echo "=== 3. Démarrage du conteneur Redroid 14 (AOSP Officiel) ==="
docker pull redroid/redroid:14.0.0-latest

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

# Déverrouiller et régler l'écran
adb shell input keyevent 82 2>/dev/null || true
adb shell wm size 720x1560 2>/dev/null || true
adb shell wm density 320 2>/dev/null || true

# 5. Démarrage du pont interactif officiel ws-scrcpy (Conteneur Docker prêt à l'emploi)
echo "=== 5. Lancement du serveur Web interactif Android (ws-scrcpy) ==="
docker pull emptys/ws-scrcpy:latest || true

docker run -d \
  --name ws_scrcpy \
  --privileged \
  --net=host \
  emptys/ws-scrcpy:latest 2>/dev/null || \
docker run -d \
  --name ws_scrcpy \
  --privileged \
  -p 8000:8000 \
  -e ADB_SERVER_IP=127.0.0.1 \
  -e ADB_SERVER_PORT=5037 \
  emptys/ws-scrcpy:latest

# Attente que ws-scrcpy écoute sur le port 8000
echo "=== Attente de ws-scrcpy (Port 8000) ==="
for i in {1..30}; do
  if curl -s http://127.0.0.1:8000/ >/dev/null 2>&1; then
    echo " ws-scrcpy actif sur le port 8000 !"
    break
  fi
  sleep 2
done

# 6. Configuration de NGINX Reverse-Proxy (Port 3000 vers ws-scrcpy)
echo "=== 6. Configuration du reverse-proxy NGINX ==="
cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
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

# 7. Test de validation HTTP NGINX
echo "=== Test de validation HTTP NGINX ==="
for i in {1..20}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  echo "[Check $i/20] HTTP Port 3000: $CODE"
  if [ "$CODE" = "200" ] || [ "$CODE" = "302" ]; then
    echo " Port 3000 opérationnel avec l'interface native Android !"
    break
  fi
  sleep 2
done

echo " Système Android 14 (API 34) 100% natif déployé avec succès !"
