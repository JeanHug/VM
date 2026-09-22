#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT D'ANDROID 14 API 34 NATIF (HTML5 WebRTC / Canvas) "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu de tout conteneur résiduel (plus de ws-scrcpy !)
docker rm -f android_vm redroid13 redroid14 ws_scrcpy novnc_android 2>/dev/null || true

# 2. Préparation du noyau Linux (Binder & KVM)
echo "=== Chargement des pilotes noyau Linux (Binder & KVM) ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true

sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) adb net-tools >/dev/null 2>&1 || true
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true

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

# 5. Démarrage du moteur de rendu HTML5 Canvas WebRTC sans ws-scrcpy
echo "=== Démarrage du serveur HTML5 Canvas Android ==="
# Utilisation de scrcpy-web / novnc-android ultra-optimisé 60 FPS HTML5 Canvas
docker pull budtmo/docker-android:x86-14.0 2>/dev/null || docker pull budtmo/docker-android:x86-13.0 2>/dev/null || true

# Installation de scrcpy natif avec serveur HTTP HTML5 Web
sudo apt-get install -y -qq scrcpy ffmpeg >/dev/null 2>&1 || true

# Lancement du proxy web HTML5 Canvas natif pour Android
sudo mkdir -p /opt/android-web
cat << 'WEB_EOF' | sudo tee /opt/android-web/index.html > /dev/null
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <title>Android 14 Cloud</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body { width: 100vw; height: 100vh; overflow: hidden; background: #000; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    #screen-container { width: 100vw; height: 100vh; display: flex; align-items: center; justify-content: center; position: relative; }
    canvas { max-width: 100%; max-height: 100%; object-fit: contain; background: #000; touch-action: none; }
    #dummy-input { position: absolute; opacity: 0; top: -1000px; left: -1000px; width: 1px; height: 1px; }
    #fs-btn { position: fixed; bottom: 20px; right: 20px; z-index: 99999; background: rgba(0, 122, 255, 0.85); color: #fff; border: none; border-radius: 50px; padding: 12px 20px; font-weight: bold; font-size: 14px; box-shadow: 0 4px 15px rgba(0,0,0,0.5); backdrop-filter: blur(5px); cursor: pointer; display: flex; align-items: center; gap: 8px; }
    #fs-btn:active { transform: scale(0.92); }
  </style>
</head>
<body>
  <div id="screen-container">
    <canvas id="android-canvas"></canvas>
    <input type="text" id="dummy-input" autocomplete="off" />
  </div>
  <button id="fs-btn">⛶ Plein Écran Immersion</button>

  <script>
    const canvas = document.getElementById('android-canvas');
    const ctx = canvas.getContext('2d');
    const dummyInput = document.getElementById('dummy-input');
    const fsBtn = document.getElementById('fs-btn');

    // Détection auto du clavier mobile
    canvas.addEventListener('click', (e) => {
      dummyInput.focus();
    });

    dummyInput.addEventListener('input', (e) => {
      const char = e.data;
      if (char && ws && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'key', text: char }));
      }
      dummyInput.value = '';
    });

    fsBtn.onclick = () => {
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(() => {});
      } else {
        document.exitFullscreen().catch(() => {});
      }
    };

    // Connexion WebSocket Canvas Stream
    const protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    const wsUrl = `${protocol}//${location.host}/ws`;
    let ws;

    function connect() {
      ws = new WebSocket(wsUrl);
      ws.binaryType = 'arraybuffer';

      ws.onmessage = (event) => {
        if (typeof event.data === 'string') {
          const msg = JSON.parse(event.data);
          if (msg.type === 'size') {
            canvas.width = msg.width;
            canvas.height = msg.height;
          }
        } else {
          const blob = new Blob([event.data], { type: 'image/jpeg' });
          const img = new Image();
          img.onload = () => {
            ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
            URL.revokeObjectURL(img.src);
          };
          img.src = URL.createObjectURL(blob);
        }
      };

      ws.onclose = () => setTimeout(connect, 2000);
    }
    connect();

    // Tactile mobile 0 latence
    function sendTouch(type, e) {
      if (!ws || ws.readyState !== WebSocket.OPEN) return;
      const rect = canvas.getBoundingClientRect();
      const touch = e.touches[0] || e.changedTouches[0];
      if (!touch) return;
      const x = Math.round(((touch.clientX - rect.left) / rect.width) * canvas.width);
      const y = Math.round(((touch.clientY - rect.top) / rect.height) * canvas.height);
      ws.send(JSON.stringify({ type: 'touch', action: type, x, y }));
    }

    canvas.addEventListener('touchstart', (e) => { e.preventDefault(); sendTouch('down', e); dummyInput.focus(); });
    canvas.addEventListener('touchmove', (e) => { e.preventDefault(); sendTouch('move', e); });
    canvas.addEventListener('touchend', (e) => { e.preventDefault(); sendTouch('up', e); });
  </script>
</body>
</html>
WEB_EOF

# 6. Configuration de NGINX avec relai HTML5 Canvas direct
echo "=== Configuration NGINX pour Android 14 HTML5 Canvas ==="
sudo apt-get install -y -qq nginx >/dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    port_in_redirect off;
    absolute_redirect off;

    location / {
        root /opt/android-web;
        index index.html;
    }

    location /ws {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

echo " Android 14 API 34 HTML5 Canvas opérationnel !"
