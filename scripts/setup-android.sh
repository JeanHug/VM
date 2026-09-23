#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT D'ANDROID 14 (API 34) OFFICIEL       "
echo "   WEBRTC / WEBSOCKET DIRECT SANS ERREUR NOVNC    "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu
echo "=== Nettoyage des conteneurs et processus existants ==="
docker rm -f redroid14 redroid13 android_vm ws_scrcpy novnc_android 2>/dev/null || true
pkill -9 -f scrcpy 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

# 2. Noyau Linux KVM + BinderFS pour Android 14
echo "=== Chargement et configuration des modules noyau (KVM + Binder) ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true

sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) adb net-tools novnc x11vnc xvfb scrcpy nginx curl jq python3 python3-pip >/dev/null 2>&1 || true

sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true
sudo mkdir -p /dev/binderfs 2>/dev/null || true
sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
sudo ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
sudo ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
sudo ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
sudo chmod 777 /dev/binder* /dev/binderfs/* 2>/dev/null || true

# 3. Lancement du conteneur Redroid 14 (API 34)
echo "=== Démarrage du conteneur Redroid 14.0.0 ==="
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

# 4. Connexion ADB et validation complète de l'initialisation Android 14
echo "=== Connexion ADB à Android 14 ==="
adb connect 127.0.0.1:5555 || true
for i in {1..45}; do
  STATE=$(adb get-state 2>/dev/null || echo "offline")
  echo "[Tentative $i/45] ADB Status: $STATE"
  if [ "$STATE" = "device" ]; then
    echo " ADB connecté !"
    break
  fi
  sleep 2
  adb connect 127.0.0.1:5555 2>/dev/null || true
done

echo "=== Attente de l'animation de démarrage et de l'initialisation système ==="
for i in {1..35}; do
  BOOT=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || echo "0")
  echo "[Boot $i/35] sys.boot_completed = $BOOT"
  if [ "$BOOT" = "1" ]; then
    echo " Android 14 prêt !"
    break
  fi
  sleep 2
done

# Réveil, déverrouillage et résolution
adb shell input keyevent 82 2>/dev/null || true
adb shell wm size 720x1560 2>/dev/null || true
adb shell wm density 320 2>/dev/null || true

# 5. Xvfb + Scrcpy + X11VNC + noVNC sans déconnexion
echo "=== Démarrage du serveur d'affichage X11 (720x1560) ==="
Xvfb :99 -screen 0 720x1560x24 -ac +extension GLX +render -noreset &
export DISPLAY=:99
sleep 2

echo "=== Démarrage de Scrcpy ==="
scrcpy --serial=127.0.0.1:5555 \
       --max-size=1560 \
       --video-bit-rate=8M \
       --max-fps=60 \
       --window-title="Android14Screen" \
       --window-x=0 --window-y=0 \
       --window-width=720 --window-height=1560 \
       --disable-screensaver \
       --stay-awake &

sleep 3

echo "=== Démarrage de X11VNC ==="
x11vnc -display :99 \
       -forever \
       -shared \
       -rfbport 5900 \
       -nopw \
       -wait 5 \
       -defer 5 \
       -noxdamage \
       -speed 100 \
       -nowf &

sleep 2

# Recherche du dossier novnc
NOVNC_DIR="/usr/share/novnc"
if [ ! -d "$NOVNC_DIR" ]; then
  NOVNC_DIR="/opt/novnc"
fi

echo "=== Démarrage de Websockify sur le port 6080 ==="
websockify --web "$NOVNC_DIR" --wrap-mode=ignore 6080 127.0.0.1:5900 &
sleep 3

# 6. Création de l'interface Android 14 avec client noVNC direct RFB (zéro iframe buggé, auto-reconnexion)
echo "=== Configuration du lecteur Web noVNC Direct Mobile ==="
sudo mkdir -p /opt/android-web
cat << 'WEB_EOF' | sudo tee /opt/android-web/index.html > /dev/null
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <title>Android 14 Cloud (API 34)</title>
  <style>
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }
    html, body {
      width: 100vw;
      height: 100vh;
      overflow: hidden;
      background: #000;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    #screen-container {
      width: 100vw;
      height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;
      background: #000;
      touch-action: none;
    }
    canvas {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      background: #000;
    }
    #fs-btn {
      position: fixed;
      bottom: 24px;
      right: 24px;
      z-index: 99999;
      background: linear-gradient(135deg, #10b981, #059669);
      color: #fff;
      border: none;
      border-radius: 50px;
      padding: 14px 22px;
      font-weight: 700;
      font-size: 14px;
      box-shadow: 0 8px 24px rgba(16, 185, 129, 0.45);
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 8px;
      transition: transform 0.2s ease, opacity 0.2s ease;
    }
    #fs-btn:active {
      transform: scale(0.92);
    }
    #status-overlay {
      position: absolute;
      top: 15px;
      left: 50%;
      transform: translateX(-50%);
      background: rgba(16, 185, 129, 0.9);
      color: white;
      padding: 6px 14px;
      border-radius: 20px;
      font-size: 12px;
      font-weight: 600;
      pointer-events: none;
      z-index: 1000;
      transition: opacity 0.5s ease;
    }
    #dummy-input {
      position: absolute;
      opacity: 0;
      top: -1000px;
      left: -1000px;
      width: 1px;
      height: 1px;
    }
  </style>
  <script type="module">
    import RFB from './core/rfb.js';

    let rfb;
    const container = document.getElementById('screen-container');
    const statusOverlay = document.getElementById('status-overlay');
    const dummyInput = document.getElementById('dummy-input');
    const fsBtn = document.getElementById('fs-btn');

    function connect() {
      statusOverlay.style.display = 'block';
      statusOverlay.textContent = 'Connexion à Android 14...';
      statusOverlay.style.background = 'rgba(37, 99, 235, 0.9)';

      const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
      const url = `${protocol}//${window.location.host}/websockify`;

      rfb = new RFB(container, url, {
        shared: true,
        credentials: { password: '' }
      });

      rfb.scaleViewport = true;
      rfb.resizeSession = false;
      rfb.focusOnClick = true;

      rfb.addEventListener('connect', () => {
        statusOverlay.textContent = 'Android 14 Connecté';
        statusOverlay.style.background = 'rgba(16, 185, 129, 0.9)';
        setTimeout(() => { statusOverlay.style.opacity = '0'; }, 2000);
      });

      rfb.addEventListener('disconnect', (e) => {
        statusOverlay.style.opacity = '1';
        statusOverlay.style.display = 'block';
        statusOverlay.style.background = 'rgba(239, 68, 68, 0.9)';
        statusOverlay.textContent = 'Reconnexion en cours...';
        setTimeout(connect, 2000);
      });
    }

    // Gestion Plein Écran & disparition automatique du bouton
    fsBtn.addEventListener('click', () => {
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(() => {});
      } else {
        document.exitFullscreen().catch(() => {});
      }
    });

    document.addEventListener('fullscreenchange', () => {
      if (document.fullscreenElement) {
        fsBtn.style.display = 'none';
      } else {
        fsBtn.style.display = 'flex';
      }
    });

    // Détection pour ouverture du clavier virtuel mobile au tap
    container.addEventListener('click', () => {
      dummyInput.focus();
    });

    dummyInput.addEventListener('input', (e) => {
      if (rfb && e.data) {
        for (let i = 0; i < e.data.length; i++) {
          rfb.sendKey(e.data.charCodeAt(i), 1);
          rfb.sendKey(e.data.charCodeAt(i), 0);
        }
      }
      dummyInput.value = '';
    });

    connect();
  </script>
</head>
<body>
  <div id="status-overlay">Initialisation...</div>
  <div id="screen-container"></div>
  <input type="text" id="dummy-input" autocomplete="off" autocapitalize="off" spellcheck="false" />
  <button id="fs-btn">⛶ Plein Écran Immersion</button>
</body>
</html>
WEB_EOF

# Copie des fichiers noVNC vers /opt/android-web pour inclusion modulaire
sudo cp -r /usr/share/novnc/* /opt/android-web/ 2>/dev/null || sudo cp -r /opt/novnc/* /opt/android-web/ 2>/dev/null || true

# 7. Configuration NGINX Reverse-Proxy
echo "=== Configuration NGINX ==="
cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    root /opt/android-web;
    index index.html;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location / {
        try_files $uri $uri/ /index.html;
    }

    location /websockify {
        proxy_pass http://127.0.0.1:6080/websockify;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo nginx -t
sudo systemctl restart nginx || sudo service nginx restart

# 8. Test HTTP Local
echo "=== Vérification de l'interface ==="
for i in {1..20}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  echo "[Check $i/20] HTTP Port 3000 : $CODE"
  if [ "$CODE" = "200" ]; then
    echo " Interface Web et Websocket prêts !"
    break
  fi
  sleep 2
done

echo " Android 14 avec client direct opérationnel !"
