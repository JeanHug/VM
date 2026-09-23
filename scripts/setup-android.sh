#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT OFFICIEL ANDROID 14 (API 34)         "
echo "   ARCHITECTURE STABLE NO-CRASH & ZERO LATENCE    "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu
echo "=== 1. Nettoyage des processus antérieurs ==="
docker rm -f redroid14 redroid13 android_vm ws_scrcpy novnc_android 2>/dev/null || true
pkill -9 -f scrcpy 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

# 2. Noyau Linux KVM + BinderFS pour Android 14
echo "=== 2. Activation des modules KVM & BinderFS ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true
sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) adb net-tools novnc x11vnc xvfb scrcpy nginx curl jq >/dev/null 2>&1 || true

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

# 4. Attente de la connexion ADB et de l'initialisation Android
echo "=== 4. Connexion ADB & Initialisation Système ==="
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
    echo " Android 14 complètement prêt !"
    break
  fi
  sleep 2
done

adb shell input keyevent 82 2>/dev/null || true
adb shell wm size 720x1560 2>/dev/null || true
adb shell wm density 320 2>/dev/null || true

# 5. Lancement de Xvfb
echo "=== 5. Démarrage de l'affichage virtuel Xvfb :99 ==="
Xvfb :99 -screen 0 720x1560x24 -ac +extension GLX +render -noreset &
export DISPLAY=:99
sleep 2

# 6. Lancement de scrcpy avec redémarrage automatique en cas de déconnexion
echo "=== 6. Lancement de Scrcpy (Boucle de maintien en vie) ==="
cat << 'SCRCPY_SCRIPT' | sudo tee /usr/local/bin/run-scrcpy.sh > /dev/null
#!/usr/bin/env bash
export DISPLAY=:99
while true; do
  scrcpy --serial=127.0.0.1:5555 \
         --max-size=1560 \
         --video-bit-rate=8M \
         --max-fps=60 \
         --window-title="Android14Screen" \
         --window-x=0 --window-y=0 \
         --window-width=720 --window-height=1560 \
         --disable-screensaver \
         --stay-awake || true
  sleep 1
done
SCRCPY_SCRIPT
sudo chmod +x /usr/local/bin/run-scrcpy.sh
/usr/local/bin/run-scrcpy.sh &
sleep 3

# 7. Lancement de x11vnc
echo "=== 7. Démarrage de x11vnc ==="
cat << 'VNC_SCRIPT' | sudo tee /usr/local/bin/run-x11vnc.sh > /dev/null
#!/usr/bin/env bash
export DISPLAY=:99
while true; do
  x11vnc -display :99 \
         -forever \
         -shared \
         -rfbport 5900 \
         -nopw \
         -wait 5 \
         -defer 5 \
         -noxdamage \
         -speed 100 \
         -nowf || true
  sleep 1
done
VNC_SCRIPT
sudo chmod +x /usr/local/bin/run-x11vnc.sh
/usr/local/bin/run-x11vnc.sh &
sleep 2

# 8. Websockify natif
NOVNC_DIR="/usr/share/novnc"
[ ! -d "$NOVNC_DIR" ] && NOVNC_DIR="/opt/novnc"

echo "=== 8. Démarrage de Websockify sur 127.0.0.1:6080 ==="
websockify --web "$NOVNC_DIR" --wrap-mode=ignore 127.0.0.1:6080 127.0.0.1:5900 &
sleep 3

# 9. Interface Web Directe Mobile Ultra-Performante
sudo mkdir -p /opt/android-web
sudo cp -r "$NOVNC_DIR"/* /opt/android-web/ 2>/dev/null || true

cat << 'INDEX_PAGE' | sudo tee /opt/android-web/index.html > /dev/null
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <title>Android 14 Cloud (API 34)</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    html, body {
      width: 100vw;
      height: 100vh;
      overflow: hidden;
      background: #000;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    #screen {
      width: 100vw;
      height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      touch-action: none;
      background: #000;
    }
    canvas {
      max-width: 100%;
      max-height: 100%;
      object-fit: contain;
      box-shadow: 0 0 20px rgba(0,0,0,0.8);
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
      transition: opacity 0.2s ease, transform 0.2s ease;
    }
    #fs-btn:active { transform: scale(0.92); }
    #dummy-input {
      position: absolute;
      opacity: 0;
      left: -9999px;
      top: -9999px;
      width: 1px;
      height: 1px;
    }
  </style>
  <script type="module">
    import RFB from './core/rfb.js';

    const screenDiv = document.getElementById('screen');
    const dummyInput = document.getElementById('dummy-input');
    const fsBtn = document.getElementById('fs-btn');

    let rfb = null;

    function initVNC() {
      try {
        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const wsUrl = `${protocol}//${window.location.host}/websockify`;
        
        rfb = new RFB(screenDiv, wsUrl, {
          shared: true,
          wsProtocols: ['binary']
        });

        rfb.scaleViewport = true;
        rfb.resizeSession = false;
        rfb.focusOnClick = true;

        rfb.addEventListener('disconnect', () => {
          setTimeout(initVNC, 2000);
        });
      } catch (err) {
        setTimeout(initVNC, 2000);
      }
    }

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

    screenDiv.addEventListener('click', () => {
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

    initVNC();
  </script>
</head>
<body>
  <div id="screen"></div>
  <input type="text" id="dummy-input" autocomplete="off" autocapitalize="off" spellcheck="false" />
  <button id="fs-btn">⛶ Plein Écran Immersion</button>
</body>
</html>
INDEX_PAGE

# 10. Configuration NGINX Reverse-Proxy (Support complet des WebSockets)
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
        proxy_pass http://127.0.0.1:6080;
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

sudo nginx -t
sudo systemctl restart nginx || sudo service nginx restart

echo " Architecture Android 14 déployée et opérationnelle !"
