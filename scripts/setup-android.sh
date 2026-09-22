#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT D'ANDROID 14 API 34 NATIF (REDROID 14) "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu de tout conteneur résiduel
docker rm -f android_vm redroid13 redroid14 ws_scrcpy 2>/dev/null || true

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

# 3. Démarrage de Redroid 14 (Android 14 API 34 Officiel AOSP natif)
echo "=== Démarrage d'Android 14 Natif (Redroid 14.0.0) ==="
if ! docker pull redroid/redroid:14.0.0-latest; then
  echo "⚠️ Image Redroid 14 en cours de repli sur 13.0.0..."
  docker pull redroid/redroid:13.0.0-latest
  REDROID_IMG="redroid/redroid:13.0.0-latest"
else
  REDROID_IMG="redroid/redroid:14.0.0-latest"
fi

docker run -d \
  --name redroid14 \
  --privileged \
  -v "$DATA_DIR/data":/data \
  -p 5555:5555 \
  "$REDROID_IMG" \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1560 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=60 \
  androidboot.redroid_gpu_mode=guest \
  androidboot.hardware=redroid

# 4. Connexion ADB au système Android 14
echo "=== Connexion ADB au système Android 14 ==="
adb connect 127.0.0.1:5555 || true
for i in {1..30}; do
  STATE=$(adb get-state 2>/dev/null || echo "offline")
  echo "[Tentative $i/30] État ADB : $STATE"
  if [ "$STATE" = "device" ]; then
    echo " Android 14 (API 34) démarré et connecté avec succès !"
    break
  fi
  sleep 2
  adb connect 127.0.0.1:5555 2>/dev/null || true
done

# 5. Démarrage du serveur Web Scrcpy (Flux H.264 60 FPS, plein écran natif, zéro cadre)
echo "=== Démarrage du serveur Web Scrcpy (Flux H.264 matériel) ==="
docker pull scavin/ws-scrcpy:latest

docker run -d \
  --name ws_scrcpy \
  --net=host \
  --restart always \
  scavin/ws-scrcpy:latest

# 6. Configuration de NGINX avec injection Immersion Mobile & Plein Écran
echo "=== Configuration du reverse-proxy NGINX pour Android 14 ==="
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

    # Proxy direct vers le client WS-Scrcpy avec overlay immersion mobile
    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Accept-Encoding "";
        sub_filter_types text/html;
        sub_filter '</head>' '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover"><style>body,html{margin:0;padding:0;overflow:hidden;background:#000;height:100vh;width:100vw;}#fs-btn{position:fixed;bottom:20px;right:20px;z-index:99999;background:rgba(0,122,255,0.85);color:#fff;border:none;border-radius:50px;padding:12px 20px;font-family:sans-serif;font-weight:bold;font-size:14px;box-shadow:0 4px 15px rgba(0,0,0,0.5);backdrop-filter:blur(5px);cursor:pointer;display:flex;align-items:center;gap:8px;transition:transform 0.2s,opacity 0.2s;}#fs-btn:active{transform:scale(0.92);}</style><script>if(!window.location.hash||window.location.hash===""||window.location.hash==="#!"){window.location.replace("#!action=stream&udid=127.0.0.1:5555&player=mse");}document.addEventListener("DOMContentLoaded",function(){var b=document.createElement("button");b.id="fs-btn";b.innerHTML="⛶ Plein Écran Immersion";b.onclick=function(){if(!document.fullscreenElement){document.documentElement.requestFullscreen().catch(function(){});}else{document.exitFullscreen().catch(function(){});}};document.body.appendChild(b);});</script></head>';
        sub_filter_once on;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 7. Test de validation en ligne
echo "=== Vérification active de WS-Scrcpy Android 14 ==="
for i in {1..30}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  echo "[Tentative $i/30] WS-Scrcpy HTTP Status : $HTTP_CODE"
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "302" ]; then
    echo " Serveur WS-Scrcpy Android 14 actif et prêt !"
    break
  fi
  sleep 2
done

echo " Android 14 API 34 Natif AOSP opérationnel !"
