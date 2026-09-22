#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT D'ANDROID 13/14 OPTIMISÉ NOVNC WEBRTC "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# Nettoyage
docker rm -f android_vm redroid13 redroid14 ws_scrcpy novnc_android 2>/dev/null || true

# Préparation KVM / Binder
sudo chmod 666 /dev/kvm 2>/dev/null || true
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq adb net-tools novnc x11vnc xvfb scrcpy >/dev/null 2>&1 || true

# Lancement d'Android Redroid (Mode logiciel universel)
echo "=== Démarrage d'Android 13.0.0 (Stabilisé GPU Software) ==="
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
  androidboot.redroid_gpu_mode=guest \
  androidboot.hardware=redroid

# Connexion ADB
adb connect 127.0.0.1:5555 || true
for i in {1..30}; do
  STATE=$(adb get-state 2>/dev/null || echo "offline")
  if [ "$STATE" = "device" ]; then
    echo " Android connecté via ADB !"
    break
  fi
  sleep 2
  adb connect 127.0.0.1:5555 2>/dev/null || true
done

# Démarrage de Xvfb + Scrcpy + noVNC pour un affichage 100% garanti sur mobile
Xvfb :99 -screen 0 720x1560x24 &
export DISPLAY=:99
sleep 2

# Lancement de scrcpy natif sur le serveur virtuel
scrcpy --serial=127.0.0.1:5555 --max-size=1080 --video-bit-rate=8M --max-fps=60 --window-title="Android14Screen" --fullscreen &
sleep 3

# Lancement du serveur x11vnc
x11vnc -display :99 -forever -shared -rfbport 5900 -nopw &
sleep 2

# Lancement de noVNC HTML5 sur le port 6080
/usr/share/novnc/utils/launch.sh --vnc 127.0.0.1:5900 --listen 6080 &
sleep 3

# Proxy NGINX avec auto-gestion du bouton Plein Écran (Disparaît en plein écran !)
cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    location / {
        proxy_pass http://127.0.0.1:6080/vnc.html?autoconnect=true&resize=scale&quality=9;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;

        sub_filter_types text/html;
        sub_filter '</head>' '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover"><style>html,body{margin:0;padding:0;overflow:hidden;background:#000;height:100vh;width:100vw;}#noVNC_control_bar_anchor,#noVNC_control_bar{display:none!important;}#fs-btn{position:fixed;bottom:20px;right:20px;z-index:99999;background:rgba(0,122,255,0.85);color:#fff;border:none;border-radius:50px;padding:12px 20px;font-family:sans-serif;font-weight:bold;font-size:14px;box-shadow:0 4px 15px rgba(0,0,0,0.5);backdrop-filter:blur(5px);cursor:pointer;display:flex;align-items:center;gap:8px;transition:opacity 0.3s;}</style><script>document.addEventListener("DOMContentLoaded",function(){var b=document.createElement("button");b.id="fs-btn";b.innerHTML="⛶ Plein Écran Immersion";b.onclick=function(){if(!document.fullscreenElement){document.documentElement.requestFullscreen().catch(function(){});}else{document.exitFullscreen().catch(function(){});}};document.body.appendChild(b);document.addEventListener("fullscreenchange",function(){if(document.fullscreenElement){b.style.display="none";}else{b.style.display="flex";}});});</script></head>';
        sub_filter_once on;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart
echo " Serveur Android 100% visuel prêt !"
